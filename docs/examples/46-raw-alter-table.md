---
title: "Raw ALTER TABLE"
description: "Use raw SQL ALTER TABLE commands to add, rename, and drop columns, and rename tables."
---

# Raw ALTER TABLE

Use raw SQL ALTER TABLE commands to add, rename, and drop columns, and rename tables.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | DROP TABLE IF EXISTS altered_demo | Drops any previous table |
| 2 | DROP TABLE IF EXISTS alter_demo | Drops any previous table |
| 3 | CREATE TABLE alter_demo (id INTEGER, label TEXT) | Creates the demo table |
| 4 | INSERT INTO alter_demo VALUES (1, 'before') | Inserts initial row |
| 5 | ALTER TABLE alter_demo ADD COLUMN enabled INTEGER | Adds 'enabled' column |
| 6 | ALTER TABLE alter_demo RENAME COLUMN label TO name | Renames 'label' to 'name' |
| 7 | ALTER TABLE alter_demo DROP COLUMN enabled | Drops the 'enabled' column |
| 8 | ALTER TABLE alter_demo RENAME TO altered_demo | Renames the table |
| 9 | SELECT id, name FROM altered_demo | Reads final schema |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_46.db");
    defer db.close();
    var result = try db.exec("DROP TABLE IF EXISTS altered_demo; DROP TABLE IF EXISTS alter_demo; CREATE TABLE alter_demo (id INTEGER, label TEXT); INSERT INTO alter_demo VALUES (1, 'before'); ALTER TABLE alter_demo ADD COLUMN enabled INTEGER; ALTER TABLE alter_demo RENAME COLUMN label TO name; ALTER TABLE alter_demo DROP COLUMN enabled; ALTER TABLE alter_demo RENAME TO altered_demo;");
    result.deinit();
    var rows = try db.exec("SELECT id, name FROM altered_demo;");
    defer rows.deinit();
    if (rows.rowCount() != 1 or !std.mem.eql(u8, rows.rows[0][1].text, "before")) return error.AlterVerificationFailed;
    std.debug.print("46 ALTER TABLE: add, rename, drop, and table rename verified\n", .{});
}
```

## Database State After Execution

**altered_demo:**

| id | name |
|----|------|
| 1 | before |

## Zig Output

```
46 ALTER TABLE: add, rename, drop, and table rename verified
```

> [!TIP]
> Run with: `zig build run-46_raw_alter_table`
