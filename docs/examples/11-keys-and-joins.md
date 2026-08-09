---
title: "Keys and Joins"
description: "Define primary keys, foreign keys, unique constraints, and perform inner/left joins between related tables."
---

# Keys and Joins

Define primary keys, foreign keys, unique constraints, and perform inner/left joins between related tables.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS relation_users (id INTEGER PRIMARY KEY, email TEXT UNIQUE) | Creates users table with PK and unique email |
| 2 | CREATE TABLE IF NOT EXISTS relation_orders (id INTEGER PRIMARY KEY, user_id INTEGER, FOREIGN KEY (user_id) REFERENCES relation_users(id)) | Creates orders table with FK to users |
| 3 | DELETE FROM relation_orders | Truncates orders |
| 4 | DELETE FROM relation_users | Truncates users |
| 5 | INSERT INTO relation_users VALUES (1, 'user@example.test') | Inserts a user |
| 6 | INSERT INTO relation_orders VALUES (1, 1) | Inserts an order linked to user 1 |
| 7 | SELECT * FROM relation_users INNER JOIN relation_orders ON relation_users.id = relation_orders.user_id | Inner join query |
| 8 | SELECT * FROM relation_users LEFT JOIN relation_orders ON relation_users.id = relation_orders.user_id | Left join query |
| 9 | SELECT * FROM relation_users JOIN relation_orders ON relation_users.id = relation_orders.user_id | Raw join query |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("relation_users", struct { id: i64, email: []const u8 });
const Order = sqlite.table("relation_orders", struct { id: i64, user_id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_11.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key = User.key("id"), .unique_keys = &.{User.key("email")} });
    try db.createTable(Order, .{ .if_not_exists = true, .primary_key = Order.key("id"), .foreign_keys = &.{.{ .table = "relation_users", .referenced_column = "id", .column_key = Order.key("user_id") }} });
    try db.truncate(Order);
    try db.truncate(User);

    var user = try db.from(User).insert(.{ .id = 1, .email = "user@example.test" });
    user.deinit();
    var order = try db.from(Order).insert(.{ .id = 1, .user_id = 1 });
    order.deinit();

    var inner = try db.from(User).innerJoin(Order, "id", "user_id").fetchAll();
    inner.deinit();
    var left = try db.from(User).leftJoin(Order, "id", "user_id").fetchAll();
    left.deinit();
    var raw = try db.exec("SELECT * FROM relation_users JOIN relation_orders ON relation_users.id = relation_orders.user_id;");
    raw.deinit();
}
```

## Database State After Execution

**relation_users:**

| id | email |
|----|-------|
| 1 | user@example.test |

**relation_orders:**

| id | user_id |
|----|---------|
| 1 | 1 |

## Zig Output

```
No console output - operations completed successfully
```

> [!TIP]
> Run with: `zig build run-11_keys_and_joins`
