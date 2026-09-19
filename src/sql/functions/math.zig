const std = @import("std");
const Value = @import("../../vm/value.zig").Value;

fn toFloat(val: Value) ?f64 {
    return switch (val) {
        .null => null,
        .integer => |i| @floatFromInt(i),
        .real => |r| r,
        .text => |t| std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch null,
        .blob => null,
    };
}

pub fn evalCeil(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @ceil(f) };
}

pub fn evalFloor(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @floor(f) };
}

pub fn evalTrunc(arg: Value, decimalsArg: ?Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (decimalsArg) |dv| {
        const decF = toFloat(dv) orelse return .null;
        const decInt: i64 = @intFromFloat(decF);
        const decClamped = @max(-30, @min(30, decInt));
        const factor = std.math.pow(f64, 10.0, @as(f64, @floatFromInt(@abs(decClamped))));
        if (decClamped > 0) {
            return .{ .real = @trunc(f * factor) / factor };
        } else {
            return .{ .real = @trunc(f / factor) * factor };
        }
    }
    return .{ .real = @trunc(f) };
}

pub fn evalLn(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f <= 0.0) return .null;
    return .{ .real = @log(f) };
}

pub fn evalLog(arg1: Value, arg2: ?Value) Value {
    if (arg2) |baseVal| {
        const b = toFloat(arg1) orelse return .null;
        const x = toFloat(baseVal) orelse return .null;
        if (b <= 0.0 or b == 1.0 or x <= 0.0) return .null;
        return .{ .real = @log(x) / @log(b) };
    }
    const f = toFloat(arg1) orelse return .null;
    if (f <= 0.0) return .null;
    return .{ .real = @log10(f) };
}

pub fn evalLog10(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f <= 0.0) return .null;
    return .{ .real = @log10(f) };
}

pub fn evalLog2(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f <= 0.0) return .null;
    return .{ .real = @log2(f) };
}

pub fn evalPow(base: Value, exp: Value) Value {
    const b = toFloat(base) orelse return .null;
    const e = toFloat(exp) orelse return .null;
    const res = std.math.pow(f64, b, e);
    if (std.math.isNan(res) or std.math.isInf(res)) return .null;
    return .{ .real = res };
}

pub fn evalSqrt(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f < 0.0) return .null;
    return .{ .real = @sqrt(f) };
}

pub fn evalSin(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @sin(f) };
}

pub fn evalCos(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @cos(f) };
}

pub fn evalTan(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @tan(f) };
}

pub fn evalAsin(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f < -1.0 or f > 1.0) return .null;
    return .{ .real = std.math.asin(f) };
}

pub fn evalAcos(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f < -1.0 or f > 1.0) return .null;
    return .{ .real = std.math.acos(f) };
}

pub fn evalAtan(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.atan(f) };
}

pub fn evalAtan2(yVal: Value, xVal: Value) Value {
    const y = toFloat(yVal) orelse return .null;
    const x = toFloat(xVal) orelse return .null;
    return .{ .real = std.math.atan2(y, x) };
}

pub fn evalDegrees(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = f * (180.0 / std.math.pi) };
}

pub fn evalRadians(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = f * (std.math.pi / 180.0) };
}

pub fn evalPi() Value {
    return .{ .real = std.math.pi };
}

pub fn evalExp(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.exp(f) };
}

pub fn evalMod(xVal: Value, yVal: Value) Value {
    const x = toFloat(xVal) orelse return .null;
    const y = toFloat(yVal) orelse return .null;
    return .{ .real = @rem(x, y) };
}

pub fn evalCosh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.cosh(f) };
}

pub fn evalSinh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.sinh(f) };
}

pub fn evalTanh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.tanh(f) };
}

pub fn evalAcosh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.acosh(f) };
}

pub fn evalAsinh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.asinh(f) };
}

pub fn evalAtanh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.atanh(f) };
}
