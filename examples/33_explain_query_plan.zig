const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("planner_items", struct { id: i64, code: []const u8, value: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_33.db");
    defer db.close();
    try db.createTable(Item, .{ .overWrite = true, .primaryKey = Item.id });
    db.dropIndex("planner_items_code_idx") catch {};
    try db.createIndex(Item, "planner_items_code_idx", &.{Item.code}, false);
    try db.truncate(Item);
    var inserted = try db.from(Item).insert(.{ .id = 1, .code = "A", .value = 10 });
    inserted.deinit();
    inserted = try db.from(Item).insert(.{ .id = 2, .code = "B", .value = 20 });
    inserted.deinit();

    var plan = try db.exec("EXPLAIN QUERY PLAN SELECT id FROM planner_items WHERE code = 'B';");
    defer plan.deinit();
    if (plan.count() != 1 or std.mem.indexOf(u8, plan.at(0)[0].text, "USING INDEX planner_items_code_idx") == null) return error.IndexPlanVerificationFailed;
    var rows = try db.from(Item).select(&.{ Item.id, Item.value }).where(Item.code.eq("B")).fetch();
    defer rows.deinit();
    if (rows.count() != 1 or rows.at(0)[0].integer != 2) return error.IndexLookupVerificationFailed;
    std.debug.print("33 planner: EXPLAIN QUERY PLAN and indexed equality verified\n", .{});
}
