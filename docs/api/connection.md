---
title: "Connection API"
description: "The Connection type providing the primary interface for database operations including open, close, exec, and prepared statements."
---

# Connection API

The `Connection` type is the primary interface for database operations.

## Opening & Closing

```zig
const sqlite = @import("sqlite");

var db = try sqlite.open(std.heap.page_allocator, "my.db");
defer db.close();
```

## Executing Raw SQL

```zig
// DDL
var result = try db.exec("CREATE TABLE users (id INTEGER, name TEXT);");
result.deinit();

// DML
result = try db.exec("INSERT INTO users VALUES (1, 'Alice');");
result.deinit();

// Query
var rows = try db.exec("SELECT * FROM users;");
defer rows.deinit();

std.debug.print("Rows: {d}\n", .{rows.count()});
for (rows.rows) |row| {
    std.debug.print("id={d} name={s}\n", .{ row[0].integer, row[1].text });
}
```

`exec` also accepts multiple semicolon-separated statements and returns the
result of the final statement. Semicolons inside quoted strings and trigger
`BEGIN`/`END` bodies are preserved.

```zig
var rows = try db.exec(
    "CREATE TABLE logs (message TEXT); INSERT INTO logs VALUES ('ready'); SELECT message FROM logs;",
);
defer rows.deinit();
```

SQLite `DEFAULT VALUES` inserts are supported for rows whose omitted columns
use their NULL/default representation:

```zig
var inserted = try db.exec("INSERT INTO logs DEFAULT VALUES;");
inserted.deinit();
```

Migration versions use SQLite's persistent header field:

```zig
var version = try db.exec("PRAGMA user_version = 3;");
version.deinit();
```

The same versions are available as direct methods, alongside the engine
schema version used for cache invalidation:

```zig
try db.setUserVersion(3);
const current = db.userVersion();
const cookie = db.schemaVersion();
try db.setApplicationId(305419896);
const appId = db.applicationId();
```

Applications can also persist an identifier in SQLite's standard header field:

```zig
var application = try db.exec("PRAGMA application_id = 305419896;");
application.deinit();
```

Additional databases can be attached for the session and addressed by name:

```zig
var attached = try db.exec("ATTACH 'archive.db' AS aux;");
attached.deinit();
var rows = try db.exec("SELECT * FROM aux.orders;");
defer rows.deinit();
var detached = try db.exec("DETACH aux;");
detached.deinit();
```

Foreign-key checks and cascading actions can be controlled per connection:

```zig
var foreignKeys = try db.exec("PRAGMA foreign_keys = ON;");
foreignKeys.deinit();
```

## DSL Query Interface

```zig
const User = sqlite.table("users", struct { id: i64, name: []const u8 });

// Create table
try db.createTable(User, .{});

// Insert
var result = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
result.deinit();

// Select
var rows = try db.from(User).fetch();
defer rows.deinit();

// With WHERE
var filtered = try db.from(User)
    .where(User.columns.id.eq(1))
    .fetch();
defer filtered.deinit();
```

## Transactions

```zig
try db.begin();
// ... operations ...
try db.commit();

// or rollback
try db.rollback();
```

## Savepoints

```zig
try db.begin();
try db.savepoint("sp1");
// ... operations ...
try db.rollbackToSavepoint("sp1");
try db.releaseSavepoint("sp1");
try db.commit();
```

## Schema Operations

```zig
// Create table
try db.createTable(User, .{
    .primaryKey = User.columns.id,
});

// Replace an existing table (drops and recreates it, discarding its rows)
try db.createTable(User, .{
    .primaryKey = User.columns.id,
    .overWrite = true,
});

// Truncate table
try db.truncate(User);
```

## Result Handling

```zig
var result = try db.exec("SELECT * FROM users;");
defer result.deinit();

// Number of rows
const count = result.count();

// Access rows
for (result.rows) |row| {
    // row is a []Value
    const id = row[0].integer;
    const name = row[1].text;
}
```
