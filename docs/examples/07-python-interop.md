---
title: "Python Interoperability"
description: "Demonstrate SQLite database interoperability between Zig and Python by sharing a database file."
---

# Python Interoperability

Demonstrate SQLite database interoperability between Zig and Python by sharing a database file.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT) | Creates the users table with primary key |
| 2 | SELECT name FROM users WHERE id = 7 | Checks if user id=7 exists |
| 3 | INSERT INTO users VALUES (7, 'Python') | Inserts user if not found |
| 4 | SELECT name FROM users WHERE id = 7 | Verifies the inserted data |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "python_interop.db");
    defer db.close();
    if (!db.tableExists(User)) {
        try db.createTable(User, .{ .if_not_exists = true, .primary_key = User.key("id") });
    }
    var result = try db.exec("SELECT name FROM users WHERE id = 7;");
    if (result.rowCount() == 0) {
        result.deinit();
        var inserted = try db.from(User).insert(.{ .id = 7, .name = "Python" });
        inserted.deinit();
        result = try db.exec("SELECT name FROM users WHERE id = 7;");
    }
    defer result.deinit();
    if (result.rowCount() != 1 or !std.mem.eql(u8, result.rows[0][0].text, "Python")) return error.InteropMismatch;
}
```

## Database State After Execution

| id | name |
|----|------|
| 7 | Python |

## Zig Output

```
No console output - operations completed successfully
```

> [!TIP]
> Run with: `zig build run-07_python_interop`
