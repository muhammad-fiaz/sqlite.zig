const std = @import("std");
const Expr = @import("expr.zig").Expr;
const sql_gen = @import("sql_gen.zig");
const Result = @import("../connection/result.zig").Result;
const Value = @import("../vm/value.zig").Value;
const ColumnKey = @import("table.zig").ColumnKey;

pub const Order = struct { column: []const u8, descending: bool };
const InSubquery = struct { column: []const u8, table: []const u8, subquery_column: []const u8 };

fn appendQuoted(allocator: std.mem.Allocator, list: *std.ArrayList(u8), bytes: []const u8) !void {
    try list.append(allocator, '\'');
    for (bytes) |byte| {
        if (byte == '\'') try list.append(allocator, '\'');
        try list.append(allocator, byte);
    }
    try list.append(allocator, '\'');
}

fn appendValue(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: anytype) !void {
    const T = @TypeOf(value);
    if (T == Value) {
        return switch (value) {
            .null => list.appendSlice(allocator, "NULL"),
            .integer => |n| {
                const rendered = try std.fmt.allocPrint(allocator, "{d}", .{n});
                defer allocator.free(rendered);
                try list.appendSlice(allocator, rendered);
            },
            .real => |n| {
                const rendered = try std.fmt.allocPrint(allocator, "{d}", .{n});
                defer allocator.free(rendered);
                try list.appendSlice(allocator, rendered);
            },
            .text => |bytes| appendQuoted(allocator, list, bytes),
            .blob => |bytes| appendQuoted(allocator, list, bytes),
        };
    }
    if (@typeInfo(T) == .optional) {
        if (value) |present| {
            return appendValue(allocator, list, present);
        }
        return list.appendSlice(allocator, "NULL");
    }
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intCast(value))});
            defer allocator.free(rendered);
            try list.appendSlice(allocator, rendered);
        },
        .float, .comptime_float => {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{@as(f64, @floatCast(value))});
            defer allocator.free(rendered);
            try list.appendSlice(allocator, rendered);
        },
        .pointer => try appendQuoted(allocator, list, value),
        else => @compileError("unsupported DSL value"),
    }
}

pub fn Query(comptime TableType: type) type {
    return struct {
        const Self = @This();
        fn emptyConditions() [8]Expr {
            return undefined;
        }
        pub const Mutation = struct {
            base: Self,
            operation: enum { update, delete },
            set_sql: []const u8 = "",

            pub fn where(self: Mutation, condition: Expr) Mutation {
                var copy = self;
                copy.base.condition = condition;
                copy.base.additional_condition_count = 0;
                return copy;
            }

            pub fn andWhere(self: Mutation, condition: Expr) Mutation {
                var copy = self;
                if (copy.base.additional_condition_count >= copy.base.additional_conditions.len) @panic("too many DSL predicates");
                copy.base.additional_conditions[copy.base.additional_condition_count] = condition;
                copy.base.additional_condition_count += 1;
                return copy;
            }

            pub fn deinit(self: *Mutation) void {
                if (self.set_sql.len != 0) self.base.allocator.free(self.set_sql);
                self.set_sql = "";
            }

            pub fn execute(self: Mutation) !Result {
                var sql = std.ArrayList(u8).empty;
                defer sql.deinit(self.base.allocator);
                if (self.operation == .update) {
                    try sql.appendSlice(self.base.allocator, "UPDATE ");
                    try sql.appendSlice(self.base.allocator, self.base.table);
                    try sql.appendSlice(self.base.allocator, " SET ");
                    try sql.appendSlice(self.base.allocator, self.set_sql);
                } else {
                    try sql.appendSlice(self.base.allocator, "DELETE FROM ");
                    try sql.appendSlice(self.base.allocator, self.base.table);
                }
                try appendCondition(self.base.allocator, &sql, self.base.condition, self.base.additional_conditions[0..self.base.additional_condition_count]);
                return self.base.execute_fn(self.base.connection, sql.items);
            }
        };

        allocator: std.mem.Allocator,
        connection: *anyopaque,
        execute_fn: *const fn (*anyopaque, []const u8) anyerror!Result,
        table: []const u8,
        projection: []const u8 = "*",
        scalar_function: ?[]const u8 = null,
        scalar_field: ?[]const u8 = null,
        selected_fields: ?[]const []const u8 = null,
        selected_columns: ?[]const ColumnKey = null,
        condition: ?Expr = null,
        additional_conditions: [8]Expr = emptyConditions(),
        additional_condition_count: usize = 0,
        order: ?Order = null,
        limit_value: ?usize = null,
        offset_value: ?usize = null,
        join_table: ?[]const u8 = null,
        join_left: []const u8 = "",
        join_right: []const u8 = "",
        join_kind: []const u8 = "JOIN",
        distinct_value: bool = false,
        in_subquery: ?InSubquery = null,

        pub fn init(connection: anytype, table: []const u8, execute_fn: *const fn (*anyopaque, []const u8) anyerror!Result) Self {
            return .{ .allocator = connection.allocator, .connection = connection, .execute_fn = execute_fn, .table = table };
        }

        pub fn select(self: Self, projection: []const u8) Self {
            var copy = self;
            copy.projection = projection;
            copy.scalar_function = null;
            copy.scalar_field = null;
            copy.selected_fields = null;
            copy.selected_columns = null;
            return copy;
        }

        pub fn selectAll(self: Self) Self {
            return self.select("*");
        }

        pub fn lowerColumn(self: Self, comptime field: ColumnKey) Self {
            return self.scalarColumn("LOWER", field);
        }

        pub fn upperColumn(self: Self, comptime field: ColumnKey) Self {
            return self.scalarColumn("UPPER", field);
        }

        pub fn lengthColumn(self: Self, comptime field: ColumnKey) Self {
            return self.scalarColumn("LENGTH", field);
        }

        pub fn absColumn(self: Self, comptime field: ColumnKey) Self {
            return self.scalarColumn("ABS", field);
        }

        pub fn typeofColumn(self: Self, comptime field: ColumnKey) Self {
            return self.scalarColumn("TYPEOF", field);
        }

        pub fn distinct(self: Self) Self {
            var copy = self;
            copy.distinct_value = true;
            return copy;
        }

        pub fn selectFieldNames(self: Self, comptime fields: []const []const u8) Self {
            inline for (fields) |field| if (!@hasField(TableType.row_type, field)) @compileError("unknown DSL column");
            var copy = self;
            copy.selected_fields = fields;
            copy.selected_columns = null;
            return copy;
        }

        pub fn selectFields(self: Self, comptime fields: []const []const u8) Self {
            return self.selectFieldNames(fields);
        }

        pub fn selectColumns(self: Self, comptime fields: []const ColumnKey) Self {
            inline for (fields) |field| {
                if (!@hasField(TableType.row_type, field.name)) @compileError("unknown DSL column");
            }
            var copy = self;
            copy.selected_columns = fields;
            copy.selected_fields = null;
            return copy;
        }

        pub fn where(self: Self, condition: Expr) Self {
            var copy = self;
            copy.condition = condition;
            copy.additional_condition_count = 0;
            return copy;
        }

        pub fn andWhere(self: Self, condition: Expr) Self {
            var copy = self;
            if (copy.additional_condition_count >= copy.additional_conditions.len) @panic("too many DSL predicates");
            copy.additional_conditions[copy.additional_condition_count] = condition;
            copy.additional_condition_count += 1;
            return copy;
        }

        pub fn whereInColumn(self: Self, comptime column: ColumnKey, comptime OtherTable: type, comptime other_column: ColumnKey) Self {
            if (!@hasField(TableType.row_type, column.name)) @compileError("unknown DSL IN column");
            if (!@hasField(OtherTable.row_type, other_column.name)) @compileError("unknown DSL subquery column");
            var copy = self;
            copy.in_subquery = .{ .column = column.name, .table = OtherTable.table_name, .subquery_column = other_column.name };
            return copy;
        }

        pub fn orderBy(self: Self, order: Order) Self {
            var copy = self;
            copy.order = order;
            return copy;
        }

        pub fn limit(self: Self, amount: usize) Self {
            var copy = self;
            copy.limit_value = amount;
            return copy;
        }

        pub fn offset(self: Self, amount: usize) Self {
            var copy = self;
            copy.offset_value = amount;
            return copy;
        }

        pub fn count(self: Self) Self {
            return self.select("COUNT(*)");
        }

        pub fn countField(self: Self, comptime field: []const u8) Self {
            if (!@hasField(TableType.row_type, field)) @compileError("unknown DSL column");
            var copy = self;
            copy.projection = "COUNT(" ++ field ++ ")";
            copy.scalar_function = null;
            copy.scalar_field = null;
            copy.selected_fields = null;
            copy.selected_columns = null;
            return copy;
        }

        pub fn countColumn(self: Self, comptime field: ColumnKey) Self {
            return self.countField(checkedColumn(field));
        }

        pub fn sum(self: Self, comptime field: []const u8) Self {
            return self.aggregate("SUM", field);
        }
        pub fn sumColumn(self: Self, comptime field: ColumnKey) Self {
            return self.aggregate("SUM", checkedColumn(field));
        }
        pub fn average(self: Self, comptime field: []const u8) Self {
            return self.aggregate("AVG", field);
        }
        pub fn averageColumn(self: Self, comptime field: ColumnKey) Self {
            return self.aggregate("AVG", checkedColumn(field));
        }
        pub fn minimum(self: Self, comptime field: []const u8) Self {
            return self.aggregate("MIN", field);
        }
        pub fn minimumColumn(self: Self, comptime field: ColumnKey) Self {
            return self.aggregate("MIN", checkedColumn(field));
        }
        pub fn maximum(self: Self, comptime field: []const u8) Self {
            return self.aggregate("MAX", field);
        }
        pub fn maximumColumn(self: Self, comptime field: ColumnKey) Self {
            return self.aggregate("MAX", checkedColumn(field));
        }

        pub fn innerJoin(self: Self, comptime OtherTable: type, comptime left_field: []const u8, comptime right_field: []const u8) Self {
            return self.joinAs(OtherTable, left_field, right_field, "JOIN");
        }

        pub fn innerJoinKeys(self: Self, comptime OtherTable: type, comptime left: ColumnKey, comptime right: ColumnKey) Self {
            return self.joinKeysAs(OtherTable, left, right, "JOIN");
        }

        pub fn leftJoin(self: Self, comptime OtherTable: type, comptime left_field: []const u8, comptime right_field: []const u8) Self {
            return self.joinAs(OtherTable, left_field, right_field, "LEFT JOIN");
        }

        pub fn leftJoinKeys(self: Self, comptime OtherTable: type, comptime left: ColumnKey, comptime right: ColumnKey) Self {
            return self.joinKeysAs(OtherTable, left, right, "LEFT JOIN");
        }

        pub fn rightJoin(self: Self, comptime OtherTable: type, comptime left_field: []const u8, comptime right_field: []const u8) Self {
            return self.joinAs(OtherTable, left_field, right_field, "RIGHT JOIN");
        }

        pub fn rightJoinKeys(self: Self, comptime OtherTable: type, comptime left: ColumnKey, comptime right: ColumnKey) Self {
            return self.joinKeysAs(OtherTable, left, right, "RIGHT JOIN");
        }

        pub fn fullJoin(self: Self, comptime OtherTable: type, comptime left_field: []const u8, comptime right_field: []const u8) Self {
            return self.joinAs(OtherTable, left_field, right_field, "FULL JOIN");
        }

        pub fn fullJoinKeys(self: Self, comptime OtherTable: type, comptime left: ColumnKey, comptime right: ColumnKey) Self {
            return self.joinKeysAs(OtherTable, left, right, "FULL JOIN");
        }

        pub fn crossJoin(self: Self, comptime OtherTable: type) Self {
            var copy = self;
            copy.join_table = OtherTable.table_name;
            copy.join_left = "";
            copy.join_right = "";
            copy.join_kind = "CROSS JOIN";
            return copy;
        }

        fn joinAs(self: Self, comptime OtherTable: type, comptime left_field: []const u8, comptime right_field: []const u8, comptime kind: []const u8) Self {
            if (!@hasField(TableType.row_type, left_field)) @compileError("unknown DSL join column");
            if (!@hasField(OtherTable.row_type, right_field)) @compileError("unknown DSL join column");
            var copy = self;
            copy.join_table = OtherTable.table_name;
            copy.join_left = left_field;
            copy.join_right = right_field;
            copy.join_kind = kind;
            return copy;
        }

        fn joinKeysAs(self: Self, comptime OtherTable: type, comptime left: ColumnKey, comptime right: ColumnKey, comptime kind: []const u8) Self {
            return self.joinAs(OtherTable, left.name, right.name, kind);
        }

        fn aggregate(self: Self, comptime function_name: []const u8, comptime field: []const u8) Self {
            if (!@hasField(TableType.row_type, field)) @compileError("unknown DSL column");
            var copy = self;
            copy.projection = function_name ++ "(" ++ field ++ ")";
            copy.scalar_function = null;
            copy.scalar_field = null;
            copy.selected_fields = null;
            copy.selected_columns = null;
            return copy;
        }

        fn checkedColumn(comptime field: ColumnKey) []const u8 {
            if (!@hasField(TableType.row_type, field.name)) @compileError("unknown DSL aggregate column");
            return field.name;
        }

        fn scalarColumn(self: Self, comptime function_name: []const u8, comptime field: ColumnKey) Self {
            _ = checkedColumn(field);
            var copy = self;
            copy.projection = "";
            copy.scalar_function = function_name;
            copy.scalar_field = field.name;
            copy.selected_fields = null;
            copy.selected_columns = null;
            return copy;
        }

        fn validateRow(comptime RowType: type) void {
            if (@typeInfo(RowType) != .@"struct") @compileError("DSL row must be a struct");
            inline for (@typeInfo(RowType).@"struct".fields) |field| {
                if (!@hasField(TableType.row_type, field.name)) @compileError("DSL row contains an unknown table column");
            }
        }

        pub fn insert(self: Self, row: anytype) !Result {
            const RowType = @TypeOf(row);
            validateRow(RowType);
            var sql = std.ArrayList(u8).empty;
            defer sql.deinit(self.allocator);
            try sql.appendSlice(self.allocator, "INSERT INTO ");
            try sql.appendSlice(self.allocator, self.table);
            try sql.appendSlice(self.allocator, " (");
            const fields = @typeInfo(RowType).@"struct".fields;
            inline for (fields, 0..) |field, index| {
                if (index != 0) try sql.appendSlice(self.allocator, ", ");
                try sql.appendSlice(self.allocator, field.name);
            }
            try sql.appendSlice(self.allocator, ") VALUES (");
            inline for (fields, 0..) |field, index| {
                if (index != 0) try sql.appendSlice(self.allocator, ", ");
                try appendValue(self.allocator, &sql, @field(row, field.name));
            }
            try sql.appendSlice(self.allocator, ");");
            return self.execute_fn(self.connection, sql.items);
        }

        pub fn insertTyped(self: Self, row: TableType.row_type) !Result {
            return self.insert(row);
        }

        pub fn update(self: Self, row: anytype) !Mutation {
            const RowType = @TypeOf(row);
            validateRow(RowType);
            var sql = std.ArrayList(u8).empty;
            const fields = @typeInfo(RowType).@"struct".fields;
            inline for (fields, 0..) |field, index| {
                if (index != 0) try sql.appendSlice(self.allocator, ", ");
                try sql.appendSlice(self.allocator, field.name);
                try sql.appendSlice(self.allocator, " = ");
                try appendValue(self.allocator, &sql, @field(row, field.name));
            }
            return .{ .base = self, .operation = .update, .set_sql = try sql.toOwnedSlice(self.allocator) };
        }

        pub fn updateTyped(self: Self, row: TableType.row_type) !Mutation {
            return self.update(row);
        }

        pub fn delete(self: Self) Mutation {
            return .{ .base = self, .operation = .delete };
        }

        pub fn fetchAll(self: Self) !Result {
            var list = std.ArrayList(u8).empty;
            defer list.deinit(self.allocator);
            try list.appendSlice(self.allocator, if (self.distinct_value) "SELECT DISTINCT " else "SELECT ");
            if (self.selected_fields) |fields| {
                for (fields, 0..) |field, index| {
                    if (index != 0) try list.appendSlice(self.allocator, ", ");
                    try list.appendSlice(self.allocator, field);
                }
            } else if (self.selected_columns) |fields| {
                for (fields, 0..) |field, index| {
                    if (index != 0) try list.appendSlice(self.allocator, ", ");
                    try list.appendSlice(self.allocator, field.name);
                }
            } else if (self.scalar_function) |function_name| {
                try list.appendSlice(self.allocator, function_name);
                try list.append(self.allocator, '(');
                try list.appendSlice(self.allocator, self.scalar_field.?);
                try list.append(self.allocator, ')');
            } else try list.appendSlice(self.allocator, self.projection);
            try list.appendSlice(self.allocator, " FROM ");
            try list.appendSlice(self.allocator, self.table);
            if (self.join_table) |joined_table| {
                try list.appendSlice(self.allocator, " ");
                try list.appendSlice(self.allocator, self.join_kind);
                try list.appendSlice(self.allocator, " ");
                try list.appendSlice(self.allocator, joined_table);
                if (!std.mem.eql(u8, self.join_kind, "CROSS JOIN")) {
                    try list.appendSlice(self.allocator, " ON ");
                    try list.appendSlice(self.allocator, self.table);
                    try list.appendSlice(self.allocator, ".");
                    try list.appendSlice(self.allocator, self.join_left);
                    try list.appendSlice(self.allocator, " = ");
                    try list.appendSlice(self.allocator, joined_table);
                    try list.appendSlice(self.allocator, ".");
                    try list.appendSlice(self.allocator, self.join_right);
                }
            }
            try appendCondition(self.allocator, &list, self.condition, self.additional_conditions[0..self.additional_condition_count]);
            if (self.in_subquery) |subquery| {
                try list.appendSlice(self.allocator, if (self.condition == null) " WHERE " else " AND ");
                try list.appendSlice(self.allocator, subquery.column);
                try list.appendSlice(self.allocator, " IN (SELECT ");
                try list.appendSlice(self.allocator, subquery.subquery_column);
                try list.appendSlice(self.allocator, " FROM ");
                try list.appendSlice(self.allocator, subquery.table);
                try list.appendSlice(self.allocator, ")");
            }
            if (self.order) |order| {
                try list.appendSlice(self.allocator, " ORDER BY ");
                try list.appendSlice(self.allocator, order.column);
                if (order.descending) try list.appendSlice(self.allocator, " DESC");
            }
            if (self.limit_value) |amount| {
                const rendered = try std.fmt.allocPrint(self.allocator, " LIMIT {d}", .{amount});
                defer self.allocator.free(rendered);
                try list.appendSlice(self.allocator, rendered);
            }
            if (self.offset_value) |amount| {
                const rendered = try std.fmt.allocPrint(self.allocator, " OFFSET {d}", .{amount});
                defer self.allocator.free(rendered);
                try list.appendSlice(self.allocator, rendered);
            }
            return self.execute_fn(self.connection, list.items);
        }
    };
}

fn appendCondition(allocator: std.mem.Allocator, sql: *std.ArrayList(u8), condition: ?Expr, additional: []const Expr) !void {
    if (condition) |item| {
        const rendered = try sql_gen.renderExpr(allocator, item);
        defer allocator.free(rendered);
        try sql.appendSlice(allocator, " WHERE ");
        try sql.appendSlice(allocator, rendered);
        for (additional) |extra| {
            const extra_rendered = try sql_gen.renderExpr(allocator, extra);
            defer allocator.free(extra_rendered);
            try sql.appendSlice(allocator, " AND ");
            try sql.appendSlice(allocator, extra_rendered);
        }
    }
}
