# SQL Engine

`sqlite.zig` includes a hand-written SQL lexer, parser, and bytecode compiler that supports a substantial subset of SQLite's SQL dialect.

## Supported Statements

| Statement | Syntax |
|-----------|--------|
| **CREATE TABLE** | `CREATE TABLE [IF NOT EXISTS] name (columns, constraints)` |
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
| **CREATE VIEW** | `CREATE VIEW name AS SELECT ...` |
| **CREATE TRIGGER** | `CREATE TRIGGER name BEFORE\|AFTER INSERT\|UPDATE\|DELETE ON table ...` |
| **CREATE INDEX** | `CREATE INDEX name ON table (columns)` |

## JOIN Types

- `INNER JOIN` / `JOIN`
- `LEFT [OUTER] JOIN`
- `RIGHT [OUTER] JOIN`
- `FULL [OUTER] JOIN`
- `CROSS JOIN`

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
