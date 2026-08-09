---
title: "INSERT SELECT Copy"
description: "Copy filtered rows from one table to another using INSERT ... SELECT."
---

# INSERT SELECT Copy

Copy filtered rows from one table to another using INSERT ... SELECT.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS copy_source (id INTEGER, label TEXT) | Creates source table |
| 2 | CREATE TABLE IF NOT EXISTS copy_destination (id INTEGER, label TEXT) | Creates destination table |
| 3 | DELETE FROM copy_source | Truncates source |
| 4 | DELETE FROM copy_destination | Truncates destination |
| 5 | INSERT INTO copy_source VALUES (1, 'skip') | Inserts row to skip |
| 6 | INSERT INTO copy_source VALUES (2, 'copy') | Inserts row to copy |
| 7 | INSERT INTO copy_destination SELECT id, label FROM copy_source WHERE id > 1 | Copies filtered rows |
| 8 | SELECT * FROM copy_destination | Reads copied rows |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Source = sqlite.table("copy_source", struct { id: i64, label: []const u8 });
const Destination = sqlite.table("copy_destination", struct { id: i64, label: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_37.db");
    defer db.close();
    try db.createTable(Source, .{ .if_not_exists = true });
    try db.createTable(Destination, .{ .if_not_exists = true });
    try db.truncate(Source);
    try db.truncate(Destination);
    var first = try db.from(Source).insert(.{ .id = 1, .label = "skip" });
    first.deinit();
    var second = try db.from(Source).insert(.{ .id = 2, .label = "copy" });
    second.deinit();
    var copied = try db.exec("INSERT INTO copy_destination SELECT id, label FROM copy_source WHERE id > 1;");
    copied.deinit();
    var rows = try db.from(Destination).selectAll().fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1 or rows.rows[0][0].integer != 2) return error.InsertSelectVerificationFailed;
    std.debug.print("37 INSERT SELECT: filtered query results copied and verified\n", .{});
}
```

## Database State After Execution

**copy_source:**

| id | label |
|----|-------|
| 1 | skip |
| 2 | copy |

**copy_destination:**

| id | label |
|----|-------|
| 2 | copy |

## Zig Output

```
37 INSERT SELECT: filtered query results copied and verified
```

> [!TIP]
> Run with: `zig build run-37_insert_select_copy`
