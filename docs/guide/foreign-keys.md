---
title: "Foreign Keys"
description: "Foreign key constraints with CASCADE, SET NULL, and RESTRICT actions, single and composite."
---

# Foreign Keys

`sqlite.zig` supports foreign key constraints with the referential actions
the engine implements. Typed keys derive both table names from the column
descriptors; dynamic keys use runtime strings.

## Basic Foreign Key

```zig
const User = sqlite.table("users", struct { id: i64, name: []const u8 });
const Order = sqlite.table("orders", struct { id: i64, user_id: i64, amount: i64 });

try db.createTable(User, .{
    .primaryKey = User.id,
});

try db.createTable(Order, .{
    .primaryKey = Order.id,
    .foreignKeys = &.{.{
        .column = Order.user_id,
        .references = User.id,
        .onDelete = .cascade,
        .onUpdate = .cascade,
    }},
});
```

Dynamic equivalent (no structs):

```zig
try db.createTable("orders", .{
    .columns = &.{
        .{ .name = "id", .type = "INTEGER" },
        .{ .name = "user_id", .type = "INTEGER" },
    },
    .foreignKeys = &.{.{
        .column = "user_id",
        .references = .{ .table = "users", .column = "id" },
        .onDelete = .cascade,
    }},
});
```

## Referential Actions

| Action | Behavior |
|--------|----------|
| `.cascade` | Delete/update matching rows in the child table |
| `.setNull` | Set foreign key columns to NULL |
| `.setDefault` | Set foreign key columns to their column defaults |
| `.restrict` | Reject the delete/update if children exist (default) |
| `.noAction` | Reject at statement end if children exist |

## Composite Foreign Keys

```zig
try db.createTable(Child, .{
    .primaryKey = Child.id,
    .foreignKeys = &.{.{
        .columns = &.{ Child.parent_a, Child.parent_b },
        .references = &.{ Parent.a, Parent.b },
        .onDelete = .cascade,
        .onUpdate = .cascade,
    }},
});
```

## CASCADE DELETE Example

When a user is deleted, all their orders are automatically deleted:

```zig
try db.begin();
var result = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
result.deinit();
result = try db.from(Order).insert(.{ .id = 1, .user_id = 1, .amount = 100 });
result.deinit();
try db.commit();

// Delete the user; orders are cascade-deleted
try db.begin();
var deleted = try db.from(User).delete().where(User.id.eq(1)).execute();
deleted.deinit();
try db.commit();

// Order count is now 0
var count = try db.from(Order).select(.{Order.id.count()}).fetch();
defer count.deinit();
```

## Raw SQL

```zig
var result = try db.exec(
    \\CREATE TABLE orders (
    \\  id INTEGER PRIMARY KEY,
    \\  user_id INTEGER,
    \\  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    \\)
);
result.deinit();
```
