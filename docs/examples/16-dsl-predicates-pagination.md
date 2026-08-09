---
title: "DSL Predicates and Pagination"
description: "Use DSL predicates like BETWEEN, LIKE, and pagination with LIMIT/OFFSET for query results."
---

# DSL Predicates and Pagination

Use DSL predicates like BETWEEN, LIKE, and pagination with LIMIT/OFFSET for query results.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS paged_events (id INTEGER, label TEXT, rank INTEGER) | Creates the events table |
| 2 | DELETE FROM paged_events | Truncates the table |
| 3 | INSERT INTO paged_events VALUES (1, 'alpha', 10) | Inserts alpha event |
| 4 | INSERT INTO paged_events VALUES (2, 'beta', 20) | Inserts beta event |
| 5 | INSERT INTO paged_events VALUES (3, 'gamma', 30) | Inserts gamma event |
| 6 | SELECT id, label, rank FROM paged_events WHERE rank BETWEEN 10 AND 30 AND label LIKE '%a%' ORDER BY rank ASC LIMIT 2 OFFSET 1 | Paginated filtered query |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const EventRow = struct { id: i64, label: []const u8, rank: i64 };
const Event = sqlite.table("paged_events", EventRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_16.db");
    defer db.close();
    try db.createTable(Event, .{ .if_not_exists = true });
    try db.truncate(Event);
    const seed = [_]EventRow{
        .{ .id = 1, .label = "alpha", .rank = 10 },
        .{ .id = 2, .label = "beta", .rank = 20 },
        .{ .id = 3, .label = "gamma", .rank = 30 },
    };
    for (seed) |item| {
        var inserted = try db.from(Event).insertTyped(item);
        inserted.deinit();
    }

    var page = try db.from(Event)
        .selectColumns(&.{ Event.key("id"), Event.key("label"), Event.key("rank") })
        .where(Event.column("rank").between(10, 30))
        .andWhere(Event.column("label").like("%a%"))
        .orderBy(Event.column("rank").asc())
        .limit(2)
        .offset(1)
        .fetchAll();
    defer page.deinit();
    std.debug.print("16 typed DSL pagination: rows={d} first_id={d}\n", .{ page.rowCount(), if (page.rowCount() == 0) -1 else page.rows[0][0].integer });
    if (page.rowCount() != 2 or page.rows[0][0].integer != 2) return error.PaginationVerificationFailed;
    std.debug.print("16 typed DSL pagination: {d} verified row\n", .{page.rowCount()});
}
```

## Database State After Execution

**paged_events (all rows):**

| id | label | rank |
|----|-------|------|
| 1 | alpha | 10 |
| 2 | beta | 20 |
| 3 | gamma | 30 |

**Query result (BETWEEN 10 AND 30, LIKE '%a%', LIMIT 2 OFFSET 1):**

| id | label | rank |
|----|-------|------|
| 2 | beta | 20 |
| 3 | gamma | 30 |

## Zig Output

```
16 typed DSL pagination: rows=2 first_id=2
16 typed DSL pagination: 2 verified row
```

> [!TIP]
> Run with: `zig build run-16_dsl_predicates_pagination`
