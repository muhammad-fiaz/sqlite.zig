//! SQLite record (row payload) codec: serial types + header + body.
//!
//! Purpose: translate `Value` slices to/from the on-disk record format used
//! for table-leaf cell payloads and index entries. Responsibilities: serial-
//! type selection, big-endian integer bodies, header framing. Dependencies:
//! `format/varint.zig` for all integers on the wire, `vm/value.zig` for the
//! in-memory `Value` model. Ownership: `encode` returns a fresh caller-owned
//! buffer; `decode` returns `Value`s whose text/blob slices borrow the input
//! `bytes` (caller must keep `bytes` alive longer than the result, or dupe).
//! Error behavior: malformed input fails closed with `Error.InvalidRecord`
//! (never panics/OOB); allocation failures propagate as `error.OutOfMemory`.
//! Invariants: header size includes its own varint (fixpoint); serial types
//! 10/11 are reserved and rejected. Compatibility: serial-type numbers and
//! integer widths match the SQLite file-format spec.

const std = @import("std");
const varint = @import("varint.zig");
const Value = @import("../vm/value.zig").Value;

/// Record failures: truncated input, reserved serial types, or payload that
/// overruns the buffer. All disk-corruption paths map here (fail closed).
pub const Error = error{InvalidRecord};

/// Maps a `Value` to its on-disk serial type number.
///
/// Why the odd numbers: 0/8/9 are constant values (NULL/0/1, zero body
/// bytes); 1..6 are fixed-width big-endian integers; 7 is a float64; even
/// codes >= 12 are blobs and odd codes >= 13 are text with length
/// `(code - base) / 2`. Length math uses `u64` so huge in-memory slices
/// cannot wrap `usize` arithmetic before the varint cast.
fn serialType(value: Value) u64 {
    return switch (value) {
        .null => 0,
        .integer => |n| if (n == 0) 8 else if (n == 1) 9 else if (n >= -128 and n <= 127) 1 else if (n >= -32768 and n <= 32767) 2 else if (n >= -8388608 and n <= 8388607) 3 else if (n >= -2147483648 and n <= 2147483647) 4 else if (n >= -140737488355328 and n <= 140737488355327) 5 else 6,
        .real => 7,
        .blob => |bytes| 12 + @as(u64, @intCast(bytes.len)) * 2,
        .text => |bytes| 13 + @as(u64, @intCast(bytes.len)) * 2,
    };
}

/// Appends `count` big-endian bytes of `value` to `list`.
///
/// Safety: caller selects `count` from the serial-type width table (1, 2, 3,
/// 4, 6, 8); the shift amount is bounded by `(count - 1) * 8 < 64`.
fn appendBigEndian(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64, count: usize) !void {
    var i: usize = count;
    while (i > 0) : (i -= 1) try list.append(allocator, @truncate(value >> @intCast((i - 1) * 8)));
}

/// Appends one varint to `list` (used for the header size + serial types).
fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buffer: [9]u8 = undefined;
    const length = try varint.encode(value, &buffer);
    try list.appendSlice(allocator, buffer[0..length]);
}

/// Encodes `values` into a fresh record buffer owned by the caller.
///
/// The header size counts its own varint, solved by fixpoint iteration
/// (converges in <= 2 steps): naive `lengths + len(lengths)` is off by one
/// when the serial-type bytes sit near a varint boundary (e.g. 127 -> 128).
pub fn encode(allocator: std.mem.Allocator, values: []const Value) ![]u8 {
    var header = std.ArrayList(u8).empty;
    defer header.deinit(allocator);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    var headerLengths: usize = 0;
    for (values) |value| {
        var tmp: [9]u8 = undefined;
        headerLengths += (try varint.encode(serialType(value), &tmp));
    }
    var headerSizeValue: u64 = @as(u64, @intCast(headerLengths)) + 1;
    while (true) {
        const candidate = @as(u64, @intCast(headerLengths)) + varint.encodedLength(headerSizeValue);
        if (candidate == headerSizeValue) break;
        headerSizeValue = candidate;
    }
    try appendVarint(&header, allocator, headerSizeValue);
    for (values) |value| try appendVarint(&header, allocator, serialType(value));
    for (values) |value| switch (value) {
        .null => {},
        .integer => |n| {
            const code = serialType(value);
            if (code == 8 or code == 9) {} else try appendBigEndian(&body, allocator, @bitCast(n), switch (code) {
                1 => 1,
                2 => 2,
                3 => 3,
                4 => 4,
                5 => 6,
                else => 8,
            });
        },
        .real => |n| try appendBigEndian(&body, allocator, @bitCast(n), 8),
        .text => |bytes| try body.appendSlice(allocator, bytes),
        .blob => |bytes| try body.appendSlice(allocator, bytes),
    };
    var result = try std.ArrayList(u8).initCapacity(allocator, header.items.len + body.items.len);
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, header.items);
    try result.appendSlice(allocator, body.items);
    return result.toOwnedSlice(allocator);
}

/// Reads a `count`-byte big-endian two's-complement integer with sign
/// extension (SQLite stores integers in 1, 2, 3, 4, 6, or 8 bytes).
///
/// Safety: caller bounds-checks `bytes.len >= count` before calling; the
/// extension loop is capped at 8 iterations.
fn readInteger(bytes: []const u8, count: usize) i64 {
    var value: u64 = 0;
    for (bytes[0..count]) |byte| value = (value << 8) | byte;
    if (count < 8 and (value & (@as(u64, 1) << @as(u6, @intCast(count * 8 - 1)))) != 0) {
        var signExtension = count;
        while (signExtension < 8) : (signExtension += 1) value |= @as(u64, 0xff) << @as(u6, @intCast(signExtension * 8));
    }
    return @bitCast(value);
}

/// Decodes a record; text/blob results borrow `bytes` (see module docs).
///
/// Fail-closed rules: empty input, zero/overlong header size, truncated
/// serial types, reserved codes 10/11, codes < 12 outside the table, and any
/// body overrun all return `Error.InvalidRecord`. All integer casts from
/// untrusted varints use checked `std.math.cast` so 32-bit targets cannot
/// panic on huge codes. Loop bounds: the type loop advances `offset` by >= 1
/// per iteration up to `headerSize <= bytes.len`; no unbounded allocation
/// (list capacities derive from `bytes.len`-bounded counts).
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Value {
    const first = varint.decode(bytes) catch return Error.InvalidRecord;
    const headerSize: usize = std.math.cast(usize, first.value) orelse return Error.InvalidRecord;
    if (headerSize > bytes.len or headerSize == 0) return Error.InvalidRecord;
    var types = std.ArrayList(u64).empty;
    defer types.deinit(allocator);
    var offset: usize = first.length;
    while (offset < headerSize) {
        const item = varint.decode(bytes[offset..]) catch return Error.InvalidRecord;
        try types.append(allocator, item.value);
        offset += item.length;
    }
    var values = try std.ArrayList(Value).initCapacity(allocator, types.items.len);
    errdefer values.deinit(allocator);
    var payload = headerSize;
    for (types.items) |code| {
        switch (code) {
            0 => try values.append(allocator, .null),
            8 => try values.append(allocator, .{ .integer = 0 }),
            9 => try values.append(allocator, .{ .integer = 1 }),
            1...6 => |c| {
                const count: usize = switch (c) {
                    1 => 1,
                    2 => 2,
                    3 => 3,
                    4 => 4,
                    5 => 6,
                    6 => 8,
                    else => unreachable,
                };
                if (payload + count > bytes.len) return Error.InvalidRecord;
                try values.append(allocator, .{ .integer = readInteger(bytes[payload..], count) });
                payload += count;
            },
            7 => {
                if (payload + 8 > bytes.len) return Error.InvalidRecord;
                try values.append(allocator, .{ .real = @bitCast(readInteger(bytes[payload..], 8)) });
                payload += 8;
            },
            else => {
                if (code < 12) return Error.InvalidRecord;
                const length: usize = std.math.cast(usize, (code - 12) / 2) orelse return Error.InvalidRecord;
                if (payload + length > bytes.len) return Error.InvalidRecord;
                if (code % 2 == 0) try values.append(allocator, .{ .blob = bytes[payload .. payload + length] }) else try values.append(allocator, .{ .text = bytes[payload .. payload + length] });
                payload += length;
            },
        }
    }
    return values.toOwnedSlice(allocator);
}

test "record format round trip" {
    const values = [_]Value{ .{ .integer = -12 }, .{ .text = "hello" }, .null, .{ .real = 2.5 }, .{ .blob = "ab" } };
    const bytes = try encode(std.testing.allocator, &values);
    defer std.testing.allocator.free(bytes);
    const decoded = try decode(std.testing.allocator, bytes);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(@as(i64, -12), decoded[0].integer);
    try std.testing.expectEqualStrings("hello", decoded[1].text);
}

test "record serial types cover every integer width and empty payloads" {
    const values = [_]Value{
        .null,
        .{ .integer = 0 },
        .{ .integer = 1 },
        .{ .integer = -1 },
        .{ .integer = 127 },
        .{ .integer = 128 },
        .{ .integer = -129 },
        .{ .integer = 32767 },
        .{ .integer = 32768 },
        .{ .integer = -8388609 },
        .{ .integer = std.math.maxInt(i64) },
        .{ .integer = std.math.minInt(i64) },
        .{ .real = -0.0 },
        .{ .text = "" },
        .{ .blob = &[_]u8{} },
        .{ .text = "x" },
        .{ .blob = &[_]u8{0x00} },
    };
    const bytes = try encode(std.testing.allocator, &values);
    defer std.testing.allocator.free(bytes);
    const decoded = try decode(std.testing.allocator, bytes);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(values.len, decoded.len);
    try std.testing.expect(decoded[0] == .null);
    try std.testing.expectEqual(@as(i64, 0), decoded[1].integer);
    try std.testing.expectEqual(@as(i64, 1), decoded[2].integer);
    try std.testing.expectEqual(@as(i64, -1), decoded[3].integer);
    try std.testing.expectEqual(@as(i64, 127), decoded[4].integer);
    try std.testing.expectEqual(@as(i64, 128), decoded[5].integer);
    try std.testing.expectEqual(@as(i64, -129), decoded[6].integer);
    try std.testing.expectEqual(@as(i64, 32767), decoded[7].integer);
    try std.testing.expectEqual(@as(i64, 32768), decoded[8].integer);
    try std.testing.expectEqual(@as(i64, -8388609), decoded[9].integer);
    try std.testing.expectEqual(std.math.maxInt(i64), decoded[10].integer);
    try std.testing.expectEqual(std.math.minInt(i64), decoded[11].integer);
    try std.testing.expect(decoded[12].real == 0);
    try std.testing.expectEqual(@as(usize, 0), decoded[13].text.len);
    try std.testing.expectEqual(@as(usize, 0), decoded[14].blob.len);
    try std.testing.expectEqualStrings("x", decoded[15].text);
    try std.testing.expectEqual(@as(u8, 0x00), decoded[16].blob[0]);
}

test "record decoder rejects reserved serial types and truncation" {
    // Reserved serial types 10 and 11 are never valid on disk.
    const reserved10 = [_]u8{ 0x02, 0x0a, 0x00 };
    try std.testing.expectError(Error.InvalidRecord, decode(std.testing.allocator, &reserved10));
    const reserved11 = [_]u8{ 0x02, 0x0b, 0x00 };
    try std.testing.expectError(Error.InvalidRecord, decode(std.testing.allocator, &reserved11));
    // Empty input and truncated payloads fail closed.
    try std.testing.expectError(Error.InvalidRecord, decode(std.testing.allocator, &[_]u8{}));
    const values = [_]Value{ .{ .integer = std.math.maxInt(i64) }, .{ .text = "hello" } };
    const bytes = try encode(std.testing.allocator, &values);
    defer std.testing.allocator.free(bytes);
    var cut: usize = 1;
    while (cut < bytes.len) : (cut += 1) {
        try std.testing.expectError(Error.InvalidRecord, decode(std.testing.allocator, bytes[0..cut]));
    }
    const ok = try decode(std.testing.allocator, bytes);
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqual(@as(usize, 2), ok.len);
}

test "record header size counts its own varint at the 127-byte boundary" {
    // 127 one-byte serial types need a 2-byte header-size varint (total 129),
    // the case a naive `lengths + len(lengths)` fixpoint misses by one.
    const count = 127;
    const values = try std.testing.allocator.alloc(Value, count);
    defer std.testing.allocator.free(values);
    for (values) |*v| v.* = .null;
    const bytes = try encode(std.testing.allocator, values);
    defer std.testing.allocator.free(bytes);
    const first = try varint.decode(bytes);
    // 127 one-byte serial types + a 2-byte size varint = 129 header bytes.
    try std.testing.expectEqual(@as(u64, 129), first.value);
    try std.testing.expectEqual(@as(u8, 2), first.length);
    const decoded = try decode(std.testing.allocator, bytes);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqual(count, decoded.len);
    // Boundary: empty record is a 1-byte header claiming size 1.
    const empty = try encode(std.testing.allocator, &[_]Value{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    const emptyDecoded = try decode(std.testing.allocator, empty);
    defer std.testing.allocator.free(emptyDecoded);
    try std.testing.expectEqual(@as(usize, 0), emptyDecoded.len);
    // Error: header size 0 and header larger than the buffer fail closed.
    try std.testing.expectError(Error.InvalidRecord, decode(std.testing.allocator, &[_]u8{0x00}));
    try std.testing.expectError(Error.InvalidRecord, decode(std.testing.allocator, &[_]u8{ 0x7f, 0x00 }));
}
