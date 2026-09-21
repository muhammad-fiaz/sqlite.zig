//! Page framing plus a sorted in-memory key to payload map.
//!
//! `BTree` owns its payload copies; `get` borrows until the next mutation.
//! Bad headers fail `InvalidHeader`, unfittable pages `PageOverflow`.

const std = @import("std");
const varint = @import("../format/varint.zig");

/// One sorted map entry: key plus an owned payload copy.
pub const Entry = struct {
    /// Sort key (table rowid or index key prefix).
    key: u64,
    /// Owned payload bytes (freed on replace/remove/deinit).
    payload: []u8,
};

/// On-disk b-tree page kinds (SQLite flag values).
pub const PageType = enum(u8) {
    /// Interior index page (flag 0x02): child pointers + separator payloads.
    interiorIndex = 0x02,
    /// Interior table page (flag 0x05): child pointers + separator rowids.
    interiorTable = 0x05,
    /// Leaf index page (flag 0x0a): payload cells only.
    leafIndex = 0x0a,
    /// Leaf table page (flag 0x0d): payload + rowid cells only.
    leafTable = 0x0d,
};

/// Decoded 8- or 12-byte b-tree page header. Interior pages carry `rightChild`.
pub const PageHeader = struct {
    /// Page kind (drives the 8 vs 12 byte header size).
    pageType: PageType,
    /// First freeblock offset (0 = none; preserved verbatim).
    firstFreeblock: u16 = 0,
    /// Number of cell pointers in the pointer array.
    cellCount: u16 = 0,
    /// Start of the cell-content area (0 when the page holds no cells).
    cellContentStart: u16 = 0,
    /// Fragmented free bytes count (preserved verbatim).
    fragmentedFreeBytes: u8 = 0,
    /// Rightmost child (interior pages only).
    rightChild: ?u32 = null,

    /// Byte offset of the b-tree header (100 on page 1 for the db header).
    pub fn headerOffset(pageNumber: u32) usize {
        return if (pageNumber == 1) 100 else 0;
    }

    /// Header length for a kind: 12 for interior, 8 for leaf pages.
    pub fn headerSize(pageType: PageType) usize {
        return switch (pageType) {
            .interiorTable, .interiorIndex => 12,
            .leafTable, .leafIndex => 8,
        };
    }

    /// Parses and validates a page header. Short buffers fail `InvalidHeader`.
    pub fn decode(page: []const u8, pageNumber: u32) !PageHeader {
        const offset = headerOffset(pageNumber);
        if (page.len < offset + 8) return error.InvalidHeader;
        const typeByte = page[offset];
        const pageType: PageType = switch (typeByte) {
            0x02 => .interiorIndex,
            0x05 => .interiorTable,
            0x0a => .leafIndex,
            0x0d => .leafTable,
            else => return error.InvalidHeader,
        };
        const hSize = headerSize(pageType);
        if (page.len < offset + hSize) return error.InvalidHeader;
        const firstFreeblock = (@as(u16, page[offset + 1]) << 8) | page[offset + 2];
        const cellCount = (@as(u16, page[offset + 3]) << 8) | page[offset + 4];
        const cellContentStart = (@as(u16, page[offset + 5]) << 8) | page[offset + 6];
        const fragmentedFreeBytes = page[offset + 7];
        var rightChild: ?u32 = null;
        if (hSize == 12) {
            rightChild = std.mem.readInt(u32, page[offset + 8 .. offset + 12][0..4], .big);
        }
        return .{
            .pageType = pageType,
            .firstFreeblock = firstFreeblock,
            .cellCount = cellCount,
            .cellContentStart = cellContentStart,
            .fragmentedFreeBytes = fragmentedFreeBytes,
            .rightChild = rightChild,
        };
    }

    /// Serializes the header at the page's header offset.
    pub fn encode(self: PageHeader, page: []u8, pageNumber: u32) void {
        const offset = headerOffset(pageNumber);
        std.debug.assert(offset + headerSize(self.pageType) <= page.len);
        std.debug.assert(self.pageType == .interiorTable or self.pageType == .interiorIndex or self.rightChild == null);
        page[offset] = @intFromEnum(self.pageType);
        page[offset + 1] = @truncate(self.firstFreeblock >> 8);
        page[offset + 2] = @truncate(self.firstFreeblock);
        page[offset + 3] = @truncate(self.cellCount >> 8);
        page[offset + 4] = @truncate(self.cellCount);
        page[offset + 5] = @truncate(self.cellContentStart >> 8);
        page[offset + 6] = @truncate(self.cellContentStart);
        page[offset + 7] = self.fragmentedFreeBytes;
        if (self.rightChild) |rc| {
            std.mem.writeInt(u32, page[offset + 8 .. offset + 12][0..4], rc, .big);
        }
    }
};

/// Writes a big-endian u16 cell-pointer slot (encode path only).
///
/// Safety: bounds-checked like `sqlite_image.putU16` — short pages return
/// `PageOverflow` instead of writing out of bounds.
fn putU16(bytes: []u8, offset: usize, value: u16) !void {
    if (offset + 2 > bytes.len) return error.PageOverflow;
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

/// Builds a table-leaf page from pre-framed cells. Unfittable cells fail `PageOverflow`.
pub fn formatLeafTablePage(page: []u8, pageNumber: u32, cells: []const []const u8, pageSize: usize) !void {
    if (page.len < pageSize) return error.PageOverflow;
    const hOffset = PageHeader.headerOffset(pageNumber);
    const hSize = PageHeader.headerSize(.leafTable);
    const header = hOffset;
    if (cells.len > 0xffff) return error.PageOverflow;
    if (header + hSize > pageSize) return error.PageOverflow;
    const arrayBytes = cells.len * 2;
    if (header + hSize + arrayBytes > pageSize) return error.PageOverflow;
    const reservedEnd = header + hSize + arrayBytes;
    var content = pageSize;
    for (cells) |item| {
        if (item.len > content - reservedEnd) return error.PageOverflow;
        content -= item.len;
        @memcpy(page[content .. content + item.len], item);
    }
    const cellContentStart: u16 = if (cells.len == 0) 0 else @intCast(content);
    const ph = PageHeader{
        .pageType = .leafTable,
        .firstFreeblock = 0,
        .cellCount = @intCast(cells.len),
        .cellContentStart = cellContentStart,
        .fragmentedFreeBytes = 0,
    };
    ph.encode(page, pageNumber);
    content = pageSize;
    for (cells, 0..) |item, index| {
        content -= item.len;
        try putU16(page, header + hSize + index * 2, @intCast(content));
    }
}

/// Builds a table-interior page from child pointers and separator rowids.
/// Mismatched lengths fail `InvalidParam`; unfittable cells fail `PageOverflow`.
pub fn formatInteriorTablePage(page: []u8, pageNumber: u32, leftChildren: []const u32, keys: []const u64, rightChild: u32, pageSize: usize) !void {
    if (page.len < pageSize) return error.PageOverflow;
    if (leftChildren.len != keys.len) return error.InvalidParam;
    const hOffset = PageHeader.headerOffset(pageNumber);
    const hSize = PageHeader.headerSize(.interiorTable);
    const header = hOffset;
    if (header + hSize > pageSize) return error.PageOverflow;
    if (leftChildren.len > 0xffff) return error.PageOverflow;
    const arrayBytes = leftChildren.len * 2;
    if (header + hSize + arrayBytes > pageSize) return error.PageOverflow;
    const reservedEnd = header + hSize + arrayBytes;
    var content = pageSize;

    for (leftChildren, 0..) |leftChild, index| {
        var keyBuf: [9]u8 = undefined;
        const keyLen = try varint.encode(keys[index], &keyBuf);
        const cellSize = 4 + keyLen;
        if (cellSize > content - reservedEnd) return error.PageOverflow;
        content -= cellSize;
        std.mem.writeInt(u32, page[content .. content + 4][0..4], leftChild, .big);
        @memcpy(page[content + 4 .. content + 4 + keyLen], keyBuf[0..keyLen]);
    }

    const ph = PageHeader{
        .pageType = .interiorTable,
        .firstFreeblock = 0,
        .cellCount = @intCast(leftChildren.len),
        .cellContentStart = if (leftChildren.len == 0) 0 else @intCast(content),
        .fragmentedFreeBytes = 0,
        .rightChild = rightChild,
    };
    ph.encode(page, pageNumber);

    // Second pass regenerates the same offsets (validated to fit above, so
    // the subtractions cannot underflow here).
    content = pageSize;
    for (0..leftChildren.len) |index| {
        var keyBuf: [9]u8 = undefined;
        const keyLen = try varint.encode(keys[index], &keyBuf);
        content -= 4 + keyLen;
        try putU16(page, header + hSize + index * 2, @intCast(content));
    }
}

/// Builds an index-leaf page from pre-framed cells (checked like the
/// table-leaf variant).
pub fn formatLeafIndexPage(page: []u8, pageNumber: u32, cells: []const []const u8, pageSize: usize) !void {
    if (page.len < pageSize) return error.PageOverflow;
    const hOffset = PageHeader.headerOffset(pageNumber);
    const hSize = PageHeader.headerSize(.leafIndex);
    const header = hOffset;
    if (cells.len > 0xffff) return error.PageOverflow;
    if (header + hSize > pageSize) return error.PageOverflow;
    const arrayBytes = cells.len * 2;
    if (header + hSize + arrayBytes > pageSize) return error.PageOverflow;
    const reservedEnd = header + hSize + arrayBytes;
    var content = pageSize;
    for (cells) |item| {
        if (item.len > content - reservedEnd) return error.PageOverflow;
        content -= item.len;
        @memcpy(page[content .. content + item.len], item);
    }
    const cellContentStart: u16 = if (cells.len == 0) 0 else @intCast(content);
    const ph = PageHeader{
        .pageType = .leafIndex,
        .firstFreeblock = 0,
        .cellCount = @intCast(cells.len),
        .cellContentStart = cellContentStart,
        .fragmentedFreeBytes = 0,
    };
    ph.encode(page, pageNumber);
    content = pageSize;
    for (cells, 0..) |item, index| {
        content -= item.len;
        try putU16(page, header + hSize + index * 2, @intCast(content));
    }
}

/// Builds an index-interior page from child pointers + separator payloads.
///
/// Same contract as the table-interior variant (allocation-free two-pass
/// offsets, `InvalidParam` on length mismatch, `PageOverflow` when unfitted).
pub fn formatInteriorIndexPage(page: []u8, pageNumber: u32, leftChildren: []const u32, payloads: []const []const u8, rightChild: u32, pageSize: usize) !void {
    if (page.len < pageSize) return error.PageOverflow;
    if (leftChildren.len != payloads.len) return error.InvalidParam;
    const hOffset = PageHeader.headerOffset(pageNumber);
    const hSize = PageHeader.headerSize(.interiorIndex);
    const header = hOffset;
    if (header + hSize > pageSize) return error.PageOverflow;
    if (leftChildren.len > 0xffff) return error.PageOverflow;
    const arrayBytes = leftChildren.len * 2;
    if (header + hSize + arrayBytes > pageSize) return error.PageOverflow;
    const reservedEnd = header + hSize + arrayBytes;
    var content = pageSize;

    for (leftChildren, 0..) |leftChild, index| {
        var lenBuf: [9]u8 = undefined;
        const lenBytes = try varint.encode(payloads[index].len, &lenBuf);
        const cellSize = 4 + lenBytes + payloads[index].len;
        if (cellSize > content - reservedEnd) return error.PageOverflow;
        content -= cellSize;
        std.mem.writeInt(u32, page[content .. content + 4][0..4], leftChild, .big);
        @memcpy(page[content + 4 .. content + 4 + lenBytes], lenBuf[0..lenBytes]);
        @memcpy(page[content + 4 + lenBytes .. content + 4 + lenBytes + payloads[index].len], payloads[index]);
    }

    const ph = PageHeader{
        .pageType = .interiorIndex,
        .firstFreeblock = 0,
        .cellCount = @intCast(leftChildren.len),
        .cellContentStart = if (leftChildren.len == 0) 0 else @intCast(content),
        .fragmentedFreeBytes = 0,
        .rightChild = rightChild,
    };
    ph.encode(page, pageNumber);

    content = pageSize;
    for (0..leftChildren.len) |index| {
        var lenBuf: [9]u8 = undefined;
        const lenBytes = try varint.encode(payloads[index].len, &lenBuf);
        content -= 4 + lenBytes + payloads[index].len;
        try putU16(page, header + hSize + index * 2, @intCast(content));
    }
}

/// Sorted in-memory key to payload map. `get` borrows; `deinit` frees payloads.
pub const BTree = struct {
    /// Allocator for payload copies and the entry list.
    allocator: std.mem.Allocator,
    /// Entries in ascending key order.
    entries: std.ArrayList(Entry),

    /// Creates an empty map (no allocation until the first `put`).
    pub fn init(allocator: std.mem.Allocator) BTree {
        return .{ .allocator = allocator, .entries = .empty };
    }
    /// Frees every payload copy and the entry list.
    pub fn deinit(self: *BTree) void {
        for (self.entries.items) |entry| self.allocator.free(entry.payload);
        self.entries.deinit(self.allocator);
    }

    /// Lower-bound index of `key` (first entry with key >= target).
    fn position(self: *const BTree, key: u64) usize {
        var low: usize = 0;
        var high = self.entries.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.entries.items[middle].key < key) low = middle + 1 else high = middle;
        }
        return low;
    }

    /// Inserts or replaces `key`, duping `payload` first so the caller's
    /// slice needs no lifetime beyond the call.
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

    /// Returns the borrowed payload for `key`, or `null` when absent.
    pub fn get(self: *const BTree, key: u64) ?[]const u8 {
        const index = self.position(key);
        if (index < self.entries.items.len and self.entries.items[index].key == key) return self.entries.items[index].payload;
        return null;
    }

    /// Deletes `key`, freeing its payload. Returns false when absent.
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

test "PageHeader encodes and decodes leaf and interior headers" {
    var page = [_]u8{0} ** 4096;
    const leafHeader = PageHeader{
        .pageType = .leafTable,
        .firstFreeblock = 0,
        .cellCount = 5,
        .cellContentStart = 3800,
        .fragmentedFreeBytes = 0,
    };
    leafHeader.encode(&page, 2);
    const decodedLeaf = try PageHeader.decode(&page, 2);
    try std.testing.expectEqual(PageType.leafTable, decodedLeaf.pageType);
    try std.testing.expectEqual(@as(u16, 5), decodedLeaf.cellCount);
    try std.testing.expectEqual(@as(u16, 3800), decodedLeaf.cellContentStart);

    const interiorHeader = PageHeader{
        .pageType = .interiorTable,
        .firstFreeblock = 0,
        .cellCount = 2,
        .cellContentStart = 3900,
        .fragmentedFreeBytes = 0,
        .rightChild = 42,
    };
    interiorHeader.encode(&page, 3);
    const decodedInterior = try PageHeader.decode(&page, 3);
    try std.testing.expectEqual(PageType.interiorTable, decodedInterior.pageType);
    try std.testing.expectEqual(@as(u32, 42), decodedInterior.rightChild.?);
}

test "formatLeafTablePage and formatInteriorTablePage construct valid pages" {
    var page = [_]u8{0} ** 4096;
    const dummyCell = "cell_payload";
    const cells = [_][]const u8{ dummyCell, dummyCell };
    try formatLeafTablePage(&page, 2, &cells, 4096);
    const decoded = try PageHeader.decode(&page, 2);
    try std.testing.expectEqual(PageType.leafTable, decoded.pageType);
    try std.testing.expectEqual(@as(u16, 2), decoded.cellCount);

    var interiorPage = [_]u8{0} ** 4096;
    const leftKids = [_]u32{ 2, 3 };
    const keys = [_]u64{ 10, 20 };
    try formatInteriorTablePage(&interiorPage, 4, &leftKids, &keys, 5, 4096);
    const decodedInterior = try PageHeader.decode(&interiorPage, 4);
    try std.testing.expectEqual(PageType.interiorTable, decodedInterior.pageType);
    try std.testing.expectEqual(@as(u32, 5), decodedInterior.rightChild.?);
}

test "PageHeader rejects unknown flags and short buffers" {
    // Error: every non-SQLite flag byte fails closed.
    for ([_]u8{ 0x00, 0x01, 0x09, 0xff }) |flag| {
        var page = [_]u8{0} ** 512;
        page[0] = flag;
        try std.testing.expectError(error.InvalidHeader, PageHeader.decode(&page, 2));
    }
    // Error: short buffers fail closed, including page-1 header reservation.
    var tiny: [7]u8 = .{ 0x0d, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidHeader, PageHeader.decode(&tiny, 2));
    var empty: [0]u8 = .{};
    try std.testing.expectError(error.InvalidHeader, PageHeader.decode(&empty, 2));
    var shortOne: [101]u8 = std.mem.zeroes([101]u8);
    shortOne[100] = 0x05; // interior needs 12 bytes, only 1 available
    try std.testing.expectError(error.InvalidHeader, PageHeader.decode(&shortOne, 1));
    // Normal: page-1 headers decode past the 100-byte reservation.
    var pageOne = [_]u8{0} ** 512;
    (PageHeader{ .pageType = .leafTable, .cellCount = 1 }).encode(pageOne[0..], 1);
    try std.testing.expectEqual(PageType.leafTable, (try PageHeader.decode(pageOne[0..], 1)).pageType);
}

test "page formatters fail closed on unfittable and short pages" {
    // Error: buffer smaller than the claimed page size.
    var small: [512]u8 = std.mem.zeroes([512]u8);
    const cell = "payload";
    const cells = [_][]const u8{cell};
    try std.testing.expectError(error.PageOverflow, formatLeafTablePage(&small, 2, &cells, 4096));
    try std.testing.expectError(error.PageOverflow, formatLeafIndexPage(&small, 2, &cells, 4096));
    const kids = [_]u32{2};
    const keyList = [_]u64{9};
    try std.testing.expectError(error.PageOverflow, formatInteriorTablePage(&small, 2, &kids, &keyList, 3, 4096));
    const payloads = [_][]const u8{"p"};
    try std.testing.expectError(error.PageOverflow, formatInteriorIndexPage(&small, 2, &kids, &payloads, 3, 4096));
    // Error: key/child and payload/child length mismatches.
    var page = [_]u8{0} ** 512;
    const twoKids = [_]u32{ 2, 3 };
    const oneKey = [_]u64{9};
    try std.testing.expectError(error.InvalidParam, formatInteriorTablePage(&page, 2, &twoKids, &oneKey, 4, 512));
    try std.testing.expectError(error.InvalidParam, formatInteriorIndexPage(&page, 2, &twoKids, &payloads, 4, 512));
    // Error: a cell larger than the page cannot fit anywhere.
    var big = [_]u8{0} ** 512;
    const hugeCell = [_]u8{0xaa} ** 600;
    const hugeCells = [_][]const u8{&hugeCell};
    try std.testing.expectError(error.PageOverflow, formatLeafTablePage(&big, 2, &hugeCells, 512));
    // Boundary: empty pages format with zero cells and null-free headers.
    var blank = [_]u8{0} ** 512;
    try formatLeafTablePage(&blank, 2, &[_][]const u8{}, 512);
    try std.testing.expectEqual(@as(u16, 0), (try PageHeader.decode(&blank, 2)).cellCount);
    // Normal: index leaf + interior pages round-trip their headers.
    var leafIdx = [_]u8{0} ** 512;
    try formatLeafIndexPage(&leafIdx, 2, &cells, 512);
    try std.testing.expectEqual(PageType.leafIndex, (try PageHeader.decode(&leafIdx, 2)).pageType);
    var interiorIdx = [_]u8{0} ** 512;
    try formatInteriorIndexPage(&interiorIdx, 2, &kids, &payloads, 9, 512);
    try std.testing.expectEqual(@as(u32, 9), (try PageHeader.decode(&interiorIdx, 2)).rightChild.?);
}

test "B-tree map handles miss, extremes, and removal" {
    var tree = BTree.init(std.testing.allocator);
    defer tree.deinit();
    // Normal: missing keys miss on an empty and populated map.
    try std.testing.expect(tree.get(1) == null);
    try tree.put(5, "five");
    try std.testing.expect(tree.get(4) == null);
    try std.testing.expect(tree.get(6) == null);
    // Boundary: u64 key extremes order correctly.
    try tree.put(0, "zero");
    try tree.put(std.math.maxInt(u64), "max");
    try std.testing.expectEqual(@as(u64, 0), tree.entries.items[0].key);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), tree.entries.items[tree.entries.items.len - 1].key);
    // Normal: empty payloads round-trip; removal frees and reports.
    try tree.put(7, "");
    try std.testing.expectEqual(@as(usize, 0), tree.get(7).?.len);
    try std.testing.expect(tree.remove(7));
    try std.testing.expect(!tree.remove(7));
    try std.testing.expect(tree.get(7) == null);
}
