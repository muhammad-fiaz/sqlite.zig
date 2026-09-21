---
title: "API Reference"
description: "Overview of the sqlite.zig public API: core types, top-level functions, and references for every documented module."
---

# API Reference

Overview of the `sqlite.zig` public API.

## Core Types

| Type | Description |
|------|-------------|
| `Connection` | Database connection handle — open, close, exec, and manage transactions |
| `Result` | Query result set — rows, columns, and count |
| `Statement` | Prepared statement with parameter binding |
| `Value` | Union type for column values (integer, real, text, blob, null) |

## Top-Level Functions

```zig
const sqlite = @import("sqlite");

// Open a database
var db = try sqlite.open(allocator, "my_database.db");
defer db.close();

// Execute raw SQL
var result = try db.exec("SELECT * FROM users;");
defer result.deinit();
```

## Table Definition

```zig
const User = sqlite.table("users", struct {
    id: i64,
    name: []const u8,
});
```

## Modules

| Module | Description |
|--------|-------------|
| [Connection](/api/connection) | Database open/close, exec, prepared statements, schema management |
| [DSL](/api/dsl) | Type-safe query builder — table, insert, select, update, delete, joins |
| [SQL](/api/sql) | Raw SQL execution — lexer, parser, AST, expressions, functions |
| [B-Tree](/api/btree) | B-tree structures — cursors, balancing, index B-trees |
| [VM](/api/vm) | Bytecode compiler, opcodes, values, virtual machine |
| [Planner](/api/planner) | Query planner — plans, cost model, optimizer |
| [Storage](/api/storage) | File I/O, pager, WAL, journal, image format |
| [Format](/api/format) | On-disk encoding — header, pages, records, varints |
| [Catalog](/api/catalog) | Schema catalog — table definitions, indexes, type affinity |
| [Transaction](/api/transaction) | Transactions, savepoints, locking |
| [Migration](/api/migration) | Schema migrations — sets and runner |
| [Errors](/api/errors) | Error values and handling |
| [Version](/api/version) | Library version |
| [Compatibility](/api/compatibility) | SQLite coverage matrix — family-by-family support status |
