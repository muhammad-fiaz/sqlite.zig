const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("relation_users", struct { id: i64, email: []const u8 });
const Order = sqlite.table("relation_orders", struct { id: i64, user_id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_11.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key = User.key("id"), .unique_keys = &.{User.key("email")} });
    try db.createTable(Order, .{ .if_not_exists = true, .primary_key = Order.key("id"), .foreign_keys = &.{.{ .table = "relation_users", .referenced_column = "id", .column_key = Order.key("user_id") }} });
    try db.truncate(Order);
    try db.truncate(User);

    var user = try db.from(User).insert(.{ .id = 1, .email = "user@example.test" });
    user.deinit();
    var order = try db.from(Order).insert(.{ .id = 1, .user_id = 1 });
    order.deinit();

    var inner = try db.from(User).innerJoin(Order, "id", "user_id").fetchAll();
    inner.deinit();
    var left = try db.from(User).leftJoin(Order, "id", "user_id").fetchAll();
    left.deinit();
    var raw = try db.exec("SELECT * FROM relation_users JOIN relation_orders ON relation_users.id = relation_orders.user_id;");
    raw.deinit();
}
