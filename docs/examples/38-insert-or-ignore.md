---
title: "INSERT OR IGNORE"
description: "Use INSERT OR IGNORE to skip conflicting rows while inserting new data."
---

# INSERT OR IGNORE

Use INSERT OR IGNORE to skip conflicting rows while inserting new data.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS ignore_items (id INTEGER PRIMARY KEY, label TEXT) | Creates items table with PK |
| 2 | DELETE FROM ignore_items | Truncates the table |
| 3 | INSERT INTO ignore_items VALUES (1, 'original') | Inserts original row |
| 4 | INSERT OR IGNORE INTO ignore_items VALUES (1, 'duplicate'), (2, 'accepted') | Skips duplicate, inserts new |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("ignore_items", struct { id: i64, label: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_38.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true, .primary_key = Item.key("id") });
    try db.truncate(Item);
    var original = try db.from(Item).insert(.{ .id = 1, .label = "original" });
    original.deinit();
    var result = try db.exec("INSERT OR IGNORE INTO ignore_items VALUES (1, 'duplicate'), (2, 'accepted');");
    defer result.deinit();
    if (result.changes != 1) return error.InsertOrIgnoreVerificationFailed;
    std.debug.print("38 INSERT OR IGNORE: conflicts skipped and accepted rows inserted\n", .{});
}
```

## Database State After Execution

| id | label |
|----|-------|
| 1 | original |
| 2 | accepted |

## Zig Output

```
38 INSERT OR IGNORE: conflicts skipped and accepted rows inserted
```

> [!TIP]
> Run with: `zig build run-38_insert_or_ignore`
