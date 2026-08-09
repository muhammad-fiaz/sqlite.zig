# SQL Engine

`sqlite.zig` includes a hand-written SQL lexer, parser, and bytecode compiler that supports a substantial subset of SQLite's SQL dialect.

## Supported Statements

| Statement | Syntax |
|-----------|--------|
| **CREATE TABLE** | `CREATE TABLE [IF NOT EXISTS] name (columns [DEFAULT literal], constraints)` |
| **DROP TABLE** | `DROP TABLE [IF EXISTS] name` |
| **INSERT** | `INSERT INTO name VALUES (...)` or `INSERT INTO name (cols) VALUES (...)` |
| **SELECT** | `SELECT [DISTINCT] columns FROM table [JOIN ...] [WHERE ...] [GROUP BY ...] [HAVING ...] [ORDER BY ...] [LIMIT ... [OFFSET ...]]` |
| **UPDATE** | `UPDATE name SET col = expr [WHERE ...]` |
| **DELETE** | `DELETE FROM name [WHERE ...]` |
| **BEGIN** | `BEGIN [DEFERRED\|IMMEDIATE\|EXCLUSIVE]` |
| **COMMIT** | `COMMIT` or `END` |
| **ROLLBACK** | `ROLLBACK [TO [SAVEPOINT] name]` |
| **SAVEPOINT** | `SAVEPOINT name` |
| **RELEASE** | `RELEASE [SAVEPOINT] name` |
| **CREATE VIEW** | `CREATE VIEW [IF NOT EXISTS] name AS SELECT ...` |
| **CREATE TRIGGER** | `CREATE TRIGGER [IF NOT EXISTS] name BEFORE\|AFTER INSERT\|UPDATE\|DELETE ON table ...` |
| **CREATE INDEX** | `CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON table (columns)` |
| **ALTER TABLE** | `ADD COLUMN`, `RENAME TO`, `RENAME COLUMN ... TO`, and `DROP COLUMN` |

## JOIN Types

- `INNER JOIN` / `JOIN`
- `LEFT [OUTER] JOIN`
- `RIGHT [OUTER] JOIN`
- `FULL [OUTER] JOIN`
- `CROSS JOIN`

Comparison predicates include `LIKE` and `NOT LIKE`; a NULL operand produces no
match, following SQLite's three-valued predicate behavior. The typed DSL exposes
these as `column.like(pattern)` and `column.notLike(pattern)`.

Literal membership lists are supported in raw SQL (`id IN (1, 3, 4)` and
`id NOT IN (1, 3, 4)`) and in the checked DSL through
`whereInValues(ColumnKey, values)` and `whereNotInValues(ColumnKey, values)`.

SQLite identity predicates are also supported: `IS`, `IS NOT`, `IS NULL`, and
`IS NOT NULL`. The typed equivalents for value identity are
`column.isValue(value)` and `column.isNotValue(value)`.

## WHERE Clauses

Standard comparison operators: `=`, `!=`, `<>`, `<`, `>`, `<=`, `>=`, `LIKE`, `NOT LIKE`, `IS NULL`, `IS NOT NULL`, `BETWEEN ... AND ...`, `IN (...)`, `NOT IN (...)`, `EXISTS (...)`.

## Aggregate Functions

`COUNT(*)`, `SUM(column)`, `AVG(column)`, `MIN(column)`, `MAX(column)`.

## Scalar Functions

`ABS(x)`, `LENGTH(x)`, `UPPER(x)`, `LOWER(x)`, `SUBSTR(x, start, length)`.

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
