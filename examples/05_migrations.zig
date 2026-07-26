const std = @import("std");
const sqlite = @import("sqlite_zig");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_05.db");
    defer db.close();
    const migrations = [_]sqlite.migration.Migration{
        .{ .version = 1, .up_sql = "CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT);", .down_sql = "DROP TABLE users;" },
    };
    var runner = sqlite.migration.Runner.init(std.heap.page_allocator, &migrations);
    _ = try runner.apply(db);
}
