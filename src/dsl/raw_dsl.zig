const std = @import("std");
const Result = @import("../connection/result.zig").Result;
const Value = @import("../vm/value.zig").Value;

pub const RawColumn = struct {
    name: []const u8,
    pub fn eq(self: @This(), value: anytype) RawCondition {
        return .{ .column = self.name, .operator = "=", .value = toValue(value) };
    }
    pub fn ne(self: @This(), value: anytype) RawCondition {
        return .{ .column = self.name, .operator = "<>", .value = toValue(value) };
    }
    pub fn gt(self: @This(), value: anytype) RawCondition {
        return .{ .column = self.name, .operator = ">", .value = toValue(value) };
    }
    pub fn gte(self: @This(), value: anytype) RawCondition {
        return .{ .column = self.name, .operator = ">=", .value = toValue(value) };
    }
    pub fn lt(self: @This(), value: anytype) RawCondition {
        return .{ .column = self.name, .operator = "<", .value = toValue(value) };
    }
    pub fn is(self: @This(), value: anytype) RawCondition {
        return .{ .column = self.name, .operator = "IS", .value = toValue(value) };
    }
    pub fn isNot(self: @This(), value: anytype) RawCondition {
        return .{ .column = self.name, .operator = "IS NOT", .value = toValue(value) };
    }
    pub fn between(self: @This(), lower: anytype, upper: anytype) RawCondition {
        return .{ .column = self.name, .operator = "BETWEEN", .value = toValue(lower), .value2 = toValue(upper) };
    }
    pub fn notBetween(self: @This(), lower: anytype, upper: anytype) RawCondition {
        return .{ .column = self.name, .operator = "NOT BETWEEN", .value = toValue(lower), .value2 = toValue(upper) };
    }
    pub fn like(self: @This(), value: []const u8) RawCondition {
        return .{ .column = self.name, .operator = "LIKE", .value = .{ .text = value } };
    }
    pub fn notLike(self: @This(), value: []const u8) RawCondition {
        return .{ .column = self.name, .operator = "NOT LIKE", .value = .{ .text = value } };
    }
    pub fn glob(self: @This(), value: []const u8) RawCondition {
        return .{ .column = self.name, .operator = "GLOB", .value = .{ .text = value } };
    }
    pub fn notGlob(self: @This(), value: []const u8) RawCondition {
        return .{ .column = self.name, .operator = "NOT GLOB", .value = .{ .text = value } };
    }
    pub fn contains(self: @This(), value: []const u8) RawCondition {
        return .{ .column = self.name, .operator = "LIKE", .value = .{ .text = value }, .pattern = .contains };
    }
    pub fn startsWith(self: @This(), value: []const u8) RawCondition {
        return .{ .column = self.name, .operator = "LIKE", .value = .{ .text = value }, .pattern = .starts };
    }
    pub fn endsWith(self: @This(), value: []const u8) RawCondition {
        return .{ .column = self.name, .operator = "LIKE", .value = .{ .text = value }, .pattern = .ends };
    }
    pub fn isNull(self: @This()) RawCondition {
        return .{ .column = self.name, .operator = "IS NULL", .value = .null };
    }
    pub fn isNotNull(self: @This()) RawCondition {
        return .{ .column = self.name, .operator = "IS NOT NULL", .value = .null };
    }
};

pub const RawCondition = struct {
    column: []const u8,
    operator: []const u8,
    value: Value,
    value2: ?Value = null,
    pattern: enum { none, contains, starts, ends } = .none,
};

pub fn RawQuery(comptime execute_fn: *const fn (*anyopaque, []const u8, []const Value) anyerror!Result) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        connection: *anyopaque,
        table: []const u8,
        projection: []const u8 = "*",
        condition: ?RawCondition = null,
        additional_condition: ?RawCondition = null,
        order_column: ?[]const u8 = null,
        descending: bool = false,
        limit_value: ?usize = null,
        offset_value: ?usize = null,
        join: ?RawJoin = null,
        group_column: ?[]const u8 = null,
        count_column: ?[]const u8 = null,

        pub fn init(allocator: std.mem.Allocator, connection: *anyopaque, table: []const u8) Self {
            return .{ .allocator = allocator, .connection = connection, .table = table };
        }
        pub fn col(_: Self, name: []const u8) RawColumn {
            return .{ .name = name };
        }
        pub fn select(self: Self, projection: []const u8) Self {
            var copy = self;
            copy.projection = projection;
            return copy;
        }
        pub fn where(self: Self, condition: RawCondition) Self {
            var copy = self;
            copy.condition = condition;
            return copy;
        }
        pub fn andWhere(self: Self, condition: RawCondition) Self {
            var copy = self;
            copy.additional_condition = condition;
            return copy;
        }
        pub fn orderBy(self: Self, column: []const u8, descending: bool) Self {
            var copy = self;
            copy.order_column = column;
            copy.descending = descending;
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
        pub fn innerJoin(self: Self, table: []const u8, left: RawColumn, right: RawColumn) Self {
            var copy = self;
            copy.join = .{ .kind = "INNER JOIN", .table = table, .left = left.name, .right = right.name };
            return copy;
        }
        pub fn leftJoin(self: Self, table: []const u8, left: RawColumn, right: RawColumn) Self {
            var copy = self;
            copy.join = .{ .kind = "LEFT JOIN", .table = table, .left = left.name, .right = right.name };
            return copy;
        }
        pub fn groupBy(self: Self, column: RawColumn) Self {
            var copy = self;
            copy.group_column = column.name;
            return copy;
        }
        pub fn count(self: Self, column: ?RawColumn) Self {
            var copy = self;
            copy.count_column = if (column) |item| item.name else null;
            return copy;
        }
        pub fn fetchAll(self: Self) !Result {
            var sql = std.ArrayList(u8).empty;
            defer sql.deinit(self.allocator);
            var values: [32]Value = undefined;
            var value_count: usize = 0;
            var owned_patterns = std.ArrayList([]u8).empty;
            defer {
                for (owned_patterns.items) |pattern| self.allocator.free(pattern);
                owned_patterns.deinit(self.allocator);
            }
            try sql.appendSlice(self.allocator, "SELECT ");
            if (self.count_column) |column| {
                try sql.appendSlice(self.allocator, "COUNT(");
                try appendIdentifier(self.allocator, &sql, column);
                try sql.append(self.allocator, ')');
            } else try sql.appendSlice(self.allocator, self.projection);
            try sql.appendSlice(self.allocator, " FROM ");
            try appendIdentifier(self.allocator, &sql, self.table);
            if (self.join) |join| {
                try sql.append(self.allocator, ' ');
                try sql.appendSlice(self.allocator, join.kind);
                try sql.append(self.allocator, ' ');
                try appendIdentifier(self.allocator, &sql, join.table);
                try sql.appendSlice(self.allocator, " ON ");
                try appendIdentifier(self.allocator, &sql, join.left);
                try sql.appendSlice(self.allocator, " = ");
                try appendIdentifier(self.allocator, &sql, join.right);
            }
            if (self.condition) |condition| {
                try sql.appendSlice(self.allocator, " WHERE ");
                try appendIdentifier(self.allocator, &sql, condition.column);
                try sql.append(self.allocator, ' ');
                try sql.appendSlice(self.allocator, condition.operator);
                if (!std.mem.eql(u8, condition.operator, "IS NULL") and !std.mem.eql(u8, condition.operator, "IS NOT NULL")) {
                    try sql.append(self.allocator, ' ');
                    try appendConditionValue(self.allocator, &sql, condition, &values, &value_count, &owned_patterns);
                }
            }
            if (self.additional_condition) |condition| {
                try sql.appendSlice(self.allocator, if (self.condition == null) " WHERE " else " AND ");
                try appendIdentifier(self.allocator, &sql, condition.column);
                try sql.append(self.allocator, ' ');
                try sql.appendSlice(self.allocator, condition.operator);
                if (!std.mem.eql(u8, condition.operator, "IS NULL") and !std.mem.eql(u8, condition.operator, "IS NOT NULL")) {
                    try sql.append(self.allocator, ' ');
                    try appendConditionValue(self.allocator, &sql, condition, &values, &value_count, &owned_patterns);
                }
            }
            if (self.group_column) |column| {
                try sql.appendSlice(self.allocator, " GROUP BY ");
                try appendIdentifier(self.allocator, &sql, column);
            }
            if (self.order_column) |column| {
                try sql.appendSlice(self.allocator, " ORDER BY ");
                try appendIdentifier(self.allocator, &sql, column);
                if (self.descending) try sql.appendSlice(self.allocator, " DESC");
            }
            if (self.limit_value) |amount| {
                const rendered = try std.fmt.allocPrint(self.allocator, " LIMIT {d}", .{amount});
                defer self.allocator.free(rendered);
                try sql.appendSlice(self.allocator, rendered);
            }
            if (self.offset_value) |amount| {
                const rendered = try std.fmt.allocPrint(self.allocator, " OFFSET {d}", .{amount});
                defer self.allocator.free(rendered);
                try sql.appendSlice(self.allocator, rendered);
            }
            return execute_fn(self.connection, sql.items, values[0..value_count]);
        }
    };
}

const RawJoin = struct {
    kind: []const u8,
    table: []const u8,
    left: []const u8,
    right: []const u8,
};

fn toValue(value: anytype) Value {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .{ .integer = @intCast(value) },
        .float, .comptime_float => .{ .real = @floatCast(value) },
        .bool => .{ .integer = if (value) 1 else 0 },
        .pointer => .{ .text = value },
        else => @compileError("unsupported RAW DSL value"),
    };
}

fn appendValue(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: Value) !void {
    switch (value) {
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
        .null => try list.appendSlice(allocator, "NULL"),
        .text => |text| {
            try list.append(allocator, '\'');
            for (text) |byte| {
                if (byte == '\'') try list.append(allocator, '\'');
                try list.append(allocator, byte);
            }
            try list.append(allocator, '\'');
        },
        .blob => |blob| {
            try list.append(allocator, '\'');
            try list.appendSlice(allocator, blob);
            try list.append(allocator, '\'');
        },
    }
}

fn appendConditionValue(allocator: std.mem.Allocator, list: *std.ArrayList(u8), condition: RawCondition, values: *[32]Value, count: *usize, owned_patterns: *std.ArrayList([]u8)) !void {
    if (count.* >= values.len) return error.InvalidSql;
    if (condition.value2) |second| {
        values[count.*] = condition.value;
        count.* += 1;
        try list.appendSlice(allocator, "?");
        try list.appendSlice(allocator, " AND ");
        values[count.*] = second;
        count.* += 1;
        return list.appendSlice(allocator, "?");
    }
    if (condition.pattern == .none) {
        values[count.*] = condition.value;
        count.* += 1;
        return list.appendSlice(allocator, "?");
    }
    if (condition.value != .text) return error.InvalidSql;
    const pattern = switch (condition.pattern) {
        .contains => try std.fmt.allocPrint(allocator, "%{s}%", .{condition.value.text}),
        .starts => try std.fmt.allocPrint(allocator, "{s}%", .{condition.value.text}),
        .ends => try std.fmt.allocPrint(allocator, "%{s}", .{condition.value.text}),
        .none => unreachable,
    };
    errdefer allocator.free(pattern);
    try owned_patterns.append(allocator, pattern);
    values[count.*] = .{ .text = pattern };
    count.* += 1;
    return list.appendSlice(allocator, "?");
}

fn appendIdentifier(allocator: std.mem.Allocator, list: *std.ArrayList(u8), identifier: []const u8) !void {
    if (identifier.len == 0) return error.InvalidSql;
    var start: usize = 0;
    while (start < identifier.len) {
        const end = std.mem.indexOfScalarPos(u8, identifier, start, '.') orelse identifier.len;
        const part = identifier[start..end];
        if (part.len == 0) return error.InvalidSql;
        try list.append(allocator, '"');
        for (part) |byte| {
            if (byte == 0) return error.InvalidSql;
            if (byte == '"') try list.append(allocator, '"');
            try list.append(allocator, byte);
        }
        try list.append(allocator, '"');
        if (end == identifier.len) break;
        try list.append(allocator, '.');
        start = end + 1;
    }
}
