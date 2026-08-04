const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_29.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS cte_source (id INTEGER, label TEXT);");
    setup.deinit();
    var cleared = try db.exec("DELETE FROM cte_source;");
    cleared.deinit();
    var inserted = try db.exec("INSERT INTO cte_source VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');");
    inserted.deinit();

    var result = try db.exec("WITH first_set AS (SELECT id, label FROM cte_source WHERE id >= 2), second_set AS (SELECT id, label FROM first_set) SELECT id, label FROM second_set ORDER BY id;");
    defer result.deinit();
    if (result.rowCount() != 2 or result.rows[0][0].integer != 2 or !std.mem.eql(u8, result.rows[0][1].text, "beta") or result.rows[1][0].integer != 3) return error.MultipleCteVerificationFailed;
    std.debug.print("29 CTEs: multiple dependent non-recursive CTEs verified\n", .{});
}
