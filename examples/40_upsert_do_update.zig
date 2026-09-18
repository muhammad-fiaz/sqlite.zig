const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("upsert_update_items", struct { id: i64, label: []const u8, amount: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_40.db");
    defer db.close();
    try db.createTable(Item, .{ .ifNotExists = true, .primaryKey = Item.columns.id });
    try db.truncate(Item);
    var original = try db.from(Item).insert(.{ .id = 1, .label = "original", .amount = 10 });
    original.deinit();
    var result = try db.exec("INSERT INTO upsert_update_items VALUES (1, 'updated', 99) ON CONFLICT(id) DO UPDATE SET label = excluded.label, amount = excluded.amount + 1;");
    defer result.deinit();
    var rows = try db.from(Item).selectAll().fetch();
    defer rows.deinit();
    if (rows.rowCount() != 1 or !std.mem.eql(u8, rows.rows[0].label, "updated") or rows.rows[0].amount != 100) return error.UpsertUpdateVerificationFailed;
    std.debug.print("40 UPSERT DO UPDATE: conflicting row updated and verified\n", .{});
}
