---
title: "API Reference"
description: "Overview of the sqlite.zig public API, including core types, top-level functions, and module references for Connection, DSL, SQL, and storage."
---

# API Reference

Overview of the `sqlite.zig` public API.

## Core Types

| Type | Description |
|------|-------------|
| `Connection` | Database connection handle — open, close, exec, and manage transactions |
| `Result` | Query result set — rows, columns, and row count |
| `Statement` | Prepared statement with parameter binding |
| `Value` | Union type for column values (integer, real, text, blob, null) |
| `Expr` | DSL expression for WHERE clauses and conditions |

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
| [Connection](/api/connection) | Database open/close, exec, transactions, schema management |
| [DSL](/api/dsl) | Type-safe query builder — table, insert, select, update, delete, joins |
| [SQL](/api/sql) | Raw SQL execution — lexer, parser, AST, compiler |
| [Storage](/api/storage) | Low-level storage — file I/O, pager, WAL, journal, image format |
| [Catalog](/api/catalog) | Schema catalog — table definitions, indexes, type affinity |
