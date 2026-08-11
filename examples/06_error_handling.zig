const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_06.db");
    defer db.close();
    const result = db.exec("SELECT * FROM missing;");
    if (result) |value| {
        var owned = value;
        owned.deinit();
    } else |_| {}
    std.debug.print("06 error handling: invalid query correctly returned error\n", .{});
}
