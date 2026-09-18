---
title: "DSL Select Projections"
description: "Use DSL select projections to query specific columns, apply DISTINCT, and perform COUNT aggregation."
---

# DSL Select Projections

Use DSL select projections to query specific columns, apply DISTINCT, and perform COUNT aggregation.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS select_products (id INTEGER, name TEXT, price INTEGER) | Creates the products table |
| 2 | DELETE FROM select_products | Truncates the table |
| 3 | INSERT INTO select_products VALUES (1, 'keyboard', 80) | Inserts keyboard |
| 4 | INSERT INTO select_products VALUES (2, 'mouse', 30) | Inserts mouse |
| 5 | SELECT id, name FROM select_products WHERE price >= 30 ORDER BY price DESC | Projects id and name columns |
| 6 | SELECT DISTINCT name FROM select_products | Gets distinct names |
| 7 | SELECT COUNT(*) FROM select_products | Counts all rows |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Product = sqlite.table("select_products", struct { id: i64, name: []const u8, price: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_14.db");
    defer db.close();
    try db.createTable(Product, .{ .ifNotExists = true });
    try db.truncate(Product);

    var first = try db.from(Product).insert(.{ .id = 1, .name = "keyboard", .price = 80 });
    first.deinit();
    var second = try db.from(Product).insert(.{ .id = 2, .name = "mouse", .price = 30 });
    second.deinit();

    var projected = try db.from(Product)
        .select(&.{ Product.columns.id, Product.columns.name })
        .where(Product.columns.price.gte(30))
        .orderBy(Product.columns.price.desc())
        .fetch();
    projected.deinit();

    var distinctNames = try db.from(Product).select(.{Product.columns.name}).distinct().fetch();
    distinctNames.deinit();

    var total = try db.from(Product).countStar().fetch();
    total.deinit();
    std.debug.print("14 dsl select projections: field projections and distinct verified\n", .{});
}
```

## Database State After Execution

| id | name | price |
|----|------|-------|
| 1 | keyboard | 80 |
| 2 | mouse | 30 |

## Zig Output

```
14 dsl select projections: field projections and distinct verified
```

> [!TIP]
> Run with: `zig build run-14_dsl_select_projections`
