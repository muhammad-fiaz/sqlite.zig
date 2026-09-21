const std = @import("std");
const varint = @import("varint.zig");
const Value = @import("../vm/value.zig").Value;

pub const Error = error{InvalidRecord};

fn serialType(value: Value) u64 {
    return switch (value) {
        .null => 0,
        .integer => |n| if (n == 0) 8 else if (n == 1) 9 else if (n >= -128 and n <= 127) 1 else if (n >= -32768 and n <= 32767) 2 else if (n >= -8388608 and n <= 8388607) 3 else if (n >= -2147483648 and n <= 2147483647) 4 else if (n >= -140737488355328 and n <= 140737488355327) 5 else 6,
        .real => 7,
        .blob => |bytes| 12 + bytes.len * 2,
        .text => |bytes| 13 + bytes.len * 2,
    };
}

fn appendBigEndian(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64, count: usize) !void {
    var i: usize = count;
    while (i > 0) : (i -= 1) try list.append(allocator, @truncate(value >> @intCast((i - 1) * 8)));
}

fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buffer: [9]u8 = undefined;
    const length = try varint.encode(value, &buffer);
    try list.appendSlice(allocator, buffer[0..length]);
}

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
    try appendVarint(&header, allocator, headerLengths + varint.encodedLength(@intCast(headerLengths)));
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

fn readInteger(bytes: []const u8, count: usize) i64 {
    var value: u64 = 0;
    for (bytes[0..count]) |byte| value = (value << 8) | byte;
    if (count < 8 and (value & (@as(u64, 1) << @as(u6, @intCast(count * 8 - 1)))) != 0) {
        var signExtension = count;
        while (signExtension < 8) : (signExtension += 1) value |= @as(u64, 0xff) << @as(u6, @intCast(signExtension * 8));
    }
    return @bitCast(value);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Value {
    const first = varint.decode(bytes) catch return Error.InvalidRecord;
    const headerSize: usize = @intCast(first.value);
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
                const length: usize = @intCast((code - 12) / 2);
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
