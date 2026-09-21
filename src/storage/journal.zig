//! Rollback-journal header codec.
//!
//! `encode` fills a caller buffer; `decode` borrows its input.
//! Bad magic or geometry fails with `InvalidJournal`.

const std = @import("std");

/// Journal header length in bytes.
pub const headerSize = 28;

/// Magic prefix identifying a SQLite rollback journal.
pub const magic = [_]u8{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7 };

/// In-memory view of the journal header.
/// Zero `sectorSize` means no alignment; `pageCount` is informational.
pub const JournalHeader = struct {
    /// Number of page records claimed to follow (informational).
    pageCount: u32 = 0,
    /// Device sector size, or 0 for "no constraint".
    sectorSize: u32 = 512,
    /// Database page size (must match the main file).
    pageSize: u32 = 4096,

    /// Serializes into `out` (trailing bytes zeroed; no failure modes).
    pub fn encode(self: JournalHeader, out: *[headerSize]u8) void {
        @memset(out, 0);
        @memcpy(out[0..8], &magic);
        std.mem.writeInt(u32, out[8..12], self.pageCount, .big);
        std.mem.writeInt(u32, out[12..16], self.sectorSize, .big);
        std.mem.writeInt(u32, out[16..20], self.pageSize, .big);
    }

    /// Parses and validates a journal header.
    /// Bad geometry fails here because it would corrupt recovery.
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

test "rollback journal header covers sector-size edges and page counts" {
    // Normal: zero sector size is legal (means "no sector constraint").
    var zero: [headerSize]u8 = undefined;
    (JournalHeader{ .pageCount = 3, .sectorSize = 0, .pageSize = 1024 }).encode(&zero);
    const parsedZero = try JournalHeader.decode(&zero);
    try std.testing.expectEqual(@as(u32, 0), parsedZero.sectorSize);
    try std.testing.expectEqual(@as(u32, 3), parsedZero.pageCount);
    try std.testing.expectEqual(@as(u32, 1024), parsedZero.pageSize);
    // Boundary: every valid page size round-trips; neighbors are rejected.
    const validSizes = [_]u32{ 512, 1024, 4096, 32768 };
    for (validSizes) |ps| {
        var buf: [headerSize]u8 = undefined;
        (JournalHeader{ .pageSize = ps }).encode(&buf);
        try std.testing.expectEqual(ps, (try JournalHeader.decode(&buf)).pageSize);
    }
    const invalidSizes = [_]u32{ 0, 100, 511, 513, 1000, 32769, 65536 };
    for (invalidSizes) |ps| {
        var buf: [headerSize]u8 = undefined;
        (JournalHeader{}).encode(&buf);
        std.mem.writeInt(u32, buf[16..20], ps, .big);
        try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&buf));
    }
    // Boundary: sector sizes accept 0 and powers of two in 512..65536 only.
    const validSectors = [_]u32{ 0, 512, 4096, 65536 };
    for (validSectors) |ss| {
        var buf: [headerSize]u8 = undefined;
        (JournalHeader{ .sectorSize = ss }).encode(&buf);
        try std.testing.expectEqual(ss, (try JournalHeader.decode(&buf)).sectorSize);
    }
    var badSector: [headerSize]u8 = undefined;
    (JournalHeader{}).encode(&badSector);
    std.mem.writeInt(u32, badSector[12..16], 70000, .big);
    try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&badSector));
}
