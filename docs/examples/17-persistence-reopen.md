---
title: "Persistence"
description: "Data persists after close/reopen"
---

# Persistence

Verify that data persists after closing and reopening the database.

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const Record = sqlite.table("persist_records", struct { id: i64, value: i64 });

pub fn main() !void {
    const path = "valid_17.db";
    {
        var db = try sqlite.open(std.heap.page_allocator, path);
        defer db.close();
        try db.createTable(Record, .{ .if_not_exists = true });
        try db.truncate(Record);
        var ins = try db.from(Record).insert(.{ .id = 1, .value = 42 });
        ins.deinit();
    }
    {
        var db = try sqlite.open(std.heap.page_allocator, path);
        defer db.close();
        var result = try db.from(Record).fetchAll();
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.rowCount());
    }
}
```

> [!TIP]
> Run with: `zig build run-17-persistence-reopen`