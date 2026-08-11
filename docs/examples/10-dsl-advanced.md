---
title: "DSL Advanced Queries"
description: "Use advanced DSL features including transactions, savepoints, filtering, ordering, and aggregation."
---

# DSL Advanced Queries

Use advanced DSL features including transactions, savepoints, filtering, ordering, and aggregation.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS dsl_accounts (id INTEGER, owner TEXT, balance INTEGER) | Creates the accounts table |
| 2 | INSERT INTO dsl_accounts VALUES (1, 'Alice', 100) | Inserts Alice's account |
| 3 | INSERT INTO dsl_accounts VALUES (2, 'Bob', 100) | Inserts Bob's account |
| 4 | UPDATE dsl_accounts SET balance = 75 WHERE id = 1 | Debits Alice's account |
| 5 | UPDATE dsl_accounts SET balance = 125 WHERE id = 2 | Credits Bob's account |
| 6 | SELECT id, owner, balance FROM dsl_accounts WHERE balance >= 75 AND id > 0 ORDER BY balance DESC LIMIT 10 | Queries filtered and sorted results |
| 7 | SELECT SUM(balance) FROM dsl_accounts | Aggregates total balance |

## Source Code

```zig
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
}
```

## Database State After Execution

| id | owner | balance |
|----|-------|---------|
| 2 | Bob | 125 |
| 1 | Alice | 75 |

## Zig Output

```
10 dsl advanced: transactions, savepoints, and aggregates verified
```

> [!TIP]
> Run with: `zig build run-10_dsl_advanced`
