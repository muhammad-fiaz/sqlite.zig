---
title: "Indexed Queries"
description: "Index creation and optimized lookups"
---

# Indexed Queries

Create indexes for optimized query performance.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("idx_users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_21.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key_key = User.key("id") });
    try db.truncate(User);
    var result = try db.exec("CREATE INDEX IF NOT EXISTS idx_name ON idx_users (name);");
    result.deinit();
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();
    var rows = try db.from(User).where(User.column("name").eq("Alice")).fetchAll();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-21-indexed-queries`