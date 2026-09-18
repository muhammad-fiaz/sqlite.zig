---
title: "Grouped Aggregates"
description: "Grouped aggregate projections with GROUP BY using COUNT, SUM, AVG, MIN, and MAX functions."
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

The grouped executor supports `COUNT`, `SUM`, `AVG`, `MIN`, and `MAX`. The
typed DSL continues to support scalar aggregates through its aggregate methods,
plus grouped aggregate filters with `groupBy(...).havingCount(...)`.

```zig
var rows = try db.from(Sale)
    .select(.{Sale.columns.amount.sum()})
    .groupBy(Sale.columns.category)
    .havingCount(">", 1)
    .fetch();
defer rows.deinit();
```
