# Migration API

Schema migration support for evolving database schemas over time.

## Overview

The migration module provides tools for applying schema changes safely, including version tracking and incremental updates.

## Schema Versioning

```zig
const migration = @import("migration");

// Track schema version
var current_version = try migration.getVersion(&connection);
```

## Applying Migrations

```zig
// Create migration table
var result = try db.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY);");
result.deinit();

// Check current version
var rows = try db.exec("SELECT MAX(version) FROM schema_version;");
defer rows.deinit();

// Apply migration if needed
const current = rows.rows[0][0].integer;
if (current < 2) {
    // Apply migration 2
    try db.exec("ALTER TABLE users ADD COLUMN email TEXT;");
    try db.exec("INSERT INTO schema_version VALUES (2);");
}
```

## Migration Patterns

### Forward-Only

Each migration runs once and the version number increases monotonically:

```zig
const migrations = [_][]const u8{
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);",
    "ALTER TABLE users ADD COLUMN email TEXT;",
    "CREATE INDEX idx_users_email ON users (email);",
};
```

### Rollback Support

Track both forward and rollback SQL:

```zig
const Migration = struct {
    version: i64,
    up: []const u8,
    down: []const u8,
};
```

## Best Practices

- Always check the current version before applying
- Use `IF NOT EXISTS` / `IF EXISTS` for idempotent migrations
- Wrap migrations in transactions for atomicity
- Test migrations against a copy of production data
