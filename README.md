<div align="center">

<img  height="250" alt="SQLITE.ZIG LOGO" src="https://github.com/user-attachments/assets/6071c76a-833f-464c-a3eb-d03c74fde328" />

# SQLite.zig

<a href="https://muhammad-fiaz.github.io/sqlite.zig/"><img src="https://img.shields.io/badge/docs-muhammad--fiaz.github.io-blue" alt="Documentation"></a>
<a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.16.0-orange.svg?logo=zig" alt="Zig Version"></a>
<a href="https://github.com/muhammad-fiaz/sqlite.zig"><img src="https://img.shields.io/github/stars/muhammad-fiaz/sqlite.zig" alt="GitHub stars"></a>
<a href="https://github.com/muhammad-fiaz/sqlite.zig/issues"><img src="https://img.shields.io/github/issues/muhammad-fiaz/sqlite.zig" alt="GitHub issues"></a>
<a href="https://github.com/muhammad-fiaz/sqlite.zig/pulls"><img src="https://img.shields.io/github/issues-pr/muhammad-fiaz/sqlite.zig" alt="GitHub pull requests"></a>
<a href="https://github.com/muhammad-fiaz/sqlite.zig"><img src="https://img.shields.io/github/last-commit/muhammad-fiaz/sqlite.zig" alt="GitHub last commit"></a>
<a href="https://github.com/muhammad-fiaz/sqlite.zig"><img src="https://img.shields.io/github/license/muhammad-fiaz/sqlite.zig" alt="License"></a>
<a href="https://github.com/muhammad-fiaz/sqlite.zig/actions/workflows/ci.yml"><img src="https://github.com/muhammad-fiaz/sqlite.zig/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<img src="https://img.shields.io/badge/platforms-linux%20%7C%20windows%20%7C%20macos-blue" alt="Supported Platforms">
<a href="https://github.com/muhammad-fiaz/sqlite.zig/actions/workflows/github-code-scanning/codeql"><img src="https://github.com/muhammad-fiaz/sqlite.zig/actions/workflows/github-code-scanning/codeql/badge.svg" alt="CodeQL"></a>
<a href="https://github.com/muhammad-fiaz/sqlite.zig/releases/latest"><img src="https://img.shields.io/github/v/release/muhammad-fiaz/sqlite.zig?label=Latest%20Release&style=flat-square" alt="Latest Release"></a>
<a href="https://pay.muhammadfiaz.com"><img src="https://img.shields.io/badge/Sponsor-pay.muhammadfiaz.com-ff69b4?style=flat&logo=heart" alt="Sponsor"></a>
<a href="https://github.com/sponsors/muhammad-fiaz"><img src="https://img.shields.io/badge/Sponsor-GitHub-pink?style=social&logo=github" alt="GitHub Sponsors"></a>
<a href="https://hits.sh/muhammad-fiaz/sqlite.zig/"><img src="https://hits.sh/muhammad-fiaz/sqlite.zig.svg?label=Visitors&extraCount=0&color=green" alt="Repo Visitors"></a>

<p><em>A fully native, zero-dependency SQLite-compatible database engine written entirely in Zig.</em></p>

<b><a href="https://muhammad-fiaz.github.io/sqlite.zig/">Documentation</a> |
<a href="https://muhammad-fiaz.github.io/sqlite.zig/api/sqlite">API Reference</a> |
<a href="https://muhammad-fiaz.github.io/sqlite.zig/guide/quick-start">Quick Start</a> |
<a href="CONTRIBUTING.md">Contributing</a> |
<a href="SECURITY.md">Security</a></b>

</div>

`sqlite.zig` is a ground-up reimplementation of the SQLite engine in pure Zig, featuring a complete storage engine with the real on-disk `.db` file format, a hand-written SQL lexer and parser, a bytecode compiler and virtual machine, WAL and rollback-journal durability modes, and a type-safe comptime query builder (DSL) that stays in sync with raw SQL.

> [!NOTE]
> Due to ongoing development, limited documentation is available at [muhammad-fiaz.github.io/sqlite.zig](https://muhammad-fiaz.github.io/sqlite.zig/). You can also generate it locally with `zig build docs`.

> [!TIP]
> If you build with sqlite.zig, make sure to give it a star. ⭐

> [!WARNING]
> This project is in **early, active development**. Core engine components are being implemented tier by tier. Expect missing features, incomplete SQL coverage, and breaking changes between commits.

> [!CAUTION]
> **Do not use this in production or on data you cannot afford to lose.** There is no stability guarantee on the file format, the API, or correctness of edge cases yet. Back up anything important separately.

---

<details>
<summary><strong>Related Projects</strong> (click to expand)</summary>

- **CUDA / GPU computing** — For GPU acceleration and CUDA support, check out [cuda.zig](https://github.com/muhammad-fiaz/cuda.zig).
- **Environment variables** — For `.env` file parsing and environment configuration, check out [env.zig](https://github.com/muhammad-fiaz/env.zig).
- **TUI** — For terminal user interfaces, check out [tui.zig](https://github.com/muhammad-fiaz/tui.zig).
- **ZON file format** — For ZON parsing and serialization, check out [zon.zig](https://github.com/muhammad-fiaz/zon.zig).
- **Spinners / loading / progress bars** — For terminal loading indicators and progress bars, check out [loaders.zig](https://github.com/muhammad-fiaz/loaders.zig).
- **MCP** — For Model Context Protocol support, check out [mcp.zig](https://github.com/muhammad-fiaz/mcp.zig).
- **Argument parsing** — For command-line argument parsing, check out [args.zig](https://github.com/muhammad-fiaz/args.zig).
- **HTTP client / server** — For HTTP client and server functionality, check out [httpx.zig](https://github.com/muhammad-fiaz/httpx.zig).
- **API framework** — For building APIs, check out [api.zig](https://github.com/muhammad-fiaz/api.zig).
- **Web framework** — For web application development, check out [zix](https://github.com/muhammad-fiaz/zix).
- **Archive / compression** — For archive handling and compression, check out [archive.zig](https://github.com/muhammad-fiaz/archive.zig).
- **Compression file formats** — For compression-oriented file format support, check out [zigx](https://github.com/muhammad-fiaz/zigx).
- **File downloading** — For downloading files, check out [downloader.zig](https://github.com/muhammad-fiaz/downloader.zig).
- **Update checker / auto-updater** — For application update checking and automatic updates, check out [updater.zig](https://github.com/muhammad-fiaz/updater.zig).
- **Numerical computing** — For numerical and scientific computing, check out [num.zig](https://github.com/muhammad-fiaz/num.zig).
- **Logging** — For structured and application logging, check out [logly.zig](https://github.com/muhammad-fiaz/logly.zig).
- **Data validation / serialization** — For data validation and serialization, check out [zigantic](https://github.com/muhammad-fiaz/zigantic).
- **Build tooling** — For advanced Zig build tooling, check out [buildx.zig](https://github.com/muhammad-fiaz/buildx.zig).
- **Tree-sitter** — For Tree-sitter parsing and syntax-tree support, check out [tree-sitter.zig](https://github.com/muhammad-fiaz/tree-sitter.zig).

</details>
---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description |
|---------|-------------|
| **Pure Zig Implementation** | Zero C dependencies, zero link-time requirements. The entire engine is written in Zig from scratch. |
| **Real On-Disk Format** | Full implementation of the SQLite `.db`/`.sqlite` file format including 100-byte header, table/index B-tree pages, record encoding, varints, and freelist pages. |
| **SQL Lexer & Parser** | Hand-written SQL lexer and parser supporting CREATE TABLE, INSERT, SELECT, UPDATE, DELETE, BEGIN, COMMIT, ROLLBACK, JOINs, subqueries, CTEs, views, triggers, and more. |
| **Bytecode Compiler & VM** | A bytecode virtual machine that compiles parsed SQL into opcodes and executes them against the storage engine, modeled on SQLite's own architecture. |
| **WAL & Rollback Journal** | SQLite-compatible WAL page headers/frames, native WAL readback, checkpointing through `PRAGMA journal_mode=DELETE`, and rollback-journal persistence. Multi-process locking/VFS parity is still in progress. |
| **Typed DSL Query Builder** | A comptime, type-safe Zig query builder that builds the same internal query representation as Raw SQL directly, ensuring compile-time validation of table names, column names, and types. |
| **DISTINCT Joins** | Full DISTINCT support for JOIN queries with automatic deduplication of result rows. |
| **Transaction Modes** | BEGIN DEFERRED, BEGIN IMMEDIATE, BEGIN EXCLUSIVE, START TRANSACTION, COMMIT, ROLLBACK, SAVEPOINT, RELEASE, and ROLLBACK TO SAVEPOINT. |
| **Foreign Key Actions** | CASCADE DELETE, CASCADE UPDATE, SET NULL, SET DEFAULT, RESTRICT, and NO ACTION (plus composite foreign keys). |
| **Composite Constraints** | Composite PRIMARY KEY, composite UNIQUE, and composite FOREIGN KEY constraints across multiple columns. |
| **Views & Triggers** | CREATE VIEW and CREATE TRIGGER (BEFORE/AFTER INSERT/UPDATE/DELETE, WHEN filters) with NEW/OLD references. |
| **CTEs & Recursive CTEs** | Common Table Expressions including recursive CTEs for hierarchical data traversal (tree/graph structures). |
| **Subqueries** | EXISTS/NOT EXISTS (incl. correlated), IN/NOT IN (lists and subqueries), scalar subqueries, derived tables in FROM, and CTEs (incl. recursive). |
| **Expression Operators** | `= == != <> < <= > >=`, `AND OR NOT`, `LIKE NOT LIKE` (`% _ ESCAPE`), `GLOB NOT GLOB` (`* ? []`), `REGEXP NOT REGEXP`, `MATCH NOT MATCH`, `||`, `IS IS NOT IS DISTINCT FROM`, `IN NOT IN`, `BETWEEN NOT BETWEEN`, `CASE`, `CAST`, `COLLATE NOCASE`, `+ - * / %`, `& | << >> ~`, all with correct NULL and precedence semantics. |
| **Scalar Functions** | ABS, LENGTH, UPPER, LOWER, SUBSTR/SUBSTRING, REPLACE, TRIM/LTRIM/RTRIM (incl. custom chars), INSTR, HEX, QUOTE, UNICODE, CHAR, PRINTF/FORMAT, ROUND, TYPEOF, CAST, COALESCE/IFNULL, NULLIF, JSON_EXTRACT/JSON_SET in raw SQL, dynamic DSL, and typed DSL. |
| **UPSERT & RETURNING** | `ON CONFLICT DO NOTHING / DO UPDATE` with `excluded`, partial targets, and `RETURNING` on INSERT/UPDATE/DELETE across all three interfaces. |
| **Compound SELECT** | UNION, UNION ALL, INTERSECT, and EXCEPT with duplicate elimination, ORDER BY, and LIMIT/OFFSET. |
| **Multi-Table JOINs** | 3+ table chains across INNER/LEFT/RIGHT/FULL/CROSS/ON/USING/NATURAL with WHERE, GROUP BY, HAVING, and pagination. |
| **CASE & Windows** | Simple/searched CASE plus 11 window functions (ROW_NUMBER, RANK, LAG/LEAD, NTILE, FIRST/LAST/NTH_VALUE, …) with PARTITION BY, ORDER BY, and ROWS/RANGE/GROUPS frames. |
| **Constraints** | CHECK, UNIQUE, NOT NULL, DEFAULT, full SQLite type names, generated columns (VIRTUAL/STORED), STRICT tables, and WITHOUT ROWID tables. |
| **PRAGMAs** | foreign_keys, user_version, application_id, journal_mode, synchronous, cache_size, integrity_check, and foreign_key_check. |
| **Indexed Queries** | CREATE INDEX and optimized indexed lookups for performance-critical queries. |
| **Query Planning** | `EXPLAIN QUERY PLAN` reports index-backed equality searches and table scans. |
| **Virtual Tables** | Native `generate_series` virtual tables support raw creation, typed DSL reads, and native reopen. Other modules return `Unsupported`. |
| **Prepared Statements** | Parameterized queries with typed binding and automatic memory management. |
| **Schema Lifecycle** | CREATE TABLE, ALTER TABLE ADD COLUMN, DROP TABLE with full schema persistence and verification. |
| **On-Disk Format** | Databases use the real SQLite file format (100-byte header, B-tree pages) and reopen losslessly. |
| **Cross-Platform** | Runs on Linux, Windows, and macOS with the same source code. |

</details>

---

<details>
<summary><strong>Prerequisites and Supported Platforms</strong> (click to expand)</summary>

<br>

## Prerequisites

Before using `sqlite.zig`, ensure you have the following:

| Requirement | Version | Notes |
|-------------|---------|-------|
| **Zig** | 0.16.0+ | Download from [ziglang.org](https://ziglang.org/download/) |
| **Operating System** | Windows 10+, Linux, macOS | Cross-platform database engine |

---

## Supported Platforms

`sqlite.zig` is validated on these architectures:

| Platform | x86_64 (64-bit) | aarch64 (ARM64) |
|----------|-----------------|-----------------|
| **Linux** | Yes | Yes |
| **Windows** | Yes | Yes |
| **macOS** | Yes | Yes |

### Cross-Compilation

Zig makes cross-compilation easy. Build for any target from any host:

```bash
# Build for Linux ARM64 from Windows
zig build -Dtarget=aarch64-linux

# Build for Windows from Linux
zig build -Dtarget=x86_64-windows
```

</details>

---

## Installation

### Method 1: Zig Fetch (Recommended)

**Latest Development Version (main branch)**

```bash
zig fetch --save git+https://github.com/muhammad-fiaz/sqlite.zig.git
```

### Method 2: Manual `build.zig.zon` Configuration

Add the dependency to your `build.zig.zon` file.

```zig
.dependencies = .{
    .sqlite = .{
        .url = "https://github.com/muhammad-fiaz/sqlite.zig/archive/refs/heads/main.tar.gz",
        .hash = "...", // Run `zig fetch --save <url>` to generate the hash.
    },
},
```

### Method 3: Local Source Checkout

Clone the repository locally.

```bash
git clone https://github.com/muhammad-fiaz/sqlite.zig.git
cd sqlite.zig
zig build
```

To use a local checkout from another project, add a path dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .sqlite = .{
        .path = "../sqlite.zig",
    },
},
```

### Wire into `build.zig`

After adding the dependency, import the module in your `build.zig`:

```zig
const sqliteDep = b.dependency("sqlite", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("sqlite", sqliteDep.module("sqlite"));
```

## Quick Start

### Basic Database Operations

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "my_database.db");
    defer db.close();

    try db.createTable(User, .{});

    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();

    var result = try db.from(User).fetch();
    defer result.deinit();

    for (result.rows) |row| {
        std.debug.print("User: id={d}, name={s}\n", .{ row.id, row.name });
    }
}
```

### Transactions & Joins

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });
const Order = sqlite.table("orders", struct { id: i64, user_id: i64, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "shop.db");
    defer db.close();

    try db.createTable(User, .{});
    try db.createTable(Order, .{});

    // Transaction with rollback safety
    try db.begin();
    var order = try db.from(Order).insert(.{ .id = 1, .user_id = 1, .amount = 100 });
    order.deinit();
    try db.commit();

    // Typed JOIN query
    var joined = try db.from(User)
        .innerJoin(Order, User.id.eq(Order.user_id))
        .selectAll()
        .distinct()
        .fetch();
    defer joined.deinit();

    std.debug.print("Found {d} rows\n", .{joined.count()});
}
```

### Three interfaces: Raw SQL, Dynamic DSL, Typed DSL

```zig
// Raw SQL: unrestricted, no struct required.
var rows = try db.exec("SELECT id, name FROM users WHERE age >= 18;");
defer rows.deinit();

// Dynamic DSL: runtime table/column names, no struct required.
// For existing databases, legacy schemas, and ad-hoc queries.
const users = db.table("users");
var dyn = try db.from(users)
    .select(.{ users.column("id"), users.column("name") })
    .where(users.column("age").gte(18))
    .orderBy(users.column("name").asc())
    .fetch();
defer dyn.deinit();

// Typed DSL: Zig structs, compile-time columns, typed rows.
const User = sqlite.table("users", struct { id: i64, name: []const u8, age: i64 });
try db.schema(User).validate();
var typed = try db.from(User)
    .where(User.age.gte(18))
    .orderBy(User.name.asc())
    .fetch();
defer typed.deinit();
for (typed.rows) |user| {
    std.debug.print("{d} {s} {d}\n", .{ user.id, user.name, user.age });
}
```

Side by side, one engine:

```text
Raw:     SELECT * FROM users WHERE id = 1;
Dynamic: db.from(users).selectAll().where(users.column("id").eq(1))
Typed:   db.from(User).select(User.all()).where(User.id.eq(1))
```

The DSL builds the same internal query representation as Raw SQL directly,
without generating SQL strings. See `docs/api/dsl.md`.

`users.column("id")` is the canonical explicit Dynamic column reference: it
carries table identity. `db.col("id")` is optional sugar for an unqualified
reference resolved with SQLite name-resolution rules; ambiguous references
are an error, never a silent pick. Typed columns are `User.id`;
`User.all()` is the typed `table.*` operation and `selectAll()` is the
`SELECT *` operation on any query; both build the same native projection
node. Schema columns are always fields — even a column literally named
`all` stays usable as `User.all` — while operations are always calls.

### Raw SQL

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "raw.db");
    defer db.close();

    var result = try db.exec("CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT);");
    result.deinit();

    result = try db.exec("INSERT INTO items VALUES (1, 'Widget');");
    result.deinit();

    var rows = try db.exec("SELECT * FROM items WHERE id = 1;");
    defer rows.deinit();

    std.debug.print("Row count: {d}\n", .{rows.count()});
}
```

## Examples

Run any example:

```bash
zig build run-01_open_and_exec
zig build run-03_transactions
zig build run-09_dsl_crud
zig build run-all-examples
```

## Validation & Testing

Run all unit tests across the entire codebase:

```bash
zig build test
```

Generate the API documentation:

```bash
zig build docs
```

> [!NOTE]
> The hosted documentation site is not ready yet. Run `zig build docs` to generate and view the current API docs at `zig-out/docs/index.html`.

## Contributing

This project is being built out tier by tier: file format and storage first, then the B-tree engine, then the SQL front end and planner, then higher-level features (views, triggers, DSL), with advanced extensions (FTS5, JSON1, R-Tree) deferred until the core engine is solid.

> [!WARNING]
> Because the internal architecture is still shifting, expect merge conflicts and API churn if you build against internal modules directly (anything outside `src/sqlite.zig`). Prefer depending only on the public API surface.

Issues and pull requests are welcome. Please check open issues before starting large changes so effort isn't duplicated.

## License

MIT License - Copyright (c) 2026 Muhammad Fiaz

