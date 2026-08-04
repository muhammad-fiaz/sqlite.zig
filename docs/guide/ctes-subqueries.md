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
    \\SELECT c.name, h.amount
    \\FROM customer c
    \\INNER JOIN high_value h ON c.id = h.id;
);
defer rows.deinit();
```

### Recursive CTEs

Recursive CTEs traverse hierarchical data like tree structures:

```zig
var rows = try db.exec(
    \\WITH RECURSIVE tree AS (
    \\  SELECT id, name, parent_id, 0 AS depth
    \\  FROM nodes WHERE parent_id IS NULL
    \\  UNION ALL
    \\  SELECT n.id, n.name, n.parent_id, t.depth + 1
    \\  FROM nodes n
    \\  INNER JOIN tree t ON n.parent_id = t.id
    \\)
    \\SELECT * FROM tree ORDER BY depth;
);
defer rows.deinit();
```

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

### Subquery in FROM (Derived Table)

```zig
var rows = try db.exec(
    \\SELECT avg_amount, user_count FROM (
    \\  SELECT user_id, AVG(amount) AS avg_amount
    \\  FROM orders GROUP BY user_id
    \\) stats
    \\INNER JOIN (
    \\  SELECT user_id, COUNT(*) AS user_count
    \\  FROM orders GROUP BY user_id
    \\) counts ON stats.user_id = counts.user_id
);
defer rows.deinit();
```

### Scalar Subquery

```zig
var rows = try db.exec(
    \\SELECT name, (SELECT COUNT(*) FROM orders WHERE user_id = users.id) AS order_count
    \\FROM users
);
defer rows.deinit();
```
