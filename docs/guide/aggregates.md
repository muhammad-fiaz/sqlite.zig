---
title: "Grouped Aggregates"
description: "Aggregate projections with GROUP BY in sqlite.zig: COUNT, SUM, AVG, TOTAL, MIN, MAX, and GROUP_CONCAT."
---

# Grouped Aggregates

Raw SQL supports grouped aggregate projections with `GROUP BY`:

```zig
var rows = try db.exec(
    "SELECT category, COUNT(*), SUM(amount), AVG(amount) " ++
        "FROM sales GROUP BY category;",
);
defer rows.deinit();
```

Aggregates work with and without `GROUP BY`: `COUNT` (including
`COUNT(DISTINCT col)`), `SUM`, `AVG`, `TOTAL`, `MIN`, `MAX`, and
`GROUP_CONCAT`. The typed DSL exposes the same set through column aggregate
methods (`.sum()`, `.avg()`, `.min()`, `.max()`, `.count()`,
`.countDistinct()`), plus grouped aggregate filters with
`groupBy(...).havingCount(...)`.

```zig
var rows = try db.from(Sale)
    .select(.{Sale.columns.amount.sum()})
    .groupBy(Sale.columns.category)
    .havingCount(">", 1)
    .fetch();
defer rows.deinit();
```
