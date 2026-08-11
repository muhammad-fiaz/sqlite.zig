---
title: "Prepared Statement with Parameter Binding"
description: "Use prepared statements with parameter binding to safely insert data into a SQLite database."
---

# Prepared Statement with Parameter Binding

Use prepared statements with parameter binding to safely insert data into a SQLite database.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT) | Creates the users table if it doesn't exist |
| 2 | INSERT INTO users VALUES (?, ?) | Inserts a row using bound parameters (id=1, name='Fiaz') |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_02.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER, name TEXT);");
    setup.deinit();
    var statement = try db.prepare("INSERT INTO users VALUES (?, ?);");
    defer statement.finalize();
    try statement.bind(1, 1);
    try statement.bind(2, "Fiaz");
    try statement.step();
}
```

## Database State After Execution

| id | name |
|----|------|
| 1 | Fiaz |

## Zig Output

```
02 prepared statement: parameterized insert completed
```

> [!TIP]
> Run with: `zig build run-02_prepared_statement`
