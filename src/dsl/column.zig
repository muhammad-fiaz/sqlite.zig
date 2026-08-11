const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const Expr = @import("expr.zig").Expr;

pub fn Column(comptime table_name: []const u8, comptime column_name: []const u8, comptime FieldType: type) type {
    return struct {
        pub const table = table_name;
        pub const name = column_name;
        pub const field_type = FieldType;

        pub fn eq(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .equal, .value = toValue(value) };
        }
        pub fn ne(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .not_equal, .value = toValue(value) };
        }
        pub fn gt(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .greater, .value = toValue(value) };
        }
        pub fn ge(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .greater_equal, .value = toValue(value) };
        }
        pub fn lt(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .less, .value = toValue(value) };
        }
        pub fn le(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .less_equal, .value = toValue(value) };
        }
        pub fn like(_: @This(), value: []const u8) Expr {
            return .{ .column = column_name, .operator = .like, .value = toValue(value) };
        }
        pub fn notLike(_: @This(), value: []const u8) Expr {
            return .{ .column = column_name, .operator = .not_like, .value = toValue(value) };
        }
        pub fn contains(_: @This(), comptime value: []const u8) Expr {
            return .{ .column = column_name, .operator = .like, .value = toValue(std.fmt.comptimePrint("%{s}%", .{value})) };
        }
        pub fn notContains(_: @This(), comptime value: []const u8) Expr {
            return .{ .column = column_name, .operator = .not_like, .value = toValue(std.fmt.comptimePrint("%{s}%", .{value})) };
        }
        pub fn startsWith(_: @This(), comptime value: []const u8) Expr {
            return .{ .column = column_name, .operator = .like, .value = toValue(std.fmt.comptimePrint("{s}%", .{value})) };
        }
        pub fn endsWith(_: @This(), comptime value: []const u8) Expr {
            return .{ .column = column_name, .operator = .like, .value = toValue(std.fmt.comptimePrint("%{s}", .{value})) };
        }
        pub fn glob(_: @This(), value: []const u8) Expr {
            return .{ .column = column_name, .operator = .glob, .value = toValue(value) };
        }
        pub fn notGlob(_: @This(), value: []const u8) Expr {
            return .{ .column = column_name, .operator = .not_glob, .value = toValue(value) };
        }
        pub fn isNull(_: @This()) Expr {
            return .{ .column = column_name, .operator = .is_null, .value = .null };
        }
        pub fn isNotNull(_: @This()) Expr {
            return .{ .column = column_name, .operator = .is_not_null, .value = .null };
        }
        pub fn isValue(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .is_value, .value = toValue(value) };
        }
        pub fn isNotValue(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .is_not_value, .value = toValue(value) };
        }
        pub fn isDistinctFrom(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .is_distinct, .value = toValue(value) };
        }
        pub fn isNotDistinctFrom(_: @This(), value: anytype) Expr {
            return .{ .column = column_name, .operator = .is_not_distinct, .value = toValue(value) };
        }
        pub fn between(_: @This(), lower: anytype, upper: anytype) Expr {
            return .{ .column = column_name, .operator = .between, .value = toValue(lower), .value2 = toValue(upper) };
        }
        pub fn asc(_: @This()) @import("query_builder.zig").Order {
            return .{ .column = column_name, .descending = false };
        }
        pub fn desc(_: @This()) @import("query_builder.zig").Order {
            return .{ .column = column_name, .descending = true };
        }
    };
}

fn toValue(value: anytype) Value {
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
        .pointer => .{ .text = value },
        else => @compileError("unsupported DSL value"),
    };
}
