---
title: "Scalar Functions"
description: "ABS, LENGTH, UPPER, LOWER, SUBSTR"
---

# Scalar Functions

Use scalar functions like ABS, LENGTH, UPPER, LOWER, and SUBSTR.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_20.db");
    defer db.close();
    var result = try db.exec("SELECT ABS(-5), LENGTH('hello'), UPPER('test'), LOWER('TEST');");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-20-scalar-functions`