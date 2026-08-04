const std = @import("std");
const sqlite = @import("sqlite");

const Note = sqlite.table("persisted_notes", struct { id: i64, body: []const u8 });

pub fn main() !void {
    const path = "valid_17.db";
    var db = try sqlite.open(std.heap.page_allocator, path);
    try db.createTable(Note, .{ .if_not_exists = true });
    try db.truncate(Note);
    var inserted = try db.from(Note).insert(.{ .id = 1, .body = "stored on disk" });
    inserted.deinit();
    db.close();

    db = try sqlite.open(std.heap.page_allocator, path);
    defer db.close();
    var rows = try db.from(Note).selectFieldNames(&.{ "id", "body" }).fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1 or rows.rows[0][0].integer != 1 or !std.mem.eql(u8, rows.rows[0][1].text, "stored on disk")) return error.PersistenceVerificationFailed;
    std.debug.print("17 persistence: persisted_notes contains {d} verified row\n", .{rows.rowCount()});
}
