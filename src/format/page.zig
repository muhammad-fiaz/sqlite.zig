const std = @import("std");

pub const PageType = enum(u8) { tableInterior = 0x05, tableLeaf = 0x0d, indexInterior = 0x02, indexLeaf = 0x0a };

pub const Page = struct {
    bytes: []u8,
    pageNumber: u32,

    pub fn init(bytes: []u8, pageNumber: u32) Page {
        return .{ .bytes = bytes, .pageNumber = pageNumber };
    }

    pub fn headerOffset(self: Page) usize {
        return if (self.pageNumber == 1) 100 else 0;
    }

    pub fn pageType(self: Page) ?PageType {
        const offset = self.headerOffset();
        if (offset >= self.bytes.len) return null;
        return std.enums.fromInt(PageType, self.bytes[offset]);
    }

    pub fn setPageType(self: Page, kind: PageType) void {
        self.bytes[self.headerOffset()] = @intFromEnum(kind);
    }
};

test "page one has a database header offset" {
    var bytes: [4096]u8 = std.mem.zeroes([4096]u8);
    var page = Page.init(&bytes, 1);
    page.setPageType(.tableLeaf);
    try std.testing.expectEqual(@as(usize, 100), page.headerOffset());
    try std.testing.expectEqual(PageType.tableLeaf, page.pageType().?);
}

test "page types round trip and unknown types stay unknown" {
    var bytes: [512]u8 = std.mem.zeroes([512]u8);
    const kinds = [_]PageType{ .tableInterior, .tableLeaf, .indexInterior, .indexLeaf };
    for (kinds) |kind| {
        var page = Page.init(&bytes, 7);
        try std.testing.expectEqual(@as(usize, 0), page.headerOffset());
        page.setPageType(kind);
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
