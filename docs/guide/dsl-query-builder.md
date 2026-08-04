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
