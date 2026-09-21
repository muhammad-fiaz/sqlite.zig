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

test "sqlite varint boundaries encode to minimal lengths" {
    const cases = [_]struct { value: u64, length: u8 }{
        .{ .value = 0, .length = 1 },
        .{ .value = 0x7f, .length = 1 },
        .{ .value = 0x80, .length = 2 },
        .{ .value = 0x3fff, .length = 2 },
        .{ .value = 0x4000, .length = 3 },
        .{ .value = 0xffffffffffffff, .length = 8 },
        .{ .value = 0x100000000000000, .length = 9 },
        .{ .value = std.math.maxInt(u64), .length = 9 },
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.length, encodedLength(c.value));
        var buffer: [9]u8 = undefined;
        try std.testing.expectEqual(c.length, try encode(c.value, &buffer));
        const decoded = try decode(buffer[0..c.length]);
        try std.testing.expectEqual(c.value, decoded.value);
    }
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(Error.InvalidVarint, encode(0x80, &tiny));
}

test "sqlite varint decoder rejects truncation without panic or overread" {
    try std.testing.expectError(Error.InvalidVarint, decode(&[_]u8{}));
    // Continuation bits with no terminator, at every truncated length.
    // Note the 9-byte case is complete: like SQLite, the ninth byte always
    // terminates the varint with its full 8 bits.
    var i: usize = 1;
    while (i <= 8) : (i += 1) {
        var buffer: [9]u8 = undefined;
        @memset(buffer[0..i], 0x80);
        try std.testing.expectError(Error.InvalidVarint, decode(buffer[0..i]));
    }
    var full: [9]u8 = undefined;
    @memset(&full, 0x80);
    // Nine continuation bytes are a complete 9-byte varint (the ninth byte
    // is always terminal data), so this decodes instead of erroring. Each
    // byte contributes zero value bits here except the last full byte.
    const nine = try decode(&full);
    try std.testing.expectEqual(@as(u8, 9), nine.length);
    try std.testing.expectEqual(@as(u64, 128), nine.value);
    // Overlong input decodes the leading 9-byte varint and stops: the first
    // eight bytes contribute 7 bits each and the ninth a full 8 bits.
    var overlong: [10]u8 = .{ 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x01, 0x00 };
    const decoded = try decode(&overlong);
    try std.testing.expectEqual(@as(u8, 9), decoded.length);
    try std.testing.expectEqual(@as(u64, 0x204081020408101), decoded.value);
}
