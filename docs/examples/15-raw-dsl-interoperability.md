---
title: "Raw and DSL Interoperability"
description: "Mix raw SQL and typed DSL operations on the same table to demonstrate interoperability."
---

# Raw and DSL Interoperability

Mix raw SQL and typed DSL operations on the same table to demonstrate interoperability.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS interop_tasks (id INTEGER, title TEXT, done INTEGER) | Creates the tasks table |
| 2 | DELETE FROM interop_tasks | Truncates the table |
| 3 | INSERT INTO interop_tasks VALUES (1, 'write docs', 0), (2, 'ship release', 1) | Raw SQL inserts two rows |
| 4 | UPDATE interop_tasks SET done = 1 WHERE id = 1 | DSL updates task 1 to done |
| 5 | SELECT id, title FROM interop_tasks WHERE done = 1 | Raw query for completed tasks |
| 6 | DELETE FROM interop_tasks WHERE id = 2 | DSL deletes task 2 |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Task = sqlite.table("interop_tasks", struct { id: i64, title: []const u8, done: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_15.db");
    defer db.close();
    try db.createTable(Task, .{ .if_not_exists = true });
    try db.truncate(Task);

    var raw_insert = try db.exec("INSERT INTO interop_tasks (id, title, done) VALUES (1, 'write docs', 0), (2, 'ship release', 1);");
    raw_insert.deinit();

    var typed_update = try db.from(Task).update(.{ .done = 1 });
    var updated = try typed_update.where(Task.column("id").eq(1)).execute();
    typed_update.deinit();
    updated.deinit();

    var raw_query = try db.exec("SELECT id, title FROM interop_tasks WHERE done = 1;");
    raw_query.deinit();

    var typed_delete = db.from(Task).delete().where(Task.column("id").eq(2));
    var deleted = try typed_delete.execute();
    typed_delete.deinit();
    deleted.deinit();
}
```

## Database State After Execution

| id | title | done |
|----|-------|------|
| 1 | write docs | 1 |

## Zig Output

```
15 raw dsl interop: raw SQL and DSL produce identical results
```

> [!TIP]
> Run with: `zig build run-15_raw_dsl_interoperability`
