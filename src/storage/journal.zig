const std = @import("std");

pub const headerSize = 28;

pub const magic = [_]u8{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7 };

pub const JournalHeader = struct {
    pageCount: u32 = 0,
    sectorSize: u32 = 512,
    pageSize: u32 = 4096,

    pub fn encode(self: JournalHeader, out: *[headerSize]u8) void {
        @memset(out, 0);
        @memcpy(out[0..8], &magic);
        std.mem.writeInt(u32, out[8..12], self.pageCount, .big);
        std.mem.writeInt(u32, out[12..16], self.sectorSize, .big);
        std.mem.writeInt(u32, out[16..20], self.pageSize, .big);
    }

    pub fn decode(bytes: []const u8) error{InvalidJournal}!JournalHeader {
        if (bytes.len < headerSize) return error.InvalidJournal;
        if (!std.mem.eql(u8, bytes[0..8], &magic)) return error.InvalidJournal;
        const pageCount = std.mem.readInt(u32, bytes[8..12], .big);
        const sectorSize = std.mem.readInt(u32, bytes[12..16], .big);
        const pageSize = std.mem.readInt(u32, bytes[16..20], .big);
        if (pageSize < 512 or pageSize > 32768 or (pageSize & (pageSize - 1)) != 0) return error.InvalidJournal;
        if (sectorSize != 0 and (sectorSize < 512 or sectorSize > 65536 or (sectorSize & (sectorSize - 1)) != 0)) return error.InvalidJournal;
        return .{ .pageCount = pageCount, .sectorSize = sectorSize, .pageSize = pageSize };
    }
};

test "rollback journal header encodes page geometry" {
    var bytes: [headerSize]u8 = undefined;
    (JournalHeader{ .pageSize = 8192 }).encode(&bytes);
    try std.testing.expectEqualSlices(u8, &magic, bytes[0..8]);
    try std.testing.expectEqual(@as(u32, 8192), std.mem.readInt(u32, bytes[16..20], .big));
    const parsed = try JournalHeader.decode(&bytes);
    try std.testing.expectEqual(@as(u32, 8192), parsed.pageSize);
    try std.testing.expectEqual(@as(u32, 512), parsed.sectorSize);
}

test "rollback journal header rejects bad magic geometry and truncation" {
    var bytes: [headerSize]u8 = undefined;
    (JournalHeader{}).encode(&bytes);
    var badMagic = bytes;
    badMagic[3] ^= 0xff;
    try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&badMagic));
    var badSize = bytes;
    std.mem.writeInt(u32, badSize[16..20], 100, .big);
    try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&badSize));
    var badSector = bytes;
    std.mem.writeInt(u32, badSector[12..16], 100, .big);
    try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&badSector));
    try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(bytes[0..27]));
    try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&[_]u8{}));
}
