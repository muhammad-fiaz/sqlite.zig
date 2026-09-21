const std = @import("std");

pub const Migration = struct {
    version: u32,
    name: []const u8 = "",
    upSql: []const u8,
    downSql: []const u8 = "",

    pub fn checksum(self: Migration) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(self.name);
        h.update(&.{0});
        h.update(self.upSql);
        h.update(&.{0});
        h.update(self.downSql);
        return h.final();
    }
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
    try set.add(.{ .version = 1, .name = "init", .upSql = "CREATE TABLE t (id INTEGER);" });
    try std.testing.expectEqual(@as(u32, 1), set.items.items[0].version);
    try std.testing.expectEqualStrings("init", set.items.items[0].name);
}

test "migration checksum distinguishes edited statements" {
    const a = Migration{ .version = 1, .name = "init", .upSql = "CREATE TABLE t (id INTEGER);" };
    const b = Migration{ .version = 1, .name = "init", .upSql = "CREATE TABLE t (id TEXT);" };
    try std.testing.expect(a.checksum() != b.checksum());
    const c = Migration{ .version = 1, .name = "init", .upSql = "CREATE TABLE t (id INTEGER);" };
    try std.testing.expectEqual(a.checksum(), c.checksum());
}
