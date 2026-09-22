//! UPDATE FROM assigns values from a join source.
const std = @import("std");
const sqlite = @import("sqlite");

const Balance = sqlite.table("update_from_balances", struct { id: i64, amount: i64 });
const Adjustment = sqlite.table("update_from_adjustments", struct { id: i64, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_42.db");
    defer db.close();
    try db.createTable(Balance, .{ .overWrite = true, .primaryKey = Balance.id });
    try db.createTable(Adjustment, .{ .overWrite = true });
    try db.truncate(Balance);
    try db.truncate(Adjustment);
    var balance = try db.from(Balance).insert(.{ .id = 1, .amount = 10 });
    balance.deinit();
    var adjustment = try db.from(Adjustment).insert(.{ .id = 1, .amount = 99 });
    adjustment.deinit();
    var result = try db.exec("UPDATE update_from_balances SET amount = update_from_adjustments.amount FROM update_from_adjustments WHERE update_from_balances.id = update_from_adjustments.id;");
    defer result.deinit();
    var rows = try db.from(Balance).selectAll().fetch();
    defer rows.deinit();
    if (rows.count() != 1 or rows.at(0).amount != 99) return error.UpdateFromVerificationFailed;
    std.debug.print("42 UPDATE FROM: equi-join source assignment verified\n", .{});
}
