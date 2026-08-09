---
title: "Recursive CTEs"
description: "Use recursive Common Table Expressions to generate a sequence of numbers with UNION ALL."
---

# Recursive CTEs

Use recursive Common Table Expressions to generate a sequence of numbers with UNION ALL.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | WITH RECURSIVE nums AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM nums WHERE n < 5) SELECT n FROM nums ORDER BY n | Generates numbers 1 through 5 |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_32.db");
    defer db.close();
    var rows = try db.exec("WITH RECURSIVE nums AS (SELECT 1 AS n UNION ALL SELECT n + 1 AS n FROM nums WHERE n < 5) SELECT n FROM nums ORDER BY n;");
    defer rows.deinit();
    if (rows.rowCount() != 5 or rows.rows[0][0].integer != 1 or rows.rows[4][0].integer != 5) return error.RecursiveCteVerificationFailed;
    std.debug.print("32 recursive CTEs: UNION ALL fixpoint and arithmetic verified\n", .{});
}
```

## Database State After Execution

No persistent tables - the recursive CTE generates a virtual result set.

**Query result:**

| n |
|---|
| 1 |
| 2 |
| 3 |
| 4 |
| 5 |

## Zig Output

```
32 recursive CTEs: UNION ALL fixpoint and arithmetic verified
```

> [!TIP]
> Run with: `zig build run-32_recursive_ctes`
