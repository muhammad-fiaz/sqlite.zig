---
title: "Composite Constraints"
description: "Composite PRIMARY KEY and UNIQUE"
---

# Composite Constraints

Use composite PRIMARY KEY and UNIQUE constraints for multi-column keys.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Membership = sqlite.table("membership", struct { user_id: i64, group_id: i64, role: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_30.db");
    defer db.close();
    try db.createTable(Membership, .{
        .if_not_exists = true,
        .primary_keys = &.{ Membership.key("user_id"), Membership.key("group_id") },
    });
    var inserted = try db.from(Membership).insert(.{ .user_id = 1, .group_id = 10, .role = "admin" });
    inserted.deinit();
    var result = try db.from(Membership).fetchAll();
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-30-composite-constraints`