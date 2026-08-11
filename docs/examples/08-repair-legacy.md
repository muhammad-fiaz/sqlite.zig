---
title: "Repair Legacy Database"
description: "Create a fresh database file and populate it with legacy table schema and data."
---

# Repair Legacy Database

Create a fresh database file and populate it with legacy table schema and data.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE users (id INTEGER, name TEXT) | Creates the users table |
| 2 | INSERT INTO users VALUES (1, 'Fiaz') | Inserts a single row |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var io_instance: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();
    var file = try std.Io.Dir.cwd().createFile(io, "example_04.db", .{ .read = true, .truncate = true });
    file.close(io);
    var db = try sqlite.open(std.heap.page_allocator, "example_04.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE users (id INTEGER, name TEXT);");
    setup.deinit();
    var insert = try db.exec("INSERT INTO users VALUES (1, 'Fiaz');");
    insert.deinit();
}
```

## Database State After Execution

| id | name |
|----|------|
| 1 | Fiaz |

## Zig Output

```
08 repair legacy: legacy database created and populated
```

> [!TIP]
> Run with: `zig build run-08_repair_legacy_example`
