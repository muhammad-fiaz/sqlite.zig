const std = @import("std");
const Value = @import("../vm/value.zig").Value;

pub const CompareOp = enum { equal, notEqual, less, lessEqual, greater, greaterEqual, like, notLike, glob, notGlob, regexp, notRegexp, match, notMatch, isNull, isNotNull, isValue, isNotValue, isDistinct, isNotDistinct, between, notBetween, in, notIn, exists, notExists };

pub const OrderItem = struct {
    expr: Expr,
    descending: bool = false,
    nullsFirst: bool = false,
};

pub const WindowFrameKind = enum { rows, range, groups };
pub const WindowFrameBound = enum { unboundedPreceding, preceding, currentRow, following, unboundedFollowing };
pub const WindowFrame = struct {
    kind: WindowFrameKind = .rows,
    start: WindowFrameBound = .unboundedPreceding,
    startOffset: usize = 0,
    end: ?WindowFrameBound = null,
    endOffset: usize = 0,
};

pub const Expr = union(enum) {
    literal: Value,
    identifier: []const u8,
    parameter: usize,
    wildcard,
    function: struct { name: []const u8, argument: *const Expr, argument2: ?*const Expr = null, argument3: ?*const Expr = null, extraArgs: []const Expr = &.{}, distinct: bool = false },
    binary: struct { op: BinaryOp, left: *const Expr, right: *const Expr },
    unary: struct { op: UnaryOp, expr: *const Expr },
    caseExpr: struct { base: ?*const Expr, whens: []CaseWhen, otherwise: ?*const Expr = null },
    patternMatch: struct { value: *const Expr, pattern: *const Expr, escape: ?*const Expr = null, negated: bool = false, glob: bool = false, isRegexp: bool = false, isMatch: bool = false },
    collate: struct { expr: *const Expr, name: []const u8 },
    scalarSubquery: []const u8,
    existsSubquery: []const u8,
    inSubquery: struct { expr: *const Expr, subquery: []const u8, negated: bool = false },
    inList: struct { expr: *const Expr, list: []const Expr, negated: bool = false },
    window: struct { funcName: []const u8, argument: ?*const Expr = null, argument2: ?*const Expr = null, extraArgs: []const Expr = &.{}, partitionBy: []const Expr = &.{}, orderBy: []const OrderItem = &.{}, frame: ?WindowFrame = null },
};
pub const BinaryOp = enum { add, subtract, multiply, divide, modulo, concat, bitAnd, bitOr, shiftLeft, shiftRight, equal, notEqual, less, lessEqual, greater, greaterEqual, logicalAnd, logicalOr, isOp, isNotOp };
pub const UnaryOp = enum { negate, positive, bitNot, logicalNot };
pub const CaseWhen = struct { condition: Expr, result: Expr };

pub const Condition = struct { column: []const u8, op: CompareOp, value: Expr, value2: ?Expr = null, subquery: ?[]const u8 = null, tableScan: ?TableScan = null, listValues: []const Expr = &.{}, joinOr: bool = false, leftExpr: ?Expr = null, escape: ?Expr = null, negated: bool = false, collate: ?[]const u8 = null };
pub const TableScan = struct { table: []const u8, column: []const u8 = "", conditions: ?Conditions = null };
pub const Having = struct { left: Expr, op: CompareOp, right: Expr };
pub const Conditions = []const Condition;
pub const Order = struct { column: []const u8, descending: bool };
pub const JoinKind = enum { inner, left, right, full, cross };
pub const Join = struct { kind: JoinKind, table: []const u8, tableAlias: ?[]const u8 = null, leftTable: []const u8, leftColumn: []const u8, rightTable: []const u8, rightColumn: []const u8, mergeOutput: bool = false, usingColumns: []const []const u8 = &.{} };
pub const Projection = struct { expr: Expr, alias: ?[]const u8 = null };
pub const ForeignKeyDef = struct { table: []const u8, column: []const u8, onDelete: ReferentialAction = .restrict, onUpdate: ReferentialAction = .restrict };
pub const ReferentialAction = enum { restrict, cascade, setNull, setDefault, noAction };
pub const ColumnDef = struct { name: []const u8, typeName: []const u8, primaryKey: bool = false, notNull: bool = false, unique: bool = false, autoincrement: bool = false, foreignKey: ?ForeignKeyDef = null, defaultValue: ?Value = null, checkExpr: ?Expr = null, generatedExpr: ?Expr = null, generatedStored: bool = false };
pub const TableForeignKeyDef = struct { columns: []const []const u8, table: []const u8, referencedColumns: []const []const u8, onDelete: ReferentialAction = .restrict, onUpdate: ReferentialAction = .restrict };
pub const TableConstraint = union(enum) { primaryKey: []const []const u8, unique: []const []const u8, foreignKey: TableForeignKeyDef, check: Expr };
pub const IndexDef = struct { name: []const u8, table: []const u8, columns: []const []const u8, keyExprs: []const ?Expr = &.{}, unique: bool = false, ifNotExists: bool = false, whereExpr: ?Expr = null, whereSql: ?[]const u8 = null };
pub const TriggerEvent = enum { insert, update, delete };
pub const TriggerTiming = enum { before, after };
pub const TriggerDef = struct { name: []const u8, table: []const u8, timing: TriggerTiming = .after, event: TriggerEvent, updateOf: []const []const u8 = &.{}, whenSql: ?[]const u8 = null, body: []const u8, ifNotExists: bool = false };
pub const VirtualTableDef = struct { name: []const u8, module: []const u8, arguments: []const []const u8, ifNotExists: bool = false };
pub const CteDef = struct { name: []const u8, columns: []const []const u8 = &.{}, querySql: []const u8, recursiveSql: ?[]const u8 = null, recursiveAll: bool = false };
pub const WithSelect = struct { ctes: []CteDef, bodySql: []const u8, recursive: bool = false };
pub const ConflictPolicy = enum { none, ignore, replace, update, abort, fail, rollback };
pub const UpsertResult = enum { noConflict, skipped, updated };
pub const UpdateFrom = struct { table: []const u8, leftTable: []const u8, leftColumn: []const u8, rightTable: []const u8, rightColumn: []const u8 };
pub const AlterTable = union(enum) {
    addColumn: struct { table: []const u8, definition: ColumnDef },
    renameTable: struct { table: []const u8, newName: []const u8 },
    renameColumn: struct { table: []const u8, oldName: []const u8, newName: []const u8 },
    dropColumn: struct { table: []const u8, column: []const u8 },
};

pub const CompoundOp = enum { unionOp, unionAllOp, intersectOp, exceptOp };
pub const CompoundSelect = struct { leftSql: []const u8, op: CompoundOp, rightSql: []const u8, order: ?Order = null, limit: ?usize = null, offset: ?usize = null };

pub const Statement = union(enum) {
    createTable: struct { name: []const u8, columns: []ColumnDef, constraints: []TableConstraint = &.{}, ifNotExists: bool = false, strict: bool = false, withoutRowid: bool = false },
    createIndex: IndexDef,
    createView: struct { name: []const u8, sql: []const u8, ifNotExists: bool = false },
    createTrigger: TriggerDef,
    createVirtualTable: VirtualTableDef,
    withSelect: WithSelect,
    compoundSelect: CompoundSelect,
    explainQueryPlan: []const u8,
    pragma: struct { name: []const u8, value: ?[]const u8 = null, argument: ?[]const u8 = null, schema: ?[]const u8 = null },
    alterTable: AlterTable,
    dropTable: struct { name: []const u8, ifExists: bool = false },
    dropIndex: struct { name: []const u8, ifExists: bool = false },
    dropView: struct { name: []const u8, ifExists: bool = false },
    dropTrigger: struct { name: []const u8, ifExists: bool = false },
    insert: struct { table: []const u8, columns: []const []const u8, rows: []const []const Expr, selectSql: ?[]const u8 = null, conflict: ConflictPolicy = .none, conflictTargetColumns: []const []const u8 = &.{}, conflictTargetWhere: ?Conditions = null, upsertColumns: []const []const u8 = &.{}, upsertValues: []const Expr = &.{}, upsertWhere: ?Conditions = null, returning: []const Projection = &.{} },
    select: struct { projections: []const Projection, table: ?[]const u8, tableAlias: ?[]const u8 = null, fromSubquery: ?[]const u8 = null, joins: []const Join = &.{}, condition: ?Conditions, groupBy: ?[]const u8 = null, having: ?Having = null, order: ?Order, limit: ?usize, offset: ?usize = null, distinct: bool = false },
    update: struct { table: []const u8, columns: []const []const u8, values: []const Expr, condition: ?Conditions, from: ?UpdateFrom = null, conflict: ConflictPolicy = .none, returning: []const Projection = &.{} },
    delete: struct { table: []const u8, condition: ?Conditions, returning: []const Projection = &.{} },
    begin,
    commit,
    rollback,
    savepoint: []const u8,
    release: []const u8,
    rollbackTo: []const u8,
    attach: struct { expr: Expr, schemaName: []const u8 },
    detach: struct { schemaName: []const u8 },
    vacuum: struct { schemaName: ?[]const u8 = null, into: ?Expr = null },
    analyze: struct { target: ?[]const u8 = null },

    pub fn isQuery(self: Statement) bool {
        return self == .select or self == .withSelect or self == .compoundSelect or self == .explainQueryPlan or self == .pragma;
    }
};

pub fn freeOwnedExpr(allocator: std.mem.Allocator, expr: Expr) void {
    switch (expr) {
        .literal => |lit| switch (lit) {
            .text => |t| allocator.free(t),
            .blob => |b| allocator.free(b),
            else => {},
        },
        .identifier => |id| allocator.free(id),
        .function => |call| {
            allocator.free(call.name);
            freeOwnedExpr(allocator, call.argument.*);
            allocator.destroy(call.argument);
            if (call.argument2) |argument| {
                freeOwnedExpr(allocator, argument.*);
                allocator.destroy(argument);
            }
            if (call.argument3) |argument| {
                freeOwnedExpr(allocator, argument.*);
                allocator.destroy(argument);
            }
            for (call.extraArgs) |argument| {
                freeOwnedExpr(allocator, argument);
            }
            if (call.extraArgs.len != 0) allocator.free(call.extraArgs);
        },
        .binary => |binary| {
            freeOwnedExpr(allocator, binary.left.*);
            freeOwnedExpr(allocator, binary.right.*);
            allocator.destroy(binary.left);
            allocator.destroy(binary.right);
        },
        .unary => |unary| {
            freeOwnedExpr(allocator, unary.expr.*);
            allocator.destroy(unary.expr);
        },
        .caseExpr => |caseBlock| {
            if (caseBlock.base) |base| {
                freeOwnedExpr(allocator, base.*);
                allocator.destroy(base);
            }
            for (caseBlock.whens) |when| {
                freeOwnedExpr(allocator, when.condition);
                freeOwnedExpr(allocator, when.result);
            }
            allocator.free(caseBlock.whens);
            if (caseBlock.otherwise) |otherwise| {
                freeOwnedExpr(allocator, otherwise.*);
                allocator.destroy(otherwise);
            }
        },
        .patternMatch => |match| {
            freeOwnedExpr(allocator, match.value.*);
            allocator.destroy(match.value);
            freeOwnedExpr(allocator, match.pattern.*);
            allocator.destroy(match.pattern);
            if (match.escape) |escape| {
                freeOwnedExpr(allocator, escape.*);
                allocator.destroy(escape);
            }
        },
        .collate => |node| {
            allocator.free(node.name);
            freeOwnedExpr(allocator, node.expr.*);
            allocator.destroy(node.expr);
        },
        .inSubquery => |inSub| {
            freeOwnedExpr(allocator, inSub.expr.*);
            allocator.destroy(inSub.expr);
            allocator.free(inSub.subquery);
        },
        .inList => |inL| {
            freeOwnedExpr(allocator, inL.expr.*);
            allocator.destroy(inL.expr);
            for (inL.list) |item| freeOwnedExpr(allocator, item);
            if (inL.list.len != 0) allocator.free(inL.list);
        },
        .scalarSubquery => |s| allocator.free(s),
        .existsSubquery => |s| allocator.free(s),
        .window => |w| {
            allocator.free(w.funcName);
            if (w.argument) |arg| {
                freeOwnedExpr(allocator, arg.*);
                allocator.destroy(arg);
            }
            if (w.argument2) |arg| {
                freeOwnedExpr(allocator, arg.*);
                allocator.destroy(arg);
            }
            for (w.extraArgs) |arg| {
                freeOwnedExpr(allocator, arg);
            }
            if (w.extraArgs.len != 0) allocator.free(w.extraArgs);
            for (w.partitionBy) |item| freeOwnedExpr(allocator, item);
            if (w.partitionBy.len != 0) allocator.free(w.partitionBy);
            for (w.orderBy) |item| freeOwnedExpr(allocator, item.expr);
            if (w.orderBy.len != 0) allocator.free(w.orderBy);
        },
        else => {},
    }
}

pub fn cloneOwnedExpr(allocator: std.mem.Allocator, expr: Expr) !Expr {
    switch (expr) {
        .literal => |lit| return .{ .literal = switch (lit) {
            .text => |t| .{ .text = try allocator.dupe(u8, t) },
            .blob => |b| .{ .blob = try allocator.dupe(u8, b) },
            else => lit,
        } },
        .identifier => |id| return .{ .identifier = try allocator.dupe(u8, id) },
        .parameter => |p| return .{ .parameter = p },
        .wildcard => return .wildcard,
        .function => |call| {
            const ownedName = try allocator.dupe(u8, call.name);
            errdefer allocator.free(ownedName);
            const arg1 = try allocator.create(Expr);
            errdefer allocator.destroy(arg1);
            arg1.* = try cloneOwnedExpr(allocator, call.argument.*);
            errdefer freeOwnedExpr(allocator, arg1.*);
            var arg2: ?*const Expr = null;
            if (call.argument2) |a2| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExpr(allocator, a2.*);
                arg2 = node;
            }
            errdefer if (arg2) |n| {
                freeOwnedExpr(allocator, @constCast(n).*);
                allocator.destroy(n);
            };
            var arg3: ?*const Expr = null;
            if (call.argument3) |a3| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExpr(allocator, a3.*);
                arg3 = node;
            }
            errdefer if (arg3) |n| {
                freeOwnedExpr(allocator, @constCast(n).*);
                allocator.destroy(n);
            };
            var extraArgs: []Expr = &.{};
            if (call.extraArgs.len != 0) {
                const list = try allocator.alloc(Expr, call.extraArgs.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeOwnedExpr(allocator, item);
                    allocator.free(list);
                }
                for (call.extraArgs, 0..) |item, idx| {
                    list[idx] = try cloneOwnedExpr(allocator, item);
                    count += 1;
                }
                extraArgs = list;
            }
            return .{ .function = .{ .name = ownedName, .argument = arg1, .argument2 = arg2, .argument3 = arg3, .extraArgs = extraArgs, .distinct = call.distinct } };
        },
        .binary => |bin| {
            const left = try allocator.create(Expr);
            errdefer allocator.destroy(left);
            left.* = try cloneOwnedExpr(allocator, bin.left.*);
            errdefer freeOwnedExpr(allocator, left.*);
            const right = try allocator.create(Expr);
            errdefer allocator.destroy(right);
            right.* = try cloneOwnedExpr(allocator, bin.right.*);
            return .{ .binary = .{ .op = bin.op, .left = left, .right = right } };
        },
        .unary => |un| {
            const inner = try allocator.create(Expr);
            errdefer allocator.destroy(inner);
            inner.* = try cloneOwnedExpr(allocator, un.expr.*);
            return .{ .unary = .{ .op = un.op, .expr = inner } };
        },
        .collate => |col| {
            const ownedName = try allocator.dupe(u8, col.name);
            errdefer allocator.free(ownedName);
            const inner = try allocator.create(Expr);
            errdefer allocator.destroy(inner);
            inner.* = try cloneOwnedExpr(allocator, col.expr.*);
            return .{ .collate = .{ .name = ownedName, .expr = inner } };
        },
        .caseExpr => |cs| {
            var baseNode: ?*const Expr = null;
            if (cs.base) |b| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExpr(allocator, b.*);
                baseNode = node;
            }
            errdefer if (baseNode) |n| {
                freeOwnedExpr(allocator, @constCast(n).*);
                allocator.destroy(n);
            };
            const whens = try allocator.alloc(CaseWhen, cs.whens.len);
            var whensCount: usize = 0;
            errdefer {
                for (whens[0..whensCount]) |w| {
                    freeOwnedExpr(allocator, w.condition);
                    freeOwnedExpr(allocator, w.result);
                }
                allocator.free(whens);
            }
            for (cs.whens, 0..) |w, idx| {
                whens[idx] = .{
                    .condition = try cloneOwnedExpr(allocator, w.condition),
                    .result = try cloneOwnedExpr(allocator, w.result),
                };
                whensCount += 1;
            }
            var otherwiseNode: ?*const Expr = null;
            if (cs.otherwise) |o| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExpr(allocator, o.*);
                otherwiseNode = node;
            }
            return .{ .caseExpr = .{ .base = baseNode, .whens = whens, .otherwise = otherwiseNode } };
        },
        .patternMatch => |pm| {
            const val = try allocator.create(Expr);
            errdefer allocator.destroy(val);
            val.* = try cloneOwnedExpr(allocator, pm.value.*);
            errdefer freeOwnedExpr(allocator, val.*);
            const pat = try allocator.create(Expr);
            errdefer allocator.destroy(pat);
            pat.* = try cloneOwnedExpr(allocator, pm.pattern.*);
            errdefer freeOwnedExpr(allocator, pat.*);
            var esc: ?*const Expr = null;
            if (pm.escape) |e| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExpr(allocator, e.*);
                esc = node;
            }
            return .{ .patternMatch = .{ .value = val, .pattern = pat, .escape = esc, .negated = pm.negated, .glob = pm.glob, .isRegexp = pm.isRegexp, .isMatch = pm.isMatch } };
        },
        .inList => |il| {
            const target = try allocator.create(Expr);
            errdefer allocator.destroy(target);
            target.* = try cloneOwnedExpr(allocator, il.expr.*);
            errdefer freeOwnedExpr(allocator, target.*);
            const list = try allocator.alloc(Expr, il.list.len);
            var listCount: usize = 0;
            errdefer {
                for (list[0..listCount]) |item| freeOwnedExpr(allocator, item);
                allocator.free(list);
            }
            for (il.list, 0..) |item, idx| {
                list[idx] = try cloneOwnedExpr(allocator, item);
                listCount += 1;
            }
            return .{ .inList = .{ .expr = target, .list = list, .negated = il.negated } };
        },
        .inSubquery => |is| {
            const target = try allocator.create(Expr);
            errdefer allocator.destroy(target);
            target.* = try cloneOwnedExpr(allocator, is.expr.*);
            errdefer freeOwnedExpr(allocator, target.*);
            const sub = try allocator.dupe(u8, is.subquery);
            return .{ .inSubquery = .{ .expr = target, .subquery = sub, .negated = is.negated } };
        },
        .scalarSubquery => |s| return .{ .scalarSubquery = try allocator.dupe(u8, s) },
        .existsSubquery => |s| return .{ .existsSubquery = try allocator.dupe(u8, s) },
        .window => |w| {
            const ownedName = try allocator.dupe(u8, w.funcName);
            errdefer allocator.free(ownedName);
            var arg1: ?*const Expr = null;
            if (w.argument) |a1| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExpr(allocator, a1.*);
                arg1 = node;
            }
            errdefer if (arg1) |n| {
                freeOwnedExpr(allocator, @constCast(n).*);
                allocator.destroy(n);
            };
            var arg2: ?*const Expr = null;
            if (w.argument2) |a2| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExpr(allocator, a2.*);
                arg2 = node;
            }
            errdefer if (arg2) |n| {
                freeOwnedExpr(allocator, @constCast(n).*);
                allocator.destroy(n);
            };
            var extraArgs: []Expr = &.{};
            if (w.extraArgs.len != 0) {
                const list = try allocator.alloc(Expr, w.extraArgs.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeOwnedExpr(allocator, item);
                    allocator.free(list);
                }
                for (w.extraArgs, 0..) |item, idx| {
                    list[idx] = try cloneOwnedExpr(allocator, item);
                    count += 1;
                }
                extraArgs = list;
            }
            var parts: []Expr = &.{};
            if (w.partitionBy.len != 0) {
                const list = try allocator.alloc(Expr, w.partitionBy.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeOwnedExpr(allocator, item);
                    allocator.free(list);
                }
                for (w.partitionBy, 0..) |item, idx| {
                    list[idx] = try cloneOwnedExpr(allocator, item);
                    count += 1;
                }
                parts = list;
            }
            var orders: []OrderItem = &.{};
            if (w.orderBy.len != 0) {
                const list = try allocator.alloc(OrderItem, w.orderBy.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeOwnedExpr(allocator, item.expr);
                    allocator.free(list);
                }
                for (w.orderBy, 0..) |item, idx| {
                    list[idx] = .{
                        .expr = try cloneOwnedExpr(allocator, item.expr),
                        .descending = item.descending,
                        .nullsFirst = item.nullsFirst,
                    };
                    count += 1;
                }
                orders = list;
            }
            return .{ .window = .{
                .funcName = ownedName,
                .argument = arg1,
                .argument2 = arg2,
                .extraArgs = extraArgs,
                .partitionBy = parts,
                .orderBy = orders,
                .frame = w.frame,
            } };
        },
    }
}

pub fn freeExprRec(gpa: anytype, expr: Expr) void {
    switch (expr) {
        .function => |call| {
            freeExprRec(gpa, call.argument.*);
            gpa.destroy(call.argument);
            if (call.argument2) |argument| {
                freeExprRec(gpa, argument.*);
                gpa.destroy(argument);
            }
            if (call.argument3) |argument| {
                freeExprRec(gpa, argument.*);
                gpa.destroy(argument);
            }
            for (call.extraArgs) |argument| {
                freeExprRec(gpa, argument);
            }
            if (call.extraArgs.len != 0) gpa.free(call.extraArgs);
        },
        .binary => |binary| {
            freeExprRec(gpa, binary.left.*);
            freeExprRec(gpa, binary.right.*);
            gpa.destroy(binary.left);
            gpa.destroy(binary.right);
        },
        .unary => |unary| {
            freeExprRec(gpa, unary.expr.*);
            gpa.destroy(unary.expr);
        },
        .caseExpr => |caseBlock| {
            if (caseBlock.base) |base| {
                freeExprRec(gpa, base.*);
                gpa.destroy(base);
            }
            for (caseBlock.whens) |when| {
                freeExprRec(gpa, when.condition);
                freeExprRec(gpa, when.result);
            }
            gpa.free(caseBlock.whens);
            if (caseBlock.otherwise) |otherwise| {
                freeExprRec(gpa, otherwise.*);
                gpa.destroy(otherwise);
            }
        },
        .patternMatch => |match| {
            freeExprRec(gpa, match.value.*);
            gpa.destroy(match.value);
            freeExprRec(gpa, match.pattern.*);
            gpa.destroy(match.pattern);
            if (match.escape) |escape| {
                freeExprRec(gpa, escape.*);
                gpa.destroy(escape);
            }
        },
        .collate => |node| {
            freeExprRec(gpa, node.expr.*);
            gpa.destroy(node.expr);
        },
        .inSubquery => |inSub| {
            freeExprRec(gpa, inSub.expr.*);
            gpa.destroy(inSub.expr);
        },
        .inList => |inL| {
            freeExprRec(gpa, inL.expr.*);
            gpa.destroy(inL.expr);
            for (inL.list) |item| freeExprRec(gpa, item);
            if (inL.list.len != 0) gpa.free(inL.list);
        },
        .window => |w| {
            if (w.argument) |arg| {
                freeExprRec(gpa, arg.*);
                gpa.destroy(arg);
            }
            if (w.argument2) |arg| {
                freeExprRec(gpa, arg.*);
                gpa.destroy(arg);
            }
            for (w.extraArgs) |arg| {
                freeExprRec(gpa, arg);
            }
            if (w.extraArgs.len != 0) gpa.free(w.extraArgs);
            for (w.partitionBy) |item| freeExprRec(gpa, item);
            if (w.partitionBy.len != 0) gpa.free(w.partitionBy);
            for (w.orderBy) |item| freeExprRec(gpa, item.expr);
            if (w.orderBy.len != 0) gpa.free(w.orderBy);
        },
        else => {},
    }
}

pub fn freeConditions(allocator: anytype, conditions: Conditions) void {
    for (conditions) |condition| {
        if (condition.leftExpr) |left| freeExprRec(allocator, left);
        freeExprRec(allocator, condition.value);
        if (condition.value2) |second| freeExprRec(allocator, second);
        if (condition.escape) |escape| freeExprRec(allocator, escape);
        for (condition.listValues) |item| freeExprRec(allocator, item);
        if (condition.listValues.len != 0) allocator.free(condition.listValues);
        if (condition.tableScan) |ts| if (ts.conditions) |inner| freeConditions(allocator, inner);
    }
    allocator.free(conditions);
}

pub fn deinit(allocator: anytype, statement: *Statement) void {
    const freeExpr = struct {
        fn run(gpa: anytype, expr: Expr) void {
            freeExprRec(gpa, expr);
        }
    }.run;
    switch (statement.*) {
        .createTable => |value| {
            for (value.columns) |column| {
                if (column.checkExpr) |chk| freeExpr(allocator, chk);
                if (column.generatedExpr) |gen| freeExpr(allocator, gen);
            }
            allocator.free(value.columns);
            for (value.constraints) |constraint| switch (constraint) {
                .primaryKey => |columns| allocator.free(columns),
                .unique => |columns| allocator.free(columns),
                .foreignKey => |foreignKey| {
                    allocator.free(foreignKey.columns);
                    allocator.free(foreignKey.referencedColumns);
                },
                .check => |chk| freeExpr(allocator, chk),
            };
            allocator.free(value.constraints);
        },
        .createIndex => |value| {
            if (value.whereExpr) |wh| freeExpr(allocator, wh);
            for (value.keyExprs) |maybeKey| if (maybeKey) |key| freeExpr(allocator, key);
            if (value.keyExprs.len != 0) allocator.free(value.keyExprs);
            allocator.free(value.columns);
        },
        .createView => {},
        .createTrigger => |value| {
            if (value.updateOf.len != 0) allocator.free(value.updateOf);
        },
        .createVirtualTable => |value| allocator.free(value.arguments),
        .withSelect => |value| {
            for (value.ctes) |cte| if (cte.columns.len != 0) allocator.free(cte.columns);
            allocator.free(value.ctes);
        },
        .compoundSelect => {},
        .explainQueryPlan => {},
        .pragma => {},
        .insert => |value| {
            allocator.free(value.columns);
            for (value.rows) |row| {
                for (row) |expr| freeExpr(allocator, expr);
                allocator.free(row);
            }
            allocator.free(value.rows);
            if (value.conflictTargetColumns.len != 0) allocator.free(value.conflictTargetColumns);
            if (value.conflictTargetWhere) |conditions| {
                for (conditions) |condition| {
                    if (condition.leftExpr) |left| freeExpr(allocator, left);
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    if (condition.escape) |escape| freeExpr(allocator, escape);
                    for (condition.listValues) |item| freeExpr(allocator, item);
                    if (condition.listValues.len != 0) allocator.free(condition.listValues);
                    if (condition.tableScan) |ts| if (ts.conditions) |inner| freeConditions(allocator, inner);
                }
                allocator.free(conditions);
            }
            allocator.free(value.upsertColumns);
            for (value.upsertValues) |expr| freeExpr(allocator, expr);
            allocator.free(value.upsertValues);
            if (value.upsertWhere) |conditions| {
                for (conditions) |condition| {
                    if (condition.leftExpr) |left| freeExpr(allocator, left);
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    if (condition.escape) |escape| freeExpr(allocator, escape);
                    for (condition.listValues) |item| freeExpr(allocator, item);
                    if (condition.listValues.len != 0) allocator.free(condition.listValues);
                    if (condition.tableScan) |ts| if (ts.conditions) |inner| freeConditions(allocator, inner);
                }
                allocator.free(conditions);
            }
            for (value.returning) |proj| freeExpr(allocator, proj.expr);
            if (value.returning.len != 0) allocator.free(value.returning);
        },
        .select => |value| {
            for (value.projections) |projection| freeExpr(allocator, projection.expr);
            allocator.free(value.projections);
            if (value.condition) |conditions| {
                for (conditions) |condition| {
                    if (condition.leftExpr) |left| freeExpr(allocator, left);
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    if (condition.escape) |escape| freeExpr(allocator, escape);
                    for (condition.listValues) |item| freeExpr(allocator, item);
                    if (condition.listValues.len != 0) allocator.free(condition.listValues);
                    if (condition.tableScan) |ts| if (ts.conditions) |inner| freeConditions(allocator, inner);
                }
                allocator.free(conditions);
            }
            if (value.having) |having| {
                freeExpr(allocator, having.left);
                freeExpr(allocator, having.right);
            }
            for (value.joins) |join| if (join.usingColumns.len != 0) allocator.free(join.usingColumns);
            if (value.joins.len != 0) allocator.free(value.joins);
        },
        .update => |value| {
            allocator.free(value.columns);
            for (value.values) |expr| freeExpr(allocator, expr);
            allocator.free(value.values);
            if (value.condition) |conditions| {
                for (conditions) |condition| {
                    if (condition.leftExpr) |left| freeExpr(allocator, left);
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    if (condition.escape) |escape| freeExpr(allocator, escape);
                    for (condition.listValues) |item| freeExpr(allocator, item);
                    if (condition.listValues.len != 0) allocator.free(condition.listValues);
                    if (condition.tableScan) |ts| if (ts.conditions) |inner| freeConditions(allocator, inner);
                }
                allocator.free(conditions);
            }
            for (value.returning) |proj| freeExpr(allocator, proj.expr);
            if (value.returning.len != 0) allocator.free(value.returning);
        },
        .delete => |value| {
            if (value.condition) |conditions| {
                for (conditions) |condition| {
                    if (condition.leftExpr) |left| freeExpr(allocator, left);
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    if (condition.escape) |escape| freeExpr(allocator, escape);
                    for (condition.listValues) |item| freeExpr(allocator, item);
                    if (condition.listValues.len != 0) allocator.free(condition.listValues);
                    if (condition.tableScan) |ts| if (ts.conditions) |inner| freeConditions(allocator, inner);
                }
                allocator.free(conditions);
            }
            for (value.returning) |proj| freeExpr(allocator, proj.expr);
            if (value.returning.len != 0) allocator.free(value.returning);
        },
        .attach => |att| freeExpr(allocator, att.expr),
        .detach => {},
        .vacuum => |vac| if (vac.into) |intoExpr| freeExpr(allocator, intoExpr),
        .alterTable => |alt| switch (alt) {
            .addColumn => |ac| {
                if (ac.definition.checkExpr) |chk| freeExpr(allocator, chk);
                if (ac.definition.generatedExpr) |gen| freeExpr(allocator, gen);
            },
            else => {},
        },
        else => {},
    }
}

test "ast nodes represent subqueries, compound statements, and returning clauses" {
    const returningProj = [_]Projection{.{ .expr = .{ .identifier = "id" } }};
    const insertStmt = Statement{
        .insert = .{
            .table = "users",
            .columns = &.{},
            .rows = &.{},
            .returning = &returningProj,
        },
    };
    try std.testing.expect(insertStmt == .insert);
    try std.testing.expectEqualStrings("id", insertStmt.insert.returning[0].expr.identifier);

    const compound = Statement{
        .compoundSelect = .{
            .leftSql = "SELECT 1",
            .op = .unionAllOp,
            .rightSql = "SELECT 2",
        },
    };
    try std.testing.expect(compound.isQuery());
}
