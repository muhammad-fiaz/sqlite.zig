---
title: "Repair Legacy"
description: "Repair and legacy database handling"
---

# Repair Legacy

Handle legacy databases and repair operations.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_08.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS legacy (id INTEGER, data TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO legacy VALUES (1, 'restored');");
    result.deinit();
    var rows = try db.exec("SELECT * FROM legacy;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-08-repair-legacy`