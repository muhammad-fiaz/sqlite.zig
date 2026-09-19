const std = @import("std");
const sqlite = @import("sqlite");

const WalEvent = sqlite.table("wal_events", struct { id: i64, message: []const u8 });

fn checkRows(db: *sqlite.Connection) !void {
    var rows = try db.from(WalEvent).selectAll().fetch();
    defer rows.deinit();
    if (rows.count() != 1) return error.WalReadbackFailed;
    if (rows.rows[0].id != 1) return error.WalReadbackFailed;
    if (!std.mem.eql(u8, rows.rows[0].message, "written through wal")) return error.WalReadbackFailed;
}

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_35.db");
    var mode = try db.exec("PRAGMA journal_mode=WAL;");
    defer mode.deinit();
    if (mode.count() != 1 or !std.mem.eql(u8, mode.rows[0][0].text, "wal")) return error.WalModeNotEnabled;

    var created = try db.exec("CREATE TABLE IF NOT EXISTS wal_events (id INTEGER PRIMARY KEY, message TEXT NOT NULL);");
    created.deinit();
    var cleared = try db.exec("DELETE FROM wal_events;");
    cleared.deinit();
    var inserted = try db.exec("INSERT INTO wal_events (id, message) VALUES (1, 'written through wal');");
    inserted.deinit();
    db.close();

    var reopened = try sqlite.open(std.heap.page_allocator, "example_35.db");
    try checkRows(reopened);
    var checkpoint = try reopened.exec("PRAGMA journal_mode=DELETE;");
    checkpoint.deinit();
    reopened.close();

    var verified = try sqlite.open(std.heap.page_allocator, "example_35.db");
    defer verified.close();
    try checkRows(verified);
    std.debug.print("35 WAL journal mode: native WAL write, reopen, readback, and checkpoint verified\n", .{});
}
