---
title: "CTEs & Subqueries"
description: "Common Table Expressions (CTEs) and subqueries including recursive CTEs, multiple CTEs, and nested subqueries."
---

# CTEs & Subqueries

## Common Table Expressions (CTEs)

CTEs provide named temporary result sets within a single query.

### Basic CTE

```zig
var rows = try db.exec(
    \\WITH active AS (
    \\  SELECT id, name FROM users WHERE active = 1
    \\)
    \\SELECT * FROM active;
);
defer rows.deinit();
```

### Multiple CTEs

```zig
var rows = try db.exec(
    \\WITH
    \\  high_value AS (SELECT id, amount FROM orders WHERE amount > 100),
    \\  customer AS (SELECT id, name FROM users)
    \\SELECT id, name FROM customer ORDER BY id;
);
defer rows.deinit();
```

Later CTEs can read earlier ones:

```zig
var chained = try db.exec(
    \\WITH first_set AS (SELECT id FROM source WHERE id >= 2),
    \\     second_set AS (SELECT id FROM first_set)
    \\SELECT id FROM second_set ORDER BY id;
);
defer chained.deinit();
```

### Recursive CTEs

Recursive CTEs iterate to a fixpoint (bounded at 1000 iterations):

```zig
var rows = try db.exec(
    \\WITH RECURSIVE nums AS (
    \\  SELECT 1 AS n
    \\  UNION ALL
    \\  SELECT n + 1 AS n FROM nums WHERE n < 5
    \\)
    \\SELECT n FROM nums ORDER BY n;
);
defer rows.deinit();
```

Table aliases (`FROM nodes n`) are not supported; use full table names.

## Subqueries

### Subquery in WHERE

```zig
var rows = try db.exec(
    \\SELECT * FROM users
    \\WHERE id IN (SELECT user_id FROM orders WHERE amount > 100)
);
defer rows.deinit();
```

### EXISTS Subquery

```zig
var rows = try db.exec(
    \\SELECT * FROM users u
    \\WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id)
);
defer rows.deinit();
```

### Subqueries in FROM and SELECT lists

Derived tables (`FROM (SELECT ...)`) and scalar subqueries in the projection
list are not supported by the engine. Express them with CTEs plus joins, or
with `IN` / `EXISTS` predicates (all supported, including correlated
`EXISTS`):

```zig
var rows = try db.exec(
    \\WITH stats AS (SELECT user_id, AVG(amount) AS avg_amount FROM orders GROUP BY user_id)
    \\SELECT user_id, avg_amount FROM stats ORDER BY user_id;
);
defer rows.deinit();
```
