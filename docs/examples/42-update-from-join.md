---
title: "UPDATE FROM Join"
description: "Use UPDATE ... FROM to update rows based on a join with another table."
---

# UPDATE FROM Join

Use UPDATE ... FROM to update rows based on a join with another table.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS update_from_balances (id INTEGER PRIMARY KEY, amount INTEGER) | Creates balances table |
| 2 | CREATE TABLE IF NOT EXISTS update_from_adjustments (id INTEGER, amount INTEGER) | Creates adjustments table |
| 3 | DELETE FROM update_from_balances | Truncates balances |
| 4 | DELETE FROM update_from_adjustments | Truncates adjustments |
| 5 | INSERT INTO update_from_balances VALUES (1, 10) | Inserts initial balance |
| 6 | INSERT INTO update_from_adjustments VALUES (1, 99) | Inserts adjustment |
| 7 | UPDATE update_from_balances SET amount = update_from_adjustments.amount FROM update_from_adjustments WHERE update_from_balances.id = update_from_adjustments.id | Updates balance from adjustment |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Balance = sqlite.table("update_from_balances", struct { id: i64, amount: i64 });
const Adjustment = sqlite.table("update_from_adjustments", struct { id: i64, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_42.db");
    defer db.close();
    try db.createTable(Balance, .{ .if_not_exists = true, .primary_key = Balance.key("id") });
    try db.createTable(Adjustment, .{ .if_not_exists = true });
    try db.truncate(Balance);
    try db.truncate(Adjustment);
    var balance = try db.from(Balance).insert(.{ .id = 1, .amount = 10 });
    balance.deinit();
    var adjustment = try db.from(Adjustment).insert(.{ .id = 1, .amount = 99 });
    adjustment.deinit();
    var result = try db.exec("UPDATE update_from_balances SET amount = update_from_adjustments.amount FROM update_from_adjustments WHERE update_from_balances.id = update_from_adjustments.id;");
    defer result.deinit();
    var rows = try db.from(Balance).selectAll().fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1 or rows.rows[0][1].integer != 99) return error.UpdateFromVerificationFailed;
    std.debug.print("42 UPDATE FROM: equi-join source assignment verified\n", .{});
}
```

## Database State After Execution

**update_from_balances:**

| id | amount |
|----|--------|
| 1 | 99 |

**update_from_adjustments:**

| id | amount |
|----|--------|
| 1 | 99 |

## Zig Output

```
42 UPDATE FROM: equi-join source assignment verified
```

> [!TIP]
> Run with: `zig build run-42_update_from_join`
