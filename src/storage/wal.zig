const std = @import("std");

pub const frame_header_size = 24;
pub const FrameHeader = struct {
    page_number: u32,
    database_size: u32,
    checksum_1: u32,
    checksum_2: u32,

    pub fn encode(self: FrameHeader, out: *[frame_header_size]u8) void {
        std.mem.writeInt(u32, out[0..4], self.page_number, .big);
        std.mem.writeInt(u32, out[4..8], self.database_size, .big);
        std.mem.writeInt(u32, out[8..12], self.checksum_1, .big);
        std.mem.writeInt(u32, out[12..16], self.checksum_2, .big);
        @memset(out[16..], 0);
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

test "WAL checksum is deterministic" {
    const first = checksum(1, 2, "page");
    const second = checksum(1, 2, "page");
    try std.testing.expectEqual(first, second);
}
