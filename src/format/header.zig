const std = @import("std");

pub const size = 100;
pub const magic = "SQLite format 3\x00";

pub const Header = struct {
    pageSize: u16 = 4096,
    writeVersion: u8 = 1,
    readVersion: u8 = 1,
    reservedBytes: u8 = 0,
    payloadFraction: u8 = 64,
    largestPayloadFraction: u8 = 32,
    minPayloadFraction: u8 = 32,
    changeCounter: u32 = 0,
    databaseSizePages: u32 = 0,
    firstFreelistPage: u32 = 0,
    freelistPages: u32 = 0,
    schemaCookie: u32 = 0,
    schemaFormat: u32 = 4,
    textEncoding: u32 = 1,
    userVersion: u32 = 0,
    applicationId: u32 = 0,

    pub fn encode(self: Header, out: *[size]u8) void {
        @memset(out, 0);
        @memcpy(out[0..16], magic);
        std.mem.writeInt(u16, out[16..18], self.pageSize, .big);
        out[18] = self.writeVersion;
        out[19] = self.readVersion;
        out[20] = self.reservedBytes;
        out[21] = self.payloadFraction;
        out[22] = self.largestPayloadFraction;
        out[23] = self.minPayloadFraction;
        std.mem.writeInt(u32, out[24..28], self.changeCounter, .big);
        std.mem.writeInt(u32, out[28..32], self.databaseSizePages, .big);
        std.mem.writeInt(u32, out[32..36], self.firstFreelistPage, .big);
        std.mem.writeInt(u32, out[36..40], self.freelistPages, .big);
        std.mem.writeInt(u32, out[40..44], self.schemaCookie, .big);
        std.mem.writeInt(u32, out[44..48], self.schemaFormat, .big);
        std.mem.writeInt(u32, out[56..60], self.textEncoding, .big);
        std.mem.writeInt(u32, out[60..64], self.userVersion, .big);
        std.mem.writeInt(u32, out[68..72], self.applicationId, .big);
    }

    pub fn decode(bytes: *const [size]u8) error{InvalidHeader}!Header {
        if (!std.mem.eql(u8, bytes[0..16], magic)) return error.InvalidHeader;
        return .{
            .pageSize = std.mem.readInt(u16, bytes[16..18], .big),
            .writeVersion = bytes[18],
            .readVersion = bytes[19],
            .reservedBytes = bytes[20],
            .payloadFraction = bytes[21],
            .largestPayloadFraction = bytes[22],
            .minPayloadFraction = bytes[23],
            .changeCounter = std.mem.readInt(u32, bytes[24..28], .big),
            .databaseSizePages = std.mem.readInt(u32, bytes[28..32], .big),
            .firstFreelistPage = std.mem.readInt(u32, bytes[32..36], .big),
            .freelistPages = std.mem.readInt(u32, bytes[36..40], .big),
            .schemaCookie = std.mem.readInt(u32, bytes[40..44], .big),
            .schemaFormat = std.mem.readInt(u32, bytes[44..48], .big),
            .textEncoding = std.mem.readInt(u32, bytes[56..60], .big),
            .userVersion = std.mem.readInt(u32, bytes[60..64], .big),
            .applicationId = std.mem.readInt(u32, bytes[68..72], .big),
        };
    }
};

test "database header round trip" {
    var bytes: [size]u8 = undefined;
    const original = Header{ .pageSize = 8192, .databaseSizePages = 3, .textEncoding = 1 };
    original.encode(&bytes);
    const decoded = try Header.decode(&bytes);
    try std.testing.expectEqual(original.pageSize, decoded.pageSize);
    try std.testing.expectEqual(original.databaseSizePages, decoded.databaseSizePages);
}

test "database header rejects bad magic" {
    var bytes: [size]u8 = undefined;
    (Header{}).encode(&bytes);
    try std.testing.expectEqualStrings(magic, bytes[0..16]);
    bytes[0] ^= 0xff;
    try std.testing.expectError(error.InvalidHeader, Header.decode(&bytes));
    bytes[0] ^= 0xff;
    bytes[15] = 'X';
    try std.testing.expectError(error.InvalidHeader, Header.decode(&bytes));
}
