# Errors API

Error types and handling for the sqlite.zig engine.

## Error Types

| Error | Description |
|-------|-------------|
| `InvalidSql` | SQL syntax error in the parsed statement |
| `UnexpectedToken` | Parser encountered an unexpected token |
| `TableNotFound` | Referenced table does not exist in the schema |
| `ColumnNotFound` | Referenced column does not exist in the table |
| `TypeMismatch` | Value type does not match the expected column type |
| `ConstraintViolation` | UNIQUE, NOT NULL, CHECK, or FOREIGN KEY constraint violated |
| `NotInTransaction` | Attempted commit/rollback without an active transaction |
| `DatabaseFull` | Database file has exceeded the maximum size |
| `Corrupt` | Database file appears to be corrupted |
| `IoError` | File system I/O error during read/write |
| `LockConflict` | Another connection holds an incompatible lock |
| `OutOfMemory` | Allocator ran out of memory |

## Using Errors

```zig
const sqlite = @import("sqlite");

var db = try sqlite.open(std.heap.page_allocator, "my.db");
defer db.close();

// Catch specific errors
const result = db.exec("SELECT * FROM nonexistent;") catch |err| {
    switch (err) {
        error.TableNotFound => std.debug.print("Table does not exist\n", .{}),
        error.InvalidSql => std.debug.print("SQL syntax error\n", .{}),
        else => return err,
    }
};
```

## Deterministic Error Behavior

Invalid SQL always returns `error.UnexpectedToken`:

```zig
const invalid = db.exec("SELECT FROM users;") catch null;
try std.testing.expect(invalid == null);
```

## Error Recovery

```zig
try db.begin();
var insert = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
insert.deinit();
// On error, rollback is safe
try db.rollback();
```
