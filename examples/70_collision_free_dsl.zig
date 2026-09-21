const std = @import("std");
const sqlite = @import("sqlite");

// Schema fields may use DSL-looking names: every one of these is a plain
// typed column. The all-columns operation is `selectAll()` here because the
// real `all` column owns the `all` member (Zig forbids a field and a
// function sharing one name, so `Weird.all()` cannot exist on this table;
// tables without an `all` column spell it `User.all()`).
const WeirdRow = struct {
    id: i64,
    all: []const u8,
    count: i64,
    len: i64,
    select: []const u8,
    where: []const u8,
    join: []const u8,
    limit: i64,
};
const Weird = sqlite.table("cf_items", WeirdRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_70.db");
    const t_db_cf_items = db.table("cf_items");
    errdefer db.close();
    try db.createTable(Weird, .{ .overWrite = true, .primaryKey = Weird.id });
    try db.schema(Weird).validate();
    var first = try db.from(Weird).insert(.{ .id = 1, .all = "a", .count = 7, .len = 3, .select = "s", .where = "w", .join = "j", .limit = 50 });
    first.deinit();
    var second = try db.from(Weird).insert(.{ .id = 2, .all = "b", .count = 3, .len = 4, .select = "t", .where = "x", .join = "k", .limit = 10 });
    second.deinit();
    // Raw SQL reads the DSL-named columns directly (reserved words quoted,
    // exactly as SQLite requires).
    var raw = try db.exec("SELECT \"all\", \"count\" FROM cf_items WHERE \"where\" = 'w' ORDER BY \"limit\";");
    defer raw.deinit();
    if (raw.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, raw.rows[0][0].text, "a")) return error.VerificationFailed;
    if (raw.rows[0][1].integer != 7) return error.VerificationFailed;
    // Dynamic DSL: same names, same behavior.
    var dyn = try t_db_cf_items.select(.{t_db_cf_items.column("all")}).where(t_db_cf_items.column("where").eq("w")).fetch();
    defer dyn.deinit();
    if (dyn.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, dyn.at(0)[0].text, "a")) return error.VerificationFailed;
    // Typed DSL: Weird.all / Weird.count / ... are columns with full
    // expression methods; selectAll() is the all-columns operation.
    var typed = try db.from(Weird).select(Weird.all).where(Weird.where.eq("w")).fetch();
    defer typed.deinit();
    if (typed.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, typed.rows[0][0].text, "a")) return error.VerificationFailed;
    var ordered = try db.from(Weird).select(Weird.all).orderBy(Weird.limit.asc()).fetch();
    defer ordered.deinit();
    if (ordered.count() != 2) return error.VerificationFailed;
    if (!std.mem.eql(u8, ordered.rows[0][0].text, "b")) return error.VerificationFailed;
    var summed = try db.from(Weird).select(.{Weird.count.sum()}).fetch();
    defer summed.deinit();
    if (summed.rows[0][0].integer != 10) return error.VerificationFailed;
    var everything = try db.from(Weird).selectAll().orderBy(Weird.id.asc()).fetch();
    defer everything.deinit();
    if (everything.count() != 2) return error.VerificationFailed;
    if (!std.mem.eql(u8, everything.at(0).all, "a")) return error.VerificationFailed;
    if (everything.at(1).limit != 10) return error.VerificationFailed;
    var updated = try (try db.from(Weird).update(.{ .limit = 99 })).where(Weird.join.eq("k")).execute();
    updated.deinit();
    const check = try db.from(Weird).select(Weird.limit).where(Weird.id.eq(2)).fetchOne();
    if (check.integer != 99) return error.VerificationFailed;
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_70.db");
    defer reopened.close();
    try reopened.schema(Weird).validate();
    var persisted = try reopened.exec("SELECT count(*) FROM cf_items;");
    defer persisted.deinit();
    if (persisted.at(0)[0].integer != 2) return error.VerificationFailed;
    std.debug.print("70 collision-free dsl: DSL-named columns verified with persistence\n", .{});
}
