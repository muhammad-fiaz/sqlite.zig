---
title: "Composite Unique"
description: "Composite unique constraints"
---

# Composite Unique

Use composite unique constraints to enforce uniqueness across multiple columns.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_27.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS combo (a INTEGER, b INTEGER, UNIQUE(a, b));");
    result.deinit();
    result = try db.exec("INSERT INTO combo VALUES (1, 1);");
    result.deinit();
    const dup = db.exec("INSERT INTO combo VALUES (1, 1);") catch null;
    if (dup) |v| {
        var owned = v;
        owned.deinit();
        return error.DuplicateWasAccepted;
    }
}
```

> [!TIP]
> Run with: `zig build run-27-composite-unique`