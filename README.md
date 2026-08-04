# sqlite.zig

A fully native SQLite-compatible database engine written entirely in Zig, with a complete implementation of the storage engine, SQL parser, query planner, and virtual machine.

> [!WARNING]
> This project is in **early, active development**. Core engine components described below are being implemented tier by tier. Expect missing features, incomplete SQL coverage, and breaking changes between commits.

> [!CAUTION]
> **Do not use this in production or on data you cannot afford to lose.** There is no stability guarantee on the file format, the API, or correctness of edge cases yet. Back up anything important separately.

---

## What this is

`sqlite.zig` re-implements the SQLite engine natively in Zig:

- The real on-disk `.sqlite`/`.db` file format (100-byte header, table/index B-tree pages, record encoding, varints, freelist pages).
- A hand-written SQL lexer, parser, and bytecode compiler/VM, modeled on SQLite's own architecture.
- WAL and rollback-journal durability modes.
- A type-safe, comptime Zig query builder (DSL) that sits on top of the same engine raw SQL uses, so both paths stay in sync.

It is a ground-up reimplementation, not a wrapper around the original C library. It aims for practical compatibility with real SQLite database files and SQL syntax, not a 1:1 reproduction of every SQLite internal.


---

## Requirements

- Zig **0.16.0** or later

---

## Installation

Add the dependency via `zig fetch`:

```sh
zig fetch --save https://github.com/muhammad-fiaz/sqlite.zig/archive/refs/heads/main.tar.gz
```

Then in `build.zig`:

```zig
const sqlite = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
```

> [!IMPORTANT]
> Pin to a specific commit or tag rather than tracking `main` directly. Until a tagged `0.x` release stream exists, `main` can change its public API at any time.


---

## Running tests and examples

```sh
zig build test
# Run every example
zig build run-all-examples
zig build docs
```

> [!NOTE]
> The hosted documentation site is not ready yet. You can generate the current up-to-date docs locally by running `zig build docs`, which emits the public API documentation to `zig-out/docs/index.html`.

### Typed DSL rows

DSL inserts and updates use Zig struct fields as column names. The field names are checked at compile time against the table schema, so an attribute that is not declared on the table fails compilation:

```zig
const Account = sqlite.table("accounts", struct { id: i64, owner: []const u8, balance: i64 });

var inserted = try db.from(Account).insert(.{ .id = 1, .owner = "Alice", .balance = 100 });
inserted.deinit();
```

Partial structs are supported for column-list inserts and updates. Typed selection, joins, and aggregates are also available through `Account.key("id")`, `selectColumns`/`selectAll`, `innerJoinKeys`/`leftJoinKeys`/`rightJoinKeys`/`fullJoinKeys`, and `sumColumn`/`averageColumn`/`minimumColumn`/`maximumColumn`/`countColumn`.

For strict full-row type checking, use `insertTyped` or `updateTyped`, whose parameter is exactly the declared table row struct.

For typed primary keys, use the canonical option `primary_key = Table.key("id")`. The string-based alternative is `primary_key_name = "id"`.

Composite table constraints are supported in both raw SQL and the typed API:

```zig
try db.createTable(Membership, .{
    .primary_keys = &.{ Membership.key("user_id"), Membership.key("group_id") },
    .unique_constraints = &.{&.{ Membership.key("group_id"), Membership.key("label") }},
});
```

Raw DDL can use `PRIMARY KEY (a, b)` and `UNIQUE (a, b)`. These constraints are persisted with SQLite autoindex entries and are checked during inserts, updates, transactions, and reopen.

Composite relationships are available through raw DDL and typed options:

```zig
try db.createTable(Child, .{
    .foreign_key_constraints = &.{.{
        .columns = &.{ Child.key("parent_a"), Child.key("parent_b") },
        .referenced_columns = &.{ Parent.key("part_a"), Parent.key("part_b") },
        .on_update = .cascade,
        .on_delete = .cascade,
    }},
});
```

> [!TIP]
> Every internal module ships its own `test` blocks at the bottom of the file it tests. Running `zig build test` is the fastest way to check whether a given part of the engine currently works as expected.

---

## Contributing

This project is being built out tier by tier: file format and storage first, then the B-tree engine, then the SQL front end and planner, then higher-level features (views, triggers, DSL), with advanced extensions (FTS5, JSON1, R-Tree) deferred until the core engine is solid.

> [!WARNING]
> Because the internal architecture is still shifting, expect merge conflicts and API churn if you build against internal modules directly (anything outside `src/sqlite.zig`). Prefer depending only on the public API surface.

Issues and pull requests are welcome. Please check open issues before starting large changes so effort isn't duplicated.

---

## License

MIT License, Copyright (c) 2026 Muhammad Fiaz.

See [LICENSE](./LICENSE) for the full text.

