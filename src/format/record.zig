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
    var header_lengths: usize = 0;
    for (values) |value| {
        var tmp: [9]u8 = undefined;
        header_lengths += (try varint.encode(serialType(value), &tmp));
    }
    try appendVarint(&header, allocator, header_lengths + varint.encodedLength(@intCast(header_lengths)));
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
        var sign_extension = count;
        while (sign_extension < 8) : (sign_extension += 1) value |= @as(u64, 0xff) << @as(u6, @intCast(sign_extension * 8));
    }
    return @bitCast(value);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Value {
    const first = try varint.decode(bytes);
    const header_size: usize = first.value;
    if (header_size > bytes.len or header_size == 0) return Error.InvalidRecord;
    var types = std.ArrayList(u64).empty;
    defer types.deinit(allocator);
    var offset: usize = first.length;
    while (offset < header_size) {
        const item = try varint.decode(bytes[offset..]);
        try types.append(allocator, item.value);
        offset += item.length;
    }
    var values = try std.ArrayList(Value).initCapacity(allocator, types.items.len);
    errdefer values.deinit(allocator);
    var payload = header_size;
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
