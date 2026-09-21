const std = @import("std");
const sqlite = @import("sqlite");

const Source = sqlite.table("copy_source", struct { id: i64, label: []const u8 });
const Destination = sqlite.table("copy_destination", struct { id: i64, label: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_37.db");
    defer db.close();
    try db.createTable(Source, .{ .overWrite = true });
    try db.createTable(Destination, .{ .overWrite = true });
    try db.truncate(Source);
    try db.truncate(Destination);
    var first = try db.from(Source).insert(.{ .id = 1, .label = "skip" });
    first.deinit();
    var second = try db.from(Source).insert(.{ .id = 2, .label = "copy" });
    second.deinit();
    var copied = try db.exec("INSERT INTO copy_destination SELECT id, label FROM copy_source WHERE id > 1;");
    copied.deinit();
    var rows = try db.from(Destination).selectAll().fetch();
    defer rows.deinit();
    if (rows.count() != 1 or rows.at(0).id != 2) return error.InsertSelectVerificationFailed;
    std.debug.print("37 INSERT SELECT: filtered query results copied and verified\n", .{});
}
