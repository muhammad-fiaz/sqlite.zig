const std = @import("std");
const sqlite = @import("sqlite");

const Sale = sqlite.table("grouped_sales", struct { category: []const u8, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_36.db");
    defer db.close();
    try db.createTable(Sale, .{ .if_not_exists = true });
    try db.truncate(Sale);
    inline for (.{ .{ "hardware", @as(i64, 10) }, .{ "hardware", @as(i64, 20) }, .{ "software", @as(i64, 7) } }) |item| {
        var inserted = try db.from(Sale).insert(.{ .category = item[0], .amount = item[1] });
        inserted.deinit();
    }
    var grouped = try db.exec("SELECT category, COUNT(*), SUM(amount), AVG(amount), MIN(amount), MAX(amount) FROM grouped_sales GROUP BY category;");
    defer grouped.deinit();
    if (grouped.rowCount() != 2 or grouped.rows[0][1].integer != 2 or grouped.rows[0][2].integer != 30) return error.GroupedAggregateVerificationFailed;
    std.debug.print("36 grouped aggregates: COUNT, SUM, AVG, MIN, and MAX verified\n", .{});
}
