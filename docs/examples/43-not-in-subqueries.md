---
title: "NOT IN Subqueries"
description: "Use NOT IN subqueries to filter rows that are not present in a related table."
---

# NOT IN Subqueries

Use NOT IN subqueries to filter rows that are not present in a related table.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS not_in_users (id INTEGER) | Creates users table |
| 2 | CREATE TABLE IF NOT EXISTS not_in_blocked (user_id INTEGER) | Creates blocked table |
| 3 | DELETE FROM not_in_users | Truncates users |
| 4 | DELETE FROM not_in_blocked | Truncates blocked |
| 5 | INSERT INTO not_in_users VALUES (1) | Inserts user 1 |
| 6 | INSERT INTO not_in_users VALUES (2) | Inserts user 2 |
| 7 | INSERT INTO not_in_blocked VALUES (2) | Blocks user 2 |
| 8 | SELECT id FROM not_in_users WHERE id NOT IN (SELECT user_id FROM not_in_blocked) | Queries non-blocked users |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("not_in_users", struct { id: i64 });
const Blocked = sqlite.table("not_in_blocked", struct { user_id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_43.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true });
    try db.createTable(Blocked, .{ .if_not_exists = true });
    try db.truncate(User);
    try db.truncate(Blocked);
    var a = try db.from(User).insert(.{ .id = 1 });
    a.deinit();
    var b = try db.from(User).insert(.{ .id = 2 });
    b.deinit();
    var blocked = try db.from(Blocked).insert(.{ .user_id = 2 });
    blocked.deinit();
    var rows = try db.from(User).whereNotInColumn(User.key("id"), Blocked, Blocked.key("user_id")).fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1 or rows.rows[0][0].integer != 1) return error.NotInVerificationFailed;
    std.debug.print("43 NOT IN: raw-compatible anti-subquery DSL verified\n", .{});
}
```

## Database State After Execution

**not_in_users:**

| id |
|----|
| 1 |
| 2 |

**not_in_blocked:**

| user_id |
|---------|
| 2 |

**Query result (users NOT IN blocked):**

| id |
|----|
| 1 |

## Zig Output

```
43 NOT IN: raw-compatible anti-subquery DSL verified
```

> [!TIP]
> Run with: `zig build run-43_not_in_subqueries`
