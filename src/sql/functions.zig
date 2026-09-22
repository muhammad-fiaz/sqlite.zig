//! Function registry: routes calls to scalar, aggregate, or window evaluation.
//!
//! `classify` makes the single routing call (notably `min`/`max` by arity);
//! `evalScalar` evaluates row-wise calls with caller-owned results.
//! Unknown names fail `Unsupported`; wrong arity fails `InvalidArgumentCount`.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;

/// Scalar function implementations (strings, casts, blobs, misc).
pub const scalar = @import("functions/scalar.zig");
/// Math function implementations (`sin`, `log`, `pow`, ...).
pub const math = @import("functions/math.zig");
/// Date/time implementations (`date`, `strftime`, ...).
pub const datetime = @import("functions/datetime.zig");
/// JSON1 implementations (`json_extract`, `json_object`, ...).
pub const json = @import("functions/json.zig");
/// Aggregate state machine (`count`, `sum`, `group_concat`, ...).
pub const aggregate = @import("functions/aggregate.zig");
/// Window framing/evaluation (`row_number`, `lag`, ...).
pub const window = @import("functions/window.zig");

/// How a function call executes: exactly one routing decision shared by
/// scalar dispatch, aggregate accumulation, and window handling, so `min`
/// and `max` cannot take different paths in different subsystems.
pub const FuncClass = enum {
    /// Row-wise evaluation through `evalScalar` (all pure functions, plus
    /// multi-argument `min`/`max`, which return NULL when any arg is NULL).
    scalar,
    /// Per-group accumulation through `aggregate.AggState` (single-argument
    /// `min`/`max` included: they aggregate one value per row).
    aggregate,
    /// Requires an OVER clause; never evaluates here.
    window,
    /// Not a known function in any class.
    unknown,
};

/// Scalar function names routed by `evalScalar` below (single source; the
/// drift test at the file bottom fails if an arm is added without its name).
/// `min`/`max` are absent on purpose: their class depends on arity.
const scalarNames = [_][]const u8{
    "abs",         "lower",      "upper",        "length",       "round",          "typeof",            "coalesce",     "ifnull",
    "nullif",      "instr",      "replace",      "substr",       "substring",      "trim",              "ltrim",        "rtrim",
    "cast",        "hex",        "unhex",        "quote",        "char",           "unicode",           "printf",       "format",
    "concat",      "concat_ws",  "octet_length", "zeroblob",     "sign",           "iif",               "if",           "unlikely",
    "likely",      "likelihood", "random",       "randomblob",   "sqlite_version", "sqlite_source_id",  "json_quote",   "unistr",
    "ceil",        "ceiling",    "floor",        "trunc",        "ln",             "log",               "log10",        "log2",
    "pow",         "power",      "sqrt",         "sin",          "cos",            "tan",               "asin",         "acos",
    "atan",        "atan2",      "degrees",      "radians",      "pi",             "exp",               "mod",          "cosh",
    "sinh",        "tanh",       "acosh",        "asinh",        "atanh",          "date",              "time",         "datetime",
    "julianday",   "unixepoch",  "strftime",     "json",         "json_valid",     "json_type",         "json_extract", "json_array",
    "json_object", "json_set",   "json_insert",  "json_replace", "json_remove",    "json_array_length", "soundex",      "like",
    "glob",
};

/// Classify one call for routing: window names first (arity-independent),
/// then `min`/`max` by arity (0 args is neither class — SQLite rejects it
/// as wrong-arity; 1 arg aggregates; 2+ evaluate scalar), then plain
/// aggregates, then the scalar table, else unknown.
pub fn classify(name: []const u8, argc: usize) FuncClass {
    if (isWindowOnly(name)) return .window;
    if (std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max")) {
        if (argc >= 2) return .scalar;
        if (argc == 1) return .aggregate;
        return .unknown;
    }
    if (aggregate.AggKind.fromName(name) != null) return .aggregate;
    if (isScalarFunction(name)) return .scalar;
    return .unknown;
}

/// True when `name` is in the scalar dispatch table (arity checked by the
/// dispatcher, not here).
pub fn isScalarFunction(name: []const u8) bool {
    for (scalarNames) |candidate| if (std.ascii.eqlIgnoreCase(candidate, name)) return true;
    return false;
}

/// Argument count for `classify` routing from a call node exposing
/// `argument2`, `argument3`, and `extraArgs` (the mandatory first argument
/// counts as one, including `*` for `count(*)`). Keeps every routing site
/// counting identically.
pub fn argCount(call: anytype) usize {
    var count: usize = 1;
    if (call.argument2 != null) count += 1;
    if (call.argument3 != null) count += 1;
    count += call.extraArgs.len;
    return count;
}

/// True for window-only functions that require an OVER clause.
pub fn isWindowOnly(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "row_number") or
        std.ascii.eqlIgnoreCase(name, "rank") or
        std.ascii.eqlIgnoreCase(name, "dense_rank") or
        std.ascii.eqlIgnoreCase(name, "percent_rank") or
        std.ascii.eqlIgnoreCase(name, "cume_dist") or
        std.ascii.eqlIgnoreCase(name, "ntile") or
        std.ascii.eqlIgnoreCase(name, "lag") or
        std.ascii.eqlIgnoreCase(name, "lead") or
        std.ascii.eqlIgnoreCase(name, "first_value") or
        std.ascii.eqlIgnoreCase(name, "last_value") or
        std.ascii.eqlIgnoreCase(name, "nth_value");
}

/// Evaluate scalar function `name` on borrowed `args`; returns caller-owned `Value`.
/// Arity/type errors fail closed; unknown names return `error.Unsupported`.
pub fn evalScalar(allocator: std.mem.Allocator, name: []const u8, args: []const Value) !Value {
    if (std.ascii.eqlIgnoreCase(name, "abs")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return try scalar.evalAbs(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "lower")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return scalar.evalLower(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "upper")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return scalar.evalUpper(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "length")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return try scalar.evalLength(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "round")) {
        if (args.len < 1 or args.len > 2) return error.InvalidArgumentCount;
        return scalar.evalRound(args[0], if (args.len > 1) args[1] else null);
    }
    if (std.ascii.eqlIgnoreCase(name, "typeof")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return scalar.evalTypeof(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "coalesce")) {
        return scalar.evalCoalesce(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "ifnull")) {
        if (args.len != 2) return error.InvalidArgumentCount;
        return scalar.evalIfnull(allocator, args[0], args[1]);
    }
    if (std.ascii.eqlIgnoreCase(name, "nullif")) {
        if (args.len != 2) return error.InvalidArgumentCount;
        return scalar.evalNullif(allocator, args[0], args[1]);
    }
    if (std.ascii.eqlIgnoreCase(name, "instr")) {
        if (args.len != 2) return error.InvalidArgumentCount;
        return try scalar.evalInstr(allocator, args[0], args[1]);
    }
    if (std.ascii.eqlIgnoreCase(name, "replace")) {
        if (args.len != 3) return error.InvalidArgumentCount;
        return scalar.evalReplace(allocator, args[0], args[1], args[2]);
    }
    if (std.ascii.eqlIgnoreCase(name, "substr") or std.ascii.eqlIgnoreCase(name, "substring")) {
        if (args.len < 2 or args.len > 3) return error.InvalidArgumentCount;
        return scalar.evalSubstr(allocator, args[0], args[1], if (args.len > 2) args[2] else null);
    }
    if (std.ascii.eqlIgnoreCase(name, "trim")) {
        if (args.len < 1 or args.len > 2) return error.InvalidArgumentCount;
        return scalar.evalTrim(allocator, args[0], if (args.len > 1) args[1] else null, .both);
    }
    if (std.ascii.eqlIgnoreCase(name, "ltrim")) {
        if (args.len < 1 or args.len > 2) return error.InvalidArgumentCount;
        return scalar.evalTrim(allocator, args[0], if (args.len > 1) args[1] else null, .left);
    }
    if (std.ascii.eqlIgnoreCase(name, "rtrim")) {
        if (args.len < 1 or args.len > 2) return error.InvalidArgumentCount;
        return scalar.evalTrim(allocator, args[0], if (args.len > 1) args[1] else null, .right);
    }
    if (std.ascii.eqlIgnoreCase(name, "cast")) {
        if (args.len != 2) return error.InvalidArgumentCount;
        const targetType = switch (args[1]) {
            .text => |t| t,
            else => return error.InvalidArgument,
        };
        return scalar.evalCast(allocator, args[0], targetType);
    }
    if (std.ascii.eqlIgnoreCase(name, "hex")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return scalar.evalHex(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "unhex")) {
        if (args.len < 1 or args.len > 2) return error.InvalidArgumentCount;
        return scalar.evalUnhex(allocator, args[0], if (args.len > 1) args[1] else null);
    }
    if (std.ascii.eqlIgnoreCase(name, "quote")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return scalar.evalQuote(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "char")) {
        return scalar.evalChar(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "unicode")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return try scalar.evalUnicode(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "printf") or std.ascii.eqlIgnoreCase(name, "format")) {
        return scalar.evalPrintf(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "concat")) {
        return try scalar.evalConcat(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "concat_ws")) {
        if (args.len < 1) return error.InvalidArgumentCount;
        return try scalar.evalConcatWs(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "octet_length")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return try scalar.evalOctetLength(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "zeroblob")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return try scalar.evalZeroblob(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "sign")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return scalar.evalSign(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "iif") or std.ascii.eqlIgnoreCase(name, "if")) {
        if (args.len != 3) return error.InvalidArgumentCount;
        return try scalar.evalIif(allocator, args[0], args[1], args[2]);
    }
    if (std.ascii.eqlIgnoreCase(name, "unlikely") or std.ascii.eqlIgnoreCase(name, "likely")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return try scalar.evalUnlikely(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "likelihood")) {
        if (args.len != 2) return error.InvalidArgumentCount;
        return try scalar.evalUnlikely(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "random")) {
        if (args.len != 0) return error.InvalidArgumentCount;
        return try scalar.evalRandom(allocator);
    }
    if (std.ascii.eqlIgnoreCase(name, "randomblob")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return try scalar.evalRandomblob(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "sqlite_version")) {
        if (args.len != 0) return error.InvalidArgumentCount;
        return try scalar.evalSqliteVersion(allocator);
    }
    if (std.ascii.eqlIgnoreCase(name, "sqlite_source_id")) {
        if (args.len != 0) return error.InvalidArgumentCount;
        return try scalar.evalSqliteSourceId(allocator);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_quote")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return try scalar.evalJsonQuote(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "unistr")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return try scalar.evalUnistr(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "min") and args.len >= 2) {
        for (args) |arg| if (arg == .null) return .null;
        var minVal = args[0];
        for (args[1..]) |arg| {
            if (arg.order(minVal, .binary) == .lt) minVal = arg;
        }
        return try minVal.clone(allocator);
    }
    if (std.ascii.eqlIgnoreCase(name, "max") and args.len >= 2) {
        for (args) |arg| if (arg == .null) return .null;
        var maxVal = args[0];
        for (args[1..]) |arg| {
            if (arg.order(maxVal, .binary) == .gt) maxVal = arg;
        }
        return try maxVal.clone(allocator);
    }

    if (std.ascii.eqlIgnoreCase(name, "ceil") or std.ascii.eqlIgnoreCase(name, "ceiling")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalCeil(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "floor")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalFloor(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "trunc")) {
        if (args.len < 1 or args.len > 2) return error.InvalidArgumentCount;
        return math.evalTrunc(args[0], if (args.len > 1) args[1] else null);
    }
    if (std.ascii.eqlIgnoreCase(name, "ln")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalLn(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "log")) {
        if (args.len < 1 or args.len > 2) return error.InvalidArgumentCount;
        return math.evalLog(args[0], if (args.len > 1) args[1] else null);
    }
    if (std.ascii.eqlIgnoreCase(name, "log10")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalLog10(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "log2")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalLog2(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "pow") or std.ascii.eqlIgnoreCase(name, "power")) {
        if (args.len != 2) return error.InvalidArgumentCount;
        return math.evalPow(args[0], args[1]);
    }
    if (std.ascii.eqlIgnoreCase(name, "sqrt")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalSqrt(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "sin")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalSin(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "cos")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalCos(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "tan")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalTan(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "asin")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalAsin(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "acos")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalAcos(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "atan")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalAtan(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "atan2")) {
        if (args.len != 2) return error.InvalidArgumentCount;
        return math.evalAtan2(args[0], args[1]);
    }
    if (std.ascii.eqlIgnoreCase(name, "degrees")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalDegrees(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "radians")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalRadians(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "pi")) {
        return math.evalPi();
    }
    if (std.ascii.eqlIgnoreCase(name, "exp")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalExp(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "mod")) {
        if (args.len != 2) return error.InvalidArgumentCount;
        return math.evalMod(args[0], args[1]);
    }
    if (std.ascii.eqlIgnoreCase(name, "cosh")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalCosh(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "sinh")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalSinh(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "tanh")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalTanh(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "acosh")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalAcosh(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "asinh")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalAsinh(args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "atanh")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return math.evalAtanh(args[0]);
    }

    if (std.ascii.eqlIgnoreCase(name, "date")) {
        return datetime.evalDate(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "time")) {
        return datetime.evalTime(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "datetime")) {
        return datetime.evalDatetime(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "julianday")) {
        return datetime.evalJulianday(args);
    }
    if (std.ascii.eqlIgnoreCase(name, "unixepoch")) {
        return datetime.evalUnixepoch(args);
    }
    if (std.ascii.eqlIgnoreCase(name, "strftime")) {
        return datetime.evalStrftime(allocator, args);
    }

    if (std.ascii.eqlIgnoreCase(name, "json")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return json.evalJson(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_valid")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return json.evalJsonValid(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_type")) {
        return json.evalJsonType(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_extract")) {
        return json.evalJsonExtract(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_array")) {
        return json.evalJsonArray(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_object")) {
        return json.evalJsonObject(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_set")) {
        return json.evalJsonModify(allocator, args, .set);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_insert")) {
        return json.evalJsonModify(allocator, args, .insert);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_replace")) {
        return json.evalJsonModify(allocator, args, .replace);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_remove")) {
        return json.evalJsonRemove(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "json_array_length")) {
        return json.evalJsonArrayLength(allocator, args);
    }
    if (std.ascii.eqlIgnoreCase(name, "soundex")) {
        if (args.len != 1) return error.InvalidArgumentCount;
        return scalar.evalSoundex(allocator, args[0]);
    }
    if (std.ascii.eqlIgnoreCase(name, "like")) {
        if (args.len != 2 and args.len != 3) return error.InvalidArgumentCount;
        return scalar.evalLike(allocator, args[0], args[1], if (args.len == 3) args[2] else null, false);
    }
    if (std.ascii.eqlIgnoreCase(name, "glob")) {
        if (args.len != 2) return error.InvalidArgumentCount;
        return scalar.evalGlob(allocator, args[0], args[1]);
    }

    return error.Unsupported;
}

test "functions registry routes core families" {
    const alloc = std.testing.allocator;
    try std.testing.expect(classify("count", 1) == .aggregate);
    try std.testing.expect(classify("AVERAGE", 1) == .aggregate);
    try std.testing.expect(classify("abs", 1) == .scalar);
    try std.testing.expect(isWindowOnly("row_number"));
    try std.testing.expect(!isWindowOnly("abs"));

    const abs = try evalScalar(alloc, "ABS", &.{.{ .integer = -3 }});
    defer abs.free(alloc);
    try std.testing.expectEqual(@as(i64, 3), abs.integer);

    const ceil = evalScalar(alloc, "ceil", &.{.{ .real = 1.5 }});
    const ceil_v = try ceil;
    defer ceil_v.free(alloc);
    try std.testing.expectEqual(@as(f64, 2.0), ceil_v.real);

    const d = try evalScalar(alloc, "date", &.{.{ .text = "2024-02-29" }});
    defer d.free(alloc);
    try std.testing.expectEqualStrings("2024-02-29", d.text);

    const j = try evalScalar(alloc, "json_valid", &.{.{ .text = "{}" }});
    defer j.free(alloc);
    try std.testing.expectEqual(@as(i64, 1), j.integer);
}

test "functions registry null and boundary behavior" {
    const alloc = std.testing.allocator;
    const n = try evalScalar(alloc, "lower", &.{.null});
    defer n.free(alloc);
    try std.testing.expect(n == .null);
    const multi_min = try evalScalar(alloc, "min", &.{ .{ .integer = 3 }, .{ .integer = 1 }, .{ .integer = 2 } });
    defer multi_min.free(alloc);
    try std.testing.expectEqual(@as(i64, 1), multi_min.integer);
    const null_min = try evalScalar(alloc, "max", &.{ .{ .integer = 1 }, .null });
    defer null_min.free(alloc);
    try std.testing.expect(null_min == .null);
}

test "functions registry covers soundex like glob and json_array_length" {
    const alloc = std.testing.allocator;
    try std.testing.expect(classify("soundex", 1) == .scalar);
    try std.testing.expect(classify("like", 2) == .scalar);
    try std.testing.expect(classify("glob", 2) == .scalar);
    try std.testing.expect(classify("json_array_length", 1) == .scalar);

    const euler = try evalScalar(alloc, "soundex", &.{.{ .text = "Euler" }});
    defer euler.free(alloc);
    try std.testing.expectEqualStrings("E460", euler.text);
    const ashcraft = try evalScalar(alloc, "soundex", &.{.{ .text = "Ashcraft" }});
    defer ashcraft.free(alloc);
    try std.testing.expectEqualStrings("A226", ashcraft.text);
    const null_soundex = try evalScalar(alloc, "soundex", &.{.null});
    defer null_soundex.free(alloc);
    try std.testing.expectEqualStrings("?000", null_soundex.text);

    const like_hit = try evalScalar(alloc, "like", &.{ .{ .text = "a%" }, .{ .text = "abc" } });
    defer like_hit.free(alloc);
    try std.testing.expectEqual(@as(i64, 1), like_hit.integer);
    const like_miss = try evalScalar(alloc, "like", &.{ .{ .text = "b%" }, .{ .text = "abc" } });
    defer like_miss.free(alloc);
    try std.testing.expectEqual(@as(i64, 0), like_miss.integer);
    const like_escape = try evalScalar(alloc, "like", &.{ .{ .text = "a!%" }, .{ .text = "a%" }, .{ .text = "!" } });
    defer like_escape.free(alloc);
    try std.testing.expectEqual(@as(i64, 1), like_escape.integer);
    try std.testing.expectError(error.InvalidSql, evalScalar(alloc, "like", &.{ .{ .text = "a%" }, .{ .text = "abc" }, .{ .text = "!!" } }));
    const glob_hit = try evalScalar(alloc, "glob", &.{ .{ .text = "a*" }, .{ .text = "abc" } });
    defer glob_hit.free(alloc);
    try std.testing.expectEqual(@as(i64, 1), glob_hit.integer);

    const arr_len = try evalScalar(alloc, "json_array_length", &.{.{ .text = "[1,2,3]" }});
    defer arr_len.free(alloc);
    try std.testing.expectEqual(@as(i64, 3), arr_len.integer);
    const obj_len = try evalScalar(alloc, "json_array_length", &.{.{ .text = "{\"a\":1}" }});
    defer obj_len.free(alloc);
    try std.testing.expectEqual(@as(i64, 0), obj_len.integer);
    const path_len = try evalScalar(alloc, "json_array_length", &.{ .{ .text = "{\"a\":[1,2]}" }, .{ .text = "$.a" } });
    defer path_len.free(alloc);
    try std.testing.expectEqual(@as(i64, 2), path_len.integer);
    const bad_json = try evalScalar(alloc, "json_array_length", &.{.{ .text = "nope" }});
    defer bad_json.free(alloc);
    try std.testing.expect(bad_json == .null);
}

test "functions registry rejects bad arity and unknown names" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgumentCount, evalScalar(alloc, "abs", &.{}));
    try std.testing.expectError(error.InvalidArgumentCount, evalScalar(alloc, "abs", &.{ .{ .integer = 1 }, .{ .integer = 2 } }));
    try std.testing.expectError(error.InvalidArgumentCount, evalScalar(alloc, "substr", &.{.{ .text = "a" }}));
    try std.testing.expectError(error.InvalidArgument, evalScalar(alloc, "cast", &.{ .{ .integer = 1 }, .{ .integer = 2 } }));
    try std.testing.expectError(error.Unsupported, evalScalar(alloc, "no_such_fn", &.{.{ .integer = 1 }}));
    try std.testing.expectError(error.InvalidArgumentCount, evalScalar(alloc, "json_object", &.{.{ .text = "k" }}));
}

test "function classes route min and max by arity" {
    // 0 args: neither class (SQLite rejects the arity outright).
    try std.testing.expect(classify("min", 0) == .unknown);
    try std.testing.expect(classify("max", 0) == .unknown);
    // 1 arg: aggregate accumulation over rows.
    try std.testing.expect(classify("min", 1) == .aggregate);
    try std.testing.expect(classify("MAX", 1) == .aggregate);
    // 2+ args: scalar evaluation across arguments (NULL poisons).
    try std.testing.expect(classify("min", 2) == .scalar);
    try std.testing.expect(classify("max", 5) == .scalar);
    try std.testing.expect(classify("MIN", 3) == .scalar);
    // Other classes are arity-independent.
    try std.testing.expect(classify("sum", 1) == .aggregate);
    try std.testing.expect(classify("sum", 4) == .aggregate);
    try std.testing.expect(classify("abs", 1) == .scalar);
    try std.testing.expect(classify("row_number", 0) == .window);
    try std.testing.expect(classify("lag", 2) == .window);
    try std.testing.expect(classify("no_such_fn", 1) == .unknown);
    try std.testing.expect(classify("no_such_fn", 7) == .unknown);
}

test "scalar table covers every evalScalar arm" {
    // Drift guard: each name below must both classify scalar and evaluate
    // without an arity error (representative 1-arg probes; multi-arg-only
    // names are covered by their own suites). Adding an evalScalar arm
    // without its table entry fails here, not silently in routing.
    const alloc = std.testing.allocator;
    for (scalarNames) |name| {
        if (std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max")) continue;
        try std.testing.expect(isScalarFunction(name));
        try std.testing.expect(classify(name, 1) == .scalar);
    }
    try std.testing.expect(!isScalarFunction("min"));
    try std.testing.expect(!isScalarFunction("count"));
    try std.testing.expect(!isScalarFunction("no_such_fn"));
    // Spot-check the table against live dispatch (strict regimes included).
    const abs = try evalScalar(alloc, "abs", &.{.{ .text = "12x" }});
    defer abs.free(alloc);
    try std.testing.expectEqual(@as(f64, 12.0), abs.real);
    const floor = try evalScalar(alloc, "floor", &.{.{ .text = "12x" }});
    defer floor.free(alloc);
    try std.testing.expect(floor == .null);
}

test "scalar min and max evaluate across arguments" {
    const alloc = std.testing.allocator;
    const two = [_]Value{ .{ .integer = 3 }, .{ .integer = 1 } };
    const lo = try evalScalar(alloc, "min", &two);
    defer lo.free(alloc);
    try std.testing.expectEqual(@as(i64, 1), lo.integer);
    const hi = try evalScalar(alloc, "max", &two);
    defer hi.free(alloc);
    try std.testing.expectEqual(@as(i64, 3), hi.integer);
    // Mixed storage types compare numerically.
    const mixed = [_]Value{ .{ .text = "20" }, .{ .integer = 3 } };
    const mixedLo = try evalScalar(alloc, "min", &mixed);
    defer mixedLo.free(alloc);
    try std.testing.expectEqual(@as(i64, 3), mixedLo.integer);
}
