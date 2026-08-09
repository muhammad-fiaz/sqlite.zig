const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_47.db");
    defer db.close();
    var result = try db.exec("DROP TABLE IF EXISTS default_demo; CREATE TABLE default_demo (id INTEGER, label TEXT DEFAULT 'untitled', enabled INTEGER DEFAULT 1); INSERT INTO default_demo (id) VALUES (1); INSERT INTO default_demo DEFAULT VALUES;");
    result.deinit();
    var rows = try db.exec("SELECT label, enabled FROM default_demo ORDER BY id;");
    defer rows.deinit();
    if (rows.rowCount() != 2 or !std.mem.eql(u8, rows.rows[0][0].text, "untitled") or rows.rows[1][1].integer != 1) return error.DefaultVerificationFailed;
    std.debug.print("47 column defaults: omitted columns and DEFAULT VALUES verified\n", .{});
}
