const std = @import("std");

pub const headerSize = 32;
pub const frameHeaderSize = 24;
pub const formatVersion: u32 = 3007000;
pub const magic: u32 = 0x377f0682;

pub const WalHeader = struct {
    pageSize: u32,
    checkpointSequence: u32 = 0,
    salt1: u32 = 0x51f15eed,
    salt2: u32 = 0x9e3779b9,
    checksum1: u32 = 0,
    checksum2: u32 = 0,

    pub fn encode(self: WalHeader, out: *[headerSize]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], magic, .big);
        std.mem.writeInt(u32, out[4..8], formatVersion, .big);
        std.mem.writeInt(u32, out[8..12], self.pageSize, .big);
        std.mem.writeInt(u32, out[12..16], self.checkpointSequence, .big);
        std.mem.writeInt(u32, out[16..20], self.salt1, .big);
        std.mem.writeInt(u32, out[20..24], self.salt2, .big);
        const sums = checksum(0, 0, out[0..24]);
        std.mem.writeInt(u32, out[24..28], sums[0], .big);
        std.mem.writeInt(u32, out[28..32], sums[1], .big);
    }
};

pub const FrameHeader = struct {
    pageNumber: u32,
    databaseSize: u32,
    salt1: u32,
    salt2: u32,
    checksum1: u32,
    checksum2: u32,

    pub fn encode(self: FrameHeader, out: *[frameHeaderSize]u8) void {
        std.mem.writeInt(u32, out[0..4], self.pageNumber, .big);
        std.mem.writeInt(u32, out[4..8], self.databaseSize, .big);
        std.mem.writeInt(u32, out[8..12], self.salt1, .big);
        std.mem.writeInt(u32, out[12..16], self.salt2, .big);
        std.mem.writeInt(u32, out[16..20], self.checksum1, .big);
        std.mem.writeInt(u32, out[20..24], self.checksum2, .big);
    }
};

pub fn checksum(seed1: u32, seed2: u32, bytes: []const u8) [2]u32 {
    var first = seed1;
    var second = seed2;
    var index: usize = 0;
    while (index + 3 < bytes.len) : (index += 4) {
        first +%= (@as(u32, bytes[index]) << 24) | (@as(u32, bytes[index + 1]) << 16) | (@as(u32, bytes[index + 2]) << 8) | bytes[index + 3];
        second +%= first;
    }
    return .{ first, second };
}

pub fn encodeImage(allocator: std.mem.Allocator, image: []const u8, pageSize: usize) ![]u8 {
    if (pageSize < 512 or image.len == 0 or image.len % pageSize != 0) return error.InvalidPageSize;
    const pageCount: u32 = @intCast(image.len / pageSize);
    var header: [headerSize]u8 = undefined;
    (WalHeader{ .pageSize = @intCast(pageSize) }).encode(&header);
    const result = try allocator.alloc(u8, headerSize + @as(usize, pageCount) * (frameHeaderSize + pageSize));
    errdefer allocator.free(result);
    @memcpy(result[0..headerSize], &header);
    var previous = [2]u32{ 0, 0 };
    var position: usize = headerSize;
    for (0..pageCount) |pageIndex| {
        var frameInput = try allocator.alloc(u8, 8 + pageSize);
        defer allocator.free(frameInput);
        std.mem.writeInt(u32, frameInput[0..4], @intCast(pageIndex + 1), .big);
        std.mem.writeInt(u32, frameInput[4..8], if (pageIndex == 0) pageCount else 0, .big);
        @memcpy(frameInput[8..], image[pageIndex * pageSize .. (pageIndex + 1) * pageSize]);
        const sums = checksum(previous[0], previous[1], frameInput);
        var frameHeader: [frameHeaderSize]u8 = undefined;
        (FrameHeader{ .pageNumber = @intCast(pageIndex + 1), .databaseSize = if (pageIndex == 0) pageCount else 0, .salt1 = std.mem.readInt(u32, header[16..20], .big), .salt2 = std.mem.readInt(u32, header[20..24], .big), .checksum1 = sums[0], .checksum2 = sums[1] }).encode(&frameHeader);
        @memcpy(result[position .. position + frameHeaderSize], &frameHeader);
        position += frameHeaderSize;
        @memcpy(result[position .. position + pageSize], image[pageIndex * pageSize .. (pageIndex + 1) * pageSize]);
        position += pageSize;
        previous = sums;
    }
    return result;
}

pub fn apply(allocator: std.mem.Allocator, baseImage: []const u8, walImage: []const u8) ![]u8 {
    if (walImage.len < headerSize) return error.InvalidWal;
    var pageSizeBytes: [4]u8 = undefined;
    @memcpy(&pageSizeBytes, walImage[8..12]);
    const pageSize = std.mem.readInt(u32, &pageSizeBytes, .big);
    if (pageSize < 512 or walImage.len < headerSize or (walImage.len - headerSize) % (frameHeaderSize + pageSize) != 0) return error.InvalidWal;
    const basePages = if (baseImage.len == 0) 0 else baseImage.len / pageSize;
    var pageCount: usize = basePages;
    var position: usize = headerSize;
    while (position < walImage.len) : (position += frameHeaderSize + pageSize) {
        var pageNumberBytes: [4]u8 = undefined;
        @memcpy(&pageNumberBytes, walImage[position .. position + 4]);
        const pageNumber = std.mem.readInt(u32, &pageNumberBytes, .big);
        if (pageNumber == 0) return error.InvalidWal;
        pageCount = @max(pageCount, @as(usize, pageNumber));
    }
    const result = try allocator.alloc(u8, pageCount * pageSize);
    errdefer allocator.free(result);
    @memset(result, 0);
    if (baseImage.len > 0) @memcpy(result[0..@min(baseImage.len, result.len)], baseImage[0..@min(baseImage.len, result.len)]);
    position = headerSize;
    while (position < walImage.len) : (position += frameHeaderSize + pageSize) {
        var pageNumberBytes: [4]u8 = undefined;
        @memcpy(&pageNumberBytes, walImage[position .. position + 4]);
        const pageNumber = std.mem.readInt(u32, &pageNumberBytes, .big);
        const destination = (@as(usize, pageNumber) - 1) * pageSize;
        @memcpy(result[destination .. destination + pageSize], walImage[position + frameHeaderSize .. position + frameHeaderSize + pageSize]);
    }
    return result;
}

test "WAL encodes and applies SQLite page frames" {
    const pageSize = 512;
    var image = [_]u8{0} ** (pageSize * 2);
    image[0] = 'S';
    image[pageSize + 7] = 42;
    const encoded = try encodeImage(std.testing.allocator, &image, pageSize);
    defer std.testing.allocator.free(encoded);
    var base = [_]u8{0} ** (pageSize * 2);
    const applied = try apply(std.testing.allocator, &base, encoded);
    defer std.testing.allocator.free(applied);
    try std.testing.expectEqual(@as(u8, 'S'), applied[0]);
    try std.testing.expectEqual(@as(u8, 42), applied[pageSize + 7]);
}
