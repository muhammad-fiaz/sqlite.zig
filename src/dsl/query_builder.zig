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

pub fn Query(comptime TableType: type) type {
    return Builder(TableType.rowType, @TypeOf(TableType.columns), true);
}

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
    if (T == dslExpr.Order) @compileError("select() takes columns, not orders; pass col.asc()/col.desc() to orderBy()");
    if (comptime isTypedColumnInstance(T)) return item.projection();
    @compileError("select() takes column descriptors (User.columns.x / db.col(\"x\")) or their aggregates");
}

fn toRef(item: anytype) ColumnRef {
    const T = @TypeOf(item);
    if (T == columnMod.DynamicColumn) return columnMod.splitRef(item.name);
    if (comptime isTypedColumnInstance(T)) return .{ .table = T.dslTable, .name = T.dslName };
    @compileError("expected a column descriptor (User.columns.x or db.col(\"x\"))");
}

fn tableNameOf(other: anytype) []const u8 {
    const T = @TypeOf(other);
    if (T == type) {
        if (!@hasDecl(other, "tableName")) @compileError("join target must be a typed table or a table-name string");
        return other.tableName;
    }
    return other;
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

pub fn Builder(comptime Row: type, comptime Columns: type, comptime mapped: bool) type {
    return struct {
        const Self = @This();
        pub const isTyped = Row != void;
        pub const rowType = Row;
        pub const columnsType = Columns;
        pub const isMapped = mapped and isTyped;

        allocator: std.mem.Allocator,
        connection: *anyopaque,
        executeFn: astBuilder.ExecFn,
        compoundExecuteFn: astBuilder.CompoundExecFn,
        derivedExecuteFn: astBuilder.DerivedExecFn,
        table: []const u8,

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

        order: ?Order = null,
        limitValue: ?usize = null,
        offsetValue: ?usize = null,
        groupByColumn: ?ColumnRef = null,
        havingOp: ?[]const u8 = null,
        havingAmount: usize = 0,

        joinTable: ?[]const u8 = null,
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
            return .{ .allocator = connection.allocator, .connection = connection, .executeFn = executeFn, .compoundExecuteFn = compoundExecuteFn, .derivedExecuteFn = derivedExecuteFn, .table = table };
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

        fn retype(self: Self, comptime nextMapped: bool) Builder(Row, Columns, nextMapped) {
            return .{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .compoundExecuteFn = self.compoundExecuteFn,
                .derivedExecuteFn = self.derivedExecuteFn,
                .table = self.table,
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
                .order = self.order,
                .limitValue = self.limitValue,
                .offsetValue = self.offsetValue,
                .groupByColumn = self.groupByColumn,
                .havingOp = self.havingOp,
                .havingAmount = self.havingAmount,
                .joinTable = self.joinTable,
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

        pub fn select(self: Self, cols: anytype) Builder(Row, Columns, false) {
            var copy = self.retype(false);
            copy.allColumns = false;
            copy.projectionCount = 0;
            copy.caseCount = 0;
            copy.windowCount = 0;
            const items = if (@typeInfo(@TypeOf(cols)) == .pointer) cols.* else cols;
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
            copy.inQuery = .{ .column = toRef(col), .table = tableNameOf(other), .subcolumn = toRef(otherCol) };
            return copy;
        }

        pub fn whereNotInQuery(self: Self, col: anytype, other: anytype, otherCol: anytype) Self {
            var copy = self;
            copy.inQuery = .{ .column = toRef(col), .table = tableNameOf(other), .subcolumn = toRef(otherCol), .negated = true };
            return copy;
        }

        pub fn whereExists(self: Self, other: anytype, on: ?Expr) Self {
            var copy = self;
            copy.existsQuery = .{ .table = tableNameOf(other), .on = on };
            return copy;
        }

        pub fn whereNotExists(self: Self, other: anytype, on: ?Expr) Self {
            var copy = self;
            copy.existsQuery = .{ .table = tableNameOf(other), .on = on, .negated = true };
            return copy;
        }

        pub fn orderBy(self: Self, order: Order) Self {
            var copy = self;
            copy.order = order;
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

        pub fn havingCount(self: Self, operator: []const u8, amount: usize) Self {
            var copy = self;
            copy.havingOp = operator;
            copy.havingAmount = amount;
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
            copy.joinTable = tableNameOf(other);
            copy.joinKind = .cross;
            copy.joinOn = null;
            copy.joinUsingCount = 0;
            copy.joinNatural = false;
            return copy;
        }

        fn joinAs(self: Self, other: anytype, on: Expr, kind: JoinKind) Self {
            var copy = self;
            copy.joinTable = tableNameOf(other);
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
            copy.joinTable = tableNameOf(other);
            copy.joinKind = kind;
            copy.joinOn = null;
            copy.joinNatural = false;
            copy.joinUsingCount = 0;
            const T = @TypeOf(col);
            if (T == columnMod.DynamicColumn) {
                copy.joinUsingCols[0] = columnMod.splitRef(col.name).name;
                copy.joinUsingCount = 1;
            } else if (comptime isTypedColumnInstance(T)) {
                copy.joinUsingCols[0] = T.dslName;
                copy.joinUsingCount = 1;
            } else if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
                inline for (col) |item| {
                    if (copy.joinUsingCount >= copy.joinUsingCols.len) @panic("too many USING columns");
                    const IT = @TypeOf(item);
                    if (IT == columnMod.DynamicColumn) {
                        copy.joinUsingCols[copy.joinUsingCount] = columnMod.splitRef(item.name).name;
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
            copy.joinTable = tableNameOf(other);
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

        fn upsertBase(self: Self) UpsertBuilder(Row, Columns) {
            return .{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .table = self.table,
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
                up.targetCols[0] = columnMod.splitRef(target.name).name;
                up.targetCount = 1;
            } else if (comptime isTypedColumnInstance(T)) {
                up.targetCols[0] = T.dslName;
                up.targetCount = 1;
            } else if (comptime @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
                inline for (target) |item| {
                    if (up.targetCount >= up.targetCols.len) @panic("too many upsert target columns");
                    const IT = @TypeOf(item);
                    if (IT == columnMod.DynamicColumn) {
                        up.targetCols[up.targetCount] = columnMod.splitRef(item.name).name;
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
            const conflict: ast.InsertConflict = if (comptime std.mem.eql(u8, mode, "")) .none else if (comptime std.mem.eql(u8, mode, "OR IGNORE")) .ignore else if (comptime std.mem.eql(u8, mode, "OR REPLACE")) .replace else @compileError("unknown insert mode");
            const RowType = @TypeOf(row);
            validateRow(RowType);
            if (Columns == void) {
                const fields = @typeInfo(RowType).@"struct".fields;
                var names: [fields.len][]const u8 = undefined;
                var vals: [fields.len]Value = undefined;
                inline for (fields, 0..) |field, index| {
                    names[index] = field.name;
                    vals[index] = columnMod.toValue(@field(row, field.name));
                }
                var built = try astBuilder.buildInsert(self.allocator, self.table, &names, &vals, conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{});
                defer built.deinit();
                return self.executeFn(self.connection, &built.stmt, &.{}, false);
            } else {
                const colFields = @typeInfo(Columns).@"struct".fields;
                var names: [colFields.len][]const u8 = undefined;
                var vals: [colFields.len]Value = undefined;
                var count: usize = 0;
                inline for (colFields) |colField| {
                    if (@hasField(RowType, colField.name)) {
                        names[count] = colField.type.dslName;
                        vals[count] = columnMod.toValue(@field(row, colField.name));
                        count += 1;
                    }
                }
                if (count == 0) return error.InvalidSql;
                var built = try astBuilder.buildInsert(self.allocator, self.table, names[0..count], vals[0..count], conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{});
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
                    if (mutation.setCount >= mutation.setNames.len) return error.InvalidSql;
                    mutation.setNames[mutation.setCount] = field.name;
                    mutation.setValues[mutation.setCount] = columnMod.toValue(@field(assignments, field.name));
                    mutation.setCount += 1;
                }
            } else {
                inline for (@typeInfo(Columns).@"struct".fields) |colField| {
                    if (@hasField(RowType, colField.name)) {
                        if (mutation.setCount >= mutation.setNames.len) return error.InvalidSql;
                        mutation.setNames[mutation.setCount] = colField.type.dslName;
                        mutation.setValues[mutation.setCount] = columnMod.toValue(@field(assignments, colField.name));
                        mutation.setCount += 1;
                    }
                }
            }
            return mutation;
        }

        pub fn delete(self: Self) Mutation {
            return .{
                .allocator = self.allocator,
                .connection = self.connection,
                .executeFn = self.executeFn,
                .table = self.table,
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
        };

        fn fetchMapped(self: *const Self) !MappedResult {
            var result = try self.fetchRaw();
            defer result.deinit();
            const rows = try mapResultRows(Row, Columns, self.allocator, &result);
            return .{ .allocator = self.allocator, .rows = rows };
        }

        pub fn fetchOne(self: Self) !?Row {
            if (!isMapped) @compileError("fetchOne requires a typed full-row query");
            var single = try self.limit(1).fetchMapped();
            if (single.rows.len == 0) {
                single.deinit();
                return null;
            }
            const row = single.rows[0];
            self.allocator.free(single.rows);
            return row;
        }

        pub fn freeRow(self: *const Self, row: *Row) void {
            if (!isTyped) @compileError("freeRow requires a typed table");
            freeMappedRow(Row, self.allocator, row);
        }
    };
}

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
        order: ?Order = null,
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

        pub fn orderBy(self: Self, order: Order) Self {
            var copy = self;
            copy.order = order;
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
        };

        pub fn fetch(self: *const Self) !if (isMapped) MappedResult else Result {
            if (isMapped) return self.fetchMapped();
            return self.fetchRaw();
        }

        fn fetchRaw(self: *const Self) !Result {
            for (self.arms[0..self.armCount]) |snapshot| {
                if (snapshot.order != null or snapshot.limitValue != null or snapshot.offsetValue != null) return error.InvalidSql;
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
            var compoundOrder: ?ast.Order = null;
            if (self.order) |ord| {
                if (ord.function != null) return error.InvalidSql;
                compoundOrder = .{ .column = ord.column.name, .descending = ord.descending };
            }
            const result = try self.compoundExecuteFn(self.connection, armInputs[0..self.armCount], self.ops[0..self.opCount], compoundOrder, self.limitValue, self.offsetValue);
            for (builts[0..count]) |*built| built.deinit();
            return result;
        }

        fn fetchMapped(self: *const Self) !MappedResult {
            var result = try self.fetchRaw();
            defer result.deinit();
            const rows = try mapResultRows(Row, Columns, self.allocator, &result);
            return .{ .allocator = self.allocator, .rows = rows };
        }

        pub fn fetchOne(self: Self) !?Row {
            if (!isMapped) @compileError("fetchOne requires a typed full-row query");
            var single = try self.limit(1).fetchMapped();
            if (single.rows.len == 0) {
                single.deinit();
                return null;
            }
            const row = single.rows[0];
            self.allocator.free(single.rows);
            return row;
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
    order: ?Order = null,
    limitValue: ?usize = null,
    offsetValue: ?usize = null,
    groupByColumn: ?ColumnRef = null,
    havingOp: ?[]const u8 = null,
    havingAmount: usize = 0,
    joinTable: ?[]const u8 = null,
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
    order: ?Order = null,
    limitValue: ?usize = null,
    offsetValue: ?usize = null,
    groupByColumn: ?ColumnRef = null,
    havingOp: ?[]const u8 = null,
    havingAmount: usize = 0,
    joinTable: ?[]const u8 = null,
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
        .order = source.order,
        .limitValue = source.limitValue,
        .offsetValue = source.offsetValue,
        .groupByColumn = source.groupByColumn,
        .havingOp = source.havingOp,
        .havingAmount = source.havingAmount,
        .joinTable = source.joinTable,
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
        .order = source.order,
        .limitValue = source.limitValue,
        .offsetValue = source.offsetValue,
        .groupByColumn = source.groupByColumn,
        .havingOp = source.havingOp,
        .havingAmount = source.havingAmount,
        .joinTable = source.joinTable,
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
        .order = sub.order,
        .limitValue = sub.limitValue,
        .offsetValue = sub.offsetValue,
        .groupByColumn = sub.groupByColumn,
        .havingOp = sub.havingOp,
        .havingAmount = sub.havingAmount,
        .joinTable = sub.joinTable,
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
        .allColumns = snapshot.allColumns,
        .projections = snapshot.projections[0..snapshot.projectionCount],
        .cases = snapshot.cases[0..snapshot.caseCount],
        .windows = snapshot.windows[0..snapshot.windowCount],
        .caseWhens = snapshot.caseWhens[0..snapshot.caseWhenCount],
        .distinct = snapshot.distinctValue,
        .conditions = snapshot.conditions[0..snapshot.conditionCount],
        .order = snapshot.order,
        .limit = snapshot.limitValue,
        .offset = snapshot.offsetValue,
        .groupBy = snapshot.groupByColumn,
        .havingOp = snapshot.havingOp,
        .havingAmount = snapshot.havingAmount,
        .joinTable = snapshot.joinTable,
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
    try std.testing.expect(Query(T).isTyped);
}

pub fn UpsertBuilder(comptime Row: type, comptime Columns: type) type {
    return struct {
        const Self = @This();
        pub const isTyped = Row != void;

        allocator: std.mem.Allocator,
        connection: *anyopaque,
        executeFn: astBuilder.ExecFn,
        table: []const u8,
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
                    if (self.setCount >= self.sets.len) return error.InvalidSql;
                    self.sets[self.setCount] = .{ .name = field.name, .value = upsertValueOf(@field(assignments, field.name)) };
                    self.setCount += 1;
                }
            } else {
                inline for (@typeInfo(Columns).@"struct".fields) |colField| {
                    if (@hasField(RowType, colField.name)) {
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
            const conflict: ast.InsertConflict = switch (self.action) {
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
                var vals: [fields.len]Value = undefined;
                inline for (fields, 0..) |field, index| {
                    names[index] = field.name;
                    vals[index] = columnMod.toValue(@field(row, field.name));
                }
                var built = try astBuilder.buildInsert(self.allocator, self.table, &names, &vals, conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{
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
                var vals: [colFields.len]Value = undefined;
                var count: usize = 0;
                inline for (colFields) |colField| {
                    if (@hasField(RowType, colField.name)) {
                        names[count] = colField.type.dslName;
                        vals[count] = columnMod.toValue(@field(row, colField.name));
                        count += 1;
                    }
                }
                if (count == 0) return error.InvalidSql;
                var built = try astBuilder.buildInsert(self.allocator, self.table, names[0..count], vals[0..count], conflict, self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], .{
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
    return .{ .literal = columnMod.toValue(value) };
}

pub const Mutation = struct {
    allocator: std.mem.Allocator,
    connection: *anyopaque,
    executeFn: astBuilder.ExecFn,
    table: []const u8,
    operation: enum { update, delete },
    setNames: [32][]const u8 = undefined,
    setValues: [32]Value = undefined,
    setCount: usize = 0,
    conditions: [16]ConditionEntry = undefined,
    conditionCount: usize = 0,
    caseWhens: [2]astBuilder.CaseWhereArgs = undefined,
    caseWhenCount: usize = 0,
    cases: [2]CaseBuilder = undefined,
    caseCount: usize = 0,
    returningCols: [16]Projection = undefined,
    returningCount: usize = 0,

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
            var built = try astBuilder.buildUpdate(self.allocator, self.table, self.setNames[0..self.setCount], self.setValues[0..self.setCount], self.conditions[0..self.conditionCount], self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], self.caseWhens[0..self.caseWhenCount]);
            defer built.deinit();
            return self.executeFn(self.connection, &built.stmt, &.{}, false);
        } else {
            var built = try astBuilder.buildDelete(self.allocator, self.table, self.conditions[0..self.conditionCount], self.returningCols[0..self.returningCount], self.cases[0..self.caseCount], self.caseWhens[0..self.caseWhenCount]);
            defer built.deinit();
            return self.executeFn(self.connection, &built.stmt, &.{}, false);
        }
    }
};
