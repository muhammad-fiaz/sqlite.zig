const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "python_interop.db");
    defer db.close();
    if (!db.tableExists(User)) {
        try db.createTable(User, .{ .if_not_exists = true, .primary_key = "id" });
    }
    var result = try db.exec("SELECT name FROM users WHERE id = 7;");
    if (result.rowCount() == 0) {
        result.deinit();
        var inserted = try db.from(User).insert(.{ .id = 7, .name = "Python" });
        inserted.deinit();
        result = try db.exec("SELECT name FROM users WHERE id = 7;");
    }
    defer result.deinit();
    if (result.rowCount() != 1 or !std.mem.eql(u8, result.rows[0][0].text, "Python")) return error.InteropMismatch;
}
