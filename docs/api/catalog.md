---
title: "Catalog API"
description: "Schema definitions, table metadata, and type affinity management for the sqlite.zig catalog module."
---

# Catalog API

The catalog module manages schema definitions, table metadata, and type affinity.

## Table Definitions

```zig
const catalog = @import("catalog");

// Table definition
const table_def = catalog.TableDef{
    .name = "users",
    .columns = &.{
        .{ .name = "id", .type = .integer, .primary_key = true },
        .{ .name = "name", .type = .text },
    },
};
```

## Schema Management

```zig
const schema = @import("schema");

// Get current schema
const current_schema = try schema.Schema.init(allocator, &connection);

// Clone for backup
const backup = try current_schema.clone();
```

## Type Affinity

SQLite uses type affinity to determine how values are stored:

| Affinity | Storage | Description |
|----------|---------|-------------|
| `INTEGER` | 1-8 bytes | Whole numbers |
| `REAL` | 8 bytes | Floating-point |
| `TEXT` | Variable | Text strings |
| `BLOB` | Variable | Binary data |
| `NULL` | 0 bytes | Null values |

## Column Definitions

```zig
const column = catalog.ColumnDef{
    .name = "email",
    .type = .text,
    .nullable = false,
    .unique = true,
};
```

## Index Definitions

```zig
const index_def = catalog.IndexDef{
    .name = "idx_users_email",
    .table_name = "users",
    .columns = &.{"email"},
    .unique = true,
};
```

## Key Definitions

```zig
// Primary key
const pk = User.key("id");

// Composite primary key
const cpk = &.{ User.key("a"), User.key("b") };
```
