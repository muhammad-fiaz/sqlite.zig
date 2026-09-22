//! Literal IN lists for membership checks in raw and typed SQL.
const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("literal_in_items", struct { id: i64, label: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_45.db");
    defer db.close();
    try db.createTable(Item, .{ .overWrite = true });
    try db.truncate(Item);
    var result = try db.exec("INSERT INTO literal_in_items VALUES (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four');");
    result.deinit();
    var raw = try db.exec("SELECT id FROM literal_in_items WHERE id IN (1, 3, 4) ORDER BY id;");
    defer raw.deinit();
    if (raw.count() != 3) return error.RawInListVerificationFailed;
    var typed = try db.from(Item).whereNotInValues(Item.id, .{ 1, 3, 4 }).fetch();
    defer typed.deinit();
    if (typed.count() != 1 or typed.at(0).id != 2) return error.TypedInListVerificationFailed;
    std.debug.print("45 literal IN lists: raw and typed membership verified\n", .{});
}
