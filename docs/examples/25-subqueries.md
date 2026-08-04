---
title: "Subqueries"
description: "Subqueries in FROM and WHERE clauses"
---

# Subqueries

Use subqueries in FROM and WHERE clauses for complex filtering.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_25.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS sub_users (id INTEGER, name TEXT);");
    result.deinit();
    result = try db.exec("CREATE TABLE IF NOT EXISTS sub_orders (id INTEGER, user_id INTEGER, amount INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO sub_users VALUES (1, 'Alice'), (2, 'Bob');");
    result.deinit();
    result = try db.exec("INSERT INTO sub_orders VALUES (10, 1, 100), (11, 2, 50);");
    result.deinit();
    var rows = try db.exec("SELECT * FROM sub_users WHERE id IN (SELECT user_id FROM sub_orders WHERE amount > 75);");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-25-subqueries`