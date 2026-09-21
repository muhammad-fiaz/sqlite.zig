const std = @import("std");
const ast = @import("../sql/ast.zig");
const opcode = @import("opcode.zig");
const Value = @import("value.zig").Value;
const Schema = @import("../catalog/schema.zig").Schema;
const Table = @import("../catalog/schema.zig").Table;
const vm = @import("vm.zig");

pub const CompiledQuery = struct {
    program: opcode.Program,
    columnNames: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledQuery) void {
        for (self.columnNames) |name| self.allocator.free(name);
        self.allocator.free(self.columnNames);
        self.program.deinit();
    }
};

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    schema: ?*const Schema,
    nextRegister: usize = 0,

    pub fn init(allocator: std.mem.Allocator, schema: ?*const Schema) Compiler {
        return .{
            .allocator = allocator,
            .schema = schema,
            .nextRegister = 0,
        };
    }

    pub fn allocRegister(self: *Compiler) usize {
        const reg = self.nextRegister;
        self.nextRegister += 1;
        return reg;
    }

    pub fn compile(self: *Compiler, statement: ast.Statement) !CompiledQuery {
        switch (statement) {
            .select => |sel| return self.compileSelect(sel),
            else => return error.Unsupported,
        }
    }

    pub fn compileExpression(self: *Compiler, expr: ast.Expr) !CompiledQuery {
        var program = opcode.Program.init(self.allocator);
        errdefer program.deinit();
        const reg = try self.compileExpr(&program, expr, null, null, null);
        _ = try program.emit(.resultRow, @as(i32, @intCast(reg)), 1, 0);
        _ = try program.emit(.halt, 0, 0, 0);
        program.maxRegisters = self.nextRegister;
        const colNames = try self.allocator.alloc([]const u8, 1);
        colNames[0] = try self.allocator.dupe(u8, "result");
        return CompiledQuery{
            .program = program,
            .columnNames = colNames,
            .allocator = self.allocator,
        };
    }

    pub fn compileSelect(self: *Compiler, select: anytype) !CompiledQuery {
        var program = opcode.Program.init(self.allocator);
        errdefer program.deinit();

        var colNamesList: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (colNamesList.items) |name| self.allocator.free(name);
            colNamesList.deinit(self.allocator);
        }

        if (select.table) |tableName| {
            const table = if (self.schema) |sch| (sch.findConst(tableName) orelse return error.TableNotFound) else return error.TableNotFound;
            const tableColNames = try self.allocator.alloc([]const u8, table.columns.len);
            defer self.allocator.free(tableColNames);
            for (table.columns, 0..) |col, i| {
                tableColNames[i] = col.name;
            }

            const cur: i32 = 0;
            _ = try program.emitValue(.openRead, cur, 0, 0, .{ .text = tableName });
            const rewindJmp = try program.emit(.rewind, cur, 0, 0);

            var limitReg: ?usize = null;
            if (select.limit) |lim| {
                const lReg = self.allocRegister();
                _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(lReg)), 0, .{ .integer = @as(i64, @intCast(lim)) });
                limitReg = lReg;
            }
            var offsetReg: ?usize = null;
            if (select.offset) |off| {
                const oReg = self.allocRegister();
                _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(oReg)), 0, .{ .integer = @as(i64, @intCast(off)) });
                offsetReg = oReg;
            }

            const loopStart = program.currentAddress();

            var skipJmps: std.ArrayList(usize) = .empty;
            defer skipJmps.deinit(self.allocator);

            if (select.condition) |conditions| {
                for (conditions) |cond| {
                    var colIdx: ?usize = null;
                    for (tableColNames, 0..) |cName, idx| {
                        if (std.ascii.eqlIgnoreCase(cName, cond.column)) {
                            colIdx = idx;
                            break;
                        }
                    }
                    const isRowid = std.ascii.eqlIgnoreCase(cond.column, "rowid") or std.ascii.eqlIgnoreCase(cond.column, "_rowid_") or std.ascii.eqlIgnoreCase(cond.column, "oid");
                    if (colIdx != null or isRowid) {
                        const colReg = self.allocRegister();
                        if (isRowid) {
                            _ = try program.emit(.rowid, cur, @as(i32, @intCast(colReg)), 0);
                        } else {
                            _ = try program.emit(.column, cur, @as(i32, @intCast(colIdx.?)), @as(i32, @intCast(colReg)));
                        }
                        const valReg = try self.compileExpr(&program, cond.value, null, cur, tableColNames);
                        const invOp: opcode.OpCode = switch (cond.op) {
                            .equal => .ne,
                            .notEqual => .eq,
                            .less => .ge,
                            .lessEqual => .gt,
                            .greater => .le,
                            .greaterEqual => .lt,
                            else => .ne,
                        };
                        const jmp = try program.emit(invOp, @as(i32, @intCast(colReg)), 0, @as(i32, @intCast(valReg)));
                        try skipJmps.append(self.allocator, jmp);
                    }
                }
            }

            if (offsetReg) |oReg| {
                const zeroReg = self.allocRegister();
                _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(zeroReg)), 0, .{ .integer = 0 });
                const notOffsetJmp = try program.emit(.le, @as(i32, @intCast(oReg)), 0, @as(i32, @intCast(zeroReg)));
                const oneReg = self.allocRegister();
                _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(oneReg)), 0, .{ .integer = 1 });
                _ = try program.emit(.subtract, @as(i32, @intCast(oReg)), @as(i32, @intCast(oneReg)), @as(i32, @intCast(oReg)));
                const skipToNext = try program.emit(.gotoOp, 0, 0, 0);
                try skipJmps.append(self.allocator, skipToNext);
                program.fixupJump(notOffsetJmp, @as(i32, @intCast(program.currentAddress())));
            }

            var outRegs: std.ArrayList(usize) = .empty;
            defer outRegs.deinit(self.allocator);
            for (select.projections) |proj| {
                if (proj.expr == .wildcard) {
                    for (table.columns, 0..) |col, i| {
                        const r = self.allocRegister();
                        _ = try program.emit(.column, cur, @as(i32, @intCast(i)), @as(i32, @intCast(r)));
                        try outRegs.append(self.allocator, r);
                        try colNamesList.append(self.allocator, try self.allocator.dupe(u8, col.name));
                    }
                } else {
                    const r = try self.compileExpr(&program, proj.expr, null, cur, tableColNames);
                    try outRegs.append(self.allocator, r);
                    const colName = if (proj.alias) |a| a else switch (proj.expr) {
                        .identifier => |id| id,
                        else => "col",
                    };
                    try colNamesList.append(self.allocator, try self.allocator.dupe(u8, colName));
                }
            }
            const projBaseReg = self.nextRegister;
            for (outRegs.items) |r| {
                const dst = self.allocRegister();
                _ = try program.emit(.move, @as(i32, @intCast(r)), @as(i32, @intCast(dst)), 1);
            }
            _ = try program.emit(.resultRow, @as(i32, @intCast(projBaseReg)), @as(i32, @intCast(outRegs.items.len)), 0);

            if (limitReg) |lReg| {
                const oneReg = self.allocRegister();
                _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(oneReg)), 0, .{ .integer = 1 });
                _ = try program.emit(.subtract, @as(i32, @intCast(lReg)), @as(i32, @intCast(oneReg)), @as(i32, @intCast(lReg)));
                const zeroReg = self.allocRegister();
                _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(zeroReg)), 0, .{ .integer = 0 });
                const limitHitJmp = try program.emit(.le, @as(i32, @intCast(lReg)), 0, @as(i32, @intCast(zeroReg)));
                try skipJmps.append(self.allocator, limitHitJmp);
            }

            const nextRowAddr = program.currentAddress();
            for (skipJmps.items) |j| {
                program.fixupJump(j, @as(i32, @intCast(nextRowAddr)));
            }

            _ = try program.emit(.next, cur, @as(i32, @intCast(loopStart)), 0);

            const endAddr = program.currentAddress();
            program.fixupJump(rewindJmp, @as(i32, @intCast(endAddr)));
            _ = try program.emit(.close, cur, 0, 0);
            _ = try program.emit(.halt, 0, 0, 0);
        } else {
            var outRegs: std.ArrayList(usize) = .empty;
            defer outRegs.deinit(self.allocator);
            for (select.projections) |proj| {
                const r = try self.compileExpr(&program, proj.expr, null, null, null);
                try outRegs.append(self.allocator, r);
                const colName = if (proj.alias) |a| a else switch (proj.expr) {
                    .identifier => |id| id,
                    else => "col",
                };
                try colNamesList.append(self.allocator, try self.allocator.dupe(u8, colName));
            }
            const projBaseReg = self.nextRegister;
            for (outRegs.items) |r| {
                const dst = self.allocRegister();
                _ = try program.emit(.move, @as(i32, @intCast(r)), @as(i32, @intCast(dst)), 1);
            }
            _ = try program.emit(.resultRow, @as(i32, @intCast(projBaseReg)), @as(i32, @intCast(outRegs.items.len)), 0);
            _ = try program.emit(.halt, 0, 0, 0);
        }

        program.maxRegisters = self.nextRegister;
        return CompiledQuery{
            .program = program,
            .columnNames = try colNamesList.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    pub fn compileExpr(self: *Compiler, program: *opcode.Program, expr: ast.Expr, target: ?usize, tableCursor: ?i32, tableColumns: ?[]const []const u8) !usize {
        switch (expr) {
            .literal => |val| {
                const reg = target orelse self.allocRegister();
                switch (val) {
                    .null => _ = try program.emit(.loadNull, 0, @as(i32, @intCast(reg)), 0),
                    .integer => _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(reg)), 0, val),
                    .real => _ = try program.emitValue(.loadReal, 0, @as(i32, @intCast(reg)), 0, val),
                    .text => _ = try program.emitValue(.loadText, 0, @as(i32, @intCast(reg)), 0, val),
                    .blob => _ = try program.emitValue(.loadBlob, 0, @as(i32, @intCast(reg)), 0, val),
                }
                return reg;
            },
            .identifier => |name| {
                const reg = target orelse self.allocRegister();
                if (tableCursor) |cursorIdx| {
                    if (std.ascii.eqlIgnoreCase(name, "rowid") or std.ascii.eqlIgnoreCase(name, "_rowid_") or std.ascii.eqlIgnoreCase(name, "oid")) {
                        _ = try program.emit(.rowid, cursorIdx, @as(i32, @intCast(reg)), 0);
                        return reg;
                    }
                    if (tableColumns) |cols| {
                        for (cols, 0..) |colName, idx| {
                            if (std.ascii.eqlIgnoreCase(colName, name)) {
                                _ = try program.emit(.column, cursorIdx, @as(i32, @intCast(idx)), @as(i32, @intCast(reg)));
                                return reg;
                            }
                        }
                    }
                }
                return error.ColumnNotFound;
            },
            .binary => |bin| {
                const regLeft = try self.compileExpr(program, bin.left.*, null, tableCursor, tableColumns);
                const regRight = try self.compileExpr(program, bin.right.*, null, tableCursor, tableColumns);
                const reg = target orelse self.allocRegister();
                switch (bin.op) {
                    .add => _ = try program.emit(.add, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .subtract => _ = try program.emit(.subtract, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .multiply => _ = try program.emit(.multiply, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .divide => _ = try program.emit(.divide, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .modulo => _ = try program.emit(.remainder, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .concat => _ = try program.emit(.concat, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .bitAnd => _ = try program.emit(.bitAnd, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .bitOr => _ = try program.emit(.bitOr, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .shiftLeft => _ = try program.emit(.shiftLeft, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .shiftRight => _ = try program.emit(.shiftRight, @as(i32, @intCast(regLeft)), @as(i32, @intCast(regRight)), @as(i32, @intCast(reg))),
                    .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual, .isOp, .isNotOp => {
                        _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(reg)), 0, .{ .integer = 0 });
                        const op: opcode.OpCode = switch (bin.op) {
                            .equal => .eq,
                            .notEqual => .ne,
                            .less => .lt,
                            .lessEqual => .le,
                            .greater => .gt,
                            .greaterEqual => .ge,
                            .isOp => .isOp,
                            .isNotOp => .isNotOp,
                            else => unreachable,
                        };
                        const jmp = try program.emit(op, @as(i32, @intCast(regLeft)), 0, @as(i32, @intCast(regRight)));
                        _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(reg)), 0, .{ .integer = 1 });
                        program.fixupJump(jmp, @as(i32, @intCast(program.currentAddress())));
                    },
                    .logicalAnd => {
                        _ = try program.emit(.move, @as(i32, @intCast(regLeft)), @as(i32, @intCast(reg)), 1);
                        const jmp = try program.emit(.ifNotOp, @as(i32, @intCast(reg)), 0, 0);
                        _ = try program.emit(.move, @as(i32, @intCast(regRight)), @as(i32, @intCast(reg)), 1);
                        program.fixupJump(jmp, @as(i32, @intCast(program.currentAddress())));
                    },
                    .logicalOr => {
                        _ = try program.emit(.move, @as(i32, @intCast(regLeft)), @as(i32, @intCast(reg)), 1);
                        const jmp = try program.emit(.ifOp, @as(i32, @intCast(reg)), 0, 0);
                        _ = try program.emit(.move, @as(i32, @intCast(regRight)), @as(i32, @intCast(reg)), 1);
                        program.fixupJump(jmp, @as(i32, @intCast(program.currentAddress())));
                    },
                }
                return reg;
            },
            .unary => |un| {
                const regInner = try self.compileExpr(program, un.expr.*, null, tableCursor, tableColumns);
                const reg = target orelse self.allocRegister();
                switch (un.op) {
                    .negate => {
                        const zeroReg = self.allocRegister();
                        _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(zeroReg)), 0, .{ .integer = 0 });
                        _ = try program.emit(.subtract, @as(i32, @intCast(zeroReg)), @as(i32, @intCast(regInner)), @as(i32, @intCast(reg)));
                    },
                    .positive => {
                        _ = try program.emit(.move, @as(i32, @intCast(regInner)), @as(i32, @intCast(reg)), 1);
                    },
                    .bitNot => {
                        _ = try program.emit(.bitNot, @as(i32, @intCast(regInner)), @as(i32, @intCast(reg)), 0);
                    },
                    .logicalNot => {
                        _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(reg)), 0, .{ .integer = 1 });
                        const jmp = try program.emit(.ifNotOp, @as(i32, @intCast(regInner)), 0, 0);
                        _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(reg)), 0, .{ .integer = 0 });
                        program.fixupJump(jmp, @as(i32, @intCast(program.currentAddress())));
                    },
                }
                return reg;
            },
            .function => |func| {
                const argStart = self.nextRegister;
                _ = try self.compileExpr(program, func.argument.*, null, tableCursor, tableColumns);
                var argCount: usize = 1;
                if (func.argument2) |arg2| {
                    _ = try self.compileExpr(program, arg2.*, null, tableCursor, tableColumns);
                    argCount += 1;
                }
                if (func.argument3) |arg3| {
                    _ = try self.compileExpr(program, arg3.*, null, tableCursor, tableColumns);
                    argCount += 1;
                }
                for (func.extraArgs) |argExtra| {
                    _ = try self.compileExpr(program, argExtra, null, tableCursor, tableColumns);
                    argCount += 1;
                }
                const reg = target orelse self.allocRegister();
                _ = try program.emitValue(.function, @as(i32, @intCast(reg)), @as(i32, @intCast(argStart)), @as(i32, @intCast(argCount)), .{ .text = func.name });
                return reg;
            },
            .caseExpr => |cs| {
                const reg = target orelse self.allocRegister();
                var endJumps: std.ArrayList(usize) = .empty;
                defer endJumps.deinit(self.allocator);

                for (cs.whens) |when| {
                    const condReg = if (cs.base) |baseExpr| blk: {
                        const bReg = try self.compileExpr(program, baseExpr.*, null, tableCursor, tableColumns);
                        const wReg = try self.compileExpr(program, when.condition, null, tableCursor, tableColumns);
                        const resReg = self.allocRegister();
                        _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(resReg)), 0, .{ .integer = 0 });
                        const jmp = try program.emit(.eq, @as(i32, @intCast(bReg)), 0, @as(i32, @intCast(wReg)));
                        _ = try program.emitValue(.loadInteger, 0, @as(i32, @intCast(resReg)), 0, .{ .integer = 1 });
                        program.fixupJump(jmp, @as(i32, @intCast(program.currentAddress())));
                        break :blk resReg;
                    } else try self.compileExpr(program, when.condition, null, tableCursor, tableColumns);

                    const nextWhenJmp = try program.emit(.ifNotOp, @as(i32, @intCast(condReg)), 0, 0);
                    _ = try self.compileExpr(program, when.result, reg, tableCursor, tableColumns);
                    const endJmp = try program.emit(.gotoOp, 0, 0, 0);
                    try endJumps.append(self.allocator, endJmp);
                    program.fixupJump(nextWhenJmp, @as(i32, @intCast(program.currentAddress())));
                }

                if (cs.otherwise) |otherwiseExpr| {
                    _ = try self.compileExpr(program, otherwiseExpr.*, reg, tableCursor, tableColumns);
                } else {
                    _ = try program.emit(.loadNull, 0, @as(i32, @intCast(reg)), 0);
                }

                const current = program.currentAddress();
                for (endJumps.items) |j| {
                    program.fixupJump(j, @as(i32, @intCast(current)));
                }
                return reg;
            },
            else => return error.Unsupported,
        }
    }
};

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

test "compiler compiles arithmetic and function expression" {
    const leftLit = ast.Expr{ .literal = .{ .integer = 10 } };
    const rightLit = ast.Expr{ .literal = .{ .integer = 3 } };
    const addExpr = ast.Expr{ .binary = .{ .op = .add, .left = &leftLit, .right = &rightLit } };

    var comp = Compiler.init(std.testing.allocator, null);
    var compiled = try comp.compileExpression(addExpr);
    defer compiled.deinit();

    var virtualMachine = vm.VirtualMachine.init(std.testing.allocator, null);
    defer virtualMachine.deinit();

    var result = try virtualMachine.execute(&compiled.program, compiled.columnNames);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(i64, 13), result.at(0)[0].integer);
}

test "compiler compiles constant select statement" {
    const expr1 = ast.Expr{ .literal = .{ .integer = 100 } };
    const expr2 = ast.Expr{ .literal = .{ .text = "sqlite.zig" } };
    const projections = [_]ast.Projection{
        .{ .expr = expr1, .alias = "num" },
        .{ .expr = expr2, .alias = "str" },
    };

    var comp = Compiler.init(std.testing.allocator, null);
    var compiled = try comp.compileSelect(.{
        .projections = &projections,
        .table = null,
        .condition = null,
        .limit = null,
        .offset = null,
    });
    defer compiled.deinit();

    var virtualMachine = vm.VirtualMachine.init(std.testing.allocator, null);
    defer virtualMachine.deinit();

    var result = try virtualMachine.execute(&compiled.program, compiled.columnNames);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(i64, 100), result.at(0)[0].integer);
    try std.testing.expectEqualStrings("sqlite.zig", result.at(0)[1].text);
}
