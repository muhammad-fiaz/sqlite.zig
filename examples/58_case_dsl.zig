const std = @import("std");
const sqlite = @import("sqlite");

const Member = sqlite.table("case_members", struct { id: i64, name: ?[]const u8, age: ?i64, score: ?i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_58.db");
    const t_db_case_members = db.table("case_members");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS case_members; CREATE TABLE case_members (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score INTEGER); INSERT INTO case_members VALUES (1, 'Alice', 30, 9), (2, 'Bob', 17, 4), (3, 'Carol', 12, NULL), (4, NULL, NULL, 7);");
    setup.deinit();
    try db.schema(Member).validate();

    var searched = try t_db_case_members.select(.{ t_db_case_members.column("id"), sqlite.caseWhen(t_db_case_members.column("age").gte(18), "adult").when(t_db_case_members.column("age").gte(13), "teen").else_("child") }).orderBy(t_db_case_members.column("id").asc()).fetch();
    defer searched.deinit();
    if (searched.count() != 4) return error.VerificationFailed;
    if (!std.mem.eql(u8, searched.at(0)[1].text, "adult")) return error.VerificationFailed;
    if (!std.mem.eql(u8, searched.at(1)[1].text, "teen")) return error.VerificationFailed;
    if (!std.mem.eql(u8, searched.at(2)[1].text, "child")) return error.VerificationFailed;
    if (!std.mem.eql(u8, searched.at(3)[1].text, "child")) return error.VerificationFailed;

    var rawSearched = try db.exec("SELECT id, CASE WHEN age >= 18 THEN 'adult' WHEN age >= 13 THEN 'teen' ELSE 'child' END FROM case_members ORDER BY id;");
    defer rawSearched.deinit();
    for (searched.rows, 0..) |row, i| {
        if (!std.mem.eql(u8, row[1].text, rawSearched.at(i)[1].text)) return error.VerificationFailed;
    }

    var simple = try db.from(Member).select(.{sqlite.caseValue(Member.age).whenValue(30, "thirty").whenValue(17, "seventeen").else_("other")}).orderBy(Member.id.asc()).fetch();
    defer simple.deinit();
    if (!std.mem.eql(u8, simple.at(0)[0].text, "thirty")) return error.VerificationFailed;
    if (!std.mem.eql(u8, simple.at(1)[0].text, "seventeen")) return error.VerificationFailed;
    if (!std.mem.eql(u8, simple.at(2)[0].text, "other")) return error.VerificationFailed;
    if (!std.mem.eql(u8, simple.at(3)[0].text, "other")) return error.VerificationFailed;

    var lowered = try db.from(Member).select(.{sqlite.caseValue(Member.name.lower()).whenValue("alice", "found").else_("missing")}).orderBy(Member.id.asc()).fetch();
    defer lowered.deinit();
    if (!std.mem.eql(u8, lowered.at(0)[0].text, "found")) return error.VerificationFailed;
    if (!std.mem.eql(u8, lowered.at(1)[0].text, "missing")) return error.VerificationFailed;

    var ranged = try db.from(Member).select(.{sqlite.caseWhen(Member.score.between(5, 10), "mid").else_("other")}).orderBy(Member.id.asc()).fetch();
    defer ranged.deinit();
    if (!std.mem.eql(u8, ranged.at(0)[0].text, "mid")) return error.VerificationFailed;
    if (!std.mem.eql(u8, ranged.at(1)[0].text, "other")) return error.VerificationFailed;
    if (!std.mem.eql(u8, ranged.at(2)[0].text, "other")) return error.VerificationFailed;
    if (!std.mem.eql(u8, ranged.at(3)[0].text, "mid")) return error.VerificationFailed;

    var retCase = try db.from(Member).returning(.{sqlite.caseWhen(Member.score.gte(5), "pass").else_("fail")}).insert(.{ .id = 5, .name = "Eve", .age = 40, .score = 6 });
    defer retCase.deinit();
    if (retCase.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, retCase.at(0)[0].text, "pass")) return error.VerificationFailed;

    var adults = try t_db_case_members.selectAll().whereCase(sqlite.caseWhen(t_db_case_members.column("age").gte(18), "adult").else_("child"), "adult").orderBy(t_db_case_members.column("id").asc()).fetch();
    defer adults.deinit();
    if (adults.count() != 2) return error.VerificationFailed;
    if (adults.at(0)[0].integer != 1) return error.VerificationFailed;
    if (adults.at(1)[0].integer != 5) return error.VerificationFailed;

    var rawAdults = try db.exec("SELECT id FROM case_members WHERE (CASE WHEN age >= 18 THEN 'adult' ELSE 'child' END) = 'adult' ORDER BY id;");
    defer rawAdults.deinit();
    if (rawAdults.count() != adults.count()) return error.VerificationFailed;

    if (t_db_case_members.select(.{sqlite.caseWhen(t_db_case_members.column("age").isNull(), "x").else_("y")}).fetch()) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |err| {
        if (err != error.InvalidSql) return error.VerificationFailed;
    }
    var intact = try db.exec("SELECT count(*) FROM case_members;");
    defer intact.deinit();
    if (intact.at(0)[0].integer != 5) return error.VerificationFailed;

    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_58.db");
    defer reopened.close();
    var persisted = try reopened.exec("SELECT CASE WHEN age >= 18 THEN 'adult' ELSE 'child' END FROM case_members ORDER BY id;");
    defer persisted.deinit();
    if (persisted.count() != 5) return error.VerificationFailed;
    if (!std.mem.eql(u8, persisted.at(0)[0].text, "adult")) return error.VerificationFailed;
    std.debug.print("58 case dsl: searched and simple case verified with persistence\n", .{});
}
