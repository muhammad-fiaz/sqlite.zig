const std = @import("std");
const Value = @import("../../vm/value.zig").Value;
const affinityOf = @import("../../catalog/type_affinity.zig").fromDeclaration;

pub fn evalAbs(arg: Value) Value {
    return switch (arg) {
        .null => .null,
        .integer => |i| .{ .integer = if (i == std.math.minInt(i64)) std.math.maxInt(i64) else @as(i64, @intCast(@abs(i))) },
        .real => |r| .{ .real = @abs(r) },
        .text => |t| blk: {
            const r = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch 0.0;
            break :blk .{ .real = @abs(r) };
        },
        .blob => .null,
    };
}

pub fn evalLower(allocator: std.mem.Allocator, arg: Value) !Value {
    switch (arg) {
        .text => |t| {
            const buf = try allocator.alloc(u8, t.len);
            for (t, 0..) |c, i| buf[i] = std.ascii.toLower(c);
            return .{ .text = buf };
        },
        else => return arg,
    }
}

pub fn evalUpper(allocator: std.mem.Allocator, arg: Value) !Value {
    switch (arg) {
        .text => |t| {
            const buf = try allocator.alloc(u8, t.len);
            for (t, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
            return .{ .text = buf };
        },
        else => return arg,
    }
}

pub fn evalLength(arg: Value) Value {
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
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{r}) catch "";
            break :blk .{ .integer = @intCast(s.len) };
        },
    };
}

pub fn evalRound(arg: Value, precisionArg: ?Value) Value {
    if (arg == .null) return .null;
    const num: f64 = switch (arg) {
        .integer => |i| @floatFromInt(i),
        .real => |r| r,
        .text => |t| std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch 0.0,
        else => return .null,
    };
    var decimals: i64 = 0;
    if (precisionArg) |pv| {
        if (pv == .null) return .null;
        decimals = switch (pv) {
            .integer => |i| i,
            .real => |r| @intFromFloat(r),
            .text => |t| std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10) catch 0,
            else => 0,
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

pub fn evalInstr(haystack: Value, needle: Value) Value {
    if (haystack == .null or needle == .null) return .null;
    const hBytes: []const u8 = switch (haystack) {
        .text => |t| t,
        .blob => |b| b,
        else => return .null,
    };
    const nBytes: []const u8 = switch (needle) {
        .text => |t| t,
        .blob => |b| b,
        else => return .null,
    };
    if (nBytes.len == 0) return .{ .integer = 1 };
    if (std.mem.indexOf(u8, hBytes, nBytes)) |pos| {
        return .{ .integer = @intCast(pos + 1) };
    }
    return .{ .integer = 0 };
}

pub fn evalReplace(allocator: std.mem.Allocator, orig: Value, from: Value, to: Value) !Value {
    if (orig == .null or from == .null or to == .null) return .null;
    if (orig != .text or from != .text or to != .text) return .null;
    if (from.text.len == 0) return .{ .text = try allocator.dupe(u8, orig.text) };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, orig.text, offset, from.text)) |pos| {
        try out.appendSlice(allocator, orig.text[offset..pos]);
        try out.appendSlice(allocator, to.text);
        offset = pos + from.text.len;
    }
    try out.appendSlice(allocator, orig.text[offset..]);
    return .{ .text = try out.toOwnedSlice(allocator) };
}

pub fn evalSubstr(allocator: std.mem.Allocator, strVal: Value, startVal: Value, lenVal: ?Value) !Value {
    if (strVal == .null or startVal == .null) return .null;
    const isBlob = strVal == .blob;
    const bytes: []const u8 = switch (strVal) {
        .text => |t| t,
        .blob => |b| b,
        else => return .null,
    };
    const startNum: i64 = switch (startVal) {
        .integer => |i| i,
        .real => |r| @intFromFloat(r),
        .text => |t| std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10) catch 0,
        else => return .null,
    };
    var startIdx: usize = 0;
    if (startNum > 0) {
        startIdx = @min(@as(usize, @intCast(startNum - 1)), bytes.len);
    } else if (startNum < 0) {
        const fromEnd: usize = @intCast(-startNum);
        startIdx = if (fromEnd > bytes.len) 0 else bytes.len - fromEnd;
    } else {
        startIdx = 0;
    }
    var endIdx: usize = bytes.len;
    if (lenVal) |lv| {
        if (lv == .null) return .null;
        const lenNum: i64 = switch (lv) {
            .integer => |i| i,
            .real => |r| @intFromFloat(r),
            .text => |t| std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10) catch 0,
            else => return .null,
        };
        if (lenNum < 0) {
            const negLen: usize = @intCast(-lenNum);
            const actualStart = if (negLen > startIdx) 0 else startIdx - negLen;
            endIdx = startIdx;
            startIdx = actualStart;
        } else {
            endIdx = @min(bytes.len, startIdx + @as(usize, @intCast(lenNum)));
        }
    }
    if (startIdx > endIdx) startIdx = endIdx;
    const sliced = try allocator.dupe(u8, bytes[startIdx..endIdx]);
    if (isBlob) return .{ .blob = sliced };
    return .{ .text = sliced };
}

pub fn evalTrim(allocator: std.mem.Allocator, strVal: Value, charsVal: ?Value, mode: enum { both, left, right }) !Value {
    if (strVal == .null) return .null;
    if (strVal != .text) return .null;
    var trimChars: []const u8 = " \t\r\n";
    if (charsVal) |cv| {
        if (cv == .null) return .null;
        if (cv == .text) trimChars = cv.text;
    }
    const text = strVal.text;
    var start: usize = 0;
    var end: usize = text.len;
    if (mode == .both or mode == .left) {
        while (start < end and std.mem.indexOfScalar(u8, trimChars, text[start]) != null) : (start += 1) {}
    }
    if (mode == .both or mode == .right) {
        while (end > start and std.mem.indexOfScalar(u8, trimChars, text[end - 1]) != null) : (end -= 1) {}
    }
    return .{ .text = try allocator.dupe(u8, text[start..end]) };
}

pub fn evalCast(allocator: std.mem.Allocator, val: Value, targetType: []const u8) !Value {
    return switch (affinityOf(targetType)) {
        .integer => switch (val) {
            .null => .null,
            .integer => val,
            .real => |r| .{ .integer = @intFromFloat(r) },
            .text => |t| .{ .integer = std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10) catch 0 },
            .blob => .null,
        },
        .real => switch (val) {
            .null => .null,
            .integer => |i| .{ .real = @floatFromInt(i) },
            .real => val,
            .text => |t| .{ .real = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch 0.0 },
            .blob => .null,
        },
        .text => switch (val) {
            .null => .null,
            .text => |t| .{ .text = try allocator.dupe(u8, t) },
            .blob => |b| .{ .text = try allocator.dupe(u8, b) },
            .integer => |i| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
            .real => |r| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{r}) },
        },
        .blob => switch (val) {
            .null => .null,
            .blob => |b| .{ .blob = try allocator.dupe(u8, b) },
            .text => |t| .{ .blob = try allocator.dupe(u8, t) },
            .integer => |i| .{ .blob = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
            .real => |r| .{ .blob = try std.fmt.allocPrint(allocator, "{d}", .{r}) },
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
    const bytes: []const u8 = switch (val) {
        .text => |t| t,
        .blob => |b| b,
        else => return .null,
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
        .real => |r| return .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{r}) },
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
        if (arg == .null) continue;
        const code: u21 = switch (arg) {
            .integer => |i| if (i >= 0 and i <= 0x10FFFF) @as(u21, @intCast(i)) else 0xFFFD,
            .real => |r| if (r >= 0 and r <= 0x10FFFF) @as(u21, @intFromFloat(r)) else 0xFFFD,
            else => continue,
        };
        const len = std.unicode.utf8Encode(code, &buf) catch continue;
        try out.appendSlice(allocator, buf[0..len]);
    }
    return .{ .text = try out.toOwnedSlice(allocator) };
}

pub fn evalUnicode(arg: Value) Value {
    if (arg == .null) return .null;
    const str = switch (arg) {
        .text => |t| t,
        else => return .null,
    };
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
