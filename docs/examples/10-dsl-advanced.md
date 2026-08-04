---
title: "DSL Advanced"
description: "Advanced DSL queries and predicates"
---

# DSL Advanced

Use advanced DSL queries and predicates for complex operations.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Account = sqlite.table("dsl_accounts", struct { id: i64, owner: []const u8, balance: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_10.db");
    defer db.close();
    try db.createTable(Account, .{ .if_not_exists = true });
    try db.truncate(Account);
    var a = try db.from(Account).insert(.{ .id = 1, .owner = "Alice", .balance = 100 });
    a.deinit();
    var b = try db.from(Account).insert(.{ .id = 2, .owner = "Bob", .balance = 200 });
    b.deinit();
    var filtered = try db.from(Account).where(Account.column("balance").gt(150)).fetchAll();
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-10-dsl-advanced`