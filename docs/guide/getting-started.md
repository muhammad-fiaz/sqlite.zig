# Getting Started

`sqlite.zig` is a fully native, zero-dependency SQLite-compatible database engine written entirely in Zig. It re-implements the storage engine, SQL parser, query planner, and virtual machine from scratch — no C bindings, no link-time dependencies.

## What You Get

- The real on-disk `.db`/`.sqlite` file format (compatible with SQLite tools)
- A hand-written SQL lexer, parser, and bytecode compiler/VM
- WAL and rollback-journal durability modes
- A type-safe, comptime Zig query builder (DSL)
- Cross-platform support (Linux, Windows, macOS)

## Prerequisites

- **Zig 0.16.0** or later — download from [ziglang.org](https://ziglang.org/download/)

## Your First Database

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    // Open (or create) a database file
    var db = try sqlite.open(std.heap.page_allocator, "hello.db");
    defer db.close();

    // Create a table using the typed DSL
    try db.createTable(User, .{ .if_not_exists = true });

    // Insert a row
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();

    // Query all rows
    var result = try db.from(User).fetchAll();
    defer result.deinit();

    std.debug.print("Rows: {d}\n", .{result.rowCount()});
}
```

## Raw SQL

You can also execute raw SQL strings:

```zig
var result = try db.exec("CREATE TABLE IF NOT EXISTS items (id INTEGER, name TEXT);");
result.deinit();

result = try db.exec("INSERT INTO items VALUES (1, 'Widget');");
result.deinit();

var rows = try db.exec("SELECT * FROM items;");
defer rows.deinit();
```

## What's Next

- [Installation](/guide/installation) — Add sqlite.zig to your project
- [SQL Engine](/guide/sql-engine) — Learn about raw SQL support
- [DSL Query Builder](/guide/dsl-query-builder) — Type-safe query construction
- [Transactions](/guide/transactions) — ACID transaction support
