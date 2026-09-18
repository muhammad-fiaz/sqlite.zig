const std = @import("std");
const sqlite = @import("sqlite");

const Ledger = sqlite.table("ledger", struct { id: i64, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_03.db");
    defer db.close();
    try db.createTable(Ledger, .{ .ifNotExists = true });
    try db.truncate(Ledger);
    try db.begin();
    var rolledBackInsert = try db.from(Ledger).insert(.{ .id = 1, .amount = 100 });
    rolledBackInsert.deinit();
    try db.rollback();
    try db.begin();
    var committedInsert = try db.from(Ledger).insert(.{ .id = 1, .amount = 100 });
    committedInsert.deinit();
    try db.commit();
    var result = try db.from(Ledger).select(.{ Ledger.columns.id, Ledger.columns.amount }).fetch();
    defer result.deinit();
    if (result.rowCount() != 1 or result.rows[0][0].integer != 1 or result.rows[0][1].integer != 100) return error.TransactionExampleFailed;
    std.debug.print("03 transactions: rollback and commit verified\n", .{});
}
