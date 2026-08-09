const std = @import("std");

pub const header_size = 32;
pub const frame_header_size = 24;
pub const format_version: u32 = 3007000;
pub const magic: u32 = 0x377f0682;

pub const WalHeader = struct {
    page_size: u32,
    checkpoint_sequence: u32 = 0,
    salt_1: u32 = 0x51f15eed,
    salt_2: u32 = 0x9e3779b9,
    checksum_1: u32 = 0,
    checksum_2: u32 = 0,

    pub fn encode(self: WalHeader, out: *[header_size]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], magic, .big);
        std.mem.writeInt(u32, out[4..8], format_version, .big);
        std.mem.writeInt(u32, out[8..12], self.page_size, .big);
        std.mem.writeInt(u32, out[12..16], self.checkpoint_sequence, .big);
        std.mem.writeInt(u32, out[16..20], self.salt_1, .big);
        std.mem.writeInt(u32, out[20..24], self.salt_2, .big);
        const sums = checksum(0, 0, out[0..24]);
        std.mem.writeInt(u32, out[24..28], sums[0], .big);
        std.mem.writeInt(u32, out[28..32], sums[1], .big);
    }
};

pub const FrameHeader = struct {
    page_number: u32,
    database_size: u32,
    salt_1: u32,
    salt_2: u32,
    checksum_1: u32,
    checksum_2: u32,

    pub fn encode(self: FrameHeader, out: *[frame_header_size]u8) void {
        std.mem.writeInt(u32, out[0..4], self.page_number, .big);
        std.mem.writeInt(u32, out[4..8], self.database_size, .big);
        std.mem.writeInt(u32, out[8..12], self.salt_1, .big);
        std.mem.writeInt(u32, out[12..16], self.salt_2, .big);
        std.mem.writeInt(u32, out[16..20], self.checksum_1, .big);
        std.mem.writeInt(u32, out[20..24], self.checksum_2, .big);
    }
};

pub fn checksum(seed_1: u32, seed_2: u32, bytes: []const u8) [2]u32 {
    var first = seed_1;
    var second = seed_2;
    var index: usize = 0;
    while (index + 3 < bytes.len) : (index += 4) {
        first +%= (@as(u32, bytes[index]) << 24) | (@as(u32, bytes[index + 1]) << 16) | (@as(u32, bytes[index + 2]) << 8) | bytes[index + 3];
        second +%= first;
    }
    return .{ first, second };
}

pub fn encodeImage(allocator: std.mem.Allocator, image: []const u8, page_size: usize) ![]u8 {
    if (page_size < 512 or image.len == 0 or image.len % page_size != 0) return error.InvalidPageSize;
    const page_count: u32 = @intCast(image.len / page_size);
    var header: [header_size]u8 = undefined;
    (WalHeader{ .page_size = @intCast(page_size) }).encode(&header);
    const result = try allocator.alloc(u8, header_size + @as(usize, page_count) * (frame_header_size + page_size));
    errdefer allocator.free(result);
    @memcpy(result[0..header_size], &header);
    var previous = [2]u32{ 0, 0 };
    var position: usize = header_size;
    for (0..page_count) |page_index| {
        var frame_input = try allocator.alloc(u8, 8 + page_size);
        defer allocator.free(frame_input);
        std.mem.writeInt(u32, frame_input[0..4], @intCast(page_index + 1), .big);
        std.mem.writeInt(u32, frame_input[4..8], if (page_index == 0) page_count else 0, .big);
        @memcpy(frame_input[8..], image[page_index * page_size .. (page_index + 1) * page_size]);
        const sums = checksum(previous[0], previous[1], frame_input);
        var frame_header: [frame_header_size]u8 = undefined;
        (FrameHeader{ .page_number = @intCast(page_index + 1), .database_size = if (page_index == 0) page_count else 0, .salt_1 = std.mem.readInt(u32, header[16..20], .big), .salt_2 = std.mem.readInt(u32, header[20..24], .big), .checksum_1 = sums[0], .checksum_2 = sums[1] }).encode(&frame_header);
        @memcpy(result[position .. position + frame_header_size], &frame_header);
        position += frame_header_size;
        @memcpy(result[position .. position + page_size], image[page_index * page_size .. (page_index + 1) * page_size]);
        position += page_size;
        previous = sums;
    }
    return result;
}

pub fn apply(allocator: std.mem.Allocator, base_image: []const u8, wal_image: []const u8) ![]u8 {
    if (wal_image.len < header_size) return error.InvalidWal;
    var page_size_bytes: [4]u8 = undefined;
    @memcpy(&page_size_bytes, wal_image[8..12]);
    const page_size = std.mem.readInt(u32, &page_size_bytes, .big);
    if (page_size < 512 or wal_image.len < header_size or (wal_image.len - header_size) % (frame_header_size + page_size) != 0) return error.InvalidWal;
    const base_pages = if (base_image.len == 0) 0 else base_image.len / page_size;
    var page_count: usize = base_pages;
    var position: usize = header_size;
    while (position < wal_image.len) : (position += frame_header_size + page_size) {
        var page_number_bytes: [4]u8 = undefined;
        @memcpy(&page_number_bytes, wal_image[position .. position + 4]);
        const page_number = std.mem.readInt(u32, &page_number_bytes, .big);
        if (page_number == 0) return error.InvalidWal;
        page_count = @max(page_count, @as(usize, page_number));
    }
    const result = try allocator.alloc(u8, page_count * page_size);
    errdefer allocator.free(result);
    @memset(result, 0);
    if (base_image.len > 0) @memcpy(result[0..@min(base_image.len, result.len)], base_image[0..@min(base_image.len, result.len)]);
    position = header_size;
    while (position < wal_image.len) : (position += frame_header_size + page_size) {
        var page_number_bytes: [4]u8 = undefined;
        @memcpy(&page_number_bytes, wal_image[position .. position + 4]);
        const page_number = std.mem.readInt(u32, &page_number_bytes, .big);
        const destination = (@as(usize, page_number) - 1) * page_size;
        @memcpy(result[destination .. destination + page_size], wal_image[position + frame_header_size .. position + frame_header_size + page_size]);
    }
    return result;
}

test "WAL encodes and applies SQLite page frames" {
    const page_size = 512;
    var image = [_]u8{0} ** (page_size * 2);
    image[0] = 'S';
    image[page_size + 7] = 42;
    const encoded = try encodeImage(std.testing.allocator, &image, page_size);
    defer std.testing.allocator.free(encoded);
    var base = [_]u8{0} ** (page_size * 2);
    const applied = try apply(std.testing.allocator, &base, encoded);
    defer std.testing.allocator.free(applied);
    try std.testing.expectEqual(@as(u8, 'S'), applied[0]);
    try std.testing.expectEqual(@as(u8, 42), applied[page_size + 7]);
}
