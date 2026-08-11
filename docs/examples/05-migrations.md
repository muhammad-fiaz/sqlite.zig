---
title: "Schema Migrations"
description: "Apply schema migrations using the migration runner to create tables with versioned SQL."
---

# Schema Migrations

Apply schema migrations using the migration runner to create tables with versioned SQL.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT) | Migration v1: Creates the users table |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_05.db");
    defer db.close();
    const migrations = [_]sqlite.migration.Migration{
        .{ .version = 1, .up_sql = "CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT);", .down_sql = "DROP TABLE users;" },
    };
    var runner = sqlite.migration.Runner.init(std.heap.page_allocator, &migrations);
    _ = try runner.apply(db);
}
```

## Database State After Execution

The `users` table is created with columns `id` and `name`. No rows are inserted.

| id | name |
|----|------|
| *(empty)* | *(empty)* |

## Zig Output

```
05 migrations: schema migration applied
```

> [!TIP]
> Run with: `zig build run-05_migrations`
