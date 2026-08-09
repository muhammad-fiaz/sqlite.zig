---
title: "Column Defaults"
description: "Use DEFAULT column values and INSERT DEFAULT VALUES to omit columns with pre-configured defaults."
---

# Column Defaults

Use DEFAULT column values and INSERT DEFAULT VALUES to omit columns with pre-configured defaults.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | DROP TABLE IF EXISTS default_demo | Drops any previous table |
| 2 | CREATE TABLE default_demo (id INTEGER, label TEXT DEFAULT 'untitled', enabled INTEGER DEFAULT 1) | Creates table with defaults |
| 3 | INSERT INTO default_demo (id) VALUES (1) | Inserts with default label and enabled |
| 4 | INSERT INTO default_demo DEFAULT VALUES | Inserts all defaults |
| 5 | SELECT label, enabled FROM default_demo ORDER BY id | Reads both rows |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_47.db");
    defer db.close();
    var result = try db.exec("DROP TABLE IF EXISTS default_demo; CREATE TABLE default_demo (id INTEGER, label TEXT DEFAULT 'untitled', enabled INTEGER DEFAULT 1); INSERT INTO default_demo (id) VALUES (1); INSERT INTO default_demo DEFAULT VALUES;");
    result.deinit();
    var rows = try db.exec("SELECT label, enabled FROM default_demo ORDER BY id;");
    defer rows.deinit();
    if (rows.rowCount() != 2 or !std.mem.eql(u8, rows.rows[0][0].text, "untitled") or rows.rows[1][1].integer != 1) return error.DefaultVerificationFailed;
    std.debug.print("47 column defaults: omitted columns and DEFAULT VALUES verified\n", .{});
}
```

## Database State After Execution

**default_demo:**

| id | label | enabled |
|----|-------|---------|
| 1 | untitled | 1 |
| NULL | untitled | 1 |

Row 1: id=1, label defaults to 'untitled', enabled defaults to 1.
Row 2: INSERT DEFAULT VALUES - all columns use defaults (id=NULL, label='untitled', enabled=1).

## Zig Output

```
47 column defaults: omitted columns and DEFAULT VALUES verified
```

> [!TIP]
> Run with: `zig build run-47_column_defaults`
