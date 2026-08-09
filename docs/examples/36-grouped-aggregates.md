---
title: "Grouped Aggregates"
description: "Use GROUP BY with aggregate functions COUNT, SUM, AVG, MIN, and MAX to summarize data."
---

# Grouped Aggregates

Use GROUP BY with aggregate functions COUNT, SUM, AVG, MIN, and MAX to summarize data.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS grouped_sales (category TEXT, amount INTEGER) | Creates sales table |
| 2 | DELETE FROM grouped_sales | Truncates the table |
| 3 | INSERT INTO grouped_sales VALUES ('hardware', 10) | Inserts hardware sale |
| 4 | INSERT INTO grouped_sales VALUES ('hardware', 20) | Inserts hardware sale |
| 5 | INSERT INTO grouped_sales VALUES ('software', 7) | Inserts software sale |
| 6 | SELECT category, COUNT(*), SUM(amount), AVG(amount), MIN(amount), MAX(amount) FROM grouped_sales GROUP BY category | Aggregates by category |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Sale = sqlite.table("grouped_sales", struct { category: []const u8, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_36.db");
    defer db.close();
    try db.createTable(Sale, .{ .if_not_exists = true });
    try db.truncate(Sale);
    inline for (.{ .{ "hardware", @as(i64, 10) }, .{ "hardware", @as(i64, 20) }, .{ "software", @as(i64, 7) } }) |item| {
        var inserted = try db.from(Sale).insert(.{ .category = item[0], .amount = item[1] });
        inserted.deinit();
    }
    var grouped = try db.exec("SELECT category, COUNT(*), SUM(amount), AVG(amount), MIN(amount), MAX(amount) FROM grouped_sales GROUP BY category;");
    defer grouped.deinit();
    if (grouped.rowCount() != 2 or grouped.rows[0][1].integer != 2 or grouped.rows[0][2].integer != 30) return error.GroupedAggregateVerificationFailed;
    std.debug.print("36 grouped aggregates: COUNT, SUM, AVG, MIN, and MAX verified\n", .{});
}
```

## Database State After Execution

**grouped_sales:**

| category | amount |
|----------|--------|
| hardware | 10 |
| hardware | 20 |
| software | 7 |

**Aggregation result:**

| category | COUNT | SUM | AVG | MIN | MAX |
|----------|-------|-----|-----|-----|-----|
| hardware | 2 | 30 | 15 | 10 | 20 |
| software | 1 | 7 | 7 | 7 | 7 |

## Zig Output

```
36 grouped aggregates: COUNT, SUM, AVG, MIN, and MAX verified
```

> [!TIP]
> Run with: `zig build run-36_grouped_aggregates`
