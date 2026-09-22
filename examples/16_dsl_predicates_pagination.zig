//! Typed DSL predicate builders with offset and limit pagination.
const std = @import("std");
const sqlite = @import("sqlite");

const EventRow = struct { id: i64, label: []const u8, rank: i64 };
const Event = sqlite.table("paged_events", EventRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_16.db");
    defer db.close();
    try db.createTable(Event, .{ .overWrite = true });
    try db.truncate(Event);
    const seed = [_]EventRow{
        .{ .id = 1, .label = "alpha", .rank = 10 },
        .{ .id = 2, .label = "beta", .rank = 20 },
        .{ .id = 3, .label = "gamma", .rank = 30 },
    };
    for (seed) |item| {
        var inserted = try db.from(Event).insert(item);
        inserted.deinit();
    }

    var page = try db.from(Event)
        .select(&.{ Event.id, Event.label, Event.rank })
        .where(Event.rank.between(10, 30))
        .andWhere(Event.label.like("%a%"))
        .orderBy(Event.rank.asc())
        .limit(2)
        .offset(1)
        .fetch();
    defer page.deinit();
    std.debug.print("16 typed DSL pagination: rows={d} first_id={d}\n", .{ page.count(), if (page.count() == 0) -1 else page.at(0)[0].integer });
    if (page.count() != 2 or page.at(0)[0].integer != 2) return error.PaginationVerificationFailed;
    std.debug.print("16 typed DSL pagination: {d} verified row\n", .{page.count()});
}
