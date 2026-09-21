---
title: "UPDATE FROM"
description: "Using UPDATE FROM with equi-join updates from a source table to update rows based on related data."
---

# UPDATE FROM

The engine supports equi-join updates from a source table:

```zig
var result = try db.exec(
    "UPDATE balances SET amount = adjustments.amount " ++
        "FROM adjustments WHERE balances.id = adjustments.id;",
);
defer result.deinit();
```

Source-qualified columns can be used in assignments. Constraint validation,
foreign-key actions, and update triggers still run for changed rows.

Additional `AND` filters apply over each joined pair, and a `WHERE` clause
without an equi-join pair scans the source table as a filter:

```zig
var filtered = try db.exec(
    "UPDATE balances SET flag = 1 FROM adjustments " ++
        "WHERE balances.id = adjustments.bal_id AND adjustments.bonus > 6;",
);
defer filtered.deinit();
```

The typed and dynamic DSL expose the same behavior through
`updateFrom`, with literal assignments:

```zig
var updated = try db.from(Bal)
    .update(.{ .flag = 1 })
    .updateFrom(Adj, Bal.id.eq(Adj.bal_id))
    .execute();
defer updated.deinit();
```
