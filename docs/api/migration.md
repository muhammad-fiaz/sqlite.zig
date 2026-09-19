---
title: "Migration API"
description: "Schema migration support for evolving database schemas over time, including version tracking and incremental updates."
---

# Migration API

Schema migration support for evolving database schemas over time.

## Overview

The migration module provides tools for applying schema changes safely, including version tracking and incremental updates.

## Schema Versioning

```zig
const sqlite = @import("sqlite");

var set = sqlite.migration.Set.init(allocator);
defer set.deinit();
try set.add(.{ .version = 1, .upSql = "CREATE TABLE users (id INTEGER);" });

const runner = sqlite.migration.Runner.init(allocator, set.items.items);
const currentVersion = try runner.apply(db);
```

`apply` records progress in a `_zig_migrations` table
(`version INTEGER PRIMARY KEY`), skipping versions already recorded, and
returns the highest applied version. Each migration is a
`sqlite.migration.Migration`:

```zig
pub const Migration = struct {
    version: u32,
    upSql: []const u8,
    downSql: []const u8 = "",
};
```

## Applying Migrations

```zig
// Runner creates and maintains _zig_migrations automatically.
const applied = try runner.apply(db);

// Roll back the most recent migration that defines downSql.
const rolledBack = try runner.rollback(db);
```

Migrations without `downSql` are skipped by `rollback`, which removes the
version row from `_zig_migrations` after running the down SQL.

## Migration Patterns

### Forward-Only

Each migration runs once and the version number increases monotonically:

```zig
const migrations = [_]sqlite.migration.Migration{
    .{ .version = 1, .upSql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);" },
    .{ .version = 2, .upSql = "ALTER TABLE users ADD COLUMN email TEXT;" },
    .{ .version = 3, .upSql = "CREATE INDEX idx_users_email ON users (email);" },
};
const runner = sqlite.migration.Runner.init(allocator, &migrations);
_ = try runner.apply(db);
```

### Rollback Support

Provide `downSql` for every migration that must be reversible:

```zig
const migrations = [_]sqlite.migration.Migration{
    .{
        .version = 1,
        .upSql = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);",
        .downSql = "DROP TABLE users;",
    },
};
```

## Best Practices

- Always check the current version before applying
- Use `IF NOT EXISTS` / `IF EXISTS` for idempotent migrations
- Wrap migrations in transactions for atomicity
- Test migrations against a copy of production data
