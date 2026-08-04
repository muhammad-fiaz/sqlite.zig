const std = @import("std");
const sqlite = @import("sqlite");

const UserRow = struct { id: i64, name: []const u8, active: i64 };
const User = sqlite.table("cte_users", UserRow);
const Active = sqlite.table("active_cte", UserRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_24.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key = User.key("id") });
    try db.truncate(User);
    var one = try db.from(User).insertTyped(.{ .id = 1, .name = "Alice", .active = 1 });
    one.deinit();
    var two = try db.from(User).insertTyped(.{ .id = 2, .name = "Bob", .active = 0 });
    two.deinit();

    var raw = try db.exec("WITH active_cte AS (SELECT id, name, active FROM cte_users WHERE active = 1) SELECT * FROM active_cte;");
    defer raw.deinit();
    try db.createView("active_cte", "SELECT id, name, active FROM cte_users WHERE active = 1");
    defer db.dropView("active_cte") catch {};
    var typed = try db.from(Active).selectAll().fetchAll();
    defer typed.deinit();
    if (raw.rowCount() != 1 or typed.rowCount() != 1 or typed.rows[0][0].integer != 1) return error.CteVerificationFailed;
    std.debug.print("24 CTE: raw materialization and typed read verified\n", .{});
}
