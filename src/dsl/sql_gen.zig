const std = @import("std");
const Expr = @import("expr.zig").Expr;

pub fn renderExpr(allocator: std.mem.Allocator, expr: Expr) ![]u8 {
    const operator = switch (expr.operator) {
        .equal => "=",
        .not_equal => "<>",
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
        .like => "LIKE",
        .is_null => "IS NULL",
        .is_not_null => "IS NOT NULL",
        .between => "BETWEEN",
    };
    if (expr.operator == .is_null or expr.operator == .is_not_null) return std.fmt.allocPrint(allocator, "{s} {s}", .{ expr.column, operator });
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
        if (upper == .null) return std.fmt.allocPrint(allocator, "{s} BETWEEN {s} AND NULL", .{ expr.column, literal });
        const upper_literal = switch (upper) {
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .real => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .text => |v| try quote(allocator, v),
            .blob => |v| try quote(allocator, v),
            .null => unreachable,
        };
        defer allocator.free(upper_literal);
        return std.fmt.allocPrint(allocator, "{s} BETWEEN {s} AND {s}", .{ expr.column, literal, upper_literal });
    }
    return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ expr.column, operator, literal });
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
