//! The 100-byte database file header on page 1.
//!
//! Encode and decode borrow fixed buffers and never allocate.
//! Bad magic fails with `InvalidHeader`.

const std = @import("std");

/// Length in bytes of the database header (always the page-1 prefix).
pub const size = 100;
/// File magic prefix identifying SQLite format 3 databases.
pub const magic = "SQLite format 3\x00";

/// In-memory view of the 100-byte database header.
pub const Header = struct {
    /// Database page size in bytes. A `u32` because 65536 does not fit the
    /// on-disk `u16`: per the file format, value 1 on disk encodes 65536.
    pageSize: u32 = 4096,
    /// File-format write version (1 = legacy rollback journal).
    writeVersion: u8 = 1,
    /// File-format read version (1 = legacy rollback journal).
    readVersion: u8 = 1,
    /// Bytes reserved at the end of each page (reduces usable page space).
    reservedBytes: u8 = 0,
    /// Target fraction (x/255) of payload kept on a leaf page.
    payloadFraction: u8 = 64,
    /// Overflow threshold numerator (x/255) for interior payload splits.
    largestPayloadFraction: u8 = 32,
    /// Minimum local payload fraction (x/255) kept on a page.
    minPayloadFraction: u8 = 32,
    /// File change counter (incremented per write transaction).
    changeCounter: u32 = 0,
    /// Size of the database in pages.
    databaseSizePages: u32 = 0,
    /// First freelist trunk page number (0 = none).
    firstFreelistPage: u32 = 0,
    /// Total number of freelist pages.
    freelistPages: u32 = 0,
    /// Schema cookie (bumped on schema change, used for cache invalidation).
    schemaCookie: u32 = 0,
    /// Schema format number (1..4; 4 supports WITHOUT ROWID etc.).
    schemaFormat: u32 = 4,
    /// Database text encoding: 1 = UTF-8, 2 = UTF-16LE, 3 = UTF-16BE.
    textEncoding: u32 = 1,
    /// PRAGMA user_version value.
    userVersion: u32 = 0,
    /// PRAGMA application_id value.
    applicationId: u32 = 0,

    /// Serializes the header into `out` (zero-fills reserved regions).
    ///
    /// Safety: `out` is a fixed `[size]u8` so all offsets are in bounds by
    /// construction; no allocation, no failure modes.
    pub fn encode(self: Header, out: *[size]u8) void {
        @memset(out, 0);
        @memcpy(out[0..16], magic);
        const diskSize: u16 = if (self.pageSize == 65536) 1 else @intCast(self.pageSize);
        std.mem.writeInt(u16, out[16..18], diskSize, .big);
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

    /// Parses a header, rejecting bad magic with `InvalidHeader`.
    /// A stored page size of 1 decodes to 65536 per the file format.
    /// Size validity (power of two in 512..65536) is checked by the file
    /// opener, not here, so readers stay permissive.
    pub fn decode(bytes: *const [size]u8) error{InvalidHeader}!Header {
        if (!std.mem.eql(u8, bytes[0..16], magic)) return error.InvalidHeader;
        const raw = std.mem.readInt(u16, bytes[16..18], .big);
        return .{
            .pageSize = if (raw == 1) 65536 else raw,
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

test "database header maps 65536 to on-disk 1 both ways" {
    // Reference file format: a 65536-byte page size is stored as u16 1.
    var bytes: [size]u8 = undefined;
    (Header{ .pageSize = 65536 }).encode(&bytes);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[16..18], .big));
    const decoded = try Header.decode(&bytes);
    try std.testing.expectEqual(@as(u32, 65536), decoded.pageSize);
    // Ordinary sizes pass through untouched.
    var small: [size]u8 = undefined;
    (Header{ .pageSize = 512 }).encode(&small);
    try std.testing.expectEqual(@as(u16, 512), std.mem.readInt(u16, small[16..18], .big));
    try std.testing.expectEqual(@as(u32, 512), (try Header.decode(&small)).pageSize);
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

test "database header round trips every field and zeroes reserved space" {
    var bytes: [size]u8 = undefined;
    const original = Header{
        .pageSize = 1024,
        .writeVersion = 2,
        .readVersion = 2,
        .reservedBytes = 7,
        .payloadFraction = 64,
        .largestPayloadFraction = 32,
        .minPayloadFraction = 32,
        .changeCounter = 0xdeadbeef,
        .databaseSizePages = 17,
        .firstFreelistPage = 5,
        .freelistPages = 2,
        .schemaCookie = 9,
        .schemaFormat = 4,
        .textEncoding = 1,
        .userVersion = 1234,
        .applicationId = 0x0badf00d,
    };
    original.encode(&bytes);
    // Normal: reserved regions stay zero so foreign readers see a clean file.
    for (bytes[48..56]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (bytes[72..100]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    const decoded = try Header.decode(&bytes);
    try std.testing.expectEqual(original.pageSize, decoded.pageSize);
    try std.testing.expectEqual(original.writeVersion, decoded.writeVersion);
    try std.testing.expectEqual(original.readVersion, decoded.readVersion);
    try std.testing.expectEqual(original.reservedBytes, decoded.reservedBytes);
    try std.testing.expectEqual(original.changeCounter, decoded.changeCounter);
    try std.testing.expectEqual(original.databaseSizePages, decoded.databaseSizePages);
    try std.testing.expectEqual(original.firstFreelistPage, decoded.firstFreelistPage);
    try std.testing.expectEqual(original.freelistPages, decoded.freelistPages);
    try std.testing.expectEqual(original.schemaCookie, decoded.schemaCookie);
    try std.testing.expectEqual(original.schemaFormat, decoded.schemaFormat);
    try std.testing.expectEqual(original.textEncoding, decoded.textEncoding);
    try std.testing.expectEqual(original.userVersion, decoded.userVersion);
    try std.testing.expectEqual(original.applicationId, decoded.applicationId);
    // Boundary: defaults encode the canonical fresh-database header.
    var fresh: [size]u8 = undefined;
    (Header{}).encode(&fresh);
    try std.testing.expectEqual(@as(u16, 4096), std.mem.readInt(u16, fresh[16..18], .big));
    try std.testing.expectEqual(@as(u8, 1), fresh[18]);
    // Error: magic is checked byte-exactly, including the NUL terminator.
    var badTail = bytes;
    badTail[15] = 0x01;
    try std.testing.expectError(error.InvalidHeader, Header.decode(&badTail));
}
