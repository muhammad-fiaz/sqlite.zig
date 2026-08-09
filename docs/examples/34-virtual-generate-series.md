---
title: Virtual Table generate_series
description: Use SQLite's virtual generate_series table to produce a sequence of integers.
---

# Virtual Table generate_series

This example shows how to create and query SQLite's `generate_series` virtual table. It generates a sequence of numbers from 1 to 5 and verifies the results survive a database close and reopen.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Series = sqlite.table("numbers_series", struct { value: i64 });

fn verify(db: *sqlite.Connection) !void {
    var rows = try db.from(Series).selectAll().fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 5 or rows.rows[0][0].integer != 1 or rows.rows[4][0].integer != 5) return error.VirtualTableVerificationFailed;
}

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_34.db");
    var created = try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS numbers_series USING generate_series(1, 5, 1);");
    created.deinit();
    try verify(db);
    db.close();

    var reopened = try sqlite.open(std.heap.page_allocator, "valid_34.db");
    defer reopened.close();
    try verify(reopened);
    std.debug.print("34 virtual tables: generate_series native DSL reads and reopen verified\n", .{});
}
```

> [!TIP]
> Run with: `zig build run-34_virtual_generate_series`
