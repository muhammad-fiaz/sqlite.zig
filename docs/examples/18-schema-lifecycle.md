---
title: "Schema Lifecycle"
description: "Demonstrate the full schema lifecycle: create, alter columns, rename, truncate, and drop tables."
---

# Schema Lifecycle

Demonstrate the full schema lifecycle: create, alter columns, rename, truncate, and drop tables.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS lifecycle_accounts (id INTEGER, name TEXT) | Creates the accounts table |
| 2 | ALTER TABLE lifecycle_accounts ADD COLUMN enabled INTEGER | Adds an 'enabled' column |
| 3 | ALTER TABLE lifecycle_accounts RENAME COLUMN enabled TO enabled | Renames 'enabled' column |
| 4 | ALTER TABLE lifecycle_accounts DROP COLUMN enabled | Drops the 'enabled' column |
| 5 | DELETE FROM lifecycle_accounts | Truncates the table |
| 6 | ALTER TABLE lifecycle_accounts RENAME TO lifecycle_accounts_archive | Renames the table |
| 7 | DROP TABLE lifecycle_accounts_archive | Drops the renamed table |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Account = sqlite.table("lifecycle_accounts", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_18.db");
    defer db.close();
    try db.createTable(Account, .{ .if_not_exists = true });
    if (!db.tableExists(Account)) return error.TableWasNotCreated;
    try db.addColumn(Account, "active", i64);
    try db.renameColumn(Account, "active", "enabled");
    try db.dropColumn(Account, "enabled");
    try db.truncate(Account);
    try db.renameTable(Account, "lifecycle_accounts_archive");
    try db.dropTable(sqlite.table("lifecycle_accounts_archive", struct { id: i64, name: []const u8 }));
    std.debug.print("18 schema lifecycle: create, alter, rename, truncate, and drop verified\n", .{});
}
```

## Database State After Execution

The table is dropped at the end of the example, so no tables remain.

## Zig Output

```
18 schema lifecycle: create, alter, rename, truncate, and drop verified
```

> [!TIP]
> Run with: `zig build run-18_schema_lifecycle_verification`
