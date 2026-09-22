//! Expression operators verified across all three frontends.
const std = @import("std");
const sqlite = @import("sqlite");

const Feature = sqlite.table("features", struct {
    id: i64,
    name: ?[]const u8,
    age: ?i64,
    active: ?i64,
    body: ?[]const u8,
    price: ?f64,
    flags: ?i64,
});

fn expectCount(db: anytype, sql: []const u8, want: usize) !void {
    var r = try db.exec(sql);
    defer r.deinit();
    if (r.count() != want) return error.VerificationFailed;
}

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_53.db");
    const t_db_features = db.table("features");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS features; CREATE TABLE features (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, active INTEGER, body TEXT, price REAL, flags INTEGER); INSERT INTO features VALUES (1, 'Alice', 30, 1, 'sqlite rocks', 19.5, 6), (2, 'Al', 17, 0, 'hello world', 7.0, 3), (3, 'Bob', 25, 1, '100% sure', 10.0, 5), (4, NULL, NULL, NULL, NULL, NULL, NULL);");
    setup.deinit();

    var cnt = try db.exec("SELECT count(*) FROM features;");
    defer cnt.deinit();
    if (cnt.at(0)[0].integer != 4) return error.VerificationFailed;
    if (cnt.at(0)[0] != .integer) return error.VerificationFailed;

    try expectCount(db, "SELECT id FROM features WHERE age >= 18;", 2);
    try expectCount(db, "SELECT id FROM features WHERE age == 30;", 1);
    try expectCount(db, "SELECT id FROM features WHERE age != 30;", 2);
    try expectCount(db, "SELECT id FROM features WHERE name <> 'Bob';", 2);
    try expectCount(db, "SELECT id FROM features WHERE age < 18;", 1);
    try expectCount(db, "SELECT id FROM features WHERE age <= 17;", 1);
    try expectCount(db, "SELECT id FROM features WHERE age > 18;", 2);
    try expectCount(db, "SELECT id FROM features WHERE age >= 25;", 2);

    try expectCount(db, "SELECT id FROM features WHERE age > 18 AND active = 1;", 2);
    try expectCount(db, "SELECT id FROM features WHERE age < 18 OR name = 'Bob';", 2);
    try expectCount(db, "SELECT id FROM features WHERE NOT age >= 18;", 1);
    try expectCount(db, "SELECT id FROM features WHERE NOT (age >= 18);", 1);
    try expectCount(db, "SELECT (1 = 1 AND 2 = 2) FROM features LIMIT 1;", 1);
    {
        var r = try db.exec("SELECT NOT 1, NOT 0, 1 AND 0, 1 OR 0 FROM features LIMIT 1;");
        defer r.deinit();
        if (r.at(0)[0].integer != 0) return error.VerificationFailed;
        if (r.at(0)[1].integer != 1) return error.VerificationFailed;
        if (r.at(0)[2].integer != 0) return error.VerificationFailed;
        if (r.at(0)[3].integer != 1) return error.VerificationFailed;
    }

    try expectCount(db, "SELECT id FROM features WHERE name LIKE 'Al%';", 2);
    try expectCount(db, "SELECT id FROM features WHERE name NOT LIKE 'Al%';", 1);
    try expectCount(db, "SELECT id FROM features WHERE name LIKE 'A_';", 1);
    try expectCount(db, "SELECT id FROM features WHERE body LIKE '100\\%%' ESCAPE '\\';", 1);
    try expectCount(db, "SELECT id FROM features WHERE name GLOB 'Al*';", 2);
    try expectCount(db, "SELECT id FROM features WHERE name GLOB 'A?i*';", 1);
    try expectCount(db, "SELECT id FROM features WHERE name GLOB '[AB]ob';", 1);
    try expectCount(db, "SELECT id FROM features WHERE name GLOB '[^A]*';", 1);
    try expectCount(db, "SELECT id FROM features WHERE name NOT GLOB 'Al*';", 1);
    try expectCount(db, "SELECT id FROM features WHERE name REGEXP '^Al';", 2);
    try expectCount(db, "SELECT id FROM features WHERE name NOT REGEXP '^Al';", 1);
    try expectCount(db, "SELECT id FROM features WHERE name REGEXP '^A.*e$';", 1);
    try expectCount(db, "SELECT id FROM features WHERE body MATCH 'sqlite';", 1);
    try expectCount(db, "SELECT id FROM features WHERE body NOT MATCH 'sqlite';", 2);

    {
        var r = try db.exec("SELECT 'a' || 'b', 'n=' || 42, 1 || 2 FROM features LIMIT 1;");
        defer r.deinit();
        if (!std.mem.eql(u8, r.at(0)[0].text, "ab")) return error.VerificationFailed;
        if (!std.mem.eql(u8, r.at(0)[1].text, "n=42")) return error.VerificationFailed;
        if (!std.mem.eql(u8, r.at(0)[2].text, "12")) return error.VerificationFailed;
    }
    {
        var r = try db.exec("SELECT lower(name), upper(name), length(name), substr(name, 1, 3), replace(name, 'a', 'b'), trim('  x  '), ltrim('  x  '), rtrim('  x  '), instr(name, 'li'), hex('AB'), quote('abc'), unicode('A'), char(65), printf('%s-%d', 'a', 1) FROM features WHERE id = 1;");
        defer r.deinit();
        if (!std.mem.eql(u8, r.at(0)[0].text, "alice")) return error.VerificationFailed;
        if (!std.mem.eql(u8, r.at(0)[1].text, "ALICE")) return error.VerificationFailed;
        if (r.at(0)[2].integer != 5) return error.VerificationFailed;
        if (!std.mem.eql(u8, r.at(0)[3].text, "Ali")) return error.VerificationFailed;
        if (r.at(0)[8].integer != 2) return error.VerificationFailed;
        if (!std.mem.eql(u8, r.at(0)[9].text, "4142")) return error.VerificationFailed;
        if (!std.mem.eql(u8, r.at(0)[10].text, "'abc'")) return error.VerificationFailed;
        if (r.at(0)[11].integer != 65) return error.VerificationFailed;
        if (!std.mem.eql(u8, r.at(0)[12].text, "A")) return error.VerificationFailed;
        if (!std.mem.eql(u8, r.at(0)[13].text, "a-1")) return error.VerificationFailed;
    }

    try expectCount(db, "SELECT id FROM features WHERE id IN (1, 2, 3);", 3);
    try expectCount(db, "SELECT id FROM features WHERE id NOT IN (1, 2);", 2);
    try expectCount(db, "SELECT id FROM features WHERE age BETWEEN 18 AND 30;", 2);
    try expectCount(db, "SELECT id FROM features WHERE age NOT BETWEEN 18 AND 30;", 1);
    try expectCount(db, "SELECT id FROM features WHERE name IS NULL;", 1);
    try expectCount(db, "SELECT id FROM features WHERE name IS NOT NULL;", 3);
    try expectCount(db, "SELECT id FROM features WHERE name IS 'Alice';", 1);
    try expectCount(db, "SELECT id FROM features WHERE name IS NOT 'Alice';", 3);
    try expectCount(db, "SELECT id FROM features WHERE age IS DISTINCT FROM 30;", 3);
    try expectCount(db, "SELECT id FROM features WHERE age IS NOT DISTINCT FROM 30;", 1);

    {
        var r = try db.exec("SELECT CASE WHEN age > 18 THEN 'adult' ELSE 'minor' END FROM features WHERE id = 1;");
        defer r.deinit();
        if (!std.mem.eql(u8, r.at(0)[0].text, "adult")) return error.VerificationFailed;
    }
    {
        var r = try db.exec("SELECT CASE age WHEN 30 THEN 'thirty' ELSE 'other' END FROM features WHERE id = 1;");
        defer r.deinit();
        if (!std.mem.eql(u8, r.at(0)[0].text, "thirty")) return error.VerificationFailed;
    }
    {
        var r = try db.exec("SELECT CAST(age AS TEXT), CAST(price AS INTEGER), CAST('42' AS INTEGER) FROM features WHERE id = 1;");
        defer r.deinit();
        if (r.at(0)[2].integer != 42) return error.VerificationFailed;
    }
    try expectCount(db, "SELECT id FROM features WHERE name COLLATE NOCASE = 'alice';", 1);
    try expectCount(db, "SELECT id FROM features WHERE name = 'alice' COLLATE NOCASE;", 1);

    {
        var r = try db.exec("SELECT 2 + 3 * 4, 7 / 2, 7 % 3, 6 & 3, 6 | 3, 1 << 4, 256 >> 4, ~5, -5, +5 FROM features LIMIT 1;");
        defer r.deinit();
        if (r.at(0)[0].integer != 14) return error.VerificationFailed;
        if (r.at(0)[1].integer != 3) return error.VerificationFailed;
        if (r.at(0)[2].integer != 1) return error.VerificationFailed;
        if (r.at(0)[3].integer != 2) return error.VerificationFailed;
        if (r.at(0)[4].integer != 7) return error.VerificationFailed;
        if (r.at(0)[5].integer != 16) return error.VerificationFailed;
        if (r.at(0)[6].integer != 16) return error.VerificationFailed;
        if (r.at(0)[7].integer != -6) return error.VerificationFailed;
    }
    try expectCount(db, "SELECT id FROM features WHERE EXISTS (SELECT id FROM features WHERE features.id = 1);", 4);
    try expectCount(db, "SELECT id FROM features WHERE NOT EXISTS (SELECT id FROM features WHERE features.id = 99);", 4);

    var dynLike = try t_db_features.selectAll().where(t_db_features.column("name").like("Al%")).fetch();
    defer dynLike.deinit();
    if (dynLike.count() != 2) return error.VerificationFailed;
    var dynEscape = try t_db_features.selectAll().where(t_db_features.column("body").likeEscape("100%", "\\")).fetch();
    defer dynEscape.deinit();
    if (dynEscape.count() != 1) return error.VerificationFailed;
    var dynGlob = try t_db_features.selectAll().where(t_db_features.column("name").glob("Al*")).fetch();
    defer dynGlob.deinit();
    if (dynGlob.count() != 2) return error.VerificationFailed;
    var dynNotGlob = try t_db_features.selectAll().where(t_db_features.column("name").notGlob("Al*")).fetch();
    defer dynNotGlob.deinit();
    if (dynNotGlob.count() != 1) return error.VerificationFailed;
    var dynRegexp = try t_db_features.selectAll().where(t_db_features.column("name").regexp("^Al")).fetch();
    defer dynRegexp.deinit();
    if (dynRegexp.count() != 2) return error.VerificationFailed;
    var dynNotRegexp = try t_db_features.selectAll().where(t_db_features.column("name").notRegexp("^Al")).fetch();
    defer dynNotRegexp.deinit();
    if (dynNotRegexp.count() != 1) return error.VerificationFailed;
    var dynMatch = try t_db_features.selectAll().where(t_db_features.column("body").matchPattern("sqlite")).fetch();
    defer dynMatch.deinit();
    if (dynMatch.count() != 1) return error.VerificationFailed;
    var dynNotMatch = try t_db_features.selectAll().where(t_db_features.column("body").notMatch("sqlite")).fetch();
    defer dynNotMatch.deinit();
    if (dynNotMatch.count() != 2) return error.VerificationFailed;
    var dynBetween = try t_db_features.selectAll().where(t_db_features.column("age").between(18, 30)).fetch();
    defer dynBetween.deinit();
    if (dynBetween.count() != 2) return error.VerificationFailed;
    var dynNotBetween = try t_db_features.selectAll().where(t_db_features.column("age").notBetween(18, 30)).fetch();
    defer dynNotBetween.deinit();
    if (dynNotBetween.count() != 1) return error.VerificationFailed;
    var dynNull = try t_db_features.selectAll().where(t_db_features.column("name").isNull()).fetch();
    defer dynNull.deinit();
    if (dynNull.count() != 1) return error.VerificationFailed;
    var dynNotNull = try t_db_features.selectAll().where(t_db_features.column("name").isNotNull()).fetch();
    defer dynNotNull.deinit();
    if (dynNotNull.count() != 3) return error.VerificationFailed;
    var dynIs = try t_db_features.selectAll().where(t_db_features.column("name").is("Alice")).fetch();
    defer dynIs.deinit();
    if (dynIs.count() != 1) return error.VerificationFailed;
    var dynDistinct = try t_db_features.selectAll().where(t_db_features.column("age").isDistinctFrom(30)).fetch();
    defer dynDistinct.deinit();
    if (dynDistinct.count() != 3) return error.VerificationFailed;
    var dynCollate = try t_db_features.selectAll().where(t_db_features.column("name").collate("NOCASE", "alice")).fetch();
    defer dynCollate.deinit();
    if (dynCollate.count() != 1) return error.VerificationFailed;
    var dynAnd = try t_db_features.selectAll().where(t_db_features.column("age").gte(18)).andWhere(t_db_features.column("active").eq(1)).fetch();
    defer dynAnd.deinit();
    if (dynAnd.count() != 2) return error.VerificationFailed;
    var dynOr = try t_db_features.selectAll().where(t_db_features.column("age").lt(18)).orWhere(t_db_features.column("name").eq("Bob")).fetch();
    defer dynOr.deinit();
    if (dynOr.count() != 2) return error.VerificationFailed;
    var dynNot = try t_db_features.selectAll().where(t_db_features.column("age").gte(18).notOp()).fetch();
    defer dynNot.deinit();
    if (dynNot.count() != 1) return error.VerificationFailed;
    var dynLower = try t_db_features.select(.{t_db_features.column("name").lower().projection()}).fetch();
    defer dynLower.deinit();
    if (dynLower.count() != 4) return error.VerificationFailed;
    var dynSubstr = try t_db_features.select(.{t_db_features.column("name").substr(1, 3).projection()}).fetch();
    defer dynSubstr.deinit();
    if (dynSubstr.count() != 4) return error.VerificationFailed;

    try db.schema(Feature).validate();
    var typedLike = try db.from(Feature).where(Feature.name.like("Al%")).fetch();
    defer typedLike.deinit();
    if (typedLike.count() != 2) return error.VerificationFailed;
    var typedRegexp = try db.from(Feature).where(Feature.name.regexp("^Al")).fetch();
    defer typedRegexp.deinit();
    if (typedRegexp.count() != 2) return error.VerificationFailed;
    var typedMatch = try db.from(Feature).where(Feature.body.matchPattern("sqlite")).fetch();
    defer typedMatch.deinit();
    if (typedMatch.count() != 1) return error.VerificationFailed;
    var typedBetween = try db.from(Feature).where(Feature.age.between(18, 30)).fetch();
    defer typedBetween.deinit();
    if (typedBetween.count() != 2) return error.VerificationFailed;
    var typedCollate = try db.from(Feature).where(Feature.name.collate("NOCASE", "alice")).fetch();
    defer typedCollate.deinit();
    if (typedCollate.count() != 1) return error.VerificationFailed;

    var rawInsert = try db.exec("INSERT INTO features VALUES (5, 'Alana', 22, 1, 'sqlite fast', 5.5, 1);");
    rawInsert.deinit();
    var dynSeeRaw = try t_db_features.selectAll().where(t_db_features.column("name").eq("Alana")).fetch();
    defer dynSeeRaw.deinit();
    if (dynSeeRaw.count() != 1) return error.VerificationFailed;
    var typedSeeRaw = try db.from(Feature).where(Feature.name.eq("Alana")).fetch();
    defer typedSeeRaw.deinit();
    if (typedSeeRaw.count() != 1) return error.VerificationFailed;

    var dynInsert = try t_db_features.insert(.{ .id = 6, .name = "Zed", .age = 40, .active = 1, .body = "nothing", .price = 1.0, .flags = 0 });
    dynInsert.deinit();
    var rawSeeDyn = try db.exec("SELECT name FROM features WHERE id = 6;");
    defer rawSeeDyn.deinit();
    if (rawSeeDyn.count() != 1 or !std.mem.eql(u8, rawSeeDyn.at(0)[0].text, "Zed")) return error.VerificationFailed;

    var typedInsert = try db.from(Feature).insert(.{ .id = 7, .name = "Yara", .age = 19, .active = 0, .body = "sqlite yara", .price = 2.0, .flags = 2 });
    typedInsert.deinit();
    var rawSeeTyped = try db.exec("SELECT age FROM features WHERE name = 'Yara';");
    defer rawSeeTyped.deinit();
    if (rawSeeTyped.count() != 1 or rawSeeTyped.at(0)[0].integer != 19) return error.VerificationFailed;

    var after = try db.exec("SELECT count(*) FROM features;");
    defer after.deinit();
    if (after.at(0)[0].integer != 7) return error.VerificationFailed;

    {
        var check = try db.exec("SELECT count(*) FROM features WHERE name LIKE 'Al%';");
        defer check.deinit();
        if (check.at(0)[0].integer != 3) return error.VerificationFailed;
    }
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_53.db");
    defer reopened.close();
    var persisted = try reopened.exec("SELECT count(*) FROM features WHERE name LIKE 'Al%';");
    defer persisted.deinit();
    if (persisted.at(0)[0].integer != 3) return error.VerificationFailed;
    var persistedRegexp = try reopened.exec("SELECT count(*) FROM features WHERE name REGEXP '^Al';");
    defer persistedRegexp.deinit();
    if (persistedRegexp.at(0)[0].integer != 3) return error.VerificationFailed;
    var persistedMatch = try reopened.exec("SELECT count(*) FROM features WHERE body MATCH 'sqlite';");
    defer persistedMatch.deinit();
    if (persistedMatch.at(0)[0].integer != 3) return error.VerificationFailed;
    std.debug.print("53 expression operators: raw/dynamic/typed verified with persistence\n", .{});
}
