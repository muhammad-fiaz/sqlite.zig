---
title: "Catalog API"
description: "Schema definitions, table metadata, and type affinity in the sqlite.zig catalog module."
---

# Catalog API

The catalog module stores live schema metadata: tables, columns,
constraints, indexes, views, and triggers.

## Table Definitions

```zig
const Name = "users";
// Schema columns carry declared type names plus flags:
const col = table.columns[0]; // .name, .typeName, .primaryKey, .notNull,
// .unique, .defaultValue, .foreignTable, .foreignColumn,
// .onDelete, .onUpdate
```

`TableDef.column(name)` resolves a column case-insensitively.

## Schema Management

```zig
var schema = Schema.init(allocator);
defer schema.deinit();

// Clone for backup
var backup = try schema.clone();
defer backup.deinit();
```

`Connection` owns one live `Schema` (`db.store`); transactions and
savepoints snapshot it with `clone()`.

## Type Affinity

Declared type names map to affinities for schema validation:

| Affinity | Matches declarations containing |
|----------|---------------------------------|
| `INTEGER` | `INT` |
| `TEXT` | `CHAR`, `CLOB`, `TEXT` |
| `BLOB` | `BLOB`, or no type at all |
| `REAL` | `REAL`, `FLOA`, `DOUB` |
| `NUMERIC` | anything else (validates against INTEGER/REAL) |

Zig mapping: `int`/`bool` to `INTEGER`, `float` to `REAL`,
`[]const u8` to `TEXT`, everything else to `BLOB`; non-optional fields are
`NOT NULL`, `?T` fields are nullable.

## Index Definitions

```zig
const indexDef = IndexDef{
    .name = "idx_users_email",
    .table = "users",
    .columns = &.{"email"},
    .unique = true,
};
```

Only plain and unique column indexes exist (no partial or expression
indexes). Use `db.createIndex(Table, name, cols, unique)`.

## Key Definitions

```zig
// Primary key
.primaryKey = User.columns.id,

// Composite primary key
.primaryKey = &.{ User.columns.tenant_id, User.columns.user_id },

// Unique
.unique = &.{User.columns.email},

// Foreign key
.foreignKeys = &.{
    .{ .column = Order.columns.user_id, .references = User.columns.id },
},
```

Single-column keys live on the column definition; composite keys become
table constraints. Actions are `.restrict`, `.cascade`, `.setNull`.
