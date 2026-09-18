const std = @import("std");
const sqlite = @import("sqlite");

const UserRow = struct { id: i64, name: []const u8 };
const OrderRow = struct { id: i64, user_id: i64 };
const User = sqlite.table("subquery_users", UserRow);
const Order = sqlite.table("subquery_orders", OrderRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_25.db");
    defer db.close();
    try db.createTable(User, .{ .ifNotExists = true, .primaryKey = User.columns.id });
    try db.createTable(Order, .{ .ifNotExists = true, .primaryKey = Order.columns.id });
    try db.truncate(User);
    try db.truncate(Order);
    var alice = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    alice.deinit();
    var bob = try db.from(User).insert(.{ .id = 2, .name = "Bob" });
    bob.deinit();
    var order = try db.from(Order).insert(.{ .id = 10, .user_id = 1 });
    order.deinit();

    var raw = try db.exec("SELECT id, name FROM subquery_users WHERE id IN (SELECT user_id FROM subquery_orders);");
    defer raw.deinit();
    var typed = try db.from(User).whereInQuery(User.columns.id, Order, Order.columns.user_id).select(&.{ User.columns.id, User.columns.name }).fetch();
    defer typed.deinit();
    if (raw.rowCount() != 1 or typed.rowCount() != 1 or typed.rows[0][0].integer != 1) return error.SubqueryVerificationFailed;
    std.debug.print("25 subqueries: raw IN SELECT and typed whereInQuery verified\n", .{});
}
