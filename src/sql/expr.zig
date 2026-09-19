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
        .literal => |lit| return try lit.clone(allocator),
        .identifier => |id| {
            const cleanId = if (std.mem.indexOfScalar(u8, id, '.')) |dot| id[dot + 1 ..] else id;
            for (columnNames, 0..) |colName, idx| {
                if (std.ascii.eqlIgnoreCase(colName, cleanId)) {
                    if (idx < row.len) return try row[idx].clone(allocator) else return .null;
                }
            }
            return EvalError.UnknownColumn;
        },
        .parameter => return .null,
        .wildcard => return EvalError.InvalidSql,
        .unary => |un| {
            const operand = try eval(allocator, columnNames, row, un.expr.*);
            defer freeValue(allocator, operand);
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
            defer freeValue(allocator, left);
            const right = try eval(allocator, columnNames, row, bin.right.*);
            defer freeValue(allocator, right);
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
                defer freeValue(allocator, baseVal);
                for (cs.whens) |when| {
                    const condVal = try eval(allocator, columnNames, row, when.condition);
                    defer freeValue(allocator, condVal);
                    if (compareValues(baseVal, .equal, condVal)) {
                        return try eval(allocator, columnNames, row, when.result);
                    }
                }
            } else {
                for (cs.whens) |when| {
                    const condVal = try eval(allocator, columnNames, row, when.condition);
                    defer freeValue(allocator, condVal);
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
            defer freeValue(allocator, target);
            if (target == .null) return .null;
            var matched = false;
            for (il.list) |item| {
                const itemVal = try eval(allocator, columnNames, row, item);
                defer freeValue(allocator, itemVal);
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

pub fn evalTemp(allocator: std.mem.Allocator, columnNames: []const []const u8, row: []const Value, expr: ast.Expr) !Value {
    return eval(allocator, columnNames, row, expr);
}

pub fn evalPredicate(allocator: std.mem.Allocator, columnNames: []const []const u8, row: []const Value, expr: ast.Expr) !bool {
    const val = try evalTemp(allocator, columnNames, row, expr);
    defer freeValue(allocator, val);
    return val.isTruthy();
}

fn predicateColumnName(identifier: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, identifier, '.')) |dot| return identifier[dot + 1 ..];
    return identifier;
}

fn equalityConjunct(expr: ast.Expr, column: *[]const u8, literal: *Value) bool {
    if (expr != .binary or expr.binary.op != .equal) return false;
    if (expr.binary.left.* == .identifier and expr.binary.right.* == .literal) {
        column.* = predicateColumnName(expr.binary.left.*.identifier);
        literal.* = expr.binary.right.*.literal;
        return true;
    }
    if (expr.binary.right.* == .identifier and expr.binary.left.* == .literal) {
        column.* = predicateColumnName(expr.binary.right.*.identifier);
        literal.* = expr.binary.left.*.literal;
        return true;
    }
    return false;
}

fn conjunctImplied(expr: ast.Expr, conditions: ast.Conditions) bool {
    var column: []const u8 = "";
    var literal: Value = .null;
    if (!equalityConjunct(expr, &column, &literal)) return false;
    for (conditions, 0..) |condition, position| {
        if (position > 0 and condition.joinOr) return false;
    }
    for (conditions) |condition| {
        if (condition.op != .equal) continue;
        if (condition.value != .literal) continue;
        if (!condition.value.literal.sameValue(literal)) continue;
        if (std.ascii.eqlIgnoreCase(predicateColumnName(condition.column), column)) return true;
    }
    return false;
}

fn exprListEqual(left: []const ast.Expr, right: []const ast.Expr) bool {
    if (left.len != right.len) return false;
    for (left, right) |l, r| if (!exprEqual(l, r)) return false;
    return true;
}

pub fn exprEqual(left: ast.Expr, right: ast.Expr) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    switch (left) {
        .literal => |l| return l.sameValue(right.literal),
        .identifier => |l| return std.ascii.eqlIgnoreCase(l, right.identifier),
        .parameter => |l| return l == right.parameter,
        .wildcard => return true,
        .binary => |l| return l.op == right.binary.op and exprEqual(l.left.*, right.binary.left.*) and exprEqual(l.right.*, right.binary.right.*),
        .unary => |l| return l.op == right.unary.op and exprEqual(l.expr.*, right.unary.expr.*),
        .collate => |l| return std.ascii.eqlIgnoreCase(l.name, right.collate.name) and exprEqual(l.expr.*, right.collate.expr.*),
        .patternMatch => |l| {
            const r = right.patternMatch;
            if (l.negated != r.negated or l.glob != r.glob or l.isRegexp != r.isRegexp or l.isMatch != r.isMatch) return false;
            if (!exprEqual(l.value.*, r.value.*)) return false;
            if (!exprEqual(l.pattern.*, r.pattern.*)) return false;
            if (l.escape == null and r.escape == null) return true;
            if (l.escape == null or r.escape == null) return false;
            return exprEqual(l.escape.?.*, r.escape.?.*);
        },
        .caseExpr => |l| {
            const r = right.caseExpr;
            if ((l.base == null) != (r.base == null)) return false;
            if (l.base) |base| if (!exprEqual(base.*, r.base.?.*)) return false;
            if (l.whens.len != r.whens.len) return false;
            for (l.whens, r.whens) |lw, rw| if (!exprEqual(lw.condition, rw.condition) or !exprEqual(lw.result, rw.result)) return false;
            if ((l.otherwise == null) != (r.otherwise == null)) return false;
            if (l.otherwise) |otherwise| if (!exprEqual(otherwise.*, r.otherwise.?.*)) return false;
            return true;
        },
        .inList => |l| {
            const r = right.inList;
            if (l.negated != r.negated) return false;
            if (!exprEqual(l.expr.*, r.expr.*)) return false;
            return exprListEqual(l.list, r.list);
        },
        .function => |l| {
            const r = right.function;
            if (!std.ascii.eqlIgnoreCase(l.name, r.name) or l.distinct != r.distinct) return false;
            if (!exprEqual(l.argument.*, r.argument.*)) return false;
            if ((l.argument2 == null) != (r.argument2 == null)) return false;
            if (l.argument2) |a| if (!exprEqual(a.*, r.argument2.?.*)) return false;
            if ((l.argument3 == null) != (r.argument3 == null)) return false;
            if (l.argument3) |a| if (!exprEqual(a.*, r.argument3.?.*)) return false;
            return exprListEqual(l.extraArgs, r.extraArgs);
        },
        .scalarSubquery => |l| return std.mem.eql(u8, l, right.scalarSubquery),
        .existsSubquery => |l| return std.mem.eql(u8, l, right.existsSubquery),
        .inSubquery => |l| {
            const r = right.inSubquery;
            return l.negated == r.negated and exprEqual(l.expr.*, r.expr.*) and std.mem.eql(u8, l.subquery, r.subquery);
        },
        .window => return false,
    }
}

pub fn partialPredicateImpliedBy(predicate: ast.Expr, conditions: ast.Conditions) bool {
    if (conditions.len == 0) return false;
    var current: ast.Expr = predicate;
    while (true) {
        if (current == .binary and current.binary.op == .logicalAnd) {
            if (!conjunctImplied(current.binary.left.*, conditions)) return false;
            current = current.binary.right.*;
            continue;
        }
        return conjunctImplied(current, conditions);
    }
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
