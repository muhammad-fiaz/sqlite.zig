---
title: "DSL CTEs"
description: "Build WITH and WITH RECURSIVE queries through the dynamic and typed DSL."
---

# DSL CTEs

The query builder prefixes `WITH` / `WITH RECURSIVE` clauses whose bodies
are raw SQL. Bodies execute through the same native engine as every other
query; outer predicates, ordering, and limits still use bound parameters.

## What This Example Does

| Step | Operation | Description |
|------|-----------|-------------|
| 1 | Raw `WITH live AS ...` | Baseline CTE result |
| 2 | `.with("live", ...)` on `db.from("live")` | Dynamic CTE query |
| 3 | `.with("live", ...)` on `db.from(Live)` | Typed CTE query with mapped rows |
| 4 | `.with(...).with(...)` | Chained CTEs |
| 5 | `.withRecursive(...)` | Recursive fixpoint CTE |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Live = sqlite.table("live", struct { id: i64, name: []const u8, active: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_51.db");
    defer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS cte_employees; CREATE TABLE cte_employees (id INTEGER, name TEXT, active INTEGER); INSERT INTO cte_employees VALUES (1, 'Ada', 1), (2, 'Bob', 0), (3, 'Cy', 1);");
    setup.deinit();

    var raw = try db.exec("WITH live AS (SELECT id, name FROM cte_employees WHERE active = 1) SELECT id, name FROM live ORDER BY id;");
    defer raw.deinit();
    if (raw.rowCount() != 2) return error.RawCteVerificationFailed;

    var dynamic = try db.from("live").with("live", "SELECT id, name FROM cte_employees WHERE active = 1").orderBy(db.col("id").asc()).fetch();
    defer dynamic.deinit();
    if (dynamic.rowCount() != 2 or dynamic.rows[1][0].integer != 3) return error.DynamicCteVerificationFailed;

    var typed = try db.from(Live).with("live", "SELECT id, name, active FROM cte_employees WHERE active = 1").orderBy(Live.columns.id.asc()).fetch();
    defer typed.deinit();
    if (typed.rowCount() != 2 or !std.mem.eql(u8, typed.rows[0].name, "Ada")) return error.TypedCteVerificationFailed;

    var chained = try db.from("second").with("first", "SELECT id FROM cte_employees WHERE id >= 2").with("second", "SELECT id FROM first").fetch();
    defer chained.deinit();
    if (chained.rowCount() != 2) return error.ChainedCteVerificationFailed;

    var counted = try db.from("nums").withRecursive("nums", "SELECT 1 AS n", "SELECT n + 1 AS n FROM nums WHERE n < 5").fetch();
    defer counted.deinit();
    if (counted.rowCount() != 5) return error.RecursiveCteVerificationFailed;
    std.debug.print("51 DSL CTEs: raw, dynamic, typed, chained, and recursive verified\n", .{});
}
```

CTE bodies are raw SQL without parameters by design; the typed table names
the CTE being read, exactly like reading a view.

## Zig Output

```text
51 DSL CTEs: raw, dynamic, typed, chained, and recursive verified
```

> [!TIP]
> Run with: `zig build run-51_dsl_ctes`
