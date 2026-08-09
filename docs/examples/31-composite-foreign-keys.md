---
title: "Composite FKs"
description: "Composite foreign keys"
---

# Composite FKs

Use composite foreign keys to reference multiple columns.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Parent = sqlite.table("comp_parent", struct { a: i64, b: i64 });
const Child = sqlite.table("comp_child", struct { id: i64, parent_a: i64, parent_b: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_31.db");
    defer db.close();
    try db.createTable(Parent, .{
        .if_not_exists = true,
        .primary_keys = &.{ Parent.key("a"), Parent.key("b") },
    });
    try db.createTable(Child, .{
        .if_not_exists = true,
        .primary_key = Child.key("id"),
        .foreign_key_constraints = &.{.{
            .columns = &.{ Child.key("parent_a"), Child.key("parent_b") },
            .referenced_table = "comp_parent",
            .referenced_columns = &.{ Parent.key("a"), Parent.key("b") },
            .on_delete = .cascade,
        }},
    });
    var p = try db.from(Parent).insert(.{ .a = 1, .b = 2 });
    p.deinit();
    var c = try db.from(Child).insert(.{ .id = 10, .parent_a = 1, .parent_b = 2 });
    c.deinit();
    var result = try db.from(Child).fetchAll();
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-31-composite-foreign-keys`