const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_02.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT);");
    setup.deinit();
    var statement = try db.prepare("INSERT INTO users VALUES (?, ?);");
    defer statement.finalize();
    try statement.bind(1, 1);
    try statement.bind(2, "Fiaz");
    try statement.step();
    std.debug.print("02 prepared statement: parameterized insert completed\n", .{});
}
