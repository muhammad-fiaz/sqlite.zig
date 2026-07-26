const std = @import("std");
const BTree = @import("btree.zig").BTree;

pub const Cursor = struct {
    tree: *const BTree,
    index: usize = 0,

    pub fn first(tree: *const BTree) Cursor {
        return .{ .tree = tree };
    }
    pub fn valid(self: Cursor) bool {
        return self.index < self.tree.entries.items.len;
    }
    pub fn next(self: *Cursor) void {
        if (self.valid()) self.index += 1;
    }
    pub fn key(self: Cursor) ?u64 {
        return if (self.valid()) self.tree.entries.items[self.index].key else null;
    }
    pub fn value(self: Cursor) ?[]const u8 {
        return if (self.valid()) self.tree.entries.items[self.index].payload else null;
    }
};

test "B-tree cursor walks entries" {
    var tree = BTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.put(1, "x");
    try tree.put(2, "y");
    var cursor = Cursor.first(&tree);
    cursor.next();
    try std.testing.expectEqual(@as(u64, 2), cursor.key().?);
}
