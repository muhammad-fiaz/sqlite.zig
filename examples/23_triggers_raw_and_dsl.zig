const std = @import("std");
const sqlite = @import("sqlite");

const EventRow = struct { id: i64, label: []const u8 };
const Event = sqlite.table("trigger_events", EventRow);
const Audit = sqlite.table("trigger_audit", struct { id: i64, message: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_23.db");
    defer db.close();
    try db.createTable(Event, .{ .ifNotExists = true, .primaryKey = Event.columns.id });
    try db.createTable(Audit, .{ .ifNotExists = true });
    try db.truncate(Event);
    try db.truncate(Audit);
    db.dropTrigger("events_after_insert") catch {};
    var trigger = try db.exec("CREATE TRIGGER events_after_insert AFTER INSERT ON trigger_events BEGIN INSERT INTO trigger_audit (id, message) VALUES (NEW.id, NEW.label); END;");
    trigger.deinit();

    var inserted = try db.from(Event).insert(.{ .id = 1, .label = "created by DSL" });
    inserted.deinit();
    var audit = try db.from(Audit).selectAll().fetch();
    defer audit.deinit();
    if (audit.rowCount() != 1 or audit.rows[0].id != 1 or !std.mem.eql(u8, audit.rows[0].message, "created by DSL")) return error.TriggerVerificationFailed;
    std.debug.print("23 triggers: raw trigger DDL, NEW references, and typed DSL mutation verified\n", .{});
}
