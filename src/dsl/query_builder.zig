const std = @import("std");
const dslExpr = @import("expr.zig");
const Expr = dslExpr.Expr;
const Order = dslExpr.Order;
const Projection = dslExpr.Projection;
const ColumnRef = dslExpr.ColumnRef;
const Value = @import("../vm/value.zig").Value;
const columnMod = @import("column.zig");
const sqlGen = @import("sql_gen.zig");
const Result = @import("../connection/result.zig").Result;

pub fn Query(comptime TableType: type) type {
    return Builder(TableType.rowType, @TypeOf(TableType.columns), true);
}

pub const DynamicQuery = Builder(void, void, false);

const ConditionEntry = struct { expr: Expr, joinOr: bool = false };

const JoinKind = enum { inner, left, right, full, cross };

const InQuery = struct {
    column: ColumnRef,
    table: []const u8,
    subcolumn: ColumnRef,
    negated: bool = false,
};

const ExistsQuery = struct {
    table: []const u8,
    on: ?Expr = null,
    negated: bool = false,
};

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

pub fn Builder(comptime Row: type, comptime Columns: type, comptime mapped: bool) type {
    return struct {
        const Self = @This();
        pub const isTyped = Row != void;
        pub const rowType = Row;
        pub const columnsType = Columns;
        pub const isMapped = mapped and isTyped;

        allocator: std.mem.Allocator,
        connection: *anyopaque,
        executeFn: *const fn (*anyopaque, []const u8, []const Value) anyerror!Result,
        table: []const u8,

        allColumns: bool = true,
        projections: [32]Projection = undefined,
        projectionCount: usize = 0,
        distinctValue: bool = false,

        conditions: [16]ConditionEntry = undefined,
        conditionCount: usize = 0,

        order: ?Order = null,
        limitValue: ?usize = null,
        offsetValue: ?usize = null,
        groupByColumn: ?ColumnRef = null,
        havingOp: ?[]const u8 = null,
        havingAmount: usize = 0,

        joinTable: ?[]const u8 = null,
        joinKind: JoinKind = .inner,
        joinOn: ?Expr = null,

        inQuery: ?InQuery = null,
        existsQuery: ?ExistsQuery = null,
        literalIn: ?LiteralIn = null,

        ctes: [8]Cte = undefined,
        cteCount: usize = 0,
        cteRecursive: bool = false,

        pub fn init(connection: anytype, table: []const u8, executeFn: *const fn (*anyopaque, []const u8, []const Value) anyerror!Result) Self {
            return .{ .allocator = connection.allocator, .connection = connection, .executeFn = executeFn, .table = table };
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
                .table = self.table,
                .allColumns = self.allColumns,
                .projections = self.projections,
                .projectionCount = self.projectionCount,
                .distinctValue = self.distinctValue,
                .conditions = self.conditions,
                .conditionCount = self.conditionCount,
                .order = self.order,
                .limitValue = self.limitValue,
                .offsetValue = self.offsetValue,
                .groupByColumn = self.groupByColumn,
                .havingOp = self.havingOp,
                .havingAmount = self.havingAmount,
                .joinTable = self.joinTable,
                .joinKind = self.joinKind,
                .joinOn = self.joinOn,
                .inQuery = self.inQuery,
                .existsQuery = self.existsQuery,
                .literalIn = self.literalIn,
                .ctes = self.ctes,
                .cteCount = self.cteCount,
                .cteRecursive = self.cteRecursive,
            };
        }

        pub fn select(self: Self, cols: anytype) Builder(Row, Columns, false) {
            var copy = self.retype(false);
            copy.allColumns = false;
            copy.projectionCount = 0;
            const items = if (@typeInfo(@TypeOf(cols)) == .pointer) cols.* else cols;
            inline for (items) |item| {
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
            return copy;
        }

        fn joinAs(self: Self, other: anytype, on: Expr, kind: JoinKind) Self {
            var copy = self;
            copy.joinTable = tableNameOf(other);
            copy.joinKind = kind;
            copy.joinOn = on;
            return copy;
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

        fn insertWithMode(self: Self, row: anytype, comptime mode: []const u8) !Result {
            const RowType = @TypeOf(row);
            validateRow(RowType);
            var sql = std.ArrayList(u8).empty;
            defer sql.deinit(self.allocator);
            var params = sqlGen.Params.empty;
            defer params.deinit(self.allocator);
            try sql.appendSlice(self.allocator, "INSERT");
            if (mode.len != 0) {
                try sql.append(self.allocator, ' ');
                try sql.appendSlice(self.allocator, mode);
            }
            try sql.appendSlice(self.allocator, " INTO ");
            try sqlGen.appendIdent(self.allocator, &sql, self.table);
            try sql.appendSlice(self.allocator, " (");
            if (Columns == void) {
                const fields = @typeInfo(RowType).@"struct".fields;
                inline for (fields, 0..) |field, index| {
                    if (index != 0) try sql.appendSlice(self.allocator, ", ");
                    try sqlGen.appendIdent(self.allocator, &sql, field.name);
                }
                try sql.appendSlice(self.allocator, ") VALUES (");
                inline for (fields, 0..) |field, index| {
                    if (index != 0) try sql.appendSlice(self.allocator, ", ");
                    try sql.append(self.allocator, '?');
                    try params.append(self.allocator, columnMod.toValue(@field(row, field.name)));
                }
            } else {
                const colFields = @typeInfo(Columns).@"struct".fields;
                var first = true;
                inline for (colFields) |colField| {
                    if (@hasField(RowType, colField.name)) {
                        if (!first) try sql.appendSlice(self.allocator, ", ");
                        first = false;
                        try sqlGen.appendIdent(self.allocator, &sql, colField.type.dslName);
                    }
                }
                if (first) return error.InvalidSql;
                try sql.appendSlice(self.allocator, ") VALUES (");
                first = true;
                inline for (colFields) |colField| {
                    if (@hasField(RowType, colField.name)) {
                        if (!first) try sql.appendSlice(self.allocator, ", ");
                        first = false;
                        try sql.append(self.allocator, '?');
                        try params.append(self.allocator, columnMod.toValue(@field(row, colField.name)));
                    }
                }
            }
            try sql.appendSlice(self.allocator, ")");
            return self.executeFn(self.connection, sql.items, params.items);
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
            };
        }

        pub fn fetch(self: Self) !if (isMapped) MappedResult else Result {
            if (isMapped) return self.fetchMapped();
            return self.fetchRaw();
        }

        fn fetchRaw(self: Self) !Result {
            var sql = std.ArrayList(u8).empty;
            defer sql.deinit(self.allocator);
            var params = sqlGen.Params.empty;
            defer params.deinit(self.allocator);
            try self.renderSelect(&sql, &params);
            return self.executeFn(self.connection, sql.items, params.items);
        }

        fn localRef(self: Self, ref: ColumnRef) ColumnRef {
            if (ref.table.len != 0 and std.ascii.eqlIgnoreCase(ref.table, self.table)) return .{ .name = ref.name };
            return ref;
        }

        fn localExpr(self: Self, expr: Expr) Expr {
            var copy = expr;
            copy.column = self.localRef(expr.column);
            switch (copy.rhs) {
                .column => |ref| copy.rhs = .{ .column = self.localRef(ref) },
                .value => {},
            }
            if (copy.rhs2) |rhs2| switch (rhs2) {
                .column => |ref| copy.rhs2 = .{ .column = self.localRef(ref) },
                .value => {},
            };
            return copy;
        }

        fn localProjection(self: Self, proj: Projection) Projection {
            var copy = proj;
            switch (copy.kind) {
                .column, .aggregate, .scalar => copy.column = self.localRef(proj.column),
                .star, .countStar => {},
            }
            return copy;
        }

        fn renderSelect(self: Self, sql: *std.ArrayList(u8), params: *sqlGen.Params) !void {
            if (self.cteCount != 0) {
                try sql.appendSlice(self.allocator, if (self.cteRecursive) "WITH RECURSIVE " else "WITH ");
                for (self.ctes[0..self.cteCount], 0..) |cte, index| {
                    if (index != 0) try sql.appendSlice(self.allocator, ", ");
                    try sqlGen.appendIdent(self.allocator, sql, cte.name);
                    try sql.appendSlice(self.allocator, " AS (");
                    try sql.appendSlice(self.allocator, cte.base);
                    if (cte.recursive) |body| {
                        try sql.appendSlice(self.allocator, " UNION ALL ");
                        try sql.appendSlice(self.allocator, body);
                    }
                    try sql.append(self.allocator, ')');
                }
                try sql.append(self.allocator, ' ');
            }
            try sql.appendSlice(self.allocator, if (self.distinctValue) "SELECT DISTINCT " else "SELECT ");
            if (self.allColumns) {
                try sql.append(self.allocator, '*');
            } else {
                for (self.projections[0..self.projectionCount], 0..) |proj, index| {
                    if (index != 0) try sql.appendSlice(self.allocator, ", ");
                    try sqlGen.appendProjection(self.allocator, sql, params, self.localProjection(proj));
                }
            }
            try sql.appendSlice(self.allocator, " FROM ");
            try sqlGen.appendIdent(self.allocator, sql, self.table);
            if (self.joinTable) |joined| {
                const kind: []const u8 = switch (self.joinKind) {
                    .inner => " JOIN ",
                    .left => " LEFT JOIN ",
                    .right => " RIGHT JOIN ",
                    .full => " FULL JOIN ",
                    .cross => " CROSS JOIN ",
                };
                try sql.appendSlice(self.allocator, kind);
                try sqlGen.appendIdent(self.allocator, sql, joined);
                if (self.joinKind != .cross) {
                    const on = self.joinOn orelse return error.InvalidSql;
                    try sql.appendSlice(self.allocator, " ON ");
                    try sqlGen.appendExpr(self.allocator, sql, params, on);
                }
            }
            try self.renderWhere(sql, params);
            if (self.groupByColumn) |group| {
                try sql.appendSlice(self.allocator, " GROUP BY ");
                try sqlGen.appendIdent(self.allocator, sql, group.name);
            }
            if (self.havingOp) |operator| {
                if (!validHavingOp(operator)) return error.InvalidSql;
                try sql.appendSlice(self.allocator, " HAVING COUNT(*) ");
                try sql.appendSlice(self.allocator, operator);
                const rendered = try std.fmt.allocPrint(self.allocator, " {d}", .{self.havingAmount});
                defer self.allocator.free(rendered);
                try sql.appendSlice(self.allocator, rendered);
            }
            if (self.order) |order| {
                if (order.function != null) return error.InvalidSql;
                try sql.appendSlice(self.allocator, " ORDER BY ");
                try sqlGen.appendIdent(self.allocator, sql, order.column.name);
                if (order.descending) try sql.appendSlice(self.allocator, " DESC");
            }
            if (self.limitValue) |amount| {
                const rendered = try std.fmt.allocPrint(self.allocator, " LIMIT {d}", .{amount});
                defer self.allocator.free(rendered);
                try sql.appendSlice(self.allocator, rendered);
            }
            if (self.offsetValue) |amount| {
                const rendered = try std.fmt.allocPrint(self.allocator, " OFFSET {d}", .{amount});
                defer self.allocator.free(rendered);
                try sql.appendSlice(self.allocator, rendered);
            }
        }

        fn renderWhere(self: Self, sql: *std.ArrayList(u8), params: *sqlGen.Params) !void {
            var hasWhere = false;
            for (self.conditions[0..self.conditionCount], 0..) |entry, index| {
                try sql.appendSlice(self.allocator, if (index == 0) " WHERE " else if (entry.joinOr) " OR " else " AND ");
                try sqlGen.appendExpr(self.allocator, sql, params, self.localExpr(entry.expr));
                hasWhere = true;
            }
            if (self.inQuery) |subquery| {
                try sql.appendSlice(self.allocator, if (hasWhere) " AND " else " WHERE ");
                hasWhere = true;
                try sqlGen.appendRef(self.allocator, sql, self.localRef(subquery.column));
                try sql.appendSlice(self.allocator, if (subquery.negated) " NOT IN (SELECT " else " IN (SELECT ");
                try sqlGen.appendIdent(self.allocator, sql, subquery.subcolumn.name);
                try sql.appendSlice(self.allocator, " FROM ");
                try sqlGen.appendIdent(self.allocator, sql, subquery.table);
                try sql.append(self.allocator, ')');
            }
            if (self.existsQuery) |subquery| {
                try sql.appendSlice(self.allocator, if (hasWhere) " AND " else " WHERE ");
                hasWhere = true;
                try sql.appendSlice(self.allocator, if (subquery.negated) "NOT EXISTS (SELECT 1 FROM " else "EXISTS (SELECT 1 FROM ");
                try sqlGen.appendIdent(self.allocator, sql, subquery.table);
                if (subquery.on) |on| {
                    try sql.appendSlice(self.allocator, " WHERE ");
                    try sqlGen.appendExpr(self.allocator, sql, params, on);
                }
                try sql.append(self.allocator, ')');
            }
            if (self.literalIn) |list| {
                try sql.appendSlice(self.allocator, if (hasWhere) " AND " else " WHERE ");
                try sqlGen.appendRef(self.allocator, sql, self.localRef(list.column));
                try sql.appendSlice(self.allocator, if (list.negated) " NOT IN (" else " IN (");
                for (list.values[0..list.count], 0..) |value, index| {
                    if (index != 0) try sql.appendSlice(self.allocator, ", ");
                    try sql.append(self.allocator, '?');
                    try params.append(self.allocator, value);
                }
                try sql.append(self.allocator, ')');
            }
        }

        pub const MappedResult = struct {
            allocator: std.mem.Allocator,
            rows: []Row,

            pub fn deinit(result: *@This()) void {
                for (result.rows) |*row| freeMappedRow(result.allocator, row);
                result.allocator.free(result.rows);
            }

            pub fn rowCount(result: @This()) usize {
                return result.rows.len;
            }
        };

        fn freeTypedValue(allocator: std.mem.Allocator, value: anytype) void {
            const T = @TypeOf(value);
            if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) allocator.free(value);
            if (@typeInfo(T) == .optional) if (value) |present| freeTypedValue(allocator, present);
        }

        fn assignTypedValue(allocator: std.mem.Allocator, destination: anytype, value: Value) !void {
            const T = @TypeOf(destination.*);
            if (@typeInfo(T) == .optional) {
                if (value == .null) {
                    destination.* = null;
                    return;
                }
                var present: @typeInfo(T).optional.child = undefined;
                try assignTypedValue(allocator, &present, value);
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

        fn freeMappedPrefix(allocator: std.mem.Allocator, row: *Row, count: usize) void {
            inline for (@typeInfo(Row).@"struct".fields, 0..) |field, fi| {
                if (fi < count) freeTypedValue(allocator, @field(row.*, field.name));
            }
        }

        fn freeMappedRow(allocator: std.mem.Allocator, row: *Row) void {
            inline for (@typeInfo(Row).@"struct".fields) |field| {
                freeTypedValue(allocator, @field(row.*, field.name));
            }
        }

        fn fetchMapped(self: Self) !MappedResult {
            var result = try self.fetchRaw();
            defer result.deinit();
            const rows = try self.allocator.alloc(Row, result.rows.len);
            var done: usize = 0;
            errdefer {
                for (rows[0..done]) |*row| freeMappedRow(self.allocator, row);
                self.allocator.free(rows);
            }
            for (result.rows, 0..) |source, rowIndex| {
                var destination: Row = undefined;
                var assigned: usize = 0;
                errdefer freeMappedPrefix(self.allocator, &destination, assigned);
                if (Columns == void) {
                    inline for (@typeInfo(Row).@"struct".fields, 0..) |field, fi| {
                        const index = findResultColumn(result.columns, field.name) orelse return error.UnknownColumn;
                        try assignTypedValue(self.allocator, &@field(destination, field.name), source[index]);
                        assigned = fi + 1;
                    }
                } else {
                    inline for (@typeInfo(Columns).@"struct".fields, 0..) |colField, fi| {
                        const index = findResultColumn(result.columns, colField.type.dslName) orelse return error.UnknownColumn;
                        try assignTypedValue(self.allocator, &@field(destination, colField.name), source[index]);
                        assigned = fi + 1;
                    }
                }
                rows[rowIndex] = destination;
                done = rowIndex + 1;
            }
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

        pub fn freeRow(self: Self, row: *Row) void {
            if (!isTyped) @compileError("freeRow requires a typed table");
            freeMappedRow(self.allocator, row);
        }
    };
}

fn findResultColumn(columns: []const []const u8, want: []const u8) ?usize {
    for (columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column, want)) return index;
    return null;
}

fn stripRef(table: []const u8, ref: ColumnRef) ColumnRef {
    if (ref.table.len != 0 and std.ascii.eqlIgnoreCase(ref.table, table)) return .{ .name = ref.name };
    return ref;
}

fn stripExpr(table: []const u8, expr: Expr) Expr {
    var copy = expr;
    copy.column = stripRef(table, expr.column);
    switch (copy.rhs) {
        .column => |ref| copy.rhs = .{ .column = stripRef(table, ref) },
        .value => {},
    }
    if (copy.rhs2) |rhs2| switch (rhs2) {
        .column => |ref| copy.rhs2 = .{ .column = stripRef(table, ref) },
        .value => {},
    };
    return copy;
}

fn validHavingOp(operator: []const u8) bool {
    for ([_][]const u8{ "=", "<>", "<", "<=", ">", ">=" }) |valid| {
        if (std.mem.eql(u8, operator, valid)) return true;
    }
    return false;
}

test "typed and dynamic builders share one engine" {
    try std.testing.expect(Builder(struct { id: i64 }, void, true).isTyped);
    try std.testing.expect(!Builder(void, void, false).isTyped);
    try std.testing.expect(DynamicQuery.isTyped == false);
    const T = @import("table.zig").table("t", struct { id: i64 });
    try std.testing.expect(Query(T).isTyped);
}

pub const Mutation = struct {
    allocator: std.mem.Allocator,
    connection: *anyopaque,
    executeFn: *const fn (*anyopaque, []const u8, []const Value) anyerror!Result,
    table: []const u8,
    operation: enum { update, delete },
    setNames: [32][]const u8 = undefined,
    setValues: [32]Value = undefined,
    setCount: usize = 0,
    conditions: [16]ConditionEntry = undefined,
    conditionCount: usize = 0,

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

    pub fn execute(self: Mutation) !Result {
        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(self.allocator);
        var params = sqlGen.Params.empty;
        defer params.deinit(self.allocator);
        if (self.operation == .update) {
            if (self.setCount == 0) return error.InvalidSql;
            try sql.appendSlice(self.allocator, "UPDATE ");
            try sqlGen.appendIdent(self.allocator, &sql, self.table);
            try sql.appendSlice(self.allocator, " SET ");
            for (self.setNames[0..self.setCount], 0..) |name, index| {
                if (index != 0) try sql.appendSlice(self.allocator, ", ");
                try sqlGen.appendIdent(self.allocator, &sql, name);
                try sql.appendSlice(self.allocator, " = ?");
                try params.append(self.allocator, self.setValues[index]);
            }
        } else {
            try sql.appendSlice(self.allocator, "DELETE FROM ");
            try sqlGen.appendIdent(self.allocator, &sql, self.table);
        }
        for (self.conditions[0..self.conditionCount], 0..) |entry, index| {
            try sql.appendSlice(self.allocator, if (index == 0) " WHERE " else if (entry.joinOr) " OR " else " AND ");
            try sqlGen.appendExpr(self.allocator, &sql, &params, stripExpr(self.table, entry.expr));
        }
        return self.executeFn(self.connection, sql.items, params.items);
    }
};
