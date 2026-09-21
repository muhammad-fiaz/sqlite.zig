const std = @import("std");
const sqlite = @import("sqlite");

const Entry = sqlite.table("wr_entries", struct { k1: i64, k2: []const u8, val: f64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_67.db");
    const t_db_wr_entries = db.table("wr_entries");
    errdefer db.close();
    try db.createTable(Entry, .{ .overWrite = true, .primaryKey = &.{ Entry.k1, Entry.k2 }, .withoutRowid = true });
    try db.schema(Entry).validate();
    var inserted = try db.from(Entry).insert(.{ .k1 = 1, .k2 = "a", .val = 1.5 });
    inserted.deinit();
    var dynInserted = try t_db_wr_entries.insert(.{ .k1 = 2, .k2 = "b", .val = 2.5 });
    dynInserted.deinit();
    var rawInserted = try db.exec("INSERT INTO wr_entries VALUES (3, 'c', 3.5);");
    rawInserted.deinit();
    var raw = try db.exec("SELECT k1, k2, val FROM wr_entries ORDER BY k1;");
    defer raw.deinit();
    if (raw.count() != 3) return error.VerificationFailed;
    var dyn = try t_db_wr_entries.selectAll().orderBy(t_db_wr_entries.column("k1").asc()).fetch();
    defer dyn.deinit();
    if (dyn.count() != 3) return error.VerificationFailed;
    var typed = try db.from(Entry).select(Entry.all()).orderBy(Entry.k1.asc()).fetch();
    defer typed.deinit();
    if (typed.count() != 3) return error.VerificationFailed;
    if (!std.mem.eql(u8, typed.at(0).k2, "a")) return error.VerificationFailed;
    // Primary-key lookup works without a rowid in every interface.
    var one = try db.from(Entry).select(Entry.all()).where(Entry.k1.eq(2)).fetchOne();
    if (!std.mem.eql(u8, one.k2, "b")) {
        db.from(Entry).freeRow(&one);
        return error.VerificationFailed;
    }
    db.from(Entry).freeRow(&one);
    // Duplicate keys and NULL key parts are rejected.
    if (db.from(Entry).insert(.{ .k1 = 3, .k2 = "c", .val = 9.0 })) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    if (db.exec("INSERT INTO wr_entries VALUES (NULL, 'z', 0.0);")) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    var intact = try db.exec("SELECT count(*) FROM wr_entries;");
    defer intact.deinit();
    if (intact.at(0)[0].integer != 3) return error.VerificationFailed;
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_67.db");
    defer reopened.close();
    try reopened.schema(Entry).validate();
    var persisted = try reopened.exec("SELECT count(*) FROM wr_entries;");
    defer persisted.deinit();
    if (persisted.at(0)[0].integer != 3) return error.VerificationFailed;
    std.debug.print("67 without rowid: raw dynamic typed verified with persistence\n", .{});
}
