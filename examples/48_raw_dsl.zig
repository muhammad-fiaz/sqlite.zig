//! Dynamic DSL: runtime table and column handles with select and where.
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_48.db");
    defer db.close();

    var setup = try db.exec(
        "DROP TABLE IF EXISTS raw_dsl_items;" ++
            "CREATE TABLE raw_dsl_items (id INTEGER, name TEXT);" ++
            "INSERT INTO raw_dsl_items VALUES (1, 'Alice'), (2, 'Bob');",
    );
    setup.deinit();

    const items = db.table("raw_dsl_items");

    const id = items.column("id");
    const name = items.column("name");

    var rows = try items
        .select(.{ id, name })
        .where(id.gte(2))
        .fetch();

    defer rows.deinit();

    std.debug.print("Dynamic DSL rows: {d}\n", .{rows.count()});

    var it = rows.iter();
    while (it.next()) |row| {
        const rowId = try row.get("id");
        const rowName = try row.get("name");

        std.debug.print("{any}: {any}\n", .{ rowId, rowName });
    }
}
