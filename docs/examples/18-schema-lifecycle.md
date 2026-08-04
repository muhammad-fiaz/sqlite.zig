---
title: "Schema Lifecycle"
description: "CREATE, ALTER, DROP table lifecycle"
---

# Schema Lifecycle

Manage the schema lifecycle with CREATE, ALTER, and DROP operations.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_18.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS lifecycle (id INTEGER, name TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO lifecycle VALUES (1, 'test');");
    result.deinit();
    var rows = try db.exec("SELECT * FROM lifecycle;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-18-schema-lifecycle`