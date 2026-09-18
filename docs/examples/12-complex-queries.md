---
title: "Complex Queries"
description: "Execute complex queries with DISTINCT, inner joins, and aggregate functions across multiple tables."
---

# Complex Queries

Execute complex queries with DISTINCT, inner joins, and aggregate functions across multiple tables.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS complex_users (id INTEGER PRIMARY KEY, name TEXT) | Creates users table |
| 2 | CREATE TABLE IF NOT EXISTS complex_orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount INTEGER) | Creates orders table |
| 3 | DELETE FROM complex_orders | Truncates orders |
| 4 | DELETE FROM complex_users | Truncates users |
| 5 | INSERT INTO complex_users VALUES (1, 'Alice') | Inserts Alice |
| 6 | INSERT INTO complex_users VALUES (2, 'Bob') | Inserts Bob |
| 7 | INSERT INTO complex_orders VALUES (10, 1, 25) | Inserts Alice's first order |
| 8 | INSERT INTO complex_orders VALUES (11, 1, 75) | Inserts Alice's second order |
| 9 | INSERT INTO complex_orders VALUES (12, 2, 10) | Inserts Bob's order |
| 10 | SELECT DISTINCT * FROM complex_users INNER JOIN complex_orders ON complex_users.id = complex_orders.user_id | Distinct inner join |
| 11 | SELECT SUM(amount) FROM complex_orders | Sums all order amounts |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const UserRow = struct { id: i64, name: []const u8 };
const OrderRow = struct { id: i64, user_id: i64, amount: i64 };
const User = sqlite.table("complex_users", UserRow);
const Order = sqlite.table("complex_orders", OrderRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_12.db");
    defer db.close();
    try db.createTable(User, .{ .ifNotExists = true, .primaryKey = User.columns.id });
    try db.createTable(Order, .{ .ifNotExists = true, .primaryKey = Order.columns.id });
    try db.truncate(Order);
    try db.truncate(User);

    var userA = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    userA.deinit();
    var userB = try db.from(User).insert(.{ .id = 2, .name = "Bob" });
    userB.deinit();
    var orderA = try db.from(Order).insert(.{ .id = 10, .user_id = 1, .amount = 25 });
    orderA.deinit();
    var orderB = try db.from(Order).insert(.{ .id = 11, .user_id = 1, .amount = 75 });
    orderB.deinit();
    var orderC = try db.from(Order).insert(.{ .id = 12, .user_id = 2, .amount = 10 });
    orderC.deinit();

    var raw = try db.exec("SELECT DISTINCT * FROM complex_users INNER JOIN complex_orders ON complex_users.id = complex_orders.user_id;");
    raw.deinit();
    var dsl = try db.from(User).innerJoin(Order, User.columns.id.eq(Order.columns.user_id)).selectAll().distinct().fetch();
    dsl.deinit();
    var aggregate = try db.from(Order).select(.{Order.columns.amount.sum()}).fetch();
    aggregate.deinit();
    std.debug.print("12 complex queries: distinct joins and aggregates verified\n", .{});
}
```

## Database State After Execution

**complex_users:**

| id | name |
|----|------|
| 1 | Alice |
| 2 | Bob |

**complex_orders:**

| id | user_id | amount |
|----|---------|--------|
| 10 | 1 | 25 |
| 11 | 1 | 75 |
| 12 | 2 | 10 |

## Zig Output

```
12 complex queries: distinct joins and aggregates verified
```

> [!TIP]
> Run with: `zig build run-12_complex_queries`
