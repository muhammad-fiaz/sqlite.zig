const std = @import("std");

pub const PageType = enum(u8) { table_interior = 0x05, table_leaf = 0x0d, index_interior = 0x02, index_leaf = 0x0a };

pub const Page = struct {
    bytes: []u8,
    page_number: u32,

    pub fn init(bytes: []u8, page_number: u32) Page {
        return .{ .bytes = bytes, .page_number = page_number };
    }

    pub fn headerOffset(self: Page) usize {
        return if (self.page_number == 1) 100 else 0;
    }

    pub fn pageType(self: Page) ?PageType {
        const offset = self.headerOffset();
        if (offset >= self.bytes.len) return null;
        return std.enums.fromInt(PageType, self.bytes[offset]);
    }

    pub fn setPageType(self: Page, page_type: PageType) void {
        self.bytes[self.headerOffset()] = @intFromEnum(page_type);
    }
};

test "page one has a database header offset" {
    var bytes: [4096]u8 = std.mem.zeroes([4096]u8);
    var page = Page.init(&bytes, 1);
    page.setPageType(.table_leaf);
    try std.testing.expectEqual(@as(usize, 100), page.headerOffset());
    try std.testing.expectEqual(PageType.table_leaf, page.pageType().?);
}
