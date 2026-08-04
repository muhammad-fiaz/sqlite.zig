---
title: "Prepared Parameters"
description: "Typed parameter binding"
---

# Prepared Parameters

Use typed parameter binding for safe and efficient queries.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("param_users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_19.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true });
    try db.truncate(User);
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();
    var result = try db.from(User).where(User.column("id").eq(1)).fetchAll();
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-19-prepared-parameter`