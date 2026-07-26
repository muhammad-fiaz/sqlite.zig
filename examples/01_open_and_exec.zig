const std = @import("std");
const sqlite = @import("sqlite_zig");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_01.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO users VALUES (1, 'Fiaz');");
    result.deinit();
}
