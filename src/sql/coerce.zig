//! Shared numeric coercion: one home for text-to-number conversion.
//!
//! Prefix rule (arithmetic): longest valid prefix wins, no digits means 0.
//! Strict rule (`sign`, `ceil`, math): whole string must be numeric, else
//! NULL. `toNumeric` keeps integers as integers; `formatReal` renders
//! whole REALs with `.0`. Inputs borrow; only `formatReal` allocates.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;

/// Spaces skipped before a numeric prefix (space, tab, newline, CR, VT, FF).
fn trimSpaces(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\n\x0B\x0C\r");
}

/// Parse a leading integer; saturates on overflow, 0 if no digits.
/// Leading/trailing spaces and a sign are allowed; parsing stops at first non-digit.
pub fn parseIntPrefix(text: []const u8) i64 {
    var rest = trimSpaces(text);
    var negative = false;
    if (rest.len != 0 and (rest[0] == '+' or rest[0] == '-')) {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    var value: i64 = 0;
    var digits: usize = 0;
    const limit: i64 = if (negative) std.math.minInt(i64) else std.math.maxInt(i64);
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        digits += 1;
        const digit: i64 = @intCast(c - '0');
        if (negative) {
            if (value < @divTrunc(limit + digit, 10)) return limit;
            value = value * 10 - digit;
        } else {
            if (value > @divTrunc(limit - digit, 10)) return limit;
            value = value * 10 + digit;
        }
    }
    if (digits == 0) return 0;
    return value;
}

/// Parse a leading float; 0.0 if no digits.
/// Handles optional fraction and exponent; trailing junk is ignored.
pub fn parseFloatPrefix(text: []const u8) f64 {
    var rest = trimSpaces(text);
    var negative = false;
    if (rest.len != 0 and (rest[0] == '+' or rest[0] == '-')) {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    var index: usize = 0;
    var digits: usize = 0;
    while (index < rest.len and rest[index] >= '0' and rest[index] <= '9') : (index += 1) digits += 1;
    if (index < rest.len and rest[index] == '.') {
        index += 1;
        while (index < rest.len and rest[index] >= '0' and rest[index] <= '9') : (index += 1) digits += 1;
    }
    if (digits == 0) return 0.0;
    if (index < rest.len and (rest[index] == 'e' or rest[index] == 'E')) {
        var cursor = index + 1;
        if (cursor < rest.len and (rest[cursor] == '+' or rest[cursor] == '-')) cursor += 1;
        var expDigits: usize = 0;
        while (cursor < rest.len and rest[cursor] >= '0' and rest[cursor] <= '9') : (cursor += 1) expDigits += 1;
        if (expDigits != 0) index = cursor;
    }
    const magnitude = std.fmt.parseFloat(f64, rest[0..index]) catch 0.0;
    return if (negative) -magnitude else magnitude;
}

/// Render a REAL with a trailing `.0` for whole numbers.
/// Returns caller-owned memory.
pub fn formatReal(allocator: std.mem.Allocator, number: f64) ![]u8 {
    const rendered = try std.fmt.allocPrint(allocator, "{d}", .{number});
    errdefer allocator.free(rendered);
    for (rendered) |byte| if (byte == '.' or byte == 'e' or byte == 'E') return rendered;
    const withDot = try std.fmt.allocPrint(allocator, "{s}.0", .{rendered});
    allocator.free(rendered);
    return withDot;
}

/// Truncate toward zero with saturation: NaN->0, infinities clamp, instead of
/// trapping like a bare `@intFromFloat` on out-of-range input.
pub fn saturatingTrunc(real: f64) i64 {
    if (std.math.isNan(real)) return 0;
    if (real >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    if (real <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
    return @as(i64, @intFromFloat(@trunc(real)));
}

/// Coerce a value to float with arithmetic rules: integers/reals
/// convert, text/blob scan a longest numeric prefix (no digits -> 0.0).
/// Returns null only for NULL input, so callers keep NULL propagation by
/// branching on the optional.
pub fn toFloat(val: Value) ?f64 {
    return switch (val) {
        .null => null,
        .integer => |i| @as(f64, @floatFromInt(i)),
        .real => |r| r,
        .text => |t| parseFloatPrefix(t),
        .blob => |b| parseFloatPrefix(b),
    };
}

/// Coerce a value to integer with SQLite CAST rules: integers pass through,
/// reals truncate with saturation, text/blob scan a longest integer prefix
/// (no digits -> 0). Returns null only for NULL input.
pub fn toInt(val: Value) ?i64 {
    return switch (val) {
        .null => null,
        .integer => |i| i,
        .real => |r| saturatingTrunc(r),
        .text => |t| parseIntPrefix(t),
        .blob => |b| parseIntPrefix(b),
    };
}

/// Strict whole-string conversion for math functions and `sign`: the trimmed
/// text must be entirely numeric (optional sign, digits, optional fraction /
/// exponent; decimal only, no hex), otherwise NULL. Blobs are never numeric.
/// Integers/reals convert; NULL stays NULL.
pub fn toFloatStrict(val: Value) ?f64 {
    return switch (val) {
        .null => null,
        .integer => |i| @as(f64, @floatFromInt(i)),
        .real => |r| r,
        .text => |t| strictTextToFloat(t),
        .blob => null,
    };
}

/// Integer-preserving numeric view for arithmetic: the integer path is
/// tried first. Integer-looking
/// text/blobs (`'6'`, `'  -7  '`) yield `.int`, so `'6' * '7'` is INTEGER 42;
/// fraction/exponent/non-numeric payloads yield `.real` (`'12x'` -> 12.0,
/// `'abc'` -> 0.0); NULL yields `.none`. Callers keep three-valued logic by
/// returning NULL on `.none`, take the integer fast path when both sides are
/// `.int` (checked ops widening to REAL on overflow), and use
/// `.real` otherwise.
pub const Numeric = union(enum) {
    none,
    int: i64,
    real: f64,
};

/// Integer-preserving coercion; see `Numeric`. Single home of the prefix
/// scan for arithmetic (previously duplicated as `connection.numericValue`).
pub fn toNumeric(val: Value) Numeric {
    return switch (val) {
        .null => .none,
        .integer => |i| .{ .int = i },
        .real => |r| .{ .real = r },
        .text => |t| parseNumericText(t),
        .blob => |b| parseNumericText(b),
    };
}

/// Longest-prefix scan distinguishing integer from real payloads: optional
/// spaces/sign, digit run, optional fraction (needs a digit after the dot to
/// count), optional exponent. No digits at all -> real 0.0. Integer results
/// saturate through the float path when they overflow i64.
///
/// Integer-vs-real rule: the
/// integer path requires the whole payload to convert (trailing spaces are
/// allowed, trailing junk is not), so `'6'` is `.int` but `'12x'` is
/// `.real`. Overflowed digit runs also land on `.real`.
fn parseNumericText(bytes: []const u8) Numeric {
    var i: usize = 0;
    while (i < bytes.len and isSpaceByte(bytes[i])) i += 1;
    const numStart = i;
    if (i < bytes.len and (bytes[i] == '+' or bytes[i] == '-')) i += 1;
    const intStart = i;
    while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') i += 1;
    const hasIntDigits = i > intStart;
    var isFloat = false;
    if (i < bytes.len and bytes[i] == '.') {
        var j = i + 1;
        while (j < bytes.len and bytes[j] >= '0' and bytes[j] <= '9') j += 1;
        if (j > i + 1) {
            isFloat = true;
            i = j;
        }
    }
    if (i < bytes.len and (bytes[i] == 'e' or bytes[i] == 'E') and (hasIntDigits or isFloat)) {
        var j = i + 1;
        if (j < bytes.len and (bytes[j] == '+' or bytes[j] == '-')) j += 1;
        const expStart = j;
        while (j < bytes.len and bytes[j] >= '0' and bytes[j] <= '9') j += 1;
        if (j > expStart) {
            isFloat = true;
            i = j;
        }
    }
    if (!hasIntDigits and !isFloat) return .{ .real = 0.0 };
    // Trailing spaces are allowed; trailing junk forces the real path.
    var end = i;
    while (end < bytes.len and isSpaceByte(bytes[end])) end += 1;
    const token = bytes[numStart..i];
    if (end == bytes.len and !isFloat) {
        if (std.fmt.parseInt(i64, token, 10)) |n| return .{ .int = n } else |_| {}
        if (std.fmt.parseFloat(f64, token)) |n| return .{ .real = n } else |_| {}
        return .{ .real = 0.0 };
    }
    if (std.fmt.parseFloat(f64, token)) |n| return .{ .real = n } else |_| {}
    return .{ .real = 0.0 };
}

fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

/// `<<`: a negative
/// amount shifts the other way (clamped at 64); amounts >= 64 yield 0 for
/// non-negative values and -1 for negative ones; the shift itself wraps mod
/// 2**64 via u64 arithmetic. Single home for the interpreter, VM, and
/// expression-evaluator shift paths.
pub fn shiftLeft(value: i64, amount: i64) i64 {
    var toLeft = true;
    var count = amount;
    if (count < 0) {
        toLeft = false;
        count = if (count > -64) -count else 64;
    }
    if (count >= 64) return if (value >= 0 or toLeft) 0 else -1;
    const bits: u64 = @bitCast(value);
    const narrow: u6 = @intCast(count);
    if (toLeft) return @bitCast(bits << narrow);
    return value >> narrow;
}

/// `>>`: same rules with the direction flipped.
pub fn shiftRight(value: i64, amount: i64) i64 {
    var toRight = true;
    var count = amount;
    if (count < 0) {
        toRight = false;
        count = if (count > -64) -count else 64;
    }
    if (count >= 64) return if (value >= 0 or !toRight) 0 else -1;
    const bits: u64 = @bitCast(value);
    const narrow: u6 = @intCast(count);
    if (!toRight) return @bitCast(bits << narrow);
    return value >> narrow;
}

/// Whole-string text scan for `toFloatStrict`: trimmed input must be fully
/// consumed as `[+-]?digits[.digits][e[+-]digits]` or `[+-]?.digits[e…]`
/// (decimal only — no hex, no `inf`/`nan` spellings, matching decimal-only
/// decimal-only strictness); trailing junk fails.
/// Integers prefer the exact `parseInt` path so large magnitudes keep full
/// precision where a float parse would round. Known residual: a trailing dot
/// directly before an exponent (`5.e2`) is rejected, since
/// `parseFloat` cannot consume it without a normalization allocation.
fn strictTextToFloat(text: []const u8) ?f64 {
    const trimmed = trimSpaces(text);
    if (trimmed.len == 0) return null;
    var i: usize = 0;
    if (trimmed[0] == '+' or trimmed[0] == '-') i = 1;
    const intStart = i;
    while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') i += 1;
    const intDigits = i - intStart;
    var fracDigits: usize = 0;
    if (i < trimmed.len and trimmed[i] == '.') {
        i += 1;
        const fracStart = i;
        while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') i += 1;
        fracDigits = i - fracStart;
    }
    if (intDigits == 0 and fracDigits == 0) return null;
    if (i < trimmed.len and (trimmed[i] == 'e' or trimmed[i] == 'E')) {
        i += 1;
        if (i < trimmed.len and (trimmed[i] == '+' or trimmed[i] == '-')) i += 1;
        const expStart = i;
        while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') i += 1;
        if (i == expStart) return null;
    }
    if (i != trimmed.len) return null;
    // Bare trailing dot ("5.") is valid input but not for parseFloat.
    const numeric = if (trimmed[trimmed.len - 1] == '.') trimmed[0 .. trimmed.len - 1] else trimmed;
    if (std.fmt.parseInt(i64, numeric, 10) catch null) |n| return @as(f64, @floatFromInt(n));
    return std.fmt.parseFloat(f64, numeric) catch null;
}

test "prefix scans share one longest-valid-prefix rule" {
    try std.testing.expectEqual(@as(i64, 12), parseIntPrefix("  12x"));
    try std.testing.expectEqual(@as(i64, -12), parseIntPrefix("-12.9"));
    try std.testing.expectEqual(@as(i64, 0), parseIntPrefix(""));
    try std.testing.expectEqual(@as(i64, 0), parseIntPrefix("abc"));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), parseIntPrefix("9999999999999999999999"));
    try std.testing.expectEqual(@as(f64, 3.5), parseFloatPrefix("  3.5  "));
    try std.testing.expectEqual(@as(f64, 12.0), parseFloatPrefix("12x"));
    try std.testing.expectEqual(@as(f64, 0.0), parseFloatPrefix(""));
    try std.testing.expectEqual(@as(f64, 0.0), parseFloatPrefix("abc"));
    try std.testing.expectEqual(@as(f64, 100.0), parseFloatPrefix("1e2junk"));
}

test "saturating conversions never trap" {
    try std.testing.expectEqual(@as(i64, 0), saturatingTrunc(std.math.nan(f64)));
    try std.testing.expectEqual(std.math.maxInt(i64), saturatingTrunc(std.math.inf(f64)));
    try std.testing.expectEqual(std.math.minInt(i64), saturatingTrunc(-std.math.inf(f64)));
    try std.testing.expectEqual(@as(i64, 3), saturatingTrunc(3.99));
    try std.testing.expectEqual(@as(i64, -3), saturatingTrunc(-3.99));
}

test "value coercion matrix is identical for every caller" {
    const cases = [_]struct { in: Value, f: f64, i: i64 }{
        .{ .in = .null, .f = 0.0, .i = 0 },
        .{ .in = .{ .integer = 7 }, .f = 7.0, .i = 7 },
        .{ .in = .{ .real = 2.5 }, .f = 2.5, .i = 2 },
        .{ .in = .{ .text = "  12x" }, .f = 12.0, .i = 12 },
        .{ .in = .{ .text = "3.5" }, .f = 3.5, .i = 3 },
        .{ .in = .{ .text = "" }, .f = 0.0, .i = 0 },
        .{ .in = .{ .text = "abc" }, .f = 0.0, .i = 0 },
        .{ .in = .{ .blob = "9lives" }, .f = 9.0, .i = 9 },
    };
    for (cases) |c| {
        if (c.in == .null) {
            try std.testing.expect(toFloat(c.in) == null);
            try std.testing.expect(toInt(c.in) == null);
        } else {
            try std.testing.expectEqual(c.f, toFloat(c.in).?);
            try std.testing.expectEqual(c.i, toInt(c.in).?);
        }
    }
}

test "strict conversion requires whole-string numbers" {
    // Shared by math functions and sign(): '12x', '0x2A', '', and blobs are
    // not numbers (strict conversion needs a lossless whole-string match),
    // conversion), while padded decimals convert exactly.
    const strict = [_]struct { in: Value, out: ?f64 }{
        .{ .in = .null, .out = null },
        .{ .in = .{ .integer = 7 }, .out = 7.0 },
        .{ .in = .{ .real = 2.5 }, .out = 2.5 },
        .{ .in = .{ .text = "  3.5  " }, .out = 3.5 },
        .{ .in = .{ .text = "-12" }, .out = -12.0 },
        .{ .in = .{ .text = "1e2" }, .out = 100.0 },
        .{ .in = .{ .text = "12x" }, .out = null },
        .{ .in = .{ .text = "abc" }, .out = null },
        .{ .in = .{ .text = "" }, .out = null },
        .{ .in = .{ .text = "0x2A" }, .out = null },
        .{ .in = .{ .blob = "12" }, .out = null },
    };
    for (strict) |c| {
        const got = toFloatStrict(c.in);
        if (c.out) |want| {
            try std.testing.expectEqual(want, got.?);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "real rendering keeps whole-number decimal points" {
    const whole = try formatReal(std.testing.allocator, 7.0);
    defer std.testing.allocator.free(whole);
    try std.testing.expectEqualStrings("7.0", whole);
    const frac = try formatReal(std.testing.allocator, 7.5);
    defer std.testing.allocator.free(frac);
    try std.testing.expectEqualStrings("7.5", frac);
}

test "integer-preserving coercion keeps whole numbers as integers" {
    // Integer-looking text stays INTEGER through arithmetic, so
    // text stays INTEGER through arithmetic, so typeof('6'*'7') is integer.
    try std.testing.expect(toNumeric(.null) == .none);
    try std.testing.expectEqual(@as(i64, 7), toNumeric(.{ .integer = 7 }).int);
    try std.testing.expectEqual(@as(f64, 2.5), toNumeric(.{ .real = 2.5 }).real);
    try std.testing.expectEqual(@as(i64, 6), toNumeric(.{ .text = "6" }).int);
    try std.testing.expectEqual(@as(i64, -7), toNumeric(.{ .text = "  -7  " }).int);
    try std.testing.expectEqual(@as(f64, 9.0), toNumeric(.{ .blob = "9lives" }).real);
    try std.testing.expectEqual(@as(f64, 12.0), toNumeric(.{ .text = "12x" }).real);
    try std.testing.expectEqual(@as(f64, 3.5), toNumeric(.{ .text = "3.5" }).real);
    try std.testing.expectEqual(@as(f64, 100.0), toNumeric(.{ .text = "1e2" }).real);
    try std.testing.expectEqual(@as(f64, 0.0), toNumeric(.{ .text = "abc" }).real);
    try std.testing.expectEqual(@as(f64, 0.0), toNumeric(.{ .text = "" }).real);
}

test "shifts flip direction on negative amounts and clamp past 63" {
    try std.testing.expectEqual(@as(i64, 8), shiftLeft(1, 3));
    try std.testing.expectEqual(@as(i64, 2), shiftLeft(4, -1));
    try std.testing.expectEqual(@as(i64, 0), shiftLeft(1, 64));
    try std.testing.expectEqual(@as(i64, 1), shiftRight(8, 3));
    try std.testing.expectEqual(@as(i64, -1), shiftRight(-8, 3));
    try std.testing.expectEqual(@as(i64, 2), shiftRight(1, -1));
    try std.testing.expectEqual(@as(i64, -1), shiftRight(-1, 64));
    try std.testing.expectEqual(@as(i64, 0), shiftRight(1, 64));
}
