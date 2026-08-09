# Format API

Low-level file format handling for the SQLite on-disk structure.

## Page Format

Database pages follow the SQLite file format specification:

| Component | Size | Description |
|-----------|------|-------------|
| Database Header | 100 bytes | Global database metadata on page 1 |
| Page Header | Variable | Per-page metadata (type, cell count, freeblocks) |
| Cell Pointer Array | 2 bytes per cell | Offsets to each cell on the page |
| Cell Content | Variable | Actual data records or keys |
| Unallocated Space | Variable | Free space on the page |

## Record Format

Records are encoded using SQLite's variable-length encoding:

| Component | Description |
|-----------|-------------|
| Header Size | Varint indicating header length |
| Serial Types | One per column, encoding the data type and size |
| Column Data | Actual values in order |

### Serial Types

| Type | Value | Storage |
|------|-------|---------|
| NULL | 0 | 0 bytes |
| 8-bit int | 1 | 1 byte |
| 16-bit int | 2 | 2 bytes |
| 24-bit int | 3 | 3 bytes |
| 32-bit int | 4 | 4 bytes |
| 48-bit int | 6 | 6 bytes |
| 64-bit int | 8 | 8 bytes |
| Float64 | 7 | 8 bytes |
| Blob | N >= 12, even | N-12 bytes |
| Text | N >= 13, odd | N-13 bytes |

## Varint Encoding

Variable-length integers for compact storage:

```zig
const varint = @import("varint");

// Encode
var buf: [9]u8 = undefined;
const len = varint.encode(&buf, value);

// Decode
const decoded = varint.decode(buf, &bytes_read);
```

## Header

The 100-byte database header on page 1:

| Offset | Size | Description |
|--------|------|-------------|
| 0 | 16 | SQLite version string |
| 16 | 2 | Page size |
| 18 | 1 | File format write version |
| 19 | 1 | File format read version |
| 20 | 1 | Reserved space at end of page |
| 21 | 1 | Maximum embedded payload fraction |
| 22 | 1 | Minimum embedded payload fraction |
| 23 | 1 | Leaf payload fraction |
| 24 | 4 | File change counter |
| 28 | 4 | Total pages in database |
| 32 | 4 | First freelist trunk page |
| 36 | 4 | Total freelist pages |
| 40 | 4 | Schema cookie |
| 44 | 4 | Schema format number |
| 48 | 4 | Default page cache size |
| 52 | 4 | Largest root b-tree page |
| 56 | 4 | Text encoding |
| 60 | 4 | User version |
| 64 | 4 | Incremental vacuum mode |
| 68 | 4 | Application ID |
| 72 | 20 | Reserved for expansion |
| 92 | 4 | Version-valid-for number |
| 96 | 4 | SQLite version number |
