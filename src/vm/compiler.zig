const std = @import("std");
const ast = @import("../sql/ast.zig");
const opcode = @import("opcode.zig");

pub fn compileLiteral(allocator: std.mem.Allocator, expression: ast.Expr) !opcode.Program {
    var program = opcode.Program.init(allocator);
    errdefer program.deinit();
    switch (expression) {
        .literal => |value| try program.append(.{ .opcode = switch (value) {
            .null => .load_null,
            .integer => .load_integer,
            .real => .load_real,
            .text, .blob => .load_text,
        }, .register = 0, .value = value }),
        else => return error.InvalidSql,
    }
    try program.append(.{ .opcode = .halt });
    return program;
}

test "compiler emits a constant program" {
    var program = try compileLiteral(std.testing.allocator, .{ .literal = .{ .integer = 5 } });
    defer program.deinit();
    try std.testing.expectEqual(opcode.OpCode.load_integer, program.instructions.items[0].opcode);
}
