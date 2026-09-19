const std = @import("std");
const Value = @import("../vm/value.zig").Value;

pub const scalar = @import("functions/scalar.zig");
pub const math = @import("functions/math.zig");
pub const datetime = @import("functions/datetime.zig");
pub const json = @import("functions/json.zig");
pub const aggregate = @import("functions/aggregate.zig");
pub const window = @import("functions/window.zig");

pub fn isAggregate(name: []const u8) bool {
    return aggregate.AggKind.fromName(name) != null;
}

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

    return error.Unsupported;
}
