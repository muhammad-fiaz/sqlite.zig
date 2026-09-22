//! INSERT OR IGNORE skips conflicting rows only.
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("ignore_items", struct { id: i64, label: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_38.db");
    defer db.close();
    try db.createTable(Item, .{ .overWrite = true, .primaryKey = Item.id });
    try db.truncate(Item);
    var original = try db.from(Item).insert(.{ .id = 1, .label = "original" });
    original.deinit();
    var result = try db.exec("INSERT OR IGNORE INTO ignore_items VALUES (1, 'duplicate'), (2, 'accepted');");
    defer result.deinit();
    if (result.changes != 1) return error.InsertOrIgnoreVerificationFailed;
    std.debug.print("38 INSERT OR IGNORE: conflicts skipped and accepted rows inserted\n", .{});
}
