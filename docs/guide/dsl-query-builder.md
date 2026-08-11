---
title: "DSL Query Builder"
description: "The typed DSL query builder providing compile-time safety for table definitions, queries, inserts, updates, and deletes."
---

# DSL Query Builder

The typed DSL (Domain-Specific Language) query builder provides compile-time safety for database operations. Table names, column names, and types are validated at compile time.

## Defining Tables

```zig
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct {
    id: i64,
    name: []const u8,
    email: []const u8,
});

const Order = sqlite.table("orders", struct {
    id: i64,
    user_id: i64,
    amount: i64,
});
```

## CRUD Operations

### Insert

```zig
var result = try db.from(User).insert(.{ .id = 1, .name = "Alice", .email = "alice@example.com" });
result.deinit();
```

### Select

```zig
// Fetch all rows
var all = try db.from(User).fetchAll();
defer all.deinit();

// With WHERE clause
var filtered = try db.from(User)
    .where(User.column("name").eq("Alice"))
    .fetchAll();
defer filtered.deinit();

// With specific columns
var projected = try db.from(User).select(&.{ "id", "name" }).fetchAll();
defer projected.deinit();

// Map named result columns back into the table struct.
var typed = try db.from(User).selectColumns(&.{ User.key("name"), User.key("id") }).fetchTyped();
defer typed.deinit();
const first_id = typed.rows[0].id;
```

### Update

```zig
var result = try db.from(User)
    .where(User.column("id").eq(1))
    .update(.{ .name = "Bob" });
result.deinit();
```

### Delete

```zig
var result = try db.from(User)
    .where(User.column("id").eq(1))
    .delete();
result.deinit();
```

## Joins

```zig
// Inner join
var result = try db.from(User)
    .innerJoin(Order, "id", "user_id")
    .select("*")
    .fetchAll();
defer result.deinit();

// Left join
var left = try db.from(User)
    .leftJoin(Order, "id", "user_id")
    .fetchAll();
defer left.deinit();
```

## DISTINCT

```zig
var result = try db.from(User)
    .innerJoin(Order, "id", "user_id")
    .select("*")
    .distinct()
    .fetchAll();
defer result.deinit();
```

## Aggregates

```zig
var total = try db.from(Order).sum("amount").fetchAll();
defer total.deinit();

var avg = try db.from(Order).average("amount").fetchAll();
defer avg.deinit();

var count = try db.from(Order).count("id").fetchAll();
defer count.deinit();
```

## Typed text projections

Column-backed helpers are available for common scalar text operations:

```zig
var changed = try db.from(User)
    .replaceColumn(User.key("name"), "Alice", "A.")
    .fetchAll();
defer changed.deinit();

var prefix = try db.from(User)
    .substrColumn(User.key("name"), 1, 3)
    .fetchAll();
defer prefix.deinit();
```

NULL fallback projections are also available without writing SQL:

```zig
var labels = try db.from(User)
    .coalesceColumn(User.key("nickname"), "anonymous")
    .fetchAll();
defer labels.deinit();
```

Use `ifNullColumn` for SQLite's two-argument `IFNULL` spelling.

Function predicates are also checked against the table struct:

Typed columns also provide concise text-search predicates:

```zig
var matches = try db.from(User)
    .where(User.key("name").contains("ali"))
    .fetchAll();
defer matches.deinit();
```

`contains("ali")`, `notContains("ali")`, `startsWith("Ali")`, and `endsWith("son")` generate
`LIKE` patterns `%ali%`, `Ali%`, and `%son` respectively.

```zig
var normalized = try db.from(User)
    .whereLower(User.key("name"), "alice")
    .fetchAll();
defer normalized.deinit();

// Generic checked scalar predicate.
var long_names = try db.from(User)
    .whereFunction("LENGTH", User.key("name"), .greater, 3)
    .fetchAll();
defer long_names.deinit();

var contains = try db.from(User)
    .whereFunction2("INSTR", User.key("name"), "ali", .greater, 0)
    .fetchAll();
defer contains.deinit();

var changed = try db.from(User)
    .where(User.key("name").isDistinctFrom(@as(sqlite.value.Value, .null)))
    .fetchAll();
defer changed.deinit();

var names = try db.from(User)
    .jsonExtractColumn(User.key("email"), "$.name")
    .fetchAll();
defer names.deinit();

var matching = try db.from(User)
    .whereJsonExtract(User.key("profile"), "$.city", .equal, "London")
    .fetchAll();
defer matching.deinit();
```

The column key is checked against the table struct at compile time; string-based
selection remains available when the projection is intentionally dynamic.

## Raw DSL

For tables without a Zig schema, use the schema-less Raw DSL. Runtime
identifiers are accepted here, while values are still rendered safely:

```zig
var rows = try db
    .from("users")
    .where(db.col("age").gte(18))
    .select("id, name")
    .fetchAll();
defer rows.deinit();
```

For an explicitly typed projection, use `selectTyped`:

```zig
var rows = try db.from(User)
    .selectTyped(&.{ User.key("id"), User.key("name") })
    .fetchAll();
defer rows.deinit();
```

For single-row lookups, `fetchOneTyped()` returns an optional row struct:

```zig
if (try db.from(User)
    .where(User.column("id").eq(1))
    .fetchOneTyped()) |*user| {
    defer db.from(User).deinitTypedRow(user);
    std.debug.print("{d} {s}\n", .{ user.id, user.name });
}
```

It returns `null` when no row matches. Typed text fields are allocator-owned;
release them with `deinitTypedRow`.

## Pagination

```zig
var page = try db.from(User)
    .select("*")
    .limit(10)
    .offset(20)
    .fetchAll();
defer page.deinit();
```

## Partial Struct Inserts

You can insert only a subset of columns:

```zig
var result = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
result.deinit();
```




