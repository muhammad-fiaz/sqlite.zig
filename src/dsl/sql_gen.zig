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
    };
    const literal = switch (expr.value) {
        .null => "NULL",
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .real => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .text => |v| try quote(allocator, v),
        .blob => |v| try quote(allocator, v),
    };
    defer if (expr.value == .integer or expr.value == .real or expr.value == .text or expr.value == .blob) allocator.free(literal);
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
