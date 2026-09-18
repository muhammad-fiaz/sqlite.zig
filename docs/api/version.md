---
title: "Version API"
description: "Database and library version information, including sqlite.zig version constants and SQLite file format version headers."
---

# Version API

Database and library version information.

## Library Version

```zig
const version = @import("version");

// SQLite source snapshot this engine implements (mirrors sqlite/VERSION)
const engine = version.sqliteEngineVersion;
const source = version.sqliteSourceVersion;
```

## Database Version

The SQLite file format includes version information in the database header:

| Header Field | Description |
|--------------|-------------|
| Version-valid-for | Schema cookie when this version was written |
| SQLite version number | SQLite version that last modified the database |

## Schema Version

Implemented PRAGMAs are `foreign_keys`, `user_version`, `application_id`,
and `journal_mode`. Other PRAGMAs, including `schema_version`, return an
unsupported-feature error rather than a fabricated value.

## User Version

A user-defined version number stored in the header:

```zig
// Set user version
var result = try db.exec("PRAGMA user_version = 1;");
result.deinit();

// Get user version
var rows = try db.exec("PRAGMA user_version;");
defer rows.deinit();
const userVersion = rows.rows[0][0].integer;
```
