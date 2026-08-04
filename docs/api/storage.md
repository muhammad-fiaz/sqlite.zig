# Storage API

The storage module handles low-level file I/O, page management, and durability.

## File I/O

```zig
const file = @import("file");

var f = try file.File.open("my.db");
```

## Pager

Manages database pages in memory:

```zig
const pager = @import("pager");

var p = try pager.Pager.init(allocator, "my.db");
```

## Write-Ahead Log (WAL)

Provides concurrent read/write access:

```zig
const wal = @import("wal");

var w = try wal.WAL.init("my.db");
```

## Rollback Journal

Traditional durability mode:

```zig
const journal = @import("journal");

var j = try journal.Journal.init("my.db-journal");
```

## SQLite Image

The on-disk format representation:

```zig
const sqlite_image = @import("sqlite_image");

var img = try sqlite_image.Image.init("my.db");
```

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
