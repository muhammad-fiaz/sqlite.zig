---
title: Explain Query Plan
description: Use EXPLAIN QUERY PLAN to verify index usage on SELECT queries.
---

# Explain Query Plan

This example demonstrates how to use SQLite's `EXPLAIN QUERY PLAN` statement to inspect the query plan and verify that an index is being used for a lookup. It creates a table with an index, runs a query, and confirms the planner uses the index.

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

> [!TIP]
> Run with: `zig build run-33_explain_query_plan`
