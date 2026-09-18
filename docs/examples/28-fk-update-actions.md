---
title: "Foreign Key Update Actions"
description: "Demonstrate ON UPDATE CASCADE, SET NULL, and RESTRICT behaviors for foreign key constraints."
---

# Foreign Key Update Actions

Demonstrate ON UPDATE CASCADE, SET NULL, and RESTRICT behaviors for foreign key constraints.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS update_parents (id INTEGER PRIMARY KEY, name TEXT) | Creates parents table |
| 2 | CREATE TABLE IF NOT EXISTS update_cascade_children (... ON UPDATE CASCADE) | Creates cascade children |
| 3 | CREATE TABLE IF NOT EXISTS update_nullable_children (... ON UPDATE SET NULL) | Creates nullable children |
| 4 | CREATE TABLE IF NOT EXISTS update_restricted_children (... ON UPDATE RESTRICT) | Creates restricted children |
| 5 | INSERT INTO update_parents VALUES (1, 'parent') | Inserts parent |
| 6 | INSERT INTO update_cascade_children VALUES (1, 1) | Inserts cascade child |
| 7 | INSERT INTO update_nullable_children VALUES (1, 1) | Inserts nullable child |
| 8 | UPDATE update_parents SET id = 2 WHERE id = 1 | Updates parent id (cascades) |
| 9 | SELECT * FROM update_cascade_children | Verifies cascade updated child |
| 10 | SELECT * FROM update_nullable_children | Verifies set null cleared FK |
| 11 | INSERT INTO update_parents VALUES (3, 'restricted') | Inserts restricted parent |
| 12 | INSERT INTO update_restricted_children VALUES (1, 3) | Inserts restricted child |
| 13 | UPDATE update_parents SET id = 4 WHERE id = 3 | Fails due to RESTRICT |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const ParentRow = struct { id: i64, name: []const u8 };
const CascadeChildRow = struct { id: i64, parent_id: i64 };
const NullableChildRow = struct { id: i64, parent_id: ?i64 };
const RestrictedChildRow = struct { id: i64, parent_id: i64 };
const Parent = sqlite.table("update_parents", ParentRow);
const CascadeChild = sqlite.table("update_cascade_children", CascadeChildRow);
const NullableChild = sqlite.table("update_nullable_children", NullableChildRow);
const RestrictedChild = sqlite.table("update_restricted_children", RestrictedChildRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_28.db");
    defer db.close();
    try db.createTable(Parent, .{ .ifNotExists = true, .primaryKey = Parent.columns.id });
    try db.createTable(CascadeChild, .{ .ifNotExists = true, .primaryKey = CascadeChild.columns.id, .foreignKeys = &.{.{ .column = CascadeChild.columns.parent_id, .references = Parent.columns.id, .onUpdate = .cascade }} });
    try db.createTable(NullableChild, .{ .ifNotExists = true, .primaryKey = NullableChild.columns.id, .foreignKeys = &.{.{ .column = NullableChild.columns.parent_id, .references = Parent.columns.id, .onUpdate = .setNull }} });
    try db.createTable(RestrictedChild, .{ .ifNotExists = true, .primaryKey = RestrictedChild.columns.id, .foreignKeys = &.{.{ .column = RestrictedChild.columns.parent_id, .references = Parent.columns.id, .onUpdate = .restrict }} });
    try db.truncate(RestrictedChild);
    try db.truncate(NullableChild);
    try db.truncate(CascadeChild);
    try db.truncate(Parent);

    var parent = try db.from(Parent).insert(.{ .id = 1, .name = "parent" });
    parent.deinit();
    var cascade = try db.from(CascadeChild).insert(.{ .id = 1, .parent_id = 1 });
    cascade.deinit();
    var nullable = try db.from(NullableChild).insert(.{ .id = 1, .parent_id = 1 });
    nullable.deinit();
    var update = try db.from(Parent).update(.{ .id = 2 });
    var result = try update.where(Parent.columns.id.eq(1)).execute();
    result.deinit();

    var child = try db.from(CascadeChild).selectAll().fetch();
    defer child.deinit();
    if (child.rows[0].parent_id != 2) return error.CascadeUpdateVerificationFailed;
    var cleared = try db.from(NullableChild).selectAll().fetch();
    defer cleared.deinit();
    if (cleared.rows[0].parent_id != null) return error.SetNullUpdateVerificationFailed;

    var restrictedParent = try db.from(Parent).insert(.{ .id = 3, .name = "restricted" });
    restrictedParent.deinit();
    var restrictedChild = try db.from(RestrictedChild).insert(.{ .id = 1, .parent_id = 3 });
    restrictedChild.deinit();
    var blocked = try db.from(Parent).update(.{ .id = 4 });
    try std.testing.expectError(error.ConstraintViolation, blocked.where(Parent.columns.id.eq(3)).execute());
    std.debug.print("28 foreign keys: ON UPDATE CASCADE, SET NULL, and RESTRICT verified\n", .{});
}
```

## Database State After Execution

**update_parents:**

| id | name |
|----|------|
| 2 | parent |
| 3 | restricted |

**update_cascade_children:**

| id | parent_id |
|----|-----------|
| 1 | 2 |

**update_nullable_children:**

| id | parent_id |
|----|-----------|
| 1 | NULL |

**update_restricted_children:**

| id | parent_id |
|----|-----------|
| 1 | 3 |

## Zig Output

```
28 foreign keys: ON UPDATE CASCADE, SET NULL, and RESTRICT verified
```

> [!TIP]
> Run with: `zig build run-28_foreign_key_update_actions`
