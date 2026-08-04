const std = @import("std");
const sqlite = @import("sqlite");

const UserRow = struct { id: i64, name: []const u8 };
const OrderRow = struct { id: i64, user_id: i64 };
const User = sqlite.table("subquery_users", UserRow);
const Order = sqlite.table("subquery_orders", OrderRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_25.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key = User.key("id") });
    try db.createTable(Order, .{ .if_not_exists = true, .primary_key = Order.key("id") });
    try db.truncate(User);
    try db.truncate(Order);
    var alice = try db.from(User).insertTyped(.{ .id = 1, .name = "Alice" });
    alice.deinit();
    var bob = try db.from(User).insertTyped(.{ .id = 2, .name = "Bob" });
    bob.deinit();
    var order = try db.from(Order).insertTyped(.{ .id = 10, .user_id = 1 });
    order.deinit();

    var raw = try db.exec("SELECT id, name FROM subquery_users WHERE id IN (SELECT user_id FROM subquery_orders);");
    defer raw.deinit();
    var typed = try db.from(User).whereInColumn(User.key("id"), Order, Order.key("user_id")).selectColumns(&.{ User.key("id"), User.key("name") }).fetchAll();
    defer typed.deinit();
    if (raw.rowCount() != 1 or typed.rowCount() != 1 or typed.rows[0][0].integer != 1) return error.SubqueryVerificationFailed;
    std.debug.print("25 subqueries: raw IN SELECT and typed whereInColumn verified\n", .{});
}
