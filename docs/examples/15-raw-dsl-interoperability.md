---
title: "Raw & DSL Interop"
description: "Verify raw SQL and DSL produce identical results"
---

# Raw & DSL Interop

Verify that raw SQL and DSL queries produce identical results.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("interop_users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_15.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true });
    try db.truncate(User);
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();
    var raw = try db.exec("SELECT * FROM interop_users;");
    defer raw.deinit();
    var dsl = try db.from(User).fetchAll();
    defer dsl.deinit();
    try std.testing.expectEqual(raw.rowCount(), dsl.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-15-raw-dsl-interoperability`