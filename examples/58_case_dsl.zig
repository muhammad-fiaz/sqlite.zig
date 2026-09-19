const std = @import("std");
const sqlite = @import("sqlite");

const Member = sqlite.table("case_members", struct { id: i64, name: ?[]const u8, age: ?i64, score: ?i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_58.db");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS case_members; CREATE TABLE case_members (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score INTEGER); INSERT INTO case_members VALUES (1, 'Alice', 30, 9), (2, 'Bob', 17, 4), (3, 'Carol', 12, NULL), (4, NULL, NULL, 7);");
    setup.deinit();
    try db.schema(Member).validate();

    var searched = try db.from("case_members").select(.{ db.col("id"), sqlite.caseWhen(db.col("age").gte(18), "adult").when(db.col("age").gte(13), "teen").else_("child") }).orderBy(db.col("id").asc()).fetch();
    defer searched.deinit();
    if (searched.count() != 4) return error.VerificationFailed;
    if (!std.mem.eql(u8, searched.rows[0][1].text, "adult")) return error.VerificationFailed;
    if (!std.mem.eql(u8, searched.rows[1][1].text, "teen")) return error.VerificationFailed;
    if (!std.mem.eql(u8, searched.rows[2][1].text, "child")) return error.VerificationFailed;
    if (!std.mem.eql(u8, searched.rows[3][1].text, "child")) return error.VerificationFailed;

    var rawSearched = try db.exec("SELECT id, CASE WHEN age >= 18 THEN 'adult' WHEN age >= 13 THEN 'teen' ELSE 'child' END FROM case_members ORDER BY id;");
    defer rawSearched.deinit();
    for (searched.rows, 0..) |row, i| {
        if (!std.mem.eql(u8, row[1].text, rawSearched.rows[i][1].text)) return error.VerificationFailed;
    }

    var simple = try db.from(Member).select(.{sqlite.caseValue(Member.columns.age).whenValue(30, "thirty").whenValue(17, "seventeen").else_("other")}).orderBy(Member.columns.id.asc()).fetch();
    defer simple.deinit();
    if (!std.mem.eql(u8, simple.rows[0][0].text, "thirty")) return error.VerificationFailed;
    if (!std.mem.eql(u8, simple.rows[1][0].text, "seventeen")) return error.VerificationFailed;
    if (!std.mem.eql(u8, simple.rows[2][0].text, "other")) return error.VerificationFailed;
    if (!std.mem.eql(u8, simple.rows[3][0].text, "other")) return error.VerificationFailed;

    var lowered = try db.from(Member).select(.{sqlite.caseValue(Member.columns.name.lower()).whenValue("alice", "found").else_("missing")}).orderBy(Member.columns.id.asc()).fetch();
    defer lowered.deinit();
    if (!std.mem.eql(u8, lowered.rows[0][0].text, "found")) return error.VerificationFailed;
    if (!std.mem.eql(u8, lowered.rows[1][0].text, "missing")) return error.VerificationFailed;

    var ranged = try db.from(Member).select(.{sqlite.caseWhen(Member.columns.score.between(5, 10), "mid").else_("other")}).orderBy(Member.columns.id.asc()).fetch();
    defer ranged.deinit();
    if (!std.mem.eql(u8, ranged.rows[0][0].text, "mid")) return error.VerificationFailed;
    if (!std.mem.eql(u8, ranged.rows[1][0].text, "other")) return error.VerificationFailed;
    if (!std.mem.eql(u8, ranged.rows[2][0].text, "other")) return error.VerificationFailed;
    if (!std.mem.eql(u8, ranged.rows[3][0].text, "mid")) return error.VerificationFailed;

    var retCase = try db.from(Member).returning(.{sqlite.caseWhen(Member.columns.score.gte(5), "pass").else_("fail")}).insert(.{ .id = 5, .name = "Eve", .age = 40, .score = 6 });
    defer retCase.deinit();
    if (retCase.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, retCase.rows[0][0].text, "pass")) return error.VerificationFailed;

    var adults = try db.from("case_members").whereCase(sqlite.caseWhen(db.col("age").gte(18), "adult").else_("child"), "adult").orderBy(db.col("id").asc()).fetch();
    defer adults.deinit();
    if (adults.count() != 2) return error.VerificationFailed;
    if (adults.rows[0][0].integer != 1) return error.VerificationFailed;
    if (adults.rows[1][0].integer != 5) return error.VerificationFailed;

    var rawAdults = try db.exec("SELECT id FROM case_members WHERE (CASE WHEN age >= 18 THEN 'adult' ELSE 'child' END) = 'adult' ORDER BY id;");
    defer rawAdults.deinit();
    if (rawAdults.count() != adults.count()) return error.VerificationFailed;

    if (db.from("case_members").select(.{sqlite.caseWhen(db.col("age").isNull(), "x").else_("y")}).fetch()) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |err| {
        if (err != error.InvalidSql) return error.VerificationFailed;
    }
    var intact = try db.exec("SELECT count(*) FROM case_members;");
    defer intact.deinit();
    if (intact.rows[0][0].integer != 5) return error.VerificationFailed;

    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_58.db");
    defer reopened.close();
    var persisted = try reopened.exec("SELECT CASE WHEN age >= 18 THEN 'adult' ELSE 'child' END FROM case_members ORDER BY id;");
    defer persisted.deinit();
    if (persisted.count() != 5) return error.VerificationFailed;
    if (!std.mem.eql(u8, persisted.rows[0][0].text, "adult")) return error.VerificationFailed;
    std.debug.print("58 case dsl: searched and simple case verified with persistence\n", .{});
}
