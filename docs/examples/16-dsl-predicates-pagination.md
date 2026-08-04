---
title: "Predicates & Pagination"
description: "WHERE predicates with LIMIT/OFFSET"
---

# Predicates & Pagination

Use WHERE predicates with LIMIT and OFFSET for pagination.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("page_items", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_16.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true });
    try db.truncate(Item);
    var i = 0;
    while (i < 20) : (i += 1) {
        var ins = try db.from(Item).insert(.{ .id = @intCast(i), .name = "item" });
        ins.deinit();
    }
    var page = try db.from(Item).where(Item.column("id").gte(10)).limit(5).fetchAll();
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 5), page.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-16-dsl-predicates-pagination`