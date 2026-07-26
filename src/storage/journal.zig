const std = @import("std");

pub const header_size = 28;
pub const JournalHeader = struct {
    page_count: u32 = 0,
    sector_size: u32 = 512,
    page_size: u32 = 4096,

    pub fn encode(self: JournalHeader, out: *[header_size]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], self.page_count, .big);
        std.mem.writeInt(u32, out[4..8], self.sector_size, .big);
        std.mem.writeInt(u32, out[8..12], self.page_size, .big);
    }
};

test "rollback journal header encodes page geometry" {
    var bytes: [header_size]u8 = undefined;
    (JournalHeader{ .page_size = 8192 }).encode(&bytes);
    try std.testing.expectEqual(@as(u32, 8192), std.mem.readInt(u32, bytes[8..12], .big));
}
