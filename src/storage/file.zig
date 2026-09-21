//! Raw database file access: pages, header, payload and WAL sidecar.
//!
//! Owns the OS handle and page geometry; callers own returned buffers and
//! free them. Corrupt or short data fails closed; oversized reads are
//! rejected before allocating. Page size is a power of two in 512..32768.

const std = @import("std");
const Io = std.Io;
const Header = @import("../format/header.zig").Header;
const headerSize = @import("../format/header.zig").size;
const wal = @import("wal.zig");
/// Page size used when creating a brand-new database file.
const pageSizeDefault: usize = 4096;
/// Upper bound for any single image/WAL/payload allocation.
///
/// Why capped: these buffers are sized from on-disk lengths, so an unchecked
/// `alloc(stat.size)` would let a corrupt length force a multi-GB allocation.
/// 256 MiB matches `wal.maxRecoveryBytes` and far exceeds test workloads.
pub const maxImageBytes: usize = 256 * 1024 * 1024;

/// Owned handle to one database file plus its cached geometry.
///
/// Lifetime: created by `open`, released by `close`. The `threaded` IO
/// context must outlive `file`; both are torn down in `close`, so no method
/// may be called after `close`.
pub const DatabaseFile = struct {
    /// Allocator for `path` and all caller-owned read buffers.
    allocator: std.mem.Allocator,
    /// Owned copy of the open path (also the base for the `-wal` path).
    path: []u8,
    /// IO context backing `file`; destroyed on `close`.
    threaded: Io.Threaded,
    /// Open OS file handle.
    file: Io.File,
    /// Validated page size (power of two, 512..32768).
    pageSize: usize,
    /// Cached PRAGMA user_version (flushed into images on write).
    userVersion: u32 = 0,
    /// Cached PRAGMA application_id (flushed into images on write).
    applicationId: u32 = 0,
    /// Cached schema cookie (flushed into images on write).
    schemaVersion: u32 = 1,
    /// When true, `writeImage` appends frames to `-wal` instead of the base.
    walEnabled: bool = false,

    /// Opens (creating when missing) the database at `path`.
    ///
    /// A zero-length file is initialized with a fresh header + one empty
    /// table-leaf page. Otherwise the stored header is decoded and its page
    /// size validated (power of two, 512..32768); anything else returns
    /// `InvalidHeader`/`InvalidPageSize`. The returned struct owns its path
    /// copy and IO context — call `close` exactly once.
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
            result.schemaVersion = header.schemaCookie;
        }
        return result;
    }

    /// Releases the file handle, IO context, and owned path. Idempotent only
    /// in the sense that it must be called exactly once per `open`.
    pub fn close(self: *DatabaseFile) void {
        self.file.close(self.threaded.io());
        self.threaded.deinit();
        self.allocator.free(self.path);
    }

    /// Reads page `pageNumber` (1-based) into a fresh caller-owned buffer.
    ///
    /// Rejects page 0 (would underflow the offset) and short reads (a file
    /// truncated mid-page is corruption, not a short page). The buffer is
    /// exactly `pageSize` bytes; the caller must free it.
    pub fn readPage(self: *DatabaseFile, pageNumber: u32) ![]u8 {
        if (pageNumber == 0) return error.InvalidHeader;
        const bytes = try self.allocator.alloc(u8, self.pageSize);
        errdefer self.allocator.free(bytes);
        const n = try self.file.readPositional(self.threaded.io(), &.{bytes}, (@as(u64, pageNumber - 1) * self.pageSize));
        if (n != self.pageSize) return error.InvalidHeader;
        return bytes;
    }

    /// Writes exactly one page. Requires `bytes.len == pageSize` and a
    /// nonzero page number; anything else is a caller bug, failed closed.
    pub fn writePage(self: *DatabaseFile, pageNumber: u32, bytes: []const u8) !void {
        if (pageNumber == 0) return error.InvalidHeader;
        if (bytes.len != self.pageSize) return error.InvalidPageSize;
        try self.file.writePositionalAll(self.threaded.io(), bytes, (@as(u64, pageNumber - 1) * self.pageSize));
    }

    /// Reads `length` bytes at `offset` into a fresh caller-owned buffer.
    ///
    /// Safety: `length` is capped at `maxImageBytes` so corrupt callers or
    /// lengths cannot force an unbounded allocation; short reads fail with
    /// `InvalidHeader`.
    pub fn readBytes(self: *DatabaseFile, offset: u64, length: usize) ![]u8 {
        if (length > maxImageBytes) return error.InvalidHeader;
        const bytes = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(bytes);
        const n = try self.file.readPositional(self.threaded.io(), &.{bytes}, offset);
        if (n != length) return error.InvalidHeader;
        return bytes;
    }

    /// Writes the legacy `ZIGSQL1` length-prefixed payload region.
    ///
    /// Layout: 7-byte marker + u32 length at `headerSize`, then the payload.
    /// This is the pre-SQLite-image encoding kept for backward compatibility
    /// with existing `connection` payload paths; new data uses `writeImage`.
    pub fn writePayload(self: *DatabaseFile, payload: []const u8) !void {
        const marker = "ZIGSQL1";
        var prefix: [11]u8 = undefined;
        @memcpy(prefix[0..7], marker);
        std.mem.writeInt(u32, prefix[7..11], @intCast(payload.len), .big);
        try self.file.writePositionalAll(self.threaded.io(), &prefix, headerSize);
        try self.file.writePositionalAll(self.threaded.io(), payload, headerSize + prefix.len);
    }

    /// Reads the legacy payload region, or `null` when absent/unmarked.
    ///
    /// Returns `null` for files too small to hold the marker or whose marker
    /// mismatches (plain SQLite images take this path). A declared length
    /// that overruns the file is corruption (`InvalidHeader`), and lengths
    /// above `maxImageBytes` are rejected before allocating.
    pub fn readPayload(self: *DatabaseFile) !?[]u8 {
        const stat = try self.file.stat(self.threaded.io());
        if (stat.size < headerSize + 11) return null;
        var prefix: [11]u8 = undefined;
        const n = try self.file.readPositional(self.threaded.io(), &.{prefix[0..]}, headerSize);
        if (n != prefix.len or !std.mem.eql(u8, prefix[0..7], "ZIGSQL1")) return null;
        const length = std.mem.readInt(u32, prefix[7..11], .big);
        if (length > maxImageBytes) return error.InvalidHeader;
        if (headerSize + prefix.len + length > stat.size) return error.InvalidHeader;
        return try self.readBytes(headerSize + prefix.len, length);
    }

    /// Reads the full database image with the WAL overlay applied.
    ///
    /// Returns a fresh caller-owned buffer (base image, or base + WAL merge).
    /// WAL validation failures surface as `InvalidWal` from `wal.apply`.
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

    /// Reads the base file bytes without WAL overlay.
    ///
    /// Capped at `maxImageBytes`: a corrupt/huge file size fails closed
    /// instead of forcing an unbounded allocation.
    fn readBaseImage(self: *DatabaseFile) ![]u8 {
        const stat = try self.file.stat(self.threaded.io());
        if (stat.size == 0) return error.InvalidHeader;
        const length: usize = std.math.cast(usize, stat.size) orelse return error.InvalidHeader;
        if (length > maxImageBytes) return error.InvalidHeader;
        return self.readBytes(0, length);
    }

    /// Persists `bytes` as the new database image.
    ///
    /// Stamps the cached schema/user/application versions into the header
    /// region first. The slice is `[]u8` (not `[]const u8`) precisely so the
    /// stamp is type-checked: passing read-only memory fails to compile
    /// instead of faulting at runtime. Routes to the WAL sidecar when
    /// `walEnabled`, else rewrites and truncates the base file.
    pub fn writeImage(self: *DatabaseFile, bytes: []u8) !void {
        if (bytes.len >= 44) std.mem.writeInt(u32, bytes[40..44], self.schemaVersion, .big);
        if (bytes.len >= 64) std.mem.writeInt(u32, bytes[60..64], self.userVersion, .big);
        if (bytes.len >= 72) std.mem.writeInt(u32, bytes[68..72], self.applicationId, .big);
        if (self.walEnabled) return self.writeWal(bytes);
        try self.file.writePositionalAll(self.threaded.io(), bytes, 0);
        try self.file.setLength(self.threaded.io(), bytes.len);
    }

    /// Cached PRAGMA user_version accessor (staged until `writeImage`).
    pub fn getUserVersion(self: *const DatabaseFile) u32 {
        return self.userVersion;
    }

    /// Stages a user_version for the next `writeImage` header stamp.
    pub fn setUserVersion(self: *DatabaseFile, version: u32) void {
        self.userVersion = version;
    }

    /// Cached PRAGMA application_id accessor (staged until `writeImage`).
    pub fn getApplicationId(self: *const DatabaseFile) u32 {
        return self.applicationId;
    }

    /// Stages an application_id for the next `writeImage` header stamp.
    pub fn setApplicationId(self: *DatabaseFile, applicationId: u32) void {
        self.applicationId = applicationId;
    }

    /// Cached schema-cookie accessor (staged until `writeImage`).
    pub fn getSchemaVersion(self: *const DatabaseFile) u32 {
        return self.schemaVersion;
    }

    /// Stages a schema cookie for the next `writeImage` header stamp.
    pub fn setSchemaVersion(self: *DatabaseFile, version: u32) void {
        self.schemaVersion = version;
    }

    /// Merges WAL frames into the base file and truncates the sidecar.
    ///
    /// No-op counters when WAL is disabled or the sidecar is missing/empty.
    /// The frame page size is fully validated (range + power of two) and the
    /// frame count must divide the sidecar evenly; deeper checksum/salt
    /// validation happens inside `readImage`/`wal.apply`. Never partially
    /// applies: any validation error aborts before touching the base file.
    pub fn checkpointWal(self: *DatabaseFile) !struct { busy: u32, log: u32, checkpointed: u32 } {
        if (!self.walEnabled) return .{ .busy = 0, .log = 0, .checkpointed = 0 };
        const walBytes = try self.readWal() orelse return .{ .busy = 0, .log = 0, .checkpointed = 0 };
        defer self.allocator.free(walBytes);
        if (walBytes.len < wal.headerSize) return error.InvalidWal;
        const framePageSize = std.mem.readInt(u32, walBytes[8..12], .big);
        if (framePageSize < 512 or framePageSize > 32768 or (framePageSize & (framePageSize - 1)) != 0 or (walBytes.len - wal.headerSize) % (wal.frameHeaderSize + framePageSize) != 0) return error.InvalidWal;
        const frames: u32 = @intCast((walBytes.len - wal.headerSize) / (wal.frameHeaderSize + framePageSize));
        const merged = try self.readImage();
        defer self.allocator.free(merged);
        const io = self.threaded.io();
        try self.file.writePositionalAll(io, merged, 0);
        try self.file.setLength(io, merged.len);
        const path = try self.walPath();
        defer self.allocator.free(path);
        var walFile = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer walFile.close(io);
        try walFile.setLength(io, 0);
        return .{ .busy = 0, .log = frames, .checkpointed = frames };
    }

    /// Enables WAL mode: subsequent `writeImage` calls append to `-wal`.
    pub fn enableWal(self: *DatabaseFile) void {
        self.walEnabled = true;
    }

    /// Reports the current journal mode string (`"wal"` or `"delete"`).
    ///
    /// Why a string: mirrors the `PRAGMA journal_mode` vocabulary used by
    /// SQLite clients; the returned slice is a static literal (no lifetime).
    pub fn journalMode(self: *const DatabaseFile) []const u8 {
        return if (self.walEnabled) "wal" else "delete";
    }

    /// Merges any WAL content into the base file, disables WAL, and deletes
    /// the sidecar (missing sidecar is fine). Fails closed on corrupt WAL.
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

    /// Builds the owned `-wal` sidecar path (`path ++ "-wal"`).
    ///
    /// Caller owns the result and must free it.
    fn walPath(self: *DatabaseFile) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}-wal", .{self.path});
    }

    /// Reads the whole `-wal` sidecar, or `null` when missing/empty.
    ///
    /// Capped at `maxImageBytes` before allocating so a huge sidecar fails
    /// closed; short reads are corruption (`InvalidWal`).
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
        const length: usize = std.math.cast(usize, stat.size) orelse return error.InvalidWal;
        if (length > maxImageBytes) return error.InvalidWal;
        const bytes = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(bytes);
        const n = try walFile.readPositional(io, &.{bytes}, 0);
        if (n != bytes.len) return error.InvalidWal;
        return bytes;
    }

    /// Encodes `image` as WAL frames and replaces the `-wal` sidecar.
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

    /// Deletes the `-wal` sidecar (used after checkpoint/disable).
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

test "database file page zero and short reads fail closed" {
    const path = "sqlite_zig_file_safety_test.db";
    defer Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try DatabaseFile.open(std.testing.allocator, path);
    defer db.close();
    // Error: page numbers are 1-based; 0 would underflow the file offset.
    try std.testing.expectError(error.InvalidHeader, db.readPage(0));
    var scratch: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidHeader, db.writePage(0, &scratch));
    // Error: short page writes are caller bugs, rejected before touching disk.
    var short: [100]u8 = undefined;
    try std.testing.expectError(error.InvalidPageSize, db.writePage(1, &short));
    // Normal: page 1 round-trips byte-identically.
    const page = try db.readPage(1);
    defer std.testing.allocator.free(page);
    try std.testing.expectEqual(db.pageSize, page.len);
    try db.writePage(1, page);
    // Boundary: oversized byte reads are rejected before allocating.
    try std.testing.expectError(error.InvalidHeader, db.readBytes(0, maxImageBytes + 1));
    // Error: missing pages past EOF fail closed instead of short-reading.
    try std.testing.expectError(error.InvalidHeader, db.readPage(0x7fffffff));
}

test "database file journal mode and version accessors" {
    const path = "sqlite_zig_file_mode_test.db";
    defer Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    // WAL sidecar cleanup for hermetic reruns.
    defer Io.Dir.cwd().deleteFile(std.testing.io, "sqlite_zig_file_mode_test.db-wal") catch {};
    var db = try DatabaseFile.open(std.testing.allocator, path);
    defer db.close();
    try std.testing.expectEqualStrings("delete", db.journalMode());
    db.enableWal();
    try std.testing.expectEqualStrings("wal", db.journalMode());
    // Normal: checkpoint with no WAL is a zeroed no-op.
    const empty = try db.checkpointWal();
    try std.testing.expectEqual(@as(u32, 0), empty.log);
    try db.disableWal();
    try std.testing.expectEqualStrings("delete", db.journalMode());
    // Normal: staged versions persist through the header stamp.
    db.setUserVersion(77);
    db.setApplicationId(88);
    db.setSchemaVersion(99);
    try std.testing.expectEqual(@as(u32, 77), db.getUserVersion());
    try std.testing.expectEqual(@as(u32, 88), db.getApplicationId());
    try std.testing.expectEqual(@as(u32, 99), db.getSchemaVersion());
}

test "writeImage stamps versions into the header image" {
    const path = "sqlite_zig_file_stamp_test.db";
    defer Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try DatabaseFile.open(std.testing.allocator, path);
    defer db.close();
    db.setUserVersion(0x01020304);
    db.setApplicationId(0x05060708);
    db.setSchemaVersion(0x090a0b0c);
    var image = try std.testing.allocator.alloc(u8, 100);
    defer std.testing.allocator.free(image);
    @memset(image, 0);
    try db.writeImage(image);
    // The mutable-slice stamp is visible in the caller's buffer and on disk.
    try std.testing.expectEqual(@as(u32, 0x090a0b0c), std.mem.readInt(u32, image[40..44], .big));
    try std.testing.expectEqual(@as(u32, 0x01020304), std.mem.readInt(u32, image[60..64], .big));
    try std.testing.expectEqual(@as(u32, 0x05060708), std.mem.readInt(u32, image[68..72], .big));
    const stored = try db.readBytes(0, 100);
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualSlices(u8, image, stored);
}
