---
title: "SQL API"
description: "Executing raw SQL with sqlite.zig: db.exec for statements and queries, plus prepared statements with parameter binding."
---

# SQL API

Raw SQL is a first-class interface. Every statement is executed through the
same native engine that backs the DSLs.

## Executing SQL

```zig
// Any statement: DDL, DML, PRAGMA, transactions, ...
var result = try db.exec("CREATE TABLE users (id INTEGER, name TEXT);");
result.deinit();

var rows = try db.exec("SELECT id, name FROM users ORDER BY id;");
defer rows.deinit();
```

`exec` accepts multiple semicolon-separated statements and returns the result
of the final statement. For `?` placeholders with bound values, use prepared
statements below.

## Prepared statements

```zig
var statement = try db.prepare("INSERT INTO users VALUES (?, ?);");
try statement.bind(1, 4);
try statement.bind(2, "saved");
try statement.step();
statement.finalize();
```

- `bind` uses **1-based** indexes. Integers and booleans bind as `INTEGER`,
  floats as `REAL`, strings as `TEXT`, `null` and null optionals as `NULL`.
- `step` executes the statement with the current parameters.
- `reset` clears bound parameters for reuse; `finalize` frees the statement.

## How it works

Under the hood, SQL text flows through the native pipeline described in the
[SQL engine guide](/guide/sql-engine): lexer and hand-written parser produce
an AST, which the connection executes (planning, function evaluation, and
storage updates included). The lexer, parser, AST, compiler, and VM modules
under `src/` are internal implementation details — client code should use
`db.exec` and `db.prepare`, not import them directly.

## Supported SQL

See the [SQL Engine](/guide/sql-engine) guide for the full list of supported
SQL statements and syntax.
