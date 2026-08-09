---
title: "UPSERT DO NOTHING"
description: "Use INSERT ... ON CONFLICT DO NOTHING to skip conflicting rows without error."
---

# UPSERT DO NOTHING

Use INSERT ... ON CONFLICT DO NOTHING to skip conflicting rows without error.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS upsert_items (id INTEGER PRIMARY KEY, label TEXT) | Creates items table |
| 2 | DELETE FROM upsert_items | Truncates the table |
| 3 | INSERT INTO upsert_items VALUES (1, 'original') | Inserts original row |
| 4 | INSERT INTO upsert_items VALUES (1, 'duplicate'), (2, 'accepted') ON CONFLICT(id) DO NOTHING | Skips conflict, inserts new |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("upsert_items", struct { id: i64, label: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_39.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true, .primary_key = Item.key("id") });
    try db.truncate(Item);
    var original = try db.from(Item).insert(.{ .id = 1, .label = "original" });
    original.deinit();
    var result = try db.exec("INSERT INTO upsert_items VALUES (1, 'duplicate'), (2, 'accepted') ON CONFLICT(id) DO NOTHING;");
    defer result.deinit();
    if (result.changes != 1) return error.UpsertDoNothingVerificationFailed;
    std.debug.print("39 UPSERT DO NOTHING: conflict target and accepted row verified\n", .{});
}
```

## Database State After Execution

| id | label |
|----|-------|
| 1 | original |
| 2 | accepted |

## Zig Output

```
39 UPSERT DO NOTHING: conflict target and accepted row verified
```

> [!TIP]
> Run with: `zig build run-39_upsert_do_nothing`
