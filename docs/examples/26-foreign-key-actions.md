---
title: "FK Actions"
description: "CASCADE DELETE and SET NULL"
---

# FK Actions

Use foreign key actions like CASCADE DELETE and SET NULL.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Parent = sqlite.table("fk_parent", struct { id: i64, name: []const u8 });
const Child = sqlite.table("fk_child", struct { id: i64, parent_id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_26.db");
    defer db.close();
    try db.createTable(Parent, .{ .if_not_exists = true, .primary_key = Parent.key("id") });
    try db.createTable(Child, .{
        .if_not_exists = true,
        .primary_key = Child.key("id"),
        .foreign_key_constraints = &.{.{
            .columns = &.{Child.key("parent_id")},
            .referenced_table = "fk_parent",
            .referenced_columns = &.{Parent.key("id")},
            .on_delete = .cascade,
        }},
    });
    try db.truncate(Child);
    try db.truncate(Parent);
    var p = try db.from(Parent).insert(.{ .id = 1, .name = "Parent1" });
    p.deinit();
    var c = try db.from(Child).insert(.{ .id = 10, .parent_id = 1 });
    c.deinit();
    var deleted = try db.from(Parent).where(Parent.column("id").eq(1)).delete();
    deleted.deinit();
    var count = try db.from(Child).count("id").fetchAll();
    defer count.deinit();
    try std.testing.expectEqual(@as(i64, 0), count.rows[0][0].integer);
}
```

> [!TIP]
> Run with: `zig build run-26-foreign-key-actions`