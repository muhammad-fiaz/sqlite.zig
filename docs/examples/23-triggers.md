---
title: "Triggers"
description: "BEFORE/AFTER INSERT triggers"
---

# Triggers

Use BEFORE and AFTER INSERT triggers for automated actions.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_23.db");
    defer db.close();
    var result = try db.exec("CREATE TABLE IF NOT EXISTS audit (id INTEGER, action TEXT);");
    result.deinit();
    result = try db.exec("CREATE TABLE IF NOT EXISTS trigger_target (id INTEGER);");
    result.deinit();
    result = try db.exec(
        \\CREATE TRIGGER IF NOT EXISTS audit_insert
        \\AFTER INSERT ON trigger_target
        \\BEGIN
        \\  INSERT INTO audit VALUES (NEW.id, 'INSERT');
        \\END
    );
    result.deinit();
    result = try db.exec("INSERT INTO trigger_target VALUES (1);");
    result.deinit();
    var rows = try db.exec("SELECT * FROM audit;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}
```

> [!TIP]
> Run with: `zig build run-23-triggers`