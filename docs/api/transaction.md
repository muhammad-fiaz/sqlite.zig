---
title: "Transaction API"
description: "Transactions, savepoints, and locking in sqlite.zig, including deferred, immediate, and exclusive begin modes."
---

# Transaction API

Transactions, savepoints, and per-connection locking.

## Overview

The transaction module manages ACID properties and locking for safe concurrent database access.

## Transaction Types

| Type | Lock Behavior |
|------|---------------|
| `BEGIN` (Deferred) | Acquires lock on first read/write |
| `BEGIN IMMEDIATE` | Acquires reserved lock immediately |
| `BEGIN EXCLUSIVE` | Acquires exclusive lock immediately |

## Locking

The engine tracks per-connection lock state (`unlocked`, `shared`,
`reserved`, `exclusive` in `src/txn/locking.zig`):

| Lock | Description |
|------|-------------|
| unlocked | No lock held |
| shared | Reading; compatible with other readers |
| reserved | Intent to write |
| exclusive | Writing; held alone |

Full multi-process file locking and VFS parity are still in progress (see
the [SQL engine guide](/guide/sql-engine)); do not rely on cross-process
coordination yet.

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

Transactions are tracked per connection with nested savepoint support.
Cross-process lock coordination is not implemented yet, so multiple writers
must be coordinated by the application.

> [!WARNING]
> Always commit or rollback transactions promptly. An open transaction holds
> the connection's state and blocks `VACUUM`.
