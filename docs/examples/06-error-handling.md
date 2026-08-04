---
title: "Error Handling"
description: "Error handling and recovery"
---

# Error Handling

Handle errors gracefully and recover from invalid operations.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_06.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS error_test (id INTEGER);");
    result.deinit();
    const invalid = db.exec("SELECT FROM error_test;") catch null;
    if (invalid) |value| {
        var owned = value;
        owned.deinit();
        return error.InvalidQueryWasAccepted;
    }
}
```

> [!TIP]
> Run with: `zig build run-06-error-handling`