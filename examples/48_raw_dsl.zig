const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_48.db");
    defer db.close();

    var setup = try db.exec("DROP TABLE IF EXISTS raw_dsl_items; CREATE TABLE raw_dsl_items (id INTEGER, name TEXT); INSERT INTO raw_dsl_items VALUES (1, 'Alice'), (2, 'Bob');");
    setup.deinit();

    var rows = try db.from("raw_dsl_items")
        .where(db.col("id").gte(2))
        .select("id, name")
        .fetchAll();
    defer rows.deinit();
    std.debug.print("Raw DSL rows: {d}\n", .{rows.rowCount()});
}




