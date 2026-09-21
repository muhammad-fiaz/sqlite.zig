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

Column lookup on a live table is case-insensitive:

```zig
const found = schema.find("USERS"); // same table as "users"
```

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
// Stored index over a table's columns, with optional partial predicate
// and expression keys:
const index = schema.findIndex("idx_users_email").?;
// .name, .table, .columns, .keyExprs, .unique, .whereExpr, .whereSql
```

Plain, unique, partial (`WHERE`), and expression indexes are supported.
Use `db.createIndex(Table, name, cols, unique)`,
`db.createIndexWhere(...)`, or `db.createIndexExpr(...)`.

## Key Definitions

```zig
// Primary key
.primaryKey = User.id,

// Composite primary key
.primaryKey = &.{ User.tenant_id, User.user_id },

// Unique
.unique = &.{User.email},

// Foreign key
.foreignKeys = &.{
    .{ .column = Order.user_id, .references = User.id },
},
```

Single-column keys live on the column definition; composite keys become
table constraints. Actions are `.restrict`, `.cascade`, `.setNull`,
`.setDefault`, and `.noAction`.
