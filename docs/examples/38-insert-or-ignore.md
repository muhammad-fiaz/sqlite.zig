---
title: INSERT OR IGNORE
description: Use INSERT OR IGNORE to silently skip rows that cause uniqueness conflicts.
---

# INSERT OR IGNORE

This example shows how `INSERT OR IGNORE` handles primary key conflicts. When a conflicting row is encountered, it is silently skipped rather than raising an error, while non-conflicting rows are still inserted.

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

> [!TIP]
> Run with: `zig build run-38_insert_or_ignore`
