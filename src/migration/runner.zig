//! Migration runner: ordered, checksummed, transactional schema evolution.
//!
//! Purpose: apply a borrowed `Migration` slice to a live `Connection`,
//! tracking progress in the `_zig_migrations(version, name, checksum)` history
//! table. Guarantees: versions apply once in ascending order, gaps and
//! post-apply edits fail loudly, each non-VACUUM migration commits atomically,
//! and legacy history rows (name/checksum missing) are backfilled.
//!
//! Responsibilities: history-table creation/upgrade, applied-row loading,
//! version sorting + duplicate/gap/edit detection, single-migration apply with
//! savepoint discipline, and single-step rollback via `downSql`.
//!
//! Dependencies: `migration/migration.zig` (`Migration`), and
//! `connection/connection.zig` (`Connection.exec`, `beginImmediate`,
//! `commit`, `rollback`). Uses `std.testing`-visible file DBs in tests only.
//!
//! Ownership/lifetime: `Runner` borrows the caller's allocator and the
//! caller's migration slice (strings inside stay caller-owned, usually string
//! literals). `init` copies nothing. `apply`/`rollback` allocate transient
//! sorted copies, `Applied` name dupes, and checksum/record SQL, freeing all
//! of it before returning. The `Connection` must outlive the runner call and
//! must not be closed mid-apply. History rows are engine-owned once written.
//!
//! Error behavior: `DuplicateMigration` (two defs share a version),
//! `MissingMigration` (applied row without a def, gap above the history peak,
//! or reordered set skipping an unapplied version below the peak),
//! `ModifiedMigration` (name/checksum drift on an applied version),
//! `NoMigrationsApplied` / `NoDownMigration` on empty/missing rollback,
//! plus engine errors (`InvalidSql`, I/O, constraint violations). A failed
//! non-VACUUM migration rolls back its own transaction (when the runner began
//! it) and leaves prior history intact; a failed VACUUM body writes no history
//! row. When the caller already holds a transaction, the runner joins it and
//! never commits/rolls back the outer scope.
//!
//! SQLite compatibility: `_zig_migrations` uses plain DDL/DML understood by
//! any SQLite. VACUUM migrations must be self-contained single statements and
//! run outside a transaction (the engine rejects VACUUM inside BEGIN..COMMIT),
//! so the runner executes them without wrapping and records history separately.
//!
//! Unified pipeline note: migrations execute raw SQL scripts through the
//! native engine, like every other pipeline — there is no DSL->SQL-string
//! round trip here.
//!
//! Safety note: history INSERT/UPDATE statements interpolate the migration
//! `name` and hex checksum. Names are caller-controlled; see `escapeLiteral`
//! and the TODO on moving to bound parameters.

const std = @import("std");
const Migration = @import("migration.zig").Migration;
const Connection = @import("../connection/connection.zig").Connection;

/// Borrowed runner over a caller-owned migration slice. Owns nothing; the
/// slice and its strings must outlive every `apply`/`rollback` call.
pub const Runner = struct {
    allocator: std.mem.Allocator,
    migrations: []const Migration,

    /// Borrow the allocator (for transient sorted copies/records) and the
    /// caller-owned migration slice. Copies nothing. Never fails.
    pub fn init(allocator: std.mem.Allocator, migrations: []const Migration) Runner {
        return .{ .allocator = allocator, .migrations = migrations };
    }

    /// One applied history row. `name` is an owned dupe freed with `applied`;
    /// `hasChecksum` is false for legacy rows predating the checksum column.
    const Applied = struct {
        version: u32,
        name: []const u8,
        checksum: u64,
        hasChecksum: bool,
    };

    /// Create `_zig_migrations` if missing and add `name`/`checksum` columns
    /// to databases created by older versions. Idempotent; no rows touched.
    fn ensureHistoryTable(connection: *Connection) !void {
        var create = try connection.exec(
            "CREATE TABLE IF NOT EXISTS _zig_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT '', checksum TEXT NOT NULL DEFAULT '');",
        );
        create.deinit();
        // Upgrade databases created by older versions that only had `version`.
        var probe = try connection.exec("SELECT * FROM _zig_migrations LIMIT 0;");
        defer probe.deinit();
        var hasName = false;
        var hasChecksum = false;
        for (probe.columns) |c| {
            if (std.ascii.eqlIgnoreCase(c, "name")) hasName = true;
            if (std.ascii.eqlIgnoreCase(c, "checksum")) hasChecksum = true;
        }
        if (!hasName) {
            var alter = try connection.exec("ALTER TABLE _zig_migrations ADD COLUMN name TEXT NOT NULL DEFAULT '';");
            alter.deinit();
        }
        if (!hasChecksum) {
            var alter = try connection.exec("ALTER TABLE _zig_migrations ADD COLUMN checksum TEXT NOT NULL DEFAULT '';");
            alter.deinit();
        }
    }

    /// Load history rows ordered by version. `name` strings are owned dupes;
    /// the caller frees each plus the slice. Malformed version cells fail.
    fn loadApplied(self: Runner, connection: *Connection) ![]Applied {
        var result = try connection.exec("SELECT version, name, checksum FROM _zig_migrations ORDER BY version;");
        defer result.deinit();
        const out = try self.allocator.alloc(Applied, result.rows.len);
        errdefer self.allocator.free(out);
        for (result.rows, 0..) |row, i| {
            const version: u32 = switch (row[0]) {
                .integer => |v| @intCast(v),
                .real => |v| @intFromFloat(v),
                .null => return error.InvalidSql,
                else => return error.InvalidSql,
            };
            const name = switch (row[1]) {
                .text => |t| try self.allocator.dupe(u8, t),
                .null => try self.allocator.dupe(u8, ""),
                else => try self.allocator.dupe(u8, ""),
            };
            errdefer self.allocator.free(name);
            var checksum: u64 = 0;
            var hasChecksum = false;
            switch (row[2]) {
                .text => |t| {
                    if (t.len != 0) {
                        checksum = std.fmt.parseInt(u64, t, 16) catch 0;
                        hasChecksum = t.len != 0;
                    }
                },
                .integer => |v| {
                    checksum = @bitCast(v);
                    hasChecksum = true;
                },
                .null => {},
                else => {},
            }
            out[i] = .{ .version = version, .name = name, .checksum = checksum, .hasChecksum = hasChecksum };
        }
        return out;
    }

    /// Owned ascending copy of the defs. Fails `DuplicateMigration` on repeat
    /// versions. Caller frees the slice (structs only; strings stay borrowed).
    fn sortedMigrations(self: Runner) ![]Migration {
        const out = try self.allocator.alloc(Migration, self.migrations.len);
        errdefer self.allocator.free(out);
        @memcpy(out, self.migrations);
        std.mem.sort(Migration, out, {}, struct {
            fn lessThan(_: void, a: Migration, b: Migration) bool {
                return a.version < b.version;
            }
        }.lessThan);
        var i: usize = 1;
        while (i < out.len) : (i += 1) {
            if (out[i].version == out[i - 1].version) return error.DuplicateMigration;
        }
        return out;
    }

    fn findMigration(sorted: []const Migration, version: u32) ?Migration {
        for (sorted) |m| if (m.version == version) return m;
        return null;
    }

    fn isApplied(applied: []const Applied, version: u32) bool {
        for (applied) |a| if (a.version == version) return true;
        return false;
    }

    fn checksumText(self: Runner, sum: u64) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{x}", .{sum});
    }

    /// Escape a borrowed literal for `'…'` interpolation (single-quote doubling).
    /// Returned slice is owned; caller must free. Checksum/version need no
    /// escaping (hex/integer), but migration names are caller-controlled.
    fn escapeLiteral(self: Runner, raw: []const u8) ![]u8 {
        var count: usize = 0;
        for (raw) |b| {
            if (b == '\'') count += 1;
        }
        if (count == 0) return self.allocator.dupe(u8, raw);
        const out = try self.allocator.alloc(u8, raw.len + count);
        var w: usize = 0;
        for (raw) |b| {
            out[w] = b;
            w += 1;
            if (b == '\'') {
                out[w] = '\'';
                w += 1;
            }
        }
        return out;
    }

    /// True when the script's first real keyword is VACUUM (comments and
    /// empty statements skipped, case-insensitive). VACUUM bodies must run
    /// outside a transaction; see `applyOne`.
    fn isVacuumMigration(sql: []const u8) bool {
        var i: usize = 0;
        while (i < sql.len) {
            while (i < sql.len and (sql[i] == ' ' or sql[i] == '\t' or sql[i] == '\n' or sql[i] == '\r' or sql[i] == ';')) : (i += 1) {}
            if (i >= sql.len) break;
            if (i + 1 < sql.len and sql[i] == '-' and sql[i + 1] == '-') {
                while (i < sql.len and sql[i] != '\n') : (i += 1) {}
                continue;
            }
            var j = i;
            while (j < sql.len and (std.ascii.isAlphanumeric(sql[j]) or sql[j] == '_')) : (j += 1) {}
            if (j == i) {
                i += 1;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(sql[i..j], "VACUUM")) return true;
            // Skip to the next statement boundary.
            while (j < sql.len and sql[j] != ';') : (j += 1) {}
            i = j;
        }
        return false;
    }

    /// Apply one def plus its history row. Non-VACUUM bodies run in the
    /// caller's transaction when one is active, else in a fresh
    /// BEGIN IMMEDIATE..COMMIT that rolls back on any failure. VACUUM bodies
    /// run unwrapped and must be a single self-contained statement.
    /// TODO: route history INSERT/UPDATE through bound parameters instead of
    /// escaped literals once Connection exposes a parameterized exec path to
    /// this layer; escaping is correct but parameter binding would remove the
    /// class entirely.
    fn applyOne(self: Runner, connection: *Connection, m: Migration) !void {
        const sum = m.checksum();
        const sumText = try self.checksumText(sum);
        defer self.allocator.free(sumText);
        if (isVacuumMigration(m.upSql)) {
            // VACUUM must run outside a transaction and alone; the engine
            // rejects it inside BEGIN..COMMIT, so enforce self-containment.
            var count: usize = 0;
            var start: usize = 0;
            var idx: usize = 0;
            var quote: u8 = 0;
            while (idx < m.upSql.len) : (idx += 1) {
                const b = m.upSql[idx];
                if (quote != 0) {
                    if (b == quote) quote = 0;
                    continue;
                }
                if (b == '\'' or b == '"') {
                    quote = b;
                    continue;
                }
                if (b == ';') {
                    if (std.mem.trim(u8, m.upSql[start..idx], " \t\r\n").len != 0) count += 1;
                    start = idx + 1;
                }
            }
            if (std.mem.trim(u8, m.upSql[start..], " \t\r\n").len != 0) count += 1;
            if (count != 1) return error.InvalidSql;
            var body = try connection.exec(m.upSql);
            body.deinit();
            const safeName = try self.escapeLiteral(m.name);
            defer self.allocator.free(safeName);
            const record = try std.fmt.allocPrint(
                self.allocator,
                "INSERT INTO _zig_migrations (version, name, checksum) VALUES ({d}, '{s}', '{s}');",
                .{ m.version, safeName, sumText },
            );
            defer self.allocator.free(record);
            var recorded = try connection.exec(record);
            recorded.deinit();
            return;
        }
        const wasActive = connection.transactionActive;
        if (!wasActive) try connection.beginImmediate();
        errdefer {
            if (!wasActive) connection.rollback() catch {};
        }
        var body = try connection.exec(m.upSql);
        body.deinit();
        // History advances only after the body succeeded.
        const safeName = try self.escapeLiteral(m.name);
        defer self.allocator.free(safeName);
        const record = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO _zig_migrations (version, name, checksum) VALUES ({d}, '{s}', '{s}');",
            .{ m.version, safeName, sumText },
        );
        defer self.allocator.free(record);
        var recorded = try connection.exec(record);
        recorded.deinit();
        if (!wasActive) try connection.commit();
    }

    /// Apply all pending migrations in ascending version order. Returns the
    /// highest applied version (0 when the set is empty). Validates every
    /// applied row against the supplied defs first, backfilling legacy rows.
    /// Each migration commits atomically (unless the caller holds the
    /// transaction, in which case the caller owns commit/rollback).
    pub fn apply(self: Runner, connection: *Connection) !u32 {
        try ensureHistoryTable(connection);
        const sorted = try self.sortedMigrations();
        defer self.allocator.free(sorted);
        const applied = try self.loadApplied(connection);
        defer {
            for (applied) |a| self.allocator.free(a.name);
            self.allocator.free(applied);
        }

        // Supplied history must explain every applied row.
        for (applied) |a| {
            const def = findMigration(sorted, a.version) orelse return error.MissingMigration;
            if (a.hasChecksum) {
                if (!std.mem.eql(u8, a.name, def.name) or a.checksum != def.checksum()) return error.ModifiedMigration;
            } else {
                // Legacy rows predate checksums: backfill after name check.
                if (a.name.len != 0 and !std.mem.eql(u8, a.name, def.name)) return error.ModifiedMigration;
                const sumText = try self.checksumText(def.checksum());
                defer self.allocator.free(sumText);
                const safeName = try self.escapeLiteral(def.name);
                defer self.allocator.free(safeName);
                const backfill = try std.fmt.allocPrint(
                    self.allocator,
                    "UPDATE _zig_migrations SET name = '{s}', checksum = '{s}' WHERE version = {d};",
                    .{ safeName, sumText, def.version },
                );
                defer self.allocator.free(backfill);
                var done = try connection.exec(backfill);
                done.deinit();
            }
        }

        var maxApplied: u32 = 0;
        for (applied) |a| maxApplied = @max(maxApplied, a.version);

        if (sorted.len != 0 and maxApplied != 0) {
            // e.g. history peaks at 5 but the set starts at 7: version 6 is
            // missing — fail loudly instead of skipping.
            if (sorted[0].version > maxApplied + 1) return error.MissingMigration;
            for (sorted) |m| {
                if (m.version <= maxApplied and !isApplied(applied, m.version)) return error.MissingMigration;
            }
        }

        var top: u32 = maxApplied;
        for (sorted) |m| {
            if (isApplied(applied, m.version)) {
                top = @max(top, m.version);
                continue;
            }
            // Never apply a migration below the history peak that was not
            // previously applied (reordered set).
            if (m.version < top) return error.MissingMigration;
            try self.applyOne(connection, m);
            top = @max(top, m.version);
        }
        return top;
    }

    /// Roll back the single newest applied migration via its `downSql` and
    /// delete its history row atomically. Returns the rolled-back version.
    /// Fails `NoMigrationsApplied` when empty, `NoDownMigration` when the def
    /// has no down SQL, and `ModifiedMigration` on checksum drift.
    pub fn rollback(self: Runner, connection: *Connection) !u32 {
        try ensureHistoryTable(connection);
        const sorted = try self.sortedMigrations();
        defer self.allocator.free(sorted);
        const applied = try self.loadApplied(connection);
        defer {
            for (applied) |a| self.allocator.free(a.name);
            self.allocator.free(applied);
        }
        if (applied.len == 0) return error.NoMigrationsApplied;
        var newest = applied[0];
        for (applied[1..]) |a| {
            if (a.version > newest.version) newest = a;
        }
        const def = findMigration(sorted, newest.version) orelse return error.MissingMigration;
        if (def.downSql.len == 0) return error.NoDownMigration;
        if (def.checksum() != newest.checksum and newest.hasChecksum) return error.ModifiedMigration;

        const wasActive = connection.transactionActive;
        if (!wasActive) try connection.beginImmediate();
        errdefer {
            if (!wasActive) connection.rollback() catch {};
        }
        var body = try connection.exec(def.downSql);
        body.deinit();
        const remove = try std.fmt.allocPrint(
            self.allocator,
            "DELETE FROM _zig_migrations WHERE version = {d};",
            .{def.version},
        );
        defer self.allocator.free(remove);
        var removed = try connection.exec(remove);
        removed.deinit();
        if (!wasActive) try connection.commit();
        return def.version;
    }
};

test "migration runner records applied versions and rolls back once" {
    const path = "sqlite_zig_migration_runner_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    const migrations = [_]Migration{
        .{ .version = 1, .name = "create items", .upSql = "CREATE TABLE migrated_items (id INTEGER);", .downSql = "DROP TABLE migrated_items;" },
    };
    const runner = Runner.init(std.testing.allocator, &migrations);
    try std.testing.expectEqual(@as(u32, 1), try runner.apply(db));
    try std.testing.expectEqual(@as(u32, 1), try runner.apply(db));
    try std.testing.expectEqual(@as(u32, 1), try runner.rollback(db));
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT * FROM migrated_items;"));
}

test "migration runner rejects duplicates gaps and edits" {
    const path = "sqlite_zig_migration_order_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();

    const dupes = [_]Migration{
        .{ .version = 1, .name = "a", .upSql = "CREATE TABLE dup_a (id INTEGER);" },
        .{ .version = 1, .name = "b", .upSql = "CREATE TABLE dup_b (id INTEGER);" },
    };
    try std.testing.expectError(error.DuplicateMigration, (Runner.init(std.testing.allocator, &dupes)).apply(db));

    const first = [_]Migration{
        .{ .version = 1, .name = "one", .upSql = "CREATE TABLE gap_one (id INTEGER);" },
    };
    try std.testing.expectEqual(@as(u32, 1), try (Runner.init(std.testing.allocator, &first)).apply(db));

    // History peaks at 1; a set starting at 3 skips 2.
    const gapped = [_]Migration{
        .{ .version = 3, .name = "three", .upSql = "CREATE TABLE gap_three (id INTEGER);" },
    };
    try std.testing.expectError(error.MissingMigration, (Runner.init(std.testing.allocator, &gapped)).apply(db));

    // Editing an applied migration is detected via the checksum.
    const edited = [_]Migration{
        .{ .version = 1, .name = "one", .upSql = "CREATE TABLE gap_one (id TEXT);" },
    };
    try std.testing.expectError(error.ModifiedMigration, (Runner.init(std.testing.allocator, &edited)).apply(db));

    // Rollback without an explicit down migration is refused.
    const noDown = [_]Migration{
        .{ .version = 1, .name = "one", .upSql = "CREATE TABLE gap_one (id INTEGER);" },
    };
    try std.testing.expectError(error.NoDownMigration, (Runner.init(std.testing.allocator, &noDown)).rollback(db));
}

test "failed migration leaves history and schema unchanged" {
    const path = "sqlite_zig_migration_failure_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    const migrations = [_]Migration{
        .{ .version = 1, .name = "good", .upSql = "CREATE TABLE mig_ok (id INTEGER);" },
        .{ .version = 2, .name = "bad", .upSql = "CREATE TABLE mig_bad (id INTEGER); INVALID SQL HERE" },
    };
    const runner = Runner.init(std.testing.allocator, &migrations);
    try std.testing.expectError(error.InvalidSql, runner.apply(db));
    // Version 1 committed, version 2 did not advance the history.
    var history = try db.exec("SELECT version FROM _zig_migrations ORDER BY version;");
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 1), history.count());
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT * FROM mig_bad;"));
    // Retrying after fixing the statement applies cleanly (idempotent).
    const fixed = [_]Migration{
        .{ .version = 1, .name = "good", .upSql = "CREATE TABLE mig_ok (id INTEGER);" },
        .{ .version = 2, .name = "bad", .upSql = "CREATE TABLE mig_bad (id INTEGER);" },
    };
    try std.testing.expectEqual(@as(u32, 2), try (Runner.init(std.testing.allocator, &fixed)).apply(db));
}

test "migrations apply in version order regardless of input order" {
    const path = "sqlite_zig_migration_sort_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    const migrations = [_]Migration{
        .{ .version = 3, .name = "three", .upSql = "CREATE TABLE mig_s3 (id INTEGER);" },
        .{ .version = 1, .name = "one", .upSql = "CREATE TABLE mig_s1 (id INTEGER);" },
        .{ .version = 2, .name = "two", .upSql = "CREATE TABLE mig_s2 (id INTEGER);" },
    };
    try std.testing.expectEqual(@as(u32, 3), try (Runner.init(std.testing.allocator, &migrations)).apply(db));
    var history = try db.exec("SELECT version FROM _zig_migrations ORDER BY version;");
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 3), history.count());
}

test "quoted migration names round-trip through history" {
    const path = "sqlite_zig_migration_quote_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    // A single quote in the name must not break the history INSERT (escaped
    // by doubling) nor trip the ModifiedMigration check on re-apply.
    const migrations = [_]Migration{
        .{ .version = 1, .name = "o'brien", .upSql = "CREATE TABLE mig_q (id INTEGER);", .downSql = "DROP TABLE mig_q;" },
    };
    const runner = Runner.init(std.testing.allocator, &migrations);
    try std.testing.expectEqual(@as(u32, 1), try runner.apply(db));
    try std.testing.expectEqual(@as(u32, 1), try runner.apply(db));
    var names = try db.exec("SELECT name FROM _zig_migrations;");
    defer names.deinit();
    try std.testing.expectEqual(@as(usize, 1), names.count());
    try std.testing.expectEqualStrings("o'brien", names.rows[0][0].text);
    try std.testing.expectEqual(@as(u32, 1), try runner.rollback(db));
}
