//! Ordered cursor over an in-memory `BTree`.
//!
//! The cursor borrows the tree and never allocates.
//! Out-of-range positions are invalid, never a panic.

const std = @import("std");
const BTree = @import("btree.zig").BTree;

/// Borrowed traversal position over a `BTree`.
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

test "B-tree cursor tracks a randomized tree in both directions" {
    // Deterministic seed: 300 puts over a 97-key universe (collisions hit
    // the replace path), then forward/backward walks plus random seeks
    // checked against an independent presence set sorted inline. Payloads
    // stay empty here; payload fidelity is covered by the map workload test.
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc07507);
    const rand = prng.random();
    var tree = BTree.init(alloc);
    defer tree.deinit();
    var present = std.AutoHashMap(u64, void).init(alloc);
    defer present.deinit();
    var n: usize = 0;
    while (n < 300) : (n += 1) {
        const key = rand.intRangeLessThan(u64, 0, 97);
        try tree.put(key, "");
        try present.put(key, {});
    }
    const sorted = blk: {
        var list = std.ArrayList(u64).empty;
        defer list.deinit(alloc);
        var it = present.keyIterator();
        while (it.next()) |k| try list.append(alloc, k.*);
        const owned = try list.toOwnedSlice(alloc);
        // Insertion sort: tiny input, no std.sort API surface needed.
        for (owned, 0..) |_, a| {
            var b = a;
            while (b > 0 and owned[b] < owned[b - 1]) : (b -= 1) {
                const tmp = owned[b];
                owned[b] = owned[b - 1];
                owned[b - 1] = tmp;
            }
        }
        break :blk owned;
    };
    defer alloc.free(sorted);
    try std.testing.expectEqual(sorted.len, tree.entries.items.len);
    var forward = Cursor.first(&tree);
    var idx: usize = 0;
    while (forward.valid()) : ({
        forward.next();
        idx += 1;
    }) {
        try std.testing.expectEqual(sorted[idx], forward.key().?);
    }
    try std.testing.expectEqual(sorted.len, idx);
    var backward = Cursor.last(&tree);
    var ridx: usize = sorted.len;
    while (backward.valid()) {
        ridx -= 1;
        try std.testing.expectEqual(sorted[ridx], backward.key().?);
        backward.prev();
    }
    try std.testing.expectEqual(@as(usize, 0), ridx);
    // Random seeks: expected outcomes by linear scan of the sorted keys.
    var s: usize = 0;
    while (s < 128) : (s += 1) {
        const target = rand.intRangeLessThan(u64, 0, 97);
        var wantGE: ?u64 = null;
        var wantLE: ?u64 = null;
        for (sorted) |k| {
            if (k >= target and wantGE == null) wantGE = k;
            if (k <= target) wantLE = k;
        }
        var ge = Cursor.first(&tree);
        ge.seekGE(target);
        if (wantGE) |k| {
            try std.testing.expect(ge.valid());
            try std.testing.expectEqual(k, ge.key().?);
        } else {
            try std.testing.expect(!ge.valid());
        }
        var le = Cursor.first(&tree);
        le.seekLE(target);
        if (wantLE) |k| {
            try std.testing.expect(le.valid());
            try std.testing.expectEqual(k, le.key().?);
        } else {
            try std.testing.expect(!le.valid());
        }
        var eq = Cursor.first(&tree);
        try std.testing.expectEqual(present.contains(target), eq.seekEQ(target));
        try std.testing.expectEqual(present.contains(target), eq.valid());
    }
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
