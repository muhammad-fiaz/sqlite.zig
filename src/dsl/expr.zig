//! DSL intermediate representation: predicates, projections, and assignments.
//!
//! Purpose: the vocabulary shared by the typed DSL (`dsl/column.zig`,
//! `dsl/table.zig`) and the dynamic DSL (`dsl/dynamic.zig`). Every entry here
//! is a plain, non-owning value — table/column names and function names are
//! borrowed slices, `Value`s borrow text/blob payloads.
//!
//! Responsibilities: define `ColumnRef`, `FuncCall`, `Operator`, `Expr`,
//! `Order`, `Projection`, `HavingCond`, and the `SetValue` assignment union
//! consumed by `dsl/ast_builder.zig`.
//!
//! Dependencies: `vm/value.zig` only. No allocator, no SQL text.
//!
//! Ownership/lifetime: all structs are `Copyable` values. String and `Value`
//! payloads are borrowed; `ast_builder` duplicates whatever the native AST
//! must retain into `BuiltStatement.ownedStrings`. Dropping an `Expr`
//! invalidates nothing. AST builders copy the struct, so mutating the DSL
//! value after `where()`/`select()` has no effect.
//!
//! Error behavior: pure data; no fallible operations. Validation (unknown
//! columns, bad HAVING shapes) happens later in `ast_builder` and returns
//! `error.InvalidSql`.
//!
//! SQLite compatibility: `Operator.sql` renders reference keywords
//! (`IS DISTINCT FROM`, `GLOB`, `MATCH`, ...). DSL operators map 1:1 onto
//! `ast.CompareOp`/`ast.BinaryOp` in `ast_builder`.
//!
//! Unified pipeline note: Raw SQL, the dynamic DSL, and the typed DSL all
//! converge on native AST/IR via `ast_builder` — this IR is never rendered to
//! an SQL string and re-parsed.
//!
//! Column/operation collision rule: schema fields are always valid struct
//! fields (`User.where`, `User.count` are column descriptors); DSL operations
//! are methods/calls on those values (`User.all()`, `col.count()`), so user
//! columns named like operations never collide.
//!
//! AllColumns note: `Projection.kind` distinguishes `.star` (native `*`) from
//! `.countStar` (native `COUNT(*)`); `countStar()` builds the latter without
//! touching a column descriptor.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;

/// Borrowed reference to one column. `table`/`schema` may be empty for
/// unqualified references; `name` is never empty in well-formed IR.
pub const ColumnRef = struct {
    table: []const u8 = "",
    name: []const u8,
    schema: []const u8 = "",
};

/// Borrowed scalar-function call attached to a column (`LOWER(name)`).
/// `argument`/`argument2` are literal `Value`s (borrowed payloads).
pub const FuncCall = struct {
    name: []const u8,
    argument: Value = .null,
    argument2: Value = .null,
    hasArgument: bool = false,
    hasArgument2: bool = false,
};

/// Comparison / pattern predicate. Maps 1:1 onto `ast.CompareOp` via
/// `ast_builder.mapCompareOp`. `sql()` is for diagnostics only.
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

    /// Reference keyword rendering for diagnostics/tests. Never parsed back.
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

/// Right-hand side of a predicate: a literal `Value` or another column.
/// Borrowed; `ast_builder.rhsToExpr` resolves it against the query's strip base.
pub const Rhs = union(enum) {
    value: Value,
    column: ColumnRef,
};

/// One predicate (`column OP rhs [AND rhs2]`, optional function/escape).
/// `negated` wraps the predicate in logical NOT at AST build time.
pub const Expr = struct {
    column: ColumnRef,
    operator: Operator,
    rhs: Rhs = .{ .value = .null },
    rhs2: ?Rhs = null,
    function: ?FuncCall = null,
    escape: ?Value = null,
    collate: ?[]const u8 = null,
    negated: bool = false,

    /// True unless the operator is IS NULL / IS NOT NULL (no RHS needed).
    pub fn needsRhs(self: Expr) bool {
        return self.operator != .isNull and self.operator != .isNotNull;
    }

    /// True only for BETWEEN / NOT BETWEEN (a second RHS bound is required).
    pub fn needsRhs2(self: Expr) bool {
        return self.operator == .between or self.operator == .notBetween;
    }

    /// Return a copy with the NOT flag toggled. The original is unchanged.
    pub fn notOp(self: Expr) Expr {
        var copy = self;
        copy.negated = !copy.negated;
        return copy;
    }
};

/// Sort key: borrowed column plus direction and optional scalar wrapper.
pub const Order = struct {
    column: ColumnRef,
    descending: bool = false,
    function: ?FuncCall = null,
};

/// SELECT/RETURNING projection. `.star` is native `*`, `.countStar` is native
/// `COUNT(*)`; `.caseExpr`/`.window` index side tables carried by the builder.
/// All names/values borrowed; `alias` (if set) is borrowed too.
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

    /// Borrowed alias copy (`SELECT x AS name`). Does not allocate.
    pub fn as(self: @This(), name: []const u8) @This() {
        var copy = self;
        copy.alias = name;
        return copy;
    }

    fn havingCond(self: @This(), op: []const u8, value: anytype) HavingCond {
        return .{ .proj = self, .op = op, .rhs = toHavingValue(value) };
    }

    /// HAVING helpers: attach a comparison against a literal to this
    /// projection. `value` is converted with the same rules as `toValue`.
    pub fn gt(self: @This(), value: anytype) HavingCond {
        return self.havingCond(">", value);
    }
    /// `>=` HAVING comparison; see `gt`.
    pub fn gte(self: @This(), value: anytype) HavingCond {
        return self.havingCond(">=", value);
    }
    /// `<` HAVING comparison; see `gt`.
    pub fn lt(self: @This(), value: anytype) HavingCond {
        return self.havingCond("<", value);
    }
    /// `<=` HAVING comparison; see `gt`.
    pub fn lte(self: @This(), value: anytype) HavingCond {
        return self.havingCond("<=", value);
    }
    /// `=` HAVING comparison; see `gt`.
    pub fn eq(self: @This(), value: anytype) HavingCond {
        return self.havingCond("=", value);
    }
    /// `<>` HAVING comparison; see `gt`.
    pub fn ne(self: @This(), value: anytype) HavingCond {
        return self.havingCond("<>", value);
    }
};

/// HAVING clause: borrowed projection plus borrowed op string plus literal RHS.
/// Materialized into `ast.Having` by `ast_builder`; invalid ops fail there.
pub const HavingCond = struct {
    proj: Projection,
    op: []const u8,
    rhs: Value,
};

/// Assignment arithmetic operator (`col + rhs`, ...).
pub const ArithOp = enum { add, sub, mul, div, mod };

/// One side of an assignment expression: literal or borrowed column.
pub const SetOperand = union(enum) {
    literal: Value,
    column: ColumnRef,
};

/// Binary assignment expression payload (`left op right`).
pub const SetArith = struct {
    op: ArithOp,
    left: SetOperand,
    right: SetOperand,
};

/// Value assigned to one column in INSERT/UPDATE/UPSERT: literal, column
/// reference (borrowed), or arithmetic tree over `SetOperand`s.
pub const SetValue = union(enum) {
    literal: Value,
    column: ColumnRef,
    arith: SetArith,
};

/// Builder-time arithmetic handle (`col.add(1)`). Convert with
/// `toSetValue` before storing it in an INSERT/UPDATE row struct.
pub const ArithExpr = struct {
    op: ArithOp,
    left: SetOperand,
    right: SetOperand,
    pub const isArithExpr = true;

    /// Lower this handle into a storable `SetValue` (copies operands).
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

/// Native `COUNT(*)` projection. Borrowed; no column is touched, so the
/// all-columns collision rule does not apply here.
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

test "distinct and negated predicates stay value-semantic" {
    const base = Expr{ .column = .{ .name = "age" }, .operator = .greater, .rhs = .{ .value = .{ .integer = 1 } } };
    try std.testing.expect(!base.negated);
    try std.testing.expect(base.notOp().negated);
    try std.testing.expect(!base.notOp().notOp().negated);
    const star = Projection{ .kind = .star };
    try std.testing.expectEqualStrings("x", star.as("x").alias.?);
    const arith = ArithExpr{ .op = .add, .left = .{ .literal = .{ .integer = 1 } }, .right = .{ .literal = .{ .integer = 2 } } };
    const lowered = arith.toSetValue();
    try std.testing.expect(lowered == .arith);
    try std.testing.expect(lowered.arith.op == .add);
    // HAVING helpers borrow the projection and convert the literal eagerly.
    const proj = Projection{ .kind = .aggregate, .column = .{ .name = "age" }, .function = "SUM" };
    try std.testing.expectEqualStrings(">=", proj.gte(3).op);
    try std.testing.expectEqual(@as(i64, 3), proj.gte(3).rhs.integer);
    try std.testing.expectEqualStrings("x", proj.as("x").alias.?);
}
