---
title: "Prepared Statements"
description: "Use prepared statements with parameter binding"
---

# Prepared Statements

Use prepared statements to safely execute SQL with parameter binding.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_02.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS items (id INTEGER, name TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO items VALUES (1, 'widget');");
    result.deinit();
    var rows = try db.exec("SELECT * FROM items WHERE id = 1;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-02-prepared-statement`