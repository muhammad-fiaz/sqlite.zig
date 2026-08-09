---
title: "Persistence and Reopen Verification"
description: "Verify data persistence by writing to a database, closing it, and reopening to confirm data survives."
---

# Persistence and Reopen Verification

Verify data persistence by writing to a database, closing it, and reopening to confirm data survives.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS persisted_notes (id INTEGER, body TEXT) | Creates the notes table |
| 2 | DELETE FROM persisted_notes | Truncates the table |
| 3 | INSERT INTO persisted_notes VALUES (1, 'stored on disk') | Inserts a note |
| 4 | *(close database)* | Closes the database connection |
| 5 | *(reopen database)* | Reopens the same database file |
| 6 | SELECT id, body FROM persisted_notes | Reads back the persisted data |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Note = sqlite.table("persisted_notes", struct { id: i64, body: []const u8 });

pub fn main() !void {
    const path = "valid_17.db";
    var db = try sqlite.open(std.heap.page_allocator, path);
    try db.createTable(Note, .{ .if_not_exists = true });
    try db.truncate(Note);
    var inserted = try db.from(Note).insert(.{ .id = 1, .body = "stored on disk" });
    inserted.deinit();
    db.close();

    db = try sqlite.open(std.heap.page_allocator, path);
    defer db.close();
    var rows = try db.from(Note).selectFieldNames(&.{ "id", "body" }).fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1 or rows.rows[0][0].integer != 1 or !std.mem.eql(u8, rows.rows[0][1].text, "stored on disk")) return error.PersistenceVerificationFailed;
    std.debug.print("17 persistence: persisted_notes contains {d} verified row\n", .{rows.rowCount()});
}
```

## Database State After Execution

| id | body |
|----|------|
| 1 | stored on disk |

## Zig Output

```
17 persistence: persisted_notes contains 1 verified row
```

> [!TIP]
> Run with: `zig build run-17_persistence_reopen_verification`
