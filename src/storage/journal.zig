const std = @import("std");

pub const headerSize = 28;
pub const JournalHeader = struct {
    pageCount: u32 = 0,
    sectorSize: u32 = 512,
    pageSize: u32 = 4096,

    pub fn encode(self: JournalHeader, out: *[headerSize]u8) void {
        @memset(out, 0);
        std.mem.writeInt(u32, out[0..4], self.pageCount, .big);
        std.mem.writeInt(u32, out[4..8], self.sectorSize, .big);
        std.mem.writeInt(u32, out[8..12], self.pageSize, .big);
    }
};

test "rollback journal header encodes page geometry" {
    var bytes: [headerSize]u8 = undefined;
    (JournalHeader{ .pageSize = 8192 }).encode(&bytes);
    try std.testing.expectEqual(@as(u32, 8192), std.mem.readInt(u32, bytes[8..12], .big));
}
