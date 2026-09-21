//! Query/mutation builders: value-semantic DSL over the native AST.
//!
//! Purpose: provide the typed (`db.from(User)`) and dynamic
//! (`db.table("users")`) builders that accumulate borrowed SELECT / INSERT /
//! UPDATE / DELETE / UPSERT state and, on `fetch()`/`execute()`/`insert()`,
//! lower snapshots through `ast_builder` into native `sql/ast.zig` statements
//! run by the connection's executor hooks. Builders never render SQL strings.
//!
//! Responsibilities: projection/condition/order/limit/offset/group/having/join
//! accumulation, CTE staging, compound (UNION/INTERSECT/EXCEPT) arms, derived
//! tables, typed row mapping (`MappedResult`), and mutation execution.
//!
//! Dependencies: `dsl/expr.zig`, `dsl/column.zig`, `dsl/table.zig`,
//! `dsl/ast_builder.zig`, `sql/ast.zig`, `vm/value.zig`,
//! `connection/result.zig`.
//!
//! Ownership/lifetime (critical): builders are small copyable values; every
//! chaining call returns a *copy*, so the original remains usable. Builders
//! borrow table/column/alias strings and hold fixed-capacity inline buffers
//! (32 projections, 16 conditions, 8 orders/CTEs, ...); exceeding a buffer is
//! a `@panic`. `fetch()` returns an *owned* `Result` (or owned `MappedResult`
//! rows) that the caller must `deinit` — the `Result` duplicates every text/
//! blob payload and column name. `fetchOne`/`fetchOptional` duplicate the
//! single value/row the same way. Mapped rows (`MappedResult.rows`) duplicate
//! text payloads per row; call `deinit()` (or `freeRow`) exactly once. AST
//! snapshots are by-value copies taken at fetch time; later builder mutation
//! never affects an in-flight query. Executor hooks borrow the connection;
//! the connection must outlive every builder and every outstanding `Result`.
//!
//! Error behavior: builder chaining panics on capacity misuse (`too many DSL
//! projections/predicates/orders/CTEs`, empty `select()`/`orderBy()`) and
//! compile-errors on type misuse (`select()` with orders, `having()` with a
//! non-comparison, compound arms from non-builders). Execution returns engine
//! errors (`UnknownColumn`, `InvalidSql`, `NoRows`, `TooManyRows`, I/O, ...).
//!
//! SQLite compatibility: inherits the engine's. `having()` accepts either a
//! `HavingCond` (`col.count().gt(1)`) or a plain column predicate lowered to
//! the same shape; unsupported shapes mark the snapshot invalid so
//! `ast_builder` fails with `InvalidSql` instead of mis-executing.
//!
//! Unified pipeline note: Raw SQL, the dynamic DSL, and the typed DSL all
//! converge on native AST/IR via `ast_builder.buildSelect`/`buildInsert`/
//! `buildUpdate`/`buildDelete` — builders never emit SQL text for re-parsing.
//!
//! Column/operation collision rule: `select()` takes column *values*
//! (`User.where`, `t.column("count")`) or their aggregate/projection calls;
//! passing the `all` *operation itself* (`User.all` without calling) is a
//! `@compileError` directing to `User.all()` or `selectAll()`. Columns named
//! `select`/`where`/`limit`/`count` therefore flow through as ordinary fields.
//!
//! AllColumns note: `AllProjection` (from `User.all()`) routes `select()` to
//! `selectAll()`, which lowers to the native `.wildcard` (`*`) node.
//! `QualifiedAllColumns` ordering (e.g. `table.*` in joins) is preserved by
//! `ast_builder`: join queries keep full qualification while single-table
//! `selectAll()` renders the historical bare `*`.

const std = @import("std");
const dslExpr = @import("expr.zig");
const Expr = dslExpr.Expr;
const Order = dslExpr.Order;
const Projection = dslExpr.Projection;
const ColumnRef = dslExpr.ColumnRef;
const Value = @import("../vm/value.zig").Value;
const columnMod = @import("column.zig");
const CaseBuilder = columnMod.CaseBuilder;
const WindowBuilder = columnMod.WindowBuilder;
const astBuilder = @import("ast_builder.zig");
const ast = @import("../sql/ast.zig");
const Result = @import("../connection/result.zig").Result;

const tableMod = @import("table.zig");

/// Typed SELECT builder for a `sqlite.table(...)` value type. Compile-errors
/// on non-table inputs (use `db.table("name")` for runtime tables).
pub fn Query(comptime TableValueType: type) type {
    if (!tableMod.isTableValue(TableValueType)) @compileError("db.from() takes a typed table value from sqlite.table(...); use db.table(\"name\") for runtime/dynamic tables");
    return Builder(tableMod.rowTypeOfValue(TableValueType), tableMod.columnsTypeOfValue(TableValueType), true);
}

/// Untyped SELECT builder for runtime tables. See `Builder(void, void, false)`.
pub const DynamicQuery = Builder(void, void, false);

const ConditionEntry = astBuilder.CondEntry;

const JoinKind = astBuilder.JoinKind;

const InQuery = astBuilder.InQueryArgs;

const ExistsQuery = astBuilder.ExistsQueryArgs;

const LiteralIn = struct {
    column: ColumnRef,
    values: [32]Value = undefined,
    count: usize = 0,
    negated: bool = false,
};

const Cte = struct {
    name: []const u8,
    base: []const u8,
    recursive: ?[]const u8 = null,
};

fn isTypedColumnInstance(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "isDslColumn") and T.isDslColumn;
}

fn toProjection(item: anytype) Projection {
    const T = @TypeOf(item);
    if (T == Projection) return item;
    if (T == columnMod.DynamicColumn) return item.projection();
    if (T == tableMod.AllProjection) return .{ .kind = .star };
    if (T == dslExpr.Order) @compileError("select() takes columns, not orders; pass col.asc()/col.desc() to orderBy()");
    if (comptime isTypedColumnInstance(T)) return item.projection();
    @compileError("select() takes column descriptors (User.id / table.column(\"x\")) or their aggregates");
}

fn toRef(item: anytype) ColumnRef {
    const T = @TypeOf(item);
    if (T == columnMod.DynamicColumn) return columnMod.dynRef(item);
    if (comptime isTypedColumnInstance(T)) return .{ .table = T.dslTable, .name = T.dslName };
    @compileError("expected a column descriptor (User.id or table.column(\"x\"))");
}

fn toOrder(item: anytype) Order {
    const T = @TypeOf(item);
    if (T == Order) return item;
    if (T == columnMod.DynamicColumn) return .{ .column = columnMod.dynRef(item) };
    if (comptime isTypedColumnInstance(T)) return .{ .column = .{ .table = T.dslTable, .name = T.dslName } };
    @compileError("orderBy() takes a column order such as col.asc()/col.desc() or a bare column for ascending order");
}

fn destSqlFor(comptime Columns: type, want: []const u8) ?[]const u8 {
    inline for (@typeInfo(Columns).@"struct".fields) |colField| {
        if (std.mem.eql(u8, colField.name, want)) return colField.type.dslName;
    }
    return null;
}

fn insertFieldOf(value: anytype) Value {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "isExplicitValue")) {
        return value.value;
    }
    return columnMod.toValue(value);
}

fn isExplicitDefault(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "isExplicitDefault");
}
fn setValueOf(value: anytype) dslExpr.SetValue {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "isExplicitValue")) {
        return .{ .literal = value.value };
    }
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "isArithExpr")) {
        return value.toSetValue();
    }
    if (T == columnMod.DynamicColumn) return .{ .column = columnMod.dynRef(value) };
    if (comptime isTypedColumnInstance(T)) return .{ .column = .{ .table = T.dslTable, .name = T.dslName } };
    return .{ .literal = columnMod.toValue(value) };
}

/// Borrowed table name of a join target (typed value, type, string, or
/// `DynamicTable`). Returned slice is borrowed from the target.
pub fn tableNameOf(other: anytype) []const u8 {
    const T = @TypeOf(other);
    if (comptime @import("table.zig").isTableValue(T)) return other.tableName;
    if (T == type) {
        if (!@hasDecl(other, "tableName")) @compileError("join target must be a typed table or a table-name string");
        return other.tableName;
    }
    return other;
}

/// Borrowed join target identity: name plus optional schema/alias.
pub const JoinTarget = struct { name: []const u8, schema: []const u8 = "", alias: ?[]const u8 = null };

/// Resolve a join target value into a borrowed `JoinTarget`. Accepts typed
/// table values, `DynamicTable`s, table types, and plain name strings.
pub fn joinTargetOf(other: anytype) JoinTarget {
    const T = @TypeOf(other);
    if (comptime T != type and @typeInfo(T) == .@"struct" and @hasDecl(T, "isDynamicTable")) {
        return .{ .name = other.name, .schema = other.schema, .alias = if (other.alias.len != 0) other.alias else null };
    }
    if (comptime @import("table.zig").isTableValue(T)) {
        return .{ .name = other.tableName, .alias = if (other.tableAlias.len != 0) other.tableAlias else null };
    }
    return .{ .name = tableNameOf(other) };
}

fn containsAllMarker(comptime T: type) bool {
    if (T == tableMod.AllProjection) return true;
    const info = @typeInfo(T);
    if (info == .pointer) return containsAllMarker(info.pointer.child);
    if (info == .array) return containsAllMarker(info.array.child);
    if (info == .@"struct" and info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |field| {
            if (containsAllMarker(field.type)) return true;
        }
    }
    return false;
}

/// Builder type returned by `select(cols)`: mapped (`selectAll`/star present)
/// when `T` contains an `AllProjection` marker, unmapped otherwise.
pub fn SelectOut(comptime Row: type, comptime Columns: type, comptime T: type) type {
    if (containsAllMarker(T)) return Builder(Row, Columns, true);
    return Builder(Row, Columns, false);
}

fn havingCondFromExpr(pred: dslExpr.Expr) ?dslExpr.HavingCond {
    if (pred.escape != null or pred.collate != null) return null;
    if (pred.rhs2 != null) return null;
    const rhs: Value = switch (pred.rhs) {
        .value => |v| v,
        .column => return null,
    };
    const proj: dslExpr.Projection = if (pred.function) |call| .{
        .kind = .scalar,
        .column = pred.column,
        .function = call.name,
        .argument = call.argument,
        .argument2 = call.argument2,
        .hasArgument = call.hasArgument,
        .hasArgument2 = call.hasArgument2,
    } else .{
        .kind = .column,
        .column = pred.column,
    };
    return .{ .proj = proj, .op = pred.operator.sql(), .rhs = rhs };
}

fn storeCaseProjection(cases: *[2]CaseBuilder, caseCount: *usize, out: []Projection, outCount: *usize, item: CaseBuilder) void {
    if (caseCount.* >= cases.len) @panic("too many DSL case expressions");
    if (outCount.* >= out.len) @panic("too many DSL projections");
    cases[caseCount.*] = item;
    out[outCount.*] = .{ .kind = .caseExpr, .caseSlot = @intCast(caseCount.*) };
    caseCount.* += 1;
    outCount.* += 1;
}

fn storeWindowProjection(windows: []WindowBuilder, windowCount: *usize, out: []Projection, outCount: *usize, item: WindowBuilder) void {
    if (windowCount.* >= windows.len) @panic("too many DSL window expressions");
    if (outCount.* >= out.len) @panic("too many DSL projections");
    windows[windowCount.*] = item;
    out[outCount.*] = .{ .kind = .window, .windowSlot = @intCast(windowCount.*) };
    windowCount.* += 1;
    outCount.* += 1;
}

/// Value-semantic query builder. `Row == void` means dynamic/untyped;
/// otherwise rows map to `Row` via `Columns`. `mapped` selects star (`*`)
/// versus explicit-projection mode. All chaining methods return copies;
/// fixed buffers panic on overflow; execution methods return owned results.
/// See the module docs for the full ownership/lifetime contract.
pub fn Builder(comptime Row: type, comptime Columns: type, comptime mapped: bool) type {
    return struct {
        const Self = @This();
        /// True for typed builders (`Row != void`); dynamic builders are untyped.
        pub const isTyped = Row != void;
        /// Row struct the result maps to (or `void` for dynamic).
        pub const rowType = Row;
        /// Columns descriptor struct (or `void` for dynamic).
        pub const columnsType = Columns;
        /// True when star mode AND typed, i.e. `fetch()` maps rows.
        pub const isMapped = mapped and isTyped;

        /// Borrowed allocator used for snapshots and owned results.
        allocator: std.mem.Allocator,
        /// Borrowed opaque live connection; must outlive builder and results.
        connection: *anyopaque,
        /// Borrowed single-statement executor hook.
        executeFn: astBuilder.ExecFn,
        /// Borrowed compound executor hook.
        compoundExecuteFn: astBuilder.CompoundExecFn,
        /// Borrowed derived-table executor hook.
        derivedExecuteFn: astBuilder.DerivedExecFn,
        /// Borrowed base table name.
        table: []const u8,
        schema: []const u8 = "",
        tableAlias: ?[]const u8 = null,

        allColumns: bool = true,
        projections: [32]Projection = undefined,
        projectionCount: usize = 0,
        distinctValue: bool = false,
        cases: [2]CaseBuilder = undefined,
        caseCount: usize = 0,
        windows: [4]WindowBuilder = undefined,
        windowCount: usize = 0,
        returningCols: [16]Projection = undefined,
        returningCount: usize = 0,

        conditions: [16]ConditionEntry = undefined,
        conditionCount: usize = 0,
        caseWhens: [2]astBuilder.CaseWhereArgs = undefined,
        caseWhenCount: usize = 0,

        orders: [8]Order = undefined,
        orderCount: usize = 0,
        limitValue: ?usize = null,
        offsetValue: ?usize = null,
        groupByColumn: ?ColumnRef = null,
        havingCond: ?dslExpr.HavingCond = null,
        havingValid: bool = true,

        joinTable: ?[]const u8 = null,
        joinSchema: []const u8 = "",
        joinAlias: ?[]const u8 = null,
        joinKind: JoinKind = .inner,
        joinOn: ?Expr = null,
        joinUsingCols: [8][]const u8 = undefined,
        joinUsingCount: usize = 0,
        joinNatural: bool = false,

        inQuery: ?InQuery = null,
        existsQuery: ?ExistsQuery = null,
        literalIn: ?LiteralIn = null,

        ctes: [8]Cte = undefined,
        cteCount: usize = 0,
        cteRecursive: bool = false,
        subquery: ?SubSnapshot = null,

        pub fn init(connection: anytype, table: []const u8, executeFn: astBuilder.ExecFn, compoundExecuteFn: astBuilder.CompoundExecFn, derivedExecuteFn: astBuilder.DerivedExecFn) Self {
            return initRaw(connection.allocator, connection, table, executeFn, compoundExecuteFn, derivedExecuteFn);
        }

        pub fn initRaw(allocator: std.mem.Allocator, connection: *anyopaque, table: []const u8, executeFn: astBuilder.ExecFn, compoundExecuteFn: astBuilder.CompoundExecFn, derivedExecuteFn: astBuilder.DerivedExecFn) Self {
            return .{ .allocator = allocator, .connection = connection, .executeFn = executeFn, .compoundExecuteFn = compoundExecuteFn, .derivedExecuteFn = derivedExecuteFn, .table = table };
        }

        pub fn with(self: Self, name: []const u8, body: []const u8) Self {
            var copy = self;
            if (copy.cteCount >= copy.ctes.len) @panic("too many CTEs");
            copy.ctes[copy.cteCount] = .{ .name = name, .base = body };
            copy.cteCount += 1;
            return copy;
        }

        pub fn withRecursive(self: Self, name: []const u8, base: []const u8, recursive: []const u8) Self {
            var copy = self.with(name, base);
            copy.ctes[copy.cteCount - 1].recursive = recursive;
            copy.cteRecursive = true;
            return copy;
        }

        pub fn column(_: Self, name: []const u8) columnMod.DynamicColumn {
            return .{ .name = name };
        }

        fn retype(self: Self, comptime nextMapped: bool) Builder(Row, Columns, nextMapped) {
            return .{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .compoundExecuteFn = self.compoundExecuteFn,
                .derivedExecuteFn = self.derivedExecuteFn,
                .table = self.table,
                .schema = self.schema,
                .tableAlias = self.tableAlias,
                .allColumns = self.allColumns,
                .projections = self.projections,
                .projectionCount = self.projectionCount,
                .distinctValue = self.distinctValue,
                .cases = self.cases,
                .caseCount = self.caseCount,
                .windows = self.windows,
                .windowCount = self.windowCount,
                .returningCols = self.returningCols,
                .returningCount = self.returningCount,
                .conditions = self.conditions,
                .conditionCount = self.conditionCount,
                .caseWhens = self.caseWhens,
                .caseWhenCount = self.caseWhenCount,
                .orders = self.orders,
                .orderCount = self.orderCount,
                .limitValue = self.limitValue,
                .offsetValue = self.offsetValue,
                .groupByColumn = self.groupByColumn,
                .havingCond = self.havingCond,
                .havingValid = self.havingValid,
                .joinTable = self.joinTable,
                .joinSchema = self.joinSchema,
                .joinAlias = self.joinAlias,
                .joinKind = self.joinKind,
                .joinOn = self.joinOn,
                .joinUsingCols = self.joinUsingCols,
                .joinUsingCount = self.joinUsingCount,
                .joinNatural = self.joinNatural,
                .inQuery = self.inQuery,
                .existsQuery = self.existsQuery,
                .literalIn = self.literalIn,
                .ctes = self.ctes,
                .cteCount = self.cteCount,
                .cteRecursive = self.cteRecursive,
                .subquery = self.subquery,
            };
        }

        /// Project explicit columns/projections in order (order preserved into
        /// the native AST). `AllProjection` items route to `selectAll()`.
        /// Passing the `all` operation without calling is a comptime error.
        pub fn select(self: Self, cols: anytype) SelectOut(Row, Columns, @TypeOf(cols)) {
            if (comptime @TypeOf(cols) == tableMod.AllOpFn) @compileError("use User.all() (call it) for the all-columns projection, or db.from(User).selectAll()");
            if (comptime containsAllMarker(@TypeOf(cols))) {
                return self.selectAll();
            }
            var copy = self.retype(false);
            copy.allColumns = false;
            copy.projectionCount = 0;
            copy.caseCount = 0;
            copy.windowCount = 0;
            const T = @TypeOf(cols);
            if (T == Projection or T == columnMod.DynamicColumn or comptime isTypedColumnInstance(T) or T == CaseBuilder or T == WindowBuilder) {
                return copy.selectOne(cols);
            }
            const items = if (@typeInfo(T) == .pointer) cols.* else cols;
            inline for (items) |item| {
                if (@TypeOf(item) == CaseBuilder) {
                    storeCaseProjection(&copy.cases, &copy.caseCount, copy.projections[0..], &copy.projectionCount, item);
                    continue;
                }
                if (@TypeOf(item) == WindowBuilder) {
                    storeWindowProjection(&copy.windows, &copy.windowCount, copy.projections[0..], &copy.projectionCount, item);
                    continue;
                }
                if (copy.projectionCount >= copy.projections.len) @panic("too many DSL projections");
                copy.projections[copy.projectionCount] = toProjection(item);
                copy.projectionCount += 1;
            }
            if (copy.projectionCount == 0) @panic("select() requires at least one column");
            return copy;
        }

        fn selectOne(self: Builder(Row, Columns, false), col: anytype) Builder(Row, Columns, false) {
            var copy = self;
            if (@TypeOf(col) == CaseBuilder) {
                storeCaseProjection(&copy.cases, &copy.caseCount, copy.projections[0..], &copy.projectionCount, col);
                return copy;
            }
            if (@TypeOf(col) == WindowBuilder) {
                storeWindowProjection(&copy.windows, &copy.windowCount, copy.projections[0..], &copy.projectionCount, col);
                return copy;
            }
            copy.projections[copy.projectionCount] = toProjection(col);
            copy.projectionCount += 1;
            return copy;
        }

        /// Project native `*` (all columns, declaration order). Mapped builders
        /// return mapped rows from `fetch()`; unmapped builders return `Result`.
        pub fn selectAll(self: Self) Builder(Row, Columns, true) {
            var copy = self.retype(true);
            copy.allColumns = true;
            copy.projectionCount = 0;
            return copy;
        }

        pub fn distinct(self: Self) Self {
            var copy = self;
            copy.distinctValue = true;
            return copy;
        }

        pub fn returning(self: Self, cols: anytype) Self {
            if (comptime @TypeOf(cols) == tableMod.AllOpFn) @compileError("use User.all() (call it) for RETURNING all columns");
            var copy = self;
            copy.returningCount = 0;
            const items = if (@typeInfo(@TypeOf(cols)) == .pointer) cols.* else cols;
            inline for (items) |item| {
                if (@TypeOf(item) == CaseBuilder) {
                    storeCaseProjection(&copy.cases, &copy.caseCount, copy.returningCols[0..], &copy.returningCount, item);
                    continue;
                }
                if (@TypeOf(item) == WindowBuilder) @panic("window functions are not supported in RETURNING");
                if (copy.returningCount >= copy.returningCols.len) @panic("too many DSL returning columns");
                copy.returningCols[copy.returningCount] = toProjection(item);
                copy.returningCount += 1;
            }
            if (copy.returningCount == 0) @panic("returning() requires at least one column");
            return copy;
        }

        pub fn countStar(self: Self) Builder(Row, Columns, false) {
            var copy = self.retype(false);
            copy.allColumns = false;
            copy.projectionCount = 1;
            copy.projections[0] = dslExpr.countStar();
            return copy;
        }

        pub fn where(self: Self, condition: Expr) Self {
            var copy = self;
            copy.conditions[0] = .{ .expr = condition };
            copy.conditionCount = 1;
            return copy;
        }

        pub fn andWhere(self: Self, condition: Expr) Self {
            var copy = self;
            if (copy.conditionCount >= copy.conditions.len) @panic("too many DSL predicates");
            if (copy.conditionCount == 0) {
                copy.conditions[0] = .{ .expr = condition };
                copy.conditionCount = 1;
                return copy;
            }
            copy.conditions[copy.conditionCount] = .{ .expr = condition, .joinOr = false };
            copy.conditionCount += 1;
            return copy;
        }

        pub fn orWhere(self: Self, condition: Expr) Self {
            var copy = self;
            if (copy.conditionCount >= copy.conditions.len) @panic("too many DSL predicates");
            if (copy.conditionCount == 0) {
                copy.conditions[0] = .{ .expr = condition };
                copy.conditionCount = 1;
                return copy;
            }
            copy.conditions[copy.conditionCount] = .{ .expr = condition, .joinOr = true };
            copy.conditionCount += 1;
            return copy;
        }

        pub fn whereCase(self: Self, case: CaseBuilder, value: anytype) Self {
            var copy = self;
            copy.caseWhens[0] = .{ .case = case, .value = columnMod.toRhs(value) };
            copy.caseWhenCount = 1;
            return copy;
        }

        pub fn andWhereCase(self: Self, case: CaseBuilder, value: anytype) Self {
            var copy = self;
            if (copy.caseWhenCount >= copy.caseWhens.len) @panic("too many DSL case filters");
            copy.caseWhens[copy.caseWhenCount] = .{ .case = case, .value = columnMod.toRhs(value), .joinOr = copy.caseWhenCount != 0 or copy.conditionCount != 0 };
            copy.caseWhenCount += 1;
            return copy;
        }

        pub fn orWhereCase(self: Self, case: CaseBuilder, value: anytype) Self {
            var copy = self;
            if (copy.caseWhenCount >= copy.caseWhens.len) @panic("too many DSL case filters");
            copy.caseWhens[copy.caseWhenCount] = .{ .case = case, .value = columnMod.toRhs(value), .joinOr = true };
            copy.caseWhenCount += 1;
            return copy;
        }

        pub fn whereInValues(self: Self, col: anytype, values: anytype) Self {
            return self.inValues(col, values, false);
        }

        pub fn whereNotInValues(self: Self, col: anytype, values: anytype) Self {
            return self.inValues(col, values, true);
        }

        fn inValues(self: Self, col: anytype, values: anytype, negated: bool) Self {
            var copy = self;
            const items = if (@typeInfo(@TypeOf(values)) == .pointer) values.* else values;
            var entry = LiteralIn{ .column = toRef(col), .negated = negated };
            inline for (items) |item| {
                if (entry.count >= entry.values.len) @panic("DSL IN supports at most 32 literal values");
                entry.values[entry.count] = columnMod.toValue(item);
                entry.count += 1;
            }
            if (entry.count == 0) @panic("IN requires at least one value");
            copy.literalIn = entry;
            return copy;
        }

        pub fn whereInQuery(self: Self, col: anytype, other: anytype, otherCol: anytype) Self {
            var copy = self;
            const target = joinTargetOf(other);
            copy.inQuery = .{ .column = toRef(col), .table = target.name, .schema = target.schema, .subcolumn = toRef(otherCol) };
            return copy;
        }

        pub fn whereNotInQuery(self: Self, col: anytype, other: anytype, otherCol: anytype) Self {
            var copy = self;
            const target = joinTargetOf(other);
            copy.inQuery = .{ .column = toRef(col), .table = target.name, .schema = target.schema, .subcolumn = toRef(otherCol), .negated = true };
            return copy;
        }

        pub fn whereExists(self: Self, other: anytype, on: ?Expr) Self {
            var copy = self;
            const target = joinTargetOf(other);
            copy.existsQuery = .{ .table = target.name, .schema = target.schema, .on = on };
            return copy;
        }

        pub fn whereNotExists(self: Self, other: anytype, on: ?Expr) Self {
            var copy = self;
            const target = joinTargetOf(other);
            copy.existsQuery = .{ .table = target.name, .schema = target.schema, .on = on, .negated = true };
            return copy;
        }

        pub fn orderBy(self: Self, order: anytype) Self {
            var copy = self;
            const T = @TypeOf(order);
            if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
                inline for (order) |item| {
                    if (copy.orderCount >= copy.orders.len) @panic("too many order columns");
                    copy.orders[copy.orderCount] = toOrder(item);
                    copy.orderCount += 1;
                }
                if (copy.orderCount == 0) @panic("orderBy() requires at least one order");
            } else {
                if (copy.orderCount >= copy.orders.len) @panic("too many order columns");
                copy.orders[copy.orderCount] = toOrder(order);
                copy.orderCount += 1;
            }
            return copy;
        }

        pub fn limit(self: Self, amount: usize) Self {
            var copy = self;
            copy.limitValue = amount;
            return copy;
        }

        pub fn offset(self: Self, amount: usize) Self {
            var copy = self;
            copy.offsetValue = amount;
            return copy;
        }

        pub fn groupBy(self: Self, col: anytype) Self {
            var copy = self;
            copy.groupByColumn = toRef(col);
            return copy;
        }

        pub fn having(self: Self, cond: anytype) Self {
            var copy = self;
            const T = @TypeOf(cond);
            if (T == dslExpr.HavingCond) {
                copy.havingCond = cond;
                copy.havingValid = true;
            } else if (T == dslExpr.Expr) {
                copy.havingCond = havingCondFromExpr(cond);
                copy.havingValid = copy.havingCond != null;
            } else {
                @compileError("having() takes an aggregate/scalar comparison such as col.count().gt(1) or a column predicate");
            }
            return copy;
        }

        pub fn innerJoin(self: Self, other: anytype, on: Expr) Self {
            return self.joinAs(other, on, .inner);
        }
        pub fn leftJoin(self: Self, other: anytype, on: Expr) Self {
            return self.joinAs(other, on, .left);
        }
        pub fn rightJoin(self: Self, other: anytype, on: Expr) Self {
            return self.joinAs(other, on, .right);
        }
        pub fn fullJoin(self: Self, other: anytype, on: Expr) Self {
            return self.joinAs(other, on, .full);
        }
        pub fn crossJoin(self: Self, other: anytype) Self {
            var copy = self;
            const target = joinTargetOf(other);
            copy.joinTable = target.name;
            copy.joinSchema = target.schema;
            copy.joinAlias = target.alias;
            copy.joinKind = .cross;
            copy.joinOn = null;
            copy.joinUsingCount = 0;
            copy.joinNatural = false;
            return copy;
        }

        fn joinAs(self: Self, other: anytype, on: Expr, kind: JoinKind) Self {
            var copy = self;
            const target = joinTargetOf(other);
            copy.joinTable = target.name;
            copy.joinSchema = target.schema;
            copy.joinAlias = target.alias;
            copy.joinKind = kind;
            copy.joinOn = on;
            copy.joinUsingCount = 0;
            copy.joinNatural = false;
            return copy;
        }

        pub fn joinUsing(self: Self, other: anytype, col: anytype) Self {
            return self.joinUsingAs(other, col, .inner);
        }
        pub fn leftJoinUsing(self: Self, other: anytype, col: anytype) Self {
            return self.joinUsingAs(other, col, .left);
        }
        pub fn rightJoinUsing(self: Self, other: anytype, col: anytype) Self {
            return self.joinUsingAs(other, col, .right);
        }
        pub fn fullJoinUsing(self: Self, other: anytype, col: anytype) Self {
            return self.joinUsingAs(other, col, .full);
        }

        fn joinUsingAs(self: Self, other: anytype, col: anytype, kind: JoinKind) Self {
            var copy = self;
            const target = joinTargetOf(other);
            copy.joinTable = target.name;
            copy.joinSchema = target.schema;
            copy.joinAlias = target.alias;
            copy.joinKind = kind;
            copy.joinOn = null;
            copy.joinNatural = false;
            copy.joinUsingCount = 0;
            const T = @TypeOf(col);
            if (T == columnMod.DynamicColumn) {
                copy.joinUsingCols[0] = columnMod.dynRef(col).name;
                copy.joinUsingCount = 1;
            } else if (comptime isTypedColumnInstance(T)) {
                copy.joinUsingCols[0] = T.dslName;
                copy.joinUsingCount = 1;
            } else if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
                inline for (col) |item| {
                    if (copy.joinUsingCount >= copy.joinUsingCols.len) @panic("too many USING columns");
                    const IT = @TypeOf(item);
                    if (IT == columnMod.DynamicColumn) {
                        copy.joinUsingCols[copy.joinUsingCount] = columnMod.dynRef(item).name;
                    } else if (comptime isTypedColumnInstance(IT)) {
                        copy.joinUsingCols[copy.joinUsingCount] = IT.dslName;
                    } else {
                        @compileError("joinUsing columns must be column descriptors");
                    }
                    copy.joinUsingCount += 1;
                }
                if (copy.joinUsingCount == 0) @panic("joinUsing requires at least one column");
            } else {
                @compileError("joinUsing column must be a column descriptor or a tuple of column descriptors");
            }
            return copy;
        }

        pub fn naturalJoin(self: Self, other: anytype) Self {
            return self.naturalAs(other, .inner);
        }
        pub fn naturalLeftJoin(self: Self, other: anytype) Self {
            return self.naturalAs(other, .left);
        }
        pub fn naturalRightJoin(self: Self, other: anytype) Self {
            return self.naturalAs(other, .right);
        }
        pub fn naturalFullJoin(self: Self, other: anytype) Self {
            return self.naturalAs(other, .full);
        }

        fn naturalAs(self: Self, other: anytype, kind: JoinKind) Self {
            var copy = self;
            const target = joinTargetOf(other);
            copy.joinTable = target.name;
            copy.joinSchema = target.schema;
            copy.joinAlias = target.alias;
            copy.joinKind = kind;
            copy.joinOn = null;
            copy.joinUsingCount = 0;
            copy.joinNatural = true;
            return copy;
        }

        fn compoundAs(self: Self, other: anytype, op: ast.CompoundOp) CompoundBuilder(Row, Columns, mapped) {
            const Other = @TypeOf(other);
            if (!@hasDecl(Other, "isTyped")) @compileError("compound arm expects a query builder from db.from(...)");
            var combined: CompoundBuilder(Row, Columns, mapped) = .{
                .allocator = self.allocator,
                .connection = self.connection,
                .compoundExecuteFn = self.compoundExecuteFn,
            };
            combined.appendArm(snapshotSelect(self, false), null);
            combined.appendArm(snapshotSelect(other, false), op);
            return combined;
        }

        pub fn unionDistinct(self: Self, other: anytype) CompoundBuilder(Row, Columns, mapped) {
            return self.compoundAs(other, .unionOp);
        }
        pub fn unionAll(self: Self, other: anytype) CompoundBuilder(Row, Columns, mapped) {
            return self.compoundAs(other, .unionAllOp);
        }
        pub fn intersect(self: Self, other: anytype) CompoundBuilder(Row, Columns, mapped) {
            return self.compoundAs(other, .intersectOp);
        }
        pub fn except(self: Self, other: anytype) CompoundBuilder(Row, Columns, mapped) {
            return self.compoundAs(other, .exceptOp);
        }

        pub fn asSubquery(self: *const Self, alias: []const u8) !DynamicQuery {
            if (alias.len == 0) return error.InvalidSql;
            if (self.subquery != null) return error.InvalidSql;
            var out = DynamicQuery{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .compoundExecuteFn = self.compoundExecuteFn,
                .derivedExecuteFn = self.derivedExecuteFn,
                .table = alias,
            };
            out.subquery = snapshotSub(self);
            return out;
        }

        fn validateRow(comptime RowType: type) void {
            if (@typeInfo(RowType) != .@"struct") @compileError("DSL row must be a struct");
            if (isTyped) {
                inline for (@typeInfo(RowType).@"struct".fields) |field| {
                    if (!@hasField(Row, field.name)) @compileError("DSL row contains an unknown table column");
                }
            }
        }

        pub fn insert(self: Self, row: anytype) !Result {
            return self.insertWithMode(row, "");
        }

        pub fn insertOrIgnore(self: Self, row: anytype) !Result {
            return self.insertWithMode(row, "OR IGNORE");
        }

        pub fn insertOrReplace(self: Self, row: anytype) !Result {
            return self.insertWithMode(row, "OR REPLACE");
        }

        pub fn insertOrAbort(self: Self, row: anytype) !Result {
            return self.insertWithMode(row, "OR ABORT");
        }

        pub fn insertOrFail(self: Self, row: anytype) !Result {
            return self.insertWithMode(row, "OR FAIL");
        }

        pub fn insertOrRollback(self: Self, row: anytype) !Result {
            return self.insertWithMode(row, "OR ROLLBACK");
        }

        pub fn insertSelect(self: Self, source: anytype) !Result {
            return self.insertSelectWithMode(source, "");
        }

        pub fn insertFrom(self: Self, source: anytype, mapping: anytype) !Result {
            const MappingType = @TypeOf(mapping);
            if (@typeInfo(MappingType) != .@"struct") @compileError("insertFrom mapping must be a struct of destination-field = source-column pairs");
            const mapFields = @typeInfo(MappingType).@"struct".fields;
            if (mapFields.len == 0) @compileError("insertFrom mapping must name at least one column");
            const SourceT = @TypeOf(source);
            const isDynamicSource = SourceT != type and @typeInfo(SourceT) == .@"struct" and @hasDecl(SourceT, "isDynamicTable");
            if (comptime !isDynamicSource and !@import("table.zig").isTableValue(SourceT)) @compileError("insertFrom source must be a typed table value or a DynamicTable");
            var projs: [mapFields.len]Projection = undefined;
            var count: usize = 0;
            inline for (mapFields) |mapField| {
                const destSql: []const u8 = if (Columns == void)
                    mapField.name
                else
                    destSqlFor(Columns, mapField.name) orelse return error.InvalidSql;
                var proj = toProjection(@field(mapping, mapField.name));
                proj.alias = destSql;
                projs[count] = proj;
                count += 1;
            }
            if (isDynamicSource) {
                var srcQuery = DynamicQuery.initRaw(self.allocator, self.connection, source.name, self.executeFn, self.compoundExecuteFn, self.derivedExecuteFn);
                srcQuery.schema = source.schema;
                return self.insertSelect(srcQuery.select(projs));
            }
            var srcQuery = Query(SourceT).initRaw(self.allocator, self.connection, source.tableName, self.executeFn, self.compoundExecuteFn, self.derivedExecuteFn);
            return self.insertSelect(srcQuery.select(projs));
        }

        pub fn insertSelectOrIgnore(self: Self, source: anytype) !Result {
            return self.insertSelectWithMode(source, "OR IGNORE");
        }

        pub fn insertSelectOrReplace(self: Self, source: anytype) !Result {
            return self.insertSelectWithMode(source, "OR REPLACE");
        }

        pub fn insertSelectOrAbort(self: Self, source: anytype) !Result {
            return self.insertSelectWithMode(source, "OR ABORT");
        }

        pub fn insertSelectOrFail(self: Self, source: anytype) !Result {
            return self.insertSelectWithMode(source, "OR FAIL");
        }

        pub fn insertSelectOrRollback(self: Self, source: anytype) !Result {
            return self.insertSelectWithMode(source, "OR ROLLBACK");
        }

        fn insertSelectWithMode(self: Self, source: anytype, comptime mode: []const u8) !Result {
            const conflict: ast.ConflictPolicy = if (comptime std.mem.eql(u8, mode, "")) .none else if (comptime std.mem.eql(u8, mode, "OR IGNORE")) .ignore else if (comptime std.mem.eql(u8, mode, "OR REPLACE")) .replace else if (comptime std.mem.eql(u8, mode, "OR ABORT")) .abort else if (comptime std.mem.eql(u8, mode, "OR FAIL")) .fail else if (comptime std.mem.eql(u8, mode, "OR ROLLBACK")) .rollback else @compileError("unknown insert mode");
            const Source = @TypeOf(source);
            if (!@hasDecl(Source, "isMapped")) @compileError("insertSelect source must be a query builder from db.from(...)");
            if (Source.isMapped) @compileError("insertSelect source must return raw rows: project columns with .select(...)");
            var data = try source.fetch();
            defer data.deinit();
            if (data.columns.len == 0) return error.InvalidSql;
            var merged = std.ArrayList([]Value).empty;
            errdefer {
                for (merged.items) |row| {
                    for (row) |item| switch (item) {
                        .text => |text| self.allocator.free(text),
                        .blob => |blob| self.allocator.free(blob),
                        else => {},
                    };
                    self.allocator.free(row);
                }
                merged.deinit(self.allocator);
            }
            var outColumns: []const []const u8 = try self.allocator.alloc([]const u8, 0);
            var adoptedColumns = false;
            errdefer {
                for (outColumns) |name| self.allocator.free(name);
                self.allocator.free(outColumns);
            }
            var changes: usize = 0;
            for (data.rows) |row| {
                const setVals = try self.allocator.alloc(dslExpr.SetValue, row.len);
                for (row, 0..) |item, index| setVals[index] = .{ .literal = item };
                var built = astBuilder.buildInsert(self.allocator, self.table, self.schema, data.columns, setVals, conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{}) catch |err| {
                    self.allocator.free(setVals);
                    return err;
                };
                self.allocator.free(setVals);
                defer built.deinit();
                const one = try self.executeFn(self.connection, &built.stmt, &.{}, false);
                changes += one.changes;
                if (!adoptedColumns) {
                    self.allocator.free(outColumns);
                    outColumns = one.columns;
                    adoptedColumns = true;
                } else {
                    for (one.columns) |name| self.allocator.free(name);
                    self.allocator.free(one.columns);
                }
                try merged.appendSlice(self.allocator, one.rows);
                self.allocator.free(one.rows);
            }
            const rows = try merged.toOwnedSlice(self.allocator);
            return .{ .allocator = self.allocator, .columns = outColumns, .rows = rows, .changes = changes };
        }

        fn upsertBase(self: Self) UpsertBuilder(Row, Columns) {
            return .{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .table = self.table,
                .schema = self.schema,
                .cases = self.cases,
                .caseCount = self.caseCount,
                .caseWhens = self.caseWhens,
                .caseWhenCount = self.caseWhenCount,
                .returningCols = self.returningCols,
                .returningCount = self.returningCount,
            };
        }

        pub fn onConflict(self: Self, target: anytype) UpsertBuilder(Row, Columns) {
            var up = self.upsertBase();
            const T = @TypeOf(target);
            if (T == columnMod.DynamicColumn) {
                up.targetCols[0] = columnMod.dynRef(target).name;
                up.targetCount = 1;
            } else if (comptime isTypedColumnInstance(T)) {
                up.targetCols[0] = T.dslName;
                up.targetCount = 1;
            } else if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
                inline for (target) |item| {
                    if (up.targetCount >= up.targetCols.len) @panic("too many upsert target columns");
                    const IT = @TypeOf(item);
                    if (IT == columnMod.DynamicColumn) {
                        up.targetCols[up.targetCount] = columnMod.dynRef(item).name;
                    } else if (comptime isTypedColumnInstance(IT)) {
                        up.targetCols[up.targetCount] = IT.dslName;
                    } else {
                        @compileError("onConflict target must be column descriptors");
                    }
                    up.targetCount += 1;
                }
                if (up.targetCount == 0) @panic("onConflict requires at least one target column");
            } else {
                @compileError("onConflict target must be a column descriptor or a tuple of column descriptors");
            }
            return up;
        }

        pub fn doNothing(self: Self) UpsertBuilder(Row, Columns) {
            var up = self.upsertBase();
            up.action = .nothing;
            return up;
        }

        pub fn doUpdate(self: Self, assignments: anytype) !UpsertBuilder(Row, Columns) {
            var up = self.upsertBase();
            try up.extractSets(assignments);
            up.action = .update;
            return up;
        }

        fn insertWithMode(self: Self, row: anytype, comptime mode: []const u8) !Result {
            const conflict: ast.ConflictPolicy = if (comptime std.mem.eql(u8, mode, "")) .none else if (comptime std.mem.eql(u8, mode, "OR IGNORE")) .ignore else if (comptime std.mem.eql(u8, mode, "OR REPLACE")) .replace else if (comptime std.mem.eql(u8, mode, "OR ABORT")) .abort else if (comptime std.mem.eql(u8, mode, "OR FAIL")) .fail else if (comptime std.mem.eql(u8, mode, "OR ROLLBACK")) .rollback else @compileError("unknown insert mode");
            const RowType = @TypeOf(row);
            validateRow(RowType);
            if (Columns == void) {
                const fields = @typeInfo(RowType).@"struct".fields;
                var names: [fields.len][]const u8 = undefined;
                var vals: [fields.len]dslExpr.SetValue = undefined;
                var count: usize = 0;
                inline for (fields) |field| {
                    if (comptime isExplicitDefault(@TypeOf(@field(row, field.name)))) continue;
                    names[count] = field.name;
                    vals[count] = .{ .literal = insertFieldOf(@field(row, field.name)) };
                    count += 1;
                }
                if (count == 0) return error.InvalidSql;
                var built = try astBuilder.buildInsert(self.allocator, self.table, self.schema, names[0..count], vals[0..count], conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{});
                defer built.deinit();
                return self.executeFn(self.connection, &built.stmt, &.{}, false);
            } else {
                const colFields = @typeInfo(Columns).@"struct".fields;
                var names: [colFields.len][]const u8 = undefined;
                var vals: [colFields.len]dslExpr.SetValue = undefined;
                var count: usize = 0;
                inline for (colFields) |colField| {
                    if (@hasField(RowType, colField.name)) {
                        if (comptime isExplicitDefault(@TypeOf(@field(row, colField.name)))) continue;
                        names[count] = colField.type.dslName;
                        vals[count] = .{ .literal = insertFieldOf(@field(row, colField.name)) };
                        count += 1;
                    }
                }
                if (count == 0) return error.InvalidSql;
                var built = try astBuilder.buildInsert(self.allocator, self.table, self.schema, names[0..count], vals[0..count], conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{});
                defer built.deinit();
                return self.executeFn(self.connection, &built.stmt, &.{}, false);
            }
        }

        pub fn update(self: Self, assignments: anytype) !Mutation {
            const RowType = @TypeOf(assignments);
            validateRow(RowType);
            var mutation = Mutation{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .table = self.table,
                .schema = self.schema,
                .operation = .update,
                .cases = self.cases,
                .caseCount = self.caseCount,
                .caseWhens = self.caseWhens,
                .caseWhenCount = self.caseWhenCount,
                .returningCols = self.returningCols,
                .returningCount = self.returningCount,
            };
            if (Columns == void) {
                inline for (@typeInfo(RowType).@"struct".fields) |field| {
                    if (comptime isExplicitDefault(@TypeOf(@field(assignments, field.name)))) continue;
                    if (mutation.setCount >= mutation.setNames.len) return error.InvalidSql;
                    mutation.setNames[mutation.setCount] = field.name;
                    mutation.setValues[mutation.setCount] = setValueOf(@field(assignments, field.name));
                    mutation.setCount += 1;
                }
            } else {
                inline for (@typeInfo(Columns).@"struct".fields) |colField| {
                    if (@hasField(RowType, colField.name)) {
                        if (comptime isExplicitDefault(@TypeOf(@field(assignments, colField.name)))) continue;
                        if (mutation.setCount >= mutation.setNames.len) return error.InvalidSql;
                        mutation.setNames[mutation.setCount] = colField.type.dslName;
                        mutation.setValues[mutation.setCount] = setValueOf(@field(assignments, colField.name));
                        mutation.setCount += 1;
                    }
                }
            }
            if (mutation.setCount == 0) return error.InvalidSql;
            return mutation;
        }

        pub fn delete(self: Self) Mutation {
            return .{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .table = self.table,
                .schema = self.schema,
                .operation = .delete,
                .cases = self.cases,
                .caseCount = self.caseCount,
                .caseWhens = self.caseWhens,
                .caseWhenCount = self.caseWhenCount,
                .returningCols = self.returningCols,
                .returningCount = self.returningCount,
            };
        }

        pub fn fetch(self: *const Self) !if (isMapped) MappedResult else Result {
            if (isMapped) return self.fetchMapped();
            return self.fetchRaw();
        }

        fn fetchRaw(self: *const Self) !Result {
            if (self.subquery != null) {
                const snapshot = snapshotSelect(self, true);
                return execDerivedSnapshot(self.connection, self.derivedExecuteFn, self.allocator, &self.subquery.?, &snapshot);
            }
            const snapshot = snapshotSelect(self, false);
            return execSnapshot(self.connection, self.executeFn, self.allocator, &snapshot);
        }

        pub const MappedResult = struct {
            allocator: std.mem.Allocator,
            rows: []Row,

            pub fn deinit(result: *@This()) void {
                for (result.rows) |*row| freeMappedRow(Row, result.allocator, row);
                result.allocator.free(result.rows);
            }

            pub fn count(result: @This()) usize {
                return result.rows.len;
            }

            pub fn isEmpty(result: @This()) bool {
                return result.rows.len == 0;
            }

            pub fn at(result: @This(), index: usize) Row {
                return result.rows[index];
            }

            pub fn slice(result: @This()) []Row {
                return result.rows;
            }
        };

        fn fetchMapped(self: *const Self) !MappedResult {
            var result = try self.fetchRaw();
            defer result.deinit();
            const rows = try mapResultRows(Row, Columns, self.allocator, &result);
            return .{ .allocator = self.allocator, .rows = rows };
        }

        pub fn fetchOne(self: Self) !if (isMapped) Row else Value {
            if (isMapped) {
                var two = try self.limit(2).fetchMapped();
                switch (two.rows.len) {
                    0 => {
                        two.deinit();
                        return error.NoRows;
                    },
                    1 => {
                        const row = two.rows[0];
                        self.allocator.free(two.rows);
                        return row;
                    },
                    else => {
                        two.deinit();
                        return error.TooManyRows;
                    },
                }
            }
            if (self.projectionCount != 1 or self.allColumns) return error.InvalidSql;
            var two = try self.limit(2).fetchRaw();
            defer two.deinit();
            if (two.rows.len == 0) return error.NoRows;
            if (two.rows.len > 1) return error.TooManyRows;
            return try dupeValue(self.allocator, two.rows[0][0]);
        }

        pub fn fetchOptional(self: Self) !if (isMapped) ?Row else ?Value {
            if (isMapped) {
                var two = try self.limit(2).fetchMapped();
                switch (two.rows.len) {
                    0 => {
                        two.deinit();
                        return null;
                    },
                    1 => {
                        const row = two.rows[0];
                        self.allocator.free(two.rows);
                        return row;
                    },
                    else => {
                        two.deinit();
                        return error.TooManyRows;
                    },
                }
            }
            if (self.projectionCount != 1 or self.allColumns) return error.InvalidSql;
            var two = try self.limit(2).fetchRaw();
            defer two.deinit();
            if (two.rows.len == 0) return null;
            if (two.rows.len > 1) return error.TooManyRows;
            return try dupeValue(self.allocator, two.rows[0][0]);
        }

        pub fn freeRow(self: *const Self, row: *Row) void {
            if (!isTyped) @compileError("freeRow requires a typed table");
            freeMappedRow(Row, self.allocator, row);
        }
    };
}

/// Value-semantic compound query (UNION/INTERSECT/EXCEPT arms). Arms are
/// by-value snapshots; `orderBy`/`limit`/`offset` apply to the whole compound.
/// `fetch()` returns an owned result the caller must `deinit`. The connection
/// must outlive the builder and its results.
pub fn CompoundBuilder(comptime Row: type, comptime Columns: type, comptime mapped: bool) type {
    return struct {
        const Self = @This();
        pub const isTyped = Row != void;
        pub const rowType = Row;
        pub const columnsType = Columns;
        pub const isMapped = mapped and isTyped;

        allocator: std.mem.Allocator,
        connection: *anyopaque,
        compoundExecuteFn: astBuilder.CompoundExecFn,
        arms: [4]SelectSnapshot = undefined,
        armCount: usize = 0,
        ops: [3]ast.CompoundOp = undefined,
        opCount: usize = 0,
        orders: [8]Order = undefined,
        orderCount: usize = 0,
        limitValue: ?usize = null,
        offsetValue: ?usize = null,

        fn appendArm(self: *Self, snapshot: SelectSnapshot, op: ?ast.CompoundOp) void {
            if (self.armCount >= self.arms.len) @panic("too many compound arms");
            if (op) |operation| {
                if (self.opCount >= self.ops.len) @panic("too many compound arms");
                self.ops[self.opCount] = operation;
                self.opCount += 1;
            }
            self.arms[self.armCount] = snapshot;
            self.armCount += 1;
        }

        fn compoundAs(self: Self, other: anytype, op: ast.CompoundOp) Self {
            const Other = @TypeOf(other);
            if (!@hasDecl(Other, "isTyped")) @compileError("compound arm expects a query builder from db.from(...)");
            var copy = self;
            copy.appendArm(snapshotSelect(other, false), op);
            return copy;
        }

        pub fn unionDistinct(self: Self, other: anytype) Self {
            return self.compoundAs(other, .unionOp);
        }
        pub fn unionAll(self: Self, other: anytype) Self {
            return self.compoundAs(other, .unionAllOp);
        }
        pub fn intersect(self: Self, other: anytype) Self {
            return self.compoundAs(other, .intersectOp);
        }
        pub fn except(self: Self, other: anytype) Self {
            return self.compoundAs(other, .exceptOp);
        }

        pub fn orderBy(self: Self, order: anytype) Self {
            var copy = self;
            const T = @TypeOf(order);
            if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
                inline for (order) |item| {
                    if (copy.orderCount >= copy.orders.len) @panic("too many order columns");
                    copy.orders[copy.orderCount] = toOrder(item);
                    copy.orderCount += 1;
                }
                if (copy.orderCount == 0) @panic("orderBy() requires at least one order");
            } else {
                if (copy.orderCount >= copy.orders.len) @panic("too many order columns");
                copy.orders[copy.orderCount] = toOrder(order);
                copy.orderCount += 1;
            }
            return copy;
        }

        pub fn limit(self: Self, amount: usize) Self {
            var copy = self;
            copy.limitValue = amount;
            return copy;
        }

        pub fn offset(self: Self, amount: usize) Self {
            var copy = self;
            copy.offsetValue = amount;
            return copy;
        }

        pub const MappedResult = struct {
            allocator: std.mem.Allocator,
            rows: []Row,

            pub fn deinit(result: *@This()) void {
                for (result.rows) |*row| freeMappedRow(Row, result.allocator, row);
                result.allocator.free(result.rows);
            }

            pub fn count(result: @This()) usize {
                return result.rows.len;
            }

            pub fn isEmpty(result: @This()) bool {
                return result.rows.len == 0;
            }

            pub fn at(result: @This(), index: usize) Row {
                return result.rows[index];
            }

            pub fn slice(result: @This()) []Row {
                return result.rows;
            }
        };

        pub fn fetch(self: *const Self) !if (isMapped) MappedResult else Result {
            if (isMapped) return self.fetchMapped();
            return self.fetchRaw();
        }

        fn fetchRaw(self: *const Self) !Result {
            for (self.arms[0..self.armCount]) |snapshot| {
                if (snapshot.orderCount != 0 or snapshot.limitValue != null or snapshot.offsetValue != null) return error.InvalidSql;
            }
            var builts: [4]astBuilder.BuiltStatement = undefined;
            var count: usize = 0;
            errdefer for (builts[0..count]) |*built| built.deinit();
            var cteBufs: [4][8]astBuilder.CteInput = undefined;
            var armInputs: [4]astBuilder.CompoundArm = undefined;
            for (0..self.armCount) |index| {
                const snapshot = &self.arms[index];
                builts[index] = try buildSnapshotSelect(self.allocator, snapshot);
                count += 1;
                for (snapshot.ctes[0..snapshot.cteCount], 0..) |cte, cteIndex| cteBufs[index][cteIndex] = .{ .name = cte.name, .querySql = cte.base, .recursiveSql = cte.recursive };
                armInputs[index] = .{ .stmt = &builts[index].stmt, .ctes = cteBufs[index][0..snapshot.cteCount], .recursive = snapshot.cteRecursive };
            }
            var compoundOrders: [8]ast.Order = undefined;
            var compoundOrderCount: usize = 0;
            for (self.orders[0..self.orderCount]) |ord| {
                if (ord.function != null) return error.InvalidSql;
                compoundOrders[compoundOrderCount] = .{ .column = ord.column.name, .descending = ord.descending };
                compoundOrderCount += 1;
            }
            const result = try self.compoundExecuteFn(self.connection, armInputs[0..self.armCount], self.ops[0..self.opCount], compoundOrders[0..compoundOrderCount], self.limitValue, self.offsetValue);
            for (builts[0..count]) |*built| built.deinit();
            return result;
        }

        fn fetchMapped(self: *const Self) !MappedResult {
            var result = try self.fetchRaw();
            defer result.deinit();
            const rows = try mapResultRows(Row, Columns, self.allocator, &result);
            return .{ .allocator = self.allocator, .rows = rows };
        }

        pub fn fetchOne(self: Self) !if (isMapped) Row else Value {
            if (isMapped) {
                var two = try self.limit(2).fetchMapped();
                switch (two.rows.len) {
                    0 => {
                        two.deinit();
                        return error.NoRows;
                    },
                    1 => {
                        const row = two.rows[0];
                        self.allocator.free(two.rows);
                        return row;
                    },
                    else => {
                        two.deinit();
                        return error.TooManyRows;
                    },
                }
            }
            for (self.arms[0..self.armCount]) |arm| {
                if (arm.allColumns or arm.projectionCount != 1) return error.InvalidSql;
            }
            var two = try self.limit(2).fetchRaw();
            defer two.deinit();
            if (two.rows.len == 0) return error.NoRows;
            if (two.rows.len > 1) return error.TooManyRows;
            if (two.rows[0].len != 1) return error.InvalidSql;
            return try dupeValue(self.allocator, two.rows[0][0]);
        }

        pub fn fetchOptional(self: Self) !if (isMapped) ?Row else ?Value {
            if (isMapped) {
                var two = try self.limit(2).fetchMapped();
                switch (two.rows.len) {
                    0 => {
                        two.deinit();
                        return null;
                    },
                    1 => {
                        const row = two.rows[0];
                        self.allocator.free(two.rows);
                        return row;
                    },
                    else => {
                        two.deinit();
                        return error.TooManyRows;
                    },
                }
            }
            for (self.arms[0..self.armCount]) |arm| {
                if (arm.allColumns or arm.projectionCount != 1) return error.InvalidSql;
            }
            var two = try self.limit(2).fetchRaw();
            defer two.deinit();
            if (two.rows.len == 0) return null;
            if (two.rows.len > 1) return error.TooManyRows;
            if (two.rows[0].len != 1) return error.InvalidSql;
            return try dupeValue(self.allocator, two.rows[0][0]);
        }

        pub fn freeRow(self: *const Self, row: *Row) void {
            if (!isTyped) @compileError("freeRow requires a typed table");
            freeMappedRow(Row, self.allocator, row);
        }
    };
}

fn findResultColumn(columns: []const []const u8, want: []const u8) ?usize {
    for (columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column, want)) return index;
    return null;
}

fn freeMappedValue(allocator: std.mem.Allocator, value: anytype) void {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) allocator.free(value);
    if (@typeInfo(T) == .optional) if (value) |present| freeMappedValue(allocator, present);
}

fn dupeValue(allocator: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .text => |bytes| .{ .text = try allocator.dupe(u8, bytes) },
        .blob => |bytes| .{ .blob = try allocator.dupe(u8, bytes) },
        else => value,
    };
}

/// Release an owned `Value`'s text/blob payload. No-op for ints/reals/null.
/// Call exactly once per owned value; borrowed values must NOT be freed.
pub fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .text => |bytes| allocator.free(bytes),
        .blob => |bytes| allocator.free(bytes),
        else => {},
    }
}

fn assignMappedValue(allocator: std.mem.Allocator, destination: anytype, value: Value) !void {
    const T = @TypeOf(destination.*);
    if (@typeInfo(T) == .optional) {
        if (value == .null) {
            destination.* = null;
            return;
        }
        var present: @typeInfo(T).optional.child = undefined;
        try assignMappedValue(allocator, &present, value);
        destination.* = present;
        return;
    }
    if (value == .null) return error.InvalidSql;
    switch (@typeInfo(T)) {
        .bool => destination.* = switch (value) {
            .integer => |n| n != 0,
            else => return error.InvalidSql,
        },
        .int => destination.* = @intCast(switch (value) {
            .integer => |n| n,
            .real => |n| @as(i64, @intFromFloat(n)),
            else => return error.InvalidSql,
        }),
        .float => destination.* = @floatCast(switch (value) {
            .integer => |n| @as(f64, @floatFromInt(n)),
            .real => |n| n,
            else => return error.InvalidSql,
        }),
        .pointer => if (@typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) {
            if (value != .text) return error.InvalidSql;
            destination.* = try allocator.dupe(u8, value.text);
        } else return error.InvalidSql,
        else => return error.InvalidSql,
    }
}

fn freeMappedRow(comptime Row: type, allocator: std.mem.Allocator, row: *Row) void {
    inline for (@typeInfo(Row).@"struct".fields) |field| {
        freeMappedValue(allocator, @field(row.*, field.name));
    }
}

fn mapResultRows(comptime Row: type, comptime Columns: type, allocator: std.mem.Allocator, result: *const Result) ![]Row {
    const rows = try allocator.alloc(Row, result.rows.len);
    var done: usize = 0;
    errdefer {
        for (rows[0..done]) |*row| freeMappedRow(Row, allocator, row);
        allocator.free(rows);
    }
    for (result.rows, 0..) |source, rowIndex| {
        var destination: Row = undefined;
        var assigned: usize = 0;
        errdefer {
            inline for (@typeInfo(Row).@"struct".fields, 0..) |field, fi| {
                if (fi < assigned) freeMappedValue(allocator, @field(destination, field.name));
            }
        }
        if (Columns == void) {
            inline for (@typeInfo(Row).@"struct".fields, 0..) |field, fi| {
                const index = findResultColumn(result.columns, field.name) orelse return error.UnknownColumn;
                try assignMappedValue(allocator, &@field(destination, field.name), source[index]);
                assigned = fi + 1;
            }
        } else {
            inline for (@typeInfo(Columns).@"struct".fields, 0..) |colField, fi| {
                const index = findResultColumn(result.columns, colField.type.dslName) orelse return error.UnknownColumn;
                try assignMappedValue(allocator, &@field(destination, colField.name), source[index]);
                assigned = fi + 1;
            }
        }
        rows[rowIndex] = destination;
        done = rowIndex + 1;
    }
    return rows;
}

const SelectSnapshot = struct {
    table: []const u8,
    schema: []const u8 = "",
    tableAlias: ?[]const u8 = null,
    allColumns: bool = true,
    projections: [32]Projection = undefined,
    projectionCount: usize = 0,
    cases: [2]CaseBuilder = undefined,
    caseCount: usize = 0,
    windows: [4]WindowBuilder = undefined,
    windowCount: usize = 0,
    distinctValue: bool = false,
    conditions: [16]ConditionEntry = undefined,
    conditionCount: usize = 0,
    caseWhens: [2]astBuilder.CaseWhereArgs = undefined,
    caseWhenCount: usize = 0,
    orders: [8]Order = undefined,
    orderCount: usize = 0,
    limitValue: ?usize = null,
    offsetValue: ?usize = null,
    groupByColumn: ?ColumnRef = null,
    havingCond: ?dslExpr.HavingCond = null,
    havingValid: bool = true,
    joinTable: ?[]const u8 = null,
    joinSchema: []const u8 = "",
    joinAlias: ?[]const u8 = null,
    joinKind: JoinKind = .inner,
    joinOn: ?Expr = null,
    joinUsingCols: [8][]const u8 = undefined,
    joinUsingCount: usize = 0,
    joinNatural: bool = false,
    inQuery: ?InQuery = null,
    existsQuery: ?ExistsQuery = null,
    literalIn: ?LiteralIn = null,
    ctes: [8]Cte = undefined,
    cteCount: usize = 0,
    cteRecursive: bool = false,
};

const SubSnapshot = struct {
    table: []const u8,
    schema: []const u8 = "",
    tableAlias: ?[]const u8 = null,
    allColumns: bool = true,
    projections: [32]Projection = undefined,
    projectionCount: usize = 0,
    cases: [2]CaseBuilder = undefined,
    caseCount: usize = 0,
    windows: [4]WindowBuilder = undefined,
    windowCount: usize = 0,
    distinctValue: bool = false,
    conditions: [16]ConditionEntry = undefined,
    conditionCount: usize = 0,
    caseWhens: [2]astBuilder.CaseWhereArgs = undefined,
    caseWhenCount: usize = 0,
    orders: [8]Order = undefined,
    orderCount: usize = 0,
    limitValue: ?usize = null,
    offsetValue: ?usize = null,
    groupByColumn: ?ColumnRef = null,
    havingCond: ?dslExpr.HavingCond = null,
    havingValid: bool = true,
    joinTable: ?[]const u8 = null,
    joinSchema: []const u8 = "",
    joinAlias: ?[]const u8 = null,
    joinKind: JoinKind = .inner,
    joinOn: ?Expr = null,
    joinUsingCols: [8][]const u8 = undefined,
    joinUsingCount: usize = 0,
    joinNatural: bool = false,
    inQuery: ?InQuery = null,
    existsQuery: ?ExistsQuery = null,
    literalIn: ?LiteralIn = null,
    ctes: [8]Cte = undefined,
    cteCount: usize = 0,
    cteRecursive: bool = false,
};

fn snapshotSelect(source: anytype, comptime allowSubquery: bool) SelectSnapshot {
    if (!allowSubquery and source.subquery != null) @panic("compound arms cannot select from a derived table");
    return .{
        .table = source.table,
        .schema = source.schema,
        .tableAlias = source.tableAlias,
        .allColumns = source.allColumns,
        .projections = source.projections,
        .projectionCount = source.projectionCount,
        .cases = source.cases,
        .caseCount = source.caseCount,
        .windows = source.windows,
        .windowCount = source.windowCount,
        .distinctValue = source.distinctValue,
        .conditions = source.conditions,
        .conditionCount = source.conditionCount,
        .caseWhens = source.caseWhens,
        .caseWhenCount = source.caseWhenCount,
        .orders = source.orders,
        .orderCount = source.orderCount,
        .limitValue = source.limitValue,
        .offsetValue = source.offsetValue,
        .groupByColumn = source.groupByColumn,
        .havingCond = source.havingCond,
        .havingValid = source.havingValid,
        .joinTable = source.joinTable,
        .joinSchema = source.joinSchema,
        .joinAlias = source.joinAlias,
        .joinKind = source.joinKind,
        .joinOn = source.joinOn,
        .joinUsingCols = source.joinUsingCols,
        .joinUsingCount = source.joinUsingCount,
        .joinNatural = source.joinNatural,
        .inQuery = source.inQuery,
        .existsQuery = source.existsQuery,
        .literalIn = source.literalIn,
        .ctes = source.ctes,
        .cteCount = source.cteCount,
        .cteRecursive = source.cteRecursive,
    };
}

fn snapshotSub(source: anytype) SubSnapshot {
    return .{
        .table = source.table,
        .schema = source.schema,
        .tableAlias = source.tableAlias,
        .allColumns = source.allColumns,
        .projections = source.projections,
        .projectionCount = source.projectionCount,
        .cases = source.cases,
        .caseCount = source.caseCount,
        .windows = source.windows,
        .windowCount = source.windowCount,
        .distinctValue = source.distinctValue,
        .conditions = source.conditions,
        .conditionCount = source.conditionCount,
        .caseWhens = source.caseWhens,
        .caseWhenCount = source.caseWhenCount,
        .orders = source.orders,
        .orderCount = source.orderCount,
        .limitValue = source.limitValue,
        .offsetValue = source.offsetValue,
        .groupByColumn = source.groupByColumn,
        .havingCond = source.havingCond,
        .havingValid = source.havingValid,
        .joinTable = source.joinTable,
        .joinSchema = source.joinSchema,
        .joinAlias = source.joinAlias,
        .joinKind = source.joinKind,
        .joinOn = source.joinOn,
        .joinUsingCols = source.joinUsingCols,
        .joinUsingCount = source.joinUsingCount,
        .joinNatural = source.joinNatural,
        .inQuery = source.inQuery,
        .existsQuery = source.existsQuery,
        .literalIn = source.literalIn,
        .ctes = source.ctes,
        .cteCount = source.cteCount,
        .cteRecursive = source.cteRecursive,
    };
}

fn selectFromSub(sub: *const SubSnapshot) SelectSnapshot {
    return .{
        .table = sub.table,
        .schema = sub.schema,
        .tableAlias = sub.tableAlias,
        .allColumns = sub.allColumns,
        .projections = sub.projections,
        .projectionCount = sub.projectionCount,
        .cases = sub.cases,
        .caseCount = sub.caseCount,
        .windows = sub.windows,
        .windowCount = sub.windowCount,
        .distinctValue = sub.distinctValue,
        .conditions = sub.conditions,
        .conditionCount = sub.conditionCount,
        .caseWhens = sub.caseWhens,
        .caseWhenCount = sub.caseWhenCount,
        .orders = sub.orders,
        .orderCount = sub.orderCount,
        .limitValue = sub.limitValue,
        .offsetValue = sub.offsetValue,
        .groupByColumn = sub.groupByColumn,
        .havingCond = sub.havingCond,
        .havingValid = sub.havingValid,
        .joinTable = sub.joinTable,
        .joinSchema = sub.joinSchema,
        .joinAlias = sub.joinAlias,
        .joinKind = sub.joinKind,
        .joinOn = sub.joinOn,
        .joinUsingCols = sub.joinUsingCols,
        .joinUsingCount = sub.joinUsingCount,
        .joinNatural = sub.joinNatural,
        .inQuery = sub.inQuery,
        .existsQuery = sub.existsQuery,
        .literalIn = sub.literalIn,
        .ctes = sub.ctes,
        .cteCount = sub.cteCount,
        .cteRecursive = sub.cteRecursive,
    };
}

fn buildSnapshotSelect(allocator: std.mem.Allocator, snapshot: *const SelectSnapshot) !astBuilder.BuiltStatement {
    var literalIn: ?astBuilder.LiteralInArgs = null;
    if (snapshot.literalIn) |entry| literalIn = .{ .column = entry.column, .values = entry.values[0..entry.count], .negated = entry.negated };
    return astBuilder.buildSelect(allocator, .{
        .table = snapshot.table,
        .schema = snapshot.schema,
        .tableAlias = snapshot.tableAlias,
        .allColumns = snapshot.allColumns,
        .projections = snapshot.projections[0..snapshot.projectionCount],
        .cases = snapshot.cases[0..snapshot.caseCount],
        .windows = snapshot.windows[0..snapshot.windowCount],
        .caseWhens = snapshot.caseWhens[0..snapshot.caseWhenCount],
        .distinct = snapshot.distinctValue,
        .conditions = snapshot.conditions[0..snapshot.conditionCount],
        .orders = snapshot.orders[0..snapshot.orderCount],
        .limit = snapshot.limitValue,
        .offset = snapshot.offsetValue,
        .groupBy = snapshot.groupByColumn,
        .having = snapshot.havingCond,
        .havingValid = snapshot.havingValid,
        .joinTable = snapshot.joinTable,
        .joinSchema = snapshot.joinSchema,
        .joinAlias = snapshot.joinAlias,
        .joinKind = snapshot.joinKind,
        .joinOn = snapshot.joinOn,
        .joinUsingCols = snapshot.joinUsingCols[0..snapshot.joinUsingCount],
        .joinNatural = snapshot.joinNatural,
        .inQuery = snapshot.inQuery,
        .existsQuery = snapshot.existsQuery,
        .literalIn = literalIn,
    });
}

fn execSnapshot(connection: *anyopaque, executeFn: astBuilder.ExecFn, allocator: std.mem.Allocator, snapshot: *const SelectSnapshot) !Result {
    var built = try buildSnapshotSelect(allocator, snapshot);
    defer built.deinit();
    var cteInputs: [8]astBuilder.CteInput = undefined;
    for (snapshot.ctes[0..snapshot.cteCount], 0..) |cte, index| cteInputs[index] = .{ .name = cte.name, .querySql = cte.base, .recursiveSql = cte.recursive };
    return executeFn(connection, &built.stmt, cteInputs[0..snapshot.cteCount], snapshot.cteRecursive);
}

fn execDerivedSnapshot(connection: *anyopaque, derivedExecuteFn: astBuilder.DerivedExecFn, allocator: std.mem.Allocator, sub: *const SubSnapshot, outer: *const SelectSnapshot) !Result {
    var outerBuilt = try buildSnapshotSelect(allocator, outer);
    defer outerBuilt.deinit();
    const subSelect = selectFromSub(sub);
    var subBuilt = try buildSnapshotSelect(allocator, &subSelect);
    defer subBuilt.deinit();
    var subCtes: [8]astBuilder.CteInput = undefined;
    for (sub.ctes[0..sub.cteCount], 0..) |cte, index| subCtes[index] = .{ .name = cte.name, .querySql = cte.base, .recursiveSql = cte.recursive };
    var outerCtes: [8]astBuilder.CteInput = undefined;
    for (outer.ctes[0..outer.cteCount], 0..) |cte, index| outerCtes[index] = .{ .name = cte.name, .querySql = cte.base, .recursiveSql = cte.recursive };
    return derivedExecuteFn(connection, .{ .stmt = &subBuilt.stmt, .ctes = subCtes[0..sub.cteCount], .recursive = sub.cteRecursive }, .{ .stmt = &outerBuilt.stmt, .ctes = outerCtes[0..outer.cteCount], .recursive = outer.cteRecursive });
}

test "typed and dynamic builders share one engine" {
    try std.testing.expect(Builder(struct { id: i64 }, void, true).isTyped);
    try std.testing.expect(!Builder(void, void, false).isTyped);
    try std.testing.expect(DynamicQuery.isTyped == false);
    const T = @import("table.zig").table("t", struct { id: i64 });
    try std.testing.expect(Query(@TypeOf(T)).isTyped);
}

/// Value-semantic UPSERT builder (`onConflict(...).doUpdate(...).insert(row)`).
/// Conflict targets, SET list, and filters are borrowed; `insert()` lowers to
/// native AST via `ast_builder` and returns an owned `Result` (caller deinits).
pub fn UpsertBuilder(comptime Row: type, comptime Columns: type) type {
    return struct {
        const Self = @This();
        pub const isTyped = Row != void;

        allocator: std.mem.Allocator,
        connection: *anyopaque,
        executeFn: astBuilder.ExecFn,
        table: []const u8,
        schema: []const u8 = "",
        targetCols: [8][]const u8 = undefined,
        targetCount: usize = 0,
        targetWhere: ?Expr = null,
        action: enum { none, nothing, update } = .none,
        sets: [16]astBuilder.UpsertSet = undefined,
        setCount: usize = 0,
        upsertConds: [8]ConditionEntry = undefined,
        upsertCondCount: usize = 0,
        caseWhens: [2]astBuilder.CaseWhereArgs = undefined,
        caseWhenCount: usize = 0,
        cases: [2]CaseBuilder = undefined,
        caseCount: usize = 0,
        returningCols: [16]Projection = undefined,
        returningCount: usize = 0,

        pub fn onConflictWhere(self: Self, condition: Expr) Self {
            var copy = self;
            copy.targetWhere = condition;
            return copy;
        }

        pub fn doNothing(self: Self) Self {
            var copy = self;
            copy.action = .nothing;
            return copy;
        }

        pub fn doUpdate(self: Self, assignments: anytype) !Self {
            var copy = self;
            try copy.extractSets(assignments);
            copy.action = .update;
            return copy;
        }

        pub fn where(self: Self, condition: Expr) Self {
            var copy = self;
            copy.upsertConds[0] = .{ .expr = condition };
            copy.upsertCondCount = 1;
            return copy;
        }

        pub fn andWhere(self: Self, condition: Expr) Self {
            var copy = self;
            if (copy.upsertCondCount >= copy.upsertConds.len) @panic("too many upsert predicates");
            if (copy.upsertCondCount == 0) return copy.where(condition);
            copy.upsertConds[copy.upsertCondCount] = .{ .expr = condition, .joinOr = false };
            copy.upsertCondCount += 1;
            return copy;
        }

        pub fn orWhere(self: Self, condition: Expr) Self {
            var copy = self;
            if (copy.upsertCondCount >= copy.upsertConds.len) @panic("too many upsert predicates");
            if (copy.upsertCondCount == 0) return copy.where(condition);
            copy.upsertConds[copy.upsertCondCount] = .{ .expr = condition, .joinOr = true };
            copy.upsertCondCount += 1;
            return copy;
        }

        pub fn whereCase(self: Self, case: CaseBuilder, value: anytype) Self {
            var copy = self;
            copy.caseWhens[0] = .{ .case = case, .value = columnMod.toRhs(value) };
            copy.caseWhenCount = 1;
            return copy;
        }

        pub fn andWhereCase(self: Self, case: CaseBuilder, value: anytype) Self {
            var copy = self;
            if (copy.caseWhenCount >= copy.caseWhens.len) @panic("too many DSL case filters");
            copy.caseWhens[copy.caseWhenCount] = .{ .case = case, .value = columnMod.toRhs(value), .joinOr = copy.caseWhenCount != 0 or copy.upsertCondCount != 0 };
            copy.caseWhenCount += 1;
            return copy;
        }

        pub fn orWhereCase(self: Self, case: CaseBuilder, value: anytype) Self {
            var copy = self;
            if (copy.caseWhenCount >= copy.caseWhens.len) @panic("too many DSL case filters");
            copy.caseWhens[copy.caseWhenCount] = .{ .case = case, .value = columnMod.toRhs(value), .joinOr = true };
            copy.caseWhenCount += 1;
            return copy;
        }

        pub fn returning(self: Self, cols: anytype) Self {
            if (comptime @TypeOf(cols) == tableMod.AllOpFn) @compileError("use User.all() (call it) for RETURNING all columns");
            var copy = self;
            copy.returningCount = 0;
            const items = if (@typeInfo(@TypeOf(cols)) == .pointer) cols.* else cols;
            inline for (items) |item| {
                if (@TypeOf(item) == CaseBuilder) {
                    storeCaseProjection(&copy.cases, &copy.caseCount, copy.returningCols[0..], &copy.returningCount, item);
                    continue;
                }
                if (@TypeOf(item) == WindowBuilder) @panic("window functions are not supported in RETURNING");
                if (copy.returningCount >= copy.returningCols.len) @panic("too many DSL returning columns");
                copy.returningCols[copy.returningCount] = toProjection(item);
                copy.returningCount += 1;
            }
            if (copy.returningCount == 0) @panic("returning() requires at least one column");
            return copy;
        }

        fn extractSets(self: *Self, assignments: anytype) !void {
            const RowType = @TypeOf(assignments);
            if (@typeInfo(RowType) != .@"struct") @compileError("DSL row must be a struct");
            if (isTyped) {
                inline for (@typeInfo(RowType).@"struct".fields) |field| {
                    if (!@hasField(Row, field.name)) @compileError("DSL row contains an unknown table column");
                }
            }
            self.setCount = 0;
            if (Columns == void) {
                inline for (@typeInfo(RowType).@"struct".fields) |field| {
                    if (comptime isExplicitDefault(@TypeOf(@field(assignments, field.name)))) continue;
                    if (self.setCount >= self.sets.len) return error.InvalidSql;
                    self.sets[self.setCount] = .{ .name = field.name, .value = upsertValueOf(@field(assignments, field.name)) };
                    self.setCount += 1;
                }
            } else {
                inline for (@typeInfo(Columns).@"struct".fields) |colField| {
                    if (@hasField(RowType, colField.name)) {
                        if (comptime isExplicitDefault(@TypeOf(@field(assignments, colField.name)))) continue;
                        if (self.setCount >= self.sets.len) return error.InvalidSql;
                        self.sets[self.setCount] = .{ .name = colField.type.dslName, .value = upsertValueOf(@field(assignments, colField.name)) };
                        self.setCount += 1;
                    }
                }
            }
            if (self.setCount == 0) return error.InvalidSql;
        }

        pub fn insert(self: Self, row: anytype) !Result {
            if (self.action == .none) return error.InvalidSql;
            const conflict: ast.ConflictPolicy = switch (self.action) {
                .nothing => .ignore,
                .update => .update,
                .none => return error.InvalidSql,
            };
            const RowType = @TypeOf(row);
            if (@typeInfo(RowType) != .@"struct") @compileError("DSL row must be a struct");
            if (isTyped) {
                inline for (@typeInfo(RowType).@"struct".fields) |field| {
                    if (!@hasField(Row, field.name)) @compileError("DSL row contains an unknown table column");
                }
            }
            if (Columns == void) {
                const fields = @typeInfo(RowType).@"struct".fields;
                var names: [fields.len][]const u8 = undefined;
                var vals: [fields.len]dslExpr.SetValue = undefined;
                var count: usize = 0;
                inline for (fields) |field| {
                    if (comptime isExplicitDefault(@TypeOf(@field(row, field.name)))) continue;
                    names[count] = field.name;
                    vals[count] = .{ .literal = insertFieldOf(@field(row, field.name)) };
                    count += 1;
                }
                if (count == 0) return error.InvalidSql;
                var built = try astBuilder.buildInsert(self.allocator, self.table, self.schema, names[0..count], vals[0..count], conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{
                    .targets = self.targetCols[0..self.targetCount],
                    .targetWhere = self.targetWhere,
                    .sets = self.sets[0..self.setCount],
                    .upsertWhere = self.upsertConds[0..self.upsertCondCount],
                    .caseWhens = self.caseWhens[0..self.caseWhenCount],
                });
                defer built.deinit();
                return self.executeFn(self.connection, &built.stmt, &.{}, false);
            } else {
                const colFields = @typeInfo(Columns).@"struct".fields;
                var names: [colFields.len][]const u8 = undefined;
                var vals: [colFields.len]dslExpr.SetValue = undefined;
                var count: usize = 0;
                inline for (colFields) |colField| {
                    if (@hasField(RowType, colField.name)) {
                        if (comptime isExplicitDefault(@TypeOf(@field(row, colField.name)))) continue;
                        names[count] = colField.type.dslName;
                        vals[count] = .{ .literal = insertFieldOf(@field(row, colField.name)) };
                        count += 1;
                    }
                }
                if (count == 0) return error.InvalidSql;
                var built = try astBuilder.buildInsert(self.allocator, self.table, self.schema, names[0..count], vals[0..count], conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{
                    .targets = self.targetCols[0..self.targetCount],
                    .targetWhere = self.targetWhere,
                    .sets = self.sets[0..self.setCount],
                    .upsertWhere = self.upsertConds[0..self.upsertCondCount],
                    .caseWhens = self.caseWhens[0..self.caseWhenCount],
                });
                defer built.deinit();
                return self.executeFn(self.connection, &built.stmt, &.{}, false);
            }
        }
    };
}

fn upsertValueOf(value: anytype) astBuilder.UpsertValue {
    const T = @TypeOf(value);
    if (T == columnMod.ExcludedColumn) return .{ .excluded = value.name };
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "isExplicitValue")) {
        return .{ .literal = value.value };
    }
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "isArithExpr")) return .{ .set = value.toSetValue() };
    if (T == columnMod.DynamicColumn) return .{ .set = .{ .column = columnMod.dynRef(value) } };
    if (comptime isTypedColumnInstance(T)) return .{ .set = .{ .column = .{ .table = T.dslTable, .name = T.dslName } } };
    return .{ .literal = columnMod.toValue(value) };
}

/// Value-semantic UPDATE/DELETE mutation. Chain `.where(...)` then call
/// `execute()` for an owned `Result` (caller `deinit`s). `updateFrom` joins a
/// second table for UPDATEs. Borrowed names/conditions; connection must
/// outlive the mutation.
pub const Mutation = struct {
    allocator: std.mem.Allocator,
    connection: *anyopaque,
    executeFn: astBuilder.ExecFn,
    table: []const u8,
    schema: []const u8 = "",
    operation: enum { update, delete },
    setNames: [32][]const u8 = undefined,
    setValues: [32]dslExpr.SetValue = undefined,
    setCount: usize = 0,
    conditions: [16]ConditionEntry = undefined,
    conditionCount: usize = 0,
    caseWhens: [2]astBuilder.CaseWhereArgs = undefined,
    caseWhenCount: usize = 0,
    cases: [2]CaseBuilder = undefined,
    caseCount: usize = 0,
    returningCols: [16]Projection = undefined,
    returningCount: usize = 0,
    fromTable: ?[]const u8 = null,
    fromSchema: []const u8 = "",
    fromLeft: dslExpr.ColumnRef = .{ .name = "" },
    fromRight: dslExpr.ColumnRef = .{ .name = "" },

    pub fn updateFrom(self: Mutation, other: anytype, on: Expr) Mutation {
        var copy = self;
        const target = joinTargetOf(other);
        copy.fromTable = target.name;
        copy.fromSchema = target.schema;
        if (on.operator != .equal) @panic("updateFrom requires an equality predicate");
        const rightRef = switch (on.rhs) {
            .column => |ref| ref,
            .value => @panic("updateFrom requires a column-to-column equality predicate"),
        };
        copy.fromLeft = on.column;
        copy.fromRight = rightRef;
        return copy;
    }

    pub fn where(self: Mutation, condition: Expr) Mutation {
        var copy = self;
        copy.conditions[0] = .{ .expr = condition };
        copy.conditionCount = 1;
        return copy;
    }

    pub fn andWhere(self: Mutation, condition: Expr) Mutation {
        var copy = self;
        if (copy.conditionCount >= copy.conditions.len) @panic("too many DSL predicates");
        if (copy.conditionCount == 0) return copy.where(condition);
        copy.conditions[copy.conditionCount] = .{ .expr = condition, .joinOr = false };
        copy.conditionCount += 1;
        return copy;
    }

    pub fn orWhere(self: Mutation, condition: Expr) Mutation {
        var copy = self;
        if (copy.conditionCount >= copy.conditions.len) @panic("too many DSL predicates");
        if (copy.conditionCount == 0) return copy.where(condition);
        copy.conditions[copy.conditionCount] = .{ .expr = condition, .joinOr = true };
        copy.conditionCount += 1;
        return copy;
    }

    pub fn whereCase(self: Mutation, case: CaseBuilder, value: anytype) Mutation {
        var copy = self;
        copy.caseWhens[0] = .{ .case = case, .value = columnMod.toRhs(value) };
        copy.caseWhenCount = 1;
        return copy;
    }

    pub fn andWhereCase(self: Mutation, case: CaseBuilder, value: anytype) Mutation {
        var copy = self;
        if (copy.caseWhenCount >= copy.caseWhens.len) @panic("too many DSL case filters");
        copy.caseWhens[copy.caseWhenCount] = .{ .case = case, .value = columnMod.toRhs(value), .joinOr = copy.caseWhenCount != 0 or copy.conditionCount != 0 };
        copy.caseWhenCount += 1;
        return copy;
    }

    pub fn orWhereCase(self: Mutation, case: CaseBuilder, value: anytype) Mutation {
        var copy = self;
        if (copy.caseWhenCount >= copy.caseWhens.len) @panic("too many DSL case filters");
        copy.caseWhens[copy.caseWhenCount] = .{ .case = case, .value = columnMod.toRhs(value), .joinOr = true };
        copy.caseWhenCount += 1;
        return copy;
    }

    pub fn returning(self: Mutation, cols: anytype) Mutation {
        if (comptime @TypeOf(cols) == tableMod.AllOpFn) @compileError("use User.all() (call it) for RETURNING all columns");
        var copy = self;
        copy.returningCount = 0;
        const items = if (@typeInfo(@TypeOf(cols)) == .pointer) cols.* else cols;
        inline for (items) |item| {
            if (@TypeOf(item) == CaseBuilder) {
                storeCaseProjection(&copy.cases, &copy.caseCount, copy.returningCols[0..], &copy.returningCount, item);
                continue;
            }
            if (@TypeOf(item) == WindowBuilder) @panic("window functions are not supported in RETURNING");
            if (copy.returningCount >= copy.returningCols.len) @panic("too many DSL returning columns");
            copy.returningCols[copy.returningCount] = toProjection(item);
            copy.returningCount += 1;
        }
        if (copy.returningCount == 0) @panic("returning() requires at least one column");
        return copy;
    }

    pub fn execute(self: Mutation) !Result {
        if (self.operation == .update) {
            const fromSpec: ?ast.UpdateFrom = if (self.fromTable) |source| .{ .table = source, .tableSchema = self.fromSchema, .leftTable = self.fromLeft.table, .leftColumn = self.fromLeft.name, .rightTable = self.fromRight.table, .rightColumn = self.fromRight.name } else null;
            var built = try astBuilder.buildUpdate(self.allocator, self.table, self.schema, self.setNames[0..self.setCount], self.setValues[0..self.setCount], self.conditions[0..self.conditionCount], self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], self.caseWhens[0..self.caseWhenCount], fromSpec);
            defer built.deinit();
            return self.executeFn(self.connection, &built.stmt, &.{}, false);
        } else {
            if (self.fromTable != null) return error.InvalidSql;
            var built = try astBuilder.buildDelete(self.allocator, self.table, self.schema, self.conditions[0..self.conditionCount], self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], self.caseWhens[0..self.caseWhenCount]);
            defer built.deinit();
            return self.executeFn(self.connection, &built.stmt, &.{}, false);
        }
    }
};

test "orderBy accepts single orders and tuples of orders" {
    const conn = @as(*anyopaque, @ptrFromInt(0x1000));
    const base = DynamicQuery.initRaw(std.testing.allocator, conn, "t", undefined, undefined, undefined);
    const colA = columnMod.DynamicColumn{ .name = "a" };
    const colB = columnMod.DynamicColumn{ .name = "b" };
    const single = base.orderBy(colA.asc());
    try std.testing.expectEqual(@as(usize, 1), single.orderCount);
    try std.testing.expectEqualStrings("a", single.orders[0].column.name);
    try std.testing.expect(!single.orders[0].descending);
    const pair = .{ colA.desc(), colB.asc() };
    const multi = base.orderBy(pair);
    try std.testing.expectEqual(@as(usize, 2), multi.orderCount);
    try std.testing.expectEqualStrings("a", multi.orders[0].column.name);
    try std.testing.expect(multi.orders[0].descending);
    try std.testing.expectEqualStrings("b", multi.orders[1].column.name);
    try std.testing.expect(!multi.orders[1].descending);
    const chained = base.orderBy(colA.asc()).orderBy(colB.desc());
    try std.testing.expectEqual(@as(usize, 2), chained.orderCount);
    try std.testing.expect(!chained.orders[0].descending);
    try std.testing.expect(chained.orders[1].descending);
    const compound = CompoundBuilder(void, void, false){ .allocator = std.testing.allocator, .connection = conn, .compoundExecuteFn = undefined };
    const compoundOrdered = compound.orderBy(pair);
    try std.testing.expectEqual(@as(usize, 2), compoundOrdered.orderCount);
    try std.testing.expect(compoundOrdered.orders[0].descending);
    try std.testing.expect(!compoundOrdered.orders[1].descending);
}

test "select preserves projection order and AllColumns routing" {
    const conn = @as(*anyopaque, @ptrFromInt(0x1000));
    const base = DynamicQuery.initRaw(std.testing.allocator, conn, "t", undefined, undefined, undefined);
    const colA = columnMod.DynamicColumn{ .name = "b" };
    const colB = columnMod.DynamicColumn{ .name = "a" };
    // Explicit projections keep caller order (engine maps columns positionally).
    const ordered = base.select(.{ colA, colB });
    try std.testing.expectEqual(@as(usize, 2), ordered.projectionCount);
    try std.testing.expect(!@TypeOf(ordered).isMapped);
    try std.testing.expectEqualStrings("b", ordered.projections[0].column.name);
    try std.testing.expectEqualStrings("a", ordered.projections[1].column.name);
    // Operation-named columns flow through select() as ordinary fields.
    const weird = base.select(.{columnMod.DynamicColumn{ .name = "where" }});
    try std.testing.expectEqualStrings("where", weird.projections[0].column.name);
    // AllColumns marker routes to the mapped star builder (native wildcard).
    const T = @import("table.zig").table("t", struct { id: i64, name: []const u8 });
    const Star = @import("table.zig").AllProjection;
    try std.testing.expect(@TypeOf(Star{}) == Star);
    const starBase = DynamicQuery.initRaw(std.testing.allocator, conn, "t", undefined, undefined, undefined);
    const all = starBase.selectAll();
    try std.testing.expect(all.allColumns);
    try std.testing.expectEqual(@as(usize, 0), all.projectionCount);
    _ = T;
}
