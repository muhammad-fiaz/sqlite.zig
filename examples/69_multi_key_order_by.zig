const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("sort_items", struct { grp: ?[]const u8, val: i64, tag: ?[]const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_69.db");
    const t_db_sort_items = db.table("sort_items");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS sort_items; DROP TABLE IF EXISTS sort_a; DROP TABLE IF EXISTS sort_b; CREATE TABLE sort_items (grp TEXT, val INTEGER, tag TEXT); INSERT INTO sort_items VALUES ('b', 2, 'x'), ('a', 1, 'y'), ('b', 1, 'z'), ('a', 2, NULL), ('a', 1, 'w'), (NULL, 0, 'n'); CREATE TABLE sort_a (id INTEGER, v TEXT); CREATE TABLE sort_b (id INTEGER, w TEXT); INSERT INTO sort_a VALUES (1, 'a1'), (2, 'a2'), (3, 'a3'); INSERT INTO sort_b VALUES (2, 'b2'), (3, 'b3'), (4, 'b4');");
    setup.deinit();
    // Raw multi-key: ties on grp broken by val, then tag; NULLs first under ASC.
    var raw = try db.exec("SELECT grp, val, tag FROM sort_items ORDER BY grp, val, tag;");
    defer raw.deinit();
    if (raw.count() != 6) return error.VerificationFailed;
    if (raw.rows[0][0] != .null) return error.VerificationFailed;
    if (!std.mem.eql(u8, raw.rows[1][2].text, "w")) return error.VerificationFailed;
    if (!std.mem.eql(u8, raw.rows[2][2].text, "y")) return error.VerificationFailed;
    if (raw.rows[3][2] != .null) return error.VerificationFailed;
    if (raw.rows[4][1].integer != 1) return error.VerificationFailed;
    // Per-key DESC inverts placement (NULLs last under DESC).
    var rawDesc = try db.exec("SELECT grp, val FROM sort_items ORDER BY grp DESC, val ASC;");
    defer rawDesc.deinit();
    if (rawDesc.count() != 6) return error.VerificationFailed;
    if (!std.mem.eql(u8, rawDesc.rows[0][0].text, "b")) return error.VerificationFailed;
    if (rawDesc.rows[0][1].integer != 1) return error.VerificationFailed;
    if (rawDesc.rows[5][0] != .null) return error.VerificationFailed;
    // Dynamic and Typed tuples build the same key list.
    var dyn = try t_db_sort_items.select(.{ t_db_sort_items.column("grp"), t_db_sort_items.column("val"), t_db_sort_items.column("tag") }).orderBy(.{ t_db_sort_items.column("grp").asc(), t_db_sort_items.column("val").desc() }).fetch();
    defer dyn.deinit();
    var typed = try db.from(Item).select(.{ Item.grp, Item.val, Item.tag }).orderBy(.{ Item.grp.asc(), Item.val.desc() }).fetch();
    defer typed.deinit();
    var rawMixed = try db.exec("SELECT grp, val, tag FROM sort_items ORDER BY grp ASC, val DESC;");
    defer rawMixed.deinit();
    if (dyn.count() != rawMixed.count() or typed.count() != rawMixed.count()) return error.VerificationFailed;
    for (0..rawMixed.count()) |i| {
        if (rawMixed.rows[i][1].integer != dyn.rows[i][1].integer) return error.VerificationFailed;
        if (rawMixed.rows[i][1].integer != typed.rows[i][1].integer) return error.VerificationFailed;
    }
    if (rawMixed.rows[1][1].integer != 2) return error.VerificationFailed;
    // Compound trailing ORDER BY takes multiple keys.
    var compound = try db.exec("SELECT grp, val FROM sort_items WHERE grp = 'a' UNION ALL SELECT grp, val FROM sort_items WHERE grp = 'b' ORDER BY 1 DESC, 2 ASC;");
    defer compound.deinit();
    if (compound.count() != 5) return error.VerificationFailed;
    if (!std.mem.eql(u8, compound.rows[0][0].text, "b")) return error.VerificationFailed;
    if (compound.rows[0][1].integer != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, compound.rows[2][0].text, "a")) return error.VerificationFailed;
    // Qualified keys resolve against their own table, not a same-named column.
    var qual = try db.exec("SELECT sort_a.id, sort_b.id FROM sort_a FULL JOIN sort_b ON sort_a.id = sort_b.id ORDER BY sort_a.id DESC, sort_b.id ASC;");
    defer qual.deinit();
    if (qual.count() != 4) return error.VerificationFailed;
    if (qual.rows[0][0].integer != 3) return error.VerificationFailed;
    if (qual.rows[2][0].integer != 1) return error.VerificationFailed;
    if (qual.rows[3][0] != .null) return error.VerificationFailed;
    if (qual.rows[3][1].integer != 4) return error.VerificationFailed;
    // Unknown keys stay errors, never silent picks.
    if (db.exec("SELECT grp FROM sort_items ORDER BY nope;")) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_69.db");
    defer reopened.close();
    var persisted = try reopened.exec("SELECT grp, val, tag FROM sort_items ORDER BY grp, val, tag;");
    defer persisted.deinit();
    if (persisted.count() != 6) return error.VerificationFailed;
    if (persisted.rows[0][0] != .null) return error.VerificationFailed;
    if (!std.mem.eql(u8, persisted.rows[1][2].text, "w")) return error.VerificationFailed;
    std.debug.print("69 multi-key order by: raw dynamic typed verified with persistence\n", .{});
}
