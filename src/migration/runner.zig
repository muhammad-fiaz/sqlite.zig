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
        var applied: u32 = 0;
        for (self.migrations) |migration| {
            var result = try connection.exec(migration.up_sql);
            result.deinit();
            applied = @max(applied, migration.version);
        }
        return applied;
    }

    pub fn rollback(self: Runner, connection: *Connection) !u32 {
        var rolled_back: u32 = 0;
        var index = self.migrations.len;
        while (index > 0) {
            index -= 1;
            const migration = self.migrations[index];
            if (migration.down_sql.len == 0) continue;
            var result = try connection.exec(migration.down_sql);
            result.deinit();
            rolled_back = migration.version;
            break;
        }
        return rolled_back;
    }
};
