---
title: "Multiple CTEs"
description: "Chain multiple dependent non-recursive Common Table Expressions in a single query."
---

# Multiple CTEs

Chain multiple dependent non-recursive Common Table Expressions in a single query.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS cte_source (id INTEGER, label TEXT) | Creates source table |
| 2 | DELETE FROM cte_source | Clears the table |
| 3 | INSERT INTO cte_source VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma') | Inserts three rows |
| 4 | WITH first_set AS (...), second_set AS (...) SELECT id, label FROM second_set ORDER BY id | Chains two dependent CTEs |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_29.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS cte_source (id INTEGER, label TEXT);");
    setup.deinit();
    var cleared = try db.exec("DELETE FROM cte_source;");
    cleared.deinit();
    var inserted = try db.exec("INSERT INTO cte_source VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');");
    inserted.deinit();

    var result = try db.exec("WITH first_set AS (SELECT id, label FROM cte_source WHERE id >= 2), second_set AS (SELECT id, label FROM first_set) SELECT id, label FROM second_set ORDER BY id;");
    defer result.deinit();
    if (result.rowCount() != 2 or result.rows[0][0].integer != 2 or !std.mem.eql(u8, result.rows[0][1].text, "beta") or result.rows[1][0].integer != 3) return error.MultipleCteVerificationFailed;
    std.debug.print("29 CTEs: multiple dependent non-recursive CTEs verified\n", .{});
}
```

## Database State After Execution

**cte_source:**

| id | label |
|----|-------|
| 1 | alpha |
| 2 | beta |
| 3 | gamma |

**Query result (from chained CTEs):**

| id | label |
|----|-------|
| 2 | beta |
| 3 | gamma |

## Zig Output

```
29 CTEs: multiple dependent non-recursive CTEs verified
```

> [!TIP]
> Run with: `zig build run-29_multiple_ctes`
