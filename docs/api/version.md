---
title: "Version API"
description: "Database and library version information, including sqlite.zig version constants and SQLite file format version headers."
---

# Version API

Database and library version information.

## Library Version

```zig
const sqlite = @import("sqlite");

// Engine version string, e.g. "3.54.0".
const engine = sqlite.version.sqliteEngineVersion;
// sqlite.zig library version, e.g. "0.0.1".
const library = sqlite.version.sqliteVersion;
```

## Database Version

The 100-byte database header (`src/format/header.zig`) carries the fields
the engine actually reads and writes:

| Header Field | Description |
|--------------|-------------|
| page size | Database page size in bytes |
| change counter | Incremented on each write transaction |
| database size | Size of the database in pages |
| freelist | First freelist page and freelist page count |
| schema cookie | Schema version cookie |
| schema format | Schema format number |
| text encoding | Text encoding (`1` for UTF-8) |
| user version | Value of `PRAGMA user_version` |
| application id | Value of `PRAGMA application_id` |

## Schema Version

Implemented PRAGMAs are `foreign_keys`, `user_version`, `application_id`,
`journal_mode`, `synchronous`, `cache_size`, `page_size`, `encoding`,
`busy_timeout`, `locking_mode`, `auto_vacuum`, `integrity_check`, and
`foreign_key_check`. Other PRAGMAs return an unsupported-feature error
rather than a fabricated value.

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
