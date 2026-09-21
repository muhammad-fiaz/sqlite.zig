//! Versioned SQL migrations.
//!
//! `Migration` and `Set` borrow their strings; `Set` owns only its list.
//! `add` fails only on out of memory.

const std = @import("std");

/// One versioned transition. `version` orders application; `name` is a human
/// label covered by the checksum; `upSql` applies, `downSql` rolls back (empty
/// means "no down migration"). All slices borrowed.
pub const Migration = struct {
    version: u32,
    name: []const u8 = "",
    upSql: []const u8,
    downSql: []const u8 = "",

    /// Wyhash fingerprint over `name`, `upSql`, `downSql` (NUL-separated).
    /// Used by `Runner` to detect post-apply edits. Deterministic, never fails.
    pub fn checksum(self: Migration) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(self.name);
        h.update(&.{0});
        h.update(self.upSql);
        h.update(&.{0});
        h.update(self.downSql);
        return h.final();
    }
};

/// Ordered collection of borrowed `Migration` values. Backed by an
/// `ArrayList`; `deinit` frees only the list, never the strings.
pub const Set = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Migration),

    /// Borrow the allocator for the list backing. Owns no migration bytes.
    pub fn init(allocator: std.mem.Allocator) Set {
        return .{ .allocator = allocator, .items = .empty };
    }
    /// Release the list backing only. Migration strings stay caller-owned.
    pub fn deinit(self: *Set) void {
        self.items.deinit(self.allocator);
    }
    /// Append a borrowed `Migration` (struct copy; bytes stay borrowed).
    /// Fails only on allocation failure. Order is caller-controlled; `Runner`
    /// sorts by version and rejects duplicates.
    pub fn add(self: *Set, migration: Migration) !void {
        try self.items.append(self.allocator, migration);
    }
};

test "migration set stores ordered definitions" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    try set.add(.{ .version = 1, .name = "init", .upSql = "CREATE TABLE t (id INTEGER);" });
    try std.testing.expectEqual(@as(u32, 1), set.items.items[0].version);
    try std.testing.expectEqualStrings("init", set.items.items[0].name);
}

test "migration checksum distinguishes edited statements" {
    const a = Migration{ .version = 1, .name = "init", .upSql = "CREATE TABLE t (id INTEGER);" };
    const b = Migration{ .version = 1, .name = "init", .upSql = "CREATE TABLE t (id TEXT);" };
    try std.testing.expect(a.checksum() != b.checksum());
    const c = Migration{ .version = 1, .name = "init", .upSql = "CREATE TABLE t (id INTEGER);" };
    try std.testing.expectEqual(a.checksum(), c.checksum());
}

test "migration set borrows definitions without copying bytes" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    try set.add(.{ .version = 2, .name = "second", .upSql = "CREATE TABLE b (id INTEGER);", .downSql = "DROP TABLE b;" });
    try set.add(.{ .version = 1, .name = "first", .upSql = "CREATE TABLE a (id INTEGER);" });
    // Insertion order preserved here; Runner sorts by version at apply time.
    try std.testing.expectEqual(@as(usize, 2), set.items.items.len);
    try std.testing.expectEqual(@as(u32, 2), set.items.items[0].version);
    try std.testing.expectEqualStrings("DROP TABLE b;", set.items.items[0].downSql);
    // Checksum covers the down migration too: editing it changes identity.
    const withDown = Migration{ .version = 2, .name = "second", .upSql = "CREATE TABLE b (id INTEGER);", .downSql = "DROP TABLE b;" };
    const withoutDown = Migration{ .version = 2, .name = "second", .upSql = "CREATE TABLE b (id INTEGER);" };
    try std.testing.expect(withDown.checksum() != withoutDown.checksum());
    try std.testing.expectEqual(withDown.checksum(), set.items.items[0].checksum());
}
