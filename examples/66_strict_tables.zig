const std = @import("std");
const sqlite = @import("sqlite");

const Strict = sqlite.table("strict_widgets", struct { id: i64, label: []const u8, score: f64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_66.db");
    const t_db_strict_widgets = db.table("strict_widgets");
    errdefer db.close();
    try db.createTable(Strict, .{ .overWrite = true, .primaryKey = Strict.id, .strict = true });
    try db.schema(Strict).validate();
    var inserted = try db.from(Strict).insert(.{ .id = 1, .label = "gear", .score = 9.5 });
    inserted.deinit();
    var dynInserted = try t_db_strict_widgets.insert(.{ .id = 2, .label = "bolt", .score = 7.25 });
    dynInserted.deinit();
    var rawInserted = try db.exec("INSERT INTO strict_widgets VALUES (3, 'nut', 1.0);");
    rawInserted.deinit();
    var raw = try db.exec("SELECT id, label, score FROM strict_widgets ORDER BY id;");
    defer raw.deinit();
    if (raw.count() != 3) return error.VerificationFailed;
    var dyn = try t_db_strict_widgets.selectAll().orderBy(t_db_strict_widgets.column("id").asc()).fetch();
    defer dyn.deinit();
    if (dyn.count() != 3) return error.VerificationFailed;
    var typed = try db.from(Strict).select(Strict.all()).orderBy(Strict.id.asc()).fetch();
    defer typed.deinit();
    if (typed.count() != 3) return error.VerificationFailed;
    if (!std.mem.eql(u8, typed.at(0).label, "gear")) return error.VerificationFailed;
    // STRICT rejects wrong-type writes in every interface.
    if (db.exec("INSERT INTO strict_widgets VALUES ('nope', 'x', 1.0);")) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    if (t_db_strict_widgets.insert(.{ .id = 4, .label = 999, .score = 1.0 })) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    var intact = try db.exec("SELECT count(*) FROM strict_widgets;");
    defer intact.deinit();
    if (intact.at(0)[0].integer != 3) return error.VerificationFailed;
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_66.db");
    defer reopened.close();
    try reopened.schema(Strict).validate();
    var persisted = try reopened.exec("SELECT count(*) FROM strict_widgets;");
    defer persisted.deinit();
    if (persisted.at(0)[0].integer != 3) return error.VerificationFailed;
    std.debug.print("66 strict tables: raw dynamic typed verified with persistence\n", .{});
}
