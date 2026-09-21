//! Ordered cursor over an in-memory `BTree` map.
//!
//! Purpose: positional (first/last/next/prev) and keyed (GE/LE/EQ) traversal
//! of `btree/btree.zig` entries without copying payloads. Responsibilities:
//! index bookkeeping and binary search only. Dependencies: `btree/btree.zig`,
//! `std` (tests). Ownership/lifetime: `Cursor` borrows the tree (`tree` must
//! outlive every cursor); `key`/`value` return borrowed data valid until the
//! tree is mutated. There is no allocation and no failure mode: out-of-range
//! positions are represented as invalid cursors (`valid() == false`), never
//! panics — `next` past the end parks at `len`, `prev` at index 0 parks at
//! `len` (invalid), and empty trees yield invalid cursors everywhere.
//! Invariants: `index <= entries.len`; `valid()` iff `index < len`.

const std = @import("std");
const BTree = @import("btree.zig").BTree;

/// Borrowed traversal position over a `BTree`.
///
/// Why index-based and not pointer-based: the entry list can reallocate on
/// insert, so stability comes from revalidating `index` per access instead
/// of holding element pointers.
pub const Cursor = struct {
    /// Borrowed map (must outlive the cursor).
    tree: *const BTree,
    /// Position; `entries.len` means invalid/past-the-end.
    index: usize = 0,

    /// Positions at the smallest key (invalid when the tree is empty).
    pub fn first(tree: *const BTree) Cursor {
        return .{ .tree = tree, .index = 0 };
    }

    /// Positions at the largest key (index 0, hence invalid, when empty).
    pub fn last(tree: *const BTree) Cursor {
        const len = tree.entries.items.len;
        return .{ .tree = tree, .index = if (len > 0) len - 1 else 0 };
    }

    /// Whether the cursor addresses a live entry.
    pub fn valid(self: Cursor) bool {
        return self.index < self.tree.entries.items.len;
    }

    /// Advances one entry; parks at `len` (invalid) past the last entry.
    pub fn next(self: *Cursor) void {
        if (self.valid()) self.index += 1;
    }

    /// Steps back one entry; stepping back from index 0 parks invalid.
    ///
    /// Why park invalid instead of wrapping: index 0 has no predecessor, and
    /// wrapping to `maxInt(usize)` would panic on the next access — parking
    /// at `len` keeps every state representable and testable.
    pub fn prev(self: *Cursor) void {
        if (self.index > 0) {
            self.index -= 1;
        } else {
            self.index = self.tree.entries.items.len;
        }
    }

    /// Seeks the first entry with key >= `targetKey` (may park invalid).
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

    /// Seeks the last entry with key <= `targetKey`.
    ///
    /// Implemented as `seekGE` plus at most one step back, so exact hits
    /// stay and in-between targets land on the predecessor; below-minimum
    /// targets park invalid.
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

    /// Seeks an exact key. Returns true and positions on it when present;
    /// otherwise parks invalid and returns false.
    pub fn seekEQ(self: *Cursor, targetKey: u64) bool {
        self.seekGE(targetKey);
        if (self.valid() and self.tree.entries.items[self.index].key == targetKey) {
            return true;
        }
        self.index = self.tree.entries.items.len;
        return false;
    }

    /// Current key, or `null` when invalid.
    pub fn key(self: Cursor) ?u64 {
        return if (self.valid()) self.tree.entries.items[self.index].key else null;
    }

    /// Current borrowed payload, or `null` when invalid.
    pub fn value(self: Cursor) ?[]const u8 {
        return if (self.valid()) self.tree.entries.items[self.index].payload else null;
    }

    /// Total entries in the tree (independent of position).
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

test "B-tree cursor edges stay invalid-safe on empty and boundary trees" {
    var empty = BTree.init(std.testing.allocator);
    defer empty.deinit();
    // Boundary: empty trees yield invalid cursors that stay parked.
    var first = Cursor.first(&empty);
    try std.testing.expect(!first.valid());
    try std.testing.expect(first.key() == null);
    try std.testing.expect(first.value() == null);
    try std.testing.expectEqual(@as(usize, 0), first.count());
    first.next();
    try std.testing.expect(!first.valid());
    first.prev(); // prev on empty parks at len (0) — still invalid, no wrap.
    try std.testing.expect(!first.valid());
    var only = Cursor.last(&empty);
    try std.testing.expect(!only.valid());
    only.seekGE(99);
    try std.testing.expect(!only.valid());
    only.seekLE(99);
    try std.testing.expect(!only.valid());
    try std.testing.expect(!only.seekEQ(99));

    var tree = BTree.init(std.testing.allocator);
    defer tree.deinit();
    try tree.put(10, "ten");
    try tree.put(20, "twenty");
    // Boundary: seeks outside the key range park at the correct edge.
    var low = Cursor.first(&tree);
    low.seekGE(1);
    try std.testing.expectEqual(@as(u64, 10), low.key().?);
    low.seekLE(1);
    try std.testing.expect(!low.valid());
    var high = Cursor.first(&tree);
    high.seekGE(100);
    try std.testing.expect(!high.valid());
    high.seekLE(100);
    try std.testing.expectEqual(@as(u64, 20), high.key().?);
    // Boundary: next past the end and prev at the start park invalid.
    var end = Cursor.last(&tree);
    end.next();
    try std.testing.expect(!end.valid());
    try std.testing.expect(end.key() == null);
    var start = Cursor.first(&tree);
    start.prev();
    try std.testing.expect(!start.valid());
    // Normal: value() exposes the borrowed payload.
    var at = Cursor.first(&tree);
    try std.testing.expect(at.seekEQ(20));
    try std.testing.expectEqualStrings("twenty", at.value().?);
    try std.testing.expectEqual(@as(usize, 2), at.count());
}
