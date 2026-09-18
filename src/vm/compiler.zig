const std = @import("std");
const ast = @import("../sql/ast.zig");
const opcode = @import("opcode.zig");

pub fn compileLiteral(allocator: std.mem.Allocator, expression: ast.Expr) !opcode.Program {
    var program = opcode.Program.init(allocator);
    errdefer program.deinit();
    switch (expression) {
        .literal => |value| try program.append(.{ .opcode = switch (value) {
            .null => .loadNull,
            .integer => .loadInteger,
            .real => .loadReal,
            .text, .blob => .loadText,
        }, .register = 0, .value = value }),
        else => return error.InvalidSql,
    }
    try program.append(.{ .opcode = .halt });
    return program;
}

test "compiler emits a constant program" {
    var program = try compileLiteral(std.testing.allocator, .{ .literal = .{ .integer = 5 } });
    defer program.deinit();
    try std.testing.expectEqual(opcode.OpCode.loadInteger, program.instructions.items[0].opcode);
}
