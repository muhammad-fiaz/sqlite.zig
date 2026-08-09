---
title: "Subqueries"
description: "Using subqueries in raw SQL and the typed DSL, including NOT IN, WHERE IN, and anti-subquery patterns."
---

# Subqueries

Raw SQL and the typed DSL support anti-subqueries:

```zig
var rows = try db.from(User)
    .whereNotInColumn(User.key("id"), Blocked, Blocked.key("user_id"))
    .fetchAll();
defer rows.deinit();
```

The equivalent raw SQL is:

```sql
SELECT id FROM users WHERE id NOT IN (SELECT user_id FROM blocked);
```

Raw SQL also supports uncorrelated and correlated existence predicates. A correlated
predicate may reference the outer table by its qualified name and is evaluated once
for each outer row:

```sql
SELECT id
FROM users
WHERE EXISTS (
    SELECT 1 FROM orders
    WHERE orders.user_id = users.id
);
```

`NOT EXISTS (...)` uses the same row-by-row evaluation and is useful for anti-joins.

The typed DSL provides the corresponding checked APIs:

```zig
const matching = try db.from(User)
    .whereExistsKey(Order, Order.key("user_id"), User.key("id"))
    .fetchAll();
```

Use `whereNotExistsKey` for the anti-join form, or `whereExists(OtherTable)` when
only the presence of any row in the other table matters. Table and column names
are validated at compile time.
