---
title: "Literal IN Lists"
description: "Use IN lists with literal values for membership testing in raw SQL and typed DSL."
---

# Literal IN Lists

Use IN lists with literal values for membership testing in raw SQL and typed DSL.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS literal_in_items (id INTEGER, label TEXT) | Creates items table |
| 2 | DELETE FROM literal_in_items | Truncates the table |
| 3 | INSERT INTO literal_in_items VALUES (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four') | Inserts four rows |
| 4 | SELECT id FROM literal_in_items WHERE id IN (1, 3, 4) ORDER BY id | Raw IN list query |
| 5 | SELECT id FROM literal_in_items WHERE id NOT IN (1, 3, 4) | Typed DSL whereNotInValues |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("literal_in_items", struct { id: i64, label: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_45.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true });
    try db.truncate(Item);
    var result = try db.exec("INSERT INTO literal_in_items VALUES (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four');");
    result.deinit();
    var raw = try db.exec("SELECT id FROM literal_in_items WHERE id IN (1, 3, 4) ORDER BY id;");
    defer raw.deinit();
    if (raw.rowCount() != 3) return error.RawInListVerificationFailed;
    var typed = try db.from(Item).whereNotInValues(Item.key("id"), .{ 1, 3, 4 }).fetchAll();
    defer typed.deinit();
    if (typed.rowCount() != 1 or typed.rows[0][0].integer != 2) return error.TypedInListVerificationFailed;
    std.debug.print("45 literal IN lists: raw and typed membership verified\n", .{});
}
```

## Database State After Execution

**literal_in_items:**

| id | label |
|----|-------|
| 1 | one |
| 2 | two |
| 3 | three |
| 4 | four |

**Raw IN query result (id IN 1, 3, 4):**

| id |
|----|
| 1 |
| 3 |
| 4 |

**Typed NOT IN result (id NOT IN 1, 3, 4):**

| id |
|----|
| 2 |

## Zig Output

```
45 literal IN lists: raw and typed membership verified
```

> [!TIP]
> Run with: `zig build run-45_literal_in_lists`
