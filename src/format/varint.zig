const std = @import("std");

pub const Error = error{InvalidVarint};

pub fn encodedLength(value: u64) u8 {
    if (value <= 0x7f) return 1;
    if (value <= 0x3fff) return 2;
    if (value <= 0x1fffff) return 3;
    if (value <= 0xfffffff) return 4;
    if (value <= 0x7ffffffff) return 5;
    if (value <= 0x3ffffffffff) return 6;
    if (value <= 0x1ffffffffffff) return 7;
    if (value <= 0xffffffffffffff) return 8;
    return 9;
}

pub fn encode(value: u64, out: []u8) Error!u8 {
    const length = encodedLength(value);
    if (out.len < length) return Error.InvalidVarint;
    if (length == 9) {
        var n = value;
        var i: usize = 8;
        out[i] = @truncate(n);
        n >>= 8;
        while (i > 0) : (i -= 1) {
            out[i - 1] = @truncate((n & 0x7f) | 0x80);
            n >>= 7;
        }
        return 9;
    }
    var n = value;
    var i: usize = length;
    while (i > 0) : (i -= 1) {
        out[i - 1] = @truncate(n & 0x7f);
        n >>= 7;
    }
    i = 0;
    while (i + 1 < length) : (i += 1) out[i] |= 0x80;
    return length;
}

pub fn decode(input: []const u8) Error!struct { value: u64, length: u8 } {
    if (input.len == 0) return Error.InvalidVarint;
    var result: u64 = 0;
    var i: usize = 0;
    while (i < input.len and i < 9) : (i += 1) {
        if (i == 8) {
            result = (result << 8) | input[i];
            return .{ .value = result, .length = 9 };
        }
        result = (result << 7) | (input[i] & 0x7f);
        if ((input[i] & 0x80) == 0) return .{ .value = result, .length = @intCast(i + 1) };
    }
    return Error.InvalidVarint;
}

test "sqlite varints round trip" {
    const values = [_]u64{ 0, 1, 127, 128, 16383, 16384, 0xffffffffffffff, std.math.maxInt(u64) };
    for (values) |expected| {
        var buffer: [9]u8 = undefined;
        const length = try encode(expected, &buffer);
        const decoded = try decode(buffer[0..length]);
        try std.testing.expectEqual(expected, decoded.value);
        try std.testing.expectEqual(length, decoded.length);
    }
}
