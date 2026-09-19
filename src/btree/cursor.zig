const std = @import("std");
const BTree = @import("btree.zig").BTree;

pub const Cursor = struct {
    tree: *const BTree,
    index: usize = 0,

    pub fn first(tree: *const BTree) Cursor {
        return .{ .tree = tree, .index = 0 };
    }

    pub fn last(tree: *const BTree) Cursor {
        const len = tree.entries.items.len;
        return .{ .tree = tree, .index = if (len > 0) len - 1 else 0 };
    }

    pub fn valid(self: Cursor) bool {
        return self.index < self.tree.entries.items.len;
    }

    pub fn next(self: *Cursor) void {
        if (self.valid()) self.index += 1;
    }

    pub fn prev(self: *Cursor) void {
        if (self.index > 0) {
            self.index -= 1;
        } else {
            self.index = self.tree.entries.items.len;
        }
    }

    pub fn seekGE(self: *Cursor, targetKey: u64) void {
        var low: usize = 0;
        var high = self.tree.entries.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.tree.entries.items[middle].key < targetKey) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        self.index = low;
    }

    pub fn seekLE(self: *Cursor, targetKey: u64) void {
        self.seekGE(targetKey);
        if (self.valid()) {
            if (self.tree.entries.items[self.index].key > targetKey) {
                if (self.index > 0) {
                    self.index -= 1;
                } else {
                    self.index = self.tree.entries.items.len;
                }
            }
        } else {
            if (self.tree.entries.items.len > 0) {
                self.index = self.tree.entries.items.len - 1;
            }
        }
    }

    pub fn seekEQ(self: *Cursor, targetKey: u64) bool {
        self.seekGE(targetKey);
        if (self.valid() and self.tree.entries.items[self.index].key == targetKey) {
            return true;
        }
        self.index = self.tree.entries.items.len;
        return false;
    }

    pub fn key(self: Cursor) ?u64 {
        return if (self.valid()) self.tree.entries.items[self.index].key else null;
    }

    pub fn value(self: Cursor) ?[]const u8 {
        return if (self.valid()) self.tree.entries.items[self.index].payload else null;
    }

    pub fn count(self: Cursor) usize {
        return self.tree.entries.items.len;
    }
};

test "B-tree cursor walks entries forwards and backwards" {
    var tree = BTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.put(1, "x");
    try tree.put(2, "y");
    try tree.put(3, "z");

    var cursor = Cursor.first(&tree);
    try std.testing.expectEqual(@as(u64, 1), cursor.key().?);
    cursor.next();
    try std.testing.expectEqual(@as(u64, 2), cursor.key().?);
    cursor.next();
    try std.testing.expectEqual(@as(u64, 3), cursor.key().?);

    var lastCursor = Cursor.last(&tree);
    try std.testing.expectEqual(@as(u64, 3), lastCursor.key().?);
    lastCursor.prev();
    try std.testing.expectEqual(@as(u64, 2), lastCursor.key().?);
}

test "B-tree cursor seek operations find target keys" {
    var tree = BTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.put(10, "ten");
    try tree.put(20, "twenty");
    try tree.put(30, "thirty");

    var cursor = Cursor.first(&tree);
    cursor.seekGE(15);
    try std.testing.expect(cursor.valid());
    try std.testing.expectEqual(@as(u64, 20), cursor.key().?);

    cursor.seekLE(25);
    try std.testing.expect(cursor.valid());
    try std.testing.expectEqual(@as(u64, 20), cursor.key().?);

    try std.testing.expect(cursor.seekEQ(30));
    try std.testing.expectEqual(@as(u64, 30), cursor.key().?);

    try std.testing.expect(!cursor.seekEQ(25));
    try std.testing.expect(!cursor.valid());
}
