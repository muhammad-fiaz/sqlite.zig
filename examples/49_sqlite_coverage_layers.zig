//! Layered coverage: raw SQL, dynamic DSL, and typed DSL.
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("coverage_users", struct {
    id: i64,
    name: []const u8,
    age: i64,
});

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_49.db");
    const t_db_coverage_users = db.table("coverage_users");
    defer db.close();

    var setup = try db.exec(
        "DROP TABLE IF EXISTS coverage_users; " ++
            "CREATE TABLE coverage_users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER); " ++
            "INSERT INTO coverage_users VALUES (1, 'Alice', 30), (2, 'Bob', 17), (3, 'Carol', 42);",
    );
    setup.deinit();

    var raw = try db.exec(
        "SELECT name, age FROM coverage_users WHERE age >= 18 ORDER BY age DESC LIMIT 2;",
    );
    defer raw.deinit();
    if (raw.count() != 2) return error.UnexpectedResult;

    var rawDsl = try t_db_coverage_users
        .select(.{ t_db_coverage_users.column("id"), t_db_coverage_users.column("name") })
        .where(t_db_coverage_users.column("age").gte(18))
        .andWhere(t_db_coverage_users.column("name").glob("A*"))
        .fetch();
    defer rawDsl.deinit();
    if (rawDsl.count() != 1) return error.UnexpectedResult;

    var text = try t_db_coverage_users
        .selectAll()
        .where(t_db_coverage_users.column("name").like("Al%"))
        .andWhere(t_db_coverage_users.column("name").like("%ce"))
        .fetch();
    defer text.deinit();
    if (text.count() != 1) return error.UnexpectedResult;

    var ranged = try t_db_coverage_users
        .selectAll()
        .where(t_db_coverage_users.column("age").between(18, 40))
        .fetch();
    defer ranged.deinit();
    if (ranged.count() != 1) return error.UnexpectedResult;

    var typed = try db.from(User)
        .where(User.age.gte(18))
        .orderBy(User.id.asc())
        .fetch();
    defer typed.deinit();
    if (typed.count() != 2) return error.UnexpectedResult;

    std.debug.print("raw={d} raw_dsl={d} typed={d}\n", .{ raw.count(), rawDsl.count(), typed.count() });
}
