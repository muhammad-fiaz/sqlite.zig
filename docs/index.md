---
title: "Native SQLite Database Engine in Zig"
description: "A fully native, zero-dependency SQLite-compatible database engine written entirely in Zig. Pure Zig storage engine, SQL parser, bytecode VM, typed DSL query builder, WAL journaling, and cross-platform support."
layout: home

hero:
  name: "sqlite.zig"
  text: "Native SQLite-Compatible Database Engine in Zig"
  tagline: A fully native, zero-dependency SQLite-compatible database engine written entirely in Zig
  image:
    src: /logo.png
    alt: sqlite.zig logo
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: API Reference
      link: /api/
    - theme: alt
      text: GitHub
      link: https://github.com/muhammad-fiaz/sqlite.zig

features:
  - icon: "\U0001f5c4"
    title: Real On-Disk Format
    details: Full implementation of the SQLite .db/.sqlite file format including 100-byte header, B-tree pages, record encoding, varints, and freelist pages.
  - icon: "\U0001f4dd"
    title: SQL Parser & VM
    details: Hand-written SQL lexer, parser, and bytecode compiler/VM modeled on SQLite's own architecture. Supports CREATE, INSERT, SELECT, UPDATE, DELETE, JOINs, and more.
  - icon: "\u26a1"
    title: Typed DSL Query Builder
    details: A comptime, type-safe Zig query builder that constructs the same internal query representation as Raw SQL directly, ensuring compile-time validation of table names, column names, and types.
  - icon: "\U0001f504"
    title: WAL & Rollback Journal
    details: Native SQLite-compatible WAL page frames, reopen/readback, and checkpointing, plus rollback-journal persistence. Full multi-process locking/VFS parity is still in progress.
  - icon: "\U0001f517"
    title: Foreign Keys & Constraints
    details: CASCADE DELETE/UPDATE, SET NULL, RESTRICT, composite foreign keys, composite PRIMARY KEY, and composite UNIQUE constraints.
  - icon: "\U0001f9e9"
    title: Views, Triggers & CTEs
    details: CREATE VIEW, CREATE TRIGGER, Common Table Expressions including recursive CTEs for hierarchical data traversal.
---

## Quick Example

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    // Open the database file. Every fallible call below propagates its
    // error with `try`, so failures never go unnoticed.
    var db = try sqlite.open(std.heap.page_allocator, "my.db");
    // Close only after every operation below has finished: `defer` runs
    // last when `main` returns, on both success and error paths, which
    // flushes pending writes and releases the file.
    defer db.close();

    try db.createTable(User, .{});

    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();

    var result = try db.from(User).fetch();
    defer result.deinit();

    // Validate what came back before using it.
    if (result.count() != 1) return error.UnexpectedRowCount;
    const row = result.rows[0];
    std.debug.print("User: id={d}, name={s}\n", .{ row.id, row.name });
}
```

> [!NOTE]
> This project is in early, active development. Expect breaking changes between commits.

