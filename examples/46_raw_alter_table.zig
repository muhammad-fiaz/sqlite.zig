const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_46.db");
    defer db.close();
    var result = try db.exec("DROP TABLE IF EXISTS altered_demo; DROP TABLE IF EXISTS alter_demo; CREATE TABLE alter_demo (id INTEGER, label TEXT); INSERT INTO alter_demo VALUES (1, 'before'); ALTER TABLE alter_demo ADD COLUMN enabled INTEGER; ALTER TABLE alter_demo RENAME COLUMN label TO name; ALTER TABLE alter_demo DROP COLUMN enabled; ALTER TABLE alter_demo RENAME TO altered_demo;");
    result.deinit();
    var rows = try db.exec("SELECT id, name FROM altered_demo;");
    defer rows.deinit();
    if (rows.rowCount() != 1 or !std.mem.eql(u8, rows.rows[0][1].text, "before")) return error.AlterVerificationFailed;
    std.debug.print("46 ALTER TABLE: add, rename, drop, and table rename verified\n", .{});
}
