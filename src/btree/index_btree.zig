const std = @import("std");
const BTree = @import("btree.zig").BTree;

pub const Index = struct {
    tree: BTree,
    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .tree = BTree.init(allocator) };
    }
    pub fn deinit(self: *Index) void {
        self.tree.deinit();
    }
    pub fn insert(self: *Index, key: u64, rid: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, rid, .big);
        try self.tree.put(key, &bytes);
    }
    pub fn rowid(self: *const Index, key: u64) ?u64 {
        const value = self.tree.get(key) orelse return null;
        var result: u64 = 0;
        for (value) |byte| result = (result << 8) | byte;
        return result;
    }
};

test "index b-tree maps keys to rowids" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();
    try index.insert(7, 42);
    try std.testing.expectEqual(@as(u64, 42), index.rowid(7).?);
}
