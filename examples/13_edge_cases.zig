const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("edge_items", struct { id: i64, label: ?[]const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_13.db");
    defer db.close();
    try db.createTable(Item, .{ .if_not_exists = true, .primary_key = Item.key("id"), .unique_keys = &.{Item.key("label")} });
    try db.truncate(Item);
    var first = try db.from(Item).insert(.{ .id = 1, .label = "alpha" });
    first.deinit();
    var nulls = try db.exec("INSERT INTO edge_items (id, label) VALUES (2, NULL), (3, NULL);");
    nulls.deinit();
    var dsl_null = try db.from(Item).insert(.{ .id = 6, .label = @as(?[]const u8, null) });
    dsl_null.deinit();
    try db.begin();
    var rolled = try db.from(Item).insert(.{ .id = 4, .label = "rolled-back" });
    rolled.deinit();
    try db.rollback();
    try db.begin();
    try db.savepoint("edge_point");
    var temporary = try db.from(Item).insert(.{ .id = 5, .label = "temporary" });
    temporary.deinit();
    try db.rollbackToSavepoint("edge_point");
    try db.releaseSavepoint("edge_point");
    try db.commit();
    var result = try db.from(Item).where(Item.column("label").isNull()).fetchAll();
    result.deinit();
    const invalid = db.exec("SELECT FROM edge_items;") catch null;
    if (invalid) |value| {
        var owned = value;
        owned.deinit();
        return error.InvalidQueryWasAccepted;
    }
}
