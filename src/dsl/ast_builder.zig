const std = @import("std");
const ast = @import("../sql/ast.zig");
const dslExpr = @import("expr.zig");
const CaseBuilder = @import("column.zig").CaseBuilder;
const WindowBuilder = @import("column.zig").WindowBuilder;
const WindowBound = @import("column.zig").WindowBound;
const Value = @import("../vm/value.zig").Value;
const Result = @import("../connection/result.zig").Result;

pub const CteInput = struct { name: []const u8, querySql: []const u8, recursiveSql: ?[]const u8 = null };

pub const ExecFn = *const fn (*anyopaque, *const ast.Statement, []const CteInput, bool) anyerror!Result;

pub const CompoundArm = struct { stmt: *const ast.Statement, ctes: []const CteInput, recursive: bool };

pub const CompoundExecFn = *const fn (*anyopaque, []const CompoundArm, []const ast.CompoundOp, ?ast.Order, ?usize, ?usize) anyerror!Result;

pub const DerivedExecFn = *const fn (*anyopaque, sub: CompoundArm, outer: CompoundArm) anyerror!Result;

pub const JoinKind = enum { inner, left, right, full, cross };

pub const CondEntry = struct { expr: dslExpr.Expr, joinOr: bool = false };

pub const InQueryArgs = struct {
    column: dslExpr.ColumnRef,
    table: []const u8,
    subcolumn: dslExpr.ColumnRef,
    negated: bool = false,
};

pub const ExistsQueryArgs = struct {
    table: []const u8,
    on: ?dslExpr.Expr = null,
    negated: bool = false,
};

pub const LiteralInArgs = struct {
    column: dslExpr.ColumnRef,
    values: []const Value,
    negated: bool = false,
};

pub const CaseWhereArgs = struct {
    case: CaseBuilder,
    value: dslExpr.Rhs,
    joinOr: bool = false,
};

pub const UpsertValue = union(enum) { literal: Value, excluded: []const u8 };

pub const UpsertSet = struct { name: []const u8, value: UpsertValue };

pub const UpsertArgs = struct {
    targets: []const []const u8 = &.{},
    targetWhere: ?dslExpr.Expr = null,
    sets: []const UpsertSet = &.{},
    upsertWhere: []const CondEntry = &.{},
    caseWhens: []const CaseWhereArgs = &.{},
};

pub const BuiltStatement = struct {
    stmt: ast.Statement,
    ownedStrings: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BuiltStatement) void {
        for (self.ownedStrings.items) |s| self.allocator.free(s);
        self.ownedStrings.deinit(self.allocator);
        ast.deinit(self.allocator, &self.stmt);
    }
};

const Ctx = struct {
    alloc: std.mem.Allocator,
    owned: std.ArrayList([]const u8),
    nodes: std.ArrayList(*ast.Expr),

    fn init(alloc: std.mem.Allocator) Ctx {
        return .{ .alloc = alloc, .owned = .empty, .nodes = .empty };
    }

    fn fail(self: *Ctx) void {
        while (self.nodes.pop()) |tracked| self.alloc.destroy(tracked);
        self.nodes.deinit(self.alloc);
        for (self.owned.items) |s| self.alloc.free(s);
        self.owned.deinit(self.alloc);
    }

    fn takeStrings(self: *Ctx) std.ArrayList([]const u8) {
        const moved = self.owned;
        self.owned = .empty;
        return moved;
    }

    fn dotted(self: *Ctx, table: []const u8, name: []const u8) ![]const u8 {
        if (table.len == 0) return name;
        const combined = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ table, name });
        errdefer self.alloc.free(combined);
        try self.owned.append(self.alloc, combined);
        return combined;
    }

    fn refName(self: *Ctx, ref: dslExpr.ColumnRef, stripTable: ?[]const u8) ![]const u8 {
        if (stripTable) |base| if (ref.table.len != 0 and std.ascii.eqlIgnoreCase(ref.table, base)) return ref.name;
        return self.dotted(ref.table, ref.name);
    }

    fn node(self: *Ctx) !*ast.Expr {
        const created = try self.alloc.create(ast.Expr);
        errdefer self.alloc.destroy(created);
        try self.nodes.append(self.alloc, created);
        return created;
    }

    fn detach(self: *Ctx, created: *ast.Expr) ast.Expr {
        const value = created.*;
        self.alloc.destroy(created);
        for (self.nodes.items, 0..) |tracked, index| if (tracked == created) {
            _ = self.nodes.swapRemove(index);
            break;
        };
        return value;
    }
};

fn mapCompareOp(op: dslExpr.Operator) ast.CompareOp {
    return switch (op) {
        .equal => .equal,
        .notEqual => .notEqual,
        .less => .less,
        .lessEqual => .lessEqual,
        .greater => .greater,
        .greaterEqual => .greaterEqual,
        .like => .like,
        .notLike => .notLike,
        .glob => .glob,
        .notGlob => .notGlob,
        .regexp => .regexp,
        .notRegexp => .notRegexp,
        .match => .match,
        .notMatch => .notMatch,
        .isNull => .isNull,
        .isNotNull => .isNotNull,
        .isValue => .isValue,
        .isNotValue => .isNotValue,
        .isDistinct => .isDistinct,
        .isNotDistinct => .isNotDistinct,
        .between => .between,
        .notBetween => .notBetween,
    };
}

fn rhsToExpr(ctx: *Ctx, rhs: dslExpr.Rhs, stripTable: ?[]const u8) !ast.Expr {
    return switch (rhs) {
        .value => |v| ast.Expr{ .literal = v },
        .column => |ref| ast.Expr{ .identifier = try ctx.refName(ref, stripTable) },
    };
}

fn funcToNode(ctx: *Ctx, ref: dslExpr.ColumnRef, func: dslExpr.FuncCall, stripTable: ?[]const u8) !*ast.Expr {
    const argNode = try ctx.node();
    argNode.* = .{ .identifier = try ctx.refName(ref, stripTable) };
    if (std.ascii.eqlIgnoreCase(func.name, "CAST")) {
        const target: []const u8 = if (func.hasArgument and func.argument == .text) func.argument.text else return error.InvalidSql;
        if (target.len == 0) return error.InvalidSql;
        const targetNode = try ctx.node();
        targetNode.* = .{ .identifier = target };
        const callNode = try ctx.node();
        callNode.* = .{ .function = .{ .name = func.name, .argument = argNode, .argument2 = targetNode } };
        return callNode;
    }
    var arg2: ?*const ast.Expr = null;
    if (func.hasArgument) {
        const created = try ctx.node();
        created.* = .{ .literal = func.argument };
        arg2 = created;
    }
    var arg3: ?*const ast.Expr = null;
    if (func.hasArgument2) {
        const created = try ctx.node();
        created.* = .{ .literal = func.argument2 };
        arg3 = created;
    }
    const callNode = try ctx.node();
    callNode.* = .{ .function = .{ .name = func.name, .argument = argNode, .argument2 = arg2, .argument3 = arg3 } };
    return callNode;
}

fn predicateToCondition(ctx: *Ctx, expr: dslExpr.Expr, stripTable: ?[]const u8, joinOr: bool) !ast.Condition {
    var leftExpr: ?ast.Expr = null;
    var column: []const u8 = "";
    if (expr.function) |func| {
        leftExpr = ctx.detach(try funcToNode(ctx, expr.column, func, stripTable));
    } else {
        column = try ctx.refName(expr.column, stripTable);
    }
    var value: ast.Expr = .{ .literal = .null };
    if (expr.needsRhs()) value = try rhsToExpr(ctx, expr.rhs, stripTable);
    var value2: ?ast.Expr = null;
    if (expr.needsRhs2()) value2 = try rhsToExpr(ctx, expr.rhs2.?, stripTable);
    var escape: ?ast.Expr = null;
    if (expr.escape) |esc| {
        if (expr.operator != .like and expr.operator != .notLike) return error.InvalidSql;
        escape = .{ .literal = esc };
    }
    return .{
        .column = column,
        .op = mapCompareOp(expr.operator),
        .value = value,
        .value2 = value2,
        .escape = escape,
        .negated = expr.negated,
        .collate = expr.collate,
        .joinOr = joinOr,
        .leftExpr = leftExpr,
    };
}

fn buildConditionList(ctx: *Ctx, list: *std.ArrayList(ast.Condition), conditions: []const CondEntry, stripTable: ?[]const u8) !void {
    for (conditions) |entry| try list.append(ctx.alloc, try predicateToCondition(ctx, entry.expr, stripTable, entry.joinOr));
}

fn buildCaseWhereList(ctx: *Ctx, list: *std.ArrayList(ast.Condition), cases: []const CaseWhereArgs, stripTable: ?[]const u8) !void {
    for (cases) |entry| {
        try list.append(ctx.alloc, .{
            .column = "",
            .op = .equal,
            .value = try rhsToExpr(ctx, entry.value, stripTable),
            .leftExpr = try caseToExpr(ctx, entry.case, stripTable),
            .joinOr = entry.joinOr,
        });
    }
}

fn projectionToAst(ctx: *Ctx, proj: dslExpr.Projection, stripTable: ?[]const u8, cases: []const CaseBuilder, windows: []const WindowBuilder) !ast.Projection {
    switch (proj.kind) {
        .star => return .{ .expr = .wildcard },
        .countStar => {
            const argNode = try ctx.node();
            argNode.* = .wildcard;
            const callNode = try ctx.node();
            callNode.* = .{ .function = .{ .name = "COUNT", .argument = argNode } };
            return .{ .expr = ctx.detach(callNode) };
        },
        .column => return .{ .expr = .{ .identifier = try ctx.refName(proj.column, stripTable) } },
        .aggregate => {
            const argNode = try ctx.node();
            argNode.* = .{ .identifier = try ctx.refName(proj.column, stripTable) };
            const callNode = try ctx.node();
            callNode.* = .{ .function = .{ .name = proj.function, .argument = argNode, .distinct = proj.distinct } };
            return .{ .expr = ctx.detach(callNode) };
        },
        .scalar => {
            if (std.ascii.eqlIgnoreCase(proj.function, "CAST")) {
                const target: []const u8 = if (proj.hasArgument and proj.argument == .text) proj.argument.text else return error.InvalidSql;
                if (target.len == 0) return error.InvalidSql;
                const argNode = try ctx.node();
                argNode.* = .{ .identifier = try ctx.refName(proj.column, stripTable) };
                const targetNode = try ctx.node();
                targetNode.* = .{ .identifier = target };
                const callNode = try ctx.node();
                callNode.* = .{ .function = .{ .name = proj.function, .argument = argNode, .argument2 = targetNode } };
                return .{ .expr = ctx.detach(callNode) };
            }
            const argNode = try ctx.node();
            argNode.* = .{ .identifier = try ctx.refName(proj.column, stripTable) };
            var arg2: ?*const ast.Expr = null;
            if (proj.hasArgument) {
                const created = try ctx.node();
                created.* = .{ .literal = proj.argument };
                arg2 = created;
            }
            var arg3: ?*const ast.Expr = null;
            if (proj.hasArgument2) {
                const created = try ctx.node();
                created.* = .{ .literal = proj.argument2 };
                arg3 = created;
            }
            const callNode = try ctx.node();
            callNode.* = .{ .function = .{ .name = proj.function, .argument = argNode, .argument2 = arg2, .argument3 = arg3 } };
            return .{ .expr = ctx.detach(callNode) };
        },
        .caseExpr => {
            if (proj.caseSlot >= cases.len) return error.InvalidSql;
            return .{ .expr = try caseToExpr(ctx, cases[proj.caseSlot], stripTable) };
        },
        .window => {
            if (proj.windowSlot >= windows.len) return error.InvalidSql;
            return .{ .expr = try windowToExpr(ctx, windows[proj.windowSlot], stripTable) };
        },
    }
}

fn leftSideToExpr(ctx: *Ctx, column: dslExpr.ColumnRef, func: ?dslExpr.FuncCall, stripTable: ?[]const u8) !ast.Expr {
    if (func) |call| {
        const callNode = try funcToNode(ctx, column, call, stripTable);
        return ctx.detach(callNode);
    }
    return .{ .identifier = try ctx.refName(column, stripTable) };
}

fn binaryNode(ctx: *Ctx, op: ast.BinaryOp, left: ast.Expr, right: ast.Expr) !*ast.Expr {
    const leftNode = try ctx.node();
    leftNode.* = left;
    const rightNode = try ctx.node();
    rightNode.* = right;
    const parent = try ctx.node();
    parent.* = .{ .binary = .{ .op = op, .left = leftNode, .right = rightNode } };
    return parent;
}

fn predicateToBinary(ctx: *Ctx, expr: dslExpr.Expr, stripTable: ?[]const u8) anyerror!ast.Expr {
    const root: *ast.Expr = switch (expr.operator) {
        .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual => try binaryNode(ctx, switch (expr.operator) {
            .equal => ast.BinaryOp.equal,
            .notEqual => ast.BinaryOp.notEqual,
            .less => ast.BinaryOp.less,
            .lessEqual => ast.BinaryOp.lessEqual,
            .greater => ast.BinaryOp.greater,
            else => ast.BinaryOp.greaterEqual,
        }, try leftSideToExpr(ctx, expr.column, expr.function, stripTable), try rhsToExpr(ctx, expr.rhs, stripTable)),
        .isValue => try binaryNode(ctx, .isOp, try leftSideToExpr(ctx, expr.column, expr.function, stripTable), try rhsToExpr(ctx, expr.rhs, stripTable)),
        .isNotValue => try binaryNode(ctx, .isNotOp, try leftSideToExpr(ctx, expr.column, expr.function, stripTable), try rhsToExpr(ctx, expr.rhs, stripTable)),
        .isNotDistinct => try binaryNode(ctx, .isOp, try leftSideToExpr(ctx, expr.column, expr.function, stripTable), try rhsToExpr(ctx, expr.rhs, stripTable)),
        .isDistinct => blk: {
            const inner = try binaryNode(ctx, .isOp, try leftSideToExpr(ctx, expr.column, expr.function, stripTable), try rhsToExpr(ctx, expr.rhs, stripTable));
            const notNode = try ctx.node();
            notNode.* = .{ .unary = .{ .op = .logicalNot, .expr = inner } };
            break :blk notNode;
        },
        .like, .notLike, .glob, .notGlob, .regexp, .notRegexp, .match, .notMatch => blk: {
            const valueNode = try ctx.node();
            valueNode.* = try leftSideToExpr(ctx, expr.column, expr.function, stripTable);
            const patternNode = try ctx.node();
            patternNode.* = try rhsToExpr(ctx, expr.rhs, stripTable);
            var escapeNode: ?*const ast.Expr = null;
            if (expr.escape) |esc| {
                if (expr.operator != .like and expr.operator != .notLike) return error.InvalidSql;
                const created = try ctx.node();
                created.* = .{ .literal = esc };
                escapeNode = created;
            }
            const matchNode = try ctx.node();
            matchNode.* = .{ .patternMatch = .{
                .value = valueNode,
                .pattern = patternNode,
                .escape = escapeNode,
                .negated = expr.operator == .notLike or expr.operator == .notGlob or expr.operator == .notRegexp or expr.operator == .notMatch,
                .glob = expr.operator == .glob or expr.operator == .notGlob,
                .isRegexp = expr.operator == .regexp or expr.operator == .notRegexp,
                .isMatch = expr.operator == .match or expr.operator == .notMatch,
            } };
            break :blk matchNode;
        },
        .between => blk: {
            const lower = try binaryNode(ctx, .greaterEqual, try leftSideToExpr(ctx, expr.column, expr.function, stripTable), try rhsToExpr(ctx, expr.rhs, stripTable));
            const upper = try binaryNode(ctx, .lessEqual, try leftSideToExpr(ctx, expr.column, expr.function, stripTable), try rhsToExpr(ctx, expr.rhs2.?, stripTable));
            const both = try ctx.node();
            both.* = .{ .binary = .{ .op = .logicalAnd, .left = lower, .right = upper } };
            break :blk both;
        },
        .notBetween => blk: {
            const lower = try binaryNode(ctx, .less, try leftSideToExpr(ctx, expr.column, expr.function, stripTable), try rhsToExpr(ctx, expr.rhs, stripTable));
            const upper = try binaryNode(ctx, .greater, try leftSideToExpr(ctx, expr.column, expr.function, stripTable), try rhsToExpr(ctx, expr.rhs2.?, stripTable));
            const either = try ctx.node();
            either.* = .{ .binary = .{ .op = .logicalOr, .left = lower, .right = upper } };
            break :blk either;
        },
        .isNull, .isNotNull => return error.InvalidSql,
    };
    if (!expr.negated) return ctx.detach(root);
    const notNode = try ctx.node();
    notNode.* = .{ .unary = .{ .op = .logicalNot, .expr = root } };
    return ctx.detach(notNode);
}

fn baseToExpr(ctx: *Ctx, case: CaseBuilder, stripTable: ?[]const u8) !ast.Expr {
    if (case.base) |baseRef| {
        if (case.baseFunc) |func| {
            const callNode = try funcToNode(ctx, baseRef, func, stripTable);
            return ctx.detach(callNode);
        }
        return .{ .identifier = try ctx.refName(baseRef, stripTable) };
    }
    const func = case.baseFunc orelse return error.InvalidSql;
    const callNode = try funcToNode(ctx, .{ .name = "" }, func, stripTable);
    return ctx.detach(callNode);
}

fn caseToExpr(ctx: *Ctx, case: CaseBuilder, stripTable: ?[]const u8) !ast.Expr {
    if (case.count == 0) return error.InvalidSql;
    var base: ?*const ast.Expr = null;
    if (case.base != null or case.baseFunc != null) {
        const created = try ctx.node();
        created.* = try baseToExpr(ctx, case, stripTable);
        base = created;
    }
    const whens = try ctx.alloc.alloc(ast.CaseWhen, case.count);
    errdefer ctx.alloc.free(whens);
    for (case.whens[0..case.count], 0..) |when, index| {
        if (when.simple) {
            if (base == null) return error.InvalidSql;
            whens[index] = .{ .condition = try rhsToExpr(ctx, when.operand, stripTable), .result = try rhsToExpr(ctx, when.result, stripTable) };
        } else {
            const cond = when.cond orelse return error.InvalidSql;
            whens[index] = .{ .condition = try predicateToBinary(ctx, cond, stripTable), .result = try rhsToExpr(ctx, when.result, stripTable) };
        }
    }
    const otherwiseNode = try ctx.node();
    if (case.hasOtherwise) {
        otherwiseNode.* = try rhsToExpr(ctx, case.otherwise, stripTable);
    } else {
        otherwiseNode.* = .{ .literal = .null };
    }
    return .{ .caseExpr = .{ .base = base, .whens = whens, .otherwise = otherwiseNode } };
}

fn isWindowFunction(name: []const u8) bool {
    const known = [_][]const u8{ "row_number", "rank", "dense_rank", "percent_rank", "cume_dist", "ntile", "lag", "lead", "first_value", "last_value", "nth_value" };
    for (known) |candidate| if (std.ascii.eqlIgnoreCase(candidate, name)) return true;
    return false;
}

fn mapWindowBound(bound: WindowBound) struct { bound: ast.WindowFrameBound, offset: usize } {
    return switch (bound) {
        .unboundedPreceding => .{ .bound = .unboundedPreceding, .offset = 0 },
        .preceding => |offset| .{ .bound = .preceding, .offset = offset },
        .currentRow => .{ .bound = .currentRow, .offset = 0 },
        .following => |offset| .{ .bound = .following, .offset = offset },
        .unboundedFollowing => .{ .bound = .unboundedFollowing, .offset = 0 },
    };
}

fn windowToExpr(ctx: *Ctx, window: WindowBuilder, stripTable: ?[]const u8) !ast.Expr {
    if (!isWindowFunction(window.func)) return error.InvalidSql;
    const funcIsNtile = std.ascii.eqlIgnoreCase(window.func, "ntile");
    var argument: ?*const ast.Expr = null;
    if (window.arg) |ref| {
        const created = try ctx.node();
        created.* = .{ .identifier = try ctx.refName(ref, stripTable) };
        argument = created;
    } else if (funcIsNtile and window.hasArgInt) {
        const created = try ctx.node();
        created.* = .{ .literal = .{ .integer = window.argInt } };
        argument = created;
    }
    var argument2: ?*const ast.Expr = null;
    if (window.hasArgInt) {
        const created = try ctx.node();
        created.* = .{ .literal = .{ .integer = window.argInt } };
        argument2 = created;
    }
    var extraArgs: []const ast.Expr = &.{};
    if (window.hasDefault) {
        const owned = try ctx.alloc.alloc(ast.Expr, 1);
        errdefer ctx.alloc.free(owned);
        owned[0] = try rhsToExpr(ctx, window.defaultRhs, stripTable);
        extraArgs = owned;
    }
    var partitions: []const ast.Expr = &.{};
    if (window.partitionCount > 0) {
        const owned = try ctx.alloc.alloc(ast.Expr, window.partitionCount);
        errdefer ctx.alloc.free(owned);
        for (window.partitions[0..window.partitionCount], 0..) |ref, index| owned[index] = .{ .identifier = try ctx.refName(ref, stripTable) };
        partitions = owned;
    }
    var orderBy: []const ast.OrderItem = &.{};
    if (window.orderCount > 0) {
        const owned = try ctx.alloc.alloc(ast.OrderItem, window.orderCount);
        errdefer ctx.alloc.free(owned);
        for (window.orders[0..window.orderCount], 0..) |ord, index| {
            if (ord.function != null) return error.InvalidSql;
            owned[index] = .{ .expr = .{ .identifier = try ctx.refName(ord.column, stripTable) }, .descending = ord.descending };
        }
        orderBy = owned;
    }
    var frame: ?ast.WindowFrame = null;
    if (window.frame) |spec| {
        const start = mapWindowBound(spec.start);
        const end = mapWindowBound(spec.end);
        frame = .{
            .kind = switch (spec.kind) {
                .rows => ast.WindowFrameKind.rows,
                .range => ast.WindowFrameKind.range,
                .groups => ast.WindowFrameKind.groups,
            },
            .start = start.bound,
            .startOffset = start.offset,
            .end = end.bound,
            .endOffset = end.offset,
        };
    }
    return .{ .window = .{ .funcName = window.func, .argument = argument, .argument2 = argument2, .extraArgs = extraArgs, .partitionBy = partitions, .orderBy = orderBy, .frame = frame } };
}

fn mapJoinKind(kind: JoinKind) ast.JoinKind {
    return switch (kind) {
        .inner => .inner,
        .left => .left,
        .right => .right,
        .full => .full,
        .cross => .cross,
    };
}

fn mapHavingOp(operator: []const u8) !ast.CompareOp {
    if (std.mem.eql(u8, operator, "=")) return .equal;
    if (std.mem.eql(u8, operator, "<>")) return .notEqual;
    if (std.mem.eql(u8, operator, "<")) return .less;
    if (std.mem.eql(u8, operator, "<=")) return .lessEqual;
    if (std.mem.eql(u8, operator, ">")) return .greater;
    if (std.mem.eql(u8, operator, ">=")) return .greaterEqual;
    return error.InvalidSql;
}

pub const SelectArgs = struct {
    table: []const u8,
    allColumns: bool,
    projections: []const dslExpr.Projection,
    cases: []const CaseBuilder = &.{},
    windows: []const WindowBuilder = &.{},
    caseWhens: []const CaseWhereArgs = &.{},
    distinct: bool,
    conditions: []const CondEntry,
    order: ?dslExpr.Order,
    limit: ?usize,
    offset: ?usize,
    groupBy: ?dslExpr.ColumnRef,
    havingOp: ?[]const u8,
    havingAmount: usize,
    joinTable: ?[]const u8,
    joinKind: JoinKind,
    joinOn: ?dslExpr.Expr,
    joinUsingCols: []const []const u8 = &.{},
    joinNatural: bool = false,
    inQuery: ?InQueryArgs,
    existsQuery: ?ExistsQueryArgs,
    literalIn: ?LiteralInArgs,
};

pub fn buildSelect(allocator: std.mem.Allocator, args: SelectArgs) !BuiltStatement {
    var ctx = Ctx.init(allocator);
    var projections = std.ArrayList(ast.Projection).empty;
    defer projections.deinit(allocator);
    var conditions = std.ArrayList(ast.Condition).empty;
    defer conditions.deinit(allocator);
    errdefer ctx.fail();
    if (args.allColumns) {
        try projections.append(allocator, .{ .expr = .wildcard });
    } else {
        for (args.projections) |proj| try projections.append(allocator, try projectionToAst(&ctx, proj, args.table, args.cases, args.windows));
    }
    try buildConditionList(&ctx, &conditions, args.conditions, args.table);
    try buildCaseWhereList(&ctx, &conditions, args.caseWhens, args.table);
    if (args.inQuery) |subquery| {
        const ts = ast.TableScan{ .table = subquery.table, .column = subquery.subcolumn.name };
        try conditions.append(allocator, .{
            .column = try ctx.refName(subquery.column, args.table),
            .op = if (subquery.negated) .notIn else .in,
            .value = .{ .literal = .null },
            .tableScan = ts,
            .joinOr = conditions.items.len != 0,
        });
    }
    if (args.existsQuery) |subquery| {
        var onConds: ?ast.Conditions = null;
        if (subquery.on) |on| {
            const list = try allocator.alloc(ast.Condition, 1);
            errdefer allocator.free(list);
            list[0] = try predicateToCondition(&ctx, on, null, false);
            onConds = list;
        }
        const ts = ast.TableScan{ .table = subquery.table, .conditions = onConds };
        try conditions.append(allocator, .{
            .column = "",
            .op = if (subquery.negated) .notExists else .exists,
            .value = .{ .literal = .null },
            .tableScan = ts,
            .joinOr = conditions.items.len != 0,
        });
    }
    if (args.literalIn) |list| {
        const items = try allocator.alloc(ast.Expr, list.values.len);
        errdefer allocator.free(items);
        for (list.values, 0..) |value, index| items[index] = .{ .literal = value };
        try conditions.append(allocator, .{
            .column = try ctx.refName(list.column, args.table),
            .op = if (list.negated) .notIn else .in,
            .value = .{ .literal = .null },
            .listValues = items,
            .joinOr = conditions.items.len != 0,
        });
    }
    var join: ?ast.Join = null;
    var ownedUsing: []const []const u8 = &.{};
    errdefer if (ownedUsing.len != 0) allocator.free(ownedUsing);
    if (args.joinTable) |joined| {
        if (args.joinNatural) {
            join = .{ .kind = mapJoinKind(args.joinKind), .table = joined, .leftTable = "", .leftColumn = "", .rightTable = "", .rightColumn = "", .mergeOutput = true };
        } else if (args.joinUsingCols.len == 1) {
            const usingCol = args.joinUsingCols[0];
            if (usingCol.len == 0) return error.InvalidSql;
            join = .{ .kind = mapJoinKind(args.joinKind), .table = joined, .leftTable = args.table, .leftColumn = usingCol, .rightTable = joined, .rightColumn = usingCol, .mergeOutput = true };
        } else if (args.joinUsingCols.len > 1) {
            for (args.joinUsingCols) |usingCol| if (usingCol.len == 0) return error.InvalidSql;
            ownedUsing = try allocator.dupe([]const u8, args.joinUsingCols);
            join = .{ .kind = mapJoinKind(args.joinKind), .table = joined, .leftTable = args.table, .leftColumn = "", .rightTable = joined, .rightColumn = "", .mergeOutput = true, .usingColumns = ownedUsing };
        } else if (args.joinKind == .cross) {
            join = .{ .kind = .cross, .table = joined, .leftTable = "", .leftColumn = "", .rightTable = "", .rightColumn = "" };
        } else {
            const on = args.joinOn orelse return error.InvalidSql;
            if (on.operator != .equal) return error.InvalidSql;
            const rightRef = switch (on.rhs) {
                .column => |ref| ref,
                .value => return error.InvalidSql,
            };
            join = .{
                .kind = mapJoinKind(args.joinKind),
                .table = joined,
                .leftTable = on.column.table,
                .leftColumn = on.column.name,
                .rightTable = rightRef.table,
                .rightColumn = rightRef.name,
            };
        }
    }
    var groupBy: ?[]const u8 = null;
    if (args.groupBy) |group| groupBy = group.name;
    var having: ?ast.Having = null;
    if (args.havingOp) |operator| {
        const countArg = try ctx.node();
        countArg.* = .wildcard;
        const countNode = try ctx.node();
        countNode.* = .{ .function = .{ .name = "COUNT", .argument = countArg } };
        having = .{ .left = ctx.detach(countNode), .op = try mapHavingOp(operator), .right = .{ .literal = .{ .integer = @intCast(args.havingAmount) } } };
    }
    var order: ?ast.Order = null;
    if (args.order) |ord| {
        if (ord.function != null) return error.InvalidSql;
        order = .{ .column = ord.column.name, .descending = ord.descending };
    }
    var ownedJoins: []const ast.Join = &.{};
    errdefer if (ownedJoins.len != 0) allocator.free(ownedJoins);
    if (join) |single| ownedJoins = try allocator.dupe(ast.Join, &[_]ast.Join{single});
    const stmt = ast.Statement{ .select = .{
        .projections = try projections.toOwnedSlice(allocator),
        .table = args.table,
        .joins = ownedJoins,
        .condition = if (conditions.items.len == 0) null else try conditions.toOwnedSlice(allocator),
        .groupBy = groupBy,
        .having = having,
        .order = order,
        .limit = args.limit,
        .offset = args.offset,
        .distinct = args.distinct,
    } };
    ctx.nodes.deinit(allocator);
    return .{ .stmt = stmt, .ownedStrings = ctx.takeStrings(), .allocator = allocator };
}

pub fn buildInsert(allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, values: []const Value, conflict: ast.ConflictPolicy, returning: []const dslExpr.Projection, cases: []const CaseBuilder, upsert: UpsertArgs) !BuiltStatement {
    if (columns.len == 0 or columns.len != values.len) return error.InvalidSql;
    var ctx = Ctx.init(allocator);
    errdefer ctx.fail();
    const ownedColumns = try allocator.dupe([]const u8, columns);
    errdefer allocator.free(ownedColumns);
    const row = try allocator.alloc(ast.Expr, values.len);
    errdefer allocator.free(row);
    for (values, 0..) |value, index| row[index] = .{ .literal = value };
    const rows = try allocator.alloc([]const ast.Expr, 1);
    errdefer allocator.free(rows);
    rows[0] = row;
    const ownedTargets = try allocator.dupe([]const u8, upsert.targets);
    errdefer allocator.free(ownedTargets);
    var targetWhere: ?ast.Conditions = null;
    if (upsert.targetWhere) |targetExpr| {
        const list = try allocator.alloc(ast.Condition, 1);
        errdefer allocator.free(list);
        list[0] = try predicateToCondition(&ctx, targetExpr, table, false);
        targetWhere = list;
    }
    const upsertColumns = try allocator.alloc([]const u8, upsert.sets.len);
    errdefer allocator.free(upsertColumns);
    const upsertValues = try allocator.alloc(ast.Expr, upsert.sets.len);
    errdefer allocator.free(upsertValues);
    for (upsert.sets, 0..) |set, index| {
        upsertColumns[index] = set.name;
        upsertValues[index] = switch (set.value) {
            .literal => |v| ast.Expr{ .literal = v },
            .excluded => |name| ast.Expr{ .identifier = try ctx.dotted("excluded", name) },
        };
    }
    var upsertCondList = std.ArrayList(ast.Condition).empty;
    defer upsertCondList.deinit(allocator);
    try buildConditionList(&ctx, &upsertCondList, upsert.upsertWhere, table);
    try buildCaseWhereList(&ctx, &upsertCondList, upsert.caseWhens, table);
    const returningProjs = try allocator.alloc(ast.Projection, returning.len);
    errdefer allocator.free(returningProjs);
    for (returning, 0..) |proj, index| returningProjs[index] = try projectionToAst(&ctx, proj, table, cases, &.{});
    const stmt = ast.Statement{ .insert = .{
        .table = table,
        .columns = ownedColumns,
        .rows = rows,
        .conflict = conflict,
        .conflictTargetColumns = ownedTargets,
        .conflictTargetWhere = targetWhere,
        .upsertColumns = upsertColumns,
        .upsertValues = upsertValues,
        .upsertWhere = if (upsertCondList.items.len == 0) null else try upsertCondList.toOwnedSlice(allocator),
        .returning = returningProjs,
    } };
    ctx.nodes.deinit(allocator);
    return .{ .stmt = stmt, .ownedStrings = ctx.takeStrings(), .allocator = allocator };
}

pub fn buildUpdate(allocator: std.mem.Allocator, table: []const u8, setNames: []const []const u8, setValues: []const Value, conditions: []const CondEntry, returning: []const dslExpr.Projection, cases: []const CaseBuilder, caseWhens: []const CaseWhereArgs, from: ?ast.UpdateFrom) !BuiltStatement {
    if (setNames.len == 0 or setNames.len != setValues.len) return error.InvalidSql;
    var ctx = Ctx.init(allocator);
    var condList = std.ArrayList(ast.Condition).empty;
    defer condList.deinit(allocator);
    errdefer ctx.fail();
    const ownedColumns = try allocator.dupe([]const u8, setNames);
    errdefer allocator.free(ownedColumns);
    const assigned = try allocator.alloc(ast.Expr, setValues.len);
    errdefer allocator.free(assigned);
    for (setValues, 0..) |value, index| assigned[index] = .{ .literal = value };
    try buildConditionList(&ctx, &condList, conditions, table);
    try buildCaseWhereList(&ctx, &condList, caseWhens, table);
    const returningProjs = try allocator.alloc(ast.Projection, returning.len);
    errdefer allocator.free(returningProjs);
    for (returning, 0..) |proj, index| returningProjs[index] = try projectionToAst(&ctx, proj, table, cases, &.{});
    const stmt = ast.Statement{ .update = .{
        .table = table,
        .columns = ownedColumns,
        .values = assigned,
        .condition = if (condList.items.len == 0) null else try condList.toOwnedSlice(allocator),
        .from = from,
        .returning = returningProjs,
    } };
    ctx.nodes.deinit(allocator);
    return .{ .stmt = stmt, .ownedStrings = ctx.takeStrings(), .allocator = allocator };
}

pub fn buildDelete(allocator: std.mem.Allocator, table: []const u8, conditions: []const CondEntry, returning: []const dslExpr.Projection, cases: []const CaseBuilder, caseWhens: []const CaseWhereArgs) !BuiltStatement {
    var ctx = Ctx.init(allocator);
    var condList = std.ArrayList(ast.Condition).empty;
    defer condList.deinit(allocator);
    errdefer ctx.fail();
    try buildConditionList(&ctx, &condList, conditions, table);
    try buildCaseWhereList(&ctx, &condList, caseWhens, table);
    const returningProjs = try allocator.alloc(ast.Projection, returning.len);
    errdefer allocator.free(returningProjs);
    for (returning, 0..) |proj, index| returningProjs[index] = try projectionToAst(&ctx, proj, table, cases, &.{});
    const stmt = ast.Statement{ .delete = .{
        .table = table,
        .condition = if (condList.items.len == 0) null else try condList.toOwnedSlice(allocator),
        .returning = returningProjs,
    } };
    ctx.nodes.deinit(allocator);
    return .{ .stmt = stmt, .ownedStrings = ctx.takeStrings(), .allocator = allocator };
}

test "predicates convert to conditions without SQL strings" {
    const allocator = std.testing.allocator;
    const DynamicColumn = @import("column.zig").DynamicColumn;
    const col = DynamicColumn{ .name = "users.age" };
    var ctx = Ctx.init(allocator);
    defer ctx.fail();
    const cond = try predicateToCondition(&ctx, col.gte(18), "users", false);
    try std.testing.expectEqualStrings("age", cond.column);
    try std.testing.expect(cond.op == .greaterEqual);
    try std.testing.expect(cond.value.literal.integer == 18);
    try std.testing.expect(ctx.owned.items.len == 0);
    const between = try predicateToCondition(&ctx, col.between(1, 9), "users", true);
    try std.testing.expect(between.op == .between);
    try std.testing.expect(between.joinOr);
    try std.testing.expect(between.value.literal.integer == 1);
    try std.testing.expect(between.value2.?.literal.integer == 9);
    const cross = try predicateToCondition(&ctx, (DynamicColumn{ .name = "a.id" }).eq(DynamicColumn{ .name = "b.aid" }), null, false);
    try std.testing.expectEqualStrings("a.id", cross.column);
    try std.testing.expectEqualStrings("b.aid", cross.value.identifier);
    try std.testing.expect(ctx.owned.items.len == 2);
}

test "function predicates build left expressions" {
    const allocator = std.testing.allocator;
    const col = @import("column.zig").DynamicColumn{ .name = "name" };
    var ctx = Ctx.init(allocator);
    defer ctx.fail();
    const cond = try predicateToCondition(&ctx, col.lower().eq("alice"), "users", false);
    try std.testing.expectEqualStrings("", cond.column);
    try std.testing.expect(cond.leftExpr.? == .function);
    try std.testing.expectEqualStrings("LOWER", cond.leftExpr.?.function.name);
    try std.testing.expect(cond.value.literal.text.len == 5);
    const like = try predicateToCondition(&ctx, col.likeEscape("Al%", "\\"), "users", false);
    try std.testing.expect(like.op == .like);
    try std.testing.expect(like.escape.?.literal.text.len == 1);
}

test "projections convert star, aggregates, and scalars" {
    const allocator = std.testing.allocator;
    const column = @import("column.zig").DynamicColumn;
    var ctx = Ctx.init(allocator);
    defer ctx.fail();
    const star = try projectionToAst(&ctx, .{ .kind = .star }, "t", &.{}, &.{});
    try std.testing.expect(star.expr == .wildcard);
    const total = try projectionToAst(&ctx, (column{ .name = "t.age" }).sum(), "t", &.{}, &.{});
    try std.testing.expect(total.expr == .function);
    try std.testing.expectEqualStrings("SUM", total.expr.function.name);
    try std.testing.expectEqualStrings("age", total.expr.function.argument.*.identifier);
    const lowered = try projectionToAst(&ctx, (column{ .name = "name" }).lower().projection(), "t", &.{}, &.{});
    try std.testing.expectEqualStrings("LOWER", lowered.expr.function.name);
    const casted = try projectionToAst(&ctx, (column{ .name = "v" }).cast("INTEGER").projection(), "t", &.{}, &.{});
    try std.testing.expectEqualStrings("CAST", casted.expr.function.name);
    try std.testing.expectEqualStrings("INTEGER", casted.expr.function.argument2.?.*.identifier);
}
