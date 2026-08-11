---
title: "Examples"
description: "Runnable examples demonstrating sqlite.zig features, from basic SQL execution to advanced queries, Raw DSL operations, and schema management."
---

# Examples

Runnable examples demonstrating `sqlite.zig` features.

## Getting Started

| # | Example | Description |
|---|---------|-------------|
| 01 | [Open & Exec](/examples/01-open-and-exec) | Open a database and execute raw SQL |
| 02 | [Prepared Statement](/examples/02-prepared-statement) | Parameterized queries with prepared statements |
| 03 | [Transactions](/examples/03-transactions) | BEGIN, COMMIT, ROLLBACK with typed DSL |

## DSL Basics

| # | Example | Description |
|---|---------|-------------|
| 04 | [DSL Query Builder](/examples/04-dsl-query-builder) | Type-safe comptime query builder basics |
| 09 | [DSL CRUD](/examples/09-dsl-crud) | Full CRUD operations via typed DSL |
| 10 | [DSL Advanced](/examples/10-dsl-advanced) | Advanced DSL queries and predicates |
| 14 | [Select Projections](/examples/14-dsl-select-projections) | SELECT field projections with selectFields() |
| 16 | [Predicates & Pagination](/examples/16-dsl-predicates-pagination) | WHERE predicates with LIMIT/OFFSET |

## Raw DSL

| # | Example | Description |
|---|---------|-------------|
| 48 | [Raw DSL](/examples/48-raw-dsl) | Schema-less runtime-column querying |

## SQL Features

| # | Example | Description |
|---|---------|-------------|
| 05 | [Migrations](/examples/05-migrations) | Schema migration patterns |
| 06 | [Error Handling](/examples/06-error-handling) | Error handling and recovery |
| 11 | [Keys & Joins](/examples/11-keys-and-joins) | Primary keys, foreign keys, and JOIN queries |
| 12 | [Complex Queries](/examples/12-complex-queries) | DISTINCT joins and aggregate functions |
| 13 | [Edge Cases](/examples/13-edge-cases) | NULL handling, savepoints, and error cases |
| 22 | [Views](/examples/22-views) | CREATE VIEW with typed DSL reads |
| 23 | [Triggers](/examples/23-triggers) | BEFORE/AFTER INSERT triggers |
| 35 | [WAL Journal Mode](/examples/35-wal-journal-mode) | WAL and journal mode switching (PRAGMA) |
| 46 | [Raw ALTER TABLE](/examples/46-raw-alter-table) | ADD COLUMN, RENAME, DROP COLUMN |

## Aggregates & Functions

| # | Example | Description |
|---|---------|-------------|
| 20 | [Scalar Functions](/examples/20-scalar-functions) | ABS, LENGTH, UPPER, LOWER, SUBSTR functions |
| 36 | [Grouped Aggregates](/examples/36-grouped-aggregates) | GROUP BY with typed DSL aggregate functions |

## CTEs & Subqueries

| # | Example | Description |
|---|---------|-------------|
| 24 | [CTEs](/examples/24-ctes) | Common Table Expressions with typed reads |
| 25 | [Subqueries](/examples/25-subqueries) | Subqueries in FROM and WHERE clauses |
| 29 | [Multiple CTEs](/examples/29-multiple-ctes) | Multiple CTEs with cross-CTE joins |
| 32 | [Recursive CTEs](/examples/32-recursive-ctes) | Recursive CTEs for hierarchical tree traversal |
| 43 | [NOT IN Subqueries](/examples/43-not-in-subqueries) | Exclusion filtering with NOT IN |
| 44 | [EXISTS Subqueries](/examples/44-exists-subqueries) | Existence checks in WHERE clauses |
| 45 | [Literal IN Lists](/examples/45-literal-in-lists) | Multiple value matching without subqueries |

## Foreign Keys & Constraints

| # | Example | Description |
|---|---------|-------------|
| 26 | [FK Actions](/examples/26-foreign-key-actions) | CASCADE DELETE and SET NULL actions |
| 27 | [Composite Unique](/examples/27-composite-unique) | Composite unique constraints |
| 28 | [FK Update Actions](/examples/28-fk-update-actions) | CASCADE UPDATE and SET DEFAULT actions |
| 30 | [Composite Constraints](/examples/30-composite-constraints) | Composite PRIMARY KEY and UNIQUE |
| 31 | [Composite FKs](/examples/31-composite-foreign-keys) | Composite foreign keys referencing multiple columns |

## Insert Variants & Upserts

| # | Example | Description |
|---|---------|-------------|
| 37 | [Insert...Select Copy](/examples/37-insert-select-copy) | INSERT...SELECT for bulk data duplication |
| 38 | [Insert OR IGNORE](/examples/38-insert-or-ignore) | Conflict-skipping inserts |
| 39 | [UPSERT DO NOTHING](/examples/39-upsert-do-nothing) | Insert-or-skip on conflict |
| 40 | [UPSERT DO UPDATE](/examples/40-upsert-do-update) | Insert-or-update on conflict |
| 41 | [Insert OR REPLACE](/examples/41-insert-or-replace) | Insert-or-delete-and-reinsert on conflict |
| 42 | [UPDATE...FROM JOIN](/examples/42-update-from-join) | Update rows using joined table data |

## Schema & Persistence

| # | Example | Description |
|---|---------|-------------|
| 17 | [Persistence](/examples/17-persistence-reopen) | Data persistence across database close/reopen |
| 18 | [Schema Lifecycle](/examples/18-schema-lifecycle) | CREATE, ALTER, DROP table lifecycle |
| 19 | [Prepared Parameters](/examples/19-prepared-parameter) | Typed parameter binding in prepared statements |
| 21 | [Indexed Queries](/examples/21-indexed-queries) | Index creation and optimized lookups |
| 47 | [Column Defaults](/examples/47-column-defaults) | Column DEFAULT expressions including dynamic defaults |
| 49 | [SQLite Coverage Layers](/examples/49-sqlite-coverage-layers) | Raw SQL, RAW DSL, and typed Zig-first DSL interoperability |

## Query Inspection & Internals

| # | Example | Description |
|---|---------|-------------|
| 33 | [EXPLAIN QUERY PLAN](/examples/33-explain-query-plan) | Inspect query execution plans |
| 34 | [GENERATE_SERIES](/examples/34-virtual-generate-series) | Virtual table for sequence generation |

## Interoperability

| # | Example | Description |
|---|---------|-------------|
| 07 | [Python Interop](/examples/07-python-interop) | Interop with Python sqlite3 module |
| 08 | [Repair Legacy](/examples/08-repair-legacy) | Repair and legacy database handling |
| 15 | [Raw & DSL Interop](/examples/15-raw-dsl-interoperability) | Verify raw SQL and DSL produce identical results |

## Running Examples

```bash
# Run a specific example
zig build run-01_open_and_exec

# Run all examples
zig build run-all-examples
```
