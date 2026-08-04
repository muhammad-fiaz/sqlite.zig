---
title: "Views"
description: "CREATE VIEW with typed DSL reads"
---

# Views

Create and query views using CREATE VIEW.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_22.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS view_users (id INTEGER, name TEXT, active INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO view_users VALUES (1, 'Alice', 1), (2, 'Bob', 0);");
    result.deinit();
    result = try db.exec("CREATE VIEW IF NOT EXISTS active_view AS SELECT id, name FROM view_users WHERE active = 1;");
    result.deinit();
    var rows = try db.exec("SELECT * FROM active_view;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-22-views`