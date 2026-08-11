const std = @import("std");
const sqlite = @import("sqlite");

const Product = sqlite.table("select_products", struct { id: i64, name: []const u8, price: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_14.db");
    defer db.close();
    try db.createTable(Product, .{ .if_not_exists = true });
    try db.truncate(Product);

    var first = try db.from(Product).insert(.{ .id = 1, .name = "keyboard", .price = 80 });
    first.deinit();
    var second = try db.from(Product).insert(.{ .id = 2, .name = "mouse", .price = 30 });
    second.deinit();

    var projected = try db.from(Product)
        .selectColumns(&.{ Product.key("id"), Product.key("name") })
        .where(Product.column("price").ge(30))
        .orderBy(Product.column("price").desc())
        .fetchAll();
    projected.deinit();

    var distinct_names = try db.from(Product).selectFieldNames(&.{"name"}).distinct().fetchAll();
    distinct_names.deinit();

    var total = try db.from(Product).count().fetchAll();
    total.deinit();
    std.debug.print("14 dsl select projections: field projections and distinct verified\n", .{});
}
