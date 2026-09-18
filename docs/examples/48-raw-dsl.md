---
title: "48 — Raw DSL"
description: "Schema-less Raw DSL querying with runtime table and column names."
---

# 48 — Raw DSL

The Raw DSL is for existing tables whose schema is not represented by a Zig
struct. It accepts runtime table and column identifiers while preserving the
library's SQL value rendering:

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_48.db");
    defer db.close();

    var setup = try db.exec("DROP TABLE IF EXISTS raw_dsl_items; CREATE TABLE raw_dsl_items (id INTEGER, name TEXT); INSERT INTO raw_dsl_items VALUES (1, 'Alice'), (2, 'Bob');");
    setup.deinit();

    var rows = try db.from("raw_dsl_items")
        .select(.{ db.col("id"), db.col("name") })
        .where(db.col("id").gte(2))
        .fetch();
    defer rows.deinit();
    std.debug.print("Raw DSL rows: {d}\n", .{rows.rowCount()});
}
```

Run the executable with:

```text
zig build run-48_raw_dsl
```

Typed schemas should use the typed DSL; Raw DSL is intentionally schema-less.




