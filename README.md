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
> Documentation is available at [muhammad-fiaz.github.io/sqlite.zig](https://muhammad-fiaz.github.io/sqlite.zig/). You can also generate it locally with `zig build docs`.

> [!TIP]
> If you build with sqlite.zig, make sure to give it a star. ⭐

> [!WARNING]
> This project is in **early, active development**. Core engine components are being implemented tier by tier. Expect missing features, incomplete SQL coverage, and breaking changes between commits.

> [!CAUTION]
> **Do not use this in production or on data you cannot afford to lose.** There is no stability guarantee on the file format, the API, or correctness of edge cases yet. Back up anything important separately.

**Related Zig projects:**

- For **CUDA/GPU computing** support, check out **[cuda.zig](https://github.com/muhammad-fiaz/cuda.zig)**.
- For **env.zig** (.env parsing), check out **[env.zig](https://github.com/muhammad-fiaz/env.zig)**.
- For **TUI** support, check out **[tui.zig](https://github.com/muhammad-fiaz/tui.zig)**.
- For **ZON file format** support, check out **[zon.zig](https://github.com/muhammad-fiaz/zon.zig)**.
- For **spinners/loading/progress bar** support, check out **[loaders.zig](https://github.com/muhammad-fiaz/loaders.zig)**.
- For **MCP** support, check out **[mcp.zig](https://github.com/muhammad-fiaz/mcp.zig)**.
- For **args parsing** support, check out **[args.zig](https://github.com/muhammad-fiaz/args.zig)**.
- For **HTTP client/server** support, check out **[httpx.zig](https://github.com/muhammad-fiaz/httpx.zig)**.
- For **API framework** support, check out **[api.zig](https://github.com/muhammad-fiaz/api.zig)**.
- For **web framework** support, check out **[zix](https://github.com/muhammad-fiaz/zix)**.
- For **archive/compression** support, check out **[archive.zig](https://github.com/muhammad-fiaz/archive.zig)**.
- For **compression file format** support, check out **[zigx](https://github.com/muhammad-fiaz/zigx)**.
- For **file downloading** support, check out **[downloader.zig](https://github.com/muhammad-fiaz/downloader.zig)**.
- For **update checker/auto-updater** support, check out **[updater.zig](https://github.com/muhammad-fiaz/updater.zig)**.
- For **numerical computing** support, check out **[num.zig](https://github.com/muhammad-fiaz/num.zig)**.
- For **logging** support, check out **[logly.zig](https://github.com/muhammad-fiaz/logly.zig)**.
- For **data validation and serialization** support, check out **[zigantic](https://github.com/muhammad-fiaz/zigantic)**.
- For **build tooling** support, check out **[buildx.zig](https://github.com/muhammad-fiaz/buildx.zig)**.

---

<details>
<summary><strong>Features</strong> (click to expand)</summary>

| Feature | Description |
|---------|-------------|
| **Pure Zig Implementation** | Zero C dependencies, zero link-time requirements. The entire engine is written in Zig from scratch. |
| **Real On-Disk Format** | Full implementation of the SQLite `.db`/`.sqlite` file format including 100-byte header, table/index B-tree pages, record encoding, varints, and freelist pages. |
| **SQL Lexer & Parser** | Hand-written SQL lexer and parser supporting CREATE TABLE, INSERT, SELECT, UPDATE, DELETE, BEGIN, COMMIT, ROLLBACK, JOINs, subqueries, CTEs, views, triggers, and more. |
| **Bytecode Compiler & VM** | A bytecode virtual machine that compiles parsed SQL into opcodes and executes them against the storage engine, modeled on SQLite's own architecture. |
| **WAL & Rollback Journal** | Both Write-Ahead Logging (WAL) and traditional rollback-journal durability modes for concurrent read/write access. |
| **Typed DSL Query Builder** | A comptime, type-safe Zig query builder that generates SQL under the hood, ensuring compile-time validation of table names, column names, and types. |
| **DISTINCT Joins** | Full DISTINCT support for JOIN queries with automatic deduplication of result rows. |
| **Transaction Modes** | BEGIN DEFERRED, BEGIN IMMEDIATE, BEGIN EXCLUSIVE, START TRANSACTION, COMMIT, ROLLBACK, SAVEPOINT, RELEASE, and ROLLBACK TO SAVEPOINT. |
| **Foreign Key Actions** | CASCADE DELETE, CASCADE UPDATE, SET NULL, SET DEFAULT, and RESTRICT with composite foreign key support. |
| **Composite Constraints** | Composite PRIMARY KEY, composite UNIQUE, and composite FOREIGN KEY constraints across multiple columns. |
| **Views & Triggers** | CREATE VIEW and CREATE TRIGGER with BEFORE/AFTER INSERT/UPDATE/DELETE support. |
| **CTEs & Recursive CTEs** | Common Table Expressions including recursive CTEs for hierarchical data traversal (tree/graph structures). |
| **Subqueries** | Scalar subqueries, EXISTS/NOT EXISTS, IN/NOT IN, and derived table subqueries in FROM and WHERE clauses. |
| **Scalar Functions** | ABS, LENGTH, UPPER, LOWER, SUBSTR, and other scalar functions in both raw SQL and typed DSL. |
| **Indexed Queries** | CREATE INDEX and optimized indexed lookups for performance-critical queries. |
| **Prepared Statements** | Parameterized queries with typed binding and automatic memory management. |
| **Schema Lifecycle** | CREATE TABLE, ALTER TABLE ADD COLUMN, DROP TABLE with full schema persistence and verification. |
| **Python Interop** | Databases created by sqlite.zig can be read by Python's `sqlite3` module and vice versa. |
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
const sqlite_dep = b.dependency("sqlite", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("sqlite", sqlite_dep.module("sqlite"));
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

    try db.createTable(User, .{ .if_not_exists = true });

    var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
    inserted.deinit();

    var result = try db.from(User).fetchAll();
    defer result.deinit();

    for (result.rows) |row| {
        std.debug.print("User: id={d}, name={s}\n", .{ row[0].integer, row[1].text });
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

    try db.createTable(User, .{ .if_not_exists = true });
    try db.createTable(Order, .{ .if_not_exists = true });

    // Transaction with rollback safety
    try db.begin();
    var order = try db.from(Order).insert(.{ .id = 1, .user_id = 1, .amount = 100 });
    order.deinit();
    try db.commit();

    // Typed JOIN query
    var joined = try db.from(User)
        .innerJoin(Order, "id", "user_id")
        .select("*")
        .distinct()
        .fetchAll();
    defer joined.deinit();

    std.debug.print("Found {d} rows\n", .{joined.rowCount()});
}
```

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

    std.debug.print("Row count: {d}\n", .{rows.rowCount()});
}
```

## Examples

The `examples/` directory contains **32 runnable examples**:

| # | Example | Description |
|---|---------|-------------|
| 01 | [`open_and_exec`](examples/01_open_and_exec.zig) | Open a database and execute raw SQL |
| 02 | [`prepared_statement`](examples/02_prepared_statement.zig) | Parameterized queries with prepared statements |
| 03 | [`transactions`](examples/03_transactions.zig) | BEGIN, COMMIT, ROLLBACK with typed DSL |
| 04 | [`dsl_query_builder`](examples/04_dsl_query_builder.zig) | Type-safe comptime query builder basics |
| 05 | [`migrations`](examples/05_migrations.zig) | Schema migration patterns |
| 06 | [`error_handling`](examples/06_error_handling.zig) | Error handling and recovery |
| 07 | [`python_interop`](examples/07_python_interop.zig) | Interop with Python sqlite3 module |
| 08 | [`repair_legacy_example`](examples/08_repair_legacy_example.zig) | Repair and legacy database handling |
| 09 | [`dsl_crud`](examples/09_dsl_crud.zig) | Full CRUD operations via typed DSL |
| 10 | [`dsl_advanced`](examples/10_dsl_advanced.zig) | Advanced DSL queries and predicates |
| 11 | [`keys_and_joins`](examples/11_keys_and_joins.zig) | Primary keys, foreign keys, and JOIN queries |
| 12 | [`complex_queries`](examples/12_complex_queries.zig) | DISTINCT joins and aggregate functions |
| 13 | [`edge_cases`](examples/13_edge_cases.zig) | NULL handling, savepoints, and error cases |
| 14 | [`dsl_select_projections`](examples/14_dsl_select_projections.zig) | SELECT field projections with selectFields() |
| 15 | [`raw_dsl_interoperability`](examples/15_raw_dsl_interoperability.zig) | Verify raw SQL and DSL produce identical results |
| 16 | [`dsl_predicates_pagination`](examples/16_dsl_predicates_pagination.zig) | WHERE predicates with LIMIT/OFFSET pagination |
| 17 | [`persistence_reopen_verification`](examples/17_persistence_reopen_verification.zig) | Data persistence across database close/reopen |
| 18 | [`schema_lifecycle_verification`](examples/18_schema_lifecycle_verification.zig) | CREATE, ALTER, DROP table lifecycle |
| 19 | [`prepared_parameter_verification`](examples/19_prepared_parameter_verification.zig) | Typed parameter binding in prepared statements |
| 20 | [`scalar_functions_typed_dsl`](examples/20_scalar_functions_typed_dsl.zig) | ABS, LENGTH, UPPER, LOWER, SUBSTR functions |
| 21 | [`indexed_queries`](examples/21_indexed_queries.zig) | Index creation and optimized lookups |
| 22 | [`views_and_typed_reads`](examples/22_views_and_typed_reads.zig) | CREATE VIEW with typed DSL reads |
| 23 | [`triggers_raw_and_dsl`](examples/23_triggers_raw_and_dsl.zig) | BEFORE/AFTER INSERT triggers |
| 24 | [`cte_raw_and_typed_reads`](examples/24_cte_raw_and_typed_reads.zig) | Common Table Expressions with typed reads |
| 25 | [`subqueries_raw_and_typed_dsl`](examples/25_subqueries_raw_and_typed_dsl.zig) | Subqueries in FROM and WHERE clauses |
| 26 | [`foreign_key_actions`](examples/26_foreign_key_actions.zig) | CASCADE DELETE and SET NULL actions |
| 27 | [`composite_unique_keys`](examples/27_composite_unique_keys.zig) | Composite unique constraints |
| 28 | [`foreign_key_update_actions`](examples/28_foreign_key_update_actions.zig) | CASCADE UPDATE and SET DEFAULT actions |
| 29 | [`multiple_ctes`](examples/29_multiple_ctes.zig) | Multiple CTEs with cross-CTE joins |
| 30 | [`composite_table_constraints`](examples/30_composite_table_constraints.zig) | Composite PRIMARY KEY and UNIQUE |
| 31 | [`composite_foreign_keys`](examples/31_composite_foreign_keys.zig) | Composite foreign keys referencing multiple columns |
| 32 | [`recursive_ctes`](examples/32_recursive_ctes.zig) | Recursive CTEs for hierarchical tree traversal |

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
