---
title: "Open Database and Execute SQL"
description: "Open a SQLite database and execute raw SQL statements to create a table and insert data."
---

# Open Database and Execute SQL

Open a SQLite database and execute raw SQL statements to create a table and insert data.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT) | Creates the users table if it doesn't exist |
| 2 | INSERT INTO users VALUES (1, 'Fiaz') | Inserts a single row into the users table |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_01.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO users VALUES (1, 'Fiaz');");
    result.deinit();
}
```

## Database State After Execution

| id | name |
|----|------|
| 1 | Fiaz |

## Zig Output

```
01 open and exec: table created and row inserted
```

> [!TIP]
> Run with: `zig build run-01_open_and_exec`
