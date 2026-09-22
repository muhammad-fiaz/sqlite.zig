//! Virtual generate_series table read natively and via DSL.
const std = @import("std");
const sqlite = @import("sqlite");

const Series = sqlite.table("numbers_series", struct { value: i64 });

fn verify(db: *sqlite.Connection) !void {
    var rows = try db.from(Series).selectAll().fetch();
    defer rows.deinit();
    if (rows.count() != 5 or rows.at(0).value != 1 or rows.at(4).value != 5) return error.VirtualTableVerificationFailed;
}

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_34.db");
    var created = try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS numbers_series USING generate_series(1, 5, 1);");
    created.deinit();
    try verify(db);
    db.close();

    var reopened = try sqlite.open(std.heap.page_allocator, "example_34.db");
    defer reopened.close();
    try verify(reopened);
    std.debug.print("34 virtual tables: generate_series native DSL reads and reopen verified\n", .{});
}
