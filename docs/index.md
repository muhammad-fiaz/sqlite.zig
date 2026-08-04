---
layout: home

hero:
  name: "sqlite.zig"
  text: "SQLite Engine in Pure Zig"
  tagline: A fully native, zero-dependency SQLite-compatible database engine written entirely in Zig
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
    details: A comptime, type-safe Zig query builder that generates SQL under the hood, ensuring compile-time validation of table names, column names, and types.
  - icon: "\U0001f504"
    title: WAL & Rollback Journal
    details: Both Write-Ahead Logging (WAL) and traditional rollback-journal durability modes for concurrent read/write access.
  - icon: "\U0001f517"
    title: Foreign Keys & Constraints
    details: CASCADE DELETE/UPDATE, SET NULL, SET DEFAULT, composite foreign keys, composite PRIMARY KEY, and composite UNIQUE constraints.
  - icon: "\U0001f9e9"
    title: Views, Triggers & CTEs
    details: CREATE VIEW, CREATE TRIGGER, Common Table Expressions including recursive CTEs for hierarchical data traversal.
---

## Quick Example

```zig
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "my.db");
    defer db.close();

    try db.createTable(User, .{ .if_not_exists = true });

    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();

    var result = try db.from(User).fetchAll();
    defer result.deinit();
}
```

> [!NOTE]
> This project is in early, active development. Expect breaking changes between commits.
