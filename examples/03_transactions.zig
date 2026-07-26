const std = @import("std");
const sqlite = @import("sqlite_zig");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_03.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS ledger (id INTEGER, amount INTEGER);");
    setup.deinit();
    var begin = try db.exec("BEGIN;");
    begin.deinit();
    var insert = try db.exec("INSERT INTO ledger VALUES (1, 100);");
    insert.deinit();
    var rollback = try db.exec("ROLLBACK;");
    rollback.deinit();
}
