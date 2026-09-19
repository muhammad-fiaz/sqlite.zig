---
title: "SQL Engine"
description: "The hand-written SQL lexer, parser, and bytecode compiler supporting a substantial subset of SQLite's SQL dialect."
---

# SQL Engine

`sqlite.zig` includes a hand-written SQL lexer, parser, and bytecode compiler that supports a substantial subset of SQLite's SQL dialect.

## Supported Statements

| Statement | Syntax |
|-----------|--------|
| **CREATE TABLE** | `CREATE TABLE [IF NOT EXISTS] name (columns [DEFAULT literal], constraints)` |
| **DROP TABLE** | `DROP TABLE [IF EXISTS] name` |
| **INSERT** | `INSERT INTO name VALUES (...)` or `INSERT INTO name (cols) VALUES (...)` |
| **SELECT** | `SELECT [DISTINCT] columns FROM table [JOIN ...] [WHERE ...] [GROUP BY ...] [HAVING ...] [ORDER BY ...] [LIMIT ... [OFFSET ...]]` |
| **UPDATE** | `UPDATE name SET col = expr [WHERE ...]` and `UPDATE name SET ... FROM source WHERE join [AND ...]` |
| **DELETE** | `DELETE FROM name [WHERE ...]` |
| **BEGIN** | `BEGIN [DEFERRED\|IMMEDIATE\|EXCLUSIVE]` or `START TRANSACTION` |
| **COMMIT** | `COMMIT` |
| **ROLLBACK** | `ROLLBACK [TO [SAVEPOINT] name]` |
| **SAVEPOINT** | `SAVEPOINT name` |
| **RELEASE** | `RELEASE [SAVEPOINT] name` |
| **CREATE VIEW** | `CREATE VIEW [IF NOT EXISTS] name AS SELECT ...` |
| **CREATE TRIGGER** | `CREATE TRIGGER [IF NOT EXISTS] name [BEFORE\|AFTER] INSERT\|UPDATE\|DELETE ON table [WHEN ...] ...` |
| **CREATE INDEX** | `CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON table (columns)` |
| **ALTER TABLE** | `ADD COLUMN`, `RENAME TO`, `RENAME COLUMN ... TO`, and `DROP COLUMN` |
| **UPSERT** | `INSERT ... ON CONFLICT [(cols)] [WHERE ...] DO NOTHING` / `DO UPDATE SET ...` with `excluded` |
| **RETURNING** | `INSERT/UPDATE/DELETE ... RETURNING ...` |
| **Compound SELECT** | `UNION [ALL]`, `INTERSECT`, `EXCEPT` with `ORDER BY` / `LIMIT` / `OFFSET` |
| **CTE** | `WITH ...` / `WITH RECURSIVE ...` |
| **VACUUM** | `VACUUM [main]` rebuilds the database; `VACUUM INTO 'file'` writes a copy |
| **EXPLAIN QUERY PLAN** | `EXPLAIN QUERY PLAN SELECT ...` reports index use vs table scans |
| **CREATE VIRTUAL TABLE** | `generate_series` module only; other modules return an explicit error |
| **DROP** | `DROP TABLE/INDEX/VIEW/TRIGGER [IF EXISTS] name` |
| **PRAGMA** | `foreign_keys`, `user_version`, `application_id`, `schema_version`, `journal_mode`, `wal_checkpoint`, `synchronous`, `cache_size`, `page_size`, `encoding`, `busy_timeout`, `locking_mode`, `auto_vacuum`, `recursive_triggers`, `integrity_check`, `foreign_key_check`, `table_info`, `table_xinfo`, `table_list`, `index_list`, `index_info`, `index_xinfo`, `foreign_key_list`, `database_list` |

`ATTACH` and `DETACH` parse but return an explicit unsupported-feature error.

Partial (`WHERE`) and expression indexes are supported: `CREATE [UNIQUE]
INDEX name ON table (columns) WHERE predicate` indexes only matching rows
(enforcing uniqueness among them), and index keys accept expressions such as
`lower(email)`. Predicates and keys must reference the indexed table's
columns; subqueries, aggregates, and window functions are rejected with an
explicit error. The planner uses a partial index only when the query implies
its predicate, and an expression index only for matching expressions.

## JOIN Types

- `INNER JOIN` / `JOIN`
- `LEFT [OUTER] JOIN`
- `RIGHT [OUTER] JOIN`
- `FULL [OUTER] JOIN`
- `CROSS JOIN`
- `... USING (col[, ...])` and `NATURAL [...] JOIN` with merged-column output

Joins chain across 3+ tables, and `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`,
`LIMIT`, and `OFFSET` all apply over join results.

Comparison predicates include `LIKE` and `NOT LIKE`; a NULL operand produces no
match, following SQLite's three-valued predicate behavior. The typed DSL exposes
these as `column.like(pattern)` and `column.notLike(pattern)`.

`LIKE` folds ASCII letters by default, while `GLOB` remains case-sensitive, matching
SQLite's standard distinction between the two operators.

NULL-safe comparisons are available with `IS DISTINCT FROM` and
`IS NOT DISTINCT FROM`; the typed equivalents are `isDistinctFrom` and
`isNotDistinctFrom`.

Case-sensitive Unix-style matching is also available with `GLOB` in raw SQL and
`column.glob(pattern)` in the typed DSL. `NOT GLOB` and `column.notGlob(pattern)`
are also supported. Patterns support `*`, `?`, and simple character classes such
as `[A-Z]`.

The text projection functions `TRIM`, `LTRIM`, and `RTRIM` are supported in raw
SQL and as column wrappers (`.trim()`, `.ltrim()`, `.rtrim()`) usable in both
`select` projections and `where` predicates in either DSL mode.

Multi-argument scalar functions `REPLACE(value, search, replacement)` and
`SUBSTR(value, start, length)` are also supported in raw SQL, with column
wrappers `.replace(search, replacement)` and `.substr(start, length)`.

`COALESCE`, `IFNULL`, and `INSTR(value, needle)` are supported as well via
`.coalesce(fallback)`, `.ifNull(fallback)`, and `.instr(needle)`.

`NULLIF(value, other)` is supported in raw SQL.

The numeric `ROUND(value, digits)` function is available in raw SQL and as
`.round(digits)` in the DSL.

Common casts are supported with `CAST(value AS <type>)` for every SQLite
type name (affinity-routed, so `BIGINT`, `VARCHAR(10)`, `DOUBLE PRECISION`,
`DECIMAL`, and `BOOLEAN` all convert correctly); the DSL exposes
`.cast("INTEGER")` with compile-time column validation.

The JSON1 family includes `json`, `json_extract`, `json_set`,
`json_insert`, `json_replace`, `json_remove`, `json_array`, `json_object`,
`json_type`, and `json_valid` over nested objects and arrays with `$.a[0]`
style paths, exposed in the DSL as `.jsonExtract(path)` /
`.jsonSet(path, value)`.

Function expressions such as `WHERE LOWER(name) = 'alice'` and
`WHERE TRIM(name) = 'alice'` are supported on the left side of comparison
predicates, including numeric expressions such as `WHERE INSTR(name, 'x') > 0`;
in the DSL these are `col.lower().eq("alice")` style wrappers.

Literal membership lists are supported in raw SQL (`id IN (1, 3, 4)` and
`id NOT IN (1, 3, 4)`) and in both DSL modes through
`whereInValues(col, values)` and `whereNotInValues(col, values)`.

SQLite identity predicates are also supported: `IS`, `IS NOT`, `IS NULL`, and
`IS NOT NULL`. The typed equivalents for value identity are
`column.is(value)` and `column.isNot(value)`.

## WHERE Clauses

Standard comparison operators: `=`, `!=`, `<>`, `<`, `>`, `<=`, `>=`, `LIKE`, `NOT LIKE`, `IS NULL`, `IS NOT NULL`, `BETWEEN ... AND ...`, `IN (...)`, `NOT IN (...)`, `EXISTS (...)`.

## Aggregate Functions

`COUNT(*)`, `SUM(column)`, `AVG(column)`, `TOTAL(column)`, `MIN(column)`,
`MAX(column)`, `GROUP_CONCAT` — each accepting `DISTINCT`
(`COUNT(DISTINCT col)`, `SUM(DISTINCT col)`, …) in bare, grouped, joined,
and subquery selects.
Date/time (`date`, `time`, `datetime`, `julianday`, `unixepoch`,
`strftime`), math (`ceil`, `floor`, `sqrt`, `log`, `pow`, `sin`, `cos`,
…), and window functions (`ROW_NUMBER`, `RANK`, `LAG`, `LEAD`, …) are
supported in Raw SQL. The DSL provides column wrappers for scalar helpers
(`abs`, `length`, `upper`, `lower`, `jsonExtract`, `jsonSet`), aggregates,
and window functions; date/time and math functions have no DSL wrappers yet,
so call them through Raw SQL.

## Scalar Functions

`ABS(x)`, `LENGTH(x)`, `UPPER(x)`, `LOWER(x)`, `SUBSTR(x, start, length)`,
`REPLACE`, `TRIM`/`LTRIM`/`RTRIM`, `INSTR`, `HEX`, `UNHEX`, `QUOTE`, `CHAR`,
`UNICODE`, `PRINTF`/`FORMAT`, `ROUND`, `TYPEOF`, `COALESCE`, `IFNULL`,
`NULLIF`.

## Storage Classes vs Declared Types

SQLite has exactly five runtime storage classes:

```text
NULL, INTEGER, REAL, TEXT, BLOB
```

Declared column types such as `INTEGER`, `INT`, `TEXT`, `VARCHAR(255)`,
`DECIMAL(10,2)`, `BOOLEAN`, `DATE`, `DATETIME`, or `BLOB` are *declared type
names*, not storage classes. The engine maps each declared name to a type
affinity (`INTEGER`, `TEXT`, `BLOB`, `REAL`, or `NUMERIC`) following SQLite's
rules — a name containing `INT` gets `INTEGER` affinity, one containing
`CHAR`/`CLOB`/`TEXT` gets `TEXT` affinity, and so on — and coerces values
accordingly. There are no separate `DATE`, `BOOLEAN`, or `DECIMAL` storage
classes: a `DATETIME` column stores whatever value affinity rules produce
(usually `TEXT` or `INTEGER`), and the declared type string is preserved in
the schema.

## CREATE TABLE Support

Table definitions support declared types with full SQLite type names
(including precision such as `DECIMAL(10,2)`), plus:

- `PRIMARY KEY` and composite `PRIMARY KEY (a, b)`
- `UNIQUE` and composite `UNIQUE`
- `NOT NULL`, `DEFAULT <literal>`
- `CHECK (...)` enforced on `INSERT`/`UPDATE` with SQLite `NULL` semantics
- `FOREIGN KEY` (column- and table-level, incl. composite) with `CASCADE`,
  `SET NULL`, `SET DEFAULT`, `RESTRICT`, and `NO ACTION`
- Generated columns: `GENERATED ALWAYS AS (...) VIRTUAL` / `STORED`
- `STRICT` tables (values outside the declared type are rejected) and
  `WITHOUT ROWID` tables (keyed by primary key)

Plain and `UNIQUE` column indexes are supported, as are partial indexes
(`CREATE INDEX ... WHERE predicate`, uniqueness enforced among matching rows
only) and expression index keys (`CREATE INDEX ... ON t (lower(email))`,
uniqueness enforced on computed values).

## Architecture

SQL text flows through the native pipeline:

```text
SQL → lexer/parser → AST → resolver → planner → executor → storage → transactions
```

The hand-written lexer and parser produce an AST. The connection resolves
names against the schema catalog, consults the planner for index selection
(see `EXPLAIN QUERY PLAN`), evaluates the shared expression and function
subsystem (`IS`, `BETWEEN`, `CASE`, `CAST`, aggregates, window functions),
and persists through the SQLite-compatible on-disk image with journal/WAL
durability. A bytecode compiler and VM (`src/vm/`) implement the same
execution model for compiled programs. Triggers, views, foreign-key actions,
and constraints all run inside this same engine — never as a second pass.

## Example

```zig
// Complex SELECT with JOIN, WHERE, ORDER BY, and LIMIT
var result = try db.exec(
    \\SELECT u.name, SUM(o.amount) AS total
    \\FROM users u
    \\INNER JOIN orders o ON u.id = o.user_id
    \\WHERE o.amount > 10
    \\GROUP BY u.name
    \\HAVING total > 50
    \\ORDER BY total DESC
    \\LIMIT 10
);
defer result.deinit();
```
