const std = @import("std");
const DatabaseFile = @import("file.zig").DatabaseFile;

pub const Pager = struct {
    allocator: std.mem.Allocator,
    file: *DatabaseFile,
    pages: std.AutoHashMap(u32, []u8),
    dirty: std.AutoHashMap(u32, void),
    freelist: std.ArrayList(u32),
    pageCount: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, file: *DatabaseFile) Pager {
        return .{
            .allocator = allocator,
            .file = file,
            .pages = std.AutoHashMap(u32, []u8).init(allocator),
            .dirty = std.AutoHashMap(u32, void).init(allocator),
            .freelist = .empty,
            .pageCount = 1,
        };
    }

    pub fn deinit(self: *Pager) void {
        var iterator = self.pages.valueIterator();
        while (iterator.next()) |page| self.allocator.free(page.*);
        self.pages.deinit();
        self.dirty.deinit();
        self.freelist.deinit(self.allocator);
    }

    pub fn get(self: *Pager, pageNumber: u32) ![]u8 {
        if (self.pages.get(pageNumber)) |page| return page;
        const page = try self.file.readPage(pageNumber);
        try self.pages.put(pageNumber, page);
        if (pageNumber > self.pageCount) self.pageCount = pageNumber;
        return page;
    }

    pub fn allocatePage(self: *Pager) !u32 {
        if (self.freelist.items.len > 0) {
            const reused = self.freelist.pop().?;
            if (self.pages.get(reused)) |page| {
                @memset(page, 0);
            } else {
                const page = try self.allocator.alloc(u8, self.file.pageSize);
                @memset(page, 0);
                try self.pages.put(reused, page);
            }
            try self.markDirty(reused);
            return reused;
        }
        self.pageCount += 1;
        const newPageNum = self.pageCount;
        const page = try self.allocator.alloc(u8, self.file.pageSize);
        @memset(page, 0);
        try self.pages.put(newPageNum, page);
        try self.markDirty(newPageNum);
        return newPageNum;
    }

    pub fn freePage(self: *Pager, pageNumber: u32) !void {
        try self.freelist.append(self.allocator, pageNumber);
        if (self.pages.get(pageNumber)) |page| {
            @memset(page, 0);
            try self.markDirty(pageNumber);
        }
    }

    pub fn markDirty(self: *Pager, pageNumber: u32) !void {
        try self.dirty.put(pageNumber, {});
    }

    pub fn flush(self: *Pager) !void {
        var iterator = self.dirty.keyIterator();
        while (iterator.next()) |pageNumber| {
            if (self.pages.get(pageNumber.*)) |pageData| {
                try self.file.writePage(pageNumber.*, pageData);
            }
        }
        self.dirty.clearRetainingCapacity();
    }

    pub fn dbPageCount(self: *const Pager) u32 {
        return self.pageCount;
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

test "pager allocates and frees pages" {
    const path = "sqlite_zig_pager_alloc_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var file = try DatabaseFile.open(std.testing.allocator, path);
    defer file.close();
    var pager = Pager.init(std.testing.allocator, &file);
    defer pager.deinit();

    const p2 = try pager.allocatePage();
    try std.testing.expectEqual(@as(u32, 2), p2);
    const p3 = try pager.allocatePage();
    try std.testing.expectEqual(@as(u32, 3), p3);

    try pager.freePage(p3);
    const reused = try pager.allocatePage();
    try std.testing.expectEqual(@as(u32, 3), reused);
}
