const std = @import("std");
const Io = std.Io;
const Header = @import("../format/header.zig").Header;
const header_size = @import("../format/header.zig").size;
const page_size_default: usize = 4096;

pub const DatabaseFile = struct {
    allocator: std.mem.Allocator,
    threaded: Io.Threaded,
    file: Io.File,
    page_size: usize,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !DatabaseFile {
        var threaded: Io.Threaded = .init(allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();
        const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        var result = DatabaseFile{ .allocator = allocator, .threaded = threaded, .file = file, .page_size = page_size_default };
        errdefer result.close();
        const stat = try file.stat(io);
        if (stat.size == 0) {
            var bytes: [header_size]u8 = undefined;
            const header = Header{ .database_size_pages = 1 };
            header.encode(&bytes);
            try file.writePositionalAll(io, &bytes, 0);
            var page: [page_size_default - header_size]u8 = std.mem.zeroes([page_size_default - header_size]u8);
            page[0] = 0x0d;
            page[5] = 0x10;
            page[6] = 0x00;
            try file.writePositionalAll(io, &page, header_size);
        } else {
            var bytes: [header_size]u8 = undefined;
            const n = try file.readPositional(io, &.{bytes[0..]}, 0);
            if (n != header_size) return error.InvalidHeader;
            const header = try Header.decode(&bytes);
            if (header.page_size < 512 or header.page_size > 32768 or (header.page_size & (header.page_size - 1)) != 0) return error.InvalidPageSize;
            result.page_size = header.page_size;
        }
        return result;
    }

    pub fn close(self: *DatabaseFile) void {
        self.file.close(self.threaded.io());
        self.threaded.deinit();
    }

    pub fn readPage(self: *DatabaseFile, page_number: u32) ![]u8 {
        const bytes = try self.allocator.alloc(u8, self.page_size);
        errdefer self.allocator.free(bytes);
        const n = try self.file.readPositional(self.threaded.io(), &.{bytes}, (@as(u64, page_number - 1) * self.page_size));
        if (n != self.page_size) return error.InvalidHeader;
        return bytes;
    }

    pub fn writePage(self: *DatabaseFile, page_number: u32, bytes: []const u8) !void {
        if (bytes.len != self.page_size) return error.InvalidPageSize;
        try self.file.writePositionalAll(self.threaded.io(), bytes, (@as(u64, page_number - 1) * self.page_size));
    }

    pub fn readBytes(self: *DatabaseFile, offset: u64, length: usize) ![]u8 {
        const bytes = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(bytes);
        const n = try self.file.readPositional(self.threaded.io(), &.{bytes}, offset);
        if (n != length) return error.InvalidHeader;
        return bytes;
    }

    pub fn writePayload(self: *DatabaseFile, payload: []const u8) !void {
        const marker = "ZIGSQL1";
        var prefix: [11]u8 = undefined;
        @memcpy(prefix[0..7], marker);
        std.mem.writeInt(u32, prefix[7..11], @intCast(payload.len), .big);
        try self.file.writePositionalAll(self.threaded.io(), &prefix, header_size);
        try self.file.writePositionalAll(self.threaded.io(), payload, header_size + prefix.len);
    }

    pub fn readPayload(self: *DatabaseFile) !?[]u8 {
        const stat = try self.file.stat(self.threaded.io());
        if (stat.size < header_size + 11) return null;
        var prefix: [11]u8 = undefined;
        const n = try self.file.readPositional(self.threaded.io(), &.{prefix[0..]}, header_size);
        if (n != prefix.len or !std.mem.eql(u8, prefix[0..7], "ZIGSQL1")) return null;
        const length = std.mem.readInt(u32, prefix[7..11], .big);
        if (header_size + prefix.len + length > stat.size) return error.InvalidHeader;
        return try self.readBytes(header_size + prefix.len, length);
    }

    pub fn readImage(self: *DatabaseFile) ![]u8 {
        const stat = try self.file.stat(self.threaded.io());
        if (stat.size == 0) return error.InvalidHeader;
        return self.readBytes(0, @intCast(stat.size));
    }

    pub fn writeImage(self: *DatabaseFile, bytes: []const u8) !void {
        try self.file.writePositionalAll(self.threaded.io(), bytes, 0);
        try self.file.setLength(self.threaded.io(), bytes.len);
    }
};

test "database file creates a SQLite header" {
    const path = "sqlite_zig_file_test.db";
    defer Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try DatabaseFile.open(std.testing.allocator, path);
    defer db.close();
    try std.testing.expectEqual(@as(usize, 4096), db.page_size);
}
