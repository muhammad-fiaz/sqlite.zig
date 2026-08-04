# Foreign Keys

`sqlite.zig` supports foreign key constraints with referential actions.

## Basic Foreign Key

```zig
const User = sqlite.table("users", struct { id: i64, name: []const u8 });
const Order = sqlite.table("orders", struct { id: i64, user_id: i64, amount: i64 });

try db.createTable(User, .{
    .if_not_exists = true,
    .primary_key_key = User.key("id"),
});

try db.createTable(Order, .{
    .if_not_exists = true,
    .primary_key_key = Order.key("id"),
    .foreign_key_constraints = &.{.{
        .columns = &.{Order.key("user_id")},
        .referenced_table = "users",
        .referenced_columns = &.{User.key("id")},
        .on_delete = .cascade,
        .on_update = .cascade,
    }},
});
```

## Referential Actions

| Action | Behavior |
|--------|----------|
| `CASCADE` | Delete/Update matching rows in child table |
| `SET NULL` | Set foreign key columns to NULL |
| `SET DEFAULT` | Set foreign key columns to default value |
| `RESTRICT` | Reject the delete/update if children exist |
| `NO ACTION` | Do nothing (default) |

## Composite Foreign Keys

```zig
try db.createTable(Child, .{
    .primary_key_key = Child.key("id"),
    .foreign_key_constraints = &.{.{
        .columns = &.{Child.key("parent_a"), Child.key("parent_b")},
        .referenced_table = "parents",
        .referenced_columns = &.{Parent.key("a"), Parent.key("b")},
        .on_delete = .cascade,
        .on_update = .cascade,
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

// Delete the user — orders are cascade-deleted
try db.begin();
var deleted = try db.from(User).where(User.column("id").eq(1)).delete();
deleted.deinit();
try db.commit();

// Order count is now 0
var count = try db.from(Order).count("id").fetchAll();
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
