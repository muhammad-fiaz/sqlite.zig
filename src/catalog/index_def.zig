const std = @import("std");

pub const IndexDef = struct {
    name: []const u8,
    table: []const u8,
    columns: []const []const u8,
    unique: bool = false,
};

pub fn covers(index: IndexDef, column: []const u8) bool {
    for (index.columns) |item| if (std.ascii.eqlIgnoreCase(item, column)) return true;
    return false;
}

test "index definition reports covered columns" {
    const columns = [_][]const u8{"email"};
    try std.testing.expect(covers(.{ .name = "users_email", .table = "users", .columns = &columns }, "EMAIL"));
}
