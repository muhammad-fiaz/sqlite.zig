const std = @import("std");
const sqlite = @import("sqlite");

const EventRow = struct { id: i64, label: []const u8, rank: i64 };
const Event = sqlite.table("paged_events", EventRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_16.db");
    defer db.close();
    try db.createTable(Event, .{ .if_not_exists = true });
    try db.truncate(Event);
    const seed = [_]EventRow{
        .{ .id = 1, .label = "alpha", .rank = 10 },
        .{ .id = 2, .label = "beta", .rank = 20 },
        .{ .id = 3, .label = "gamma", .rank = 30 },
    };
    for (seed) |item| {
        var inserted = try db.from(Event).insertTyped(item);
        inserted.deinit();
    }

    var page = try db.from(Event)
        .selectColumns(&.{ Event.key("id"), Event.key("label"), Event.key("rank") })
        .where(Event.column("rank").between(10, 30))
        .andWhere(Event.column("label").like("%a%"))
        .orderBy(Event.column("rank").asc())
        .limit(2)
        .offset(1)
        .fetchAll();
    defer page.deinit();
    std.debug.print("16 typed DSL pagination: rows={d} first_id={d}\n", .{ page.rowCount(), if (page.rowCount() == 0) -1 else page.rows[0][0].integer });
    if (page.rowCount() != 2 or page.rows[0][0].integer != 2) return error.PaginationVerificationFailed;
    std.debug.print("16 typed DSL pagination: {d} verified row\n", .{page.rowCount()});
}
