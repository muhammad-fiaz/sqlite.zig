---
title: "B-Tree API"
description: "The B-Tree module managing hierarchical tree structures for indexing and storing database records, including cursors and page traversal."
---

# B-Tree API

The B-Tree module manages the hierarchical tree structure used for indexing and storing database records.

## Overview

SQLite stores all table and index data in B-tree structures. Each B-tree consists of pages linked together, with interior pages containing keys and child pointers, and leaf pages containing actual data records.

These modules are internal: client code reaches them through `Connection`,
not by importing them directly.

## Core Types

| Type | Description |
|------|-------------|
| `BTree` | Ordered key-to-payload container (`init`, `put`, `get`, `remove`) |
| `Cursor` | Position pointer over a `BTree` (`first`, `last`, `next`, `prev`, `seekGE`, `seekLE`, `seekEQ`, `key`, `value`) |
| `Index` | Key-to-rowid map for index data (`insert`, `rowid`, `remove`, `count`) |

## B-Tree Operations

The container API works on `u64` keys with byte payloads:

- insert or replace a payload: `put(key, payload)`
- look up a payload: `get(key)`
- remove a key: `remove(key)`

Cursors walk entries forwards and backwards (`first`/`last`, then
`next`/`prev` while `valid()` holds), or seek directly with `seekGE`,
`seekLE`, and `seekEQ`.

## Page Types

| Type | Description |
|------|-------------|
| Interior Table B-tree | Contains child pointers and rowid keys |
| Leaf Table B-tree | Contains actual row data |
| Interior Index B-tree | Contains child pointers and index keys |
| Leaf Index B-tree | Contains index key and pointer to data |

## Balancing

The `balance` module computes bounded split points and SQLite-compatible
payload fragmentation (`splitPoint`, `splitPointByBytes`, `maxLocalPayload`,
`minLocalPayload`, `localPayloadSize`). Page headers encode and decode
through `PageHeader`, and page images are constructed with
`formatLeafTablePage`, `formatInteriorTablePage`, `formatLeafIndexPage`, and
`formatInteriorIndexPage`.
