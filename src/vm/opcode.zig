const std = @import("std");
const Value = @import("value.zig").Value;

pub const OpCode = enum {
    halt,
    gotoOp,
    ifOp,
    ifNotOp,
    returnOp,
    loadNull,
    loadInteger,
    loadReal,
    loadText,
    loadBlob,
    move,
    copy,
    add,
    subtract,
    multiply,
    divide,
    remainder,
    concat,
    bitAnd,
    bitOr,
    shiftLeft,
    shiftRight,
    bitNot,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    isOp,
    isNotOp,
    isNull,
    notNull,
    openRead,
    openWrite,
    openEphemeral,
    close,
    rewind,
    next,
    prev,
    seekGE,
    seekGT,
    seekLE,
    seekLT,
    seekEQ,
    column,
    rowid,
    makeRecord,
    insert,
    delete,
    newRowid,
    resultRow,
    function,
    aggStep,
    aggFinal,
};

pub const Instruction = struct {
    opcode: OpCode,
    p1: i32 = 0,
    p2: i32 = 0,
    p3: i32 = 0,
    p4: ?Value = null,
    p5: u16 = 0,
    register: usize = 0,
    value: Value = .null,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    maxRegisters: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{ .allocator = allocator, .instructions = .empty, .maxRegisters = 0 };
    }

    pub fn deinit(self: *Program) void {
        self.instructions.deinit(self.allocator);
    }

    pub fn append(self: *Program, instruction: Instruction) !void {
        try self.instructions.append(self.allocator, instruction);
    }

    pub fn emit(self: *Program, opcode: OpCode, p1: i32, p2: i32, p3: i32) !usize {
        const addr = self.instructions.items.len;
        try self.append(.{
            .opcode = opcode,
            .p1 = p1,
            .p2 = p2,
            .p3 = p3,
            .register = if (p2 >= 0) @as(usize, @intCast(p2)) else 0,
        });
        return addr;
    }

    pub fn emitValue(self: *Program, opcode: OpCode, p1: i32, p2: i32, p3: i32, val: Value) !usize {
        const addr = self.instructions.items.len;
        try self.append(.{
            .opcode = opcode,
            .p1 = p1,
            .p2 = p2,
            .p3 = p3,
            .p4 = val,
            .register = if (p2 >= 0) @as(usize, @intCast(p2)) else 0,
            .value = val,
        });
        return addr;
    }

    pub fn currentAddress(self: *const Program) usize {
        return self.instructions.items.len;
    }

    pub fn fixupJump(self: *Program, address: usize, target: i32) void {
        self.instructions.items[address].p2 = target;
    }
};

test "bytecode program stores instructions" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    try program.append(.{ .opcode = .loadInteger, .register = 0, .value = .{ .integer = 3 } });
    try std.testing.expectEqual(OpCode.loadInteger, program.instructions.items[0].opcode);
}

test "program emission and jump fixup" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    const jumpAddr = try program.emit(.gotoOp, 0, 0, 0);
    _ = try program.emit(.loadInteger, 0, 1, 0);
    const targetAddr = program.currentAddress();
    _ = try program.emit(.halt, 0, 0, 0);
    program.fixupJump(jumpAddr, @as(i32, @intCast(targetAddr)));
    try std.testing.expectEqual(@as(i32, 2), program.instructions.items[jumpAddr].p2);
}
