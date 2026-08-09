---
title: "Complex Queries"
description: "DISTINCT joins and aggregate functions"
---

# Complex Queries

Use DISTINCT joins and aggregate functions for complex queries.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("complex_users", struct { id: i64, name: []const u8 });
const Order = sqlite.table("complex_orders", struct { id: i64, user_id: i64, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_12.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key = User.key("id") });
    try db.createTable(Order, .{ .if_not_exists = true, .primary_key = Order.key("id") });
    try db.truncate(Order);
    try db.truncate(User);
    var user_a = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    user_a.deinit();
    var order_a = try db.from(Order).insert(.{ .id = 10, .user_id = 1, .amount = 25 });
    order_a.deinit();
    var dsl = try db.from(User).innerJoin(Order, "id", "user_id").select("*").distinct().fetchAll();
    dsl.deinit();
    var aggregate = try db.from(Order).sum("amount").fetchAll();
    aggregate.deinit();
}
```

> [!TIP]
> Run with: `zig build run-12-complex-queries`