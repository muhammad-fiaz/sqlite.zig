//! Rollback-journal header codec plus page-record framing.
//!
//! `encode` fills a caller buffer; `decode` borrows its input.
//! Bad magic or geometry fails with `InvalidJournal`.

const std = @import("std");
const limits = @import("../sql/limits.zig");

/// Journal header length in bytes.
pub const headerSize = 28;

/// Magic prefix identifying a SQLite rollback journal.
pub const magic = [_]u8{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7 };

/// Per-page record header: big-endian page number.
pub const pageRecordHeaderSize = 4;

/// Maximum journal payload we will allocate during recovery.
pub const maxJournalBytes: usize = 256 * 1024 * 1024;

/// In-memory view of the journal header, laid out exactly as SQLite's
/// `readJournalHdr` in `pager.c` expects: magic, record count, checksum
/// nonce, database size at transaction start, sector size, page size.
/// `nonce`/`dbSize`/`pageCount` are informational (any u32 survives the
/// round trip); geometry is validated on decode. Zero `sectorSize` means
/// no alignment.
pub const JournalHeader = struct {
    /// Number of page records following this header (informational).
    pageCount: u32 = 0,
    /// Checksum randomizer for the following records (informational).
    nonce: u32 = 0,
    /// Database size in pages when the transaction started (informational).
    dbSize: u32 = 0,
    /// Device sector size, or 0 for "no constraint".
    sectorSize: u32 = 512,
    /// Database page size (must match the main file).
    pageSize: u32 = 4096,

    /// Serializes into `out` (no failure modes; all 28 bytes assigned).
    pub fn encode(self: JournalHeader, out: *[headerSize]u8) void {
        @memcpy(out[0..8], &magic);
        std.mem.writeInt(u32, out[8..12], self.pageCount, .big);
        std.mem.writeInt(u32, out[12..16], self.nonce, .big);
        std.mem.writeInt(u32, out[16..20], self.dbSize, .big);
        std.mem.writeInt(u32, out[20..24], self.sectorSize, .big);
        std.mem.writeInt(u32, out[24..28], self.pageSize, .big);
    }

    /// Parses and validates a journal header.
    /// Bad magic, truncation, or geometry fails here because it would
    /// corrupt recovery.
    pub fn decode(bytes: []const u8) error{InvalidJournal}!JournalHeader {
        if (bytes.len < headerSize) return error.InvalidJournal;
        if (!std.mem.eql(u8, bytes[0..8], &magic)) return error.InvalidJournal;
        const pageCount = std.mem.readInt(u32, bytes[8..12], .big);
        const nonce = std.mem.readInt(u32, bytes[12..16], .big);
        const dbSize = std.mem.readInt(u32, bytes[16..20], .big);
        const sectorSize = std.mem.readInt(u32, bytes[20..24], .big);
        const pageSize = std.mem.readInt(u32, bytes[24..28], .big);
        if (pageSize < 512 or pageSize > limits.max_page_size or (pageSize & (pageSize - 1)) != 0) return error.InvalidJournal;
        // Sector sizes follow the reference (`readJournalHdr` in `pager.c`):
        // powers of two in 32..65536. Zero stays accepted as this engine's
        // "no constraint" marker (the reference writer never emits it).
        if (sectorSize != 0 and (sectorSize < 32 or sectorSize > 65536 or (sectorSize & (sectorSize - 1)) != 0)) return error.InvalidJournal;
        return .{ .pageCount = pageCount, .nonce = nonce, .dbSize = dbSize, .sectorSize = sectorSize, .pageSize = pageSize };
    }
};

/// Builds a rollback journal image: header plus one record per journaled page.
/// Every record stores the full page image (including page 1's 100-byte
/// database header), matching `pager.c`.
pub fn encodeJournal(
    allocator: std.mem.Allocator,
    oldImage: []const u8,
    pageSize: u32,
    nonce: u32,
) ![]u8 {
    if (pageSize < 512 or pageSize > limits.max_page_size or (pageSize & (pageSize - 1)) != 0) return error.InvalidJournal;
    if (oldImage.len < pageSize) return error.InvalidJournal;
    const pageCount: u32 = @intCast(@divFloor(oldImage.len, pageSize));
    if (pageCount == 0) return error.InvalidJournal;
    const recordSize = pageRecordHeaderSize + pageSize;
    const total = headerSize + @as(usize, pageCount) * recordSize;
    if (total > maxJournalBytes) return error.InvalidJournal;
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    const hdr = JournalHeader{
        .pageCount = pageCount,
        .nonce = nonce,
        .dbSize = pageCount,
        .sectorSize = 512,
        .pageSize = pageSize,
    };
    hdr.encode(out[0..headerSize]);
    var offset: usize = headerSize;
    var pageNo: u32 = 1;
    while (pageNo <= pageCount) : (pageNo += 1) {
        std.mem.writeInt(u32, out[offset .. offset + 4][0..4], pageNo, .big);
        const pageStart = @as(usize, pageNo - 1) * pageSize;
        // Full page image including page 1's database header (pager.c
        // writes `pageSize` bytes per record for every page).
        @memcpy(out[offset + 4 .. offset + 4 + pageSize], oldImage[pageStart .. pageStart + pageSize]);
        offset += recordSize;
    }
    return out;
}

/// One decoded page record: 1-based page number plus the full journaled
/// page image (including page 1's database header).
pub const PageRecord = struct { pageNumber: u32, data: []const u8 };

/// Applies journal page records onto `image` (in place), restoring the
/// pre-transaction state. `image` must already be large enough for every
/// journaled page.
pub fn applyJournal(image: []u8, bytes: []const u8) error{InvalidJournal}!void {
    const header = try JournalHeader.decode(bytes);
    const pageSize: usize = header.pageSize;
    const recordSize = pageRecordHeaderSize + pageSize;
    const body = bytes[headerSize..];
    if (body.len != @as(usize, header.pageCount) * recordSize) return error.InvalidJournal;
    var offset: usize = 0;
    var i: u32 = 0;
    while (i < header.pageCount) : (i += 1) {
        const pageNo = std.mem.readInt(u32, body[offset .. offset + 4][0..4], .big);
        if (pageNo == 0) return error.InvalidJournal;
        const pageStart = @as(usize, pageNo - 1) * pageSize;
        if (pageStart + pageSize > image.len) return error.InvalidJournal;
        @memcpy(image[pageStart .. pageStart + pageSize], body[offset + 4 .. offset + 4 + pageSize]);
        offset += recordSize;
    }
}

test "journal page records round-trip and restore a mutated image" {
    const allocator = std.testing.allocator;
    const pageSize: u32 = 512;
    const pageCount: u32 = 3;
    const original = try allocator.alloc(u8, pageSize * pageCount);
    defer allocator.free(original);
    for (original, 0..) |*byte, index| byte.* = @truncate(index);
    // Stamp a recognizable page-1 header so the encode path includes it.
    @memcpy(original[0..16], "SQLite format 3\x00");
    const journalBytes = try encodeJournal(allocator, original, pageSize, 0xAABBCCDD);
    defer allocator.free(journalBytes);
    const hdr = try JournalHeader.decode(journalBytes);
    try std.testing.expectEqual(pageCount, hdr.pageCount);
    try std.testing.expectEqual(pageSize, hdr.pageSize);
    try std.testing.expectEqual(0xAABBCCDD, hdr.nonce);
    // Expected size: header + pageCount * (4 + pageSize).
    try std.testing.expectEqual(headerSize + pageCount * (pageRecordHeaderSize + pageSize), journalBytes.len);
    // Mutate the image, then restore from the journal.
    const mutated = try allocator.dupe(u8, original);
    defer allocator.free(mutated);
    @memset(mutated, 0xEE);
    try applyJournal(mutated, journalBytes);
    // Full pages including page 1's database header restore completely
    // (pager.c journals `pageSize` bytes for every page record).
    try std.testing.expectEqualSlices(u8, original, mutated);
}

test "journal apply rejects truncated and corrupt records" {
    const allocator = std.testing.allocator;
    const original = try allocator.alloc(u8, 512 * 2);
    defer allocator.free(original);
    @memset(original, 0x42);
    @memcpy(original[0..16], "SQLite format 3\x00");
    const journalBytes = try encodeJournal(allocator, original, 512, 1);
    defer allocator.free(journalBytes);
    const image = try allocator.dupe(u8, original);
    defer allocator.free(image);
    @memset(image, 0);
    try std.testing.expectError(error.InvalidJournal, applyJournal(image, journalBytes[0 .. journalBytes.len - 1]));
    try std.testing.expectError(error.InvalidJournal, applyJournal(image, journalBytes[0 .. headerSize + 3]));
    var badMagic = try allocator.dupe(u8, journalBytes);
    defer allocator.free(badMagic);
    badMagic[0] ^= 0xff;
    try std.testing.expectError(error.InvalidJournal, applyJournal(image, badMagic));
    // Page 0 in a record is rejected.
    var badPage = try allocator.dupe(u8, journalBytes);
    defer allocator.free(badPage);
    std.mem.writeInt(u32, badPage[headerSize .. headerSize + 4][0..4], 0, .big);
    try std.testing.expectError(error.InvalidJournal, applyJournal(image, badPage));
    // Empty image fails the header decode.
    try std.testing.expectError(error.InvalidJournal, applyJournal(image, &[_]u8{}));
}

test "rollback journal header matches the reference byte layout" {
    // Byte-exact vector per `readJournalHdr` in `pager.c`: magic, nRec=2,
    // nonce, dbSize=5, sector=512, page=4096.
    const vector = [_]u8{ 0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7, 0x00, 0x00, 0x00, 0x02, 0x12, 0x34, 0x56, 0x78, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x10, 0x00 };
    const parsed = try JournalHeader.decode(&vector);
    try std.testing.expectEqual(@as(u32, 2), parsed.pageCount);
    try std.testing.expectEqual(@as(u32, 0x12345678), parsed.nonce);
    try std.testing.expectEqual(@as(u32, 5), parsed.dbSize);
    try std.testing.expectEqual(@as(u32, 512), parsed.sectorSize);
    try std.testing.expectEqual(@as(u32, 4096), parsed.pageSize);
    var bytes: [headerSize]u8 = undefined;
    (JournalHeader{ .pageCount = 2, .nonce = 0x12345678, .dbSize = 5, .sectorSize = 512, .pageSize = 4096 }).encode(&bytes);
    try std.testing.expectEqualSlices(u8, &vector, &bytes);
}

test "rollback journal header encodes page geometry" {
    var bytes: [headerSize]u8 = undefined;
    (JournalHeader{ .pageSize = 8192 }).encode(&bytes);
    try std.testing.expectEqualSlices(u8, &magic, bytes[0..8]);
    try std.testing.expectEqual(@as(u32, 8192), std.mem.readInt(u32, bytes[24..28], .big));
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
    std.mem.writeInt(u32, badSize[24..28], 100, .big);
    try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&badSize));
    var badSector = bytes;
    std.mem.writeInt(u32, badSector[20..24], 100, .big);
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
    const validSizes = [_]u32{ 512, 1024, 4096, 32768, 65536 };
    for (validSizes) |ps| {
        var buf: [headerSize]u8 = undefined;
        (JournalHeader{ .pageSize = ps }).encode(&buf);
        try std.testing.expectEqual(ps, (try JournalHeader.decode(&buf)).pageSize);
    }
    const invalidSizes = [_]u32{ 0, 100, 511, 513, 1000, 32769, 131072 };
    for (invalidSizes) |ps| {
        var buf: [headerSize]u8 = undefined;
        (JournalHeader{}).encode(&buf);
        std.mem.writeInt(u32, buf[24..28], ps, .big);
        try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&buf));
    }
    // Boundary: sector sizes accept 0 and powers of two in 32..65536 only.
    const validSectors = [_]u32{ 0, 32, 64, 512, 4096, 65536 };
    for (validSectors) |ss| {
        var buf: [headerSize]u8 = undefined;
        (JournalHeader{ .sectorSize = ss }).encode(&buf);
        try std.testing.expectEqual(ss, (try JournalHeader.decode(&buf)).sectorSize);
    }
    var badSector: [headerSize]u8 = undefined;
    (JournalHeader{}).encode(&badSector);
    std.mem.writeInt(u32, badSector[20..24], 70000, .big);
    try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&badSector));
    var smallSector: [headerSize]u8 = undefined;
    (JournalHeader{}).encode(&smallSector);
    std.mem.writeInt(u32, smallSector[20..24], 16, .big);
    try std.testing.expectError(error.InvalidJournal, JournalHeader.decode(&smallSector));
}
