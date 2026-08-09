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
