const std = @import("std");
const Value = @import("../../vm/value.zig").Value;
const affinityOf = @import("../../catalog/type_affinity.zig").fromDeclaration;

fn trimSpaces(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\n\x0B\x0C\r");
}

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

pub fn formatReal(allocator: std.mem.Allocator, number: f64) ![]u8 {
    const rendered = try std.fmt.allocPrint(allocator, "{d}", .{number});
    errdefer allocator.free(rendered);
    for (rendered) |byte| if (byte == '.' or byte == 'e' or byte == 'E') return rendered;
    const withDot = try std.fmt.allocPrint(allocator, "{s}.0", .{rendered});
    allocator.free(rendered);
    return withDot;
}

pub fn isTruthyValue(value: Value) bool {
    return switch (value) {
        .null => false,
        .integer => |n| n != 0,
        .real => |n| n != 0.0,
        .text => |t| parseFloatPrefix(t) != 0.0,
        .blob => |b| parseFloatPrefix(b) != 0.0,
    };
}

pub fn evalAbs(arg: Value) anyerror!Value {
    return switch (arg) {
        .null => .null,
        .integer => |i| .{ .integer = if (i == std.math.minInt(i64)) return error.IntegerOverflow else @as(i64, @intCast(@abs(i))) },
        .real => |r| .{ .real = @abs(r) },
        .text => |t| .{ .real = @abs(parseFloatPrefix(t)) },
        .blob => |b| .{ .real = @abs(parseFloatPrefix(b)) },
    };
}

pub fn evalLower(allocator: std.mem.Allocator, arg: Value) !Value {
    switch (arg) {
        .text => |t| {
            const buf = try allocator.alloc(u8, t.len);
            for (t, 0..) |c, i| buf[i] = std.ascii.toLower(c);
            return .{ .text = buf };
        },
        else => return try arg.clone(allocator),
    }
}

pub fn evalUpper(allocator: std.mem.Allocator, arg: Value) !Value {
    switch (arg) {
        .text => |t| {
            const buf = try allocator.alloc(u8, t.len);
            for (t, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
            return .{ .text = buf };
        },
        else => return try arg.clone(allocator),
    }
}

pub fn evalLength(allocator: std.mem.Allocator, arg: Value) !Value {
    return switch (arg) {
        .null => .null,
        .text => |t| .{ .integer = @intCast(utf8Count(t)) },
        .blob => |b| .{ .integer = @intCast(b.len) },
        .integer => |i| blk: {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "";
            break :blk .{ .integer = @intCast(s.len) };
        },
        .real => |r| blk: {
            const s = try formatReal(allocator, r);
            defer allocator.free(s);
            break :blk .{ .integer = @intCast(s.len) };
        },
    };
}

fn utf8Count(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const sequenceLen = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        index += @min(sequenceLen, text.len - index);
        count += 1;
    }
    return count;
}

fn utf8CharAt(text: []const u8, charIndex: usize) ?[]const u8 {
    var current: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const sequenceLen = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const next = index + @min(sequenceLen, text.len - index);
        if (current == charIndex) return text[index..next];
        index = next;
        current += 1;
    }
    return null;
}

pub fn evalRound(arg: Value, precisionArg: ?Value) Value {
    if (arg == .null) return .null;
    const num: f64 = switch (arg) {
        .integer => |i| @floatFromInt(i),
        .real => |r| r,
        .text => |t| parseFloatPrefix(t),
        .blob => |b| parseFloatPrefix(b),
        .null => unreachable,
    };
    var decimals: i64 = 0;
    if (precisionArg) |pv| {
        if (pv == .null) return .null;
        decimals = switch (pv) {
            .integer => |i| i,
            .real => |r| saturatingTrunc(r),
            .text => |t| parseIntPrefix(t),
            .blob => |b| parseIntPrefix(b),
            .null => unreachable,
        };
    }
    if (decimals == 0) {
        return .{ .real = @round(num) };
    }
    const decClamped = @max(-30, @min(30, decimals));
    const factor = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(@abs(decClamped))));
    if (decClamped > 0) {
        return .{ .real = @round(num * factor) / factor };
    } else {
        return .{ .real = @round(num / factor) * factor };
    }
}

pub fn evalTypeof(allocator: std.mem.Allocator, arg: Value) !Value {
    return .{ .text = try allocator.dupe(u8, arg.typeName()) };
}

pub fn evalCoalesce(allocator: std.mem.Allocator, args: []const Value) !Value {
    for (args) |a| {
        if (a != .null) return try a.clone(allocator);
    }
    return .null;
}

pub fn evalIfnull(allocator: std.mem.Allocator, a: Value, b: Value) !Value {
    if (a != .null) return try a.clone(allocator);
    return try b.clone(allocator);
}

pub fn evalNullif(allocator: std.mem.Allocator, a: Value, b: Value) !Value {
    if (a.sameValue(b)) return .null;
    return try a.clone(allocator);
}

fn coerceText(allocator: std.mem.Allocator, val: Value) !?[]const u8 {
    return switch (val) {
        .null => null,
        .text => |t| t,
        .blob => |b| b,
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .real => |r| try formatReal(allocator, r),
    };
}

pub fn evalInstr(allocator: std.mem.Allocator, haystack: Value, needle: Value) !Value {
    if (haystack == .null or needle == .null) return .null;
    const hBytes = try coerceText(allocator, haystack) orelse return .null;
    defer if (haystack != .text and haystack != .blob) allocator.free(hBytes);
    const nBytes = try coerceText(allocator, needle) orelse return .null;
    defer if (needle != .text and needle != .blob) allocator.free(nBytes);
    if (nBytes.len == 0) return .{ .integer = 1 };
    if (std.mem.indexOf(u8, hBytes, nBytes)) |pos| {
        return .{ .integer = @intCast(pos + 1) };
    }
    return .{ .integer = 0 };
}

pub fn evalReplace(allocator: std.mem.Allocator, orig: Value, from: Value, to: Value) !Value {
    if (orig == .null or from == .null or to == .null) return .null;
    const origText = try coerceText(allocator, orig) orelse return .null;
    defer if (orig != .text and orig != .blob) allocator.free(origText);
    const fromText = try coerceText(allocator, from) orelse return .null;
    defer if (from != .text and from != .blob) allocator.free(fromText);
    const toText = try coerceText(allocator, to) orelse return .null;
    defer if (to != .text and to != .blob) allocator.free(toText);
    return evalReplaceText(allocator, origText, fromText, toText);
}

fn evalReplaceText(allocator: std.mem.Allocator, orig: []const u8, from: []const u8, to: []const u8) !Value {
    if (from.len == 0) {
        return .{ .text = try allocator.dupe(u8, orig) };
    }
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, orig, offset, from)) |pos| {
        try out.appendSlice(allocator, orig[offset..pos]);
        try out.appendSlice(allocator, to);
        offset = pos + from.len;
    }
    try out.appendSlice(allocator, orig[offset..]);
    return .{ .text = try out.toOwnedSlice(allocator) };
}

fn saturatingTrunc(real: f64) i64 {
    if (std.math.isNan(real)) return 0;
    if (real >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    if (real <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
    return @as(i64, @intFromFloat(@trunc(real)));
}

fn absUnsigned(value: i64) usize {
    if (value == std.math.minInt(i64)) return @as(usize, @intCast(std.math.maxInt(i64))) + 1;
    return @as(usize, @intCast(if (value < 0) -value else value));
}

fn substrArgInt(val: Value) ?i64 {
    return switch (val) {
        .null => null,
        .integer => |i| i,
        .real => |r| saturatingTrunc(r),
        .text => |t| parseIntPrefix(t),
        .blob => |b| parseIntPrefix(b),
    };
}

pub fn evalSubstr(allocator: std.mem.Allocator, strVal: Value, startVal: Value, lenVal: ?Value) !Value {
    if (strVal == .null or startVal == .null) return .null;
    const isBlob = strVal == .blob;
    const ownedText: ?[]u8 = switch (strVal) {
        .text, .blob => null,
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .real => |r| try formatReal(allocator, r),
        .null => return .null,
    };
    defer if (ownedText) |text| allocator.free(text);
    const bytes: []const u8 = ownedText orelse switch (strVal) {
        .text => |t| t,
        .blob => |b| b,
        else => unreachable,
    };
    const charCount = if (isBlob) bytes.len else utf8Count(bytes);
    const charAt = struct {
        fn at(source: []const u8, charBlob: bool, index: usize) usize {
            if (charBlob) return @min(index, source.len);
            var current: usize = 0;
            var offset: usize = 0;
            while (offset < source.len and current < index) {
                const sequenceLen = std.unicode.utf8ByteSequenceLength(source[offset]) catch 1;
                offset += @min(sequenceLen, source.len - offset);
                current += 1;
            }
            return offset;
        }
    }.at;
    const startNum = substrArgInt(startVal) orelse return .null;
    var startChar: usize = 0;
    if (startNum > 0) {
        startChar = @min(@as(usize, @intCast(startNum - 1)), charCount);
    } else if (startNum < 0) {
        const fromEnd = absUnsigned(startNum);
        startChar = if (fromEnd > charCount) 0 else charCount - fromEnd;
    }
    var endChar: usize = charCount;
    if (lenVal) |lv| {
        const lenNum = substrArgInt(lv) orelse return .null;
        if (lenNum < 0) {
            const negLen = absUnsigned(lenNum);
            const actualStart = if (negLen > startChar) 0 else startChar - negLen;
            endChar = startChar;
            startChar = actualStart;
        } else {
            endChar = @min(charCount, startChar +% @as(usize, @intCast(lenNum)));
        }
    }
    if (startChar > endChar) startChar = endChar;
    const startByte = charAt(bytes, isBlob, startChar);
    const endByte = charAt(bytes, isBlob, endChar);
    const sliced = try allocator.dupe(u8, bytes[startByte..endByte]);
    if (isBlob) return .{ .blob = sliced };
    return .{ .text = sliced };
}

pub fn evalTrim(allocator: std.mem.Allocator, strVal: Value, charsVal: ?Value, mode: enum { both, left, right }) !Value {
    if (strVal == .null) return .null;
    const ownedText: ?[]u8 = switch (strVal) {
        .text, .blob => null,
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .real => |r| try formatReal(allocator, r),
        .null => return .null,
    };
    defer if (ownedText) |text| allocator.free(text);
    const source: []const u8 = ownedText orelse switch (strVal) {
        .text => |t| t,
        .blob => |b| b,
        else => unreachable,
    };
    var trimChars: []const u8 = " \t\r\n";
    var ownedChars: ?[]const u8 = null;
    defer if (ownedChars) |chars| allocator.free(chars);
    if (charsVal) |cv| {
        switch (cv) {
            .null => return .null,
            .text => |t| trimChars = t,
            .blob => |b| trimChars = b,
            else => {
                ownedChars = try coerceText(allocator, cv);
                trimChars = ownedChars.?;
            },
        }
    }
    var start: usize = 0;
    var end: usize = source.len;
    if (mode == .both or mode == .left) {
        while (start < end and std.mem.indexOfScalar(u8, trimChars, source[start]) != null) : (start += 1) {}
    }
    if (mode == .both or mode == .right) {
        while (end > start and std.mem.indexOfScalar(u8, trimChars, source[end - 1]) != null) : (end -= 1) {}
    }
    return .{ .text = try allocator.dupe(u8, source[start..end]) };
}

pub fn evalCast(allocator: std.mem.Allocator, val: Value, targetType: []const u8) !Value {
    return switch (affinityOf(targetType)) {
        .integer => switch (val) {
            .null => .null,
            .integer => val,
            .real => |r| .{ .integer = saturatingTrunc(r) },
            .text => |t| .{ .integer = saturatingTrunc(parseFloatPrefix(t)) },
            .blob => |b| .{ .integer = saturatingTrunc(parseFloatPrefix(b)) },
        },
        .real => switch (val) {
            .null => .null,
            .integer => |i| .{ .real = @floatFromInt(i) },
            .real => val,
            .text => |t| .{ .real = parseFloatPrefix(t) },
            .blob => |b| .{ .real = parseFloatPrefix(b) },
        },
        .text => switch (val) {
            .null => .null,
            .text => |t| .{ .text = try allocator.dupe(u8, t) },
            .blob => |b| .{ .text = try allocator.dupe(u8, b) },
            .integer => |i| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
            .real => |r| .{ .text = try formatReal(allocator, r) },
        },
        .blob => switch (val) {
            .null => .null,
            .blob => |b| .{ .blob = try allocator.dupe(u8, b) },
            .text => |t| .{ .blob = try allocator.dupe(u8, t) },
            .integer => |i| .{ .blob = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
            .real => |r| .{ .blob = try formatReal(allocator, r) },
        },
        .numeric => switch (val) {
            .null => .null,
            .integer => val,
            .real => val,
            .text => |t| blk: {
                const trimmed = std.mem.trim(u8, t, " \t\r\n");
                if (std.fmt.parseInt(i64, trimmed, 10)) |n| {
                    break :blk .{ .integer = n };
                } else |_| {}
                if (std.fmt.parseFloat(f64, trimmed)) |r| {
                    if (!std.math.isNan(r) and !std.math.isInf(r)) break :blk .{ .real = r };
                } else |_| {}
                break :blk val;
            },
            .blob => val,
        },
    };
}

pub fn evalHex(allocator: std.mem.Allocator, val: Value) !Value {
    if (val == .null) return .null;
    var owned: ?[]u8 = null;
    defer if (owned) |bytes| allocator.free(bytes);
    const bytes: []const u8 = switch (val) {
        .null => unreachable,
        .text => |t| t,
        .blob => |b| b,
        .integer => |i| blk: {
            owned = try std.fmt.allocPrint(allocator, "{d}", .{i});
            break :blk owned.?;
        },
        .real => |r| blk: {
            owned = try formatReal(allocator, r);
            break :blk owned.?;
        },
    };
    const hexCharset = "0123456789ABCDEF";
    const hexStr = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        hexStr[i * 2] = hexCharset[b >> 4];
        hexStr[i * 2 + 1] = hexCharset[b & 0x0F];
    }
    return .{ .text = hexStr };
}

pub fn evalUnhex(allocator: std.mem.Allocator, val: Value, ignoreVal: ?Value) !Value {
    if (val == .null) return .null;
    if (val != .text) return .null;
    var ignored: []const u8 = "";
    if (ignoreVal) |iv| {
        if (iv == .text) ignored = iv.text;
    }
    var clean = std.ArrayList(u8).empty;
    defer clean.deinit(allocator);
    for (val.text) |ch| {
        if (ignored.len > 0 and std.mem.indexOfScalar(u8, ignored, ch) != null) continue;
        try clean.append(allocator, ch);
    }
    if (clean.items.len % 2 != 0) return .null;
    const out = try allocator.alloc(u8, clean.items.len / 2);
    _ = std.fmt.hexToBytes(out, clean.items) catch {
        allocator.free(out);
        return .null;
    };
    return .{ .blob = out };
}

pub fn evalQuote(allocator: std.mem.Allocator, val: Value) !Value {
    switch (val) {
        .null => return .{ .text = try allocator.dupe(u8, "NULL") },
        .integer => |i| return .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
        .real => |r| return .{ .text = try formatReal(allocator, r) },
        .text => |t| {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(allocator);
            try out.append(allocator, '\'');
            for (t) |c| {
                if (c == '\'') try out.append(allocator, '\'');
                try out.append(allocator, c);
            }
            try out.append(allocator, '\'');
            return .{ .text = try out.toOwnedSlice(allocator) };
        },
        .blob => |b| {
            const hexCharset = "0123456789ABCDEF";
            var out = std.ArrayList(u8).empty;
            defer out.deinit(allocator);
            try out.appendSlice(allocator, "X'");
            for (b) |byte| {
                try out.append(allocator, hexCharset[byte >> 4]);
                try out.append(allocator, hexCharset[byte & 0x0F]);
            }
            try out.append(allocator, '\'');
            return .{ .text = try out.toOwnedSlice(allocator) };
        },
    }
}

pub fn evalChar(allocator: std.mem.Allocator, args: []const Value) !Value {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var buf: [4]u8 = undefined;
    for (args) |arg| {
        const raw: i64 = switch (arg) {
            .null => 0,
            .integer => |i| i,
            .real => |r| if (r >= @as(f64, @floatFromInt(std.math.minInt(i64))) and r <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) @as(i64, @intFromFloat(r)) else std.math.maxInt(i64),
            .text => |t| parseIntPrefix(t),
            .blob => |b| parseIntPrefix(b),
        };
        const code: u21 = if (raw >= 0 and raw <= 0x10FFFF) @as(u21, @intCast(raw)) else 0xFFFD;
        const len = std.unicode.utf8Encode(code, &buf) catch continue;
        try out.appendSlice(allocator, buf[0..len]);
    }
    return .{ .text = try out.toOwnedSlice(allocator) };
}

pub fn evalUnicode(allocator: std.mem.Allocator, arg: Value) !Value {
    const str = switch (arg) {
        .null => return .null,
        .text => |t| t,
        .integer => |i| blk: {
            var buf: [32]u8 = undefined;
            break :blk try allocator.dupe(u8, std.fmt.bufPrint(&buf, "{d}", .{i}) catch "");
        },
        .real => |r| blk: {
            break :blk try formatReal(allocator, r);
        },
        .blob => |b| b,
    };
    defer if (arg != .text and arg != .blob) allocator.free(str);
    if (str.len == 0) return .null;
    const len = std.unicode.utf8ByteSequenceLength(str[0]) catch 1;
    const slice = str[0..@min(len, str.len)];
    const cp = std.unicode.utf8Decode(slice) catch str[0];
    return .{ .integer = @intCast(cp) };
}

pub fn evalPrintf(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len == 0 or args[0] == .null) return .null;
    const fmt = switch (args[0]) {
        .text => |t| t,
        else => return .null,
    };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var argIdx: usize = 1;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            const spec = fmt[i + 1];
            if (spec == '%') {
                try out.append(allocator, '%');
                i += 1;
                continue;
            }
            if (argIdx < args.len) {
                const val = args[argIdx];
                argIdx += 1;
                if (spec == 'd' or spec == 'i') {
                    const intVal: i64 = switch (val) {
                        .integer => |n| n,
                        .real => |r| @intFromFloat(r),
                        .text => |t| std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10) catch 0,
                        else => 0,
                    };
                    var b: [32]u8 = undefined;
                    const s = try std.fmt.bufPrint(&b, "{d}", .{intVal});
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                }
                if (spec == 'u') {
                    const uVal: u64 = switch (val) {
                        .integer => |n| @bitCast(n),
                        .real => |r| if (r >= 0) @intFromFloat(r) else 0,
                        else => 0,
                    };
                    var b: [32]u8 = undefined;
                    const s = try std.fmt.bufPrint(&b, "{d}", .{uVal});
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                }
                if (spec == 'f' or spec == 'g') {
                    const rVal: f64 = switch (val) {
                        .real => |r| r,
                        .integer => |n| @floatFromInt(n),
                        .text => |t| std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch 0.0,
                        else => 0.0,
                    };
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{rVal});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                }
                if (spec == 's') {
                    switch (val) {
                        .text => |t| try out.appendSlice(allocator, t),
                        .blob => |b| try out.appendSlice(allocator, b),
                        .integer => |n| {
                            var b: [32]u8 = undefined;
                            const s = try std.fmt.bufPrint(&b, "{d}", .{n});
                            try out.appendSlice(allocator, s);
                        },
                        .real => |r| {
                            const s = try std.fmt.allocPrint(allocator, "{d}", .{r});
                            defer allocator.free(s);
                            try out.appendSlice(allocator, s);
                        },
                        .null => {},
                    }
                    i += 1;
                    continue;
                }
                if (spec == 'x' or spec == 'X') {
                    const intVal: u64 = switch (val) {
                        .integer => |n| @bitCast(n),
                        .real => |r| if (r >= 0) @intFromFloat(r) else 0,
                        else => 0,
                    };
                    var b: [32]u8 = undefined;
                    const s = if (spec == 'x')
                        try std.fmt.bufPrint(&b, "{x}", .{intVal})
                    else
                        try std.fmt.bufPrint(&b, "{X}", .{intVal});
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                }
                if (spec == 'q') {
                    const qVal = try evalQuote(allocator, val);
                    if (qVal == .text) {
                        defer allocator.free(qVal.text);
                        try out.appendSlice(allocator, qVal.text);
                    }
                    i += 1;
                    continue;
                }
            }
        }
        try out.append(allocator, fmt[i]);
    }
    return .{ .text = try out.toOwnedSlice(allocator) };
}

pub fn evalConcat(allocator: std.mem.Allocator, args: []const Value) !Value {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (args) |arg| {
        switch (arg) {
            .null => continue,
            .text => |t| try out.appendSlice(allocator, t),
            .blob => |b| try out.appendSlice(allocator, b),
            .integer => |i| {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
                defer allocator.free(s);
                try out.appendSlice(allocator, s);
            },
            .real => |r| {
                const s = try formatReal(allocator, r);
                defer allocator.free(s);
                try out.appendSlice(allocator, s);
            },
        }
    }
    return .{ .text = try out.toOwnedSlice(allocator) };
}

pub fn evalConcatWs(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len == 0) return error.InvalidArgumentCount;
    if (args[0] == .null) return .null;
    const sep = try coerceText(allocator, args[0]) orelse return .null;
    defer if (args[0] != .text and args[0] != .blob) allocator.free(sep);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var first = true;
    for (args[1..]) |arg| {
        if (arg == .null) continue;
        if (!first) try out.appendSlice(allocator, sep);
        first = false;
        switch (arg) {
            .null => unreachable,
            .text => |t| try out.appendSlice(allocator, t),
            .blob => |b| try out.appendSlice(allocator, b),
            .integer => |i| {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
                defer allocator.free(s);
                try out.appendSlice(allocator, s);
            },
            .real => |r| {
                const s = try formatReal(allocator, r);
                defer allocator.free(s);
                try out.appendSlice(allocator, s);
            },
        }
    }
    return .{ .text = try out.toOwnedSlice(allocator) };
}

pub fn evalOctetLength(allocator: std.mem.Allocator, arg: Value) !Value {
    return switch (arg) {
        .null => .null,
        .text => |t| .{ .integer = @intCast(t.len) },
        .blob => |b| .{ .integer = @intCast(b.len) },
        .integer => |i| blk: {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "";
            break :blk .{ .integer = @intCast(s.len) };
        },
        .real => |r| blk: {
            const s = try formatReal(allocator, r);
            defer allocator.free(s);
            break :blk .{ .integer = @intCast(s.len) };
        },
    };
}

pub fn evalZeroblob(allocator: std.mem.Allocator, arg: Value) !Value {
    const count: i64 = switch (arg) {
        .null => 0,
        .integer => |i| i,
        .real => |r| saturatingTrunc(r),
        .text => |t| parseIntPrefix(t),
        .blob => |b| parseIntPrefix(b),
    };
    if (count <= 0) return .{ .blob = try allocator.alloc(u8, 0) };
    const out = try allocator.alloc(u8, @intCast(count));
    @memset(out, 0);
    return .{ .blob = out };
}

pub fn evalSign(arg: Value) Value {
    switch (arg) {
        .null => return .null,
        .integer => |i| return .{ .integer = if (i < 0) -1 else if (i > 0) 1 else 0 },
        .real => |r| return .{ .integer = if (r < 0.0) -1 else if (r > 0.0) 1 else 0 },
        .text => |t| {
            const trimmed = trimSpaces(t);
            if (std.fmt.parseInt(i64, trimmed, 10)) |i| {
                return .{ .integer = if (i < 0) -1 else if (i > 0) 1 else 0 };
            } else |_| {
                if (std.fmt.parseFloat(f64, trimmed)) |r| {
                    if (std.math.isNan(r)) return .null;
                    return .{ .integer = if (r < 0.0) -1 else if (r > 0.0) 1 else 0 };
                } else |_| {}
                return .null;
            }
        },
        .blob => return .null,
    }
}

pub fn evalIif(allocator: std.mem.Allocator, cond: Value, whenTrue: Value, whenFalse: Value) !Value {
    if (isTruthyValue(cond)) return try whenTrue.clone(allocator);
    return try whenFalse.clone(allocator);
}

pub fn evalUnlikely(allocator: std.mem.Allocator, arg: Value) !Value {
    return try arg.clone(allocator);
}

const RandomState = struct {
    var prng: ?std.Random.DefaultPrng = null;
    var counter: u64 = 0x9E3779B97F4A7C15;

    fn random() std.Random {
        if (prng == null) {
            var marker: u8 = 0;
            counter +%= 1;
            var seed: u64 = @as(u64, @intCast(@intFromPtr(&marker))) ^ (counter *% 0xBF58476D1CE4E5B9);
            seed ^= seed >> 29;
            seed *%= 0xBF58476D1CE4E5B9;
            seed ^= seed >> 32;
            prng = std.Random.DefaultPrng.init(seed);
        }
        return prng.?.random();
    }
};

pub fn evalRandom(allocator: std.mem.Allocator) !Value {
    _ = allocator;
    return .{ .integer = RandomState.random().int(i64) };
}

pub fn evalRandomblob(allocator: std.mem.Allocator, arg: Value) !Value {
    var count: i64 = switch (arg) {
        .null => 0,
        .integer => |i| i,
        .real => |r| saturatingTrunc(r),
        .text => |t| parseIntPrefix(t),
        .blob => |b| parseIntPrefix(b),
    };
    if (count < 1) count = 1;
    const out = try allocator.alloc(u8, @intCast(count));
    RandomState.random().bytes(out);
    return .{ .blob = out };
}

pub fn evalSqliteVersion(allocator: std.mem.Allocator) !Value {
    return .{ .text = try allocator.dupe(u8, @import("../../version.zig").sqliteEngineVersion) };
}

pub fn evalSqliteSourceId(allocator: std.mem.Allocator) !Value {
    return .{ .text = try std.fmt.allocPrint(allocator, "{s}|sqlite.zig-native", .{@import("../../version.zig").sqliteEngineVersion}) };
}

pub fn evalJsonQuote(allocator: std.mem.Allocator, val: Value) !Value {
    switch (val) {
        .null => return .{ .text = try allocator.dupe(u8, "null") },
        .integer => |i| return .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
        .real => |r| return .{ .text = try formatReal(allocator, r) },
        .text => |t| {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(allocator);
            try out.append(allocator, '"');
            for (t) |c| {
                if (c == '"') {
                    try out.appendSlice(allocator, "\\\"");
                } else if (c == '\\') {
                    try out.appendSlice(allocator, "\\\\");
                } else if (c == 0x08) {
                    try out.appendSlice(allocator, "\\b");
                } else if (c == 0x0C) {
                    try out.appendSlice(allocator, "\\f");
                } else if (c == '\n') {
                    try out.appendSlice(allocator, "\\n");
                } else if (c == '\r') {
                    try out.appendSlice(allocator, "\\r");
                } else if (c == '\t') {
                    try out.appendSlice(allocator, "\\t");
                } else if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, hex[c >> 4]);
                    try out.append(allocator, hex[c & 0x0F]);
                } else {
                    try out.append(allocator, c);
                }
            }
            try out.append(allocator, '"');
            return .{ .text = try out.toOwnedSlice(allocator) };
        },
        .blob => return error.InvalidSql,
    }
}

fn appendUtf8(allocator: std.mem.Allocator, out: *std.ArrayList(u8), code: u32) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@as(u21, @intCast(@min(code, 0x10FFFF))), &buf) catch return error.InvalidSql;
    try out.appendSlice(allocator, buf[0..len]);
}

fn parseHexDigits(text: []const u8, count: usize) ?u32 {
    if (text.len < count) return null;
    var value: u32 = 0;
    for (text[0..count]) |c| {
        const digit: u32 = if (c >= '0' and c <= '9') @as(u32, c - '0') else if (c >= 'a' and c <= 'f') @as(u32, c - 'a' + 10) else if (c >= 'A' and c <= 'F') @as(u32, c - 'A' + 10) else return null;
        value = value * 16 + digit;
    }
    return value;
}

pub fn evalUnistr(allocator: std.mem.Allocator, arg: Value) !Value {
    const owned: ?[]u8 = switch (arg) {
        .null => return .null,
        .text => null,
        .blob => null,
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .real => |r| try formatReal(allocator, r),
    };
    defer if (owned) |bytes| allocator.free(bytes);
    const input: []const u8 = owned orelse switch (arg) {
        .text => |t| t,
        .blob => |b| b,
        else => unreachable,
    };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '\\') {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= input.len) return error.InvalidSql;
        const next = input[i + 1];
        if (next == '\\') {
            try out.append(allocator, '\\');
            i += 2;
        } else if (next == 'u') {
            const code = parseHexDigits(input[i + 2 ..], 4) orelse return error.InvalidSql;
            try appendUtf8(allocator, &out, code);
            i += 6;
        } else if (next == 'U') {
            const code = parseHexDigits(input[i + 2 ..], 8) orelse return error.InvalidSql;
            try appendUtf8(allocator, &out, code);
            i += 10;
        } else if (next == '+') {
            const code = parseHexDigits(input[i + 2 ..], 6) orelse return error.InvalidSql;
            try appendUtf8(allocator, &out, code);
            i += 8;
        } else if (std.ascii.isHex(next)) {
            const code = parseHexDigits(input[i + 1 ..], 4) orelse return error.InvalidSql;
            try appendUtf8(allocator, &out, code);
            i += 5;
        } else {
            return error.InvalidSql;
        }
    }
    return .{ .text = try out.toOwnedSlice(allocator) };
}
