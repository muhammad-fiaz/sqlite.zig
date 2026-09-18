const std = @import("std");
const Value = @import("../vm/value.zig").Value;

pub const ColumnRef = struct {
    table: []const u8 = "",
    name: []const u8,
};

pub const FuncCall = struct {
    name: []const u8,
    argument: Value = .null,
    argument2: Value = .null,
    hasArgument: bool = false,
    hasArgument2: bool = false,
};

pub const Operator = enum {
    equal,
    notEqual,
    less,
    lessEqual,
    greater,
    greaterEqual,
    like,
    notLike,
    glob,
    notGlob,
    regexp,
    notRegexp,
    match,
    notMatch,
    isNull,
    isNotNull,
    isValue,
    isNotValue,
    isDistinct,
    isNotDistinct,
    between,
    notBetween,

    pub fn sql(self: Operator) []const u8 {
        return switch (self) {
            .equal => "=",
            .notEqual => "<>",
            .less => "<",
            .lessEqual => "<=",
            .greater => ">",
            .greaterEqual => ">=",
            .like => "LIKE",
            .notLike => "NOT LIKE",
            .glob => "GLOB",
            .notGlob => "NOT GLOB",
            .regexp => "REGEXP",
            .notRegexp => "NOT REGEXP",
            .match => "MATCH",
            .notMatch => "NOT MATCH",
            .isNull => "IS NULL",
            .isNotNull => "IS NOT NULL",
            .isValue => "IS",
            .isNotValue => "IS NOT",
            .isDistinct => "IS DISTINCT FROM",
            .isNotDistinct => "IS NOT DISTINCT FROM",
            .between => "BETWEEN",
            .notBetween => "NOT BETWEEN",
        };
    }
};

pub const Rhs = union(enum) {
    value: Value,
    column: ColumnRef,
};

pub const Expr = struct {
    column: ColumnRef,
    operator: Operator,
    rhs: Rhs = .{ .value = .null },
    rhs2: ?Rhs = null,
    function: ?FuncCall = null,
    escape: ?Value = null,
    collate: ?[]const u8 = null,
    negated: bool = false,

    pub fn needsRhs(self: Expr) bool {
        return self.operator != .isNull and self.operator != .isNotNull;
    }

    pub fn needsRhs2(self: Expr) bool {
        return self.operator == .between or self.operator == .notBetween;
    }

    pub fn notOp(self: Expr) Expr {
        var copy = self;
        copy.negated = !copy.negated;
        return copy;
    }
};

pub const Order = struct {
    column: ColumnRef,
    descending: bool = false,
    function: ?FuncCall = null,
};

pub const Projection = struct {
    kind: enum { column, aggregate, scalar, star, countStar },
    column: ColumnRef = .{ .name = "" },
    function: []const u8 = "",
    argument: Value = .null,
    argument2: Value = .null,
    hasArgument: bool = false,
    hasArgument2: bool = false,
    distinct: bool = false,
};

pub fn countStar() Projection {
    return .{ .kind = .countStar };
}

test "operators render SQLite keywords" {
    try std.testing.expectEqualStrings("=", Operator.equal.sql());
    try std.testing.expectEqualStrings("<>", Operator.notEqual.sql());
    try std.testing.expectEqualStrings("<", Operator.less.sql());
    try std.testing.expectEqualStrings("<=", Operator.lessEqual.sql());
    try std.testing.expectEqualStrings(">", Operator.greater.sql());
    try std.testing.expectEqualStrings(">=", Operator.greaterEqual.sql());
    try std.testing.expectEqualStrings("LIKE", Operator.like.sql());
    try std.testing.expectEqualStrings("NOT LIKE", Operator.notLike.sql());
    try std.testing.expectEqualStrings("GLOB", Operator.glob.sql());
    try std.testing.expectEqualStrings("NOT GLOB", Operator.notGlob.sql());
    try std.testing.expectEqualStrings("IS NULL", Operator.isNull.sql());
    try std.testing.expectEqualStrings("IS NOT NULL", Operator.isNotNull.sql());
    try std.testing.expectEqualStrings("IS", Operator.isValue.sql());
    try std.testing.expectEqualStrings("IS NOT", Operator.isNotValue.sql());
    try std.testing.expectEqualStrings("IS DISTINCT FROM", Operator.isDistinct.sql());
    try std.testing.expectEqualStrings("IS NOT DISTINCT FROM", Operator.isNotDistinct.sql());
    try std.testing.expectEqualStrings("BETWEEN", Operator.between.sql());
    try std.testing.expectEqualStrings("NOT BETWEEN", Operator.notBetween.sql());
    try std.testing.expectEqualStrings("REGEXP", Operator.regexp.sql());
    try std.testing.expectEqualStrings("NOT REGEXP", Operator.notRegexp.sql());
    try std.testing.expectEqualStrings("MATCH", Operator.match.sql());
    try std.testing.expectEqualStrings("NOT MATCH", Operator.notMatch.sql());
}

test "predicates report which sides they need" {
    const bare = Expr{ .column = .{ .name = "age" }, .operator = .isNull };
    try std.testing.expect(!bare.needsRhs());
    try std.testing.expect(!bare.needsRhs2());
    const cmp = Expr{ .column = .{ .name = "age" }, .operator = .greater, .rhs = .{ .value = .{ .integer = 1 } } };
    try std.testing.expect(cmp.needsRhs());
    try std.testing.expect(!cmp.needsRhs2());
    const btw = Expr{ .column = .{ .name = "age" }, .operator = .between, .rhs = .{ .value = .{ .integer = 1 } }, .rhs2 = .{ .value = .{ .integer = 2 } } };
    try std.testing.expect(btw.needsRhs());
    try std.testing.expect(btw.needsRhs2());
}

test "countStar builds a star projection" {
    try std.testing.expect(countStar().kind == .countStar);
}
