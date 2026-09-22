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
const users = db.table("users");
var dyn = try db.from(users)
    .select(.{ users.column("id"), users.column("name") })
    .where(db.col("age").gte(18))
    .orderBy(users.column("name").asc())
    .fetch();
defer dyn.deinit();

// Typed DSL: Zig structs, compile-time columns, typed rows.
const User = sqlite.table("users", struct {
    id: i64,
    name: []const u8,
    age: i64,
});
var typed = try db.from(User)
    .where(User.age.gte(18))
    .orderBy(User.name.asc())
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
`DEFAULT` clause. Every struct field is exposed as `User.<field>`,
so an unknown column is a compile error.

## Columns named like DSL operations

The API rule is simple: **fields are schema data, methods are operations**.
`User.id`, `User.count`, even `User.where` are always plain column
descriptors, so a table may legally declare columns named `all`, `count`,
`select`, `where`, `limit`, and friends — they keep working as columns
with full expression methods (`Weird.where.eq("x")`,
`Weird.limit.desc()`).

The all-columns operation is `User.all()` (a generated call), which builds
the native all-columns node behind `select(User.all())`. One hard limit
comes from Zig itself: a struct cannot hold a field and a function under
one name, so when the schema defines its own `all` column, that real
column owns the `all` member and the operation moves to
`db.from(User).selectAll()` — which builds the exact same node. See
`examples/70_collision_free_dsl.zig`.

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

## Columns: `table.column()` vs `db.col()`

The canonical explicit Dynamic form is `users.column("id")`: the column
carries its table identity, so joins and self-joins resolve unambiguously.
`db.col("id")` is optional syntactic sugar for an unqualified runtime column
reference. Both construct the same native column-reference node; the resolver
applies SQLite's normal name-resolution rules, and an ambiguous unqualified
reference (two tables exposing `id` in one query) is an error rather than a
silent pick of one side. Prefer `table.column()` whenever the table is known
and reach for `db.col()` for concise single-table predicates. Dotted sugar
`db.col("users.id")` is accepted and resolves as a qualified reference.

Typed: `User.id`. Dynamic: `users.column("id")`, sugar `db.col("id")`
(qualified form `db.col("users.id")` is accepted). Both spell every predicate the same way:

```zig
User.age.eq(18)      // =          db.col("age").eq(18)
User.age.ne(18)      // <>
User.age.lt(18)      // <
User.age.lte(18)     // <=
User.age.gt(18)      // >
User.age.gte(18)     // >=
User.name.like("A%") // LIKE (also notLike)
User.name.glob("A*") // GLOB, case-sensitive (also notGlob)
User.age.is(18)      // IS (also isNot)
User.name.isNull()   // IS NULL (also isNotNull)
User.age.isDistinctFrom(18) // IS DISTINCT FROM (also isNotDistinctFrom)
User.age.between(18, 30)    // BETWEEN (also notBetween)
```

Ordering: `User.name.asc()` / `.desc()`. Aggregates are column
projections used with `select`:

```zig
.select(.{Order.amount.sum()})   // also avg/min/max/count/countDistinct
```

Scalar wrappers (engine-supported functions only) compose with predicates
and projections:

```zig
.where(User.name.lower().eq("alice"))
.select(.{User.payload.jsonExtract("$.city")})
```

Available: `lower/upper/trim/ltrim/rtrim/length/abs/typeOf/round/coalesce/
ifNull/instr/substr/replace/cast/jsonExtract/jsonSet`.

A predicate can compare two columns (JOIN ON, correlated EXISTS):

```zig
User.id.eq(Order.user_id)
```

## Table scope: scoped fields and explicit paths

`db.from(User)` establishes User as the query's root scope. Inside that
scope, unqualified typed fields resolve against the root table, while
explicit table paths carry their own identity. Both forms converge on the
same native column reference; neither generates SQL text.

```zig
// Scoped: .id means User.id because User is the root table.
db.from(User).select(.{ .id, .name });
db.from(User).orderBy(.name).groupBy(.{.id});

// Explicit: qualification survives regardless of scope.
db.from(User).select(.{ User.id, User.name });
db.from(User).where(User.id.eq(1));
```

Column lists accept scoped fields, explicit descriptors, or a mix of both:

```zig
db.from(User).join(Membership, .inner, User.id.eq(Membership.user_id))
    .where(User.id.eq(1))
    .select(.{ .id, Membership.group_id });
```

Predicate positions (`where`, `having`, join conditions) cannot take a
bare `.id` — Zig has no syntax for an operator on an unscoped literal —
so the query exposes its scoped columns as a value:

```zig
const q = db.from(User);
q.where(q.c().id.eq(1)).select(.{.name});
```

Writes accept scoped row structs and explicit qualified assignments:

```zig
db.from(Membership).insert(.{ .user_id = 1, .group_id = 10 });
db.from(Membership).insert(.{
    Membership.user_id.set(1),
    Membership.group_id.set(10),
});
db.from(User).update(.{User.name.set("Alice"), User.age.set(User.age.add(1))});
```

`set()` payloads are type-checked like row-struct fields (literals coerce
to the declared Zig type, including range checks); column references,
arithmetic, `excluded()` (upserts only), and explicit value/default
markers pass through natively.

Schema objects resolve the same way against the table being defined
(`.primaryKey = .id`, `.unique = &.{.email}`, `.column = .thing_id`,
`createIndex(User, "idx", .{.email}, ...)`, `addColumn(User, .nick, ...)`).
Foreign-key `references` must stay explicit (`Parent.id`): the parent
scope is unknown there, so a bare field would be a guess. Unknown scoped
fields and cross-table assigns fail loudly (compile error or
`UnknownColumn`), never by silent picking.

Aliases never mutate the schema. `sqlite.aliased(User, "u")` rebinds the
table value's columns to the alias; `db.from(User).as("u")` rebinds a
query instead, in which case scoped references qualify with the alias
while explicit `User.id` keeps the real table name. (Zig comptime structs
cannot carry methods, so a `User.as("u")` method is not expressible; the
free function is the alias API.)

Each nested query root (`db.from(...)` inside a CTE body reference,
a derived table, or a correlated `whereExists`) opens its own scope:
inner `.user_id` binds to the inner table while explicit outer paths
(`User.id`) still resolve. Typed CTE references are ordinary table
values over the CTE name (`sqlite.table("lite", LiteRow)`), so they
scope like any table; CTE bodies themselves and migration version
scripts stay SQL text by design (frozen, stable over time). See
`examples/72_scoped_and_explicit_typed.zig`.

## Queries

```zig
db.from(User)      // typed table value from sqlite.table(...)
const users = db.table("users");
db.from(users)     // dynamic table handle
users.selectAll()  // dynamic SELECT * without spelling db.from
```

One builder, one method chain:

```zig
.select(.{ User.id, User.name }) // heterogeneous tuple/array
.select(User.all())              // typed table.* (call the operation)
.selectAll()                     // SELECT * on any db.from(...) query
.distinct()
.where(expr).andWhere(expr).orWhere(expr)
.whereInValues(User.id, .{ 1, 2, 3 })
.whereNotInValues(User.id, .{ 1, 2, 3 })
.whereInQuery(User.id, Order, Order.user_id)
.whereNotInQuery(User.id, Order, Order.user_id)
.whereExists(Order, Order.user_id.eq(User.id))
.whereNotExists(Order, Order.user_id.eq(User.id))
.orderBy(User.name.asc())
.orderBy(.{ User.name.asc(), User.age.desc() }) // multi-key ORDER BY
.limit(10).offset(20)
    .groupBy(User.age).having(User.id.count().gt(1))
    .andHaving(User.age.avg().lt(40)) // compound HAVING AND
    .orHaving(User.id.count().gt(10)) // compound HAVING OR
    .countStar() // COUNT(*)
.with("live", "SELECT ...") // CTE with a raw SQL body
.withRecursive("nums", "SELECT 1 AS n", "SELECT n + 1 AS n FROM nums WHERE n < 5")
.fetch()     // one canonical fetch; see below
.fetchOne()  // single row or error.NoRows / error.TooManyRows
.fetchOptional() // single row or null
```

## Fetch

One execution operation for every mode. The return type is inferred: typed
full-row queries map into structs, everything else returns raw rows. Both
provide `rows`, `count()`, and `deinit()`.

```zig
const users = db.table("users");
var dyn = try db.from(users).where(users.column("age").gte(18)).fetch();
defer dyn.deinit();
dyn.rows[0][0].integer;

var typed = try db.from(User).where(User.age.gte(18)).fetch();
defer typed.deinit();
typed.rows[0].name;
```

`select()` projections and `countStar()` return raw rows even on typed
tables, because a projection is not a full struct row. `fetchOne()` returns
the single row or `error.NoRows` / `error.TooManyRows`; `fetchOptional()`
returns `null` when no row matches. Free typed rows with `freeRow` when done.

```zig
var user = try db.from(User).where(User.id.eq(1)).fetchOne();
defer db.from(User).freeRow(&user);
```

Joins take the other table (typed or name) plus a column-comparison
expression:

```zig
.innerJoin(Order, User.id.eq(Order.user_id))
.leftJoin(Order, User.id.eq(Order.user_id))
.rightJoin(Order, User.id.eq(Order.user_id))
.fullJoin(Order, User.id.eq(Order.user_id))
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
var updated = try mutation.where(User.id.eq(1)).execute();
defer updated.deinit();

var deleted = try db.from(User).delete().where(User.id.eq(1)).execute();
defer deleted.deinit();
```

Copies run through `insertSelect` (plus `insertSelectOrIgnore` /
`insertSelectOrReplace`), mapping source columns positionally with the same
constraint, trigger, and `RETURNING` handling as single-row inserts:

```zig
var copied = try db.from(Archive)
    .insertSelect(db.from(Active).select(.{ Active.id, Active.name }));
defer copied.deinit();
```

Updates can read a source table through `updateFrom` with an equi-join
predicate (assignments are literals; `delete` rejects a source table):

```zig
var updated = try db.from(Bal).update(.{ .flag = 1 })
    .updateFrom(Adj, Bal.id.eq(Adj.bal_id))
    .execute();
defer updated.deinit();
```

Advanced upserts use `onConflict` with `doNothing` / `doUpdate` (plus
`onConflictWhere`, `excluded` values, and `returning`); see the UPSERT
examples.

## Schema

```zig
// Typed: columns inferred; keys are descriptors (single or composite).
try db.createTable(User, .{ .primaryKey = User.id });
try db.createTable(Member, .{ .primaryKey = &.{ Member.tenant_id, Member.user_id } });
try db.createTable(User, .{ .unique = &.{User.email} });
try db.createTable(Order, .{ .foreignKeys = &.{
    .{ .column = Order.user_id, .references = User.id, .onDelete = .cascade },
    // Deferred variant: enforced at COMMIT instead of per statement.
    .{ .column = Order.coupon_id, .references = Coupon.id, .deferrable = true, .initiallyDeferred = true },
} });
// Foreign keys also accept `.onUpdate`, `.deferrable`, and
// `.initiallyDeferred` (the latter needs `.deferrable = true`).

// Dynamic: explicit columns plus string keys.
try db.createTable("users", .{
    .columns = &.{ .{ .name = "id", .type = "INTEGER" }, .{ .name = "email", .type = "TEXT" } },
    .primaryKey = "id",
    .unique = &.{ "email" },
});

try db.createIndex(User, "users_email_idx", .{User.email}, true);
try db.schema(User).validate(); // error.SchemaMismatch on divergence
```

Partial and expression indexes use `createIndexWhere` (descriptor columns
plus a predicate) and `createIndexExpr` (column names or SQL expressions,
with an optional predicate), covering typed and dynamic tables alike:

```zig
try db.createIndexWhere(User, "users_active_id", .{User.id}, false, "active = 1");
try db.createIndexExpr("users", "users_lower_email", &.{ "lower(email)" }, true, null);
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
`sqlite.DynamicColumn`, `db.from`, and `db.col`. There is no
`sqlite.dsl` namespace; `DynamicQuery`, `Builder`, `Mutation`, `Expr`,
and `Operator` stay internal implementation types reached by
inference.

Foreign-key actions are the engine's own: `.restrict`, `.cascade`,
`.setNull`, `.setDefault`, `.noAction`. Predicates include
`like`/`glob`/`regexp`/`match`; window functions, compound selects, CTEs,
derived tables, `RETURNING`, `insertSelect`, `updateFrom`, and partial /
expression index creation (`createIndexWhere` / `createIndexExpr`) all have
DSL builders. Named `WINDOW` clauses are Raw SQL only — the DSL reuses a
shared `WindowBuilder` value instead of a name. Features without a
builder stay in Raw SQL: `VACUUM` and `ALTER TABLE` are supported
there, while `INSTEAD OF` triggers and `ATTACH`/`DETACH` are not
supported and fail with an explicit error.

Builder limits (misuse panics instead of silently truncating): at most 32
projections, 16 `where`/`andWhere`/`orWhere` predicates, 32 literal `IN`
values, 16 key columns, 8 foreign keys, and 8 composite unique groups.

Raw SQL, Dynamic DSL, and Typed DSL share the same underlying engine. Use
Raw SQL for anything without a DSL builder; the
[SQL engine guide](/guide/sql-engine) describes what Raw SQL supports.
