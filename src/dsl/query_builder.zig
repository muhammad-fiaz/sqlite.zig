//! Value-semantic query and mutation builders over the native AST.
//!
//! Builders are copies that borrow names; `fetch`/`execute` return owned results.
//! The connection must outlive every builder and result.
//! Overflow panics; execution returns engine errors.

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
const scopeMod = @import("scope.zig");
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

pub const JoinKind = astBuilder.JoinKind;

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
    if (comptime isTypedColumnInstance(T)) return .{ .table = columnMod.qualifiedTable(item), .name = T.dslName };
    @compileError("expected a column descriptor (User.id or table.column(\"x\"))");
}

fn toOrder(item: anytype) Order {
    const T = @TypeOf(item);
    if (T == Order) return item;
    if (T == columnMod.DynamicColumn) return .{ .column = columnMod.dynRef(item) };
    if (comptime isTypedColumnInstance(T)) return .{ .column = .{ .table = columnMod.qualifiedTable(item), .name = T.dslName } };
    @compileError("orderBy() takes a column order such as col.asc()/col.desc(), a bare column, or a scoped field such as .name");
}

/// True for one assign-tuple element: a typed `Column.set(...)` assign or
/// a dynamic `column(...).set(...)` assign.
fn isAssignItem(comptime T: type) bool {
    return columnMod.isAssignValue(T) or columnMod.isDynAssignValue(T);
}

/// True when `assigns` is an explicit-assignment tuple: every element is an
/// assign carrying its own table identity (see `column.zig.Assign` and
/// `column.zig.DynAssign`). Empty tuples are rows, not assigns.
fn isAssignList(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct" or !info.@"struct".is_tuple) return false;
    if (info.@"struct".fields.len == 0) return false;
    inline for (info.@"struct".fields) |field| {
        if (!isAssignItem(field.type)) return false;
    }
    return true;
}

/// Runtime duplicate-target guard shared by typed and dynamic assigns
/// (covers mixed tuples, where comptime names are unavailable).
fn checkDuplicateName(names: []const []const u8, dest: []const u8) !void {
    for (names) |existing| if (std.mem.eql(u8, existing, dest)) return error.InvalidSql;
}

/// Runtime scope check for one dynamic assign: a set qualifier must be the
/// statement's table (real name or alias); empty qualifiers bind to the
/// target table by SQLite's own single-table rules.
fn checkDynAssignScope(item: anytype, table: []const u8, tableAlias: ?[]const u8) !void {
    if (item.table.len == 0) return;
    if (std.mem.eql(u8, item.table, table)) return;
    if (tableAlias) |alias| if (std.mem.eql(u8, item.table, alias)) return;
    return error.UnknownColumn;
}

/// Runtime membership check for one dynamic assign on a typed target: the
/// SQL name must be a column of the statement target. Dynamic targets
/// (`Columns == void`) stay unchecked by design.
fn checkDynAssignColumn(comptime Columns: type, name: []const u8) !void {
    if (Columns == void) return;
    inline for (@typeInfo(Columns).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.type.dslName, name)) return;
    }
    return error.UnknownColumn;
}

/// Comptime membership test for one explicit assignment: its SQL name must
/// be a column of the statement target. Cross-table assigns with disjoint
/// names fail at the call site. NOTE: callers must gate on
/// `if (comptime ...)` explicitly — a runtime `if (eql) return` does not
/// prune a trailing `@compileError` during analysis.
fn hasAssignColumn(comptime Col: type, comptime Columns: type) bool {
    if (Columns == void) return true;
    inline for (@typeInfo(Columns).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.type.dslName, Col.dslName)) return true;
    }
    return false;
}

/// Comptime duplicate test for assign tuple element `index`: true when an
/// earlier *typed* element targets the same SQL column. Dynamic elements
/// carry runtime names, so they (and mixed pairs) are covered by the
/// runtime `checkDuplicateName`/inline sweeps at each use site instead.
/// Callers gate explicitly.
fn hasDuplicateAssign(comptime Tuple: type, comptime index: usize) bool {
    const fields = @typeInfo(Tuple).@"struct".fields;
    const needleT = fields[index].type;
    if (comptime !columnMod.isAssignValue(needleT)) return false;
    const needle = needleT.assignColumn.dslName;
    inline for (0..index) |prev| {
        const candT = fields[prev].type;
        if (comptime !columnMod.isAssignValue(candT)) continue;
        if (std.mem.eql(u8, candT.assignColumn.dslName, needle)) return true;
    }
    return false;
}

/// Runtime scope check for one explicit assignment: its table identity must
/// be the statement's table (by real name or by the builder's alias).
/// Same-named columns of other tables fail here, never binding silently.
fn checkAssignScope(comptime Col: type, table: []const u8, tableAlias: ?[]const u8) !void {
    if (std.mem.eql(u8, Col.dslTable, table)) return;
    if (tableAlias) |alias| if (std.mem.eql(u8, Col.dslTable, alias)) return;
    return error.UnknownColumn;
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
    if (comptime isTypedColumnInstance(T)) return .{ .column = .{ .table = columnMod.qualifiedTable(value), .name = T.dslName } };
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

fn tryHavingCond(cond: anytype) ?dslExpr.HavingCond {
    const T = @TypeOf(cond);
    if (T == dslExpr.HavingCond) return cond;
    if (T == dslExpr.Expr) return havingCondFromExpr(cond);
    @compileError("having() takes an aggregate/scalar comparison such as col.count().gt(1) or a column predicate");
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

/// Value-semantic query builder. Chaining returns copies; results are owned.
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
        havingEntries: [8]astBuilder.HavingEntry = undefined,
        havingCount: usize = 0,
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

        /// Scoped columns value for this query's root table
        /// (`q.c().id.eq(1)`, `q.c().name`). Each field is the table's
        /// typed column bound to the current scope: the builder's alias when
        /// set, else its table name. The valid-Zig form of scoped `.id`
        /// references for predicate positions (`where`, `having`, `join`
        /// conditions), where a bare `.id` cannot carry an operator. Only
        /// available on typed builders; dynamic queries use `column(name)`.
        pub fn c(self: Self) Columns {
            if (Columns == void) return {};
            var scoped: Columns = undefined;
            inline for (@typeInfo(Columns).@"struct".fields) |field| {
                // Stamp the runtime scope: the alias when set, else null
                // (which keeps the type-level table identity).
                var col: field.type = .{};
                col.qualifier = self.tableAlias;
                @field(scoped, field.name) = col;
            }
            return scoped;
        }

        /// Rebind this query to `alias` (borrowed slice must outlive use),
        /// the builder-level form of `sqlite.aliased(Table, "alias")`.
        /// Scoped references (`col()`, `.{ .id }` lists) qualify with the
        /// alias from here on; explicit `Table.col` references keep the real
        /// table name, which stays valid SQL against `FROM table alias`.
        pub fn as(self: Self, alias: []const u8) Self {
            var copy = self;
            copy.tableAlias = alias;
            return copy;
        }

        /// This builder's resolver scope: alias when set, else table name.
        fn scope(self: *const Self) scopeMod.Scope {
            return scopeMod.builderScope(self.table, self.tableAlias);
        }

        /// Resolve one scoped field (`.id`) to a native `ColumnRef`.
        fn scopedRef(self: *const Self, item: anytype) ColumnRef {
            return scopeMod.resolveRef(Row, Columns, self.scope(), item);
        }

        /// Resolve one scoped field to a SELECT/RETURNING projection.
        fn scopedProjection(self: *const Self, item: anytype) Projection {
            return .{ .kind = .column, .column = self.scopedRef(item) };
        }

        /// Resolve one scoped field to an ascending ORDER BY key.
        fn scopedOrder(self: *const Self, item: anytype) Order {
            return .{ .column = self.scopedRef(item) };
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
                .havingEntries = self.havingEntries,
                .havingCount = self.havingCount,
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
            // Scoped single field (`select(.id)`): resolves against the
            // root table, equivalent to `select(.{ Table.id })`.
            if (Row != void and comptime scopeMod.isScopedItem(T, Row)) {
                return copy.selectOne(copy.scopedProjection(cols));
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
                // Scoped (`.id`) and explicit (`Table.id`) items mix freely;
                // both converge on the same native projection.
                if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(item), Row)) {
                    copy.projections[copy.projectionCount] = copy.scopedProjection(item);
                } else {
                    copy.projections[copy.projectionCount] = toProjection(item);
                }
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
            // Scoped single field (`returning(.id)`).
            if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(cols), Row)) {
                copy.returningCols[0] = copy.scopedProjection(cols);
                copy.returningCount = 1;
                return copy;
            }
            const items = if (@typeInfo(@TypeOf(cols)) == .pointer) cols.* else cols;
            inline for (items) |item| {
                if (@TypeOf(item) == CaseBuilder) {
                    storeCaseProjection(&copy.cases, &copy.caseCount, copy.returningCols[0..], &copy.returningCount, item);
                    continue;
                }
                if (@TypeOf(item) == WindowBuilder) @panic("window functions are not supported in RETURNING");
                if (copy.returningCount >= copy.returningCols.len) @panic("too many DSL returning columns");
                if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(item), Row)) {
                    copy.returningCols[copy.returningCount] = copy.scopedProjection(item);
                } else {
                    copy.returningCols[copy.returningCount] = toProjection(item);
                }
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
            // Scoped target (`whereInValues(.id, &.{ 1, 2 })`) resolves
            // against the root table like every other scoped field.
            const target: ColumnRef = if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(col), Row)) copy.scopedRef(col) else toRef(col);
            var entry = LiteralIn{ .column = target, .negated = negated };
            inline for (items) |item| {
                if (entry.count >= entry.values.len) @panic("DSL IN supports at most 32 literal values");
                entry.values[entry.count] = columnMod.toValue(item);
                entry.count += 1;
            }
            if (entry.count == 0) @panic("IN requires at least one value");
            copy.literalIn = entry;
            return copy;
        }

        /// Outer column may be scoped (`.id` binds to this query's root
        /// table); the subquery column stays explicit since the inner scope
        /// belongs to `other`.
        pub fn whereInQuery(self: Self, col: anytype, other: anytype, otherCol: anytype) Self {
            var copy = self;
            const target = joinTargetOf(other);
            const outer: ColumnRef = if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(col), Row)) copy.scopedRef(col) else toRef(col);
            copy.inQuery = .{ .column = outer, .table = target.name, .schema = target.schema, .subcolumn = toRef(otherCol) };
            return copy;
        }

        pub fn whereNotInQuery(self: Self, col: anytype, other: anytype, otherCol: anytype) Self {
            var copy = self;
            const target = joinTargetOf(other);
            const outer: ColumnRef = if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(col), Row)) copy.scopedRef(col) else toRef(col);
            copy.inQuery = .{ .column = outer, .table = target.name, .schema = target.schema, .subcolumn = toRef(otherCol), .negated = true };
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

        /// Order by explicit orders/descriptors (`User.id.desc()`), ascending
        /// scoped fields (`orderBy(.name)`, `orderBy(.{ .name })`), or a
        /// tuple mixing both. Scoped fields resolve against the root table.
        pub fn orderBy(self: Self, order: anytype) Self {
            var copy = self;
            const T = @TypeOf(order);
            if (Row != void and comptime scopeMod.isScopedItem(T, Row)) {
                if (copy.orderCount >= copy.orders.len) @panic("too many order columns");
                copy.orders[copy.orderCount] = copy.scopedOrder(order);
                copy.orderCount += 1;
                return copy;
            }
            if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
                inline for (order) |item| {
                    if (copy.orderCount >= copy.orders.len) @panic("too many order columns");
                    if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(item), Row)) {
                        copy.orders[copy.orderCount] = copy.scopedOrder(item);
                    } else {
                        copy.orders[copy.orderCount] = toOrder(item);
                    }
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

        /// Group by an explicit descriptor (`User.id`), a dynamic column, or
        /// a scoped field (`groupBy(.id)`, `groupBy(.{ .id })`) resolved
        /// against the root table. The engine groups by one column; longer
        /// scoped lists are compile errors.
        pub fn groupBy(self: Self, col: anytype) Self {
            var copy = self;
            const T = @TypeOf(col);
            if (Row != void and comptime scopeMod.isScopedItem(T, Row)) {
                copy.groupByColumn = copy.scopedRef(col);
                return copy;
            }
            if (Row != void and comptime scopeMod.isScopedList(T, Row)) {
                const items = if (@typeInfo(T) == .pointer) col.* else col;
                if (items.len != 1) @panic("groupBy() takes one column; pass a single descriptor or one scoped field");
                copy.groupByColumn = copy.scopedRef(items[0]);
                return copy;
            }
            copy.groupByColumn = toRef(col);
            return copy;
        }

        pub fn having(self: Self, cond: anytype) Self {
            var copy = self;
            copy.havingCount = 0;
            const parsed = tryHavingCond(cond) orelse {
                copy.havingValid = false;
                return copy;
            };
            copy.havingEntries[0] = .{ .cond = parsed };
            copy.havingCount = 1;
            copy.havingValid = true;
            return copy;
        }

        pub fn andHaving(self: Self, cond: anytype) Self {
            return self.appendHaving(cond, false);
        }

        pub fn orHaving(self: Self, cond: anytype) Self {
            return self.appendHaving(cond, true);
        }

        fn appendHaving(self: Self, cond: anytype, joinOr: bool) Self {
            var copy = self;
            const parsed = tryHavingCond(cond) orelse {
                copy.havingValid = false;
                copy.havingCount = 0;
                return copy;
            };
            if (!copy.havingValid) return copy;
            if (copy.havingCount == 0) {
                copy.havingEntries[0] = .{ .cond = parsed };
                copy.havingCount = 1;
                return copy;
            }
            if (copy.havingCount >= copy.havingEntries.len) @panic("too many DSL having predicates");
            copy.havingEntries[copy.havingCount] = .{ .cond = parsed, .joinOr = joinOr };
            copy.havingCount += 1;
            return copy;
        }

        /// Join with an explicit kind (`db.from(u).join(m, .inner, on)`).
        /// Forwards to the dedicated `innerJoin`/`leftJoin`/… variants.
        pub fn join(self: Self, other: anytype, kind: JoinKind, on: Expr) Self {
            return self.joinAs(other, on, kind);
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
            } else if (Row != void and comptime scopeMod.isScopedItem(T, Row)) {
                // Scoped single (`joinUsing(Member, .user_id)`): USING names
                // are bare by SQL rules; scope only maps zig to sql names.
                copy.joinUsingCols[0] = copy.scopedRef(col).name;
                copy.joinUsingCount = 1;
            } else if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
                inline for (col) |item| {
                    if (copy.joinUsingCount >= copy.joinUsingCols.len) @panic("too many USING columns");
                    const IT = @TypeOf(item);
                    if (IT == columnMod.DynamicColumn) {
                        copy.joinUsingCols[copy.joinUsingCount] = columnMod.dynRef(item).name;
                    } else if (comptime isTypedColumnInstance(IT)) {
                        copy.joinUsingCols[copy.joinUsingCount] = IT.dslName;
                    } else if (Row != void and comptime scopeMod.isScopedItem(IT, Row)) {
                        copy.joinUsingCols[copy.joinUsingCount] = copy.scopedRef(item).name;
                    } else {
                        @compileError("joinUsing columns must be column descriptors or scoped fields such as .user_id");
                    }
                    copy.joinUsingCount += 1;
                }
                if (copy.joinUsingCount == 0) @panic("joinUsing requires at least one column");
            } else {
                @compileError("joinUsing column must be a column descriptor, a scoped field, or a tuple of those");
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
            // Scoped mapping values (`insertFrom(Src, .{ .dst = .src })`)
            // resolve against the source table's own scope when typed.
            inline for (mapFields) |mapField| {
                const destSql: []const u8 = if (Columns == void)
                    mapField.name
                else
                    destSqlFor(Columns, mapField.name) orelse return error.InvalidSql;
                const mapValue = @field(mapping, mapField.name);
                var proj: Projection = if (comptime !isDynamicSource and @import("table.zig").isTableValue(SourceT) and scopeMod.isScopedItem(@TypeOf(mapValue), @import("table.zig").rowTypeOfValue(SourceT)))
                    .{
                        .kind = .column,
                        .column = scopeMod.resolveRef(
                            @import("table.zig").rowTypeOfValue(SourceT),
                            @import("table.zig").columnsTypeOfValue(SourceT),
                            scopeMod.builderScope(source.tableName, if (source.tableAlias.len != 0) source.tableAlias else null),
                            mapValue,
                        ),
                    }
                else
                    toProjection(mapValue);
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
            var up = UpsertBuilder(Row, Columns){
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .table = self.table,
                .schema = self.schema,
                .tableAlias = self.tableAlias,
                .cases = self.cases,
                .caseCount = self.caseCount,
                .caseWhens = self.caseWhens,
                .caseWhenCount = self.caseWhenCount,
                .returningCols = self.returningCols,
                .returningCount = self.returningCount,
            };
            // Predicates staged before onConflict/doNothing/doUpdate carry
            // over instead of dropping silently (see delete()).
            if (self.conditionCount > up.upsertConds.len) @panic("too many upsert predicates");
            @memcpy(up.upsertConds[0..self.conditionCount], self.conditions[0..self.conditionCount]);
            up.upsertCondCount = self.conditionCount;
            return up;
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
            } else if (Row != void and comptime scopeMod.isScopedItem(T, Row)) {
                // Scoped single target (`onConflict(.id)`): resolves against
                // the upsert's target table.
                up.targetCols[0] = scopeMod.resolveRef(Row, Columns, self.scope(), target).name;
                up.targetCount = 1;
            } else if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
                inline for (target) |item| {
                    if (up.targetCount >= up.targetCols.len) @panic("too many upsert target columns");
                    const IT = @TypeOf(item);
                    if (IT == columnMod.DynamicColumn) {
                        up.targetCols[up.targetCount] = columnMod.dynRef(item).name;
                    } else if (comptime isTypedColumnInstance(IT)) {
                        up.targetCols[up.targetCount] = IT.dslName;
                    } else if (Row != void and comptime scopeMod.isScopedItem(IT, Row)) {
                        up.targetCols[up.targetCount] = scopeMod.resolveRef(Row, Columns, self.scope(), item).name;
                    } else {
                        @compileError("onConflict target must be column descriptors or scoped fields such as .id");
                    }
                    up.targetCount += 1;
                }
                if (up.targetCount == 0) @panic("onConflict requires at least one target column");
            } else {
                @compileError("onConflict target must be a column descriptor, a scoped field, or a tuple of those");
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

        /// Explicit-assignment INSERT (`insert(.{ User.id.set(1), ... })`).
        /// Each assign carries its own table identity, checked against this
        /// statement's table (real name or alias); omitted columns follow
        /// normal default semantics, exactly like partial row structs.
        fn insertAssigns(self: Self, assigns: anytype, conflict: ast.ConflictPolicy) !Result {
            var names: [16][]const u8 = undefined;
            var vals: [16]dslExpr.SetValue = undefined;
            var count: usize = 0;
            const AssignsType = @TypeOf(assigns);
            inline for (assigns, 0..) |item, index| {
                // Dynamic assigns resolve at setup time against the same
                // target contract; typed assigns resolve at compile time.
                if (comptime columnMod.isDynAssignValue(@TypeOf(item))) {
                    try checkDynAssignScope(item, self.table, self.tableAlias);
                    try checkDynAssignColumn(Columns, item.name);
                    if (comptime isExplicitDefault(@TypeOf(item.value))) continue;
                    if (@TypeOf(item.value) == columnMod.ExcludedColumn) @compileError("excluded() is only valid in UPSERT assignments");
                    if (count >= names.len) return error.InvalidSql;
                    try checkDuplicateName(names[0..count], item.name);
                    names[count] = item.name;
                    vals[count] = .{ .literal = insertFieldOf(item.value) };
                    count += 1;
                    continue;
                }
                const Col = @TypeOf(item).assignColumn;
                if (comptime !hasAssignColumn(Col, Columns)) @compileError("assignment column is not a column of the statement target table");
                // Same column twice is most likely a copy/paste slip; SQL
                // rejects duplicate targets, so fail loudly here too.
                if (comptime hasDuplicateAssign(AssignsType, index)) @compileError("duplicate assignment to one column in an explicit assign list");
                try checkAssignScope(Col, self.table, self.tableAlias);
                if (comptime isExplicitDefault(@TypeOf(item.value))) continue;
                if (@TypeOf(item.value) == columnMod.ExcludedColumn) @compileError("excluded() is only valid in UPSERT assignments");
                if (count >= names.len) return error.InvalidSql;
                try checkDuplicateName(names[0..count], Col.dslName);
                names[count] = Col.dslName;
                vals[count] = .{ .literal = insertFieldOf(item.value) };
                count += 1;
            }
            if (count == 0) return error.InvalidSql;
            var built = try astBuilder.buildInsert(self.allocator, self.table, self.schema, names[0..count], vals[0..count], conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{});
            defer built.deinit();
            return self.executeFn(self.connection, &built.stmt, &.{}, false);
        }

        fn insertWithMode(self: Self, row: anytype, comptime mode: []const u8) !Result {
            const conflict: ast.ConflictPolicy = if (comptime std.mem.eql(u8, mode, "")) .none else if (comptime std.mem.eql(u8, mode, "OR IGNORE")) .ignore else if (comptime std.mem.eql(u8, mode, "OR REPLACE")) .replace else if (comptime std.mem.eql(u8, mode, "OR ABORT")) .abort else if (comptime std.mem.eql(u8, mode, "OR FAIL")) .fail else if (comptime std.mem.eql(u8, mode, "OR ROLLBACK")) .rollback else @compileError("unknown insert mode");
            const RowType = @TypeOf(row);
            if (comptime isAssignList(RowType)) return self.insertAssigns(row, conflict);
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
            var mutation = Mutation{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .table = self.table,
                .schema = self.schema,
                .operation = .update,
                .conditions = self.conditions,
                .conditionCount = self.conditionCount,
                .cases = self.cases,
                .caseCount = self.caseCount,
                .caseWhens = self.caseWhens,
                .caseWhenCount = self.caseWhenCount,
                .returningCols = self.returningCols,
                .returningCount = self.returningCount,
            };
            // Explicit assignments (`update(.{ User.name.set("x"),
            // User.age.set(User.age.add(1)) })`): targets carry table
            // identity; expressions distinguish target from value natively.
            if (comptime isAssignList(RowType)) {
                inline for (assignments, 0..) |item, index| {
                    if (comptime columnMod.isDynAssignValue(@TypeOf(item))) {
                        try checkDynAssignScope(item, self.table, self.tableAlias);
                        try checkDynAssignColumn(Columns, item.name);
                        if (comptime isExplicitDefault(@TypeOf(item.value))) continue;
                        if (@TypeOf(item.value) == columnMod.ExcludedColumn) @compileError("excluded() is only valid in UPSERT assignments");
                        if (mutation.setCount >= mutation.setNames.len) return error.InvalidSql;
                        try checkDuplicateName(mutation.setNames[0..mutation.setCount], item.name);
                        mutation.setNames[mutation.setCount] = item.name;
                        mutation.setValues[mutation.setCount] = setValueOf(item.value);
                        mutation.setCount += 1;
                        continue;
                    }
                    const Col = @TypeOf(item).assignColumn;
                    if (comptime !hasAssignColumn(Col, Columns)) @compileError("assignment column is not a column of the statement target table");
                    if (comptime hasDuplicateAssign(RowType, index)) @compileError("duplicate assignment to one column in an explicit assign list");
                    try checkAssignScope(Col, self.table, self.tableAlias);
                    if (comptime isExplicitDefault(@TypeOf(item.value))) continue;
                    if (@TypeOf(item.value) == columnMod.ExcludedColumn) @compileError("excluded() is only valid in UPSERT assignments");
                    if (mutation.setCount >= mutation.setNames.len) return error.InvalidSql;
                    try checkDuplicateName(mutation.setNames[0..mutation.setCount], Col.dslName);
                    mutation.setNames[mutation.setCount] = Col.dslName;
                    mutation.setValues[mutation.setCount] = setValueOf(item.value);
                    mutation.setCount += 1;
                }
                if (mutation.setCount == 0) return error.InvalidSql;
                return mutation;
            }
            validateRow(RowType);
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

        /// Predicates staged with `where()` before `delete()` carry over, so
        /// `db.from(User).where(.id.eq(1))` and `db.from(User).where(User.id
        /// .eq(1))` both delete exactly that row; previously the predicate
        /// was silently dropped into a full-table delete.
        pub fn delete(self: Self) Mutation {
            return .{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .table = self.table,
                .schema = self.schema,
                .operation = .delete,
                .conditions = self.conditions,
                .conditionCount = self.conditionCount,
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
    havingEntries: [8]astBuilder.HavingEntry = undefined,
    havingCount: usize = 0,
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
    havingEntries: [8]astBuilder.HavingEntry = undefined,
    havingCount: usize = 0,
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
        .havingEntries = source.havingEntries,
        .havingCount = source.havingCount,
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
        .havingEntries = source.havingEntries,
        .havingCount = source.havingCount,
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
        .havingEntries = sub.havingEntries,
        .havingCount = sub.havingCount,
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
        .having = snapshot.havingEntries[0..snapshot.havingCount],
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
        tableAlias: ?[]const u8 = null,
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

        /// Scoped columns value for the upsert target table (`up.c().id`).
        /// See `Builder.c` for the scoping contract.
        pub fn c(self: Self) Columns {
            if (Columns == void) return {};
            var scoped: Columns = undefined;
            inline for (@typeInfo(Columns).@"struct".fields) |field| {
                var col: field.type = .{};
                col.qualifier = self.tableAlias;
                @field(scoped, field.name) = col;
            }
            return scoped;
        }

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
            // Scoped single field (`returning(.id)`): resolves against the
            // upsert's target table.
            if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(cols), Row)) {
                copy.returningCols[0] = .{ .kind = .column, .column = scopeMod.resolveRef(Row, Columns, scopeMod.builderScope(self.table, self.tableAlias), cols) };
                copy.returningCount = 1;
                return copy;
            }
            const items = if (@typeInfo(@TypeOf(cols)) == .pointer) cols.* else cols;
            inline for (items) |item| {
                if (@TypeOf(item) == CaseBuilder) {
                    storeCaseProjection(&copy.cases, &copy.caseCount, copy.returningCols[0..], &copy.returningCount, item);
                    continue;
                }
                if (@TypeOf(item) == WindowBuilder) @panic("window functions are not supported in RETURNING");
                if (copy.returningCount >= copy.returningCols.len) @panic("too many DSL returning columns");
                if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(item), Row)) {
                    copy.returningCols[copy.returningCount] = .{ .kind = .column, .column = scopeMod.resolveRef(Row, Columns, scopeMod.builderScope(self.table, self.tableAlias), item) };
                } else {
                    copy.returningCols[copy.returningCount] = toProjection(item);
                }
                copy.returningCount += 1;
            }
            if (copy.returningCount == 0) @panic("returning() requires at least one column");
            return copy;
        }

        fn extractSets(self: *Self, assignments: anytype) !void {
            const RowType = @TypeOf(assignments);
            if (@typeInfo(RowType) != .@"struct") @compileError("DSL row must be a struct");
            // Explicit UPSERT assignments (`doUpdate(.{ User.name.set("x"),
            // User.age.set(db.excluded("age")) })`): `excluded()` markers,
            // arithmetic, and column references all pass through natively.
            if (comptime isAssignList(RowType)) {
                self.setCount = 0;
                inline for (assignments, 0..) |item, index| {
                    if (comptime columnMod.isDynAssignValue(@TypeOf(item))) {
                        try checkDynAssignScope(item, self.table, self.tableAlias);
                        try checkDynAssignColumn(Columns, item.name);
                        if (comptime isExplicitDefault(@TypeOf(item.value))) continue;
                        if (self.setCount >= self.sets.len) return error.InvalidSql;
                        for (self.sets[0..self.setCount]) |existing| if (std.mem.eql(u8, existing.name, item.name)) return error.InvalidSql;
                        self.sets[self.setCount] = .{ .name = item.name, .value = upsertValueOf(item.value) };
                        self.setCount += 1;
                        continue;
                    }
                    const Col = @TypeOf(item).assignColumn;
                    if (comptime !hasAssignColumn(Col, Columns)) @compileError("assignment column is not a column of the statement target table");
                    if (comptime hasDuplicateAssign(RowType, index)) @compileError("duplicate assignment to one column in an explicit assign list");
                    try checkAssignScope(Col, self.table, self.tableAlias);
                    if (comptime isExplicitDefault(@TypeOf(item.value))) continue;
                    if (self.setCount >= self.sets.len) return error.InvalidSql;
                    for (self.sets[0..self.setCount]) |existing| if (std.mem.eql(u8, existing.name, Col.dslName)) return error.InvalidSql;
                    self.sets[self.setCount] = .{ .name = Col.dslName, .value = upsertValueOf(item.value) };
                    self.setCount += 1;
                }
                if (self.setCount == 0) return error.InvalidSql;
                return;
            }
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
    if (comptime isTypedColumnInstance(T)) return .{ .set = .{ .column = .{ .table = columnMod.qualifiedTable(value), .name = T.dslName } } };
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

test "scoped and explicit selects converge on one projection" {
    const conn = @as(*anyopaque, @ptrFromInt(0x1000));
    const T = @import("table.zig").table("scope_users", struct { id: i64, name: []const u8 });
    const base = Query(@TypeOf(T)).initRaw(std.testing.allocator, conn, "scope_users", undefined, undefined, undefined);
    const scoped = base.select(.{ .id, .name });
    const explicit = base.select(.{ T.id, T.name });
    try std.testing.expectEqual(@as(usize, 2), scoped.projectionCount);
    try std.testing.expectEqual(@as(usize, 2), explicit.projectionCount);
    // Same native shape: column kind, scope table, and sql name agree.
    for ([_]usize{ 0, 1 }) |i| {
        try std.testing.expect(scoped.projections[i].kind == .column);
        try std.testing.expectEqualStrings(explicit.projections[i].column.table, scoped.projections[i].column.table);
        try std.testing.expectEqualStrings(explicit.projections[i].column.name, scoped.projections[i].column.name);
    }
    try std.testing.expectEqualStrings("scope_users", scoped.projections[0].column.table);
    try std.testing.expectEqualStrings("id", scoped.projections[0].column.name);
    // Single scoped field behaves like a one element list.
    const one = base.select(.id);
    try std.testing.expectEqual(@as(usize, 1), one.projectionCount);
    try std.testing.expectEqualStrings("id", one.projections[0].column.name);
    // Mixed scoped + explicit items keep position and identity.
    const mixed = base.select(.{ .id, T.name });
    try std.testing.expectEqualStrings("scope_users", mixed.projections[0].column.table);
    try std.testing.expectEqualStrings("scope_users", mixed.projections[1].column.table);
}

test "scoped references follow the builder alias" {
    const conn = @as(*anyopaque, @ptrFromInt(0x1000));
    const T = @import("table.zig").table("scope_users", struct { id: i64, name: []const u8 });
    const base = Query(@TypeOf(T)).initRaw(std.testing.allocator, conn, "scope_users", undefined, undefined, undefined);
    const aliased = base.as("u");
    try std.testing.expectEqualStrings("u", aliased.tableAlias.?);
    try std.testing.expectEqualStrings("scope_users", aliased.table);
    // Scoped list qualifies with the alias; explicit keeps the table name.
    const scoped = aliased.select(.{.id});
    try std.testing.expectEqualStrings("u", scoped.projections[0].column.table);
    const explicit = aliased.select(.{T.id});
    try std.testing.expectEqualStrings("scope_users", explicit.projections[0].column.table);
    // The scoped columns value binds predicates to the alias too.
    const pred = aliased.c().id.eq(1);
    try std.testing.expectEqualStrings("u", pred.column.table);
    try std.testing.expectEqualStrings("id", pred.column.name);
    const plain = base.c().name.eq("x");
    try std.testing.expectEqualStrings("scope_users", plain.column.table);
}

test "scoped order group returning and join keys resolve" {
    const conn = @as(*anyopaque, @ptrFromInt(0x1000));
    const T = @import("table.zig").table("scope_users", struct { id: i64, name: []const u8 });
    const base = Query(@TypeOf(T)).initRaw(std.testing.allocator, conn, "scope_users", undefined, undefined, undefined);
    const ordered = base.orderBy(.{ .name, T.id.desc() });
    try std.testing.expectEqual(@as(usize, 2), ordered.orderCount);
    try std.testing.expectEqualStrings("name", ordered.orders[0].column.name);
    try std.testing.expect(!ordered.orders[0].descending);
    try std.testing.expect(ordered.orders[1].descending);
    const single = base.orderBy(.id);
    try std.testing.expectEqualStrings("id", single.orders[0].column.name);
    const grouped = base.groupBy(.{.id});
    try std.testing.expectEqualStrings("id", grouped.groupByColumn.?.name);
    try std.testing.expectEqualStrings("scope_users", grouped.groupByColumn.?.table);
    const ret = base.returning(.{ .id, T.name });
    try std.testing.expectEqual(@as(usize, 2), ret.returningCount);
    try std.testing.expectEqualStrings("id", ret.returningCols[0].column.name);
    const Other = @import("table.zig").table("scope_groups", struct { id: i64 });
    const joined = base.joinUsing(Other, .id);
    try std.testing.expectEqual(@as(usize, 1), joined.joinUsingCount);
    try std.testing.expectEqualStrings("id", joined.joinUsingCols[0]);
    const conflicted = base.onConflict(.id);
    try std.testing.expectEqual(@as(usize, 1), conflicted.targetCount);
    try std.testing.expectEqualStrings("id", conflicted.targetCols[0]);
    const inListed = base.whereInValues(.id, &[_]i64{ 1, 2 });
    try std.testing.expectEqualStrings("id", inListed.literalIn.?.column.name);
    try std.testing.expectEqualStrings("scope_users", inListed.literalIn.?.column.table);
}

test "explicit assigns carry table identity for writes" {
    const T = @import("table.zig").table("scope_users", struct { id: i64, name: []const u8 });
    const a = T.id.set(1);
    try std.testing.expect(columnMod.isAssignValue(@TypeOf(a)));
    try std.testing.expectEqualStrings("scope_users", @TypeOf(a).assignColumn.dslTable);
    try std.testing.expectEqualStrings("id", @TypeOf(a).assignColumn.dslName);
    try std.testing.expect(a.value == 1);
    const b = T.name.set("x");
    try std.testing.expectEqualStrings("x", b.value);
    // Arithmetic and column payloads pass through for expression updates.
    const arith = T.id.set(T.id.add(1));
    try std.testing.expect(@TypeOf(arith.value) == dslExpr.ArithExpr);
    // Plain values are not assigns; row structs stay the scoped write form.
    try std.testing.expect(!columnMod.isAssignValue(@TypeOf(1)));
    try std.testing.expect(!columnMod.isAssignValue(@TypeOf(.{ .id = 1 })));
}
