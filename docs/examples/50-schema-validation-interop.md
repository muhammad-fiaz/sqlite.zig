---
title: "Schema Validation Interop"
description: "Adopt Raw-SQL-created tables into the typed DSL only after strict schema validation."
---

# Schema Validation Interop

Raw SQL creates a legacy table, the dynamic DSL queries it with no struct,
and the typed DSL adopts it after `db.schema(User).validate()`. A mismatched
declaration fails with `error.SchemaMismatch` instead of silently proceeding.

## What This Example Does

| Step | Operation | Description |
|------|-----------|-------------|
| 1 | Raw `CREATE TABLE` + `INSERT` | Legacy table with data |
| 2 | `db.from("validation_users")` | Dynamic DSL reads immediately |
| 3 | `db.schema(User).validate()` | Typed schema adopts the table |
| 4 | `db.from(User).where(...)` | Typed query with mapped rows |
| 5 | Wrong struct validated | Rejected with `SchemaMismatch` |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("validation_users", struct { id: i64, email: []const u8, age: ?i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_50.db");
    defer db.close();

    var setup = try db.exec("DROP TABLE IF EXISTS validation_users; CREATE TABLE validation_users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, age INTEGER); INSERT INTO validation_users VALUES (1, 'ada@example.test', 36);");
    setup.deinit();

    var dyn = try db.from("validation_users").where(db.col("email").like("%@example.test")).fetch();
    defer dyn.deinit();
    if (dyn.rowCount() != 1) return error.DynamicInteropFailed;

    try db.schema(User).validate();
    var typed = try db.from(User).where(User.columns.age.gte(18)).fetch();
    defer typed.deinit();
    if (typed.rowCount() != 1 or !std.mem.eql(u8, typed.rows[0].email, "ada@example.test")) return error.TypedInteropFailed;

    const Wrong = sqlite.table("validation_users", struct { id: i64, email: []const u8 });
    if (db.schema(Wrong).validate()) {
        return error.MismatchWasAccepted;
    } else |err| {
        if (err != error.SchemaMismatch) return err;
    }

    std.debug.print("50 schema validation: raw, dynamic, and typed interop verified\n", .{});
}
```

## Zig Output

```text
50 schema validation: raw, dynamic, and typed interop verified
```

> [!TIP]
> Run with: `zig build run-50_schema_validation_interop`
