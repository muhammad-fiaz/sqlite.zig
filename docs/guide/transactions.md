---
title: "Transactions"
description: "Full ACID transaction semantics with BEGIN, COMMIT, ROLLBACK, SAVEPOINT, and RELEASE support."
---

# Transactions

`sqlite.zig` supports full ACID transaction semantics with BEGIN, COMMIT, ROLLBACK, SAVEPOINT, and RELEASE.

## Basic Transactions

```zig
// Begin a transaction
try db.begin();

// Perform operations
var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
inserted.deinit();

// Commit (or rollback on error)
try db.commit();
```

## Rollback

```zig
try db.begin();
var result = try db.from(User).insert(.{ .id = 1, .name = "Temporary" });
result.deinit();
try db.rollback(); // Changes are discarded
```

## Transaction Modes

```zig
// Standard (deferred)
try db.begin();

// Immediate (locks the database immediately)
try db.beginImmediate();

// Exclusive (waits for a lock)
try db.beginExclusive();
```

## SAVEPOINT

Savepoints allow partial rollbacks within a transaction:

```zig
try db.begin();

var a = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
a.deinit();

try db.savepoint("sp1");

var b = try db.from(User).insert(.{ .id = 2, .name = "Bob" });
b.deinit();

// Roll back only the second insert
try db.rollbackToSavepoint("sp1");
try db.releaseSavepoint("sp1");

// Only Alice remains
try db.commit();
```

## Raw SQL Transactions

```zig
var result = try db.exec("BEGIN;");
result.deinit();
result = try db.exec("INSERT INTO users VALUES (1, 'Alice');");
result.deinit();
result = try db.exec("COMMIT;");
result.deinit();
```

> [!WARNING]
> Always ensure transactions are either committed or rolled back. Uncommitted transactions will be rolled back when the connection is closed.
