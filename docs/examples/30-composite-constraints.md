---
title: "Composite Table Constraints"
description: "Define composite PRIMARY KEY and UNIQUE constraints using both raw SQL and typed DSL."
---

# Composite Table Constraints

Define composite PRIMARY KEY and UNIQUE constraints using both raw SQL and typed DSL.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS raw_composite_items (left_id INTEGER, right_id INTEGER, label TEXT, PRIMARY KEY (left_id, right_id), UNIQUE (right_id, label)) | Creates table with raw composite constraints |
| 2 | DELETE FROM raw_composite_items | Clears the table |
| 3 | INSERT INTO raw_composite_items VALUES (1, 10, 'alpha') | Inserts first row |
| 4 | INSERT INTO raw_composite_items VALUES (1, 10, 'duplicate') | Fails - duplicate PK |
| 5 | CREATE TABLE IF NOT EXISTS typed_composite_memberships (... PRIMARY KEY (user_id, group_id), UNIQUE (group_id, label)) | Creates table with typed constraints |
| 6 | INSERT INTO typed_composite_memberships VALUES (1, 10, 'alpha') | Inserts first membership |
| 7 | INSERT INTO typed_composite_memberships VALUES (1, 10, 'duplicate') | Fails - duplicate PK |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const MembershipRow = struct { user_id: i64, group_id: i64, label: []const u8 };
const Membership = sqlite.table("typed_composite_memberships", MembershipRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_30.db");
    defer db.close();

    var rawSetup = try db.exec("CREATE TABLE IF NOT EXISTS raw_composite_items (left_id INTEGER, right_id INTEGER, label TEXT, PRIMARY KEY (left_id, right_id), UNIQUE (right_id, label));");
    rawSetup.deinit();
    var rawClear = try db.exec("DELETE FROM raw_composite_items;");
    rawClear.deinit();
    var rawInsert = try db.exec("INSERT INTO raw_composite_items VALUES (1, 10, 'alpha');");
    rawInsert.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO raw_composite_items VALUES (1, 10, 'duplicate');"));

    try db.createTable(Membership, .{ .ifNotExists = true, .primaryKey = &.{ Membership.columns.user_id, Membership.columns.group_id }, .unique = &.{&.{ Membership.columns.group_id, Membership.columns.label }} });
    try db.truncate(Membership);
    var typed = try db.from(Membership).insert(.{ .user_id = 1, .group_id = 10, .label = "alpha" });
    typed.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Membership).insert(.{ .user_id = 1, .group_id = 10, .label = "duplicate" }));
    std.debug.print("30 composite constraints: raw and typed PRIMARY KEY/UNIQUE verified\n", .{});
}
```

## Database State After Execution

**raw_composite_items:**

| left_id | right_id | label |
|---------|----------|-------|
| 1 | 10 | alpha |

**typed_composite_memberships:**

| user_id | group_id | label |
|---------|----------|-------|
| 1 | 10 | alpha |

## Zig Output

```
30 composite constraints: raw and typed PRIMARY KEY/UNIQUE verified
```

> [!TIP]
> Run with: `zig build run-30_composite_table_constraints`
