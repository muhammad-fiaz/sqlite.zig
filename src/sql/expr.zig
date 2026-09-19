const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("../vm/value.zig").Value;
const functions = @import("functions.zig");

pub const EvalError = error{
    UnknownColumn,
    InvalidSql,
    DivisionByZero,
    OutOfMemory,
    ConstraintViolation,
    Unsupported,
};

pub fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .text => |t| allocator.free(t),
        .blob => |b| allocator.free(b),
        else => {},
    }
}

fn compareValues(left: Value, op: ast.CompareOp, right: Value) bool {
    if (left == .null or right == .null) return false;
    const lOrder = valueOrder(left);
    const rOrder = valueOrder(right);
    if (lOrder != rOrder) {
        return switch (op) {
            .equal => false,
            .notEqual => true,
            .less => lOrder < rOrder,
            .lessEqual => lOrder <= rOrder,
            .greater => lOrder > rOrder,
            .greaterEqual => lOrder >= rOrder,
            else => false,
        };
    }
    const cmpResult: i32 = switch (left) {
        .null => 0,
        .integer => |li| switch (right) {
            .integer => |ri| if (li < ri) -1 else if (li > ri) 1 else 0,
            .real => |rr| blk: {
                const lr = @as(f64, @floatFromInt(li));
                break :blk if (lr < rr) -1 else if (lr > rr) 1 else 0;
            },
            else => 0,
        },
        .real => |lr| switch (right) {
            .real => |rr| if (lr < rr) -1 else if (lr > rr) 1 else 0,
            .integer => |ri| blk: {
                const rr = @as(f64, @floatFromInt(ri));
                break :blk if (lr < rr) -1 else if (lr > rr) 1 else 0;
            },
            else => 0,
        },
        .text => |lt| switch (std.mem.order(u8, lt, right.text)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        },
        .blob => |lb| switch (std.mem.order(u8, lb, right.blob)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        },
    };
    return switch (op) {
        .equal => cmpResult == 0,
        .notEqual => cmpResult != 0,
        .less => cmpResult < 0,
        .lessEqual => cmpResult <= 0,
        .greater => cmpResult > 0,
        .greaterEqual => cmpResult >= 0,
        else => false,
    };
}

fn valueOrder(value: Value) u8 {
    return switch (value) {
        .null => 0,
        .integer, .real => 1,
        .text => 2,
        .blob => 3,
    };
}

fn isTruthy(value: Value) bool {
    return value.isTruthy();
}

fn globMatch(text: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (pattern[0] == '*') return globMatch(text, pattern[1..]) or (text.len != 0 and globMatch(text[1..], pattern));
    if (text.len == 0) return false;
    if (pattern[0] == '?') return globMatch(text[1..], pattern[1..]);
    return text[0] == pattern[0] and globMatch(text[1..], pattern[1..]);
}

fn likeMatch(text: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (pattern[0] == '%') return likeMatch(text, pattern[1..]) or (text.len != 0 and likeMatch(text[1..], pattern));
    if (text.len == 0) return false;
    if (pattern[0] == '_') return likeMatch(text[1..], pattern[1..]);
    return std.ascii.toLower(text[0]) == std.ascii.toLower(pattern[0]) and likeMatch(text[1..], pattern[1..]);
}

fn toFloat(value: Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .real => |r| r,
        else => null,
    };
}

pub fn eval(allocator: std.mem.Allocator, columnNames: []const []const u8, row: []const Value, expr: ast.Expr) anyerror!Value {
    switch (expr) {
        .literal => |lit| return lit,
        .identifier => |id| {
            const cleanId = if (std.mem.indexOfScalar(u8, id, '.')) |dot| id[dot + 1 ..] else id;
            for (columnNames, 0..) |colName, idx| {
                if (std.ascii.eqlIgnoreCase(colName, cleanId)) {
                    if (idx < row.len) return row[idx] else return .null;
                }
            }
            return EvalError.UnknownColumn;
        },
        .parameter => return .null,
        .wildcard => return EvalError.InvalidSql,
        .unary => |un| {
            const operand = try eval(allocator, columnNames, row, un.expr.*);
            if (operand == .null) return .null;
            return switch (un.op) {
                .logicalNot => .{ .integer = if (isTruthy(operand)) 0 else 1 },
                .negate => switch (operand) {
                    .integer => |n| if (n == std.math.minInt(i64)) .{ .real = 9223372036854775808.0 } else .{ .integer = -n },
                    .real => |r| .{ .real = -r },
                    else => .null,
                },
                .positive => switch (operand) {
                    .integer, .real => operand,
                    else => .null,
                },
                .bitNot => switch (operand) {
                    .integer => |n| .{ .integer = ~n },
                    else => .null,
                },
            };
        },
        .binary => |bin| {
            if (bin.op == .logicalAnd) {
                const left = try eval(allocator, columnNames, row, bin.left.*);
                if (left != .null and !isTruthy(left)) return .{ .integer = 0 };
                const right = try eval(allocator, columnNames, row, bin.right.*);
                if (right != .null and !isTruthy(right)) return .{ .integer = 0 };
                if (left == .null or right == .null) return .null;
                return .{ .integer = if (isTruthy(left) and isTruthy(right)) 1 else 0 };
            }
            if (bin.op == .logicalOr) {
                const left = try eval(allocator, columnNames, row, bin.left.*);
                if (left != .null and isTruthy(left)) return .{ .integer = 1 };
                const right = try eval(allocator, columnNames, row, bin.right.*);
                if (right != .null and isTruthy(right)) return .{ .integer = 1 };
                if (left == .null or right == .null) return .null;
                return .{ .integer = 0 };
            }
            const left = try eval(allocator, columnNames, row, bin.left.*);
            const right = try eval(allocator, columnNames, row, bin.right.*);
            if (bin.op == .concat) {
                if (left == .null or right == .null) return .null;
                const leftStr = switch (left) {
                    .text => |t| t,
                    else => return .null,
                };
                const rightStr = switch (right) {
                    .text => |t| t,
                    else => return .null,
                };
                const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ leftStr, rightStr });
                return .{ .text = combined };
            }
            if (bin.op == .isOp) {
                return .{ .integer = if (left.sameValue(right)) 1 else 0 };
            }
            if (bin.op == .isNotOp) {
                return .{ .integer = if (!left.sameValue(right)) 1 else 0 };
            }
            if (bin.op == .equal or bin.op == .notEqual or bin.op == .less or bin.op == .lessEqual or bin.op == .greater or bin.op == .greaterEqual) {
                const cmpOp: ast.CompareOp = switch (bin.op) {
                    .equal => .equal,
                    .notEqual => .notEqual,
                    .less => .less,
                    .lessEqual => .lessEqual,
                    .greater => .greater,
                    .greaterEqual => .greaterEqual,
                    else => unreachable,
                };
                if (left == .null or right == .null) return .null;
                return .{ .integer = if (compareValues(left, cmpOp, right)) 1 else 0 };
            }
            if (left == .null or right == .null) return .null;
            if (left == .integer and right == .integer) {
                const a = left.integer;
                const b = right.integer;
                switch (bin.op) {
                    .add => {
                        const sum = @addWithOverflow(a, b);
                        if (sum[1] == 0) return .{ .integer = sum[0] };
                        return .{ .real = @as(f64, @floatFromInt(a)) + @as(f64, @floatFromInt(b)) };
                    },
                    .subtract => {
                        const diff = @subWithOverflow(a, b);
                        if (diff[1] == 0) return .{ .integer = diff[0] };
                        return .{ .real = @as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b)) };
                    },
                    .multiply => {
                        const prod = @mulWithOverflow(a, b);
                        if (prod[1] == 0) return .{ .integer = prod[0] };
                        return .{ .real = @as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(b)) };
                    },
                    .divide => {
                        if (b == 0) return .null;
                        if (b == -1 and a == std.math.minInt(i64)) return .{ .real = 9223372036854775808.0 };
                        return .{ .integer = @divTrunc(a, b) };
                    },
                    .modulo => {
                        if (b == 0) return .null;
                        const divisor = if (b == -1) @as(i64, 1) else b;
                        return .{ .integer = @rem(a, divisor) };
                    },
                    .bitAnd => return .{ .integer = a & b },
                    .bitOr => return .{ .integer = a | b },
                    .shiftLeft => {
                        if (b < 0 or b >= 64) return .{ .integer = 0 };
                        return .{ .integer = a << @intCast(b) };
                    },
                    .shiftRight => {
                        if (b < 0 or b >= 64) return .{ .integer = if (a >= 0) 0 else -1 };
                        return .{ .integer = a >> @intCast(b) };
                    },
                    else => return EvalError.InvalidSql,
                }
            }
            const fa = toFloat(left);
            const fb = toFloat(right);
            if (fa != null and fb != null) {
                const a = fa.?;
                const b = fb.?;
                switch (bin.op) {
                    .add => return .{ .real = a + b },
                    .subtract => return .{ .real = a - b },
                    .multiply => return .{ .real = a * b },
                    .divide => if (b == 0) return .null else return .{ .real = a / b },
                    else => return EvalError.InvalidSql,
                }
            }
            return .null;
        },
        .collate => |col| return try eval(allocator, columnNames, row, col.expr.*),
        .caseExpr => |cs| {
            if (cs.base) |baseExpr| {
                const baseVal = try eval(allocator, columnNames, row, baseExpr.*);
                for (cs.whens) |when| {
                    const condVal = try eval(allocator, columnNames, row, when.condition);
                    if (compareValues(baseVal, .equal, condVal)) {
                        return try eval(allocator, columnNames, row, when.result);
                    }
                }
            } else {
                for (cs.whens) |when| {
                    const condVal = try eval(allocator, columnNames, row, when.condition);
                    if (isTruthy(condVal)) {
                        return try eval(allocator, columnNames, row, when.result);
                    }
                }
            }
            if (cs.otherwise) |other| return try eval(allocator, columnNames, row, other.*);
            return .null;
        },
        .inList => |il| {
            const target = try eval(allocator, columnNames, row, il.expr.*);
            if (target == .null) return .null;
            var matched = false;
            for (il.list) |item| {
                const itemVal = try eval(allocator, columnNames, row, item);
                if (compareValues(target, .equal, itemVal)) {
                    matched = true;
                    break;
                }
            }
            const isMatch = if (il.negated) !matched else matched;
            return .{ .integer = if (isMatch) 1 else 0 };
        },
        .patternMatch => |pm| {
            const val = try eval(allocator, columnNames, row, pm.value.*);
            defer freeValue(allocator, val);
            const pat = try eval(allocator, columnNames, row, pm.pattern.*);
            defer freeValue(allocator, pat);
            if (val == .null or pat == .null) return .null;
            if (val != .text or pat != .text) return .{ .integer = 0 };
            const matched = if (pm.glob)
                globMatch(val.text, pat.text)
            else
                likeMatch(val.text, pat.text);
            const isMatch = if (pm.negated) !matched else matched;
            return .{ .integer = if (isMatch) 1 else 0 };
        },
        .function => |f| {
            var argList = std.ArrayList(Value).empty;
            defer {
                for (argList.items) |v| freeValue(allocator, v);
                argList.deinit(allocator);
            }
            if (f.argument.* == .wildcard) return .null;
            try argList.append(allocator, try eval(allocator, columnNames, row, f.argument.*));
            if (f.argument2) |a2| {
                if (a2.* == .identifier and std.ascii.eqlIgnoreCase(f.name, "cast")) {
                    try argList.append(allocator, .{ .text = a2.identifier });
                } else {
                    try argList.append(allocator, try eval(allocator, columnNames, row, a2.*));
                }
            }
            if (f.argument3) |a3| {
                try argList.append(allocator, try eval(allocator, columnNames, row, a3.*));
            }
            for (f.extraArgs) |ea| {
                try argList.append(allocator, try eval(allocator, columnNames, row, ea));
            }
            return functions.evalScalar(allocator, f.name, argList.items) catch .null;
        },
        else => return .null,
    }
}

pub fn evalCheck(allocator: std.mem.Allocator, columnNames: []const []const u8, row: []const Value, expr: ast.Expr) !bool {
    const val = try eval(allocator, columnNames, row, expr);
    defer freeValue(allocator, val);
    if (val == .null) return true;
    return val.isTruthy();
}

test "evaluates arithmetic, logic, and comparisons" {
    const colNames = [_][]const u8{ "a", "b", "c" };
    const row = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .text = "hello" } };
    const leftExpr = ast.Expr{ .identifier = "a" };
    const rightExpr = ast.Expr{ .identifier = "b" };
    const addExpr = ast.Expr{ .binary = .{ .op = .add, .left = &leftExpr, .right = &rightExpr } };
    const res = try eval(std.testing.allocator, &colNames, &row, addExpr);
    try std.testing.expectEqual(@as(i64, 30), res.integer);
}

test "evalCheck accepts truthy and null and rejects zero" {
    const colNames = [_][]const u8{"x"};
    const rowTrue = [_]Value{.{ .integer = 5 }};
    const rowFalse = [_]Value{.{ .integer = 0 }};
    const rowNull = [_]Value{.null};
    const idExpr = ast.Expr{ .identifier = "x" };
    try std.testing.expect(try evalCheck(std.testing.allocator, &colNames, &rowTrue, idExpr));
    try std.testing.expect(!try evalCheck(std.testing.allocator, &colNames, &rowFalse, idExpr));
    try std.testing.expect(try evalCheck(std.testing.allocator, &colNames, &rowNull, idExpr));
}
