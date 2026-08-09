---
title: "Edge Cases"
description: "Handle edge cases including NULL values, unique constraints, savepoints, and invalid SQL syntax."
---

# Edge Cases

Handle edge cases including NULL values, unique constraints, savepoints, and invalid SQL syntax.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS edge_items (id INTEGER PRIMARY KEY, label TEXT UNIQUE) | Creates table with unique label |
| 2 | DELETE FROM edge_items | Truncates the table |
| 3 | INSERT INTO edge_items VALUES (1, 'alpha') | Inserts a row with label |
| 4 | INSERT INTO edge_items (id, label) VALUES (2, NULL), (3, NULL) | Inserts rows with NULL labels |
| 5 | INSERT INTO edge_items VALUES (6, NULL) | Inserts another NULL via DSL |
| 6 | BEGIN / INSERT INTO edge_items VALUES (4, 'rolled-back') / ROLLBACK | Rolled back insert |
| 7 | BEGIN / INSERT INTO edge_items VALUES (5, 'temporary') / ROLLBACK TO SAVEPOINT edge_point | Rolled back to savepoint |
| 8 | COMMIT | Commits the transaction |
| 9 | SELECT * FROM edge_items WHERE label IS NULL | Queries NULL labels |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("edge_items", struct { id: i64, label: ?[]const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_13.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true, .primary_key = Item.key("id"), .unique_keys = &.{Item.key("label")} });
    try db.truncate(Item);
    var first = try db.from(Item).insert(.{ .id = 1, .label = "alpha" });
    first.deinit();
    var nulls = try db.exec("INSERT INTO edge_items (id, label) VALUES (2, NULL), (3, NULL);");
    nulls.deinit();
    var dsl_null = try db.from(Item).insert(.{ .id = 6, .label = @as(?[]const u8, null) });
    dsl_null.deinit();
    try db.begin();
    var rolled = try db.from(Item).insert(.{ .id = 4, .label = "rolled-back" });
    rolled.deinit();
    try db.rollback();
    try db.begin();
    try db.savepoint("edge_point");
    var temporary = try db.from(Item).insert(.{ .id = 5, .label = "temporary" });
    temporary.deinit();
    try db.rollbackToSavepoint("edge_point");
    try db.releaseSavepoint("edge_point");
    try db.commit();
    var result = try db.from(Item).where(Item.column("label").isNull()).fetchAll();
    result.deinit();
    const invalid = db.exec("SELECT FROM edge_items;") catch null;
    if (invalid) |value| {
        var owned = value;
        owned.deinit();
        return error.InvalidQueryWasAccepted;
    }
}
```

## Database State After Execution

| id | label |
|----|-------|
| 1 | alpha |
| 2 | NULL |
| 3 | NULL |
| 6 | NULL |

## Zig Output

```
No console output - operations completed successfully
```

> [!TIP]
> Run with: `zig build run-13_edge_cases`
