const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("mapped_users", .{
    .firstName = sqlite.column("first_name", []const u8),
    .ageYears = sqlite.column("age_years", i64),
});

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_52.db");
    const t_db_mapped_users = db.table("mapped_users");
    defer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS mapped_users; CREATE TABLE mapped_users (first_name TEXT NOT NULL, age_years INTEGER NOT NULL); INSERT INTO mapped_users VALUES ('Grace', 85);");
    setup.deinit();

    var dynamic = try t_db_mapped_users.selectAll().where(t_db_mapped_users.column("first_name").eq("Grace")).fetch();
    defer dynamic.deinit();
    if (dynamic.count() != 1) return error.DynamicMappingVerificationFailed;

    try db.schema(User).validate();

    var typed = try db.from(User).where(User.ageYears.gte(18)).fetch();
    defer typed.deinit();
    if (typed.count() != 1 or !std.mem.eql(u8, typed.at(0).firstName, "Grace")) return error.TypedMappingVerificationFailed;

    var inserted = try db.from(User).insert(.{ .firstName = "Ada", .ageYears = 36 });
    inserted.deinit();

    var raw = try db.exec("SELECT first_name, age_years FROM mapped_users ORDER BY age_years;");
    defer raw.deinit();
    if (raw.count() != 2 or !std.mem.eql(u8, raw.at(0)[0].text, "Ada")) return error.RawMappingVerificationFailed;
    std.debug.print("52 column mapping: zig names map onto sql names in every mode\n", .{});
}
