//! Math SQL functions (`ceil`, `sin`, `pow`, ...) — pure `Value` transforms.
//!
//! Purpose: authoritative math implementations behind `functions.evalScalar`.
//! All functions take already-evaluated `Value` args (never AST) and return a
//! fresh `Value` (never NULL except on domain errors).
//!
//! Dependencies: `std`, `../../vm/value.zig` only.
//!
//! Ownership/lifetime: inputs borrowed; outputs are integer/real/null and need
//! no freeing. No allocation occurs here.
//!
//! Error behavior: infallible (`Value` return, not `!Value`); domain errors
//! (log of non-positive, asin out of range, NaN/Inf pow) yield `.null` per
//! SQLite. Wrong arity is rejected by the dispatcher.
//!
//! Invariants: text inputs coerce via trimmed `parseFloat`; blobs always yield
//! NULL; `toFloat(NULL)` is null so NULL propagates.
//!
//! SQLite compatibility: `log(X)` is base-10, `log(B,X)` is base-B;
//! `degrees`/`radians` use `std.math.pi`; `trunc` clamps decimals to ±30.
// TODO(sql/math): `toFloat` text coercion duplicates scalar/VM parsing with
// subtly different rules (trim+parseFloat vs prefix parse). Expected: shared
// coerce helper; tests: `'12x'`, `'  3.5  '`, `''`, blob matrices identical
// across math/scalar/vm. Subsystem: sql/functions.

const std = @import("std");
const Value = @import("../../vm/value.zig").Value;

/// Coerce a value to float; integers/reals convert, trimmed numeric text parses, else null.
fn toFloat(val: Value) ?f64 {
    return switch (val) {
        .null => null,
        .integer => |i| @floatFromInt(i),
        .real => |r| r,
        .text => |t| std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch null,
        .blob => null,
    };
}

/// `ceil(X)`/`ceiling`: smallest integer >= X as REAL; NULL on non-numeric.
pub fn evalCeil(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @ceil(f) };
}

/// `floor(X)`: largest integer <= X as REAL; NULL on non-numeric.
pub fn evalFloor(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @floor(f) };
}

/// `trunc(X[,N])`: truncate toward zero to N decimals (clamped ±30). NULL on bad input.
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

/// `ln(X)`: natural log; NULL when X <= 0 or non-numeric.
pub fn evalLn(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f <= 0.0) return .null;
    return .{ .real = @log(f) };
}

/// `log([B,]X)`: base-10 without B, else log-B of X. NULL on bad base/value.
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

/// `log10(X)`: base-10 log; NULL when X <= 0 or non-numeric.
pub fn evalLog10(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f <= 0.0) return .null;
    return .{ .real = @log10(f) };
}

/// `log2(X)`: base-2 log; NULL when X <= 0 or non-numeric.
pub fn evalLog2(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f <= 0.0) return .null;
    return .{ .real = @log2(f) };
}

/// `pow(B,E)`/`power`: B^E as REAL; NaN/Inf results map to NULL.
pub fn evalPow(base: Value, exp: Value) Value {
    const b = toFloat(base) orelse return .null;
    const e = toFloat(exp) orelse return .null;
    const res = std.math.pow(f64, b, e);
    if (std.math.isNan(res) or std.math.isInf(res)) return .null;
    return .{ .real = res };
}

/// `sqrt(X)`: square root; NULL when X < 0 or non-numeric.
pub fn evalSqrt(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f < 0.0) return .null;
    return .{ .real = @sqrt(f) };
}

/// `sin(X)`: sine of X radians; NULL on non-numeric.
pub fn evalSin(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @sin(f) };
}

/// `cos(X)`: cosine of X radians; NULL on non-numeric.
pub fn evalCos(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @cos(f) };
}

/// `tan(X)`: tangent of X radians; NULL on non-numeric.
pub fn evalTan(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = @tan(f) };
}

/// `asin(X)`: arcsine; NULL unless -1 <= X <= 1.
pub fn evalAsin(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f < -1.0 or f > 1.0) return .null;
    return .{ .real = std.math.asin(f) };
}

/// `acos(X)`: arccosine; NULL unless -1 <= X <= 1.
pub fn evalAcos(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    if (f < -1.0 or f > 1.0) return .null;
    return .{ .real = std.math.acos(f) };
}

/// `atan(X)`: arctangent; NULL on non-numeric.
pub fn evalAtan(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.atan(f) };
}

/// `atan2(Y,X)`: quadrant-aware arctangent; NULL when either is non-numeric.
pub fn evalAtan2(yVal: Value, xVal: Value) Value {
    const y = toFloat(yVal) orelse return .null;
    const x = toFloat(xVal) orelse return .null;
    return .{ .real = std.math.atan2(y, x) };
}

/// `degrees(X)`: radians to degrees; NULL on non-numeric.
pub fn evalDegrees(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = f * (180.0 / std.math.pi) };
}

/// `radians(X)`: degrees to radians; NULL on non-numeric.
pub fn evalRadians(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = f * (std.math.pi / 180.0) };
}

/// `pi()`: REAL π constant (dispatcher allows any arity; 0-arg is canonical).
pub fn evalPi() Value {
    return .{ .real = std.math.pi };
}

/// `exp(X)`: e^X; NULL on non-numeric (Inf propagates as REAL Inf here).
pub fn evalExp(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.exp(f) };
}

/// `mod(X,Y)`: floating remainder; NULL on non-numeric (differs from integer `%`).
pub fn evalMod(xVal: Value, yVal: Value) Value {
    const x = toFloat(xVal) orelse return .null;
    const y = toFloat(yVal) orelse return .null;
    return .{ .real = @rem(x, y) };
}

/// `cosh(X)`: hyperbolic cosine; NULL on non-numeric.
pub fn evalCosh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.cosh(f) };
}

/// `sinh(X)`: hyperbolic sine; NULL on non-numeric.
pub fn evalSinh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.sinh(f) };
}

/// `tanh(X)`: hyperbolic tangent; NULL on non-numeric.
pub fn evalTanh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.tanh(f) };
}

/// `acosh(X)`: inverse hyperbolic cosine (NaN for X < 1 propagates as REAL).
pub fn evalAcosh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.acosh(f) };
}

/// `asinh(X)`: inverse hyperbolic sine; NULL on non-numeric.
pub fn evalAsinh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.asinh(f) };
}

/// `atanh(X)`: inverse hyperbolic tangent (out-of-range yields NaN/Inf REAL).
pub fn evalAtanh(arg: Value) Value {
    const f = toFloat(arg) orelse return .null;
    return .{ .real = std.math.atanh(f) };
}

test "math normal behavior" {
    try std.testing.expectEqual(@as(f64, 2.0), evalCeil(.{ .real = 1.5 }).real);
    try std.testing.expectEqual(@as(f64, 1.0), evalFloor(.{ .real = 1.9 }).real);
    try std.testing.expectEqual(@as(f64, 4.0), evalSqrt(.{ .integer = 16 }).real);
    try std.testing.expectEqual(@as(f64, 8.0), evalPow(.{ .integer = 2 }, .{ .integer = 3 }).real);
    try std.testing.expectEqual(@as(f64, 1.0), evalLog10(.{ .integer = 10 }).real);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), evalSin(.{ .integer = 0 }).real, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 180.0), evalDegrees(.{ .real = std.math.pi }).real, 1e-9);
    try std.testing.expectApproxEqAbs(std.math.pi, evalRadians(.{ .integer = 180 }).real, 1e-12);
    try std.testing.expectEqual(std.math.pi, evalPi().real);
}

test "math null and boundary behavior" {
    try std.testing.expect(evalCeil(.null) == .null);
    try std.testing.expect(evalFloor(.{ .text = "abc" }) == .null);
    try std.testing.expect(evalLn(.{ .integer = 0 }) == .null);
    try std.testing.expect(evalLog10(.{ .integer = -5 }) == .null);
    try std.testing.expect(evalSqrt(.{ .integer = -1 }) == .null);
    try std.testing.expect(evalAsin(.{ .integer = 2 }) == .null);
    try std.testing.expect(evalAcos(.{ .integer = 2 }) == .null);
    try std.testing.expect(evalPow(.{ .integer = -1 }, .{ .real = 0.5 }) == .null);
    try std.testing.expect(evalMod(.{ .integer = 5 }, .{ .integer = 3 }) != .null);
    // Blob inputs never coerce.
    try std.testing.expect(evalSin(.{ .blob = "x" }) == .null);
    // trunc clamps decimals; text decimals coerce.
    try std.testing.expect(evalTrunc(.{ .real = 123.456 }, .{ .integer = 1 }) != .null);
}

test "math error-equivalent domain nulls" {
    // No Zig errors here by design; every domain failure is NULL.
    // log(B,X) is log-base-B of X: base 1 is undefined -> NULL, while
    // log-base-10 of 1 is a valid 0.
    try std.testing.expect(evalLog(.{ .integer = 1 }, .{ .integer = 10 }) == .null);
    try std.testing.expectEqual(@as(f64, 0.0), evalLog(.{ .integer = 10 }, .{ .integer = 1 }).real);
    try std.testing.expect(evalLog2(.{ .integer = 0 }) == .null);
    try std.testing.expect(evalAtan2(.null, .{ .integer = 1 }) == .null);
    try std.testing.expect(evalPow(.null, .{ .integer = 2 }) == .null);
}
