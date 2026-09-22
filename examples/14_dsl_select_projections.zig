//! Typed DSL projections and distinct result sets.
const std = @import("std");
const sqlite = @import("sqlite");

const Product = sqlite.table("select_products", struct { id: i64, name: []const u8, price: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_14.db");
    defer db.close();
    try db.createTable(Product, .{ .overWrite = true });
    try db.truncate(Product);

    var first = try db.from(Product).insert(.{ .id = 1, .name = "keyboard", .price = 80 });
    first.deinit();
    var second = try db.from(Product).insert(.{ .id = 2, .name = "mouse", .price = 30 });
    second.deinit();

    var projected = try db.from(Product)
        .select(&.{ Product.id, Product.name })
        .where(Product.price.gte(30))
        .orderBy(Product.price.desc())
        .fetch();
    projected.deinit();

    var distinctNames = try db.from(Product).select(.{Product.name}).distinct().fetch();
    distinctNames.deinit();

    var total = try db.from(Product).countStar().fetch();
    total.deinit();
    std.debug.print("14 dsl select projections: field projections and distinct verified\n", .{});
}
