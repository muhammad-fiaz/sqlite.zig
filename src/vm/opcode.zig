//! VM instruction set: opcodes, operands, and programs.
//!
//! `Program` owns its instruction list; payloads follow the compiler's
//! ownership contract. `fixupJump` panics on a bad address (compiler bug,
//! never corrupt input). Semantics per opcode live in `vm/vm.zig`.
const std = @import("std");
const Value = @import("value.zig").Value;

/// Bytecode operation. Cursor, comparison, arithmetic, and aggregation
/// operations; see `vm.zig` for per-opcode semantics, NULL behavior, and
/// cursor/transaction interaction.
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
    transaction,
    autoCommit,
    savepoint,
    checkpoint,
    vacuum,
    createBtree,
    parseSchema,
    dropTable,
    dropIndex,
    dropTrigger,
    sorterOpen,
    sorterInsert,
    sorterSort,
    sorterNext,
    sorterData,
};

/// Single instruction: opcode plus operands. `p1`/`p2`/`p3` are
/// integer operands (registers, jump targets, cursor ids); `p4`/`value`
/// carry an optional scalar payload; `p5` holds flags. `register` mirrors
/// the destination register when `p2 >= 0`.
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

/// Append-only instruction sequence. Owned by the compiler output; freed by
/// `CompiledQuery.deinit`. `maxRegisters` sizes the VM register file.
pub const Program = struct {
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    maxRegisters: usize = 0,

    /// Empty program; caller `deinit`s. Register high-water starts at 0.
    pub fn init(allocator: std.mem.Allocator) Program {
        return .{ .allocator = allocator, .instructions = .empty, .maxRegisters = 0 };
    }

    /// Frees the instruction list (payloads follow the CompiledQuery contract).
    pub fn deinit(self: *Program) void {
        self.instructions.deinit(self.allocator);
    }

    /// Pushes one instruction (OOM propagates).
    pub fn append(self: *Program, instruction: Instruction) !void {
        try self.instructions.append(self.allocator, instruction);
    }

    /// Emits an operand-only instruction, returning its address for fixups.
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

    /// Emits an instruction with a scalar payload, returning its address.
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

    /// Next instruction address (i.e. current length).
    pub fn currentAddress(self: *const Program) usize {
        return self.instructions.items.len;
    }

    /// Patches a previously emitted jump's `p2` target. Panics on a bad
    /// address (compiler bug, never runtime input).
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
