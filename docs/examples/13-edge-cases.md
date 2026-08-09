---
title: "Edge Cases"
description: "NULL handling, savepoints, and error cases"
---

# Edge Cases

Handle NULL values, savepoints, and other edge cases.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("edge_items", struct { id: i64, label: ?[]const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_13.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true, .primary_key = Item.key("id") });
    try db.truncate(Item);
    var first = try db.from(Item).insert(.{ .id = 1, .label = "alpha" });
    first.deinit();
    var nulls = try db.exec("INSERT INTO edge_items (id, label) VALUES (2, NULL), (3, NULL);");
    nulls.deinit();
    try db.begin();
    var rolled = try db.from(Item).insert(.{ .id = 4, .label = "rolled-back" });
    rolled.deinit();
    try db.rollback();
    var result = try db.from(Item).where(Item.column("label").isNull()).fetchAll();
    result.deinit();
}
```

> [!TIP]
> Run with: `zig build run-13-edge-cases`