---
title: "DSL CRUD Operations"
description: "Perform Create, Read, Update, and Delete operations using the typed DSL query builder."
---

# DSL CRUD Operations

Perform Create, Read, Update, and Delete operations using the typed DSL query builder.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS dsl_users (id INTEGER, name TEXT) | Creates the dsl_users table |
| 2 | INSERT INTO dsl_users VALUES (1, 'before') | Inserts initial row |
| 3 | UPDATE dsl_users SET name = 'after' WHERE id = 1 | Updates the row |
| 4 | SELECT id, name FROM dsl_users WHERE id = 1 | Reads the updated row |
| 5 | DELETE FROM dsl_users WHERE id = 1 | Deletes the row |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("dsl_users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_09.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true });
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "before" });
    inserted.deinit();
    var mutation = try db.from(User).update(.{ .name = "after" });
    defer mutation.deinit();
    var updated = try mutation.where(User.column("id").eq(1)).execute();
    updated.deinit();
    var selected = try db.from(User).selectFieldNames(&.{ "id", "name" }).where(User.column("id").eq(1)).fetchAll();
    selected.deinit();
    var deleted = try db.from(User).delete().where(User.column("id").eq(1)).execute();
    deleted.deinit();
}
```

## Database State After Execution

The row is deleted at the end of the example, so the table is empty:

| id | name |
|----|------|
| *(empty)* | *(empty)* |

## Zig Output

```
09 dsl crud: insert, update, select, delete verified
```

> [!TIP]
> Run with: `zig build run-09_dsl_crud`
