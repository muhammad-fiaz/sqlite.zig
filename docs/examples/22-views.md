---
title: "Views and Typed Reads"
description: "Create SQL views and read from them using both raw SQL and typed DSL queries."
---

# Views and Typed Reads

Create SQL views and read from them using both raw SQL and typed DSL queries.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS view_users (id INTEGER PRIMARY KEY, name TEXT, active INTEGER) | Creates users table |
| 2 | DELETE FROM view_users | Truncates the table |
| 3 | INSERT INTO view_users VALUES (1, 'Alice', 1) | Inserts active Alice |
| 4 | INSERT INTO view_users VALUES (2, 'Bob', 0) | Inserts inactive Bob |
| 5 | CREATE VIEW active_users AS SELECT id, name, active FROM view_users WHERE active = 1 | Creates view for active users |
| 6 | SELECT * FROM active_users | Typed DSL read from view |
| 7 | SELECT * FROM active_users | Raw SQL read from view |
| 8 | *(reopen database)* | Reopens to verify persistence |
| 9 | SELECT * FROM active_users | Reads view after reopen |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const UserRow = struct { id: i64, name: []const u8, active: i64 };
const User = sqlite.table("view_users", UserRow);
const ActiveUser = sqlite.table("active_users", struct { id: i64, name: []const u8, active: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_22.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key = User.key("id") });
    try db.truncate(User);
    db.dropView("active_users") catch {};
    var first = try db.from(User).insertTyped(.{ .id = 1, .name = "Alice", .active = 1 });
    first.deinit();
    var second = try db.from(User).insertTyped(.{ .id = 2, .name = "Bob", .active = 0 });
    second.deinit();
    var create = try db.exec("CREATE VIEW active_users AS SELECT id, name, active FROM view_users WHERE active = 1;");
    create.deinit();

    var typed = try db.from(ActiveUser).selectAll().fetchAll();
    defer typed.deinit();
    if (typed.rowCount() != 1 or typed.rows[0][0].integer != 1) return error.ViewVerificationFailed;
    var raw = try db.exec("SELECT * FROM active_users;");
    defer raw.deinit();
    if (raw.rowCount() != typed.rowCount()) return error.ViewInteropVerificationFailed;
    var reopened = try sqlite.open(std.heap.page_allocator, "valid_22.db");
    defer reopened.close();
    var persisted = try reopened.from(ActiveUser).selectAll().fetchAll();
    defer persisted.deinit();
    if (persisted.rowCount() != 1) return error.ViewPersistenceVerificationFailed;
    std.debug.print("22 views: raw and typed view reads verified\n", .{});
}
```

## Database State After Execution

**view_users:**

| id | name | active |
|----|------|--------|
| 1 | Alice | 1 |
| 2 | Bob | 0 |

**active_users (view):**

| id | name | active |
|----|------|--------|
| 1 | Alice | 1 |

## Zig Output

```
22 views: raw and typed view reads verified
```

> [!TIP]
> Run with: `zig build run-22_views_and_typed_reads`
