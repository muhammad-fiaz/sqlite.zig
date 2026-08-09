---
title: "Error Handling"
description: "Demonstrate error handling when executing invalid SQL queries against a SQLite database."
---

# Error Handling

Demonstrate error handling when executing invalid SQL queries against a SQLite database.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | SELECT * FROM missing | Attempts to query a non-existent table (returns error) |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_06.db");
    defer db.close();
    const result = db.exec("SELECT * FROM missing;");
    if (result) |value| {
        var owned = value;
        owned.deinit();
    } else |_| {}
}
```

## Database State After Execution

No tables exist in the database - the example only demonstrates error handling on a missing table.

## Zig Output

```
No console output - operations completed successfully
```

> [!TIP]
> Run with: `zig build run-06_error_handling`
