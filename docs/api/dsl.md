# DSL API

The typed DSL (Domain-Specific Language) query builder provides compile-time safety for all database operations.

## Table Definition

```zig
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct {
    id: i64,
    name: []const u8,
    email: []const u8,
});
```

## Query Builder Methods

### from()

Start a query on a table:

```zig
var query = db.from(User);
```

### insert()

Insert a row:

```zig
var result = try db.from(User).insert(.{
    .id = 1,
    .name = "Alice",
    .email = "alice@example.com",
});
result.deinit();
```

### fetchAll()

Execute and return all rows:

```zig
var result = try db.from(User).fetchAll();
defer result.deinit();
```

### where()

Filter rows:

```zig
var result = try db.from(User)
    .where(User.column("name").eq("Alice"))
    .fetchAll();
defer result.deinit();
```

### select() / selectFields() / selectAll()

Select specific columns:

```zig
var result = try db.from(User).select(&.{ "id", "name" }).fetchAll();
defer result.deinit();

// Using selectFields
var result2 = try db.from(User).selectFields(&.{ "id", "name" }).fetchAll();
defer result2.deinit();
```

### limit() / offset()

Pagination:

```zig
var result = try db.from(User).limit(10).offset(20).fetchAll();
defer result.deinit();
```

### distinct()

Remove duplicate rows:

```zig
var result = try db.from(User)
    .innerJoin(Order, "id", "user_id")
    .select("*")
    .distinct()
    .fetchAll();
defer result.deinit();
```

## Joins

```zig
// Inner join
var result = try db.from(User)
    .innerJoin(Order, "id", "user_id")
    .fetchAll();

// Left join
var result = try db.from(User)
    .leftJoin(Order, "id", "user_id")
    .fetchAll();

// Right join
var result = try db.from(User)
    .rightJoin(Order, "id", "user_id")
    .fetchAll();

// Full join
var result = try db.from(User)
    .fullJoin(Order, "id", "user_id")
    .fetchAll();
```

## Aggregates

```zig
var total = try db.from(Order).sum("amount").fetchAll();
var avg = try db.from(Order).average("amount").fetchAll();
var min = try db.from(Order).minimum("amount").fetchAll();
var max = try db.from(Order).maximum("amount").fetchAll();
var count = try db.from(Order).count("id").fetchAll();
```

## Update

```zig
var result = try db.from(User)
    .where(User.column("id").eq(1))
    .update(.{ .name = "Bob" });
result.deinit();
```

## Delete

```zig
var result = try db.from(User)
    .where(User.column("id").eq(1))
    .delete();
result.deinit();
```

## Expressions

```zig
User.column("age").eq(25)
User.column("name").ne("Bob")
User.column("amount").gt(100)
User.column("amount").gte(100)
User.column("amount").lt(50)
User.column("amount").lte(50)
User.column("name").like("%alice%")
User.column("name").isNull()
User.column("name").isNotNull()
User.column("id").between(1, 10)
User.column("id").in(&.{ 1, 2, 3 })
```
