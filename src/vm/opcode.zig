const std = @import("std");
const Value = @import("value.zig").Value;

pub const OpCode = enum { halt, load_null, load_integer, load_real, load_text, move };
pub const Instruction = struct { opcode: OpCode, register: usize = 0, value: Value = .null };

pub const Program = struct {
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    pub fn init(allocator: std.mem.Allocator) Program {
        return .{ .allocator = allocator, .instructions = .empty };
    }
    pub fn deinit(self: *Program) void {
        self.instructions.deinit(self.allocator);
    }
    pub fn append(self: *Program, instruction: Instruction) !void {
        try self.instructions.append(self.allocator, instruction);
    }
};

test "bytecode program stores instructions" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    try program.append(.{ .opcode = .load_integer, .register = 0, .value = .{ .integer = 3 } });
    try std.testing.expectEqual(OpCode.load_integer, program.instructions.items[0].opcode);
}
