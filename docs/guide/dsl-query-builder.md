---
title: "DSL Query Builder"
description: "Raw SQL, the dynamic DSL, and the typed DSL over one shared query engine."
---

# DSL Query Builder

Three interfaces share one engine: unrestricted raw SQL, a dynamic DSL for
runtime table/column names (no struct required), and a typed DSL where
`User.columns.<field>` gives compile-time columns and typed rows.

## Defining tables

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

Non-optional fields are `NOT NULL`, `?T` fields are nullable, and struct
field defaults become `DEFAULT` clauses.

## Dynamic queries without structs

```zig
var rows = try db
    .from("users")
    .select(.{ db.col("id"), db.col("name") })
    .where(db.col("age").gte(18))
    .orderBy(db.col("name").asc())
    .fetch();
defer rows.deinit();
```

This is the mode for existing databases, legacy schemas, runtime table
names, and ad-hoc queries: `db.from("users")` plus `db.col("age")` never
require a Zig struct.

## Typed queries

```zig
// Fetch all rows
var all = try db.from(User).fetch();
defer all.deinit();

// With WHERE clause
var filtered = try db.from(User)
    .where(User.columns.name.eq("Alice"))
    .fetch();
defer filtered.deinit();

// With specific columns (projections return raw rows)
var projected = try db.from(User).select(.{ User.columns.id, User.columns.name }).fetch();
defer projected.deinit();

// Full-row queries map back into the table struct.
var typed = try db.from(User).selectAll().fetch();
defer typed.deinit();
const firstId = typed.rows[0].id;
```

## CRUD operations

### Insert

```zig
var result = try db.from(User).insert(.{ .id = 1, .name = "Alice", .email = "alice@example.com" });
result.deinit();
```

Partial inserts name a subset of columns:

```zig
var partial = try db.from(User).insert(.{ .id = 1, .name = "Alice" });
partial.deinit();
```

Conflict handling: `insertOrIgnore` / `insertOrReplace`, plus full
`ON CONFLICT` support in the DSL:

```zig
var upserted = try db.from(User)
    .onConflict(User.columns.id)
    .doUpdate(.{ .name = "Alice" })
    .insert(.{ .id = 1, .name = "Alice", .email = "alice@example.com" });
upserted.deinit();
```

### Insert...Select

```zig
var copied = try db.from(Archive)
    .insertSelect(db.from(Active).select(.{ Active.columns.id, Active.columns.name }));
defer copied.deinit();
```

`insertSelectOrIgnore` / `insertSelectOrReplace` apply the matching
conflict policy per row. The source must project columns with `.select(...)`
so every value maps positionally, exactly like raw `INSERT ... SELECT`.

### Update

```zig
var mutation = try db.from(User).update(.{ .name = "Bob" });
var result = try mutation.where(User.columns.id.eq(1)).execute();
defer result.deinit();
```

Updates can read a source table with `updateFrom` and an equi-join predicate
(assignments are literals; combined freely with `where` filters):

```zig
var joined = try db.from(Bal).update(.{ .flag = 1 })
    .updateFrom(Adj, Bal.columns.id.eq(Adj.columns.bal_id))
    .execute();
defer joined.deinit();
```

### Delete

```zig
var result = try db.from(User).delete().where(User.columns.id.eq(1)).execute();
defer result.deinit();
```

## Joins

Joins take the other table plus one column-comparison expression:

```zig
// Inner join
var result = try db.from(User)
    .innerJoin(Order, User.columns.id.eq(Order.columns.user_id))
    .fetch();
defer result.deinit();

// Left join
var left = try db.from(User)
    .leftJoin(Order, User.columns.id.eq(Order.columns.user_id))
    .fetch();
defer left.deinit();
```

Dynamic equivalent:

```zig
var dyn = try db.from("users")
    .innerJoin("orders", db.col("users.id").eq(db.col("orders.user_id")))
    .fetch();
defer dyn.deinit();
```

## DISTINCT

```zig
var result = try db.from(User)
    .innerJoin(Order, User.columns.id.eq(Order.columns.user_id))
    .selectAll()
    .distinct()
    .fetch();
defer result.deinit();
```

## Aggregates

Aggregates are column projections used with `select`, freely combined in
one statement:

```zig
var total = try db.from(Order).select(.{Order.columns.amount.sum()}).fetch();
defer total.deinit();

var avg = try db.from(Order).select(.{Order.columns.amount.avg()}).fetch();
defer avg.deinit();

var count = try db.from(Order).select(.{Order.columns.id.count()}).fetch();
defer count.deinit();

var all = try db.from(Order).countStar().fetch(); // COUNT(*)
defer all.deinit();
```

## Scalar functions

Column wrappers cover the engine-supported functions and compose with both
predicates and projections:

```zig
var changed = try db.from(User)
    .select(.{User.columns.name.replace("Alice", "A.")})
    .fetch();
defer changed.deinit();

var prefix = try db.from(User)
    .select(.{User.columns.name.substr(1, 3)})
    .fetch();
defer prefix.deinit();

var labels = try db.from(User)
    .select(.{User.columns.name.coalesce("anonymous")})
    .fetch();
defer labels.deinit();

var normalized = try db.from(User)
    .where(User.columns.name.lower().eq("alice"))
    .fetch();
defer normalized.deinit();

var longNames = try db.from(User)
    .where(User.columns.name.length().gt(3))
    .fetch();
defer longNames.deinit();

var contains = try db.from(User)
    .where(User.columns.name.instr("ali").gt(0))
    .fetch();
defer contains.deinit();

var names = try db.from(User)
    .select(.{User.columns.email.jsonExtract("$.name")})
    .fetch();
defer names.deinit();

var matching = try db.from(User)
    .where(User.columns.email.jsonExtract("$.city").eq("London"))
    .fetch();
defer matching.deinit();
```

Text search uses `LIKE`/`GLOB` patterns directly:

```zig
var matches = try db.from(User)
    .where(User.columns.name.like("%ali%"))
    .fetch();
defer matches.deinit();
```

## Single-row typed lookups

```zig
if (try db.from(User)
    .where(User.columns.id.eq(1))
    .fetchOne()) |*user| {
    defer db.from(User).freeRow(user);
    std.debug.print("{d} {s}\n", .{ user.id, user.name });
}
```

It returns `null` when no row matches. Typed text fields are allocator-owned;
release them with `freeRow`.

## Pagination

```zig
var page = try db.from(User)
    .selectAll()
    .limit(10)
    .offset(20)
    .fetch();
defer page.deinit();
```

## CTEs

`.with` / `.withRecursive` prefix raw-SQL CTE bodies; the typed table names
the CTE being read, like a view:

```zig
var rows = try db.from(Live)
    .with("live", "SELECT id, name FROM users WHERE active = 1")
    .orderBy(Live.columns.id.asc())
    .fetch();
defer rows.deinit();
```

## Explicit name mapping

SQL names never change for Zig. Declare the mapping once:

```zig
const User = sqlite.table("users", .{
    .firstName = sqlite.column("first_name", []const u8),
});
```

Inserts, validation, and typed mapping translate both ways; key options
use SQL names. All three interfaces — Raw SQL, Dynamic DSL, and Typed DSL —
share the same underlying engine; anything without a DSL builder is available
through Raw SQL as described in the [SQL engine guide](/guide/sql-engine).
