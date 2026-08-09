# Transaction API

Transaction and locking support for concurrent access.

## Overview

The transaction module manages ACID properties and locking for safe concurrent database access.

## Transaction Types

| Type | Lock Behavior |
|------|---------------|
| `BEGIN` (Deferred) | Acquires lock on first read/write |
| `BEGIN IMMEDIATE` | Acquires reserved lock immediately |
| `BEGIN EXCLUSIVE` | Acquires exclusive lock immediately |

## Locking

SQLite uses file-level locks to coordinate concurrent access:

| Lock | Description |
|------|-------------|
| UNLOCKED | No lock held |
| SHARED | One or more readers, no writers |
| RESERVED | Intent to write, readers still allowed |
| PENDING | Waiting for exclusive, no new readers |
| EXCLUSIVE | One writer, no readers |

## Transaction Lifecycle

```zig
// Begin
try db.begin();

// Operations
var result = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
result.deinit();

// Commit or rollback
try db.commit();
// or
try db.rollback();
```

## Savepoints

Partial rollback within a transaction:

```zig
try db.begin();
// ... operations ...
try db.savepoint("sp1");
// ... more operations ...
try db.rollbackToSavepoint("sp1"); // undo only after sp1
try db.releaseSavepoint("sp1");
try db.commit();
```

## Concurrent Access

Multiple connections can read simultaneously. Writers must wait for readers to finish and vice versa.

> [!WARNING]
> Always commit or rollback transactions promptly to avoid blocking other connections.
