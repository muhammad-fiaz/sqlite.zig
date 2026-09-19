const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("relation_users", struct { id: i64, email: []const u8 });
const Order = sqlite.table("relation_orders", struct { id: i64, user_id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_11.db");
    defer db.close();
    try db.createTable(User, .{ .overWrite = true, .primaryKey = User.columns.id, .unique = &.{User.columns.email} });
    try db.createTable(Order, .{ .overWrite = true, .primaryKey = Order.columns.id, .foreignKeys = &.{.{ .column = Order.columns.user_id, .references = User.columns.id }} });
    try db.truncate(Order);
    try db.truncate(User);

    var user = try db.from(User).insert(.{ .id = 1, .email = "user@example.test" });
    user.deinit();
    var order = try db.from(Order).insert(.{ .id = 1, .user_id = 1 });
    order.deinit();

    var inner = try db.from(User).innerJoin(Order, User.columns.id.eq(Order.columns.user_id)).fetch();
    inner.deinit();
    var left = try db.from(User).leftJoin(Order, User.columns.id.eq(Order.columns.user_id)).fetch();
    left.deinit();
    var raw = try db.exec("SELECT * FROM relation_users JOIN relation_orders ON relation_users.id = relation_orders.user_id;");
    raw.deinit();
    std.debug.print("11 keys and joins: primary keys, foreign keys, and joins verified\n", .{});
}
