const std = @import("std");
const Program = @import("opcode.zig").Program;
const Instruction = @import("opcode.zig").Instruction;
const OpCode = @import("opcode.zig").OpCode;
const Value = @import("value.zig").Value;
const Comparison = @import("value.zig").Comparison;
const Collation = @import("value.zig").Collation;
const Schema = @import("../catalog/schema.zig").Schema;
const Table = @import("../catalog/schema.zig").Table;
const Result = @import("../connection/result.zig").Result;

pub const TableCursor = struct {
    table: *const Table,
    rowIndex: usize = 0,
    eof: bool = true,

    pub fn init(table: *const Table) TableCursor {
        return .{
            .table = table,
            .rowIndex = 0,
            .eof = table.rows.items.len == 0,
        };
    }

    pub fn rewind(self: *TableCursor) bool {
        self.rowIndex = 0;
        self.eof = self.table.rows.items.len == 0;
        return self.eof;
    }

    pub fn next(self: *TableCursor) bool {
        if (self.eof) return false;
        self.rowIndex += 1;
        self.eof = self.rowIndex >= self.table.rows.items.len;
        return !self.eof;
    }

    pub fn prev(self: *TableCursor) bool {
        if (self.rowIndex == 0 or self.table.rows.items.len == 0) {
            self.eof = true;
            return false;
        }
        self.rowIndex -= 1;
        self.eof = false;
        return true;
    }

    pub fn column(self: *const TableCursor, colIdx: usize) Value {
        if (self.eof or self.rowIndex >= self.table.rows.items.len) return .null;
        const row = self.table.rows.items[self.rowIndex];
        if (colIdx < row.values.len) return row.values[colIdx];
        return .null;
    }

    pub fn rowid(self: *const TableCursor) i64 {
        return @intCast(self.rowIndex + 1);
    }
};

pub const EphemeralCursor = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList([]Value),
    rowIndex: usize = 0,
    eof: bool = true,

    pub fn init(allocator: std.mem.Allocator) EphemeralCursor {
        return .{
            .allocator = allocator,
            .rows = .empty,
            .rowIndex = 0,
            .eof = true,
        };
    }

    pub fn deinit(self: *EphemeralCursor) void {
        for (self.rows.items) |row| {
            for (row) |val| val.free(self.allocator);
            self.allocator.free(row);
        }
        self.rows.deinit(self.allocator);
    }

    pub fn insert(self: *EphemeralCursor, values: []const Value) !void {
        const row = try self.allocator.alloc(Value, values.len);
        for (values, 0..) |v, i| {
            row[i] = try v.clone(self.allocator);
        }
        try self.rows.append(self.allocator, row);
    }

    pub fn rewind(self: *EphemeralCursor) bool {
        self.rowIndex = 0;
        self.eof = self.rows.items.len == 0;
        return self.eof;
    }

    pub fn next(self: *EphemeralCursor) bool {
        if (self.eof) return false;
        self.rowIndex += 1;
        self.eof = self.rowIndex >= self.rows.items.len;
        return !self.eof;
    }

    pub fn column(self: *const EphemeralCursor, colIdx: usize) Value {
        if (self.eof or self.rowIndex >= self.rows.items.len) return .null;
        const row = self.rows.items[self.rowIndex];
        if (colIdx < row.len) return row[colIdx];
        return .null;
    }

    pub fn rowid(self: *const EphemeralCursor) i64 {
        return @intCast(self.rowIndex + 1);
    }
};

pub const Cursor = union(enum) {
    table: TableCursor,
    ephemeral: EphemeralCursor,

    pub fn deinit(self: *Cursor) void {
        switch (self.*) {
            .table => {},
            .ephemeral => |*e| e.deinit(),
        }
    }

    pub fn rewind(self: *Cursor) bool {
        return switch (self.*) {
            .table => |*t| t.rewind(),
            .ephemeral => |*e| e.rewind(),
        };
    }

    pub fn next(self: *Cursor) bool {
        return switch (self.*) {
            .table => |*t| t.next(),
            .ephemeral => |*e| e.next(),
        };
    }

    pub fn prev(self: *Cursor) bool {
        return switch (self.*) {
            .table => |*t| t.prev(),
            .ephemeral => false,
        };
    }

    pub fn column(self: *const Cursor, colIdx: usize) Value {
        return switch (self.*) {
            .table => |*t| t.column(colIdx),
            .ephemeral => |*e| e.column(colIdx),
        };
    }

    pub fn rowid(self: *const Cursor) i64 {
        return switch (self.*) {
            .table => |*t| t.rowid(),
            .ephemeral => |*e| e.rowid(),
        };
    }
};

pub const AggState = struct {
    count: i64 = 0,
    sumInt: i64 = 0,
    sumReal: f64 = 0.0,
    isReal: bool = false,
    hasValue: bool = false,
    minVal: ?Value = null,
    maxVal: ?Value = null,
};

fn toReal(val: Value) f64 {
    return switch (val) {
        .null => 0.0,
        .integer => |i| @floatFromInt(i),
        .real => |r| r,
        .text => |t| std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch 0.0,
        .blob => 0.0,
    };
}

fn toInt(val: Value) i64 {
    return switch (val) {
        .null => 0,
        .integer => |i| i,
        .real => |r| @intFromFloat(r),
        .text => |t| std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10) catch 0,
        .blob => 0,
    };
}

fn evalAdd(a: Value, b: Value) Value {
    if (a == .null or b == .null) return .null;
    if (a == .integer and b == .integer) {
        const sum = std.math.add(i64, a.integer, b.integer) catch {
            return .{ .real = @as(f64, @floatFromInt(a.integer)) + @as(f64, @floatFromInt(b.integer)) };
        };
        return .{ .integer = sum };
    }
    return .{ .real = toReal(a) + toReal(b) };
}

fn evalSub(a: Value, b: Value) Value {
    if (a == .null or b == .null) return .null;
    if (a == .integer and b == .integer) {
        const diff = std.math.sub(i64, a.integer, b.integer) catch {
            return .{ .real = @as(f64, @floatFromInt(a.integer)) - @as(f64, @floatFromInt(b.integer)) };
        };
        return .{ .integer = diff };
    }
    return .{ .real = toReal(a) - toReal(b) };
}

fn evalMul(a: Value, b: Value) Value {
    if (a == .null or b == .null) return .null;
    if (a == .integer and b == .integer) {
        const prod = std.math.mul(i64, a.integer, b.integer) catch {
            return .{ .real = @as(f64, @floatFromInt(a.integer)) * @as(f64, @floatFromInt(b.integer)) };
        };
        return .{ .integer = prod };
    }
    return .{ .real = toReal(a) * toReal(b) };
}

fn evalDiv(a: Value, b: Value) Value {
    if (a == .null or b == .null) return .null;
    if (a == .integer and b == .integer) {
        if (b.integer == 0) return .null;
        return .{ .integer = @divTrunc(a.integer, b.integer) };
    }
    const divisor = toReal(b);
    if (divisor == 0.0) return .null;
    return .{ .real = toReal(a) / divisor };
}

fn evalRem(a: Value, b: Value) Value {
    if (a == .null or b == .null) return .null;
    const divisor = toInt(b);
    if (divisor == 0) return .null;
    return .{ .integer = @rem(toInt(a), divisor) };
}

fn evalConcat(allocator: std.mem.Allocator, a: Value, b: Value) !Value {
    if (a == .null or b == .null) return .null;
    var bufA: [64]u8 = undefined;
    const strA: []const u8 = switch (a) {
        .text => |t| t,
        .blob => |b_bytes| b_bytes,
        .integer => |i| try std.fmt.bufPrint(&bufA, "{d}", .{i}),
        .real => |r| try std.fmt.bufPrint(&bufA, "{d}", .{r}),
        .null => unreachable,
    };
    var bufB: [64]u8 = undefined;
    const strB: []const u8 = switch (b) {
        .text => |t| t,
        .blob => |b_bytes| b_bytes,
        .integer => |i| try std.fmt.bufPrint(&bufB, "{d}", .{i}),
        .real => |r| try std.fmt.bufPrint(&bufB, "{d}", .{r}),
        .null => unreachable,
    };
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ strA, strB });
    return .{ .text = combined };
}

fn evalBitAnd(a: Value, b: Value) Value {
    if (a == .null or b == .null) return .null;
    return .{ .integer = toInt(a) & toInt(b) };
}

fn evalBitOr(a: Value, b: Value) Value {
    if (a == .null or b == .null) return .null;
    return .{ .integer = toInt(a) | toInt(b) };
}

fn evalShiftLeft(a: Value, b: Value) Value {
    if (a == .null or b == .null) return .null;
    const shift = toInt(b);
    if (shift < 0 or shift >= 64) return .{ .integer = 0 };
    return .{ .integer = toInt(a) << @as(u6, @intCast(shift)) };
}

fn evalShiftRight(a: Value, b: Value) Value {
    if (a == .null or b == .null) return .null;
    const shift = toInt(b);
    if (shift < 0 or shift >= 64) return .{ .integer = 0 };
    return .{ .integer = toInt(a) >> @as(u6, @intCast(shift)) };
}

fn evalBitNot(a: Value) Value {
    if (a == .null) return .null;
    return .{ .integer = ~toInt(a) };
}

fn evalCmp(a: Value, cmp: Comparison, b: Value, col: Collation, nullEq: bool) bool {
    if (nullEq) {
        if (a == .null and b == .null) return cmp == .equal or cmp == .lessEqual or cmp == .greaterEqual;
        if (a == .null) return cmp == .less or cmp == .lessEqual or cmp == .notEqual;
        if (b == .null) return cmp == .greater or cmp == .greaterEqual or cmp == .notEqual;
    }
    return a.compare(cmp, b, col);
}

const functions = @import("../sql/functions.zig");

fn evalFunction(allocator: std.mem.Allocator, name: []const u8, args: []const Value) !Value {
    return functions.evalScalar(allocator, name, args);
}

pub const VirtualMachine = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    schema: ?*Schema,
    cursors: [32]?Cursor,
    aggStates: [16]AggState,
    changes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, schema: ?*Schema) VirtualMachine {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .schema = schema,
            .cursors = [_]?Cursor{null} ** 32,
            .aggStates = [_]AggState{.{}} ** 16,
            .changes = 0,
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        for (&self.cursors) |*cursorOpt| {
            if (cursorOpt.*) |*cursor| cursor.deinit();
            cursorOpt.* = null;
        }
        self.arena.deinit();
    }

    pub fn execute(self: *VirtualMachine, program: *const Program, columnNames: []const []const u8) !Result {
        var outputRows: std.ArrayList([]Value) = .empty;
        errdefer {
            for (outputRows.items) |row| {
                for (row) |val| val.free(self.allocator);
                self.allocator.free(row);
            }
            outputRows.deinit(self.allocator);
        }

        var maxReg: usize = program.maxRegisters;
        for (program.instructions.items) |inst| {
            if (inst.register >= maxReg) maxReg = inst.register + 1;
            if (inst.p1 >= 0 and @as(usize, @intCast(inst.p1)) >= maxReg) maxReg = @as(usize, @intCast(inst.p1)) + 1;
            if (inst.p2 >= 0 and @as(usize, @intCast(inst.p2)) >= maxReg) maxReg = @as(usize, @intCast(inst.p2)) + 1;
            if (inst.p3 >= 0 and @as(usize, @intCast(inst.p3)) >= maxReg) maxReg = @as(usize, @intCast(inst.p3)) + 1;
        }
        const regCount = @max(maxReg, 32);
        const registers = try self.arena.allocator().alloc(Value, regCount);
        @memset(registers, .null);

        const arenaAlloc = self.arena.allocator();
        var pc: usize = 0;
        var callStack: std.ArrayList(usize) = .empty;
        defer callStack.deinit(arenaAlloc);

        while (pc < program.instructions.items.len) {
            const inst = program.instructions.items[pc];
            switch (inst.opcode) {
                .halt => break,
                .gotoOp => {
                    pc = @as(usize, @intCast(inst.p2));
                    continue;
                },
                .ifOp => {
                    const regIdx = @as(usize, @intCast(inst.p1));
                    if (registers[regIdx].isTruthy()) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .ifNotOp => {
                    const regIdx = @as(usize, @intCast(inst.p1));
                    if (!registers[regIdx].isTruthy()) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .returnOp => {
                    if (callStack.pop()) |returnAddr| {
                        pc = returnAddr;
                        continue;
                    }
                    break;
                },
                .loadNull => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = .null;
                },
                .loadInteger => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = if (inst.p4) |v| v else if (inst.value != .null) inst.value else .{ .integer = inst.p1 };
                },
                .loadReal => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = if (inst.p4) |v| v else inst.value;
                },
                .loadText => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = if (inst.p4) |v| v else inst.value;
                },
                .loadBlob => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = if (inst.p4) |v| v else inst.value;
                },
                .move => {
                    if (inst.value == .integer and inst.p1 == 0 and inst.p3 == 0) {
                        registers[inst.register] = registers[@as(usize, @intCast(inst.value.integer))];
                    } else {
                        const src = @as(usize, @intCast(inst.p1));
                        const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                        const count = if (inst.p3 > 0) @as(usize, @intCast(inst.p3)) else 1;
                        for (0..count) |i| registers[dst + i] = registers[src + i];
                    }
                },
                .copy => {
                    const src = @as(usize, @intCast(inst.p1));
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = try registers[src].clone(arenaAlloc);
                },
                .add => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalAdd(registers[p1], registers[p2]);
                },
                .subtract => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalSub(registers[p1], registers[p2]);
                },
                .multiply => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalMul(registers[p1], registers[p2]);
                },
                .divide => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalDiv(registers[p1], registers[p2]);
                },
                .remainder => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalRem(registers[p1], registers[p2]);
                },
                .concat => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = try evalConcat(arenaAlloc, registers[p1], registers[p2]);
                },
                .bitAnd => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalBitAnd(registers[p1], registers[p2]);
                },
                .bitOr => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalBitOr(registers[p1], registers[p2]);
                },
                .shiftLeft => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalShiftLeft(registers[p1], registers[p2]);
                },
                .shiftRight => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalShiftRight(registers[p1], registers[p2]);
                },
                .bitNot => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[p2] = evalBitNot(registers[p1]);
                },
                .eq, .ne, .lt, .le, .gt, .ge => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p3 = @as(usize, @intCast(inst.p3));
                    const col: Collation = if (inst.p4) |p4v| (if (p4v == .text) Collation.fromName(p4v.text) else .binary) else .binary;
                    const nullEq = (inst.p5 & 1) != 0;
                    const cmp: Comparison = switch (inst.opcode) {
                        .eq => .equal,
                        .ne => .notEqual,
                        .lt => .less,
                        .le => .lessEqual,
                        .gt => .greater,
                        .ge => .greaterEqual,
                        else => unreachable,
                    };
                    if (evalCmp(registers[p1], cmp, registers[p3], col, nullEq)) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .isOp, .isNotOp => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p3 = @as(usize, @intCast(inst.p3));
                    const isSame = registers[p1].sameValue(registers[p3]);
                    const matches = if (inst.opcode == .isOp) isSame else !isSame;
                    if (matches) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .isNull => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    if (registers[p1] == .null) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .notNull => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    if (registers[p1] != .null) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .openRead, .openWrite => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    if (inst.p4) |tableNameVal| {
                        if (tableNameVal == .text) {
                            if (self.schema) |sch| {
                                if (sch.find(tableNameVal.text)) |table| {
                                    self.cursors[cIdx] = .{ .table = TableCursor.init(table) };
                                } else return error.TableNotFound;
                            } else return error.TableNotFound;
                        }
                    }
                },
                .openEphemeral => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    self.cursors[cIdx] = .{ .ephemeral = EphemeralCursor.init(arenaAlloc) };
                },
                .close => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    if (self.cursors[cIdx]) |*c| c.deinit();
                    self.cursors[cIdx] = null;
                },
                .rewind => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    if (self.cursors[cIdx]) |*cursor| {
                        if (cursor.rewind()) {
                            pc = @as(usize, @intCast(inst.p2));
                            continue;
                        }
                    } else return error.CursorNotFound;
                },
                .next => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    if (self.cursors[cIdx]) |*cursor| {
                        if (cursor.next()) {
                            pc = @as(usize, @intCast(inst.p2));
                            continue;
                        }
                    } else return error.CursorNotFound;
                },
                .prev => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    if (self.cursors[cIdx]) |*cursor| {
                        if (cursor.prev()) {
                            pc = @as(usize, @intCast(inst.p2));
                            continue;
                        }
                    } else return error.CursorNotFound;
                },
                .seekGE, .seekGT, .seekLE, .seekLT, .seekEQ => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    const keyReg = @as(usize, @intCast(inst.p3));
                    const keyVal = registers[keyReg];
                    if (self.cursors[cIdx]) |*cursor| {
                        var found = false;
                        _ = cursor.rewind();
                        while (true) {
                            const curVal = cursor.column(0);
                            const match = switch (inst.opcode) {
                                .seekEQ => curVal.sameValue(keyVal),
                                .seekGE => curVal.compare(.greaterEqual, keyVal, .binary),
                                .seekGT => curVal.compare(.greater, keyVal, .binary),
                                .seekLE => curVal.compare(.lessEqual, keyVal, .binary),
                                .seekLT => curVal.compare(.less, keyVal, .binary),
                                else => false,
                            };
                            if (match) {
                                found = true;
                                break;
                            }
                            if (!cursor.next()) break;
                        }
                        if (!found) {
                            pc = @as(usize, @intCast(inst.p2));
                            continue;
                        }
                    } else return error.CursorNotFound;
                },
                .column => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    const colIdx = @as(usize, @intCast(inst.p2));
                    const dst = @as(usize, @intCast(inst.p3));
                    if (self.cursors[cIdx]) |*cursor| {
                        registers[dst] = try cursor.column(colIdx).clone(arenaAlloc);
                    } else return error.CursorNotFound;
                },
                .rowid => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    const dst = @as(usize, @intCast(inst.p2));
                    if (self.cursors[cIdx]) |*cursor| {
                        registers[dst] = .{ .integer = cursor.rowid() };
                    } else return error.CursorNotFound;
                },
                .makeRecord => {
                    const start = @as(usize, @intCast(inst.p1));
                    const count = @as(usize, @intCast(inst.p2));
                    const dst = @as(usize, @intCast(inst.p3));
                    if (count > 0) registers[dst] = registers[start];
                },
                .insert => {
                    const cIdx = @as(usize, @intCast(inst.p1));
                    const recReg = @as(usize, @intCast(inst.p2));
                    if (self.cursors[cIdx]) |*cursor| {
                        switch (cursor.*) {
                            .ephemeral => |*e| try e.insert(registers[recReg .. recReg + 1]),
                            .table => |*t| {
                                if (self.schema) |sch| {
                                    if (sch.find(t.table.name)) |mutTable| {
                                        const r = try self.allocator.alloc(Value, 1);
                                        r[0] = try registers[recReg].clone(self.allocator);
                                        try mutTable.rows.append(self.allocator, .{ .values = r });
                                        self.changes += 1;
                                    }
                                }
                            },
                        }
                    } else return error.CursorNotFound;
                },
                .delete => {
                    self.changes += 1;
                },
                .newRowid => {
                    const dst = @as(usize, @intCast(inst.p2));
                    registers[dst] = .{ .integer = @as(i64, @intCast(self.changes + 1)) };
                },
                .resultRow => {
                    const start = @as(usize, @intCast(inst.p1));
                    const count = @as(usize, @intCast(inst.p2));
                    const row = try self.allocator.alloc(Value, count);
                    errdefer self.allocator.free(row);
                    for (0..count) |i| {
                        row[i] = try registers[start + i].clone(self.allocator);
                    }
                    try outputRows.append(self.allocator, row);
                },
                .function => {
                    const dst = @as(usize, @intCast(inst.p1));
                    const start = @as(usize, @intCast(inst.p2));
                    const count = @as(usize, @intCast(inst.p3));
                    const funcName = if (inst.p4) |p4v| (if (p4v == .text) p4v.text else return error.Unsupported) else return error.Unsupported;
                    registers[dst] = try evalFunction(arenaAlloc, funcName, registers[start .. start + count]);
                },
                .aggStep => {
                    const aggIdx = @as(usize, @intCast(inst.p1));
                    const argReg = @as(usize, @intCast(inst.p2));
                    const funcName = if (inst.p4) |p4v| (if (p4v == .text) p4v.text else "") else "";
                    const argVal = registers[argReg];
                    var state = &self.aggStates[aggIdx];
                    if (std.ascii.eqlIgnoreCase(funcName, "count")) {
                        if (argVal != .null) state.count += 1;
                    } else if (std.ascii.eqlIgnoreCase(funcName, "sum") or std.ascii.eqlIgnoreCase(funcName, "total")) {
                        if (argVal != .null) {
                            state.hasValue = true;
                            switch (argVal) {
                                .integer => |i| {
                                    state.sumInt += i;
                                    state.sumReal += @as(f64, @floatFromInt(i));
                                },
                                .real => |r| {
                                    state.isReal = true;
                                    state.sumReal += r;
                                },
                                else => {},
                            }
                        }
                    } else if (std.ascii.eqlIgnoreCase(funcName, "min")) {
                        if (argVal != .null) {
                            if (state.minVal == null or argVal.order(state.minVal.?, .binary) == .lt) {
                                state.minVal = argVal;
                            }
                        }
                    } else if (std.ascii.eqlIgnoreCase(funcName, "max")) {
                        if (argVal != .null) {
                            if (state.maxVal == null or argVal.order(state.maxVal.?, .binary) == .gt) {
                                state.maxVal = argVal;
                            }
                        }
                    }
                },
                .aggFinal => {
                    const dst = @as(usize, @intCast(inst.p1));
                    const aggIdx = @as(usize, @intCast(inst.p2));
                    const funcName = if (inst.p4) |p4v| (if (p4v == .text) p4v.text else "") else "";
                    const state = self.aggStates[aggIdx];
                    if (std.ascii.eqlIgnoreCase(funcName, "count")) {
                        registers[dst] = .{ .integer = state.count };
                    } else if (std.ascii.eqlIgnoreCase(funcName, "sum")) {
                        registers[dst] = if (!state.hasValue) .null else if (state.isReal) .{ .real = state.sumReal } else .{ .integer = state.sumInt };
                    } else if (std.ascii.eqlIgnoreCase(funcName, "total")) {
                        registers[dst] = .{ .real = state.sumReal };
                    } else if (std.ascii.eqlIgnoreCase(funcName, "avg")) {
                        registers[dst] = if (state.count == 0) .null else .{ .real = state.sumReal / @as(f64, @floatFromInt(state.count)) };
                    } else if (std.ascii.eqlIgnoreCase(funcName, "min")) {
                        registers[dst] = state.minVal orelse .null;
                    } else if (std.ascii.eqlIgnoreCase(funcName, "max")) {
                        registers[dst] = state.maxVal orelse .null;
                    }
                },
            }
            pc += 1;
        }

        const cols = try self.allocator.alloc([]const u8, columnNames.len);
        var colIdx: usize = 0;
        errdefer {
            for (0..colIdx) |i| self.allocator.free(cols[i]);
            self.allocator.free(cols);
        }
        for (columnNames) |name| {
            cols[colIdx] = try self.allocator.dupe(u8, name);
            colIdx += 1;
        }

        return Result{
            .allocator = self.allocator,
            .columns = cols,
            .rows = try outputRows.toOwnedSlice(self.allocator),
            .changes = self.changes,
        };
    }

    pub fn runProgram(self: *VirtualMachine, program: *const Program, registerCount: usize) ![]Value {
        var maxReg: usize = program.maxRegisters;
        for (program.instructions.items) |inst| {
            if (inst.register >= maxReg) maxReg = inst.register + 1;
            if (inst.p1 >= 0 and @as(usize, @intCast(inst.p1)) >= maxReg) maxReg = @as(usize, @intCast(inst.p1)) + 1;
            if (inst.p2 >= 0 and @as(usize, @intCast(inst.p2)) >= maxReg) maxReg = @as(usize, @intCast(inst.p2)) + 1;
            if (inst.p3 >= 0 and @as(usize, @intCast(inst.p3)) >= maxReg) maxReg = @as(usize, @intCast(inst.p3)) + 1;
        }
        const regCount = @max(@max(maxReg, registerCount), 32);
        const registers = try self.arena.allocator().alloc(Value, regCount);
        @memset(registers, .null);

        const arenaAlloc = self.arena.allocator();
        var pc: usize = 0;

        while (pc < program.instructions.items.len) {
            const inst = program.instructions.items[pc];
            switch (inst.opcode) {
                .halt => break,
                .gotoOp => {
                    pc = @as(usize, @intCast(inst.p2));
                    continue;
                },
                .ifOp => {
                    const regIdx = @as(usize, @intCast(inst.p1));
                    if (registers[regIdx].isTruthy()) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .ifNotOp => {
                    const regIdx = @as(usize, @intCast(inst.p1));
                    if (!registers[regIdx].isTruthy()) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .returnOp => break,
                .loadNull => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = .null;
                },
                .loadInteger => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = if (inst.p4) |v| v else if (inst.value != .null) inst.value else .{ .integer = inst.p1 };
                },
                .loadReal => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = if (inst.p4) |v| v else inst.value;
                },
                .loadText => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = if (inst.p4) |v| v else inst.value;
                },
                .loadBlob => {
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = if (inst.p4) |v| v else inst.value;
                },
                .move => {
                    if (inst.value == .integer and inst.p1 == 0 and inst.p3 == 0) {
                        registers[inst.register] = registers[@as(usize, @intCast(inst.value.integer))];
                    } else {
                        const src = @as(usize, @intCast(inst.p1));
                        const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                        const count = if (inst.p3 > 0) @as(usize, @intCast(inst.p3)) else 1;
                        for (0..count) |i| registers[dst + i] = registers[src + i];
                    }
                },
                .copy => {
                    const src = @as(usize, @intCast(inst.p1));
                    const dst = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[dst] = try registers[src].clone(arenaAlloc);
                },
                .add => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalAdd(registers[p1], registers[p2]);
                },
                .subtract => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalSub(registers[p1], registers[p2]);
                },
                .multiply => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalMul(registers[p1], registers[p2]);
                },
                .divide => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalDiv(registers[p1], registers[p2]);
                },
                .remainder => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalRem(registers[p1], registers[p2]);
                },
                .concat => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = try evalConcat(arenaAlloc, registers[p1], registers[p2]);
                },
                .bitAnd => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalBitAnd(registers[p1], registers[p2]);
                },
                .bitOr => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalBitOr(registers[p1], registers[p2]);
                },
                .shiftLeft => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalShiftLeft(registers[p1], registers[p2]);
                },
                .shiftRight => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = @as(usize, @intCast(inst.p2));
                    const p3 = @as(usize, @intCast(inst.p3));
                    registers[p3] = evalShiftRight(registers[p1], registers[p2]);
                },
                .bitNot => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p2 = if (inst.p2 > 0) @as(usize, @intCast(inst.p2)) else inst.register;
                    registers[p2] = evalBitNot(registers[p1]);
                },
                .eq, .ne, .lt, .le, .gt, .ge => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p3 = @as(usize, @intCast(inst.p3));
                    const col: Collation = if (inst.p4) |p4v| (if (p4v == .text) Collation.fromName(p4v.text) else .binary) else .binary;
                    const nullEq = (inst.p5 & 1) != 0;
                    const cmp: Comparison = switch (inst.opcode) {
                        .eq => .equal,
                        .ne => .notEqual,
                        .lt => .less,
                        .le => .lessEqual,
                        .gt => .greater,
                        .ge => .greaterEqual,
                        else => unreachable,
                    };
                    if (evalCmp(registers[p1], cmp, registers[p3], col, nullEq)) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .isOp, .isNotOp => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    const p3 = @as(usize, @intCast(inst.p3));
                    const isSame = registers[p1].sameValue(registers[p3]);
                    const matches = if (inst.opcode == .isOp) isSame else !isSame;
                    if (matches) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .isNull => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    if (registers[p1] == .null) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .notNull => {
                    const p1 = @as(usize, @intCast(inst.p1));
                    if (registers[p1] != .null) {
                        pc = @as(usize, @intCast(inst.p2));
                        continue;
                    }
                },
                .function => {
                    const dst = @as(usize, @intCast(inst.p1));
                    const start = @as(usize, @intCast(inst.p2));
                    const count = @as(usize, @intCast(inst.p3));
                    const funcName = if (inst.p4) |p4v| (if (p4v == .text) p4v.text else return error.Unsupported) else return error.Unsupported;
                    registers[dst] = try evalFunction(arenaAlloc, funcName, registers[start .. start + count]);
                },
                else => {},
            }
            pc += 1;
        }

        const out = try self.allocator.alloc(Value, registerCount);
        for (0..registerCount) |i| {
            out[i] = if (i < registers.len) registers[i] else .null;
        }
        return out;
    }
};

pub fn run(allocator: std.mem.Allocator, program: *const Program, registerCount: usize) ![]Value {
    var vm = VirtualMachine.init(allocator, null);
    defer vm.deinit();
    return vm.runProgram(program, registerCount);
}

test "virtual machine executes constant bytecode" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    try program.append(.{ .opcode = .loadInteger, .register = 0, .value = .{ .integer = 9 } });
    try program.append(.{ .opcode = .halt });
    const values = try run(std.testing.allocator, &program, 1);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(i64, 9), values[0].integer);
}

test "virtual machine executes arithmetic instructions" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    _ = try program.emitValue(.loadInteger, 0, 0, 0, .{ .integer = 15 });
    _ = try program.emitValue(.loadInteger, 0, 1, 0, .{ .integer = 4 });
    _ = try program.emit(.add, 0, 1, 2);
    _ = try program.emit(.subtract, 0, 1, 3);
    _ = try program.emit(.multiply, 0, 1, 4);
    _ = try program.emit(.divide, 0, 1, 5);
    _ = try program.emit(.remainder, 0, 1, 6);
    _ = try program.emit(.halt, 0, 0, 0);

    const values = try run(std.testing.allocator, &program, 7);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(i64, 19), values[2].integer);
    try std.testing.expectEqual(@as(i64, 11), values[3].integer);
    try std.testing.expectEqual(@as(i64, 60), values[4].integer);
    try std.testing.expectEqual(@as(i64, 3), values[5].integer);
    try std.testing.expectEqual(@as(i64, 3), values[6].integer);
}

test "virtual machine executes conditional jumps" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    _ = try program.emitValue(.loadInteger, 0, 0, 0, .{ .integer = 10 });
    _ = try program.emitValue(.loadInteger, 0, 1, 0, .{ .integer = 20 });
    _ = try program.emitValue(.loadInteger, 0, 2, 0, .{ .integer = 0 });
    const jmpAddr = try program.emit(.lt, 0, 0, 1);
    _ = try program.emitValue(.loadInteger, 0, 2, 0, .{ .integer = 99 });
    const targetAddr = program.currentAddress();
    _ = try program.emitValue(.loadInteger, 0, 2, 0, .{ .integer = 42 });
    _ = try program.emit(.halt, 0, 0, 0);
    program.fixupJump(jmpAddr, @as(i32, @intCast(targetAddr)));

    const values = try run(std.testing.allocator, &program, 3);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(i64, 42), values[2].integer);
}

test "virtual machine executes built-in functions" {
    var program = Program.init(std.testing.allocator);
    defer program.deinit();
    _ = try program.emitValue(.loadInteger, 0, 1, 0, .{ .integer = -42 });
    _ = try program.emitValue(.function, 0, 1, 1, .{ .text = "abs" });
    _ = try program.emit(.halt, 0, 0, 0);

    const values = try run(std.testing.allocator, &program, 2);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(i64, 42), values[0].integer);
}
