---
title: "CTEs"
description: "Common Table Expressions with typed reads"
---

# CTEs

Use Common Table Expressions (CTEs) for complex queries.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_24.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS cte_users (id INTEGER, name TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO cte_users VALUES (1, 'Alice'), (2, 'Bob');");
    result.deinit();
    var rows = try db.exec("WITH active AS (SELECT id, name FROM cte_users) SELECT * FROM active;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-24-ctes`