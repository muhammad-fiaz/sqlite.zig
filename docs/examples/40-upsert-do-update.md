---
title: UPSERT DO UPDATE
description: Use INSERT ... ON CONFLICT DO UPDATE to merge new values into conflicting rows.
---

# UPSERT DO UPDATE

This example demonstrates the `ON CONFLICT DO UPDATE` upsert clause. When a conflict is found, the existing row is updated with values from the `excluded` pseudo-table, allowing you to merge or transform data.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("upsert_update_items", struct { id: i64, label: []const u8, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_40.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true, .primary_key = Item.key("id") });
    try db.truncate(Item);
    var original = try db.from(Item).insert(.{ .id = 1, .label = "original", .amount = 10 });
    original.deinit();
    var result = try db.exec("INSERT INTO upsert_update_items VALUES (1, 'updated', 99) ON CONFLICT(id) DO UPDATE SET label = excluded.label, amount = excluded.amount + 1;");
    defer result.deinit();
    var rows = try db.from(Item).selectAll().fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1 or !std.mem.eql(u8, rows.rows[0][1].text, "updated") or rows.rows[0][2].integer != 100) return error.UpsertUpdateVerificationFailed;
    std.debug.print("40 UPSERT DO UPDATE: conflicting row updated and verified\n", .{});
}
```

> [!TIP]
> Run with: `zig build run-40_upsert_do_update`
