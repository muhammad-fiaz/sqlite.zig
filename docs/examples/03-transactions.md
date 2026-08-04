---
title: "Transactions"
description: "BEGIN, COMMIT, ROLLBACK with the typed DSL"
---

# Transactions

Use transactions to group multiple operations with BEGIN, COMMIT, and ROLLBACK.

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

> [!TIP]
> Run with: `zig build run-03-transactions`