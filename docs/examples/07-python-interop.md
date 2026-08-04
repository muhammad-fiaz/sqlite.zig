---
title: "Python Interop"
description: "Interop with Python sqlite3 module"
---

# Python Interop

Interoperate with Python's sqlite3 module by using compatible database formats.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "python_interop.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true });
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();
}
```

> [!TIP]
> Run with: `zig build run-07-python-interop`