const std = @import("std");
const sqlite = @import("sqlite");

const Live = sqlite.table("live", struct { id: i64, name: []const u8, active: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_51.db");
    const t_db_live = db.table("live");
    const t_db_second = db.table("second");
    const t_db_nums = db.table("nums");
    defer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS cte_employees; CREATE TABLE cte_employees (id INTEGER, name TEXT, active INTEGER); INSERT INTO cte_employees VALUES (1, 'Ada', 1), (2, 'Bob', 0), (3, 'Cy', 1);");
    setup.deinit();

    var raw = try db.exec("WITH live AS (SELECT id, name FROM cte_employees WHERE active = 1) SELECT id, name FROM live ORDER BY id;");
    defer raw.deinit();
    if (raw.count() != 2) return error.RawCteVerificationFailed;

    var dynamic = try t_db_live.with("live", "SELECT id, name FROM cte_employees WHERE active = 1").orderBy(t_db_live.column("id").asc()).fetch();
    defer dynamic.deinit();
    if (dynamic.count() != 2 or dynamic.at(1)[0].integer != 3) return error.DynamicCteVerificationFailed;

    var typed = try db.from(Live).with("live", "SELECT id, name, active FROM cte_employees WHERE active = 1").orderBy(Live.id.asc()).fetch();
    defer typed.deinit();
    if (typed.count() != 2 or !std.mem.eql(u8, typed.at(0).name, "Ada")) return error.TypedCteVerificationFailed;

    var chained = try t_db_second.with("first", "SELECT id FROM cte_employees WHERE id >= 2").with("second", "SELECT id FROM first").fetch();
    defer chained.deinit();
    if (chained.count() != 2) return error.ChainedCteVerificationFailed;

    var counted = try t_db_nums.withRecursive("nums", "SELECT 1 AS n", "SELECT n + 1 AS n FROM nums WHERE n < 5").fetch();
    defer counted.deinit();
    if (counted.count() != 5) return error.RecursiveCteVerificationFailed;
    std.debug.print("51 DSL CTEs: raw, dynamic, typed, chained, and recursive verified\n", .{});
}
