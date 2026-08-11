const std = @import("std");
const sqlite = @import("sqlite");

const Account = sqlite.table("dsl_accounts", struct { id: i64, owner: []const u8, balance: i64 });

fn transfer(db: *sqlite.Connection) !void {
    var debit_mutation = try db.from(Account).update(.{ .balance = 75 });
    var debit = try debit_mutation.where(Account.column("id").eq(1)).execute();
    debit_mutation.deinit();
    debit.deinit();
    var credit_mutation = try db.from(Account).update(.{ .balance = 125 });
    var credit = try credit_mutation.where(Account.column("id").eq(2)).execute();
    credit_mutation.deinit();
    credit.deinit();
}

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_10.db");
    defer db.close();
    try db.createTable(Account, .{ .if_not_exists = true });

    var first = try db.from(Account).insert(.{ .id = 1, .owner = "Alice", .balance = 100 });
    first.deinit();
    var second = try db.from(Account).insert(.{ .id = 2, .owner = "Bob", .balance = 100 });
    second.deinit();

    try db.transaction(transfer);
    try db.savepoint("report");
    var rows = try db.from(Account).selectFieldNames(&.{ "id", "owner", "balance" })
        .where(Account.column("balance").ge(75))
        .andWhere(Account.column("id").gt(0))
        .orderBy(Account.column("balance").desc())
        .limit(10)
        .fetchAll();
    rows.deinit();
    try db.releaseSavepoint("report");

    var total = try db.from(Account).sum("balance").fetchAll();
    total.deinit();
    std.debug.print("10 dsl advanced: transactions, savepoints, and aggregates verified\n", .{});
}
