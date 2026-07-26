const std = @import("std");

pub const Migration = struct {
    version: u32,
    up_sql: []const u8,
    down_sql: []const u8 = "",
};

pub const Set = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Migration),

    pub fn init(allocator: std.mem.Allocator) Set {
        return .{ .allocator = allocator, .items = .empty };
    }
    pub fn deinit(self: *Set) void {
        self.items.deinit(self.allocator);
    }
    pub fn add(self: *Set, migration: Migration) !void {
        try self.items.append(self.allocator, migration);
    }
};

test "migration set stores ordered definitions" {
    var set = Set.init(std.testing.allocator);
    defer set.deinit();
    try set.add(.{ .version = 1, .up_sql = "CREATE TABLE t (id INTEGER);" });
    try std.testing.expectEqual(@as(u32, 1), set.items.items[0].version);
}
