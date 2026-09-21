//! Secondary-index overlay: key -> rowid map over a `BTree`.
//!
//! Purpose: maintain the `key -> rowid` lookup an index needs, encoding each
//! rowid as 8 big-endian bytes in the underlying map payload. Dependencies:
//! `btree/btree.zig`, `std`. Ownership/lifetime: `Index` owns its `BTree`
//! (`deinit` frees); `rowid` returns a copied integer (no lifetime).
//! Error behavior: short/corrupt payloads yield `null` from `rowid` (fail
//! closed, never panics on slicing); allocation failures propagate from
//! `insert`. Invariants: every stored payload is exactly 8 bytes; inserting
//! an existing key overwrites its rowid.

const std = @import("std");
const BTree = @import("btree.zig").BTree;

/// Owned secondary-index map from index key to table rowid.
pub const Index = struct {
    /// Backing map (payloads are 8-byte big-endian rowids).
    tree: BTree,

    /// Creates an empty index (no allocation until the first `insert`).
    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .tree = BTree.init(allocator) };
    }

    /// Frees all stored rowid payloads.
    pub fn deinit(self: *Index) void {
        self.tree.deinit();
    }

    /// Maps `key` to `rid`, overwriting any previous rowid for the key.
    pub fn insert(self: *Index, key: u64, rid: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, rid, .big);
        try self.tree.put(key, &bytes);
    }

    /// Looks up the rowid for `key`, or `null` when absent or corrupt.
    ///
    /// Why the length check: payloads should always be 8 bytes, but a short
    /// payload (only reachable via direct `tree` manipulation or a bug)
    /// returns `null` instead of panicking on the fixed slice.
    pub fn rowid(self: *const Index, key: u64) ?u64 {
        const value = self.tree.get(key) orelse return null;
        if (value.len < 8) return null;
        return std.mem.readInt(u64, value[0..8], .big);
    }

    /// Number of indexed keys.
    pub fn count(self: *const Index) usize {
        return self.tree.entries.items.len;
    }

    /// Deletes `key`. Returns false when the key was absent.
    pub fn remove(self: *Index, key: u64) bool {
        return self.tree.remove(key);
    }
};

test "index b-tree maps keys to rowids" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();
    try index.insert(7, 42);
    try std.testing.expectEqual(@as(u64, 42), index.rowid(7).?);
    try std.testing.expectEqual(@as(usize, 1), index.count());
    try std.testing.expect(index.remove(7));
    try std.testing.expectEqual(@as(usize, 0), index.count());
}

test "index b-tree overwrites, misses safely, and tolerates short payloads" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();
    // Normal: missing keys miss; removing them reports false.
    try std.testing.expect(index.rowid(1) == null);
    try std.testing.expect(!index.remove(1));
    // Normal: re-inserting a key overwrites the rowid in place.
    try index.insert(3, 100);
    try index.insert(3, 200);
    try std.testing.expectEqual(@as(u64, 200), index.rowid(3).?);
    try std.testing.expectEqual(@as(usize, 1), index.count());
    // Boundary: rowid extremes survive the big-endian round trip.
    try index.insert(4, 0);
    try index.insert(5, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 0), index.rowid(4).?);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), index.rowid(5).?);
    // Safety: a short payload (injected below the API) reads as null, never
    // panics on the 8-byte slice.
    try index.tree.put(6, "short");
    try std.testing.expect(index.rowid(6) == null);
    try std.testing.expectEqual(@as(usize, 4), index.count());
}
