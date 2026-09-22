//! Row-level expression evaluator (AST -> value).
//!
//! Interprets trees against one row for CHECK constraints, generated
//! columns, and partial-index predicates. `eval` clones into caller-owned
//! values (free with `freeValue`); inputs borrow. NULL propagates except
//! through `IS` and Kleene `AND`/`OR`; overflow widens to REAL; `x/0`
//! yields NULL. Depth-guarded against hostile nesting.

const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("../vm/value.zig").Value;
const functions = @import("functions.zig");
const coerce = @import("coerce.zig");
const compareLib = @import("../connection/compare.zig");

/// Hard cap on nested-expression depth; hostile `((((...))))` fails closed.
pub const max_eval_depth: usize = 200;

/// Evaluation failure modes. OOM propagates; most type errors become NULL at runtime.
pub const EvalError = error{
    UnknownColumn,
    InvalidSql,
    DivisionByZero,
    OutOfMemory,
    ConstraintViolation,
    Unsupported,
};

/// Free a value produced by `eval` (no-op for null/int/real).
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

/// Expression-position `IS` equality: NULL-safe, numerics across
/// int/real (via `compareValues`), text-vs-text with an explicit COLLATE
/// name (`NOCASE` folds ASCII). Used by `isOp`/`isNotOp`, which also cover
/// `IS [NOT] DISTINCT FROM` lowered from expression position.
fn isEqual(left: Value, right: Value, collate: ?[]const u8) bool {
    if (left == .null or right == .null) return left == .null and right == .null;
    if (collate) |name| if (std.ascii.eqlIgnoreCase(name, "nocase") and left == .text and right == .text) {
        if (left.text.len != right.text.len) return false;
        for (left.text, right.text) |a, b| if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
        return true;
    };
    return compareValues(left, .equal, right);
}

/// SQLite storage-class rank: NULL(0) < numeric(1) < text(2) < blob(3).
fn valueOrder(value: Value) u8 {
    return switch (value) {
        .null => 0,
        .integer, .real => 1,
        .text => 2,
        .blob => 3,
    };
}

/// Three-valued-logic truth test; delegates to the single `Value.isTruthy`.
fn isTruthy(value: Value) bool {
    return value.isTruthy();
}

/// Iterative GLOB matcher (`*` = any run, `?` = one char, case-sensitive).
/// Backtracking (no recursion) so hostile `*****...` patterns cannot overflow.
fn globMatch(text: []const u8, pattern: []const u8) bool {
    var ti: usize = 0;
    var pi: usize = 0;
    var star: ?usize = null;
    var star_ti: usize = 0;
    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == text[ti])) {
            ti += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star = pi;
            star_ti = ti;
            pi += 1;
        } else if (star != null) {
            star_ti += 1;
            ti = star_ti;
            pi = star.? + 1;
        } else return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

/// Iterative LIKE matcher (`%` = any run, `_` = one char, ASCII case-insensitive).
/// Backtracking (no recursion) so hostile `%%%%...` patterns cannot overflow.
fn likeMatch(text: []const u8, pattern: []const u8) bool {
    var ti: usize = 0;
    var pi: usize = 0;
    var star: ?usize = null;
    var star_ti: usize = 0;
    while (ti < text.len) {
        if (pi < pattern.len and pattern[pi] == '_') {
            ti += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '%') {
            star = pi;
            star_ti = ti;
            pi += 1;
        } else if (pi < pattern.len and std.ascii.toLower(pattern[pi]) == std.ascii.toLower(text[ti])) {
            ti += 1;
            pi += 1;
        } else if (star != null) {
            star_ti += 1;
            ti = star_ti;
            pi = star.? + 1;
        } else return false;
    }
    while (pi < pattern.len and pattern[pi] == '%') pi += 1;
    return pi == pattern.len;
}

/// Evaluate `expr` against `row`; returns a caller-owned `Value`.
/// See module docs for NULL/ownership/error semantics. Depth-guarded.
pub fn eval(allocator: std.mem.Allocator, columnNames: []const []const u8, row: []const Value, expr: ast.Expr) anyerror!Value {
    return evalDepth(allocator, columnNames, row, expr, 0);
}

/// Depth-limited worker behind `eval`; `depth > max_eval_depth` fails closed.
fn evalDepth(allocator: std.mem.Allocator, columnNames: []const []const u8, row: []const Value, expr: ast.Expr, depth: usize) anyerror!Value {
    if (depth > max_eval_depth) return EvalError.InvalidSql;
    const child = depth + 1;
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
            const operand = try evalDepth(allocator, columnNames, row, un.expr.*, child);
            defer freeValue(allocator, operand);
            if (operand == .null) return .null;
            return switch (un.op) {
                .logicalNot => .{ .integer = if (isTruthy(operand)) 0 else 1 },
                // Text/blob coerce integer-preserving like the interpreter
                // (unary minus applies numeric affinity): -'6' is INTEGER -6,
                // -'6.5' is REAL -6.5.
                .negate => switch (coerce.toNumeric(operand)) {
                    .none => .null,
                    .int => |n| if (n == std.math.minInt(i64)) .{ .real = 9223372036854775808.0 } else .{ .integer = -n },
                    .real => |r| .{ .real = -r },
                },
                .positive => switch (coerce.toNumeric(operand)) {
                    .none => .null,
                    .int => |n| .{ .integer = n },
                    .real => |r| .{ .real = r },
                },
                .bitNot => switch (operand) {
                    .integer => |n| .{ .integer = ~n },
                    .real => |r| .{ .integer = ~coerce.saturatingTrunc(r) },
                    .text, .blob => .{ .integer = coerce.toInt(operand) orelse 0 },
                    else => .null,
                },
            };
        },
        .binary => |bin| {
            if (bin.op == .logicalAnd) {
                const left = try evalDepth(allocator, columnNames, row, bin.left.*, child);
                defer freeValue(allocator, left);
                if (left != .null and !isTruthy(left)) return .{ .integer = 0 };
                const right = try evalDepth(allocator, columnNames, row, bin.right.*, child);
                defer freeValue(allocator, right);
                if (right != .null and !isTruthy(right)) return .{ .integer = 0 };
                if (left == .null or right == .null) return .null;
                return .{ .integer = if (isTruthy(left) and isTruthy(right)) 1 else 0 };
            }
            if (bin.op == .logicalOr) {
                const left = try evalDepth(allocator, columnNames, row, bin.left.*, child);
                defer freeValue(allocator, left);
                if (left != .null and isTruthy(left)) return .{ .integer = 1 };
                const right = try evalDepth(allocator, columnNames, row, bin.right.*, child);
                defer freeValue(allocator, right);
                if (right != .null and isTruthy(right)) return .{ .integer = 1 };
                if (left == .null or right == .null) return .null;
                return .{ .integer = 0 };
            }
            const left = try evalDepth(allocator, columnNames, row, bin.left.*, child);
            defer freeValue(allocator, left);
            const right = try evalDepth(allocator, columnNames, row, bin.right.*, child);
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
            if (bin.op == .isOp or bin.op == .isNotOp) {
                // `IS [NOT] [DISTINCT FROM]` lowers here with an explicit
                // COLLATE wrapped around either side; the collation applies
                // to the (null-safe, numeric-folding) equality.
                const collation = if (bin.left.* == .collate) bin.left.*.collate.name else if (bin.right.* == .collate) bin.right.*.collate.name else null;
                const eq = isEqual(left, right, collation);
                return .{ .integer = if ((bin.op == .isOp) == eq) 1 else 0 };
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
                // An explicit COLLATE on either operand selects the
                // comparison collation; without one the local binary
                // ordering applies (it keeps numeric < text < blob ranks,
                // which the shared helper inverts for text-vs-numeric).
                // RTRIM and outer `(a = b) COLLATE name` wrappers still
                // evaluate binary (see the row-2 matrix TODO).
                const collation = if (bin.left.* == .collate) bin.left.*.collate.name else if (bin.right.* == .collate) bin.right.*.collate.name else null;
                if (collation) |_| return .{ .integer = if (compareLib.compareCollated(left, cmpOp, right, collation)) 1 else 0 };
                return .{ .integer = if (compareValues(left, cmpOp, right)) 1 else 0 };
            }
            if (left == .null or right == .null) return .null;
            // Integer-preserving arithmetic mirroring the interpreter:
            // operands that coerce to integers take checked
            // integer ops (overflow widens to REAL); anything else computes
            // in REAL with longest-prefix coercion. '6' * '7' is INTEGER 42.
            const leftNum = coerce.toNumeric(left);
            const rightNum = coerce.toNumeric(right);
            if (leftNum == .int and rightNum == .int) {
                const a = leftNum.int;
                const b = rightNum.int;
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
                    .shiftLeft => return .{ .integer = coerce.shiftLeft(a, b) },
                    .shiftRight => return .{ .integer = coerce.shiftRight(a, b) },
                    else => return EvalError.InvalidSql,
                }
            }
            // Integer-class operators coerce non-integer operands through
            // integers (prefix scan, saturating), like the interpreter.
            if (bin.op == .modulo or bin.op == .bitAnd or bin.op == .bitOr or bin.op == .shiftLeft or bin.op == .shiftRight) {
                // NULL was checked above, so these never fail.
                const a = coerce.toInt(left) orelse return .null;
                const b = coerce.toInt(right) orelse return .null;
                switch (bin.op) {
                    .modulo => {
                        if (b == 0) return .null;
                        const divisor = if (b == -1) @as(i64, 1) else b;
                        return .{ .integer = @rem(a, divisor) };
                    },
                    .bitAnd => return .{ .integer = a & b },
                    .bitOr => return .{ .integer = a | b },
                    .shiftLeft => return .{ .integer = coerce.shiftLeft(a, b) },
                    .shiftRight => return .{ .integer = coerce.shiftRight(a, b) },
                    else => unreachable,
                }
            }
            const fa = coerce.toFloat(left) orelse return .null;
            const fb = coerce.toFloat(right) orelse return .null;
            switch (bin.op) {
                .add => return .{ .real = fa + fb },
                .subtract => return .{ .real = fa - fb },
                .multiply => return .{ .real = fa * fb },
                .divide => {
                    if (fb == 0) return .null;
                    const quotient = fa / fb;
                    if (std.math.isNan(quotient)) return .null;
                    return .{ .real = quotient };
                },
                else => return EvalError.InvalidSql,
            }
        },
        .collate => |col| return try evalDepth(allocator, columnNames, row, col.expr.*, child),
        .caseExpr => |cs| {
            if (cs.base) |baseExpr| {
                const baseVal = try evalDepth(allocator, columnNames, row, baseExpr.*, child);
                defer freeValue(allocator, baseVal);
                for (cs.whens) |when| {
                    const condVal = try evalDepth(allocator, columnNames, row, when.condition, child);
                    defer freeValue(allocator, condVal);
                    if (compareValues(baseVal, .equal, condVal)) {
                        return try evalDepth(allocator, columnNames, row, when.result, child);
                    }
                }
            } else {
                for (cs.whens) |when| {
                    const condVal = try evalDepth(allocator, columnNames, row, when.condition, child);
                    defer freeValue(allocator, condVal);
                    if (isTruthy(condVal)) {
                        return try evalDepth(allocator, columnNames, row, when.result, child);
                    }
                }
            }
            if (cs.otherwise) |other| return try evalDepth(allocator, columnNames, row, other.*, child);
            return .null;
        },
        .inList => |il| {
            const target = try evalDepth(allocator, columnNames, row, il.expr.*, child);
            defer freeValue(allocator, target);
            if (target == .null) return .null;
            var matched = false;
            for (il.list) |item| {
                const itemVal = try evalDepth(allocator, columnNames, row, item, child);
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
            const val = try evalDepth(allocator, columnNames, row, pm.value.*, child);
            defer freeValue(allocator, val);
            const pat = try evalDepth(allocator, columnNames, row, pm.pattern.*, child);
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
            try argList.append(allocator, try evalDepth(allocator, columnNames, row, f.argument.*, child));
            if (f.argument2) |a2| {
                if (a2.* == .identifier and std.ascii.eqlIgnoreCase(f.name, "cast")) {
                    try argList.append(allocator, .{ .text = a2.identifier });
                } else {
                    try argList.append(allocator, try evalDepth(allocator, columnNames, row, a2.*, child));
                }
            }
            if (f.argument3) |a3| {
                try argList.append(allocator, try evalDepth(allocator, columnNames, row, a3.*, child));
            }
            for (f.extraArgs) |ea| {
                try argList.append(allocator, try evalDepth(allocator, columnNames, row, ea, child));
            }
            return functions.evalScalar(allocator, f.name, argList.items) catch |err| {
                if (err == error.OutOfMemory) return err;
                return .null;
            };
        },
        else => return .null,
    }
}

/// CHECK-constraint predicate: NULL counts as satisfied (SQL semantics).
/// Unknown columns propagate as errors; OOM propagates.
pub fn evalCheck(allocator: std.mem.Allocator, columnNames: []const []const u8, row: []const Value, expr: ast.Expr) !bool {
    const val = try eval(allocator, columnNames, row, expr);
    defer freeValue(allocator, val);
    if (val == .null) return true;
    return val.isTruthy();
}

/// Boolean predicate view: NULL/false -> false, truthy -> true.
/// Used by join/partial-index implication checks.
pub fn evalPredicate(allocator: std.mem.Allocator, columnNames: []const []const u8, row: []const Value, expr: ast.Expr) !bool {
    const val = try eval(allocator, columnNames, row, expr);
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

/// Structural expression equality (case-insensitive identifiers/names).
/// Window nodes are never equal (conservative: forces re-evaluation).
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

/// True when every AND-conjunct of `predicate` is an equality implied by `conditions`.
/// Used for partial-index eligibility; OR-joined conditions imply nothing.
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

test "arithmetic coerces text and blob with prefix rules" {
    // Shared coercion with scalar/math/VM, integer-preserving:
    // integer-looking text computes as INTEGER ('6' * '7' is 42),
    // other text is 0.0/0, and NULL still propagates as NULL.
    const noCols = [_][]const u8{};
    const noRow = [_]Value{};
    const cases = [_]struct {
        op: ast.BinaryOp,
        left: Value,
        right: Value,
        expectNull: bool,
        expectInt: ?i64,
        expectReal: f64,
    }{
        .{ .op = .add, .left = .{ .text = "6" }, .right = .{ .text = "7" }, .expectNull = false, .expectInt = 13, .expectReal = 0.0 },
        .{ .op = .multiply, .left = .{ .text = "6" }, .right = .{ .text = "7" }, .expectNull = false, .expectInt = 42, .expectReal = 0.0 },
        .{ .op = .subtract, .left = .{ .text = "12x" }, .right = .{ .integer = 2 }, .expectNull = false, .expectInt = null, .expectReal = 10.0 },
        .{ .op = .divide, .left = .{ .text = "abc" }, .right = .{ .integer = 2 }, .expectNull = false, .expectInt = null, .expectReal = 0.0 },
        .{ .op = .add, .left = .{ .blob = "3" }, .right = .{ .integer = 4 }, .expectNull = false, .expectInt = 7, .expectReal = 0.0 },
        .{ .op = .shiftLeft, .left = .{ .integer = 4 }, .right = .{ .text = "-1" }, .expectNull = false, .expectInt = 2, .expectReal = 0.0 },
        .{ .op = .add, .left = .null, .right = .{ .integer = 1 }, .expectNull = true, .expectInt = null, .expectReal = 0.0 },
        .{ .op = .multiply, .left = .{ .integer = 2 }, .right = .null, .expectNull = true, .expectInt = null, .expectReal = 0.0 },
    };
    for (cases) |c| {
        var l = ast.Expr{ .literal = c.left };
        var r = ast.Expr{ .literal = c.right };
        const expr = ast.Expr{ .binary = .{ .op = c.op, .left = &l, .right = &r } };
        const got = try eval(std.testing.allocator, &noCols, &noRow, expr);
        defer freeValue(std.testing.allocator, got);
        if (c.expectNull) {
            try std.testing.expect(got == .null);
        } else if (c.expectInt) |want| {
            try std.testing.expectEqual(want, got.integer);
        } else {
            try std.testing.expectEqual(c.expectReal, got.real);
        }
    }
    // Unary minus coerces text like the interpreter.
    var negText = ast.Expr{ .literal = .{ .text = "6" } };
    const negExpr = ast.Expr{ .unary = .{ .op = .negate, .expr = &negText } };
    const negGot = try eval(std.testing.allocator, &noCols, &noRow, negExpr);
    defer freeValue(std.testing.allocator, negGot);
    try std.testing.expectEqual(@as(i64, -6), negGot.integer);
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

test "logical operators follow SQLite three-valued truth tables" {
    const noCols = [_][]const u8{};
    const noRow = [_]Value{};
    const nullLit = ast.Expr{ .literal = .null };
    const trueLit = ast.Expr{ .literal = .{ .integer = 1 } };
    const falseLit = ast.Expr{ .literal = .{ .integer = 0 } };
    const textLit = ast.Expr{ .literal = .{ .text = "abc" } };
    const cases = [_]struct { op: ast.BinaryOp, left: ast.Expr, right: ast.Expr, expectNull: bool, expectInt: i64 }{
        .{ .op = .logicalAnd, .left = nullLit, .right = trueLit, .expectNull = true, .expectInt = 0 },
        .{ .op = .logicalAnd, .left = nullLit, .right = falseLit, .expectNull = false, .expectInt = 0 },
        .{ .op = .logicalAnd, .left = trueLit, .right = trueLit, .expectNull = false, .expectInt = 1 },
        .{ .op = .logicalAnd, .left = nullLit, .right = nullLit, .expectNull = true, .expectInt = 0 },
        .{ .op = .logicalOr, .left = nullLit, .right = trueLit, .expectNull = false, .expectInt = 1 },
        .{ .op = .logicalOr, .left = nullLit, .right = falseLit, .expectNull = true, .expectInt = 0 },
        .{ .op = .logicalOr, .left = falseLit, .right = falseLit, .expectNull = false, .expectInt = 0 },
        .{ .op = .logicalOr, .left = nullLit, .right = nullLit, .expectNull = true, .expectInt = 0 },
        // Text operands are cloned by eval and must not leak through AND/OR.
        .{ .op = .logicalAnd, .left = textLit, .right = falseLit, .expectNull = false, .expectInt = 0 },
        .{ .op = .logicalOr, .left = textLit, .right = trueLit, .expectNull = false, .expectInt = 1 },
    };
    for (cases) |c| {
        const expr = ast.Expr{ .binary = .{ .op = c.op, .left = &c.left, .right = &c.right } };
        const got = try eval(std.testing.allocator, &noCols, &noRow, expr);
        defer freeValue(std.testing.allocator, got);
        if (c.expectNull) {
            try std.testing.expect(got == .null);
        } else {
            try std.testing.expectEqual(c.expectInt, got.integer);
        }
    }
    const notNull = ast.Expr{ .unary = .{ .op = .logicalNot, .expr = &nullLit } };
    const notGot = try eval(std.testing.allocator, &noCols, &noRow, notNull);
    defer freeValue(std.testing.allocator, notGot);
    try std.testing.expect(notGot == .null);
}

test "expr null/integer/real/text/blob comparison matrix" {
    const noCols = [_][]const u8{};
    const noRow = [_]Value{};
    const nullLit = ast.Expr{ .literal = .null };
    const intLit = ast.Expr{ .literal = .{ .integer = 1 } };
    const realLit = ast.Expr{ .literal = .{ .real = 1.0 } };
    const textLit = ast.Expr{ .literal = .{ .text = "1" } };
    const blobLit = ast.Expr{ .literal = .{ .blob = "1" } };
    // NULL comparisons yield NULL (not false).
    const eqNull = ast.Expr{ .binary = .{ .op = .equal, .left = &nullLit, .right = &intLit } };
    const gotNull = try eval(std.testing.allocator, &noCols, &noRow, eqNull);
    defer freeValue(std.testing.allocator, gotNull);
    try std.testing.expect(gotNull == .null);
    // int 1 == real 1.0 (numeric class), but text/blob sort after numeric.
    const eqNum = ast.Expr{ .binary = .{ .op = .equal, .left = &intLit, .right = &realLit } };
    const gotNum = try eval(std.testing.allocator, &noCols, &noRow, eqNum);
    defer freeValue(std.testing.allocator, gotNum);
    try std.testing.expectEqual(@as(i64, 1), gotNum.integer);
    const ltCross = ast.Expr{ .binary = .{ .op = .less, .left = &realLit, .right = &textLit } };
    const gotCross = try eval(std.testing.allocator, &noCols, &noRow, ltCross);
    defer freeValue(std.testing.allocator, gotCross);
    try std.testing.expectEqual(@as(i64, 1), gotCross.integer);
    const gtBlob = ast.Expr{ .binary = .{ .op = .greater, .left = &blobLit, .right = &textLit } };
    const gotBlob = try eval(std.testing.allocator, &noCols, &noRow, gtBlob);
    defer freeValue(std.testing.allocator, gotBlob);
    try std.testing.expectEqual(@as(i64, 1), gotBlob.integer);
    // IS distinguishes NULL identity from equality.
    const isNull = ast.Expr{ .binary = .{ .op = .isOp, .left = &nullLit, .right = &nullLit } };
    const gotIs = try eval(std.testing.allocator, &noCols, &noRow, isNull);
    defer freeValue(std.testing.allocator, gotIs);
    try std.testing.expectEqual(@as(i64, 1), gotIs.integer);
}

test "expr like/glob iterative matchers handle edge cases" {
    const noCols = [_][]const u8{};
    const noRow = [_]Value{};
    const val = ast.Expr{ .literal = .{ .text = "aXc" } };
    const likePat = ast.Expr{ .literal = .{ .text = "a_c" } };
    const globPat = ast.Expr{ .literal = .{ .text = "a?c" } };
    const likeExpr = ast.Expr{ .patternMatch = .{ .value = &val, .pattern = &likePat, .negated = false, .glob = false, .isRegexp = false, .isMatch = false } };
    const gotLike = try eval(std.testing.allocator, &noCols, &noRow, likeExpr);
    defer freeValue(std.testing.allocator, gotLike);
    try std.testing.expectEqual(@as(i64, 1), gotLike.integer);
    const globExpr = ast.Expr{ .patternMatch = .{ .value = &val, .pattern = &globPat, .negated = false, .glob = true, .isRegexp = false, .isMatch = false } };
    const gotGlob = try eval(std.testing.allocator, &noCols, &noRow, globExpr);
    defer freeValue(std.testing.allocator, gotGlob);
    try std.testing.expectEqual(@as(i64, 1), gotGlob.integer);
    // Hostile run of wildcards terminates (no recursion) and matches empty.
    try std.testing.expect(likeMatch("", "%%%%"));
    try std.testing.expect(globMatch("", "****"));
    try std.testing.expect(!likeMatch("ab", "a"));
}

test "expr integer overflow wraps to real and div-by-zero is null" {
    const noCols = [_][]const u8{};
    const noRow = [_]Value{};
    const maxLit = ast.Expr{ .literal = .{ .integer = std.math.maxInt(i64) } };
    const oneLit = ast.Expr{ .literal = .{ .integer = 1 } };
    const zeroLit = ast.Expr{ .literal = .{ .integer = 0 } };
    const add = ast.Expr{ .binary = .{ .op = .add, .left = &maxLit, .right = &oneLit } };
    const gotAdd = try eval(std.testing.allocator, &noCols, &noRow, add);
    defer freeValue(std.testing.allocator, gotAdd);
    try std.testing.expect(gotAdd == .real);
    const div = ast.Expr{ .binary = .{ .op = .divide, .left = &oneLit, .right = &zeroLit } };
    const gotDiv = try eval(std.testing.allocator, &noCols, &noRow, div);
    defer freeValue(std.testing.allocator, gotDiv);
    try std.testing.expect(gotDiv == .null);
}
