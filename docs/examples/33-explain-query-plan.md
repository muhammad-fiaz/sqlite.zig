---
title: "EXPLAIN QUERY PLAN"
description: "Use EXPLAIN QUERY PLAN to inspect query execution plans and verify index usage."
---

# EXPLAIN QUERY PLAN

Use EXPLAIN QUERY PLAN to inspect query execution plans and verify index usage.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS planner_items (id INTEGER PRIMARY KEY, code TEXT, value INTEGER) | Creates items table |
| 2 | CREATE INDEX planner_items_code_idx ON planner_items (code) | Creates index on code |
| 3 | DELETE FROM planner_items | Truncates the table |
| 4 | INSERT INTO planner_items VALUES (1, 'A', 10) | Inserts item A |
| 5 | INSERT INTO planner_items VALUES (2, 'B', 20) | Inserts item B |
| 6 | EXPLAIN QUERY PLAN SELECT id FROM planner_items WHERE code = 'B' | Shows query plan (uses index) |
| 7 | SELECT id, value FROM planner_items WHERE code = 'B' | Queries using index |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("planner_items", struct { id: i64, code: []const u8, value: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_33.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true, .primary_key = Item.key("id") });
    db.dropIndex("planner_items_code_idx") catch {};
    try db.createIndex(Item, "planner_items_code_idx", &.{Item.key("code")}, false);
    try db.truncate(Item);
    var inserted = try db.from(Item).insertTyped(.{ .id = 1, .code = "A", .value = 10 });
    inserted.deinit();
    inserted = try db.from(Item).insertTyped(.{ .id = 2, .code = "B", .value = 20 });
    inserted.deinit();

    var plan = try db.exec("EXPLAIN QUERY PLAN SELECT id FROM planner_items WHERE code = 'B';");
    defer plan.deinit();
    if (plan.rowCount() != 1 or std.mem.indexOf(u8, plan.rows[0][0].text, "USING INDEX planner_items_code_idx") == null) return error.IndexPlanVerificationFailed;
    var rows = try db.from(Item).selectColumns(&.{ Item.key("id"), Item.key("value") }).where(Item.column("code").eq("B")).fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1 or rows.rows[0][0].integer != 2) return error.IndexLookupVerificationFailed;
    std.debug.print("33 planner: EXPLAIN QUERY PLAN and indexed equality verified\n", .{});
}
```

## Database State After Execution

| id | code | value |
|----|------|-------|
| 1 | A | 10 |
| 2 | B | 20 |

## Zig Output

```
33 planner: EXPLAIN QUERY PLAN and indexed equality verified
```

> [!TIP]
> Run with: `zig build run-33_explain_query_plan`
