const std = @import("std");
const DatabaseFile = @import("file.zig").DatabaseFile;

pub const Pager = struct {
    allocator: std.mem.Allocator,
    file: *DatabaseFile,
    pages: std.AutoHashMap(u32, []u8),
    dirty: std.AutoHashMap(u32, void),

    pub fn init(allocator: std.mem.Allocator, file: *DatabaseFile) Pager {
        return .{ .allocator = allocator, .file = file, .pages = std.AutoHashMap(u32, []u8).init(allocator), .dirty = std.AutoHashMap(u32, void).init(allocator) };
    }
    pub fn deinit(self: *Pager) void {
        var iterator = self.pages.valueIterator();
        while (iterator.next()) |page| self.allocator.free(page.*);
        self.pages.deinit();
        self.dirty.deinit();
    }

    pub fn get(self: *Pager, page_number: u32) ![]u8 {
        if (self.pages.get(page_number)) |page| return page;
        const page = try self.file.readPage(page_number);
        try self.pages.put(page_number, page);
        return page;
    }

    pub fn markDirty(self: *Pager, page_number: u32) !void {
        try self.dirty.put(page_number, {});
    }

    pub fn flush(self: *Pager) !void {
        var iterator = self.dirty.keyIterator();
        while (iterator.next()) |page_number| try self.file.writePage(page_number.*, self.pages.get(page_number.*).?);
        self.dirty.clearRetainingCapacity();
    }
};

test "pager caches and flushes a page" {
    const path = "sqlite_zig_pager_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var file = try DatabaseFile.open(std.testing.allocator, path);
    defer file.close();
    var pager = Pager.init(std.testing.allocator, &file);
    defer pager.deinit();
    const page = try pager.get(1);
    page[100] = 0x0d;
    try pager.markDirty(1);
    try pager.flush();
}
