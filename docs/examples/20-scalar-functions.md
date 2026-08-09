---
title: "Scalar Functions with Typed DSL"
description: "Use scalar functions like lower(), upper(), length(), abs(), and typeof() with raw SQL and typed DSL."
---

# Scalar Functions with Typed DSL

Use scalar functions like lower(), upper(), length(), abs(), and typeof() with raw SQL and typed DSL.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS scalar_metrics (id INTEGER PRIMARY KEY, label TEXT, value INTEGER) | Creates the metrics table |
| 2 | DELETE FROM scalar_metrics | Truncates the table |
| 3 | INSERT INTO scalar_metrics VALUES (1, 'Alpha', 12) | Inserts a metric row |
| 4 | SELECT lower(label), upper(label), length(label), abs(value), typeof(value) FROM scalar_metrics | Raw scalar function query |
| 5 | SELECT lower(label) FROM scalar_metrics | DSL lower column projection |
| 6 | SELECT abs(value) FROM scalar_metrics | DSL abs column projection |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const MetricRow = struct { id: i64, label: []const u8, value: i64 };
const Metric = sqlite.table("scalar_metrics", MetricRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_20.db");
    defer db.close();
    try db.createTable(Metric, .{ .if_not_exists = true, .primary_key = Metric.key("id") });
    try db.truncate(Metric);
    var inserted = try db.from(Metric).insertTyped(.{ .id = 1, .label = "Alpha", .value = 12 });
    inserted.deinit();

    var raw = try db.exec("SELECT lower(label), upper(label), length(label), abs(value), typeof(value) FROM scalar_metrics;");
    defer raw.deinit();
    if (raw.rowCount() != 1) return error.RawScalarVerificationFailed;

    var lower = try db.from(Metric).lowerColumn(Metric.key("label")).fetchAll();
    defer lower.deinit();
    var absolute = try db.from(Metric).absColumn(Metric.key("value")).fetchAll();
    defer absolute.deinit();
    if (lower.rowCount() != 1 or absolute.rows[0][0].integer != 12) return error.TypedScalarVerificationFailed;
    std.debug.print("20 scalar functions: raw and typed projections verified\n", .{});
}
```

## Database State After Execution

| id | label | value |
|----|-------|-------|
| 1 | Alpha | 12 |

## Zig Output

```
20 scalar functions: raw and typed projections verified
```

> [!TIP]
> Run with: `zig build run-20_scalar_functions_typed_dsl`
