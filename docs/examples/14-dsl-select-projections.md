---
title: "Select Projections"
description: "SELECT field projections with selectFields()"
---

# Select Projections

Use selectFields() to project specific columns in SELECT queries.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("proj_users", struct { id: i64, name: []const u8, email: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_14.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true });
    try db.truncate(User);
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice", .email = "a@test.com" });
    inserted.deinit();
    var result = try db.from(User).selectFields(&.{ "id", "name" }).fetchAll();
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-14-dsl-select-projections`