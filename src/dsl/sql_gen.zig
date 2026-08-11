const std = @import("std");
const Expr = @import("expr.zig").Expr;

pub fn renderExpr(allocator: std.mem.Allocator, expr: Expr) ![]u8 {
    const left = if (expr.function) |function| if (expr.function_argument) |argument| blk: {
        const rendered = switch (argument) {
            .null => "NULL",
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .real => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .text => |v| try quote(allocator, v),
            .blob => |v| try quote(allocator, v),
        };
        defer if (argument == .integer or argument == .real or argument == .text or argument == .blob) allocator.free(rendered);
        break :blk try std.fmt.allocPrint(allocator, "{s}({s}, {s})", .{ function, expr.column, rendered });
    } else try std.fmt.allocPrint(allocator, "{s}({s})", .{ function, expr.column }) else try allocator.dupe(u8, expr.column);
    defer allocator.free(left);
    const operator = switch (expr.operator) {
        .equal => "=",
        .not_equal => "<>",
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
        .like => "LIKE",
        .not_like => "NOT LIKE",
        .glob => "GLOB",
        .not_glob => "NOT GLOB",
        .is_null => "IS NULL",
        .is_not_null => "IS NOT NULL",
        .is_value => "IS",
        .is_not_value => "IS NOT",
        .is_distinct => "IS DISTINCT FROM",
        .is_not_distinct => "IS NOT DISTINCT FROM",
        .between => "BETWEEN",
    };
    if (expr.operator == .is_null or expr.operator == .is_not_null) return std.fmt.allocPrint(allocator, "{s} {s}", .{ left, operator });
    const literal = switch (expr.value) {
        .null => "NULL",
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .real => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .text => |v| try quote(allocator, v),
        .blob => |v| try quote(allocator, v),
    };
    defer if (expr.value == .integer or expr.value == .real or expr.value == .text or expr.value == .blob) allocator.free(literal);
    if (expr.operator == .between) {
        const upper = expr.value2 orelse return error.InvalidExpression;
        if (upper == .null) return std.fmt.allocPrint(allocator, "{s} BETWEEN {s} AND NULL", .{ left, literal });
        const upper_literal = switch (upper) {
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .real => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .text => |v| try quote(allocator, v),
            .blob => |v| try quote(allocator, v),
            .null => unreachable,
        };
        defer allocator.free(upper_literal);
        return std.fmt.allocPrint(allocator, "{s} BETWEEN {s} AND {s}", .{ left, literal, upper_literal });
    }
    return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ left, operator, literal });
}

fn quote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    try list.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') try list.append(allocator, '\'');
        try list.append(allocator, byte);
    }
    try list.append(allocator, '\'');
    return list.toOwnedSlice(allocator);
}

test "DSL expressions render to SQL" {
    const expr = Expr{ .column = "age", .operator = .greater, .value = .{ .integer = 18 } };
    const sql = try renderExpr(std.testing.allocator, expr);
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings("age > 18", sql);
}
