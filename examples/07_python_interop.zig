const std = @import("std");
const sqlite = @import("sqlite_zig");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "python_interop.db");
    defer db.close();
    var result = try db.exec("SELECT name FROM users WHERE id = 7;");
    defer result.deinit();
    if (result.rowCount() != 1 or !std.mem.eql(u8, result.rows[0][0].text, "Python")) return error.InteropMismatch;
}
