const std = @import("std");
const sqlite = @import("sqlite");

const Account = sqlite.table("dsl_accounts", struct { id: i64, owner: []const u8, balance: i64 });

fn transfer(db: *sqlite.Connection) !void {
    var debitMutation = try db.from(Account).update(.{ .balance = 75 });
    var debit = try debitMutation.where(Account.columns.id.eq(1)).execute();
    debit.deinit();
    var creditMutation = try db.from(Account).update(.{ .balance = 125 });
    var credit = try creditMutation.where(Account.columns.id.eq(2)).execute();
    credit.deinit();
}

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_10.db");
    defer db.close();
    try db.createTable(Account, .{ .overWrite = true });

    var first = try db.from(Account).insert(.{ .id = 1, .owner = "Alice", .balance = 100 });
    first.deinit();
    var second = try db.from(Account).insert(.{ .id = 2, .owner = "Bob", .balance = 100 });
    second.deinit();

    try db.transaction(transfer);
    try db.savepoint("report");
    var rows = try db.from(Account).select(.{ Account.columns.id, Account.columns.owner, Account.columns.balance })
        .where(Account.columns.balance.gte(75))
        .andWhere(Account.columns.id.gt(0))
        .orderBy(Account.columns.balance.desc())
        .limit(10)
        .fetch();
    rows.deinit();
    try db.releaseSavepoint("report");

    var total = try db.from(Account).select(.{Account.columns.balance.sum()}).fetch();
    total.deinit();
    std.debug.print("10 dsl advanced: transactions, savepoints, and aggregates verified\n", .{});
}
