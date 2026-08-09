---
title: "Prepared Parameter Verification"
description: "Verify prepared statement parameter binding by inserting and reading back bound values."
---

# Prepared Parameter Verification

Verify prepared statement parameter binding by inserting and reading back bound values.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS prepared_items (id INTEGER, label TEXT) | Creates the items table |
| 2 | DELETE FROM prepared_items | Clears the table |
| 3 | INSERT INTO prepared_items (id, label) VALUES (?, ?) | Inserts with bound params (7, 'bound value') |
| 4 | SELECT id, label FROM prepared_items WHERE id = 7 | Reads back the bound row |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_19.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS prepared_items (id INTEGER, label TEXT);");
    setup.deinit();
    var clear = try db.exec("DELETE FROM prepared_items;");
    clear.deinit();
    var statement = try db.prepare("INSERT INTO prepared_items (id, label) VALUES (?, ?);");
    try statement.bind(1, 7);
    try statement.bind(2, "bound value");
    try statement.step();
    statement.finalize();
    var result = try db.exec("SELECT id, label FROM prepared_items WHERE id = 7;");
    defer result.deinit();
    if (result.rowCount() != 1 or result.rows[0][0].integer != 7 or !std.mem.eql(u8, result.rows[0][1].text, "bound value")) return error.PreparedValueVerificationFailed;
    std.debug.print("19 prepared parameters: prepared_items contains {d} verified row\n", .{result.rowCount()});
}
```

## Database State After Execution

| id | label |
|----|-------|
| 7 | bound value |

## Zig Output

```
19 prepared parameters: prepared_items contains 1 verified row
```

> [!TIP]
> Run with: `zig build run-19_prepared_parameter_verification`
