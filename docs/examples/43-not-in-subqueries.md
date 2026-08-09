---
title: NOT IN Subqueries
description: Use NOT IN with subqueries to filter rows not present in another table.
---

# NOT IN Subqueries

This example demonstrates using `NOT IN` with a subquery (or the equivalent DSL method) to exclude rows that appear in another table. It selects only users whose IDs are not in the blocked list.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("not_in_users", struct { id: i64 });
const Blocked = sqlite.table("not_in_blocked", struct { user_id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_43.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true });
    try db.createTable(Blocked, .{ .if_not_exists = true });
    try db.truncate(User);
    try db.truncate(Blocked);
    var a = try db.from(User).insert(.{ .id = 1 });
    a.deinit();
    var b = try db.from(User).insert(.{ .id = 2 });
    b.deinit();
    var blocked = try db.from(Blocked).insert(.{ .user_id = 2 });
    blocked.deinit();
    var rows = try db.from(User).whereNotInColumn(User.key("id"), Blocked, Blocked.key("user_id")).fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1 or rows.rows[0][0].integer != 1) return error.NotInVerificationFailed;
    std.debug.print("43 NOT IN: raw-compatible anti-subquery DSL verified\n", .{});
}
```

> [!TIP]
> Run with: `zig build run-43_not_in_subqueries`
