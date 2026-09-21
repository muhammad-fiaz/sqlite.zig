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

`apply` records progress in a `_zig_migrations` history table
(`version INTEGER PRIMARY KEY, name TEXT, checksum TEXT`), skipping versions
already recorded after verifying their checksums, and returns the highest
applied version. Each migration is a `sqlite.migration.Migration`:

```zig
pub const Migration = struct {
    version: u32,
    name: []const u8 = "",
    upSql: []const u8,
    downSql: []const u8 = "",
};
```

## Version concepts

Three different counters exist; the runner never conflates them:

- `PRAGMA schema_version`: the engine's internal schema cookie, bumped on
  every DDL change. Never use it as a migration counter.
- `PRAGMA user_version`: an opaque 32-bit application marker the engine
  never interprets. The runner leaves it untouched.
- `Migration.version`: the monotonically ordered application-migration
  number. The `_zig_migrations` history table is authoritative for it.

## Guarantees

- **Ordering**: migrations apply in ascending `version` order regardless of
  input order. Filesystem or insertion order is never trusted.
- **Atomicity**: each migration runs in its own transaction and the history
  row is written only after the migration body succeeds. A failed migration
  is never marked applied.
- **Idempotence**: re-running `apply` skips applied versions after checksum
  verification.
- **Duplicate detection**: two migrations sharing a version report
  `error.DuplicateMigration`.
- **Gap detection**: a history peak of 5 with a set starting at 7 reports
  `error.MissingMigration` instead of skipping version 6. Applying a version
  at or below the peak that was never applied is likewise rejected.
- **Modification detection**: editing the name or SQL of an already-applied
  migration changes its checksum and reports `error.ModifiedMigration`.
- **Raw SQL equivalence**: `upSql`/`downSql` run through `Connection.exec`,
  so a migration performs exactly the same native operations as the
  equivalent hand-run statements. The runner is orchestration, not a second
  schema engine.
- **Transaction boundaries**: `VACUUM` cannot run inside a transaction. A
  migration containing a top-level `VACUUM` must hold that statement alone
  and runs outside a transaction; mixing it with other statements reports
  `error.InvalidSql`.

## Applying Migrations

```zig
// Runner creates and maintains _zig_migrations automatically.
const applied = try runner.apply(db);

// Roll back the most recent migration that defines downSql.
const rolledBack = try runner.rollback(db);
```

Migrations without `downSql` cannot be rolled back: `rollback` reports
`error.NoDownMigration` instead of guessing a reverse operation. Arbitrary
SQL is never auto-reversed.

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
