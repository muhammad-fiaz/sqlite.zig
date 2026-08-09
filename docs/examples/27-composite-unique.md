---
title: "Composite Unique Keys"
description: "Define multi-column UNIQUE indexes to enforce uniqueness across combinations of columns."
---

# Composite Unique Keys

Define multi-column UNIQUE indexes to enforce uniqueness across combinations of columns.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS composite_memberships (id INTEGER PRIMARY KEY, user_id INTEGER, group_id INTEGER) | Creates memberships table |
| 2 | DELETE FROM composite_memberships | Truncates the table |
| 3 | CREATE UNIQUE INDEX membership_user_group ON composite_memberships (user_id, group_id) | Creates composite unique index |
| 4 | INSERT INTO composite_memberships VALUES (1, 10, 20) | Inserts first membership |
| 5 | INSERT INTO composite_memberships VALUES (2, 10, 20) | Fails - duplicate (user_id, group_id) |
| 6 | INSERT INTO composite_memberships VALUES (3, 10, 21) | Succeeds - different group_id |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const MembershipRow = struct { id: i64, user_id: i64, group_id: i64 };
const Membership = sqlite.table("composite_memberships", MembershipRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_27.db");
    defer db.close();
    try db.createTable(Membership, .{ .if_not_exists = true, .primary_key = Membership.key("id") });
    try db.truncate(Membership);
    db.dropIndex("membership_user_group") catch {};
    try db.createIndex(Membership, "membership_user_group", &.{ Membership.key("user_id"), Membership.key("group_id") }, true);

    var first = try db.from(Membership).insertTyped(.{ .id = 1, .user_id = 10, .group_id = 20 });
    first.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Membership).insertTyped(.{ .id = 2, .user_id = 10, .group_id = 20 }));
    var different_group = try db.from(Membership).insertTyped(.{ .id = 3, .user_id = 10, .group_id = 21 });
    different_group.deinit();
    std.debug.print("27 composite keys: typed multi-column UNIQUE index verified\n", .{});
}
```

## Database State After Execution

| id | user_id | group_id |
|----|---------|----------|
| 1 | 10 | 20 |
| 3 | 10 | 21 |

## Zig Output

```
27 composite keys: typed multi-column UNIQUE index verified
```

> [!TIP]
> Run with: `zig build run-27_composite_unique_keys`
