---
title: "Conflict Handling"
description: "Handling constraint conflicts with INSERT OR IGNORE, UPSERT DO NOTHING, and UPSERT DO UPDATE patterns."
---

# Conflict Handling

Use `INSERT OR IGNORE` when importing data and duplicate constraint rows
should be skipped without aborting the statement:

```zig
var result = try db.exec(
    "INSERT OR IGNORE INTO items (id, label) VALUES (1, 'existing'), (2, 'new');",
);
defer result.deinit();
```

The incoming row is available through `excluded.column`:

```sql
INSERT INTO items (id, label) VALUES (1, 'new')
ON CONFLICT(id) DO UPDATE SET label = excluded.label;
```

Supported expressions can also use incoming values, for example
`amount = excluded.amount + 1`.

An optional `WHERE` clause can prevent an update while still treating the
conflict as handled:

```sql
INSERT INTO items (id, label) VALUES (1, 'new')
ON CONFLICT(id) DO UPDATE SET label = excluded.label
WHERE enabled = 1;
```

`INSERT OR REPLACE` deletes the conflicting row, applies its foreign-key delete
actions, and inserts the replacement row:

```zig
var result = try db.exec("INSERT OR REPLACE INTO items VALUES (1, 'replacement');");
defer result.deinit();
```

`Result.changes` reports only rows actually inserted.

The typed DSL exposes the same modes while retaining compile-time row-field
validation:

```zig
var ignored = try db.from(Item).insertIgnore(.{ .id = 1, .label = "duplicate" });
ignored.deinit();
var replaced = try db.from(Item).insertReplace(.{ .id = 1, .label = "new value" });
replaced.deinit();
```

The modern UPSERT spelling is also supported:

```zig
var result = try db.exec(
    "INSERT INTO items (id, label) VALUES (1, 'new') " ++
        "ON CONFLICT(id) DO NOTHING;",
);
defer result.deinit();
```

Conflicts can update the existing row:

```zig
var result = try db.exec(
    "INSERT INTO items (id, label) VALUES (1, 'replacement') " ++
        "ON CONFLICT(id) DO UPDATE SET label = 'updated';",
);
defer result.deinit();
```
