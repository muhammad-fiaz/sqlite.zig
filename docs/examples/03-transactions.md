---
title: "Transactions with Rollback and Commit"
description: "Demonstrate transaction handling with rollback and commit using the DSL query builder."
---

# Transactions with Rollback and Commit

Demonstrate transaction handling with rollback and commit using the DSL query builder.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS ledger (id INTEGER, amount INTEGER) | Creates the ledger table |
| 2 | DELETE FROM ledger | Truncates the ledger table |
| 3 | BEGIN | Starts a transaction |
| 4 | INSERT INTO ledger VALUES (1, 100) | Inserts a row (will be rolled back) |
| 5 | ROLLBACK | Rolls back the transaction |
| 6 | BEGIN | Starts a new transaction |
| 7 | INSERT INTO ledger VALUES (1, 100) | Inserts a row (will be committed) |
| 8 | COMMIT | Commits the transaction |
| 9 | SELECT id, amount FROM ledger | Queries the final state |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Ledger = sqlite.table("ledger", struct { id: i64, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_03.db");
    defer db.close();
    try db.createTable(Ledger, .{ .if_not_exists = true });
    try db.truncate(Ledger);
    try db.begin();
    var rolled_back_insert = try db.from(Ledger).insert(.{ .id = 1, .amount = 100 });
    rolled_back_insert.deinit();
    try db.rollback();
    try db.begin();
    var committed_insert = try db.from(Ledger).insert(.{ .id = 1, .amount = 100 });
    committed_insert.deinit();
    try db.commit();
    var result = try db.from(Ledger).selectFieldNames(&.{ "id", "amount" }).fetchAll();
    defer result.deinit();
    if (result.rowCount() != 1 or result.rows[0][0].integer != 1 or result.rows[0][1].integer != 100) return error.TransactionExampleFailed;
}
```

## Database State After Execution

| id | amount |
|----|--------|
| 1 | 100 |

## Zig Output

```
No console output - operations completed successfully
```

> [!TIP]
> Run with: `zig build run-03_transactions`
