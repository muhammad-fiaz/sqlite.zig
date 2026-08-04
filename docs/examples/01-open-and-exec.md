---
title: "Open & Execute"
description: "Open a database and execute raw SQL statements"
---

# Open & Execute

Open a database connection and execute raw SQL statements including CREATE TABLE, INSERT, and SELECT.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_01.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS demo (id INTEGER, value TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO demo VALUES (1, 'hello');");
    result.deinit();
    var rows = try db.exec("SELECT * FROM demo;");
    defer rows.deinit();
    std.debug.print("Rows: {d}\n", .{rows.rowCount()});
}
```

> [!TIP]
> Run with: `zig build run-01-open-and-exec`