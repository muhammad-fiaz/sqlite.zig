---
title: "Keys & Joins"
description: "Primary keys, foreign keys, and JOIN queries"
---

# Keys & Joins

Work with primary keys, foreign keys, and JOIN queries.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("relation_users", struct { id: i64, email: []const u8 });
const Order = sqlite.table("relation_orders", struct { id: i64, user_id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_11.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key_key = User.key("id") });
    try db.createTable(Order, .{ .if_not_exists = true, .primary_key_key = Order.key("id") });
    try db.truncate(Order);
    try db.truncate(User);
    var u = try db.from(User).insert(.{ .id = 1, .email = "a@test.com" });
    u.deinit();
    var o = try db.from(Order).insert(.{ .id = 10, .user_id = 1 });
    o.deinit();
    var joined = try db.from(User).innerJoin(Order, "id", "user_id").select("*").fetchAll();
    defer joined.deinit();
    try std.testing.expectEqual(@as(usize, 1), joined.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-11-keys-and-joins`