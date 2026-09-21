const std = @import("std");
const Value = @import("../vm/value.zig").Value;

pub const ColumnRef = struct {
    table: []const u8 = "",
    name: []const u8,
    schema: []const u8 = "",
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
    kind: enum { column, aggregate, scalar, star, countStar, caseExpr, window },
    column: ColumnRef = .{ .name = "" },
    function: []const u8 = "",
    argument: Value = .null,
    argument2: Value = .null,
    hasArgument: bool = false,
    hasArgument2: bool = false,
    distinct: bool = false,
    caseSlot: u8 = 0,
    windowSlot: u8 = 0,
    alias: ?[]const u8 = null,

    pub fn as(self: @This(), name: []const u8) @This() {
        var copy = self;
        copy.alias = name;
        return copy;
    }

    fn havingCond(self: @This(), op: []const u8, value: anytype) HavingCond {
        return .{ .proj = self, .op = op, .rhs = toHavingValue(value) };
    }

    pub fn gt(self: @This(), value: anytype) HavingCond {
        return self.havingCond(">", value);
    }
    pub fn gte(self: @This(), value: anytype) HavingCond {
        return self.havingCond(">=", value);
    }
    pub fn lt(self: @This(), value: anytype) HavingCond {
        return self.havingCond("<", value);
    }
    pub fn lte(self: @This(), value: anytype) HavingCond {
        return self.havingCond("<=", value);
    }
    pub fn eq(self: @This(), value: anytype) HavingCond {
        return self.havingCond("=", value);
    }
    pub fn ne(self: @This(), value: anytype) HavingCond {
        return self.havingCond("<>", value);
    }
};

pub const HavingCond = struct {
    proj: Projection,
    op: []const u8,
    rhs: Value,
};

pub const ArithOp = enum { add, sub, mul, div, mod };

pub const SetOperand = union(enum) {
    literal: Value,
    column: ColumnRef,
};

pub const SetArith = struct {
    op: ArithOp,
    left: SetOperand,
    right: SetOperand,
};

pub const SetValue = union(enum) {
    literal: Value,
    column: ColumnRef,
    arith: SetArith,
};

pub const ArithExpr = struct {
    op: ArithOp,
    left: SetOperand,
    right: SetOperand,
    pub const isArithExpr = true;

    pub fn toSetValue(self: @This()) SetValue {
        return .{ .arith = .{ .op = self.op, .left = self.left, .right = self.right } };
    }
};

fn toHavingValue(value: anytype) Value {
    const T = @TypeOf(value);
    if (T == Value) return value;
    if (@typeInfo(T) == .optional) {
        if (value) |present| return toHavingValue(present);
        return .null;
    }
    return switch (@typeInfo(T)) {
        .bool => .{ .integer = if (value) 1 else 0 },
        .int, .comptime_int => .{ .integer = @intCast(value) },
        .float, .comptime_float => .{ .real = @floatCast(value) },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return .{ .text = value };
            if (ptr.size == .one) {
                const child = @typeInfo(ptr.child);
                if (child == .array and child.array.child == u8) return .{ .text = value };
            }
            @compileError("unsupported HAVING value type");
        },
        .null => .null,
        else => @compileError("unsupported HAVING value type"),
    };
}

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
