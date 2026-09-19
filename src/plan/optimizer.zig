const std = @import("std");
const ast = @import("../sql/ast.zig");
const Value = @import("../vm/value.zig").Value;

pub fn isConstantTrue(value: bool) bool {
    return value;
}

pub fn isConstantFalse(value: bool) bool {
    return !value;
}

pub fn foldConstants(allocator: std.mem.Allocator, expr: ast.Expr) !ast.Expr {
    switch (expr) {
        .binary => |bin| {
            const foldedLeft = try foldConstants(allocator, bin.left.*);
            const foldedRight = try foldConstants(allocator, bin.right.*);

            if (bin.op == .logicalAnd) {
                if (foldedLeft == .literal and !foldedLeft.literal.isTruthy()) return foldedLeft;
                if (foldedRight == .literal and !foldedRight.literal.isTruthy()) return foldedRight;
                if (foldedLeft == .literal and foldedLeft.literal.isTruthy()) return foldedRight;
                if (foldedRight == .literal and foldedRight.literal.isTruthy()) return foldedLeft;
            }
            if (bin.op == .logicalOr) {
                if (foldedLeft == .literal and foldedLeft.literal.isTruthy()) return foldedLeft;
                if (foldedRight == .literal and foldedRight.literal.isTruthy()) return foldedRight;
                if (foldedLeft == .literal and !foldedLeft.literal.isTruthy()) return foldedRight;
                if (foldedRight == .literal and !foldedRight.literal.isTruthy()) return foldedLeft;
            }

            if (foldedLeft == .literal and foldedRight == .literal) {
                const valA = foldedLeft.literal;
                const valB = foldedRight.literal;
                switch (bin.op) {
                    .add => {
                        if (valA == .integer and valB == .integer) {
                            return .{ .literal = .{ .integer = valA.integer + valB.integer } };
                        }
                    },
                    .subtract => {
                        if (valA == .integer and valB == .integer) {
                            return .{ .literal = .{ .integer = valA.integer - valB.integer } };
                        }
                    },
                    .multiply => {
                        if (valA == .integer and valB == .integer) {
                            return .{ .literal = .{ .integer = valA.integer * valB.integer } };
                        }
                    },
                    .divide => {
                        if (valA == .integer and valB == .integer and valB.integer != 0) {
                            return .{ .literal = .{ .integer = @divTrunc(valA.integer, valB.integer) } };
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
