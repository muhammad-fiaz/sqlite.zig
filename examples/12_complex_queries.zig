const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("complex_users", struct { id: i64, name: []const u8 });
const Order = sqlite.table("complex_orders", struct { id: i64, user_id: i64, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_12.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key_key = User.key("id") });
    try db.createTable(Order, .{ .if_not_exists = true, .primary_key_key = Order.key("id") });
    try db.truncate(Order);
    try db.truncate(User);

    var user_a = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    user_a.deinit();
    var user_b = try db.from(User).insert(.{ .id = 2, .name = "Bob" });
    user_b.deinit();
    var order_a = try db.from(Order).insert(.{ .id = 10, .user_id = 1, .amount = 25 });
    order_a.deinit();
    var order_b = try db.from(Order).insert(.{ .id = 11, .user_id = 1, .amount = 75 });
    order_b.deinit();
    var order_c = try db.from(Order).insert(.{ .id = 12, .user_id = 2, .amount = 10 });
    order_c.deinit();

    var raw = try db.exec("SELECT DISTINCT * FROM complex_users INNER JOIN complex_orders ON complex_users.id = complex_orders.user_id;");
    raw.deinit();
    var dsl = try db.from(User).innerJoin(Order, "id", "user_id").select("*").distinct().fetchAll();
    dsl.deinit();
    var aggregate = try db.from(Order).sum("amount").fetchAll();
    aggregate.deinit();
}
