//! Typed DSL intro: where, orderBy, and limit on a typed table.
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_04.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT); DELETE FROM users;");
    setup.deinit();
    var insert = try db.exec("INSERT INTO users VALUES (1, 'Fiaz'), (2, 'Ada');");
    insert.deinit();
    var rows = try db.from(User).where(User.id.gt(0)).orderBy(User.id.asc()).limit(10).fetch();
    defer rows.deinit();
    if (rows.count() != 2) return error.VerificationFailed;
    std.debug.print("04 dsl query builder: {d} row(s) fetched\n", .{rows.count()});
}
