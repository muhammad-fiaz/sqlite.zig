---
title: "Foreign Key Actions"
description: "Demonstrate CASCADE delete behavior with foreign key constraints between parent and child tables."
---

# Foreign Key Actions

Demonstrate CASCADE delete behavior with foreign key constraints between parent and child tables.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS cascade_parents (id INTEGER PRIMARY KEY, name TEXT) | Creates parents table |
| 2 | CREATE TABLE IF NOT EXISTS cascade_children (id INTEGER PRIMARY KEY, parent_id INTEGER, FOREIGN KEY (parent_id) REFERENCES cascade_parents(id) ON DELETE CASCADE) | Creates children with CASCADE delete |
| 3 | DELETE FROM cascade_children | Truncates children |
| 4 | DELETE FROM cascade_parents | Truncates parents |
| 5 | INSERT INTO cascade_parents VALUES (1, 'parent') | Inserts parent row |
| 6 | INSERT INTO cascade_children VALUES (1, 1) | Inserts child linked to parent |
| 7 | DELETE FROM cascade_parents WHERE id = 1 | Deletes parent (cascades to children) |
| 8 | SELECT * FROM cascade_children | Verifies children were cascade-deleted |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const ParentRow = struct { id: i64, name: []const u8 };
const ChildRow = struct { id: i64, parent_id: i64 };
const Parent = sqlite.table("cascade_parents", ParentRow);
const Child = sqlite.table("cascade_children", ChildRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_26.db");
    defer db.close();
    try db.createTable(Parent, .{ .if_not_exists = true, .primary_key = Parent.key("id") });
    try db.createTable(Child, .{ .if_not_exists = true, .primary_key = Child.key("id"), .foreign_keys = &.{.{ .table = "cascade_parents", .referenced_column = "id", .column_key = Child.key("parent_id"), .on_delete = .cascade }} });
    try db.truncate(Child);
    try db.truncate(Parent);
    var parent = try db.from(Parent).insertTyped(.{ .id = 1, .name = "parent" });
    parent.deinit();
    var child = try db.from(Child).insertTyped(.{ .id = 1, .parent_id = 1 });
    child.deinit();
    var deleted = db.from(Parent).delete().where(Parent.column("id").eq(1));
    var result = try deleted.execute();
    deleted.deinit();
    result.deinit();
    var remaining = try db.from(Child).selectAll().fetchAll();
    defer remaining.deinit();
    if (remaining.rowCount() != 0) return error.CascadeVerificationFailed;
    std.debug.print("26 foreign keys: typed CASCADE delete verified\n", .{});
}
```

## Database State After Execution

**cascade_parents:**

| id | name |
|----|------|
| *(empty)* | *(empty)* |

**cascade_children:**

| id | parent_id |
|----|-----------|
| *(empty)* | *(empty)* |

Both tables are empty because the parent delete cascaded to delete the child.

## Zig Output

```
26 foreign keys: typed CASCADE delete verified
```

> [!TIP]
> Run with: `zig build run-26_foreign_key_actions`
