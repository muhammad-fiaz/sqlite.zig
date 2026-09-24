//! Query optimizer: constant folding and predicate pushdown checks.
//!
//! Folds literal-only subtrees with evaluator semantics (overflow widens to
//! REAL, `x/0` folds to NULL) and answers whether a predicate can run on one
//! table's scan. Input borrows; folded text results are caller-owned (free
//! with `freeFoldedExpr`, never with the parser's freer).

const std = @import("std");
const ast = @import("../sql/ast.zig");
const Value = @import("../vm/value.zig").Value;
const exprEval = @import("../sql/expr.zig");

/// Trivial boolean-constant predicate (kept for call-site readability).
pub fn isConstantTrue(value: bool) bool {
    return value;
}

/// Trivial boolean-constant predicate (kept for call-site readability).
pub fn isConstantFalse(value: bool) bool {
    return !value;
}

/// Fold literal-only subtrees; returns a borrowed-or-new tree (see module docs).
/// Dropped sides of AND/OR identities are freed; overflow-prone ops stay unfolded.
pub fn foldConstants(allocator: std.mem.Allocator, expr: ast.Expr) !ast.Expr {
    switch (expr) {
        .binary => |bin| {
            const foldedLeft = try foldConstants(allocator, bin.left.*);
            const foldedRight = try foldConstants(allocator, bin.right.*);

            if (bin.op == .logicalAnd) {
                if (foldedLeft == .literal and !foldedLeft.literal.isTruthy()) {
                    ast.freeExprRec(allocator, foldedRight);
                    return foldedLeft;
                }
                if (foldedRight == .literal and !foldedRight.literal.isTruthy()) {
                    ast.freeExprRec(allocator, foldedLeft);
                    return foldedRight;
                }
                if (foldedLeft == .literal and foldedLeft.literal.isTruthy()) {
                    return foldedRight;
                }
                if (foldedRight == .literal and foldedRight.literal.isTruthy()) {
                    return foldedLeft;
                }
            }
            if (bin.op == .logicalOr) {
                if (foldedLeft == .literal and foldedLeft.literal.isTruthy()) {
                    ast.freeExprRec(allocator, foldedRight);
                    return foldedLeft;
                }
                if (foldedRight == .literal and foldedRight.literal.isTruthy()) {
                    ast.freeExprRec(allocator, foldedLeft);
                    return foldedRight;
                }
                if (foldedLeft == .literal and !foldedLeft.literal.isTruthy()) {
                    return foldedRight;
                }
                if (foldedRight == .literal and !foldedRight.literal.isTruthy()) {
                    return foldedLeft;
                }
            }

            // Both sides literal: evaluate once with the same semantics as
            // runtime (`expr.eval`), covering int/real arithmetic (overflow
            // widens to REAL), bitwise ops, all comparisons with three-valued
            // NULL logic, IS/IS NOT, and text-text concatenation. Anything
            // else (identifiers, calls, patterns, subqueries) rebuilds below.
            if (foldedLeft == .literal and foldedRight == .literal and isFoldableBinary(bin.op)) {
                var lNode = foldedLeft;
                var rNode = foldedRight;
                const probe = ast.Expr{ .binary = .{ .op = bin.op, .left = &lNode, .right = &rNode } };
                const noCols = [_][]const u8{};
                const noRow = [_]Value{};
                return .{ .literal = try exprEval.eval(allocator, &noCols, &noRow, probe) };
            }

            const lNode = try allocator.create(ast.Expr);
            lNode.* = foldedLeft;
            const rNode = try allocator.create(ast.Expr);
            rNode.* = foldedRight;
            return .{ .binary = .{ .op = bin.op, .left = lNode, .right = rNode } };
        },
        .unary => |un| {
            const foldedInner = try foldConstants(allocator, un.expr.*);
            if (foldedInner == .literal and isFoldableUnary(un.op)) {
                var innerNode = foldedInner;
                const probe = ast.Expr{ .unary = .{ .op = un.op, .expr = &innerNode } };
                const noCols = [_][]const u8{};
                const noRow = [_]Value{};
                return .{ .literal = try exprEval.eval(allocator, &noCols, &noRow, probe) };
            }
            const innerNode = try allocator.create(ast.Expr);
            innerNode.* = foldedInner;
            return .{ .unary = .{ .op = un.op, .expr = innerNode } };
        },
        else => return expr,
    }
}

/// Binary operators safe to fold when both sides are literals: pure,
/// row-independent, and evaluated by `expr.eval` with runtime-identical
/// semantics. Functions, patterns, IN, CASE, and subqueries are excluded —
/// they need catalog/row context or have their own dispatch.
fn isFoldableBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .subtract, .multiply, .divide, .modulo, .bitAnd, .bitOr, .shiftLeft, .shiftRight, .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual, .isOp, .isNotOp, .concat, .isTrue, .isNotTrue, .isFalse, .isNotFalse => true,
        .logicalAnd, .logicalOr, .jsonArrow, .jsonArrowText => false,
    };
}

/// Unary operators safe to fold on a literal operand (same rationale).
fn isFoldableUnary(op: ast.UnaryOp) bool {
    return switch (op) {
        .negate, .positive, .bitNot, .logicalNot => true,
    };
}

/// Free a tree produced by `foldConstants`: releases owned text/blob literal
/// payloads (concat folding allocates them) before the node structure.
/// Never use on parser-borrowed trees, whose literal slices are borrowed.
pub fn freeFoldedExpr(allocator: std.mem.Allocator, expr: ast.Expr) void {
    switch (expr) {
        .literal => |lit| lit.free(allocator),
        .binary => |bin| {
            freeFoldedExpr(allocator, bin.left.*);
            freeFoldedExpr(allocator, bin.right.*);
            allocator.destroy(bin.left);
            allocator.destroy(bin.right);
        },
        .unary => |un| {
            freeFoldedExpr(allocator, un.expr.*);
            allocator.destroy(un.expr);
        },
        else => ast.freeExprRec(allocator, expr),
    }
}
/// Whether `expr` may be evaluated on scans of `targetTable` alone.
/// Bare identifiers push anywhere; qualified `table.column` references push
/// only when the qualifier's last segment matches the target (so `a.x` pushes
/// to `a` but never to `b`, and `schema.tbl.col` matches `tbl`). Literals
/// push anywhere; calls, patterns, and subqueries never push (conservative).
pub fn canPushDownPredicate(expr: ast.Expr, targetTable: []const u8) bool {
    switch (expr) {
        .identifier => |name| return qualifierMatchesTarget(name, targetTable),
        .binary => |b| return canPushDownPredicate(b.left.*, targetTable) and canPushDownPredicate(b.right.*, targetTable),
        .unary => |u| return canPushDownPredicate(u.expr.*, targetTable),
        .literal => return true,
        else => return false,
    }
}

/// Qualifier check behind `canPushDownPredicate`: unqualified names are
/// scope-free; otherwise the segment before the final dot (itself possibly
/// schema-qualified) must equal the target, ASCII case-insensitive.
fn qualifierMatchesTarget(name: []const u8, targetTable: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return true;
    if (dot == 0 or dot + 1 >= name.len) return false;
    const qualifier = name[0..dot];
    const segment = if (std.mem.lastIndexOfScalar(u8, qualifier, '.')) |d| qualifier[d + 1 ..] else qualifier;
    if (segment.len == 0) return false;
    return std.ascii.eqlIgnoreCase(segment, targetTable);
}

test "optimizer identifies boolean constants" {
    try std.testing.expect(isConstantTrue(true));
    try std.testing.expect(isConstantFalse(false));
}

test "optimizer folds constant arithmetic expressions" {
    const leftLit = ast.Expr{ .literal = .{ .integer = 40 } };
    const rightLit = ast.Expr{ .literal = .{ .integer = 2 } };
    const addExpr = ast.Expr{ .binary = .{ .op = .add, .left = &leftLit, .right = &rightLit } };

    const folded = try foldConstants(std.testing.allocator, addExpr);
    try std.testing.expect(folded == .literal);
    try std.testing.expectEqual(@as(i64, 42), folded.literal.integer);
}

test "optimizer simplifies boolean logic" {
    const falseLit = ast.Expr{ .literal = .{ .integer = 0 } };
    const colExpr = ast.Expr{ .identifier = "x" };
    const andExpr = ast.Expr{ .binary = .{ .op = .logicalAnd, .left = &falseLit, .right = &colExpr } };

    const folded = try foldConstants(std.testing.allocator, andExpr);
    try std.testing.expect(folded == .literal);
    try std.testing.expectEqual(@as(i64, 0), folded.literal.integer);
}

test "optimizer folds float arithmetic and text concat" {
    var a = ast.Expr{ .literal = .{ .real = 1.5 } };
    var b = ast.Expr{ .literal = .{ .real = 2.5 } };
    const add = ast.Expr{ .binary = .{ .op = .add, .left = &a, .right = &b } };
    const foldedAdd = try foldConstants(std.testing.allocator, add);
    defer freeFoldedExpr(std.testing.allocator, foldedAdd);
    try std.testing.expectEqual(@as(f64, 4.0), foldedAdd.literal.real);

    var s1 = ast.Expr{ .literal = .{ .text = "a" } };
    var s2 = ast.Expr{ .literal = .{ .text = "b" } };
    const concat = ast.Expr{ .binary = .{ .op = .concat, .left = &s1, .right = &s2 } };
    const foldedConcat = try foldConstants(std.testing.allocator, concat);
    defer freeFoldedExpr(std.testing.allocator, foldedConcat);
    try std.testing.expectEqualStrings("ab", foldedConcat.literal.text);
}

test "optimizer folding preserves null, overflow, and shift rules" {
    // NULL comparisons fold to NULL, not to 0/1 (three-valued logic).
    var n1 = ast.Expr{ .literal = .null };
    var n2 = ast.Expr{ .literal = .null };
    const eqNull = ast.Expr{ .binary = .{ .op = .equal, .left = &n1, .right = &n2 } };
    const foldedNull = try foldConstants(std.testing.allocator, eqNull);
    defer freeFoldedExpr(std.testing.allocator, foldedNull);
    try std.testing.expect(foldedNull.literal == .null);

    // Integer overflow widens to REAL instead of trapping.
    var big = ast.Expr{ .literal = .{ .integer = std.math.maxInt(i64) } };
    var one = ast.Expr{ .literal = .{ .integer = 1 } };
    const overflow = ast.Expr{ .binary = .{ .op = .add, .left = &big, .right = &one } };
    const foldedBig = try foldConstants(std.testing.allocator, overflow);
    defer freeFoldedExpr(std.testing.allocator, foldedBig);
    try std.testing.expect(foldedBig.literal == .real);

    // Unary minus on minInt widens instead of trapping.
    var min = ast.Expr{ .literal = .{ .integer = std.math.minInt(i64) } };
    const neg = ast.Expr{ .unary = .{ .op = .negate, .expr = &min } };
    const foldedNeg = try foldConstants(std.testing.allocator, neg);
    defer freeFoldedExpr(std.testing.allocator, foldedNeg);
    try std.testing.expectEqual(@as(f64, 9223372036854775808.0), foldedNeg.literal.real);

    // Negative shifts flip direction: 4 << -1 is 4 >> 1.
    var four = ast.Expr{ .literal = .{ .integer = 4 } };
    var negOne = ast.Expr{ .literal = .{ .integer = -1 } };
    const shift = ast.Expr{ .binary = .{ .op = .shiftLeft, .left = &four, .right = &negOne } };
    const foldedShift = try foldConstants(std.testing.allocator, shift);
    defer freeFoldedExpr(std.testing.allocator, foldedShift);
    try std.testing.expectEqual(@as(i64, 2), foldedShift.literal.integer);

    // Non-foldable trees rebuild instead of folding.
    var col = ast.Expr{ .identifier = "x" };
    var five = ast.Expr{ .literal = .{ .integer = 5 } };
    const colAdd = ast.Expr{ .binary = .{ .op = .add, .left = &col, .right = &five } };
    const foldedCol = try foldConstants(std.testing.allocator, colAdd);
    defer freeFoldedExpr(std.testing.allocator, foldedCol);
    try std.testing.expect(foldedCol == .binary);
}

test "pushdown respects column qualifiers" {
    const bare = ast.Expr{ .identifier = "x" };
    try std.testing.expect(canPushDownPredicate(bare, "a"));
    try std.testing.expect(canPushDownPredicate(bare, "b"));
    const qualified = ast.Expr{ .identifier = "a.x" };
    try std.testing.expect(canPushDownPredicate(qualified, "a"));
    try std.testing.expect(canPushDownPredicate(qualified, "A"));
    try std.testing.expect(!canPushDownPredicate(qualified, "b"));
    const schemaQualified = ast.Expr{ .identifier = "aux.orders.amount" };
    try std.testing.expect(canPushDownPredicate(schemaQualified, "orders"));
    try std.testing.expect(!canPushDownPredicate(schemaQualified, "aux"));
    try std.testing.expect(!canPushDownPredicate(schemaQualified, "users"));
    var left = ast.Expr{ .identifier = "a.x" };
    var right = ast.Expr{ .literal = .{ .integer = 1 } };
    const pred = ast.Expr{ .binary = .{ .op = .equal, .left = &left, .right = &right } };
    try std.testing.expect(canPushDownPredicate(pred, "a"));
    try std.testing.expect(!canPushDownPredicate(pred, "b"));
}
