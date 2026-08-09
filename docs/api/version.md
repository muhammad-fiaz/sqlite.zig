---
title: "Version API"
description: "Database and library version information, including sqlite.zig version constants and SQLite file format version headers."
---

# Version API

Database and library version information.

## Library Version

```zig
const version = @import("version");

// Get sqlite.zig version
const lib_version = version.VERSION;
```

## Database Version

The SQLite file format includes version information in the database header:

| Header Field | Description |
|--------------|-------------|
| Version-valid-for | Schema cookie when this version was written |
| SQLite version number | SQLite version that last modified the database |

## Schema Version

Track schema changes with a version counter:

```zig
// Schema cookie changes whenever the schema is modified
var rows = try db.exec("PRAGMA schema_version;");
defer rows.deinit();
const schema_version = rows.rows[0][0].integer;
```

## User Version

A user-defined version number stored in the header:

```zig
// Set user version
var result = try db.exec("PRAGMA user_version = 1;");
result.deinit();

// Get user version
var rows = try db.exec("PRAGMA user_version;");
defer rows.deinit();
const user_version = rows.rows[0][0].integer;
```
