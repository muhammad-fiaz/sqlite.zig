---
title: "Indexed Queries"
description: "Create unique and non-unique indexes, and verify constraint enforcement on indexed columns."
---

# Indexed Queries

Create unique and non-unique indexes, and verify constraint enforcement on indexed columns.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS indexed_customers (id INTEGER PRIMARY KEY, email TEXT, name TEXT) | Creates customers table |
| 2 | DELETE FROM indexed_customers | Truncates the table |
| 3 | INSERT INTO indexed_customers VALUES (1, 'one@example.test', 'One') | Inserts first customer |
| 4 | CREATE UNIQUE INDEX indexed_customers_email ON indexed_customers (email) | Creates unique index on email |
| 5 | INSERT INTO indexed_customers VALUES (2, 'one@example.test', 'Duplicate') | Fails due to unique constraint |
| 6 | CREATE INDEX indexed_customers_name ON indexed_customers (name) | Creates non-unique index on name |
| 7 | SELECT id, email FROM indexed_customers | Queries all customers |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const CustomerRow = struct { id: i64, email: []const u8, name: []const u8 };
const Customer = sqlite.table("indexed_customers", CustomerRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_21.db");
    defer db.close();
    try db.createTable(Customer, .{ .if_not_exists = true, .primary_key = Customer.key("id") });
    try db.truncate(Customer);
    db.dropIndex("indexed_customers_email") catch {};
    db.dropIndex("indexed_customers_name") catch {};
    var first = try db.from(Customer).insertTyped(.{ .id = 1, .email = "one@example.test", .name = "One" });
    first.deinit();

    try db.createIndex(Customer, "indexed_customers_email", &.{Customer.key("email")}, true);
    try std.testing.expectError(error.ConstraintViolation, db.from(Customer).insertTyped(.{ .id = 2, .email = "one@example.test", .name = "Duplicate" }));

    var raw_index = try db.exec("CREATE INDEX indexed_customers_name ON indexed_customers (name);");
    raw_index.deinit();
    var rows = try db.from(Customer).selectColumns(&.{ Customer.key("id"), Customer.key("email") }).fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1) return error.IndexedQueryVerificationFailed;
    std.debug.print("21 indexes: typed unique and raw non-unique indexes verified\n", .{});
}
```

## Database State After Execution

| id | email | name |
|----|-------|------|
| 1 | one@example.test | One |

## Zig Output

```
21 indexes: typed unique and raw non-unique indexes verified
```

> [!TIP]
> Run with: `zig build run-21_indexed_queries`
