const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("coverage_users", struct {
    id: i64,
    name: []const u8,
    age: i64,
});

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_49.db");
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
    if (raw.rowCount() != 2) return error.UnexpectedResult;

    var raw_dsl = try db.from("coverage_users")
        .where(db.col("age").gte(18))
        .andWhere(db.col("name").glob("A*"))
        .select("id, name")
        .fetchAll();
    defer raw_dsl.deinit();
    if (raw_dsl.rowCount() != 1) return error.UnexpectedResult;

    var text = try db.from("coverage_users")
        .where(db.col("name").startsWith("Al"))
        .andWhere(db.col("name").endsWith("ce"))
        .fetchAll();
    defer text.deinit();
    if (text.rowCount() != 1) return error.UnexpectedResult;

    var ranged = try db.from("coverage_users")
        .where(db.col("age").between(18, 40))
        .fetchAll();
    defer ranged.deinit();
    if (ranged.rowCount() != 1) return error.UnexpectedResult;

    var typed = try db.from(User)
        .where(User.columns("age").ge(18))
        .orderBy(User.columns("id").asc())
        .fetchTyped();
    defer typed.deinit();
    if (typed.rowCount() != 2) return error.UnexpectedResult;

    std.debug.print("raw={d} raw_dsl={d} typed={d}\n", .{ raw.rowCount(), raw_dsl.rowCount(), typed.rowCount() });
}
