---
title: UPSERT DO NOTHING
description: Use INSERT ... ON CONFLICT DO NOTHING to skip conflicting rows in a targeted way.
---

# UPSERT DO NOTHING

This example demonstrates the `ON CONFLICT DO NOTHING` upsert clause. Unlike `INSERT OR IGNORE`, this targets a specific conflict column. Conflicting rows are skipped while non-conflicting rows proceed.

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

> [!TIP]
> Run with: `zig build run-39_upsert_do_nothing`
