---
title: "Column Mapping"
description: "Map camelCase Zig fields onto unchanged SQL column names."
---

# Column Mapping

SQL identifiers stay exactly as they exist in the database while Zig code
uses camelCase fields:

```zig
const User = sqlite.table("mapped_users", .{
    .firstName = sqlite.column("first_name", []const u8),
    .ageYears = sqlite.column("age_years", i64),
});
```

## What This Example Does

| Step | Operation | Description |
|------|-----------|-------------|
| 1 | Raw SQL creates `mapped_users` | Legacy snake_case schema |
| 2 | `db.from("mapped_users")` | Dynamic DSL reads SQL names directly |
| 3 | `db.schema(User).validate()` | Typed schema adopts the table |
| 4 | `db.from(User).where(...)` | Typed queries use Zig names, mapped rows |
| 5 | Raw `SELECT first_name ...` | Same database, unchanged SQL names |

## Source Code

```zig
var typed = try db.from(User).where(User.columns.ageYears.gte(18)).fetch();
defer typed.deinit();

var inserted = try db.from(User).insert(.{ .firstName = "Ada", .ageYears = 36 });
inserted.deinit();
```

Inserts, updates, validation, and typed mapping translate Zig names to SQL
names in both directions. Key options (`.primaryKey`, `.unique`,
`.foreignKeys`) always use SQL column names; column descriptors resolve
automatically.

## Zig Output

```text
52 column mapping: zig names map onto sql names in every mode
```

> [!TIP]
> Run with: `zig build run-52_column_mapping`
