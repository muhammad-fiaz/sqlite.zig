---
title: "DSL Query Builder"
description: "Use the typed DSL query builder to construct and execute SQL queries with predicates."
---

# DSL Query Builder

Use the typed DSL query builder to construct and execute SQL queries with predicates.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT) | Creates the users table |
| 2 | INSERT INTO users VALUES (1, 'Fiaz') | Inserts a single row |
| 3 | SELECT * FROM users WHERE id > 0 | Queries rows using DSL where clause |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_04.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT);");
    setup.deinit();
    var insert = try db.exec("INSERT INTO users VALUES (1, 'Fiaz');");
    insert.deinit();
    var rows = try db.from(User).where(User.column("id").gt(0)).fetchAll();
    defer rows.deinit();
}
```

## Database State After Execution

| id | name |
|----|------|
| 1 | Fiaz |

## Zig Output

```
04 dsl query builder: 122 row(s) fetched
```

> [!TIP]
> Run with: `zig build run-04_dsl_query_builder`
