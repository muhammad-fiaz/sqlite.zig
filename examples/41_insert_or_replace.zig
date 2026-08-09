const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("replace_items", struct { id: i64, label: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_41.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true, .primary_key = Item.key("id") });
    try db.truncate(Item);
    var original = try db.from(Item).insert(.{ .id = 1, .label = "original" });
    original.deinit();
    var result = try db.exec("INSERT OR REPLACE INTO replace_items VALUES (1, 'replacement');");
    defer result.deinit();
    var rows = try db.from(Item).selectAll().fetchAll();
    defer rows.deinit();
    if (rows.rowCount() != 1 or !std.mem.eql(u8, rows.rows[0][1].text, "replacement")) return error.InsertOrReplaceVerificationFailed;
    std.debug.print("41 INSERT OR REPLACE: conflicting row replaced and verified\n", .{});
}
