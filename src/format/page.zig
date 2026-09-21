//! B-tree page view: type byte plus the page-1 header offset.
//!
//! Purpose: minimal read/write accessor for a raw page image's type flag and
//! the 100-byte database-header reservation on page 1. Responsibilities: map
//! page numbers to header offsets, translate the flag byte to `PageType`.
//! Dependencies: `std` only. Ownership: `Page` borrows the caller's byte
//! slice (no allocation, no copying); mutations write through immediately.
//! Error behavior: `pageType` returns `null` for short buffers/unknown flags
//! (fail closed); `setPageType` returns `error.InvalidPage` on a short buffer
//! instead of writing out of bounds. Invariants: page numbers start at 1;
//! page 1 reserves the first 100 bytes for `format/header.zig`.
//! Compatibility: flag values (0x02/0x05/0x0a/0x0d) match SQLite.

const std = @import("std");

/// On-disk b-tree page kinds (interior vs leaf, table vs index).
pub const PageType = enum(u8) { tableInterior = 0x05, tableLeaf = 0x0d, indexInterior = 0x02, indexLeaf = 0x0a };

/// Borrowed view over one raw page image.
///
/// Why a view and not an owner: pages live in the pager/file cache; this
/// type only interprets memory owned elsewhere, so it must never outlive
/// `bytes` and never allocates.
pub const Page = struct {
    /// Raw page image (length should equal the database page size).
    bytes: []u8,
    /// 1-based page number (page 1 carries the database header).
    pageNumber: u32,

    /// Creates a view; no validation (use `pageType`/`setPageType` for that).
    pub fn init(bytes: []u8, pageNumber: u32) Page {
        return .{ .bytes = bytes, .pageNumber = pageNumber };
    }

    /// Byte offset where the b-tree header starts (100 on page 1).
    ///
    /// Why page 1 differs: the first 100 bytes hold the database header, so
    /// the b-tree cell-pointer array starts later there than on other pages.
    pub fn headerOffset(self: Page) usize {
        return if (self.pageNumber == 1) 100 else 0;
    }

    /// Reads the page-type flag, or `null` when the buffer is too short or
    /// the flag is not a known SQLite page kind (corrupt/foreign data stays
    /// safely unrecognized instead of misinterpreted).
    pub fn pageType(self: Page) ?PageType {
        const offset = self.headerOffset();
        if (offset >= self.bytes.len) return null;
        return std.enums.fromInt(PageType, self.bytes[offset]);
    }

    /// Writes the page-type flag.
    ///
    /// Safety: fails with `error.InvalidPage` when the buffer cannot hold
    /// the flag byte (empty slice, or < 101 bytes for page 1) instead of
    /// writing out of bounds. Page number 0 is rejected: pages are 1-based
    /// and 0 would alias page 1's data region while claiming no offset.
    pub fn setPageType(self: Page, kind: PageType) error{InvalidPage}!void {
        if (self.pageNumber == 0) return error.InvalidPage;
        const offset = self.headerOffset();
        if (offset >= self.bytes.len) return error.InvalidPage;
        self.bytes[offset] = @intFromEnum(kind);
    }
};

test "page one has a database header offset" {
    var bytes: [4096]u8 = std.mem.zeroes([4096]u8);
    var page = Page.init(&bytes, 1);
    try page.setPageType(.tableLeaf);
    try std.testing.expectEqual(@as(usize, 100), page.headerOffset());
    try std.testing.expectEqual(PageType.tableLeaf, page.pageType().?);
}

test "page types round trip and unknown types stay unknown" {
    var bytes: [512]u8 = std.mem.zeroes([512]u8);
    const kinds = [_]PageType{ .tableInterior, .tableLeaf, .indexInterior, .indexLeaf };
    for (kinds) |kind| {
        var page = Page.init(&bytes, 7);
        try std.testing.expectEqual(@as(usize, 0), page.headerOffset());
        try page.setPageType(kind);
        try std.testing.expectEqual(kind, page.pageType().?);
    }
    bytes[0] = 0x09; // no SQLite page type uses this flag byte
    try std.testing.expect(Page.init(&bytes, 7).pageType() == null);
    // A short buffer can never yield a page type: untrusted sizes stay safe.
    var tiny: [0]u8 = .{};
    try std.testing.expect(Page.init(&tiny, 2).pageType() == null);
    var short: [99]u8 = std.mem.zeroes([99]u8);
    try std.testing.expect(Page.init(&short, 1).pageType() == null);
}

test "page setPageType fails closed on short buffers and page zero" {
    // Normal: page 1 needs 101 bytes, other pages need 1 byte.
    var one: [100]u8 = std.mem.zeroes([100]u8);
    try std.testing.expectError(error.InvalidPage, Page.init(&one, 1).setPageType(.tableLeaf));
    var empty: [0]u8 = .{};
    try std.testing.expectError(error.InvalidPage, Page.init(&empty, 2).setPageType(.tableLeaf));
    var scratch: [8]u8 = std.mem.zeroes([8]u8);
    try std.testing.expectError(error.InvalidPage, Page.init(&scratch, 0).setPageType(.tableLeaf));
    // Boundary: exactly-sized buffers succeed.
    var single: [1]u8 = .{0};
    try Page.init(&single, 2).setPageType(.indexLeaf);
    try std.testing.expectEqual(PageType.indexLeaf, Page.init(&single, 2).pageType().?);
    var full: [101]u8 = std.mem.zeroes([101]u8);
    try Page.init(&full, 1).setPageType(.tableInterior);
    try std.testing.expectEqual(PageType.tableInterior, Page.init(&full, 1).pageType().?);
}
