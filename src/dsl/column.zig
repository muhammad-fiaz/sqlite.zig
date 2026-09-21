//! Typed and dynamic column descriptors that build borrowed expr values.
//!
//! Descriptors hold borrowed names only; `ast_builder` dupes what it keeps.
//! Type misuse is a compile error; CASE/window overflow panics.

const std = @import("std");
const dslExpr = @import("expr.zig");
const Expr = dslExpr.Expr;
const Order = dslExpr.Order;
const Projection = dslExpr.Projection;
const ColumnRef = dslExpr.ColumnRef;
const FuncCall = dslExpr.FuncCall;
const Operator = dslExpr.Operator;
const Value = @import("../vm/value.zig").Value;

/// Build a typed column value for a descriptor-declared SQL name.
/// `FieldType` drives `value()` checking and arithmetic gating only.
pub fn column(comptime name: []const u8, comptime FieldType: type) Column("", name, FieldType) {
    return .{};
}

/// Convert a Zig scalar to a borrowed `Value` (text/blob stay borrowed).
/// `Value` passes through; optionals map null -> `.null`; bools -> 0/1.
/// Anything else is a comptime error.
pub fn toValue(value: anytype) Value {
    const T = @TypeOf(value);
    if (T == Value) return value;
    if (@typeInfo(T) == .optional) {
        if (value) |present| return toValue(present);
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
            @compileError("unsupported DSL value type");
        },
        .null => .null,
        else => @compileError("unsupported DSL value type"),
    };
}

/// Split `"table.col"` / `"col"` into a borrowed `ColumnRef`.
pub fn splitRef(name: []const u8) ColumnRef {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        return .{ .table = name[0..dot], .name = name[dot + 1 ..] };
    }
    return .{ .name = name };
}

/// Resolve a `DynamicColumn` to a `ColumnRef`, preferring explicit
/// schema/table fields and falling back to dotted-name parsing. Borrowed.
pub fn dynRef(col: DynamicColumn) ColumnRef {
    if (col.schema.len != 0 or col.table.len != 0) return .{ .schema = col.schema, .table = col.table, .name = col.name };
    return splitRef(col.name);
}

fn isTypedColumn(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "isDslColumn") and T.isDslColumn;
}

/// Convert a column descriptor or literal into an `Rhs` (borrowed).
pub fn toRhs(value: anytype) dslExpr.Rhs {
    return rhsFrom(value);
}

/// Convert a typed or dynamic column descriptor into a borrowed `ColumnRef`.
pub fn toColumnRef(col: anytype) dslExpr.ColumnRef {
    const T = @TypeOf(col);
    if (T == DynamicColumn) return dynRef(col);
    if (comptime isTypedColumn(T)) return .{ .table = T.dslTable, .name = T.dslName };
    @compileError("expected a column descriptor (User.id or table.column(\"x\"))");
}

/// One CASE branch: searched (`cond` set) or simple (`operand` set).
/// Borrowed; built by `CaseBuilder.when` / `whenValue`.
pub const CaseWhen = struct { cond: ?Expr = null, operand: dslExpr.Rhs, result: dslExpr.Rhs, simple: bool };

/// Fixed-capacity (8 branches) CASE builder. Searched (`when`) and simple
/// (`whenValue` on a `caseValue` base) branches must not mix; misuse panics.
/// Borrowed; `ast_builder.caseToExpr` validates arity at build time.
pub const CaseBuilder = struct {
    base: ?dslExpr.ColumnRef = null,
    baseFunc: ?FuncCall = null,
    whens: [8]CaseWhen = undefined,
    count: usize = 0,
    otherwise: dslExpr.Rhs = .{ .value = .null },
    hasOtherwise: bool = false,

    /// Append a searched `WHEN cond THEN result`. Panics on simple-case base,
    /// mixed branch kinds, or more than 8 branches.
    pub fn when(self: @This(), cond: Expr, result: anytype) @This() {
        var copy = self;
        if (copy.base != null or copy.baseFunc != null) @panic("when() needs searched case; use whenValue() with caseValue()");
        if (copy.count != 0 and copy.whens[0].simple) @panic("cannot mix when() and whenValue() branches");
        if (copy.count >= copy.whens.len) @panic("too many CASE branches");
        copy.whens[copy.count] = .{ .cond = cond, .operand = .{ .value = .null }, .result = toRhs(result), .simple = false };
        copy.count += 1;
        return copy;
    }

    /// Append a simple `WHEN operand THEN result` (needs `caseValue` base).
    /// Panics on searched-case base, mixed branch kinds, or overflow.
    pub fn whenValue(self: @This(), operand: anytype, result: anytype) @This() {
        var copy = self;
        if (copy.base == null and copy.baseFunc == null) @panic("whenValue() needs simple case; use caseValue()");
        if (copy.count != 0 and !copy.whens[0].simple) @panic("cannot mix when() and whenValue() branches");
        if (copy.count >= copy.whens.len) @panic("too many CASE branches");
        copy.whens[copy.count] = .{ .operand = toRhs(operand), .result = toRhs(result), .simple = true };
        copy.count += 1;
        return copy;
    }

    /// Set the `ELSE` result (default is NULL). Overwrites any prior `else_`.
    pub fn else_(self: @This(), result: anytype) @This() {
        var copy = self;
        copy.otherwise = toRhs(result);
        copy.hasOtherwise = true;
        return copy;
    }
};

/// Start a searched CASE builder with one `WHEN cond THEN result`.
pub fn caseWhen(cond: Expr, result: anytype) CaseBuilder {
    var builder = CaseBuilder{};
    return builder.when(cond, result);
}

/// Start a simple CASE builder dispatching on `col` (typed or dynamic).
pub fn caseValue(col: anytype) CaseBuilder {
    const T = @TypeOf(col);
    if (T == DynamicColumn) {
        const ref = dynRef(col);
        return .{ .base = ref, .baseFunc = col.func };
    }
    if (comptime isTypedColumn(T)) {
        return .{ .base = .{ .table = T.dslTable, .name = T.dslName }, .baseFunc = col.func };
    }
    @compileError("caseValue() needs a column descriptor");
}

/// Window frame bound: fixed rows/groups offsets are `usize` counts.
pub const WindowBound = union(enum) {
    unboundedPreceding,
    preceding: usize,
    currentRow,
    following: usize,
    unboundedFollowing,
};

/// Window frame unit (ROWS / RANGE / GROUPS).
pub const WindowFrameKind = enum { rows, range, groups };

/// Rows removed by a window frame's EXCLUDE clause; default keeps everything.
pub const WindowExclude = enum { none, currentRow, group, ties };

/// Window frame span with inclusive start/end bounds.
pub const WindowFrameSpec = struct {
    kind: WindowFrameKind = .rows,
    start: WindowBound = .unboundedPreceding,
    end: WindowBound = .currentRow,
    exclude: WindowExclude = .none,
};

/// `UNBOUNDED PRECEDING` frame bound.
pub fn unboundedPreceding() WindowBound {
    return .unboundedPreceding;
}

/// `<offset> PRECEDING` frame bound.
pub fn preceding(offset: usize) WindowBound {
    return .{ .preceding = offset };
}

/// `CURRENT ROW` frame bound.
pub fn currentRow() WindowBound {
    return .currentRow;
}

/// `<offset> FOLLOWING` frame bound.
pub fn following(offset: usize) WindowBound {
    return .{ .following = offset };
}

/// `UNBOUNDED FOLLOWING` frame bound.
pub fn unboundedFollowing() WindowBound {
    return .unboundedFollowing;
}

/// Fixed-capacity (4 partitions, 2 orders) window-function builder.
/// Methods return copies; `ast_builder.windowToExpr` rejects unknown
/// function names with `error.InvalidSql` at build time.
pub const WindowBuilder = struct {
    /// Borrowed window function name (`"row_number"`, `"lag"`, ...).
    func: []const u8,
    /// Borrowed target column (for `lag`/`lead`/`first_value`/..., else null).
    arg: ?ColumnRef = null,
    /// Integer argument (`ntile` buckets, `lag` offset, `nth_value` n).
    argInt: i64 = 0,
    /// Whether `argInt` is meaningful.
    hasArgInt: bool = false,
    /// Borrowed default for `lag`/`lead` two-arg form.
    defaultRhs: dslExpr.Rhs = .{ .value = .null },
    /// Whether `defaultRhs` is meaningful.
    hasDefault: bool = false,
    /// Borrowed PARTITION BY columns (max 4).
    partitions: [4]ColumnRef = undefined,
    /// Number of valid `partitions` entries.
    partitionCount: usize = 0,
    /// ORDER BY keys inside the window (max 2).
    orders: [2]Order = undefined,
    /// Number of valid `orders` entries.
    orderCount: usize = 0,
    /// Optional frame span; null means the engine default.
    frame: ?WindowFrameSpec = null,
    /// Optional FILTER predicate (aggregate windows only).
    filterExpr: ?dslExpr.Expr = null,
    /// Aggregate DISTINCT flag (`sum(DISTINCT x) OVER (...)`).
    distinct: bool = false,

    fn withArg(col: anytype, func: []const u8) WindowBuilder {
        return .{ .func = func, .arg = toColumnRef(col) };
    }

    /// Add PARTITION BY columns (one descriptor or a tuple). Panics past 4.
    pub fn partitionBy(self: @This(), cols: anytype) @This() {
        var copy = self;
        const T = @TypeOf(cols);
        if (T == DynamicColumn) {
            if (copy.partitionCount >= copy.partitions.len) @panic("too many window partition columns");
            copy.partitions[copy.partitionCount] = dynRef(cols);
            copy.partitionCount += 1;
        } else if (comptime isTypedColumn(T)) {
            if (copy.partitionCount >= copy.partitions.len) @panic("too many window partition columns");
            copy.partitions[copy.partitionCount] = .{ .table = T.dslTable, .name = T.dslName };
            copy.partitionCount += 1;
        } else if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
            inline for (cols) |item| {
                if (copy.partitionCount >= copy.partitions.len) @panic("too many window partition columns");
                copy.partitions[copy.partitionCount] = toColumnRef(item);
                copy.partitionCount += 1;
            }
            if (copy.partitionCount == 0) @panic("partitionBy requires at least one column");
        } else {
            @compileError("partitionBy() needs a column descriptor or a tuple of column descriptors");
        }
        return copy;
    }

    /// Add window ORDER BY keys (`col.asc()` or a tuple). Panics past 2.
    pub fn orderBy(self: @This(), orders: anytype) @This() {
        var copy = self;
        const T = @TypeOf(orders);
        if (T == Order) {
            if (copy.orderCount >= copy.orders.len) @panic("too many window order columns");
            copy.orders[copy.orderCount] = orders;
            copy.orderCount += 1;
        } else if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
            inline for (orders) |item| {
                if (@TypeOf(item) != Order) @compileError("orderBy() needs column orders such as db.col(\"x\").asc()");
                if (copy.orderCount >= copy.orders.len) @panic("too many window order columns");
                copy.orders[copy.orderCount] = item;
                copy.orderCount += 1;
            }
            if (copy.orderCount == 0) @panic("orderBy() requires at least one order");
        } else {
            @compileError("orderBy() needs a column order such as db.col(\"x\").asc() or a tuple of orders");
        }
        return copy;
    }

    /// Set the integer argument (`lag`/`lead` offset, `nth_value` n).
    pub fn offset(self: @This(), amount: i64) @This() {
        var copy = self;
        copy.argInt = amount;
        copy.hasArgInt = true;
        return copy;
    }

    /// Set the `lag`/`lead` default value used past the partition edge.
    pub fn defaultValue(self: @This(), value: anytype) @This() {
        var copy = self;
        copy.defaultRhs = toRhs(value);
        copy.hasDefault = true;
        return copy;
    }

    fn frameBetween(self: @This(), kind: WindowFrameKind, start: WindowBound, end: WindowBound) @This() {
        var copy = self;
        copy.frame = .{ .kind = kind, .start = start, .end = end };
        return copy;
    }

    /// `ROWS BETWEEN start AND end` frame.
    pub fn rowsBetween(self: @This(), start: WindowBound, end: WindowBound) @This() {
        return self.frameBetween(.rows, start, end);
    }

    /// `RANGE BETWEEN start AND end` frame.
    pub fn rangeBetween(self: @This(), start: WindowBound, end: WindowBound) @This() {
        return self.frameBetween(.range, start, end);
    }

    /// `GROUPS BETWEEN start AND end` frame.
    pub fn groupsBetween(self: @This(), start: WindowBound, end: WindowBound) @This() {
        return self.frameBetween(.groups, start, end);
    }

    /// `ROWS start TO CURRENT ROW` shorthand frame.
    pub fn rowsFrom(self: @This(), start: WindowBound) @This() {
        return self.frameBetween(.rows, start, .currentRow);
    }

    /// `RANGE start TO CURRENT ROW` shorthand frame.
    pub fn rangeFrom(self: @This(), start: WindowBound) @This() {
        return self.frameBetween(.range, start, .currentRow);
    }

    /// `GROUPS start TO CURRENT ROW` shorthand frame.
    pub fn groupsFrom(self: @This(), start: WindowBound) @This() {
        return self.frameBetween(.groups, start, .currentRow);
    }

    fn excludeMode(self: @This(), mode: WindowExclude) @This() {
        var copy = self;
        if (copy.frame) |*spec| {
            spec.exclude = mode;
        } else @panic("exclude() needs a frame: call rowsBetween/rangeBetween/groupsBetween first");
        return copy;
    }

    /// `EXCLUDE CURRENT ROW`: drop just the current row from the frame.
    pub fn excludeCurrentRow(self: @This()) @This() {
        return self.excludeMode(.currentRow);
    }

    /// `EXCLUDE GROUP`: drop the current row plus its peers.
    pub fn excludeGroup(self: @This()) @This() {
        return self.excludeMode(.group);
    }

    /// `EXCLUDE TIES`: drop peers but keep the current row.
    pub fn excludeTies(self: @This()) @This() {
        return self.excludeMode(.ties);
    }

    /// `EXCLUDE NO OTHERS`: keep everything (the default, explicit).
    pub fn excludeNoOthers(self: @This()) @This() {
        return self.excludeMode(.none);
    }

    /// `FILTER (WHERE cond)` on an aggregate window; panics for
    /// non-aggregates at build time (the engine rejects them anyway).
    pub fn filter(self: @This(), cond: dslExpr.Expr) @This() {
        var copy = self;
        copy.filterExpr = cond;
        return copy;
    }

    /// `DISTINCT` argument for aggregate windows (`sum(DISTINCT x) OVER ...`).
    pub fn distinctArg(self: @This()) @This() {
        var copy = self;
        copy.distinct = true;
        return copy;
    }
};

/// `row_number() OVER (...)` window handle.
pub fn rowNumber() WindowBuilder {
    return .{ .func = "row_number" };
}

/// `rank() OVER (...)` window handle.
pub fn rank() WindowBuilder {
    return .{ .func = "rank" };
}

/// `dense_rank() OVER (...)` window handle.
pub fn denseRank() WindowBuilder {
    return .{ .func = "dense_rank" };
}

/// `percent_rank() OVER (...)` window handle.
pub fn percentRank() WindowBuilder {
    return .{ .func = "percent_rank" };
}

/// `cume_dist() OVER (...)` window handle.
pub fn cumeDist() WindowBuilder {
    return .{ .func = "cume_dist" };
}

/// `ntile(buckets) OVER (...)` window handle.
pub fn ntile(buckets: i64) WindowBuilder {
    return .{ .func = "ntile", .argInt = buckets, .hasArgInt = true };
}

/// `lag(col) OVER (...)` handle; chain `.offset(n).defaultValue(v)`.
pub fn lag(col: anytype) WindowBuilder {
    return WindowBuilder.withArg(col, "lag");
}

/// `lead(col) OVER (...)` handle; chain `.offset(n).defaultValue(v)`.
pub fn lead(col: anytype) WindowBuilder {
    return WindowBuilder.withArg(col, "lead");
}

/// `first_value(col) OVER (...)` handle.
pub fn firstValue(col: anytype) WindowBuilder {
    return WindowBuilder.withArg(col, "first_value");
}

/// `last_value(col) OVER (...)` handle.
pub fn lastValue(col: anytype) WindowBuilder {
    return WindowBuilder.withArg(col, "last_value");
}

/// `nth_value(col, n) OVER (...)` handle.
pub fn nthValue(col: anytype, n: i64) WindowBuilder {
    var builder = WindowBuilder.withArg(col, "nth_value");
    builder.argInt = n;
    builder.hasArgInt = true;
    return builder;
}

/// `sum(col) OVER (...)` aggregate window handle.
pub fn sum(col: anytype) WindowBuilder {
    return WindowBuilder.withArg(col, "sum");
}

/// `avg(col) OVER (...)` aggregate window handle.
pub fn avg(col: anytype) WindowBuilder {
    return WindowBuilder.withArg(col, "avg");
}

/// `min(col) OVER (...)` aggregate window handle.
pub fn min(col: anytype) WindowBuilder {
    return WindowBuilder.withArg(col, "min");
}

/// `max(col) OVER (...)` aggregate window handle.
pub fn max(col: anytype) WindowBuilder {
    return WindowBuilder.withArg(col, "max");
}

/// `count(col) OVER (...)` aggregate window handle.
pub fn count(col: anytype) WindowBuilder {
    return WindowBuilder.withArg(col, "count");
}

/// `count(*) OVER (...)` aggregate window handle.
pub fn countStar() WindowBuilder {
    return .{ .func = "count" };
}

fn rhsFrom(value: anytype) dslExpr.Rhs {
    const T = @TypeOf(value);
    if (T == DynamicColumn) return .{ .column = dynRef(value) };
    if (comptime isTypedColumn(T)) return .{ .column = .{ .table = T.dslTable, .name = T.dslName } };
    return .{ .value = toValue(value) };
}

fn orderFromRef(ref: ColumnRef, func: ?FuncCall, descending: bool) Order {
    return .{ .column = ref, .descending = descending, .function = func };
}

/// Explicit literal marker for INSERT/UPDATE rows (`User.age.value(3)`).
/// Bypasses `toValue` inference while keeping the borrowed-payload rule.
pub const ExplicitValue = struct {
    value: Value,
    pub const isExplicitValue = true;
};

/// DEFAULT marker for INSERT/UPDATE rows (`User.age.defaultValue()`).
/// The column is omitted from the statement so SQLite applies its default.
pub const ExplicitDefault = struct {
    pub const isExplicitDefault = true;
};

fn checkExplicitValue(comptime FieldType: type, comptime V: type) void {
    if (V == Value) return;
    if (V == @TypeOf(null)) {
        if (@typeInfo(FieldType) != .optional) @compileError("cannot assign NULL to non-nullable column");
        return;
    }
    if (@typeInfo(V) == .optional) {
        // Runtime-checked like the concise path; literal null handled above.
        checkExplicitValueOptional(FieldType, @typeInfo(V).optional.child);
        return;
    }
    const Target = if (@typeInfo(FieldType) == .optional) @typeInfo(FieldType).optional.child else FieldType;
    if (Target == bool) {
        if (V != bool) @compileError("column expects a boolean value");
        return;
    }
    switch (@typeInfo(Target)) {
        .int => {
            if (@typeInfo(V) != .int and @typeInfo(V) != .comptime_int) @compileError("column expects an integer value");
        },
        .float => {
            const vi = @typeInfo(V);
            if (vi != .int and vi != .float and vi != .comptime_int and vi != .comptime_float) @compileError("column expects a numeric value");
        },
        .pointer => |ptr| {
            if (!(ptr.size == .slice and ptr.child == u8)) @compileError("unsupported column type");
            const vi = @typeInfo(V);
            const okSlice = vi == .pointer and vi.pointer.size == .slice and vi.pointer.child == u8;
            const okArray = vi == .pointer and vi.pointer.size == .one and @typeInfo(vi.pointer.child) == .array and @typeInfo(vi.pointer.child).array.child == u8;
            if (!okSlice and !okArray) @compileError("column expects text");
        },
        else => @compileError("unsupported column type"),
    }
}

fn checkExplicitValueOptional(comptime FieldType: type, comptime Child: type) void {
    // An optional value may hold null at runtime; non-nullable columns then
    // fail at execution with a constraint error, matching concise behavior.
    if (Child == @TypeOf(null)) return;
    const Target = if (@typeInfo(FieldType) == .optional) @typeInfo(FieldType).optional.child else FieldType;
    if (Target == bool and Child != bool) @compileError("column expects a boolean value");
    switch (@typeInfo(Target)) {
        .int => {
            if (@typeInfo(Child) != .int and @typeInfo(Child) != .comptime_int and Child != Value) @compileError("column expects an integer value");
        },
        .float => {
            const ci = @typeInfo(Child);
            if (ci != .int and ci != .float and ci != .comptime_int and ci != .comptime_float and Child != Value) @compileError("column expects a numeric value");
        },
        .pointer => {
            const ci = @typeInfo(Child);
            const okSlice = ci == .pointer and ci.pointer.size == .slice and ci.pointer.child == u8;
            const okArray = ci == .pointer and ci.pointer.size == .one and @typeInfo(ci.pointer.child) == .array and @typeInfo(ci.pointer.child).array.child == u8;
            if (!okSlice and !okArray and Child != Value) @compileError("column expects text");
        },
        else => {
            if (Child != Value) @compileError("unsupported column type");
        },
    }
}

fn setOperandOf(value: anytype) dslExpr.SetOperand {
    const T = @TypeOf(value);
    if (comptime isTypedColumn(T)) return .{ .column = .{ .table = T.dslTable, .name = T.dslName } };
    if (T == DynamicColumn) return .{ .column = dynRef(value) };
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "isExplicitValue")) {
        return .{ .literal = value.value };
    }
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "isExplicitDefault")) {
        @compileError("defaultValue() cannot appear inside an arithmetic expression");
    }
    return .{ .literal = toValue(value) };
}

fn checkNumericColumn(comptime FieldType: type) void {
    const Target = if (@typeInfo(FieldType) == .optional) @typeInfo(FieldType).optional.child else FieldType;
    const ti = @typeInfo(Target);
    if (ti != .int and ti != .float and ti != .comptime_int and ti != .comptime_float) @compileError("arithmetic assignment requires a numeric column");
}

fn arithOf(ref: ColumnRef, op: dslExpr.ArithOp, other: anytype) dslExpr.ArithExpr {
    return .{ .op = op, .left = .{ .column = ref }, .right = setOperandOf(other) };
}

/// Typed column descriptor factory. Fields are schema, methods are operations.
pub fn Column(comptime tableName: []const u8, comptime columnName: []const u8, comptime FieldType: type) type {
    return struct {
        const Self = @This();
        pub const isDslColumn = true;
        pub const dslTable = tableName;
        pub const dslName = columnName;
        pub const table = tableName;
        pub const name = columnName;
        pub const fieldType = FieldType;

        func: ?FuncCall = null,

        fn ref(self: Self) ColumnRef {
            _ = self;
            return .{ .table = tableName, .name = columnName };
        }

        fn pred(self: Self, op: Operator, val: anytype) Expr {
            return .{ .column = self.ref(), .operator = op, .rhs = rhsFrom(val), .function = self.func };
        }

        pub fn eq(self: Self, val: anytype) Expr {
            return self.pred(.equal, val);
        }
        pub fn ne(self: Self, val: anytype) Expr {
            return self.pred(.notEqual, val);
        }
        pub fn lt(self: Self, val: anytype) Expr {
            return self.pred(.less, val);
        }
        pub fn lte(self: Self, val: anytype) Expr {
            return self.pred(.lessEqual, val);
        }
        pub fn gt(self: Self, val: anytype) Expr {
            return self.pred(.greater, val);
        }
        pub fn gte(self: Self, val: anytype) Expr {
            return self.pred(.greaterEqual, val);
        }
        pub fn like(self: Self, val: anytype) Expr {
            return self.pred(.like, val);
        }
        pub fn notLike(self: Self, val: anytype) Expr {
            return self.pred(.notLike, val);
        }
        pub fn likeEscape(self: Self, val: anytype, escape: anytype) Expr {
            var expr = self.pred(.like, val);
            expr.escape = toValue(escape);
            return expr;
        }
        pub fn notLikeEscape(self: Self, val: anytype, escape: anytype) Expr {
            var expr = self.pred(.notLike, val);
            expr.escape = toValue(escape);
            return expr;
        }
        pub fn glob(self: Self, val: anytype) Expr {
            return self.pred(.glob, val);
        }
        pub fn notGlob(self: Self, val: anytype) Expr {
            return self.pred(.notGlob, val);
        }
        pub fn regexp(self: Self, val: anytype) Expr {
            return self.pred(.regexp, val);
        }
        pub fn notRegexp(self: Self, val: anytype) Expr {
            return self.pred(.notRegexp, val);
        }
        pub fn matchPattern(self: Self, val: anytype) Expr {
            return self.pred(.match, val);
        }
        pub fn match(self: Self, val: anytype) Expr {
            return self.pred(.match, val);
        }
        pub fn notMatch(self: Self, val: anytype) Expr {
            return self.pred(.notMatch, val);
        }
        pub fn collate(self: Self, comptime collation: []const u8, val: anytype) Expr {
            var expr = self.pred(.equal, val);
            expr.collate = collation;
            return expr;
        }
        pub fn is(self: Self, val: anytype) Expr {
            return self.pred(.isValue, val);
        }
        pub fn isNot(self: Self, val: anytype) Expr {
            return self.pred(.isNotValue, val);
        }
        pub fn isDistinctFrom(self: Self, val: anytype) Expr {
            return self.pred(.isDistinct, val);
        }
        pub fn isNotDistinctFrom(self: Self, val: anytype) Expr {
            return self.pred(.isNotDistinct, val);
        }
        pub fn isNull(self: Self) Expr {
            return .{ .column = self.ref(), .operator = .isNull, .function = self.func };
        }
        pub fn isNotNull(self: Self) Expr {
            return .{ .column = self.ref(), .operator = .isNotNull, .function = self.func };
        }
        pub fn between(self: Self, lo: anytype, hi: anytype) Expr {
            return .{ .column = self.ref(), .operator = .between, .rhs = rhsFrom(lo), .rhs2 = rhsFrom(hi), .function = self.func };
        }
        pub fn notBetween(self: Self, lo: anytype, hi: anytype) Expr {
            return .{ .column = self.ref(), .operator = .notBetween, .rhs = rhsFrom(lo), .rhs2 = rhsFrom(hi), .function = self.func };
        }

        pub fn asc(self: Self) Order {
            return orderFromRef(self.ref(), self.func, false);
        }
        pub fn desc(self: Self) Order {
            return orderFromRef(self.ref(), self.func, true);
        }

        pub fn sum(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "SUM" };
        }
        pub fn avg(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "AVG" };
        }
        pub fn min(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "MIN" };
        }
        pub fn max(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "MAX" };
        }
        pub fn count(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "COUNT" };
        }
        pub fn countDistinct(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "COUNT", .distinct = true };
        }

        fn wrap(self: Self, call: FuncCall) Self {
            var copy = self;
            copy.func = call;
            return copy;
        }
        pub fn lower(self: Self) Self {
            return self.wrap(.{ .name = "LOWER" });
        }
        pub fn upper(self: Self) Self {
            return self.wrap(.{ .name = "UPPER" });
        }
        pub fn trim(self: Self) Self {
            return self.wrap(.{ .name = "TRIM" });
        }
        pub fn ltrim(self: Self) Self {
            return self.wrap(.{ .name = "LTRIM" });
        }
        pub fn rtrim(self: Self) Self {
            return self.wrap(.{ .name = "RTRIM" });
        }
        pub fn length(self: Self) Self {
            return self.wrap(.{ .name = "LENGTH" });
        }
        pub fn abs(self: Self) Self {
            return self.wrap(.{ .name = "ABS" });
        }
        pub fn typeOf(self: Self) Self {
            return self.wrap(.{ .name = "TYPEOF" });
        }
        pub fn round(self: Self, precision: anytype) Self {
            return self.wrap(.{ .name = "ROUND", .argument = toValue(precision), .hasArgument = true });
        }
        pub fn coalesce(self: Self, fallback: anytype) Self {
            return self.wrap(.{ .name = "COALESCE", .argument = toValue(fallback), .hasArgument = true });
        }
        pub fn ifNull(self: Self, fallback: anytype) Self {
            return self.wrap(.{ .name = "IFNULL", .argument = toValue(fallback), .hasArgument = true });
        }
        pub fn instr(self: Self, needle: anytype) Self {
            return self.wrap(.{ .name = "INSTR", .argument = toValue(needle), .hasArgument = true });
        }
        pub fn substr(self: Self, start: anytype, len: anytype) Self {
            return self.wrap(.{ .name = "SUBSTR", .argument = toValue(start), .argument2 = toValue(len), .hasArgument = true, .hasArgument2 = true });
        }
        pub fn replace(self: Self, search: anytype, replacement: anytype) Self {
            return self.wrap(.{ .name = "REPLACE", .argument = toValue(search), .argument2 = toValue(replacement), .hasArgument = true, .hasArgument2 = true });
        }
        pub fn cast(self: Self, comptime target: []const u8) Self {
            return self.wrap(.{ .name = "CAST", .argument = .{ .text = target }, .hasArgument = true });
        }
        pub fn hex(self: Self) Self {
            return self.wrap(.{ .name = "HEX" });
        }
        pub fn quote(self: Self) Self {
            return self.wrap(.{ .name = "QUOTE" });
        }
        pub fn unicode(self: Self) Self {
            return self.wrap(.{ .name = "UNICODE" });
        }
        pub fn char(self: Self, extra: anytype) Self {
            return self.wrap(.{ .name = "CHAR", .argument = toValue(extra), .hasArgument = true });
        }
        pub fn printf(self: Self, arg: anytype) Self {
            return self.wrap(.{ .name = "PRINTF", .argument = toValue(arg), .hasArgument = true });
        }
        pub fn jsonExtract(self: Self, path: anytype) Self {
            return self.wrap(.{ .name = "json_extract", .argument = toValue(path), .hasArgument = true });
        }
        pub fn jsonSet(self: Self, path: anytype, val: anytype) Self {
            return self.wrap(.{ .name = "json_set", .argument = toValue(path), .argument2 = toValue(val), .hasArgument = true, .hasArgument2 = true });
        }

        pub fn projection(self: Self) Projection {
            if (self.func) |call| {
                return .{
                    .kind = .scalar,
                    .column = self.ref(),
                    .function = call.name,
                    .argument = call.argument,
                    .argument2 = call.argument2,
                    .hasArgument = call.hasArgument,
                    .hasArgument2 = call.hasArgument2,
                };
            }
            return .{ .kind = .column, .column = self.ref() };
        }

        pub fn as(self: Self, alias: []const u8) Projection {
            return self.projection().as(alias);
        }

        pub fn value(_: Self, v: anytype) ExplicitValue {
            checkExplicitValue(FieldType, @TypeOf(v));
            return .{ .value = toValue(v) };
        }

        pub fn nullValue(_: Self) ExplicitValue {
            if (@typeInfo(FieldType) != .optional) @compileError("nullValue() requires a nullable (?T) column");
            return .{ .value = .null };
        }

        pub fn defaultValue(_: Self) ExplicitDefault {
            return .{};
        }

        pub fn add(self: Self, other: anytype) dslExpr.ArithExpr {
            checkNumericColumn(FieldType);
            return arithOf(self.ref(), .add, other);
        }
        pub fn sub(self: Self, other: anytype) dslExpr.ArithExpr {
            checkNumericColumn(FieldType);
            return arithOf(self.ref(), .sub, other);
        }
        pub fn mul(self: Self, other: anytype) dslExpr.ArithExpr {
            checkNumericColumn(FieldType);
            return arithOf(self.ref(), .mul, other);
        }
        pub fn div(self: Self, other: anytype) dslExpr.ArithExpr {
            checkNumericColumn(FieldType);
            return arithOf(self.ref(), .div, other);
        }
        pub fn mod(self: Self, other: anytype) dslExpr.ArithExpr {
            checkNumericColumn(FieldType);
            return arithOf(self.ref(), .mod, other);
        }
    };
}

/// Runtime column descriptor. Typeless; `name` may be dotted.
/// All slices borrowed from the caller/table handle.
pub const DynamicColumn = struct {
    name: []const u8,
    schema: []const u8 = "",
    table: []const u8 = "",
    func: ?FuncCall = null,

    fn ref(self: @This()) ColumnRef {
        return dynRef(self);
    }

    fn pred(self: @This(), op: Operator, val: anytype) Expr {
        const T = @TypeOf(val);
        const rhs: dslExpr.Rhs = if (T == DynamicColumn)
            .{ .column = dynRef(val) }
        else if (comptime isTypedColumn(T))
            .{ .column = .{ .table = T.dslTable, .name = T.dslName } }
        else
            .{ .value = toValue(val) };
        return .{ .column = self.ref(), .operator = op, .rhs = rhs, .function = self.func };
    }

    pub fn eq(self: @This(), val: anytype) Expr {
        return self.pred(.equal, val);
    }
    pub fn ne(self: @This(), val: anytype) Expr {
        return self.pred(.notEqual, val);
    }
    pub fn lt(self: @This(), val: anytype) Expr {
        return self.pred(.less, val);
    }
    pub fn lte(self: @This(), val: anytype) Expr {
        return self.pred(.lessEqual, val);
    }
    pub fn gt(self: @This(), val: anytype) Expr {
        return self.pred(.greater, val);
    }
    pub fn gte(self: @This(), val: anytype) Expr {
        return self.pred(.greaterEqual, val);
    }
    pub fn like(self: @This(), val: anytype) Expr {
        return self.pred(.like, val);
    }
    pub fn notLike(self: @This(), val: anytype) Expr {
        return self.pred(.notLike, val);
    }
    pub fn likeEscape(self: @This(), val: anytype, escape: anytype) Expr {
        var expr = self.pred(.like, val);
        expr.escape = toValue(escape);
        return expr;
    }
    pub fn notLikeEscape(self: @This(), val: anytype, escape: anytype) Expr {
        var expr = self.pred(.notLike, val);
        expr.escape = toValue(escape);
        return expr;
    }
    pub fn glob(self: @This(), val: anytype) Expr {
        return self.pred(.glob, val);
    }
    pub fn notGlob(self: @This(), val: anytype) Expr {
        return self.pred(.notGlob, val);
    }
    pub fn regexp(self: @This(), val: anytype) Expr {
        return self.pred(.regexp, val);
    }
    pub fn notRegexp(self: @This(), val: anytype) Expr {
        return self.pred(.notRegexp, val);
    }
    pub fn matchPattern(self: @This(), val: anytype) Expr {
        return self.pred(.match, val);
    }
    pub fn match(self: @This(), val: anytype) Expr {
        return self.pred(.match, val);
    }
    pub fn notMatch(self: @This(), val: anytype) Expr {
        return self.pred(.notMatch, val);
    }
    pub fn collate(self: @This(), comptime collationName: []const u8, val: anytype) Expr {
        var expr = self.pred(.equal, val);
        expr.collate = collationName;
        return expr;
    }
    pub fn is(self: @This(), val: anytype) Expr {
        return self.pred(.isValue, val);
    }
    pub fn isNot(self: @This(), val: anytype) Expr {
        return self.pred(.isNotValue, val);
    }
    pub fn isDistinctFrom(self: @This(), val: anytype) Expr {
        return self.pred(.isDistinct, val);
    }
    pub fn isNotDistinctFrom(self: @This(), val: anytype) Expr {
        return self.pred(.isNotDistinct, val);
    }
    pub fn isNull(self: @This()) Expr {
        return .{ .column = self.ref(), .operator = .isNull, .function = self.func };
    }
    pub fn isNotNull(self: @This()) Expr {
        return .{ .column = self.ref(), .operator = .isNotNull, .function = self.func };
    }
    pub fn between(self: @This(), lo: anytype, hi: anytype) Expr {
        return .{
            .column = self.ref(),
            .operator = .between,
            .rhs = rhsFrom(lo),
            .rhs2 = rhsFrom(hi),
            .function = self.func,
        };
    }
    pub fn notBetween(self: @This(), lo: anytype, hi: anytype) Expr {
        return .{
            .column = self.ref(),
            .operator = .notBetween,
            .rhs = rhsFrom(lo),
            .rhs2 = rhsFrom(hi),
            .function = self.func,
        };
    }

    pub fn asc(self: @This()) Order {
        return orderFromRef(self.ref(), self.func, false);
    }
    pub fn desc(self: @This()) Order {
        return orderFromRef(self.ref(), self.func, true);
    }

    pub fn sum(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "SUM" };
    }
    pub fn avg(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "AVG" };
    }
    pub fn min(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "MIN" };
    }
    pub fn max(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "MAX" };
    }
    pub fn count(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "COUNT" };
    }
    pub fn countDistinct(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "COUNT", .distinct = true };
    }

    fn wrap(self: @This(), call: FuncCall) @This() {
        var copy = self;
        copy.func = call;
        return copy;
    }
    pub fn lower(self: @This()) @This() {
        return self.wrap(.{ .name = "LOWER" });
    }
    pub fn upper(self: @This()) @This() {
        return self.wrap(.{ .name = "UPPER" });
    }
    pub fn trim(self: @This()) @This() {
        return self.wrap(.{ .name = "TRIM" });
    }
    pub fn ltrim(self: @This()) @This() {
        return self.wrap(.{ .name = "LTRIM" });
    }
    pub fn rtrim(self: @This()) @This() {
        return self.wrap(.{ .name = "RTRIM" });
    }
    pub fn length(self: @This()) @This() {
        return self.wrap(.{ .name = "LENGTH" });
    }
    pub fn abs(self: @This()) @This() {
        return self.wrap(.{ .name = "ABS" });
    }
    pub fn typeOf(self: @This()) @This() {
        return self.wrap(.{ .name = "TYPEOF" });
    }
    pub fn round(self: @This(), precision: anytype) @This() {
        return self.wrap(.{ .name = "ROUND", .argument = toValue(precision), .hasArgument = true });
    }
    pub fn coalesce(self: @This(), fallback: anytype) @This() {
        return self.wrap(.{ .name = "COALESCE", .argument = toValue(fallback), .hasArgument = true });
    }
    pub fn ifNull(self: @This(), fallback: anytype) @This() {
        return self.wrap(.{ .name = "IFNULL", .argument = toValue(fallback), .hasArgument = true });
    }
    pub fn instr(self: @This(), needle: anytype) @This() {
        return self.wrap(.{ .name = "INSTR", .argument = toValue(needle), .hasArgument = true });
    }
    pub fn substr(self: @This(), start: anytype, len: anytype) @This() {
        return self.wrap(.{ .name = "SUBSTR", .argument = toValue(start), .argument2 = toValue(len), .hasArgument = true, .hasArgument2 = true });
    }
    pub fn replace(self: @This(), search: anytype, replacement: anytype) @This() {
        return self.wrap(.{ .name = "REPLACE", .argument = toValue(search), .argument2 = toValue(replacement), .hasArgument = true, .hasArgument2 = true });
    }
    pub fn cast(self: @This(), target: []const u8) @This() {
        return self.wrap(.{ .name = "CAST", .argument = .{ .text = target }, .hasArgument = true });
    }
    pub fn hex(self: @This()) @This() {
        return self.wrap(.{ .name = "HEX" });
    }
    pub fn quote(self: @This()) @This() {
        return self.wrap(.{ .name = "QUOTE" });
    }
    pub fn unicode(self: @This()) @This() {
        return self.wrap(.{ .name = "UNICODE" });
    }
    pub fn char(self: @This(), extra: anytype) @This() {
        return self.wrap(.{ .name = "CHAR", .argument = toValue(extra), .hasArgument = true });
    }
    pub fn printf(self: @This(), arg: anytype) @This() {
        return self.wrap(.{ .name = "PRINTF", .argument = toValue(arg), .hasArgument = true });
    }
    pub fn jsonExtract(self: @This(), path: anytype) @This() {
        return self.wrap(.{ .name = "json_extract", .argument = toValue(path), .hasArgument = true });
    }
    pub fn jsonSet(self: @This(), path: anytype, val: anytype) @This() {
        return self.wrap(.{ .name = "json_set", .argument = toValue(path), .argument2 = toValue(val), .hasArgument = true, .hasArgument2 = true });
    }

    pub fn projection(self: @This()) Projection {
        if (self.func) |call| {
            return .{
                .kind = .scalar,
                .column = self.ref(),
                .function = call.name,
                .argument = call.argument,
                .argument2 = call.argument2,
                .hasArgument = call.hasArgument,
                .hasArgument2 = call.hasArgument2,
            };
        }
        return .{ .kind = .column, .column = self.ref() };
    }

    pub fn as(self: @This(), alias: []const u8) Projection {
        return self.projection().as(alias);
    }

    pub fn value(_: @This(), v: anytype) ExplicitValue {
        return .{ .value = toValue(v) };
    }

    pub fn nullValue(_: @This()) ExplicitValue {
        return .{ .value = .null };
    }

    pub fn defaultValue(_: @This()) ExplicitDefault {
        return .{};
    }

    pub fn add(self: @This(), other: anytype) dslExpr.ArithExpr {
        return arithOf(self.ref(), .add, other);
    }
    pub fn sub(self: @This(), other: anytype) dslExpr.ArithExpr {
        return arithOf(self.ref(), .sub, other);
    }
    pub fn mul(self: @This(), other: anytype) dslExpr.ArithExpr {
        return arithOf(self.ref(), .mul, other);
    }
    pub fn div(self: @This(), other: anytype) dslExpr.ArithExpr {
        return arithOf(self.ref(), .div, other);
    }
    pub fn mod(self: @This(), other: anytype) dslExpr.ArithExpr {
        return arithOf(self.ref(), .mod, other);
    }
};

/// `excluded.*` pseudo-table descriptor for UPSERT `doUpdate` assignments.
/// Predicates here address the proposed insertion row. Borrowed name.
pub const ExcludedColumn = struct {
    name: []const u8,

    fn ref(self: @This()) dslExpr.ColumnRef {
        return .{ .table = "excluded", .name = self.name };
    }

    fn pred(self: @This(), op: Operator, value: anytype) Expr {
        return .{ .column = self.ref(), .operator = op, .rhs = rhsFrom(value) };
    }

    pub fn eq(self: @This(), value: anytype) Expr {
        return self.pred(.equal, value);
    }
    pub fn ne(self: @This(), value: anytype) Expr {
        return self.pred(.notEqual, value);
    }
    pub fn lt(self: @This(), value: anytype) Expr {
        return self.pred(.less, value);
    }
    pub fn lte(self: @This(), value: anytype) Expr {
        return self.pred(.lessEqual, value);
    }
    pub fn gt(self: @This(), value: anytype) Expr {
        return self.pred(.greater, value);
    }
    pub fn gte(self: @This(), value: anytype) Expr {
        return self.pred(.greaterEqual, value);
    }
    pub fn like(self: @This(), value: anytype) Expr {
        return self.pred(.like, value);
    }
    pub fn notLike(self: @This(), value: anytype) Expr {
        return self.pred(.notLike, value);
    }
    pub fn glob(self: @This(), value: anytype) Expr {
        return self.pred(.glob, value);
    }
    pub fn notGlob(self: @This(), value: anytype) Expr {
        return self.pred(.notGlob, value);
    }
    pub fn regexp(self: @This(), value: anytype) Expr {
        return self.pred(.regexp, value);
    }
    pub fn notRegexp(self: @This(), value: anytype) Expr {
        return self.pred(.notRegexp, value);
    }
    pub fn matchPattern(self: @This(), value: anytype) Expr {
        return self.pred(.match, value);
    }
    pub fn match(self: @This(), value: anytype) Expr {
        return self.pred(.match, value);
    }
    pub fn notMatch(self: @This(), value: anytype) Expr {
        return self.pred(.notMatch, value);
    }
    pub fn is(self: @This(), value: anytype) Expr {
        return self.pred(.isValue, value);
    }
    pub fn isNot(self: @This(), value: anytype) Expr {
        return self.pred(.isNotValue, value);
    }
    pub fn isDistinctFrom(self: @This(), value: anytype) Expr {
        return self.pred(.isDistinct, value);
    }
    pub fn isNotDistinctFrom(self: @This(), value: anytype) Expr {
        return self.pred(.isNotDistinct, value);
    }
    pub fn isNull(self: @This()) Expr {
        return .{ .column = self.ref(), .operator = .isNull };
    }
    pub fn isNotNull(self: @This()) Expr {
        return .{ .column = self.ref(), .operator = .isNotNull };
    }
    pub fn between(self: @This(), lo: anytype, hi: anytype) Expr {
        return .{
            .column = self.ref(),
            .operator = .between,
            .rhs = rhsFrom(lo),
            .rhs2 = rhsFrom(hi),
        };
    }
    pub fn notBetween(self: @This(), lo: anytype, hi: anytype) Expr {
        return .{
            .column = self.ref(),
            .operator = .notBetween,
            .rhs = rhsFrom(lo),
            .rhs2 = rhsFrom(hi),
        };
    }
};

test "typed predicates carry table identity and bound values" {
    const Age = Column("users", "age", i64);
    const age = Age{};
    const pred = age.gte(18);
    try std.testing.expectEqualStrings("users", pred.column.table);
    try std.testing.expectEqualStrings("age", pred.column.name);
    try std.testing.expect(pred.operator == .greaterEqual);
    try std.testing.expect(pred.rhs.value.integer == 18);
    const Name = Column("users", "name", []const u8);
    const like = (Name{}).like("A%");
    try std.testing.expect(like.operator == .like);
    try std.testing.expectEqualStrings("A%", like.rhs.value.text);
    const nullPred = (Name{}).isNull();
    try std.testing.expect(nullPred.operator == .isNull);
    const range = age.between(1, 9);
    try std.testing.expect(range.operator == .between);
    try std.testing.expect(range.rhs.value.integer == 1);
    try std.testing.expect(range.rhs2.?.value.integer == 9);
}

test "typed predicates compare columns without string lookup" {
    const Uid = Column("users", "id", i64);
    const Oid = Column("orders", "user_id", i64);
    const join = (Uid{}).eq(Oid{});
    try std.testing.expectEqualStrings("users", join.column.table);
    try std.testing.expectEqualStrings("orders", join.rhs.column.table);
    try std.testing.expectEqualStrings("user_id", join.rhs.column.name);
}

test "typed columns build orders aggregates and wrappers" {
    const Age = Column("users", "age", i64);
    const age = Age{};
    const asc = age.asc();
    try std.testing.expect(!asc.descending);
    try std.testing.expectEqualStrings("age", asc.column.name);
    try std.testing.expect(age.desc().descending);
    const total = age.sum();
    try std.testing.expect(total.kind == .aggregate);
    try std.testing.expectEqualStrings("SUM", total.function);
    try std.testing.expectEqualStrings("users", total.column.table);
    const lowered = (Column("users", "name", []const u8){}).lower();
    const lp = lowered.projection();
    try std.testing.expect(lp.kind == .scalar);
    try std.testing.expectEqualStrings("LOWER", lp.function);
    const plain = age.projection();
    try std.testing.expect(plain.kind == .column);
}

test "dynamic predicates mirror typed predicates at runtime" {
    const age = DynamicColumn{ .name = "users.age" };
    const pred = age.gte(18);
    try std.testing.expectEqualStrings("users", pred.column.table);
    try std.testing.expectEqualStrings("age", pred.column.name);
    try std.testing.expect(pred.rhs.value.integer == 18);
    const cross = (DynamicColumn{ .name = "a" }).eq(DynamicColumn{ .name = "b.c" });
    try std.testing.expectEqualStrings("b", cross.rhs.column.table);
    try std.testing.expectEqualStrings("c", cross.rhs.column.name);
    try std.testing.expectEqualStrings("age", splitRef("age").name);
    try std.testing.expect(splitRef("age").table.len == 0);
    const missing = (DynamicColumn{ .name = "x" }).isNotNull();
    try std.testing.expect(missing.operator == .isNotNull);
}

test "excluded columns address the proposed upsert row" {
    const label = ExcludedColumn{ .name = "label" };
    const pred = label.eq("alpha");
    try std.testing.expectEqualStrings("excluded", pred.column.table);
    try std.testing.expectEqualStrings("label", pred.column.name);
    try std.testing.expect(pred.operator == .equal);
    try std.testing.expectEqualStrings("alpha", pred.rhs.value.text);
    const range = (ExcludedColumn{ .name = "stock" }).between(1, 9);
    try std.testing.expect(range.operator == .between);
    try std.testing.expect((ExcludedColumn{ .name = "x" }).isNull().operator == .isNull);
}

test "operation-named typed columns stay usable as fields" {
    // Collision rule: `all`/`count`/`select`/`where`/`join`/`limit` are plain
    // fields when the schema declares them; operations are calls on values.
    const All = Column("t", "all", []const u8);
    const Count = Column("t", "count", i64);
    const Select = Column("t", "select", []const u8);
    const Where = Column("t", "where", []const u8);
    const Join = Column("t", "join", []const u8);
    const Limit = Column("t", "limit", i64);
    try std.testing.expectEqualStrings("all", (All{}).projection().column.name);
    try std.testing.expectEqualStrings("COUNT", (Count{}).count().function);
    try std.testing.expect((Select{}).eq("x").operator == .equal);
    try std.testing.expectEqualStrings("where", (Where{}).like("a%").column.name);
    try std.testing.expect((Join{}).isNotNull().operator == .isNotNull);
    try std.testing.expect((Limit{}).desc().descending);
    try std.testing.expectEqualStrings("limit", (Limit{}).desc().column.name);
    // Dynamic side mirrors it: dotted names keep table identity.
    const dyn = DynamicColumn{ .name = "t.where" };
    try std.testing.expectEqualStrings("where", dynRef(dyn).name);
    try std.testing.expectEqualStrings("t", dynRef(dyn).table);
    // CASE base accepts an operation-named column without ambiguity.
    const builder = caseValue(Where{});
    try std.testing.expectEqualStrings("where", builder.base.?.name);
}
