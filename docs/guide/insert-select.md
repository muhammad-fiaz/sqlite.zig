---
title: "INSERT SELECT"
description: "Inserting query results into another table using INSERT ... SELECT with raw SQL."
---

# INSERT SELECT

Query results can be inserted into another table using raw SQL:

```zig
var result = try db.exec(
    "INSERT INTO archive SELECT id, label FROM active_items WHERE id > 100;",
);
defer result.deinit();
```

The destination column list is optional when the selected column count matches
the destination schema, or it can be specified explicitly:

```sql
INSERT INTO archive (id, label) SELECT item_id, title FROM source_items;
```

The typed and dynamic DSL copy through `insertSelect` (plus
`insertSelectOrIgnore` / `insertSelectOrReplace`), mapping source columns
positionally and running the same constraint, trigger, and `RETURNING`
handling as single-row inserts:

```zig
var copied = try db.from(Archive)
    .insertSelect(db.from(Active).select(.{ Active.columns.id, Active.columns.label }));
defer copied.deinit();
```
