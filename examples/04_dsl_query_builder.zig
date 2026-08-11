const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_04.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT);");
    setup.deinit();
    var insert = try db.exec("INSERT INTO users VALUES (1, 'Fiaz');");
    insert.deinit();
    var rows = try db.from(User).where(User.column("id").gt(0)).fetchAll();
    defer rows.deinit();
    std.debug.print("04 dsl query builder: {d} row(s) fetched\n", .{rows.rowCount()});
}
