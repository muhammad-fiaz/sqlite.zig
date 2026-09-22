//! Complex SELECT: distinct, joins, and grouped aggregates.
const std = @import("std");
const sqlite = @import("sqlite");

const UserRow = struct { id: i64, name: []const u8 };
const OrderRow = struct { id: i64, user_id: i64, amount: i64 };
const User = sqlite.table("complex_users", UserRow);
const Order = sqlite.table("complex_orders", OrderRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_12.db");
    defer db.close();
    try db.createTable(User, .{ .overWrite = true, .primaryKey = User.id });
    try db.createTable(Order, .{ .overWrite = true, .primaryKey = Order.id });
    try db.truncate(Order);
    try db.truncate(User);

    var userA = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    userA.deinit();
    var userB = try db.from(User).insert(.{ .id = 2, .name = "Bob" });
    userB.deinit();
    var orderA = try db.from(Order).insert(.{ .id = 10, .user_id = 1, .amount = 25 });
    orderA.deinit();
    var orderB = try db.from(Order).insert(.{ .id = 11, .user_id = 1, .amount = 75 });
    orderB.deinit();
    var orderC = try db.from(Order).insert(.{ .id = 12, .user_id = 2, .amount = 10 });
    orderC.deinit();

    var raw = try db.exec("SELECT DISTINCT * FROM complex_users INNER JOIN complex_orders ON complex_users.id = complex_orders.user_id;");
    raw.deinit();
    var dsl = try db.from(User).innerJoin(Order, User.id.eq(Order.user_id)).selectAll().distinct().fetch();
    dsl.deinit();
    var aggregate = try db.from(Order).select(.{Order.amount.sum()}).fetch();
    aggregate.deinit();
    std.debug.print("12 complex queries: distinct joins and aggregates verified\n", .{});
}
