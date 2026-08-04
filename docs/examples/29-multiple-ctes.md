---
title: "Multiple CTEs"
description: "Multiple CTEs with cross-CTE joins"
---

# Multiple CTEs

Use multiple CTEs with cross-CTE joins for complex queries.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_29.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS mcte_users (id INTEGER, name TEXT);");
    result.deinit();
    result = try db.exec("CREATE TABLE IF NOT EXISTS mcte_orders (id INTEGER, user_id INTEGER, amount INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO mcte_users VALUES (1, 'Alice');");
    result.deinit();
    result = try db.exec("INSERT INTO mcte_orders VALUES (10, 1, 100);");
    result.deinit();
    var rows = try db.exec(
        \\WITH
        \\  u AS (SELECT id, name FROM mcte_users),
        \\  o AS (SELECT id, user_id, amount FROM mcte_orders)
        \\SELECT u.name, o.amount FROM u INNER JOIN o ON u.id = o.user_id;
    );
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-29-multiple-ctes`