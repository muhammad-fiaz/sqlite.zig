const std = @import("std");
const sqlite = @import("sqlite");

const CustomerRow = struct { id: i64, email: []const u8, name: []const u8 };
const Customer = sqlite.table("indexed_customers", CustomerRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_21.db");
    defer db.close();
    try db.createTable(Customer, .{ .ifNotExists = true, .primaryKey = Customer.columns.id });
    try db.truncate(Customer);
    db.dropIndex("indexed_customers_email") catch {};
    db.dropIndex("indexed_customers_name") catch {};
    var first = try db.from(Customer).insert(.{ .id = 1, .email = "one@example.test", .name = "One" });
    first.deinit();

    try db.createIndex(Customer, "indexed_customers_email", &.{Customer.columns.email}, true);
    try std.testing.expectError(error.ConstraintViolation, db.from(Customer).insert(.{ .id = 2, .email = "one@example.test", .name = "Duplicate" }));

    var rawIndex = try db.exec("CREATE INDEX indexed_customers_name ON indexed_customers (name);");
    rawIndex.deinit();
    var rows = try db.from(Customer).select(&.{ Customer.columns.id, Customer.columns.email }).fetch();
    defer rows.deinit();
    if (rows.rowCount() != 1) return error.IndexedQueryVerificationFailed;
    std.debug.print("21 indexes: typed unique and raw non-unique indexes verified\n", .{});
}
