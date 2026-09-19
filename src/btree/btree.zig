const std = @import("std");
const varint = @import("../format/varint.zig");

pub const Entry = struct { key: u64, payload: []u8 };

pub const PageType = enum(u8) {
    interiorIndex = 0x02,
    interiorTable = 0x05,
    leafIndex = 0x0a,
    leafTable = 0x0d,
};

pub const PageHeader = struct {
    pageType: PageType,
    firstFreeblock: u16 = 0,
    cellCount: u16 = 0,
    cellContentStart: u16 = 0,
    fragmentedFreeBytes: u8 = 0,
    rightChild: ?u32 = null,

    pub fn headerOffset(pageNumber: u32) usize {
        return if (pageNumber == 1) 100 else 0;
    }

    pub fn headerSize(pageType: PageType) usize {
        return switch (pageType) {
            .interiorTable, .interiorIndex => 12,
            .leafTable, .leafIndex => 8,
        };
    }

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

    pub fn encode(self: PageHeader, page: []u8, pageNumber: u32) void {
        const offset = headerOffset(pageNumber);
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

fn putU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

pub fn formatLeafTablePage(page: []u8, pageNumber: u32, cells: []const []const u8, pageSize: usize) !void {
    const hOffset = PageHeader.headerOffset(pageNumber);
    const hSize = PageHeader.headerSize(.leafTable);
    const header = hOffset;
    if (cells.len > 0xffff) return error.PageOverflow;
    var content = pageSize;
    for (cells) |item| {
        if (item.len > content - (header + hSize + cells.len * 2)) return error.PageOverflow;
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
        putU16(page, header + hSize + index * 2, @intCast(content));
    }
}

pub fn formatInteriorTablePage(page: []u8, pageNumber: u32, leftChildren: []const u32, keys: []const u64, rightChild: u32, pageSize: usize) !void {
    if (leftChildren.len != keys.len) return error.InvalidParam;
    const hOffset = PageHeader.headerOffset(pageNumber);
    const hSize = PageHeader.headerSize(.interiorTable);
    const header = hOffset;
    var content = pageSize;
    var cellOffsets: [1024]u16 = undefined;
    if (leftChildren.len > 1024) return error.PageOverflow;

    for (leftChildren, 0..) |leftChild, index| {
        var keyBuf: [9]u8 = undefined;
        const keyLen = try varint.encode(keys[index], &keyBuf);
        const cellSize = 4 + keyLen;
        if (cellSize > content - (header + hSize + leftChildren.len * 2)) return error.PageOverflow;
        content -= cellSize;
        std.mem.writeInt(u32, page[content .. content + 4][0..4], leftChild, .big);
        @memcpy(page[content + 4 .. content + 4 + keyLen], keyBuf[0..keyLen]);
        cellOffsets[index] = @intCast(content);
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

    for (0..leftChildren.len) |index| {
        putU16(page, header + hSize + index * 2, cellOffsets[index]);
    }
}

pub fn formatLeafIndexPage(page: []u8, pageNumber: u32, cells: []const []const u8, pageSize: usize) !void {
    const hOffset = PageHeader.headerOffset(pageNumber);
    const hSize = PageHeader.headerSize(.leafIndex);
    const header = hOffset;
    if (cells.len > 0xffff) return error.PageOverflow;
    var content = pageSize;
    for (cells) |item| {
        if (item.len > content - (header + hSize + cells.len * 2)) return error.PageOverflow;
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
        putU16(page, header + hSize + index * 2, @intCast(content));
    }
}

pub fn formatInteriorIndexPage(page: []u8, pageNumber: u32, leftChildren: []const u32, payloads: []const []const u8, rightChild: u32, pageSize: usize) !void {
    if (leftChildren.len != payloads.len) return error.InvalidParam;
    const hOffset = PageHeader.headerOffset(pageNumber);
    const hSize = PageHeader.headerSize(.interiorIndex);
    const header = hOffset;
    var content = pageSize;
    var cellOffsets: [1024]u16 = undefined;
    if (leftChildren.len > 1024) return error.PageOverflow;

    for (leftChildren, 0..) |leftChild, index| {
        var lenBuf: [9]u8 = undefined;
        const lenBytes = try varint.encode(payloads[index].len, &lenBuf);
        const cellSize = 4 + lenBytes + payloads[index].len;
        if (cellSize > content - (header + hSize + leftChildren.len * 2)) return error.PageOverflow;
        content -= cellSize;
        std.mem.writeInt(u32, page[content .. content + 4][0..4], leftChild, .big);
        @memcpy(page[content + 4 .. content + 4 + lenBytes], lenBuf[0..lenBytes]);
        @memcpy(page[content + 4 + lenBytes .. content + 4 + lenBytes + payloads[index].len], payloads[index]);
        cellOffsets[index] = @intCast(content);
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

    for (0..leftChildren.len) |index| {
        putU16(page, header + hSize + index * 2, cellOffsets[index]);
    }
}

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
