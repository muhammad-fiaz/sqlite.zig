---
title: "DSL CRUD"
description: "Full CRUD operations via typed DSL"
---

# DSL CRUD

Perform full Create, Read, Update, Delete operations using the typed DSL.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("dsl_users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_09.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true });
    try db.truncate(User);
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();
    var result = try db.from(User).fetchAll();
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
    var updated = try db.from(User).where(User.column("id").eq(1)).update(.{ .name = "Bob" });
    updated.deinit();
    var deleted = try db.from(User).where(User.column("id").eq(1)).delete();
    deleted.deinit();
}
```

> [!TIP]
> Run with: `zig build run-09-dsl-crud`