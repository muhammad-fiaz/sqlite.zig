---
title: "FK Update Actions"
description: "CASCADE UPDATE and SET DEFAULT"
---

# FK Update Actions

Use foreign key update actions like CASCADE UPDATE and SET DEFAULT.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Parent = sqlite.table("fk_upd_parent", struct { id: i64, name: []const u8 });
const Child = sqlite.table("fk_upd_child", struct { id: i64, parent_id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_28.db");
    defer db.close();
    try db.createTable(Parent, .{ .if_not_exists = true, .primary_key_key = Parent.key("id") });
    try db.createTable(Child, .{
        .if_not_exists = true,
        .primary_key_key = Child.key("id"),
        .foreign_key_constraints = &.{.{
            .columns = &.{Child.key("parent_id")},
            .referenced_table = "fk_upd_parent",
            .referenced_columns = &.{Parent.key("id")},
            .on_update = .cascade,
        }},
    });
    try db.truncate(Child);
    try db.truncate(Parent);
    var p = try db.from(Parent).insert(.{ .id = 1, .name = "Parent1" });
    p.deinit();
    var c = try db.from(Child).insert(.{ .id = 10, .parent_id = 1 });
    c.deinit();
    var updated = try db.from(Parent).where(Parent.column("id").eq(1)).update(.{ .id = 2 });
    updated.deinit();
    var result = try db.from(Child).fetchAll();
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 2), result.rows[0][1].integer);
}
```

> [!TIP]
> Run with: `zig build run-28-fk-update-actions`