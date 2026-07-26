const std = @import("std");

pub const Entry = struct { key: u64, payload: []u8 };

pub const BTree = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    pub fn init(allocator: std.mem.Allocator) BTree {
        return .{ .allocator = allocator, .entries = .empty };
    }
    pub fn deinit(self: *BTree) void {
        for (self.entries.items) |entry| self.allocator.free(entry.payload);
        self.entries.deinit(self.allocator);
    }

    fn position(self: *const BTree, key: u64) usize {
        var low: usize = 0;
        var high = self.entries.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.entries.items[middle].key < key) low = middle + 1 else high = middle;
        }
        return low;
    }

    pub fn put(self: *BTree, key: u64, payload: []const u8) !void {
        const owned = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned);
        const index = self.position(key);
        if (index < self.entries.items.len and self.entries.items[index].key == key) {
            self.allocator.free(self.entries.items[index].payload);
            self.entries.items[index].payload = owned;
            return;
        }
        try self.entries.insert(self.allocator, index, .{ .key = key, .payload = owned });
    }

    pub fn get(self: *const BTree, key: u64) ?[]const u8 {
        const index = self.position(key);
        if (index < self.entries.items.len and self.entries.items[index].key == key) return self.entries.items[index].payload;
        return null;
    }

    pub fn remove(self: *BTree, key: u64) bool {
        const index = self.position(key);
        if (index >= self.entries.items.len or self.entries.items[index].key != key) return false;
        const entry = self.entries.orderedRemove(index);
        self.allocator.free(entry.payload);
        return true;
    }
};

test "B-tree keeps keys ordered and replaces values" {
    var tree = BTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.put(8, "b");
    try tree.put(2, "a");
    try tree.put(8, "c");
    try std.testing.expectEqualStrings("c", tree.get(8).?);
    try std.testing.expectEqual(@as(u64, 2), tree.entries.items[0].key);
}
