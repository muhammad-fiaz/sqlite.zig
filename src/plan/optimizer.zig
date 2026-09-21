//! Query optimizer: constant folding and predicate pushdown checks.
//!
//! Purpose: cheap logical rewrites before planning — fold literal-only
//! arithmetic/comparisons and boolean identities, and answer whether a
//! predicate can be pushed to a given table scan.
//!
//! Responsibilities: pure AST->AST transform (`foldConstants`) allocating
//! replacement nodes with the caller allocator; `canPushDownPredicate` is a
//! conservative syntactic check used by the planner.
//!
//! Dependencies: `../sql/ast.zig`, `../vm/value.zig`; no schema/VM imports.
//!
//! Ownership/lifetime: input `expr` is borrowed; the returned tree owns its
//! *new* nodes (free dropped sides internally; caller frees the result
//! structure with `ast.freeExprRec` plus its own arena policy). Literals need
//! no freeing.
//!
//! Error behavior: OOM only. Folding is overflow-safe: overflowing `+ - *` or
//! unary `-` on minInt is left unfolded (runtime handles widening) rather
//! than trapping.
//!
//! Invariants: folding preserves three-valued logic; `AND`/`OR` identities
//! only apply to literal sides; non-literal trees are rebuilt, never mutated.
//!
//! SQLite compatibility: matches SQLite's `truthy` (via `Value.isTruthy`)
//! for boolean identities; arithmetic identities are intentionally minimal.
// TODO(plan/optimizer): `canPushDownPredicate` ignores `targetTable` and
// returns true for any bare identifier, so qualified `a.x` could push to `b`.
// Expected: qualifier-aware check (split on `.`, compare to target/alias);
// tests: `a.x` pushable to `a` only, `x` pushable anywhere. Subsystem: plan/opt.
// TODO(plan/optimizer): folding covers only int `+ - * /` and `=`/`!=`;
// floats, comparisons, and string concat are left unfolded. Expected: reuse
// `expr.zig` evaluation for full literal folding; tests: `1.5+2.5`,
// `'a'||'b'` fold matrices. Subsystem: plan/opt.

const std = @import("std");
const ast = @import("../sql/ast.zig");
const Value = @import("../vm/value.zig").Value;

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

            if (foldedLeft == .literal and foldedRight == .literal) {
                const valA = foldedLeft.literal;
                const valB = foldedRight.literal;
                switch (bin.op) {
                    .add => {
                        if (valA == .integer and valB == .integer) {
                            const res = @addWithOverflow(valA.integer, valB.integer);
                            if (res[1] == 0) return .{ .literal = .{ .integer = res[0] } };
                        }
                    },
                    .subtract => {
                        if (valA == .integer and valB == .integer) {
                            const res = @subWithOverflow(valA.integer, valB.integer);
                            if (res[1] == 0) return .{ .literal = .{ .integer = res[0] } };
                        }
                    },
                    .multiply => {
                        if (valA == .integer and valB == .integer) {
                            const res = @mulWithOverflow(valA.integer, valB.integer);
                            if (res[1] == 0) return .{ .literal = .{ .integer = res[0] } };
                        }
                    },
                    .divide => {
                        if (valA == .integer and valB == .integer and valB.integer != 0) {
                            if (valA.integer == std.math.minInt(i64) and valB.integer == -1) {
                                // Leave minInt / -1 unfolded; runtime widens to REAL.
                            } else return .{ .literal = .{ .integer = @divTrunc(valA.integer, valB.integer) } };
                        }
                    },
                    .equal => {
                        return .{ .literal = .{ .integer = if (valA.sameValue(valB)) 1 else 0 } };
                    },
                    .notEqual => {
                        return .{ .literal = .{ .integer = if (!valA.sameValue(valB)) 1 else 0 } };
                    },
                    else => {},
                }
            }

            const lNode = try allocator.create(ast.Expr);
            lNode.* = foldedLeft;
            const rNode = try allocator.create(ast.Expr);
            rNode.* = foldedRight;
            return .{ .binary = .{ .op = bin.op, .left = lNode, .right = rNode } };
        },
        .unary => |un| {
            const foldedInner = try foldConstants(allocator, un.expr.*);
            if (foldedInner == .literal) {
                const val = foldedInner.literal;
                switch (un.op) {
                    .negate => {
                        if (val == .integer) return .{ .literal = .{ .integer = -val.integer } };
                        if (val == .real) return .{ .literal = .{ .real = -val.real } };
                    },
                    .logicalNot => {
                        return .{ .literal = .{ .integer = if (val.isTruthy()) 0 else 1 } };
                    },
                    else => {},
                }
            }
            const innerNode = try allocator.create(ast.Expr);
            innerNode.* = foldedInner;
            return .{ .unary = .{ .op = un.op, .expr = innerNode } };
        },
        else => return expr,
    }
}

pub fn canPushDownPredicate(expr: ast.Expr, targetTable: []const u8) bool {
    switch (expr) {
        .identifier => return true,
        .binary => |b| return canPushDownPredicate(b.left.*, targetTable) and canPushDownPredicate(b.right.*, targetTable),
        .unary => |u| return canPushDownPredicate(u.expr.*, targetTable),
        .literal => return true,
        else => return false,
    }
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
