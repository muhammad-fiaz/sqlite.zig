//! DML builders plus shared predicate/assignment/target helpers.
//!
//! Responsibility: the typed/dynamic UPSERT builder (`UpsertBuilder`), the
//! UPDATE/DELETE `Mutation` builder, and the assignment/predicate/join-target
//! helpers they share with the select builders in `query_builder.zig`
//! (condition lists, SET-list validation, projection/ordering helpers,
//! join-target resolution). `query_builder.zig` imports this module
//! one-directionally; nothing here imports `query_builder.zig`, so no cycle
//! forms. Raw SQL, typed DSL, and dynamic DSL still converge on the same
//! native AST via `ast_builder.zig` — builders never render SQL strings.
//!
//! Dependencies: `dsl/expr.zig` (predicates/projections), `dsl/column.zig`
//! (assign/case/window builders), `dsl/scope.zig` (the single scope
//! resolver), `dsl/ast_builder.zig` (native AST lowering types),
//! `dsl/table.zig` (table-value introspection), `sql/ast.zig` (AST nodes),
//! `connection/result.zig` (owned results). Lifetime: builders are
//! value-semantic copies borrowing caller names/conditions; `fetch`/
//! `execute` return owned results; the connection must outlive every
//! builder and result. Errors: engine errors from execution; overflow
//! panics like every other builder limit path.

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

const ConditionEntry = astBuilder.CondEntry;

pub fn isTypedColumnInstance(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "isDslColumn") and T.isDslColumn;
}

pub fn toProjection(item: anytype) Projection {
    const T = @TypeOf(item);
    if (T == Projection) return item;
    if (T == columnMod.DynamicColumn) return item.projection();
    if (comptime tableMod.isAllProjectionType(T)) return .{ .kind = .star };
    if (T == dslExpr.Order) @compileError("select() takes columns, not orders; pass col.asc()/col.desc() to orderBy()");
    if (comptime isTypedColumnInstance(T)) return item.projection();
    @compileError("select() takes column descriptors (User.id / table.column(\"x\")) or their aggregates");
}

/// Root-scope qualifier for column resolution: the table name (or alias)
/// carried by the columns descriptor. Empty for untyped builders.
pub fn rootScopeName(comptime Columns: type) []const u8 {
    if (Columns == void) return "";
    const info = @typeInfo(Columns);
    if (info != .@"struct") return "";
    for (info.@"struct".fields) |field| {
        if (@hasDecl(field.type, "dslTable")) return field.type.dslTable;
    }
    return "";
}

/// True when an all-columns marker names the builder's own scope: the
/// mapped star path stays. Anything else expands to that side's explicit
/// qualified columns (see `appendMarkerColumns`).
pub fn allMatchesRoot(comptime Columns: type, comptime Marker: type) bool {
    return std.ascii.eqlIgnoreCase(rootScopeName(Columns), Marker.qualifierName);
}

/// Append one all-columns marker's side as explicit qualified column
/// references (native `ColumnRef`s in declaration order, never SQL text).
/// The marker carries its own columns descriptor, so the qualifier is
/// always the side the marker was built from (table name or alias).
pub fn appendMarkerColumns(projections: []Projection, count: *usize, comptime Marker: type) void {
    inline for (@typeInfo(Marker.Columns).@"struct".fields) |field| {
        if (count.* >= projections.len) @panic("too many DSL projections");
        projections[count.*] = toProjection(field.type{});
        count.* += 1;
    }
}

/// Runtime scope check for one dynamic assign: a set qualifier must be the
/// statement's table (real name or alias); empty qualifiers bind to the
/// target table by SQLite's own single-table rules.
pub fn checkDynAssignScope(item: anytype, table: []const u8, tableAlias: ?[]const u8) !void {
    if (item.table.len == 0) return;
    if (std.mem.eql(u8, item.table, table)) return;
    if (tableAlias) |alias| if (std.mem.eql(u8, item.table, alias)) return;
    return error.UnknownColumn;
}

/// Runtime membership check for one dynamic assign on a typed target: the
/// SQL name must be a column of the statement target. Dynamic targets
/// (`Columns == void`) stay unchecked by design.
pub fn checkDynAssignColumn(comptime Columns: type, name: []const u8) !void {
    if (Columns == void) return;
    inline for (@typeInfo(Columns).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.type.dslName, name)) return;
    }
    return error.UnknownColumn;
}

/// Runtime duplicate-target guard shared by typed and dynamic assigns
/// (covers mixed tuples, where comptime names are unavailable).
pub fn checkDuplicateName(names: []const []const u8, dest: []const u8) !void {
    for (names) |existing| if (std.mem.eql(u8, existing, dest)) return error.InvalidSql;
}

/// Comptime membership test for one explicit assignment: its SQL name must
/// be a column of the statement target. Cross-table assigns with disjoint
/// names fail at the call site. NOTE: callers must gate on
/// `if (comptime ...)` explicitly — a runtime `if (eql) return` does not
/// prune a trailing `@compileError` during analysis.
pub fn hasAssignColumn(comptime Col: type, comptime Columns: type) bool {
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
pub fn hasDuplicateAssign(comptime Tuple: type, comptime index: usize) bool {
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
pub fn checkAssignScope(comptime Col: type, table: []const u8, tableAlias: ?[]const u8) !void {
    if (std.mem.eql(u8, Col.dslTable, table)) return;
    if (tableAlias) |alias| if (std.mem.eql(u8, Col.dslTable, alias)) return;
    return error.UnknownColumn;
}

/// Append one predicate to a condition slice with the given OR-join flag.
/// The first element's flag is engine-ignored; callers keep the historical
/// shape (false) so existing single-predicate behavior is untouched.
pub fn appendCond(conds: []ConditionEntry, count: *usize, expr: Expr, joinOr: bool) void {
    if (count.* >= conds.len) @panic("too many DSL predicates");
    conds[count.*] = .{ .expr = expr, .joinOr = if (count.* == 0) false else joinOr };
    count.* += 1;
}

/// Distribute `L AND (a OR b)` over the existing AND-groups of a condition
/// slice as `(L1 AND a) OR (L1 AND b) OR ...`, valid in Kleene three-valued
/// logic, so SQL AND-binds-tighter precedence evaluates the intended
/// grouping. DSL predicates are pure, so duplicating them is side-effect
/// free. Panics on overflow like every other condition-limit path.
pub fn distributeOr(conds: []ConditionEntry, count: *usize, pair: dslExpr.ExprPair) void {
    var starts: [17]usize = undefined;
    var ngroups: usize = 1;
    starts[0] = 0;
    var i: usize = 1;
    while (i < count.*) : (i += 1) {
        if (conds[i].joinOr) {
            if (ngroups >= starts.len - 1) @panic("too many DSL predicates");
            starts[ngroups] = i;
            ngroups += 1;
        }
    }
    var tmp: [16]ConditionEntry = undefined;
    var n: usize = 0;
    const members = [_]Expr{ pair.first, pair.second };
    var gi: usize = 0;
    while (gi < ngroups) : (gi += 1) {
        const gend = if (gi + 1 < ngroups) starts[gi + 1] else count.*;
        for (members) |pm| {
            const boundary = n != 0;
            var k: usize = starts[gi];
            while (k < gend) : (k += 1) {
                if (n >= conds.len) @panic("too many DSL predicates");
                tmp[n] = .{ .expr = conds[k].expr, .joinOr = boundary and k == starts[gi] };
                n += 1;
            }
            if (n >= conds.len) @panic("too many DSL predicates");
            tmp[n] = .{ .expr = pm, .joinOr = boundary and gend == starts[gi] };
            n += 1;
        }
    }
    std.mem.copyForwards(ConditionEntry, conds[0..n], tmp[0..n]);
    count.* = n;
}

/// Append one predicate-or-pair in an AND-context (`andWhere`): AND-pairs
/// append directly (associative, always sound); OR-pairs distribute.
pub fn appendAnd(conds: []ConditionEntry, count: *usize, cond: anytype) void {
    const T = @TypeOf(cond);
    if (T == dslExpr.ExprPair) {
        if (!cond.joinOr) {
            appendCond(conds, count, cond.first, false);
            appendCond(conds, count, cond.second, false);
        } else {
            distributeOr(conds, count, cond);
        }
        return;
    }
    if (T == Expr) {
        appendCond(conds, count, cond, false);
        return;
    }
    @compileError("where() takes a predicate such as User.id.eq(1) or an and/or pair");
}

/// Append one predicate-or-pair in an OR-context (`orWhere`): SQL
/// precedence keeps AND-pairs grouped, so straight appends are sound.
pub fn appendOr(conds: []ConditionEntry, count: *usize, cond: anytype) void {
    const T = @TypeOf(cond);
    if (T == dslExpr.ExprPair) {
        appendCond(conds, count, cond.first, true);
        appendCond(conds, count, cond.second, cond.joinOr);
        return;
    }
    if (T == Expr) {
        appendCond(conds, count, cond, true);
        return;
    }
    @compileError("where() takes a predicate such as User.id.eq(1) or an and/or pair");
}

/// Reset a condition slice to one predicate-or-pair (`where` semantics).
pub fn storeWhere(conds: []ConditionEntry, count: *usize, cond: anytype) void {
    count.* = 0;
    appendAnd(conds, count, cond);
}

pub fn insertFieldOf(value: anytype) Value {
    const T = @TypeOf(value);
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "isExplicitValue")) {
        return value.value;
    }
    return columnMod.toValue(value);
}

pub fn isExplicitDefault(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "isExplicitDefault");
}

/// True for one assign-tuple element: a typed `Column.set(...)` assign or
/// a dynamic `column(...).set(...)` assign.
pub fn isAssignItem(comptime T: type) bool {
    return columnMod.isAssignValue(T) or columnMod.isDynAssignValue(T);
}

/// True when `assigns` is an explicit-assignment tuple: every element is an
/// assign carrying its own table identity (see `column.zig.Assign` and
/// `column.zig.DynAssign`). Empty tuples are rows, not assigns.
pub fn isAssignList(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct" or !info.@"struct".is_tuple) return false;
    if (info.@"struct".fields.len == 0) return false;
    inline for (info.@"struct".fields) |field| {
        if (!isAssignItem(field.type)) return false;
    }
    return true;
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

pub fn storeCaseProjection(cases: *[2]CaseBuilder, caseCount: *usize, out: []Projection, outCount: *usize, item: CaseBuilder) void {
    if (caseCount.* >= cases.len) @panic("too many DSL case expressions");
    if (outCount.* >= out.len) @panic("too many DSL projections");
    cases[caseCount.*] = item;
    out[outCount.*] = .{ .kind = .caseExpr, .caseSlot = @intCast(caseCount.*) };
    caseCount.* += 1;
    outCount.* += 1;
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

        pub fn where(self: Self, condition: anytype) Self {
            var copy = self;
            storeWhere(copy.upsertConds[0..], &copy.upsertCondCount, condition);
            return copy;
        }

        pub fn andWhere(self: Self, condition: anytype) Self {
            var copy = self;
            appendAnd(copy.upsertConds[0..], &copy.upsertCondCount, condition);
            return copy;
        }

        pub fn orWhere(self: Self, condition: anytype) Self {
            var copy = self;
            appendOr(copy.upsertConds[0..], &copy.upsertCondCount, condition);
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
            if (comptime tableMod.isAllOpFn(@TypeOf(cols))) @compileError("use User.all() (call it) for RETURNING all columns");
            var copy = self;
            copy.returningCount = 0;
            const T = @TypeOf(cols);
            // A foreign-scope marker expands as an explicit list; a
            // root-scope marker keeps the native star below.
            if (comptime tableMod.isAllProjectionType(T) and !allMatchesRoot(Columns, T)) {
                return self.returning(.{cols});
            }
            // Single items project exactly one RETURNING expression.
            if (T == Projection or T == columnMod.DynamicColumn or comptime tableMod.isAllProjectionType(T) or isTypedColumnInstance(T)) {
                copy.returningCols[0] = toProjection(cols);
                copy.returningCount = 1;
                return copy;
            }
            // Scoped star (`returning(.all)`) wins over plain scoped fields.
            if (T == scopeMod.EnumLiteral and comptime scopeMod.isScopedAll(T, Row, cols)) {
                copy.returningCols[0] = .{ .kind = .star };
                copy.returningCount = 1;
                return copy;
            }
            // Scoped single field (`returning(.id)`): resolves against the
            // upsert's target table.
            if (Row != void and comptime scopeMod.isScopedItem(T, Row)) {
                copy.returningCols[0] = .{ .kind = .column, .column = scopeMod.resolveRef(Row, Columns, scopeMod.builderScope(self.table, self.tableAlias), cols) };
                copy.returningCount = 1;
                return copy;
            }
            const items = if (@typeInfo(T) == .pointer) cols.* else cols;
            inline for (items) |item| {
                if (@TypeOf(item) == CaseBuilder) {
                    storeCaseProjection(&copy.cases, &copy.caseCount, copy.returningCols[0..], &copy.returningCount, item);
                    continue;
                }
                if (@TypeOf(item) == WindowBuilder) @panic("window functions are not supported in RETURNING");
                if (copy.returningCount >= copy.returningCols.len) @panic("too many DSL returning columns");
                // A qualified marker expands to its own side's explicit
                // qualified references (exact one-side projection).
                if (comptime tableMod.isAllProjectionType(@TypeOf(item))) {
                    appendMarkerColumns(copy.returningCols[0..], &copy.returningCount, @TypeOf(item));
                    continue;
                }
                if (@TypeOf(item) == scopeMod.EnumLiteral and comptime scopeMod.isScopedAll(@TypeOf(item), Row, item)) {
                    copy.returningCols[copy.returningCount] = .{ .kind = .star };
                } else if (Row != void and comptime scopeMod.isScopedItem(@TypeOf(item), Row)) {
                    copy.returningCols[copy.returningCount] = .{ .kind = .column, .column = scopeMod.resolveRef(Row, Columns, scopeMod.builderScope(self.table, self.tableAlias), item) };
                } else {
                    copy.returningCols[copy.returningCount] = toProjection(item);
                }
                copy.returningCount += 1;
            }
            if (copy.returningCount == 0) @panic("returning() requires at least one column");
            return copy;
        }

        /// Lower explicit SET assignments into the builder. Public so the
        /// `Builder.doUpdate` bridge in `query_builder.zig` shares the one
        /// canonical implementation instead of duplicating it.
        pub fn extractSets(self: *Self, assignments: anytype) !void {
            const RowType = @TypeOf(assignments);
            if (@typeInfo(RowType) != .@"struct") @compileError("DSL row must be a struct");
            // Explicit UPSERT assignments (`doUpdate(.{ User.name.set("x"),
            // User.age.set(db.excluded("age")) })`): `excluded()` markers,
            // arithmetic, and column references all pass through natively.
            // Bare singles act as 1-tuples, mirroring insert/update.
            if (comptime isAssignItem(RowType)) {
                try self.extractSets(.{assignments});
                return;
            }
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

pub fn upsertValueOf(value: anytype) astBuilder.UpsertValue {
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

    pub fn where(self: Mutation, condition: anytype) Mutation {
        var copy = self;
        storeWhere(copy.conditions[0..], &copy.conditionCount, condition);
        return copy;
    }

    pub fn andWhere(self: Mutation, condition: anytype) Mutation {
        var copy = self;
        appendAnd(copy.conditions[0..], &copy.conditionCount, condition);
        return copy;
    }

    pub fn orWhere(self: Mutation, condition: anytype) Mutation {
        var copy = self;
        appendOr(copy.conditions[0..], &copy.conditionCount, condition);
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
        if (comptime tableMod.isAllOpFn(@TypeOf(cols))) @compileError("use User.all() (call it) for RETURNING all columns");
        var copy = self;
        copy.returningCount = 0;
        const T = @TypeOf(cols);
        // Mutations are untyped: the root scope is the runtime target
        // table. A marker naming it keeps the native star; anything else
        // expands to that side's explicit qualified references.
        if (comptime tableMod.isAllProjectionType(T)) {
            if (std.ascii.eqlIgnoreCase(copy.table, T.qualifierName)) {
                copy.returningCols[0] = .{ .kind = .star };
                copy.returningCount = 1;
            } else {
                appendMarkerColumns(copy.returningCols[0..], &copy.returningCount, T);
            }
            if (copy.returningCount == 0) @panic("returning() requires at least one column");
            return copy;
        }
        const items = if (@typeInfo(T) == .pointer) cols.* else cols;
        inline for (items) |item| {
            if (@TypeOf(item) == CaseBuilder) {
                storeCaseProjection(&copy.cases, &copy.caseCount, copy.returningCols[0..], &copy.returningCount, item);
                continue;
            }
            if (@TypeOf(item) == WindowBuilder) @panic("window functions are not supported in RETURNING");
            if (copy.returningCount >= copy.returningCols.len) @panic("too many DSL returning columns");
            if (comptime tableMod.isAllProjectionType(@TypeOf(item))) {
                if (std.ascii.eqlIgnoreCase(copy.table, @TypeOf(item).qualifierName)) {
                    copy.returningCols[copy.returningCount] = .{ .kind = .star };
                    copy.returningCount += 1;
                } else {
                    appendMarkerColumns(copy.returningCols[0..], &copy.returningCount, @TypeOf(item));
                }
                continue;
            }
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
