const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("gen_items", struct { x: i64, y: i64, s: ?i64, v: ?i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_65.db");
    const t_db_gen_items = db.table("gen_items");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS gen_items; CREATE TABLE gen_items (x INTEGER NOT NULL, y INTEGER NOT NULL, s INTEGER GENERATED ALWAYS AS (x + y) STORED, v INTEGER AS (x * y) VIRTUAL); INSERT INTO gen_items (x, y) VALUES (3, 4), (10, -2);");
    setup.deinit();
    try db.schema(Item).validate();
    var raw = try db.exec("SELECT x, y, s, v FROM gen_items ORDER BY x;");
    defer raw.deinit();
    if (raw.count() != 2) return error.VerificationFailed;
    if (raw.at(0)[2].integer != 7) return error.VerificationFailed;
    if (raw.at(0)[3].integer != 12) return error.VerificationFailed;
    if (raw.at(1)[2].integer != 8) return error.VerificationFailed;
    if (raw.at(1)[3].integer != -20) return error.VerificationFailed;
    var dyn = try t_db_gen_items.select(.{ t_db_gen_items.column("x"), t_db_gen_items.column("s"), t_db_gen_items.column("v") }).orderBy(t_db_gen_items.column("x").asc()).fetch();
    defer dyn.deinit();
    if (dyn.count() != 2) return error.VerificationFailed;
    if (dyn.at(0)[1].integer != 7) return error.VerificationFailed;
    if (dyn.at(0)[2].integer != 12) return error.VerificationFailed;
    var typed = try db.from(Item).select(.{ Item.x, Item.s, Item.v }).orderBy(Item.x.asc()).fetch();
    defer typed.deinit();
    if (typed.count() != 2) return error.VerificationFailed;
    if (typed.at(0)[1].integer != 7) return error.VerificationFailed;
    if (typed.at(1)[2].integer != -20) return error.VerificationFailed;
    // Generated columns reject direct writes in every interface.
    if (db.exec("INSERT INTO gen_items (x, y, s) VALUES (1, 2, 3);")) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    if (db.from(Item).insert(.{ .x = 1, .y = 2, .s = 3, .v = 2 })) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    var intact = try db.exec("SELECT count(*) FROM gen_items;");
    defer intact.deinit();
    if (intact.at(0)[0].integer != 2) return error.VerificationFailed;
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_65.db");
    defer reopened.close();
    var persisted = try reopened.exec("SELECT s, v FROM gen_items ORDER BY x;");
    defer persisted.deinit();
    if (persisted.count() != 2) return error.VerificationFailed;
    if (persisted.at(0)[0].integer != 7) return error.VerificationFailed;
    if (persisted.at(1)[1].integer != -20) return error.VerificationFailed;
    std.debug.print("65 generated columns: raw dynamic typed verified with persistence\n", .{});
}
