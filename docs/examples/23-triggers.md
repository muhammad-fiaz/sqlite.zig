---
title: "Triggers with Raw and DSL"
description: "Create SQL triggers that automatically insert audit records when data is modified via DSL operations."
---

# Triggers with Raw and DSL

Create SQL triggers that automatically insert audit records when data is modified via DSL operations.

## What This Example Does

| Step | SQL Operation | Description |
|------|---------------|-------------|
| 1 | CREATE TABLE IF NOT EXISTS trigger_events (id INTEGER PRIMARY KEY, label TEXT) | Creates events table |
| 2 | CREATE TABLE IF NOT EXISTS trigger_audit (id INTEGER, message TEXT) | Creates audit table |
| 3 | DELETE FROM trigger_events | Truncates events |
| 4 | DELETE FROM trigger_audit | Truncates audit |
| 5 | CREATE TRIGGER events_after_insert AFTER INSERT ON trigger_events BEGIN INSERT INTO trigger_audit (id, message) VALUES (NEW.id, NEW.label); END | Creates trigger |
| 6 | INSERT INTO trigger_events VALUES (1, 'created by DSL') | Inserts event (trigger fires) |

## Source Code

```zig
const std = @import("std");
const sqlite = @import("sqlite");

const EventRow = struct { id: i64, label: []const u8 };
const Event = sqlite.table("trigger_events", EventRow);
const Audit = sqlite.table("trigger_audit", struct { id: i64, message: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_23.db");
    defer db.close();
    try db.createTable(Event, .{ .if_not_exists = true, .primary_key = Event.key("id") });
    try db.createTable(Audit, .{ .if_not_exists = true });
    try db.truncate(Event);
    try db.truncate(Audit);
    db.dropTrigger("events_after_insert") catch {};
    var trigger = try db.exec("CREATE TRIGGER events_after_insert AFTER INSERT ON trigger_events BEGIN INSERT INTO trigger_audit (id, message) VALUES (NEW.id, NEW.label); END;");
    trigger.deinit();

    var inserted = try db.from(Event).insertTyped(.{ .id = 1, .label = "created by DSL" });
    inserted.deinit();
    var audit = try db.from(Audit).selectAll().fetchAll();
    defer audit.deinit();
    if (audit.rowCount() != 1 or audit.rows[0][0].integer != 1 or !std.mem.eql(u8, audit.rows[0][1].text, "created by DSL")) return error.TriggerVerificationFailed;
    std.debug.print("23 triggers: raw trigger DDL, NEW references, and typed DSL mutation verified\n", .{});
}
```

## Database State After Execution

**trigger_events:**

| id | label |
|----|-------|
| 1 | created by DSL |

**trigger_audit (populated by trigger):**

| id | message |
|----|---------|
| 1 | created by DSL |

## Zig Output

```
23 triggers: raw trigger DDL, NEW references, and typed DSL mutation verified
```

> [!TIP]
> Run with: `zig build run-23_triggers_raw_and_dsl`
