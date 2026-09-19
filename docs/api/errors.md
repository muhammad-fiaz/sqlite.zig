---
title: "Errors API"
description: "Error values returned by the sqlite.zig engine, from SQL syntax errors to constraint violations and unsupported features."
---

# Errors API

Error values returned by the sqlite.zig engine. The full set lives in
`src/errors/errors.zig` and is exposed as `sqlite.errors`.

## Error Values

| Error | Description |
|-------|-------------|
| `InvalidSql` | SQL statement is invalid |
| `UnexpectedToken` | Parser encountered an unexpected token |
| `UnknownTable` | Referenced table does not exist in the schema |
| `UnknownColumn` | Referenced column does not exist in the table |
| `ColumnExists` | Column already exists |
| `TableExists` | Table already exists |
| `IndexExists` | Index already exists |
| `UnknownIndex` | Referenced index does not exist |
| `ViewExists` | View already exists |
| `UnknownView` | Referenced view does not exist |
| `TriggerExists` | Trigger already exists |
| `UnknownTrigger` | Referenced trigger does not exist |
| `ColumnCountMismatch` | Value count does not match the column count |
| `ConstraintViolation` | UNIQUE, NOT NULL, CHECK, or FOREIGN KEY constraint violated |
| `NotInTransaction` | Commit/rollback attempted without an active transaction |
| `TransactionActive` | Operation (e.g. `VACUUM`, nested `BEGIN`) rejected while a transaction is active |
| `Unsupported` | Feature is explicitly unsupported (never silently faked) |
| `SchemaMismatch` | Database schema does not match the declared table |
| `InvalidHeader` | Database file header is invalid |
| `InvalidPageSize` | Database page size is invalid |
| `InvalidRecord` | Database record encoding is invalid |

Use `sqlite.errors.message(err)` for the stable human-readable message
associated with each error.

## Using Errors

```zig
const sqlite = @import("sqlite");

var db = try sqlite.open(std.heap.page_allocator, "my.db");
defer db.close();

// Catch specific errors
var rows = db.exec("SELECT * FROM nonexistent;") catch |err| switch (err) {
    error.UnknownTable => {
        std.debug.print("Table does not exist\n", .{});
        return err;
    },
    error.InvalidSql => {
        std.debug.print("SQL syntax error\n", .{});
        return err;
    },
    else => return err,
};
defer rows.deinit();
```

## Deterministic Error Behavior

Invalid SQL returns a syntax error rather than succeeding:

```zig
try std.testing.expectError(error.UnexpectedToken, db.exec("SELECT FROM users;"));
```

Unsupported statements (for example `ATTACH`) return `error.Unsupported`
instead of pretending to work.

## Error Recovery

```zig
try db.begin();
var insert = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
insert.deinit();
// On error, rollback is safe
try db.rollback();
```
