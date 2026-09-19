---
title: "DSL API"
description: "Raw SQL, the dynamic (runtime) DSL, and the typed (compile-time) DSL: one shared query engine."
---

# DSL API

`sqlite.zig` offers three interfaces over one engine. Raw SQL is unrestricted;
the two DSL modes share Raw SQL's expression model and executor: builders
construct the same internal query representation directly, with no SQL
string round-trip.

```zig
// Raw SQL: any SQLite the engine parses.
var rows = try db.exec("SELECT id, name FROM users WHERE age >= 18;");
defer rows.deinit();

// Dynamic DSL: runtime table/column names, no struct required.
var dyn = try db.from("users")
    .select(.{ db.col("id"), db.col("name") })
    .where(db.col("age").gte(18))
    .orderBy(db.col("name").asc())
    .fetch();
defer dyn.deinit();

// Typed DSL: Zig structs, compile-time columns, typed rows.
const User = sqlite.table("users", struct {
    id: i64,
    name: []const u8,
    age: i64,
});
var typed = try db.from(User)
    .where(User.columns.age.gte(18))
    .orderBy(User.columns.name.asc())
    .fetch();
defer typed.deinit();
```

## Table definition

```zig
const User = sqlite.table("users", struct {
    id: i64,
    name: []const u8,
    age: ?i64, // nullable column
});
```

Type mapping: `int`/`bool` to `INTEGER`, `float` to `REAL`,
`[]const u8` to `TEXT`, anything else to `BLOB`. Non-optional fields are
`NOT NULL`; `?T` fields are nullable. A struct field default becomes a
`DEFAULT` clause. Every struct field is exposed as `User.columns.<field>`,
so an unknown column is a compile error.

Keys and constraints can be declared once with field names so schema
validation and table creation share them:

```zig
const User = sqlite.tableWith("users", struct {
    id: i64,
    email: []const u8,
}, .{
    .primaryKey = "id",
    .unique = &.{ "email" },
});
```

## Columns

Typed: `User.columns.id`. Dynamic: `db.col("id")` (qualified form
`db.col("users.id")` is accepted). Both spell every predicate the same way:

```zig
User.columns.age.eq(18)      // =          db.col("age").eq(18)
User.columns.age.ne(18)      // <>
User.columns.age.lt(18)      // <
User.columns.age.lte(18)     // <=
User.columns.age.gt(18)      // >
User.columns.age.gte(18)     // >=
User.columns.name.like("A%") // LIKE (also notLike)
User.columns.name.glob("A*") // GLOB, case-sensitive (also notGlob)
User.columns.age.is(18)      // IS (also isNot)
User.columns.name.isNull()   // IS NULL (also isNotNull)
User.columns.age.isDistinctFrom(18) // IS DISTINCT FROM (also isNotDistinctFrom)
User.columns.age.between(18, 30)    // BETWEEN (also notBetween)
```

Ordering: `User.columns.name.asc()` / `.desc()`. Aggregates are column
projections used with `select`:

```zig
.select(.{Order.columns.amount.sum()})   // also avg/min/max/count/countDistinct
```

Scalar wrappers (engine-supported functions only) compose with predicates
and projections:

```zig
.where(User.columns.name.lower().eq("alice"))
.select(.{User.columns.payload.jsonExtract("$.city")})
```

Available: `lower/upper/trim/ltrim/rtrim/length/abs/typeOf/round/coalesce/
ifNull/instr/substr/replace/cast/jsonExtract/jsonSet`.

A predicate can compare two columns (JOIN ON, correlated EXISTS):

```zig
User.columns.id.eq(Order.columns.user_id)
```

## Queries

```zig
db.from(User)      // typed
db.from("users")   // dynamic
```

One builder, one method chain:

```zig
.select(.{ User.columns.id, User.columns.name }) // heterogeneous tuple/array
.selectAll()                                     // SELECT *
.distinct()
.where(expr).andWhere(expr).orWhere(expr)
.whereInValues(User.columns.id, .{ 1, 2, 3 })
.whereNotInValues(User.columns.id, .{ 1, 2, 3 })
.whereInQuery(User.columns.id, Order, Order.columns.user_id)
.whereNotInQuery(User.columns.id, Order, Order.columns.user_id)
.whereExists(Order, Order.columns.user_id.eq(User.columns.id))
.whereNotExists(Order, Order.columns.user_id.eq(User.columns.id))
.orderBy(User.columns.name.asc())
.limit(10).offset(20)
.groupBy(User.columns.age).havingCount(">", 1)
.countStar() // COUNT(*)
.with("live", "SELECT ...") // CTE with a raw SQL body
.withRecursive("nums", "SELECT 1 AS n", "SELECT n + 1 AS n FROM nums WHERE n < 5")
.fetch()     // one canonical fetch; see below
.fetchOne()  // typed full-row queries only: ?Row
```

## Fetch

One execution operation for every mode. The return type is inferred: typed
full-row queries map into structs, everything else returns raw rows. Both
provide `rows`, `count()`, and `deinit()`.

```zig
var dyn = try db.from("users").where(db.col("age").gte(18)).fetch();
defer dyn.deinit();
dyn.rows[0][0].integer;

var typed = try db.from(User).where(User.columns.age.gte(18)).fetch();
defer typed.deinit();
typed.rows[0].name;
```

`select()` projections and `countStar()` return raw rows even on typed
tables, because a projection is not a full struct row. `fetchOne()` is the
zero-or-one-row accessor for typed full-row queries; free its row with
`freeRow` when done.

```zig
if (try db.from(User).where(User.columns.id.eq(1)).fetchOne()) |*user| {
    defer db.from(User).freeRow(user);
}
```

Joins take the other table (typed or name) plus a column-comparison
expression:

```zig
.innerJoin(Order, User.columns.id.eq(Order.columns.user_id))
.leftJoin(Order, User.columns.id.eq(Order.columns.user_id))
.rightJoin(Order, User.columns.id.eq(Order.columns.user_id))
.fullJoin(Order, User.columns.id.eq(Order.columns.user_id))
.crossJoin(Order)
```

## Mutations

```zig
var inserted = try db.from(User).insert(.{ .id = 1, .name = "Alice", .age = 30 });
inserted.deinit();
var ignored = try db.from(User).insertOrIgnore(.{ .id = 1, .name = "Alice", .age = 30 });
ignored.deinit();
var replaced = try db.from(User).insertOrReplace(.{ .id = 1, .name = "Alice", .age = 30 });
replaced.deinit();

var mutation = try db.from(User).update(.{ .name = "Bob" });
var updated = try mutation.where(User.columns.id.eq(1)).execute();
defer updated.deinit();

var deleted = try db.from(User).delete().where(User.columns.id.eq(1)).execute();
defer deleted.deinit();
```

Advanced upserts use `onConflict` with `doNothing` / `doUpdate` (plus
`onConflictWhere`, `excluded` values, and `returning`); see the UPSERT
examples.

## Schema

```zig
// Typed: columns inferred; keys are descriptors (single or composite).
try db.createTable(User, .{ .primaryKey = User.columns.id });
try db.createTable(Member, .{ .primaryKey = &.{ Member.columns.tenant_id, Member.columns.user_id } });
try db.createTable(User, .{ .unique = &.{User.columns.email} });
try db.createTable(Order, .{ .foreignKeys = &.{
    .{ .column = Order.columns.user_id, .references = User.columns.id, .onDelete = .cascade },
} });

// Dynamic: explicit columns plus string keys.
try db.createTable("users", .{
    .columns = &.{ .{ .name = "id", .type = "INTEGER" }, .{ .name = "email", .type = "TEXT" } },
    .primaryKey = "id",
    .unique = &.{ "email" },
});

try db.createIndex(User, "users_email_idx", .{User.columns.email}, true);
try db.schema(User).validate(); // error.SchemaMismatch on divergence
```

## Explicit name mapping

SQL identifiers never change to satisfy Zig. Map camelCase fields onto
existing columns:

```zig
const User = sqlite.table("mapped_users", .{
    .firstName = sqlite.column("first_name", []const u8),
    .ageYears = sqlite.column("age_years", i64),
});
```

Inserts, updates, validation, and typed mapping translate in both
directions; key options always use SQL column names. Dynamic DSL and raw
SQL keep using the SQL names directly.

## Public surface

Clients use `sqlite.table`, `sqlite.tableWith`, `sqlite.column`,
`db.from`, and `db.col`. There is no `sqlite.dsl` namespace and no public
`DynamicColumn`, `DynamicQuery`, `Builder`, `Mutation`, `Expr`, or
`Operator`: those are internal implementation types reached by inference.

Foreign-key actions are the engine's own: `.restrict`, `.cascade`,
`.setNull`, `.setDefault`, `.noAction`. Predicates include
`like`/`glob`/`regexp`/`match`; window functions, compound selects, CTEs,
derived tables, and `RETURNING` all have DSL builders. Features without a
builder stay in Raw SQL: `VACUUM` is supported there, while partial
(`WHERE`) and expression indexes, `INSTEAD OF` triggers, and
`ATTACH`/`DETACH` are not supported and fail with an explicit error.

Builder limits (misuse panics instead of silently truncating): at most 32
projections, 16 `where`/`andWhere`/`orWhere` predicates, 32 literal `IN`
values, 16 key columns, 8 foreign keys, and 8 composite unique groups.

Raw SQL, Dynamic DSL, and Typed DSL share the same underlying engine. Use
Raw SQL for anything without a DSL builder; the
[SQL engine guide](/guide/sql-engine) describes what Raw SQL supports.
