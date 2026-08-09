---
title: "B-Tree API"
description: "The B-Tree module managing hierarchical tree structures for indexing and storing database records, including cursors and page traversal."
---

# B-Tree API

The B-Tree module manages the hierarchical tree structure used for indexing and storing database records.

## Overview

SQLite stores all table and index data in B-tree structures. Each B-tree consists of pages linked together, with interior pages containing keys and child pointers, and leaf pages containing actual data records.

## Core Types

| Type | Description |
|------|-------------|
| `BTree` | Main B-tree handle for traversal and modification |
| `Cursor` | Position pointer for iterating through B-tree nodes |
| `IndexBTree` | Specialized B-tree for index data |

## B-Tree Operations

### Insert

```zig
try btree.insert(key, record);
```

### Delete

```zig
try btree.delete(key);
```

### Lookup

```zig
var cursor = try btree.find(key);
```

### Scan

```zig
var cursor = try btree.beginScan();
while (try cursor.next()) |record| {
    // process record
}
```

## Page Types

| Type | Description |
|------|-------------|
| Interior Table B-tree | Contains child pointers and rowid keys |
| Leaf Table B-tree | Contains actual row data |
| Interior Index B-tree | Contains child pointers and index keys |
| Leaf Index B-tree | Contains index key and pointer to data |

## Balancing

The `balance` module handles page splitting and merging when inserts or deletes cause pages to exceed or fall below the fill factor:

```zig
try btree.balance(page);
```
