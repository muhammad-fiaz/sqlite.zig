const std = @import("std");
const Io = std.Io;
const Header = @import("../format/header.zig").Header;
const headerSize = @import("../format/header.zig").size;
const wal = @import("wal.zig");
const pageSizeDefault: usize = 4096;

pub const DatabaseFile = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    threaded: Io.Threaded,
    file: Io.File,
    pageSize: usize,
    userVersion: u32 = 0,
    applicationId: u32 = 0,
    walEnabled: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !DatabaseFile {
        var threaded: Io.Threaded = .init(allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();
        const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        const ownedPath = try allocator.dupe(u8, path);
        var result = DatabaseFile{ .allocator = allocator, .path = ownedPath, .threaded = threaded, .file = file, .pageSize = pageSizeDefault };
        errdefer result.close();
        const stat = try file.stat(io);
        if (stat.size == 0) {
            var bytes: [headerSize]u8 = undefined;
            const header = Header{ .databaseSizePages = 1 };
            header.encode(&bytes);
            try file.writePositionalAll(io, &bytes, 0);
            var page: [pageSizeDefault - headerSize]u8 = std.mem.zeroes([pageSizeDefault - headerSize]u8);
            page[0] = 0x0d;
            page[5] = 0x10;
            page[6] = 0x00;
            try file.writePositionalAll(io, &page, headerSize);
        } else {
            var bytes: [headerSize]u8 = undefined;
            const n = try file.readPositional(io, &.{bytes[0..]}, 0);
            if (n != headerSize) return error.InvalidHeader;
            const header = try Header.decode(&bytes);
            if (header.pageSize < 512 or header.pageSize > 32768 or (header.pageSize & (header.pageSize - 1)) != 0) return error.InvalidPageSize;
            result.pageSize = header.pageSize;
            result.userVersion = header.userVersion;
            result.applicationId = header.applicationId;
        }
        return result;
    }

    pub fn close(self: *DatabaseFile) void {
        self.file.close(self.threaded.io());
        self.threaded.deinit();
        self.allocator.free(self.path);
    }

    pub fn readPage(self: *DatabaseFile, pageNumber: u32) ![]u8 {
        const bytes = try self.allocator.alloc(u8, self.pageSize);
        errdefer self.allocator.free(bytes);
        const n = try self.file.readPositional(self.threaded.io(), &.{bytes}, (@as(u64, pageNumber - 1) * self.pageSize));
        if (n != self.pageSize) return error.InvalidHeader;
        return bytes;
    }

    pub fn writePage(self: *DatabaseFile, pageNumber: u32, bytes: []const u8) !void {
        if (bytes.len != self.pageSize) return error.InvalidPageSize;
        try self.file.writePositionalAll(self.threaded.io(), bytes, (@as(u64, pageNumber - 1) * self.pageSize));
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
        try self.file.writePositionalAll(self.threaded.io(), &prefix, headerSize);
        try self.file.writePositionalAll(self.threaded.io(), payload, headerSize + prefix.len);
    }

    pub fn readPayload(self: *DatabaseFile) !?[]u8 {
        const stat = try self.file.stat(self.threaded.io());
        if (stat.size < headerSize + 11) return null;
        var prefix: [11]u8 = undefined;
        const n = try self.file.readPositional(self.threaded.io(), &.{prefix[0..]}, headerSize);
        if (n != prefix.len or !std.mem.eql(u8, prefix[0..7], "ZIGSQL1")) return null;
        const length = std.mem.readInt(u32, prefix[7..11], .big);
        if (headerSize + prefix.len + length > stat.size) return error.InvalidHeader;
        return try self.readBytes(headerSize + prefix.len, length);
    }

    pub fn readImage(self: *DatabaseFile) ![]u8 {
        const base = try self.readBaseImage();
        errdefer self.allocator.free(base);
        if (try self.readWal()) |walBytes| {
            defer self.allocator.free(walBytes);
            const merged = try wal.apply(self.allocator, base, walBytes);
            self.allocator.free(base);
            return merged;
        }
        return base;
    }

    fn readBaseImage(self: *DatabaseFile) ![]u8 {
        const stat = try self.file.stat(self.threaded.io());
        if (stat.size == 0) return error.InvalidHeader;
        return self.readBytes(0, @intCast(stat.size));
    }

    pub fn writeImage(self: *DatabaseFile, bytes: []const u8) !void {
        if (bytes.len >= 64) std.mem.writeInt(u32, @constCast(bytes[60..64]), self.userVersion, .big);
        if (bytes.len >= 72) std.mem.writeInt(u32, @constCast(bytes[68..72]), self.applicationId, .big);
        if (self.walEnabled) return self.writeWal(bytes);
        try self.file.writePositionalAll(self.threaded.io(), bytes, 0);
        try self.file.setLength(self.threaded.io(), bytes.len);
    }

    pub fn getUserVersion(self: *const DatabaseFile) u32 {
        return self.userVersion;
    }

    pub fn setUserVersion(self: *DatabaseFile, version: u32) void {
        self.userVersion = version;
    }

    pub fn getApplicationId(self: *const DatabaseFile) u32 {
        return self.applicationId;
    }

    pub fn setApplicationId(self: *DatabaseFile, applicationId: u32) void {
        self.applicationId = applicationId;
    }

    pub fn enableWal(self: *DatabaseFile) void {
        self.walEnabled = true;
    }

    pub fn journalMode(self: *const DatabaseFile) []const u8 {
        return if (self.walEnabled) "wal" else "delete";
    }

    pub fn disableWal(self: *DatabaseFile) !void {
        if (self.walEnabled) {
            const merged = try self.readImage();
            defer self.allocator.free(merged);
            self.walEnabled = false;
            try self.file.writePositionalAll(self.threaded.io(), merged, 0);
            try self.file.setLength(self.threaded.io(), merged.len);
        }
        self.deleteWal() catch {};
    }

    fn walPath(self: *DatabaseFile) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}-wal", .{self.path});
    }

    fn readWal(self: *DatabaseFile) !?[]u8 {
        const path = try self.walPath();
        defer self.allocator.free(path);
        const io = self.threaded.io();
        var walFile = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer walFile.close(io);
        const stat = try walFile.stat(io);
        if (stat.size == 0) return null;
        const bytes = try self.allocator.alloc(u8, @intCast(stat.size));
        errdefer self.allocator.free(bytes);
        const n = try walFile.readPositional(io, &.{bytes}, 0);
        if (n != bytes.len) return error.InvalidWal;
        return bytes;
    }

    fn writeWal(self: *DatabaseFile, image: []const u8) !void {
        const encoded = try wal.encodeImage(self.allocator, image, self.pageSize);
        defer self.allocator.free(encoded);
        const path = try self.walPath();
        defer self.allocator.free(path);
        const io = self.threaded.io();
        var walFile = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true }),
            else => return err,
        };
        defer walFile.close(io);
        try walFile.writePositionalAll(io, encoded, 0);
        try walFile.setLength(io, encoded.len);
    }

    fn deleteWal(self: *DatabaseFile) !void {
        const path = try self.walPath();
        defer self.allocator.free(path);
        try Io.Dir.cwd().deleteFile(self.threaded.io(), path);
    }
};

test "database file creates a SQLite header" {
    const path = "sqlite_zig_file_test.db";
    defer Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try DatabaseFile.open(std.testing.allocator, path);
    defer db.close();
    try std.testing.expectEqual(@as(usize, 4096), db.pageSize);
}
