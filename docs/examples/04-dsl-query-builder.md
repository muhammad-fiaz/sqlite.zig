---
title: "DSL Query Builder"
description: "Type-safe comptime query builder basics"
---

# DSL Query Builder

Use the type-safe comptime query builder for basic operations.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_04.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true });
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();
    var result = try db.from(User).fetchAll();
    defer result.deinit();
    std.debug.print("Rows: {d}\n", .{result.rowCount()});
}
```

> [!TIP]
> Run with: `zig build run-04-dsl-query-builder`