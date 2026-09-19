---
title: "Storage API"
description: "Low-level file I/O, page management, and durability for the SQLite on-disk format, including pager, WAL, and journaling."
---

# Storage API

The storage module handles low-level file I/O, page management, and durability.
These modules are internal: client code reaches them through `Connection`,
not by importing them directly.

## File I/O

`DatabaseFile.open(allocator, path)` opens (or creates) the database file,
reads the 100-byte header, and exposes page reads/writes plus image
readback (`readImage`) and `user_version` / `application_id` accessors.

## Pager

`Pager.init(allocator, file)` caches pages from a `DatabaseFile` in memory,
with `get`, `allocatePage` (reusing freed pages first), `freePage`,
`markDirty`, and `flush`.

## Write-Ahead Log (WAL)

WAL mode is selected through the public connection API. The implementation writes
SQLite-compatible WAL headers and page frames, merges them on native reopen, and
checkpoints back to the main database when switched to `DELETE` mode.

```zig
var mode = try db.exec("PRAGMA journal_mode=WAL;");
mode.deinit();
// ... writes are durable in the native WAL ...
var checkpoint = try db.exec("PRAGMA wal_checkpoint(TRUNCATE);");
checkpoint.deinit();
var back = try db.exec("PRAGMA journal_mode=DELETE;");
back.deinit();
```

`PRAGMA wal_checkpoint;` (or with `PASSIVE`, `FULL`, `RESTART`, `TRUNCATE`)
merges WAL frames into the main database and reports `busy`, `log`, and
`checkpointed` frame counts.

This is single-process native WAL support; multi-process locking, VFS callbacks,
and full SQLite concurrency semantics remain under development.

## Rollback Journal

The `journal` module encodes the rollback-journal header (page geometry);
durability itself is managed by the connection, which persists the rebuilt
database image on every write outside a transaction.

## SQLite Image

The `sqlite_image` module converts between the live schema and the on-disk
format: `encode` / `encodeWithPageSize` build the header, schema-table
B-tree, table/index B-trees, views, and triggers into pages, while `decode`
reconstructs the schema (tables with rows, indexes, views, triggers) when a
database is opened.

## Page Format

Database pages follow the SQLite file format:

- **Page 1**: Database header (100 bytes) + schema table B-tree
- **Table B-tree pages**: Interior and leaf pages with cell pointers
- **Index B-tree pages**: Index data storage
- **Freelist pages**: Unused page tracking

## Record Format

Records are encoded using SQLite's variable-length format:

- Header size (varint)
- Column types (serial types)
- Column data (text, integer, blob)

## Varint Encoding

Variable-length integers for compact storage:
