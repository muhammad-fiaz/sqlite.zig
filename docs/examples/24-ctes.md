---
title: "CTEs with Raw and Typed Reads"
description: "Use Common Table Expressions (CTEs) with raw SQL and read results via typed DSL queries."
---

# CTEs with Raw and Typed Reads

Use Common Table Expressions (CTEs) with raw SQL and read results via typed DSL queries.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS cte_users (id INTEGER PRIMARY KEY, name TEXT, active INTEGER) | Creates users table |
| 2 | DELETE FROM cte_users | Truncates the table |
| 3 | INSERT INTO cte_users VALUES (1, 'Alice', 1) | Inserts active Alice |
| 4 | INSERT INTO cte_users VALUES (2, 'Bob', 0) | Inserts inactive Bob |
| 5 | WITH active_cte AS (SELECT id, name, active FROM cte_users WHERE active = 1) SELECT * FROM active_cte | Raw CTE query |
| 6 | CREATE VIEW active_cte AS SELECT id, name, active FROM cte_users WHERE active = 1 | Creates view from CTE logic |
| 7 | SELECT * FROM active_cte | Typed DSL read from view |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const UserRow = struct { id: i64, name: []const u8, active: i64 };
const User = sqlite.table("cte_users", UserRow);
const Active = sqlite.table("active_cte", UserRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_24.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key = User.key("id") });
    try db.truncate(User);
    var one = try db.from(User).insertTyped(.{ .id = 1, .name = "Alice", .active = 1 });
    one.deinit();
    var two = try db.from(User).insertTyped(.{ .id = 2, .name = "Bob", .active = 0 });
    two.deinit();

    var raw = try db.exec("WITH active_cte AS (SELECT id, name, active FROM cte_users WHERE active = 1) SELECT * FROM active_cte;");
    defer raw.deinit();
    try db.createView("active_cte", "SELECT id, name, active FROM cte_users WHERE active = 1");
    defer db.dropView("active_cte") catch {};
    var typed = try db.from(Active).selectAll().fetchAll();
    defer typed.deinit();
    if (raw.rowCount() != 1 or typed.rowCount() != 1 or typed.rows[0][0].integer != 1) return error.CteVerificationFailed;
    std.debug.print("24 CTE: raw materialization and typed read verified\n", .{});
}
```

## Database State After Execution

**cte_users:**

| id | name | active |
|----|------|--------|
| 1 | Alice | 1 |
| 2 | Bob | 0 |

## Zig Output

```
24 CTE: raw materialization and typed read verified
```

> [!TIP]
> Run with: `zig build run-24_cte_raw_and_typed_reads`
