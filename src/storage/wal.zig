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

    pub fn decode(bytes: []const u8) error{InvalidWal}!WalHeader {
        if (bytes.len < headerSize) return error.InvalidWal;
        if (std.mem.readInt(u32, bytes[0..4], .big) != magic) return error.InvalidWal;
        if (std.mem.readInt(u32, bytes[4..8], .big) != formatVersion) return error.InvalidWal;
        const pageSize = std.mem.readInt(u32, bytes[8..12], .big);
        if (pageSize < 512 or pageSize > 32768 or (pageSize & (pageSize - 1)) != 0) return error.InvalidWal;
        const sums = checksum(0, 0, bytes[0..24]);
        if (sums[0] != std.mem.readInt(u32, bytes[24..28], .big) or sums[1] != std.mem.readInt(u32, bytes[28..32], .big)) return error.InvalidWal;
        return .{
            .pageSize = pageSize,
            .checkpointSequence = std.mem.readInt(u32, bytes[12..16], .big),
            .salt1 = std.mem.readInt(u32, bytes[16..20], .big),
            .salt2 = std.mem.readInt(u32, bytes[20..24], .big),
            .checksum1 = sums[0],
            .checksum2 = sums[1],
        };
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
    if (pageSize < 512 or pageSize > 32768 or (pageSize & (pageSize - 1)) != 0 or image.len == 0 or image.len % pageSize != 0) return error.InvalidPageSize;
    const pageCount: u32 = @intCast(image.len / pageSize);
    var header: [headerSize]u8 = undefined;
    (WalHeader{ .pageSize = @intCast(pageSize) }).encode(&header);
    const result = try allocator.alloc(u8, headerSize + @as(usize, pageCount) * (frameHeaderSize + pageSize));
    errdefer allocator.free(result);
    @memcpy(result[0..headerSize], &header);
    // Frame checksums chain from the header checksum (frame header bytes
    // 0..8, i.e. page number plus commit size, then the page image; salts
    // are compared for equality, not checksummed).
    var previous = [2]u32{ std.mem.readInt(u32, header[24..28], .big), std.mem.readInt(u32, header[28..32], .big) };
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

pub const maxRecoveryBytes: usize = 256 * 1024 * 1024;

pub fn apply(allocator: std.mem.Allocator, baseImage: []const u8, walImage: []const u8) ![]u8 {
    // Recovery validation: masked magic, format version, power-of-two page
    // size in range, header checksum, per-frame salt equality, non-zero
    // page numbers, and the chained frame checksums.
    // Anything malformed is a controlled InvalidWal, never a panic, an
    // out-of-bounds access, or an unbounded allocation. Big-endian
    // checksummed WALs (magic LSB set) are rejected: this engine only
    // verifies the little-endian checksum variant it also writes.
    if (walImage.len < headerSize) return error.InvalidWal;
    if (std.mem.readInt(u32, walImage[0..4], .big) & 0xfffffffe != magic) return error.InvalidWal;
    if (std.mem.readInt(u32, walImage[0..4], .big) & 1 != 0) return error.InvalidWal;
    const header = try WalHeader.decode(walImage);
    const pageSize: usize = header.pageSize;
    if ((walImage.len - headerSize) % (frameHeaderSize + pageSize) != 0) return error.InvalidWal;
    const basePages = if (baseImage.len == 0) 0 else baseImage.len / pageSize;
    var pageCount: usize = basePages;
    var position: usize = headerSize;
    var running = [2]u32{ header.checksum1, header.checksum2 };
    while (position < walImage.len) : (position += frameHeaderSize + pageSize) {
        if (position + frameHeaderSize + pageSize > walImage.len) return error.InvalidWal;
        const frame = walImage[position .. position + frameHeaderSize];
        const pageNumber = std.mem.readInt(u32, frame[0..4], .big);
        if (pageNumber == 0) return error.InvalidWal;
        if (std.mem.readInt(u32, frame[8..12], .big) != header.salt1 or std.mem.readInt(u32, frame[12..16], .big) != header.salt2) return error.InvalidWal;
        running = checksum(running[0], running[1], frame[0..8]);
        running = checksum(running[0], running[1], walImage[position + frameHeaderSize .. position + frameHeaderSize + pageSize]);
        if (running[0] != std.mem.readInt(u32, frame[16..20], .big) or running[1] != std.mem.readInt(u32, frame[20..24], .big)) return error.InvalidWal;
        pageCount = @max(pageCount, @as(usize, pageNumber));
    }
    const total = std.math.mul(usize, pageCount, pageSize) catch return error.InvalidWal;
    if (total > maxRecoveryBytes) return error.InvalidWal;
    const result = try allocator.alloc(u8, total);
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

test "WAL header decode rejects bad magic version geometry and checksum" {
    var good: [headerSize]u8 = undefined;
    (WalHeader{ .pageSize = 512 }).encode(&good);
    const parsed = try WalHeader.decode(&good);
    try std.testing.expectEqual(@as(u32, 512), parsed.pageSize);
    var badMagic = good;
    badMagic[0] ^= 0xff;
    try std.testing.expectError(error.InvalidWal, WalHeader.decode(&badMagic));
    var badVersion = good;
    badVersion[7] ^= 0xff;
    try std.testing.expectError(error.InvalidWal, WalHeader.decode(&badVersion));
    var badSize = good;
    badSize[11] = 100; // 500: below minimum and not a power of two
    try std.testing.expectError(error.InvalidWal, WalHeader.decode(&badSize));
    var badSum = good;
    badSum[30] ^= 0x01;
    try std.testing.expectError(error.InvalidWal, WalHeader.decode(&badSum));
    try std.testing.expectError(error.InvalidWal, WalHeader.decode(good[0..31]));
}

test "WAL apply rejects corrupt frames without unsafe behavior" {
    const pageSize = 512;
    var image = [_]u8{0} ** pageSize;
    image[3] = 0xab;
    const encoded = try encodeImage(std.testing.allocator, &image, pageSize);
    defer std.testing.allocator.free(encoded);
    var base = [_]u8{0} ** pageSize;
    // Truncations fail closed, except the exact end-of-header prefix, which
    // is a valid zero-frame WAL that applies to a copy of the base image.
    var cut: usize = 1;
    while (cut < encoded.len) : (cut += 1) {
        const partial = encoded[0..cut];
        if (cut == headerSize) {
            const ok = try apply(std.testing.allocator, &base, partial);
            defer std.testing.allocator.free(ok);
            try std.testing.expectEqualSlices(u8, &base, ok);
        } else {
            try std.testing.expectError(error.InvalidWal, apply(std.testing.allocator, &base, partial));
        }
    }
    // Flipping any header, salt, checksum, or page-number byte breaks recovery.
    const flipSpots = [_]usize{ 0, 10, 26, headerSize + 0, headerSize + 9, headerSize + 17, headerSize + 24 };
    for (flipSpots) |spot| {
        var broken = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(broken);
        broken[spot] ^= 0xff;
        try std.testing.expectError(error.InvalidWal, apply(std.testing.allocator, &base, broken));
    }
    // Big-endian-checksummed WALs (magic LSB set) are rejected rather than
    // mis-verified: only the little-endian variant is supported.
    {
        var bigEndian = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(bigEndian);
        bigEndian[3] |= 0x01;
        try std.testing.expectError(error.InvalidWal, apply(std.testing.allocator, &base, bigEndian));
    }
    // A huge page number cannot force a huge allocation: recompute valid
    // checksums around it so only the recovery bound can reject the WAL.
    {
        const parsed = try WalHeader.decode(encoded[0..headerSize]);
        var huge = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(huge);
        std.mem.writeInt(u32, huge[headerSize .. headerSize + 4][0..4], 0xffffffff, .big);
        var chain = [2]u32{ parsed.checksum1, parsed.checksum2 };
        chain = checksum(chain[0], chain[1], huge[headerSize .. headerSize + 8]);
        chain = checksum(chain[0], chain[1], huge[headerSize + frameHeaderSize .. headerSize + frameHeaderSize + pageSize]);
        std.mem.writeInt(u32, huge[headerSize + 16 .. headerSize + 20][0..4], chain[0], .big);
        std.mem.writeInt(u32, huge[headerSize + 20 .. headerSize + 24][0..4], chain[1], .big);
        try std.testing.expectError(error.InvalidWal, apply(std.testing.allocator, &base, huge));
    }
}
