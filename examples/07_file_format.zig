//! On-disk page format verified with close and reopen.
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_07.db");
    defer db.close();
    try db.createTable(User, .{ .overWrite = true, .primaryKey = User.id });
    var inserted = try db.from(User).insert(.{ .id = 7, .name = "Compat" });
    inserted.deinit();
    var check = try db.exec("PRAGMA integrity_check;");
    defer check.deinit();
    if (check.count() != 1 or !std.mem.eql(u8, check.at(0)[0].text, "ok")) return error.FormatMismatch;
    db.close();
    db = try sqlite.open(std.heap.page_allocator, "example_07.db");
    var result = try db.exec("SELECT name FROM users WHERE id = 7;");
    defer result.deinit();
    if (result.count() != 1 or !std.mem.eql(u8, result.at(0)[0].text, "Compat")) return error.FormatMismatch;
    std.debug.print("07 file format: on-disk image verified with reopen\n", .{});
}
