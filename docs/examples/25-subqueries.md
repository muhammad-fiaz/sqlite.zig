---
title: "Subqueries with Raw and Typed DSL"
description: "Use IN subqueries with raw SQL and typed DSL whereInQuery to filter rows based on related tables."
---

# Subqueries with Raw and Typed DSL

Use IN subqueries with raw SQL and typed DSL whereInQuery to filter rows based on related tables.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS subquery_users (id INTEGER PRIMARY KEY, name TEXT) | Creates users table |
| 2 | CREATE TABLE IF NOT EXISTS subquery_orders (id INTEGER PRIMARY KEY, user_id INTEGER) | Creates orders table |
| 3 | DELETE FROM subquery_users | Truncates users |
| 4 | DELETE FROM subquery_orders | Truncates orders |
| 5 | INSERT INTO subquery_users VALUES (1, 'Alice') | Inserts Alice |
| 6 | INSERT INTO subquery_users VALUES (2, 'Bob') | Inserts Bob |
| 7 | INSERT INTO subquery_orders VALUES (10, 1) | Inserts order for Alice |
| 8 | SELECT id, name FROM subquery_users WHERE id IN (SELECT user_id FROM subquery_orders) | Raw IN subquery |
| 9 | SELECT id, name FROM subquery_users WHERE id IN (SELECT user_id FROM subquery_orders) | Typed DSL whereInQuery |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const UserRow = struct { id: i64, name: []const u8 };
const OrderRow = struct { id: i64, user_id: i64 };
const User = sqlite.table("subquery_users", UserRow);
const Order = sqlite.table("subquery_orders", OrderRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_25.db");
    defer db.close();
    try db.createTable(User, .{ .ifNotExists = true, .primaryKey = User.columns.id });
    try db.createTable(Order, .{ .ifNotExists = true, .primaryKey = Order.columns.id });
    try db.truncate(User);
    try db.truncate(Order);
    var alice = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    alice.deinit();
    var bob = try db.from(User).insert(.{ .id = 2, .name = "Bob" });
    bob.deinit();
    var order = try db.from(Order).insert(.{ .id = 10, .user_id = 1 });
    order.deinit();

    var raw = try db.exec("SELECT id, name FROM subquery_users WHERE id IN (SELECT user_id FROM subquery_orders);");
    defer raw.deinit();
    var typed = try db.from(User).whereInQuery(User.columns.id, Order, Order.columns.user_id).select(&.{ User.columns.id, User.columns.name }).fetch();
    defer typed.deinit();
    if (raw.rowCount() != 1 or typed.rowCount() != 1 or typed.rows[0][0].integer != 1) return error.SubqueryVerificationFailed;
    std.debug.print("25 subqueries: raw IN SELECT and typed whereInQuery verified\n", .{});
}
```

## Database State After Execution

**subquery_users:**

| id | name |
|----|------|
| 1 | Alice |
| 2 | Bob |

**subquery_orders:**

| id | user_id |
|----|---------|
| 10 | 1 |

## Zig Output

```
25 subqueries: raw IN SELECT and typed whereInQuery verified
```

> [!TIP]
> Run with: `zig build run-25_subqueries_raw_and_typed_dsl`
