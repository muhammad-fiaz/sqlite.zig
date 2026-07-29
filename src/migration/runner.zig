const std = @import("std");
const Migration = @import("migration.zig").Migration;
const Connection = @import("../connection/connection.zig").Connection;

pub const Runner = struct {
    allocator: std.mem.Allocator,
    migrations: []const Migration,

    pub fn init(allocator: std.mem.Allocator, migrations: []const Migration) Runner {
        return .{ .allocator = allocator, .migrations = migrations };
    }

    pub fn apply(self: Runner, connection: *Connection) !u32 {
        var setup = try connection.exec("CREATE TABLE IF NOT EXISTS _zig_migrations (version INTEGER PRIMARY KEY);");
        setup.deinit();
        var applied: u32 = 0;
        for (self.migrations) |migration| {
            const check = try std.fmt.allocPrint(self.allocator, "SELECT version FROM _zig_migrations WHERE version = {d};", .{migration.version});
            defer self.allocator.free(check);
            var existing = try connection.exec(check);
            const already_applied = existing.rowCount() != 0;
            existing.deinit();
            if (already_applied) {
                applied = @max(applied, migration.version);
                continue;
            }
            var result = try connection.exec(migration.up_sql);
            result.deinit();
            const record = try std.fmt.allocPrint(self.allocator, "INSERT INTO _zig_migrations VALUES ({d});", .{migration.version});
            defer self.allocator.free(record);
            var recorded = try connection.exec(record);
            recorded.deinit();
            applied = @max(applied, migration.version);
        }
        return applied;
    }

    pub fn rollback(self: Runner, connection: *Connection) !u32 {
        var setup = try connection.exec("CREATE TABLE IF NOT EXISTS _zig_migrations (version INTEGER PRIMARY KEY);");
        setup.deinit();
        var rolled_back: u32 = 0;
        var index = self.migrations.len;
        while (index > 0) {
            index -= 1;
            const migration = self.migrations[index];
            if (migration.down_sql.len == 0) continue;
            const check = try std.fmt.allocPrint(self.allocator, "SELECT version FROM _zig_migrations WHERE version = {d};", .{migration.version});
            defer self.allocator.free(check);
            var existing = try connection.exec(check);
            const is_applied = existing.rowCount() != 0;
            existing.deinit();
            if (!is_applied) continue;
            var result = try connection.exec(migration.down_sql);
            result.deinit();
            const remove = try std.fmt.allocPrint(self.allocator, "DELETE FROM _zig_migrations WHERE version = {d};", .{migration.version});
            defer self.allocator.free(remove);
            var removed = try connection.exec(remove);
            removed.deinit();
            rolled_back = migration.version;
            break;
        }
        return rolled_back;
    }
};

test "migration runner records applied versions and rolls back once" {
    const path = "sqlite_zig_migration_runner_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    const migrations = [_]Migration{
        .{ .version = 1, .up_sql = "CREATE TABLE migrated_items (id INTEGER);", .down_sql = "DROP TABLE migrated_items;" },
    };
    const runner = Runner.init(std.testing.allocator, &migrations);
    try std.testing.expectEqual(@as(u32, 1), try runner.apply(&db));
    try std.testing.expectEqual(@as(u32, 1), try runner.apply(&db));
    try std.testing.expectEqual(@as(u32, 1), try runner.rollback(&db));
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT * FROM migrated_items;"));
}
