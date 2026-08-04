---
title: "Migrations"
description: "Schema migration patterns"
---

# Migrations

Implement schema migration patterns to manage database versions.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_05.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO schema_version VALUES (1);");
    result.deinit();
    var rows = try db.exec("SELECT * FROM schema_version;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-05-migrations`