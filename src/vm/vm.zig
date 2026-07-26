const std = @import("std");
const Program = @import("opcode.zig").Program;
const OpCode = @import("opcode.zig").OpCode;
const Value = @import("value.zig").Value;

pub fn run(allocator: std.mem.Allocator, program: *const Program, register_count: usize) ![]Value {
    const registers = try allocator.alloc(Value, register_count);
    @memset(registers, .null);
    var pc: usize = 0;
    while (pc < program.instructions.items.len) : (pc += 1) {
        const instruction = program.instructions.items[pc];
        switch (instruction.opcode) {
            .halt => break,
            .load_null, .load_integer, .load_real, .load_text => registers[instruction.register] = instruction.value,
            .move => registers[instruction.register] = registers[instruction.value.integer],
        }
    }
    return registers;
}

test "virtual machine executes constant bytecode" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    try program.append(.{ .opcode = .load_integer, .register = 0, .value = .{ .integer = 9 } });
    try program.append(.{ .opcode = .halt });
    const values = try run(std.testing.allocator, &program, 1);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(i64, 9), values[0].integer);
}
