//! Page cache over the database file.
//!
//! Owns cached page buffers; slices borrow the cache until `deinit`.
//! Dirty pages flush on demand; double free fails `AlreadyFreed`.

const std = @import("std");
const DatabaseFile = @import("file.zig").DatabaseFile;

/// Read-through page cache with explicit write-back.
///
/// Why dirty tracking is explicit: the pager cannot know which borrowed slice
/// mutations are intentional, so callers mark pages dirty (or allocate, which
/// marks automatically) and `flush` persists exactly the dirty set.
pub const Pager = struct {
    /// Allocator for cached page buffers and map storage.
    allocator: std.mem.Allocator,
    /// Borrowed database file (must outlive the pager).
    file: *DatabaseFile,
    /// Page number -> owned page image.
    pages: std.AutoHashMap(u32, []u8),
    /// Pages awaiting write-back (subset of `pages` keys).
    dirty: std.AutoHashMap(u32, void),
    /// Reusable page numbers from `freePage` (LIFO).
    freelist: std.ArrayList(u32),
    /// Freelist numbers not yet reallocated; guards against double free.
    freed: std.AutoHashMap(u32, void),
    /// High-water page number allocated so far.
    pageCount: u32 = 1,

    /// Creates an empty cache over `file`. No I/O happens until `get`.
    pub fn init(allocator: std.mem.Allocator, file: *DatabaseFile) Pager {
        return .{
            .allocator = allocator,
            .file = file,
            .pages = std.AutoHashMap(u32, []u8).init(allocator),
            .dirty = std.AutoHashMap(u32, void).init(allocator),
            .freelist = .empty,
            .freed = std.AutoHashMap(u32, void).init(allocator),
            .pageCount = 1,
        };
    }

    /// Frees all cached pages and map storage. The borrowed `file` is left
    /// open (its owner closes it).
    pub fn deinit(self: *Pager) void {
        var iterator = self.pages.valueIterator();
        while (iterator.next()) |page| self.allocator.free(page.*);
        self.pages.deinit();
        self.dirty.deinit();
        self.freed.deinit();
        self.freelist.deinit(self.allocator);
    }

    /// Returns the cached (or freshly read) mutable image for `pageNumber`.
    ///
    /// The slice borrows the cache: valid until `deinit`, must not be freed.
    /// Page 0 is rejected; reads past EOF fail with `InvalidHeader` via the
    /// file layer. Repeated calls return the same buffer (pointer-stable
    /// until `deinit`).
    pub fn get(self: *Pager, pageNumber: u32) ![]u8 {
        if (pageNumber == 0) return error.InvalidHeader;
        if (self.pages.get(pageNumber)) |page| return page;
        const page = try self.file.readPage(pageNumber);
        try self.pages.put(pageNumber, page);
        if (pageNumber > self.pageCount) self.pageCount = pageNumber;
        return page;
    }

    /// Allocates a fresh zeroed page, reusing a freelist entry when present.
    ///
    /// Returned pages are zeroed (no stale data leaks across reuse) and
    /// pre-marked dirty so a subsequent `flush` persists them. The returned
    /// number is 1-based and newly high-water unless recycled.
    pub fn allocatePage(self: *Pager) !u32 {
        if (self.freelist.items.len > 0) {
            const reused = self.freelist.pop().?;
            _ = self.freed.remove(reused);
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

    /// Releases `pageNumber` for reuse: zeroes any cached image, marks it
    /// dirty (the zeroing must reach disk), and pushes it on the freelist.
    /// Page 0 is rejected. Uncached pages are still tracked so a later
    /// `allocatePage` can recycle the number. Freeing a number that is
    /// already freed (and not yet reallocated) fails with `AlreadyFreed`
    /// instead of recycling it twice, which would let two live pages alias.
    pub fn freePage(self: *Pager, pageNumber: u32) !void {
        if (pageNumber == 0) return error.InvalidHeader;
        if (self.freed.contains(pageNumber)) return error.AlreadyFreed;
        try self.freelist.append(self.allocator, pageNumber);
        errdefer _ = self.freelist.pop();
        try self.freed.put(pageNumber, {});
        if (self.pages.get(pageNumber)) |page| {
            @memset(page, 0);
            try self.markDirty(pageNumber);
        }
    }

    /// Marks a cached page for write-back. Dirty entries without cached data
    /// are skipped by `flush` (no-op rather than an error).
    pub fn markDirty(self: *Pager, pageNumber: u32) !void {
        try self.dirty.put(pageNumber, {});
    }

    /// Writes every dirty cached page to the file and clears the dirty set.
    ///
    /// Dirty numbers with no cached image are skipped (defensive: can only
    /// happen if a caller marked a never-fetched page). Capacity is retained
    /// for the next transaction.
    pub fn flush(self: *Pager) !void {
        var iterator = self.dirty.keyIterator();
        while (iterator.next()) |pageNumber| {
            if (self.pages.get(pageNumber.*)) |pageData| {
                try self.file.writePage(pageNumber.*, pageData);
            }
        }
        self.dirty.clearRetainingCapacity();
    }

    /// Returns the high-water page number (allocated count, 1-based).
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

test "pager rejects page zero and missing pages without panic" {
    const path = "sqlite_zig_pager_safety_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var file = try DatabaseFile.open(std.testing.allocator, path);
    defer file.close();
    var pager = Pager.init(std.testing.allocator, &file);
    defer pager.deinit();
    // Error: page numbers are 1-based throughout the pager and file layers.
    try std.testing.expectError(error.InvalidHeader, pager.get(0));
    try std.testing.expectError(error.InvalidHeader, pager.freePage(0));
    // Error: unbacked pages past EOF fail closed instead of short-reading.
    try std.testing.expectError(error.InvalidHeader, pager.get(0x00ffffff));
    // Normal: cache identity — the same page returns the same buffer.
    const first = try pager.get(1);
    const second = try pager.get(1);
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expectEqual(@as(u32, 1), pager.dbPageCount());
    // Normal: flushing with nothing dirty is a no-op.
    try pager.flush();
    // Normal: marking a never-fetched page dirty flushes safely (skipped).
    try pager.markDirty(9);
    try pager.flush();
}

test "pager zeroes recycled pages so no stale data leaks" {
    const path = "sqlite_zig_pager_zero_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var file = try DatabaseFile.open(std.testing.allocator, path);
    defer file.close();
    var pager = Pager.init(std.testing.allocator, &file);
    defer pager.deinit();
    const p2 = try pager.allocatePage();
    const image = try pager.get(p2);
    @memset(image, 0xab);
    try pager.markDirty(p2);
    try pager.freePage(p2);
    // Boundary: the cached image is zeroed synchronously on free.
    for (image) |b| try std.testing.expectEqual(@as(u8, 0), b);
    const recycled = try pager.allocatePage();
    try std.testing.expectEqual(p2, recycled);
    const fresh = try pager.get(recycled);
    for (fresh) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "pager rejects double free instead of aliasing pages" {
    const path = "sqlite_zig_pager_double_free_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var file = try DatabaseFile.open(std.testing.allocator, path);
    defer file.close();
    var pager = Pager.init(std.testing.allocator, &file);
    defer pager.deinit();
    const p2 = try pager.allocatePage();
    // Free-then-free-again errors; the number is recycled exactly once.
    try pager.freePage(p2);
    try std.testing.expectError(error.AlreadyFreed, pager.freePage(p2));
    const recycled = try pager.allocatePage();
    try std.testing.expectEqual(p2, recycled);
    // After reallocation the number is live again: freeing works once more.
    try pager.freePage(recycled);
    try std.testing.expectError(error.AlreadyFreed, pager.freePage(recycled));
    // Uncached numbers are tracked too, and also refuse a second free.
    try pager.freePage(41);
    try std.testing.expectError(error.AlreadyFreed, pager.freePage(41));
    try std.testing.expectEqual(@as(u32, 41), try pager.allocatePage());
}
