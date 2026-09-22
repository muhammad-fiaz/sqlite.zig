//! Syntax tree nodes shared by the parser and planner.
//!
//! Borrowed trees free with `deinit`; owned trees free with `freeOwnedExpr`.
//! Cloning fails only on out of memory.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;

/// WHERE/HAVING comparison operators, including SQLite-only predicates.
pub const CompareOp = enum { equal, notEqual, less, lessEqual, greater, greaterEqual, like, notLike, glob, notGlob, regexp, notRegexp, match, notMatch, isNull, isNotNull, isValue, isNotValue, isDistinct, isNotDistinct, between, notBetween, in, notIn, exists, notExists, isTrue };

/// One ORDER BY / window-ORDER-BY key: expression plus direction/null placement.
pub const OrderItem = struct {
    /// Sort key expression (owned per the enclosing flavor; see module docs).
    expr: Expr,
    /// True for `DESC`, false for `ASC`/default.
    descending: bool = false,
    /// True for `NULLS FIRST`, false for default/`NULLS LAST`.
    nullsFirst: bool = false,
};

/// Window frame unit (`ROWS`/`RANGE`/`GROUPS`).
pub const WindowFrameKind = enum { rows, range, groups };
/// One end of a window frame.
pub const WindowFrameBound = enum { unboundedPreceding, preceding, currentRow, following, unboundedFollowing };
/// Rows removed from a window frame (`EXCLUDE ...`); `none` keeps everything.
pub const WindowExclude = enum { none, currentRow, group, ties };
/// Complete frame descriptor; `end == null` means "same as start" (single-bound form).
pub const WindowFrame = struct {
    /// Frame unit.
    kind: WindowFrameKind = .rows,
    /// Start bound.
    start: WindowFrameBound = .unboundedPreceding,
    /// Expression for `N` in `N PRECEDING`/`N FOLLOWING`; null means 0.
    /// Offsets are full expressions (literals, parameters, column refs) that
    /// must evaluate to a non-negative integer per row, like the reference.
    startOffset: ?*const Expr = null,
    /// End bound, or null for the single-bound shorthand.
    end: ?WindowFrameBound = null,
    /// Expression for `N` for the end bound; null means 0.
    endOffset: ?*const Expr = null,
    /// Rows to remove from the frame (`EXCLUDE`); default keeps everything.
    exclude: WindowExclude = .none,
};

/// Owned expression tree. Pointer children are heap nodes; see module docs.
pub const Expr = union(enum) {
    literal: Value,
    identifier: []const u8,
    parameter: usize,
    wildcard,
    function: struct { name: []const u8, argument: *const Expr, argument2: ?*const Expr = null, argument3: ?*const Expr = null, extraArgs: []const Expr = &.{}, distinct: bool = false, filter: ?*const Expr = null },
    binary: struct { op: BinaryOp, left: *const Expr, right: *const Expr },
    unary: struct { op: UnaryOp, expr: *const Expr },
    caseExpr: struct { base: ?*const Expr, whens: []CaseWhen, otherwise: ?*const Expr = null },
    patternMatch: struct { value: *const Expr, pattern: *const Expr, escape: ?*const Expr = null, negated: bool = false, glob: bool = false, isRegexp: bool = false, isMatch: bool = false },
    collate: struct { expr: *const Expr, name: []const u8 },
    scalarSubquery: []const u8,
    existsSubquery: []const u8,
    inSubquery: struct { expr: *const Expr, subquery: []const u8, negated: bool = false },
    inList: struct { expr: *const Expr, list: []const Expr, negated: bool = false },
    window: struct { funcName: []const u8, argument: ?*const Expr = null, argument2: ?*const Expr = null, extraArgs: []const Expr = &.{}, partitionBy: []const Expr = &.{}, orderBy: []const OrderItem = &.{}, frame: ?WindowFrame = null, filter: ?*const Expr = null, distinct: bool = false, base: ?[]const u8 = null },
};
/// Binary expression operators (arithmetic, bitwise, concat, comparison, logic).
pub const BinaryOp = enum { add, subtract, multiply, divide, modulo, concat, bitAnd, bitOr, shiftLeft, shiftRight, equal, notEqual, less, lessEqual, greater, greaterEqual, logicalAnd, logicalOr, isOp, isNotOp };
/// Unary operators; `logicalNot` is three-valued (NULL stays NULL).
pub const UnaryOp = enum { negate, positive, bitNot, logicalNot };
/// One `WHEN cond THEN result` arm of a `CASE`.
pub const CaseWhen = struct { condition: Expr, result: Expr };

/// Legacy flat WHERE conjunct used by the planner/executor fast path.
/// `leftExpr` carries arbitrary expression keys; `column` the simple-column fast path.
pub const Condition = struct { column: []const u8, op: CompareOp, value: Expr, value2: ?Expr = null, subquery: ?[]const u8 = null, tableScan: ?TableScan = null, listValues: []const Expr = &.{}, joinOr: bool = false, leftExpr: ?Expr = null, escape: ?Expr = null, negated: bool = false, collate: ?[]const u8 = null };
/// Correlated table-scan predicate (EXISTS-style delegation to storage).
pub const TableScan = struct { table: []const u8, column: []const u8 = "", conditions: ?Conditions = null };
/// One HAVING comparison arm; `joinOr` on element i joins i to i+1 with OR.
pub const HavingItem = struct { left: Expr, op: CompareOp, right: Expr, joinOr: bool = false };
/// HAVING clause arms; same AND/OR join semantics as `Conditions`.
pub const Having = []const HavingItem;
/// WHERE condition list; `joinOr == true` on element i joins i to i+1 with OR.
pub const Conditions = []const Condition;
/// Legacy ORDER BY entry (column-name form; `OrderItem` is the expression form).
pub const Order = struct { column: []const u8, descending: bool };
/// Join flavor; `cross` and bare `natural` carry empty join keys.
pub const JoinKind = enum { inner, left, right, full, cross };
/// One JOIN arm; USING(single-col) lowers to left/right column pair.
pub const Join = struct { kind: JoinKind, table: []const u8, tableAlias: ?[]const u8 = null, leftTable: []const u8, leftColumn: []const u8, rightTable: []const u8, rightColumn: []const u8, mergeOutput: bool = false, usingColumns: []const []const u8 = &.{} };
/// SELECT output item with optional alias.
pub const Projection = struct { expr: Expr, alias: ?[]const u8 = null };
/// Inline `REFERENCES t(c)` column constraint. `deferrable` with
/// `initiallyDeferred` postpones enforcement to COMMIT (or statement end in
/// autocommit); otherwise the constraint is immediate.
pub const ForeignKeyDef = struct { table: []const u8, column: []const u8, onDelete: ReferentialAction = .restrict, onUpdate: ReferentialAction = .restrict, deferrable: bool = false, initiallyDeferred: bool = false };
/// FK referential actions; default `.restrict` matches the parser default.
pub const ReferentialAction = enum { restrict, cascade, setNull, setDefault, noAction };
/// Column definition; `typeName` may be "" (untyped affinity) or multi-word.
pub const ColumnDef = struct { name: []const u8, typeName: []const u8, primaryKey: bool = false, notNull: bool = false, unique: bool = false, autoincrement: bool = false, foreignKey: ?ForeignKeyDef = null, defaultValue: ?Value = null, checkExpr: ?Expr = null, generatedExpr: ?Expr = null, generatedStored: bool = false };
/// Table-level `FOREIGN KEY (cols) REFERENCES t(cols)` constraint.
/// Deferral semantics match `ForeignKeyDef`.
pub const TableForeignKeyDef = struct { columns: []const []const u8, table: []const u8, referencedColumns: []const []const u8, onDelete: ReferentialAction = .restrict, onUpdate: ReferentialAction = .restrict, deferrable: bool = false, initiallyDeferred: bool = false };
/// Table-level constraints (PK/UNIQUE/FK/CHECK).
pub const TableConstraint = union(enum) { primaryKey: []const []const u8, unique: []const []const u8, foreignKey: TableForeignKeyDef, check: Expr };
/// CREATE INDEX payload; `keyExprs` parallels `columns` (null = plain column).
pub const IndexDef = struct { name: []const u8, table: []const u8, columns: []const []const u8, keyExprs: []const ?Expr = &.{}, unique: bool = false, ifNotExists: bool = false, whereExpr: ?Expr = null, whereSql: ?[]const u8 = null };
/// Trigger DML event.
pub const TriggerEvent = enum { insert, update, delete };
/// Trigger firing time (SQLite has no INSTEAD OF here yet).
pub const TriggerTiming = enum { before, after };
/// CREATE TRIGGER payload; `body`/`whenSql` are retained source slices.
pub const TriggerDef = struct { name: []const u8, table: []const u8, timing: TriggerTiming = .after, event: TriggerEvent, updateOf: []const []const u8 = &.{}, whenSql: ?[]const u8 = null, body: []const u8, ifNotExists: bool = false, temporary: bool = false };
/// CREATE VIRTUAL TABLE payload; args are raw token texts.
pub const VirtualTableDef = struct { name: []const u8, module: []const u8, arguments: []const []const u8, ifNotExists: bool = false };
/// One WITH arm; queries kept as source SQL for lazy re-parse by connection.
pub const CteDef = struct { name: []const u8, columns: []const []const u8 = &.{}, querySql: []const u8, recursiveSql: ?[]const u8 = null, recursiveAll: bool = false };
/// WITH [RECURSIVE] wrapper; body kept as source SQL.
pub const WithSelect = struct { ctes: []CteDef, bodySql: []const u8, recursive: bool = false };
/// INSERT OR / UPDATE OR conflict resolution.
pub const ConflictPolicy = enum { none, ignore, replace, update, abort, fail, rollback };
/// Upsert execution outcome (used by the executor, not the parser).
pub const UpsertResult = enum { noConflict, skipped, updated };
/// UPDATE..FROM join descriptor (single equi-join pair fast path).
pub const UpdateFrom = struct { table: []const u8, tableSchema: []const u8 = "", leftTable: []const u8, leftColumn: []const u8, rightTable: []const u8, rightColumn: []const u8 };
/// ALTER TABLE variants supported by the parser.
pub const AlterTable = union(enum) {
    addColumn: struct { table: []const u8, definition: ColumnDef },
    renameTable: struct { table: []const u8, newName: []const u8 },
    renameColumn: struct { table: []const u8, oldName: []const u8, newName: []const u8 },
    dropColumn: struct { table: []const u8, column: []const u8 },
};

/// Compound SELECT operators (`UNION [ALL]` / `INTERSECT` / `EXCEPT`).
pub const CompoundOp = enum { unionOp, unionAllOp, intersectOp, exceptOp };
/// Compound select kept as source slices plus trailing ORDER/LIMIT for lazy execution.
pub const CompoundSelect = struct { leftSql: []const u8, op: CompoundOp, rightSql: []const u8, orders: []const Order = &.{}, limit: ?usize = null, offset: ?usize = null };

/// Top-level statement union produced by `Parser.parse`.
pub const Statement = union(enum) {
    createTable: struct { name: []const u8, columns: []ColumnDef, constraints: []TableConstraint = &.{}, ifNotExists: bool = false, strict: bool = false, withoutRowid: bool = false, temporary: bool = false },
    createIndex: IndexDef,
    createView: struct { name: []const u8, sql: []const u8, ifNotExists: bool = false, temporary: bool = false },
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
    select: struct { projections: []const Projection, table: ?[]const u8, tableAlias: ?[]const u8 = null, fromSubquery: ?[]const u8 = null, joins: []const Join = &.{}, condition: ?Conditions, groupBy: ?[]const u8 = null, having: ?Having = null, orders: []const Order = &.{}, limit: ?usize, offset: ?usize = null, distinct: bool = false },
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
    reindex: struct { target: ?[]const u8 = null },

    /// True for read-like statements (select/with/compound/explain/pragma).
    pub fn isQuery(self: Statement) bool {
        return self == .select or self == .withSelect or self == .compoundSelect or self == .explainQueryPlan or self == .pragma;
    }
};

/// Free an *owned* expression: node structure plus owned strings/blobs/names.
/// Each heap node and owned slice is freed exactly once. Borrowed parser
/// output must use `freeExprRec`/`deinit` instead (they skip string frees).
/// Iterative (explicit work stack), so even pathologically deep caller-built
/// trees free without touching the call stack.
const FreeWork = union(enum) {
    destroy: *const Expr,
    borrowed: *const Expr,
    exprs: []const Expr,
    whens: []const CaseWhen,
    orders: []const OrderItem,
};

pub fn freeOwnedExpr(allocator: std.mem.Allocator, expr: Expr) void {
    var root = expr;
    var stack = std.ArrayList(FreeWork).empty;
    defer stack.deinit(allocator);
    stack.append(allocator, .{ .borrowed = &root }) catch return;
    while (stack.pop()) |work| {
        switch (work) {
            .destroy => |node| {
                freeOwnedExprChildren(allocator, node.*, &stack) catch continue;
                allocator.destroy(node);
            },
            .borrowed => |node| {
                freeOwnedExprChildren(allocator, node.*, &stack) catch continue;
            },
            .exprs => |items| {
                for (items) |*item| stack.append(allocator, .{ .borrowed = item }) catch continue;
                if (items.len != 0) allocator.free(items);
            },
            .whens => |items| {
                for (items) |*item| {
                    stack.append(allocator, .{ .borrowed = &item.result }) catch continue;
                    stack.append(allocator, .{ .borrowed = &item.condition }) catch continue;
                }
                if (items.len != 0) allocator.free(items);
            },
            .orders => |items| {
                for (items) |*item| stack.append(allocator, .{ .borrowed = &item.expr }) catch continue;
                if (items.len != 0) allocator.free(items);
            },
        }
    }
}

/// Single-node visit for the iterative `freeOwnedExpr`: frees the node's own
/// strings and queues child work. Never recurses; OOM while queueing skips
/// the remaining subtree (leaks under OOM only, never crashes).
fn freeOwnedExprChildren(allocator: std.mem.Allocator, expr: Expr, stack: *std.ArrayList(FreeWork)) !void {
    switch (expr) {
        .literal => |lit| switch (lit) {
            .text => |t| allocator.free(t),
            .blob => |b| allocator.free(b),
            else => {},
        },
        .identifier => |id| allocator.free(id),
        .function => |call| {
            allocator.free(call.name);
            try stack.append(allocator, .{ .destroy = call.argument });
            if (call.argument2) |argument| try stack.append(allocator, .{ .destroy = argument });
            if (call.argument3) |argument| try stack.append(allocator, .{ .destroy = argument });
            if (call.extraArgs.len != 0) {
                for (call.extraArgs) |*item| try stack.append(allocator, .{ .borrowed = item });
                try stack.append(allocator, .{ .exprs = call.extraArgs });
            }
            if (call.filter) |filter| try stack.append(allocator, .{ .destroy = filter });
        },
        .binary => |binary| {
            try stack.append(allocator, .{ .destroy = binary.left });
            try stack.append(allocator, .{ .destroy = binary.right });
        },
        .unary => |unary| {
            try stack.append(allocator, .{ .destroy = unary.expr });
        },
        .caseExpr => |caseBlock| {
            if (caseBlock.base) |base| try stack.append(allocator, .{ .destroy = base });
            if (caseBlock.whens.len != 0) {
                for (caseBlock.whens) |*item| {
                    try stack.append(allocator, .{ .borrowed = &item.result });
                    try stack.append(allocator, .{ .borrowed = &item.condition });
                }
                try stack.append(allocator, .{ .whens = caseBlock.whens });
            }
            if (caseBlock.otherwise) |otherwise| try stack.append(allocator, .{ .destroy = otherwise });
        },
        .patternMatch => |match| {
            try stack.append(allocator, .{ .destroy = match.value });
            try stack.append(allocator, .{ .destroy = match.pattern });
            if (match.escape) |escape| try stack.append(allocator, .{ .destroy = escape });
        },
        .collate => |node| {
            allocator.free(node.name);
            try stack.append(allocator, .{ .destroy = node.expr });
        },
        .inSubquery => |inSub| {
            try stack.append(allocator, .{ .destroy = inSub.expr });
            allocator.free(inSub.subquery);
        },
        .inList => |inL| {
            try stack.append(allocator, .{ .destroy = inL.expr });
            if (inL.list.len != 0) {
                for (inL.list) |*item| try stack.append(allocator, .{ .borrowed = item });
                try stack.append(allocator, .{ .exprs = inL.list });
            }
        },
        .scalarSubquery => |sub| allocator.free(sub),
        .existsSubquery => |sub| allocator.free(sub),
        .window => |w| {
            allocator.free(w.funcName);
            if (w.base) |base| allocator.free(base);
            if (w.argument) |arg| try stack.append(allocator, .{ .destroy = arg });
            if (w.argument2) |arg| try stack.append(allocator, .{ .destroy = arg });
            if (w.extraArgs.len != 0) {
                for (w.extraArgs) |*item| try stack.append(allocator, .{ .borrowed = item });
                try stack.append(allocator, .{ .exprs = w.extraArgs });
            }
            if (w.partitionBy.len != 0) {
                for (w.partitionBy) |*item| try stack.append(allocator, .{ .borrowed = item });
                try stack.append(allocator, .{ .exprs = w.partitionBy });
            }
            if (w.orderBy.len != 0) {
                for (w.orderBy) |*item| try stack.append(allocator, .{ .borrowed = &item.expr });
                try stack.append(allocator, .{ .orders = w.orderBy });
            }
            if (w.frame) |fr| {
                if (fr.startOffset) |off| try stack.append(allocator, .{ .destroy = off });
                if (fr.endOffset) |off| try stack.append(allocator, .{ .destroy = off });
            }
            if (w.filter) |filter| try stack.append(allocator, .{ .destroy = filter });
        },
        else => {},
    }
}

/// Deep-clone an expression into fully-owned memory (`OutOfMemory` on failure).
/// On error, partially built output is freed; the input is never consumed.
/// Maximum expression depth accepted by `cloneOwnedExpr`. Parser output
/// never exceeds 200 levels, so legitimate trees always fit; deeper
/// caller-built trees fail closed with `error.TooDeep` instead of
/// overflowing the call stack during the recursive descent. The cap is
/// 400 because Debug Windows frames overflow the default stack near 412
/// recursive `cloneOwnedExprDepth` calls; 400 keeps a margin above the
/// parser's 200 limit while still failing closed on hostile depth.
pub const max_clone_depth: usize = 400;

/// Deep-clone an expression into fully-owned memory (`OutOfMemory` on failure).
/// On error, partially built output is freed; the input is never consumed.
/// Trees deeper than `max_clone_depth` fail with `error.TooDeep`.
pub fn cloneOwnedExpr(allocator: std.mem.Allocator, expr: Expr) !Expr {
    return cloneOwnedExprDepth(allocator, expr, 0);
}

/// Clone one optional heap expression node (`null` stays `null`).
fn cloneOptionalNode(allocator: std.mem.Allocator, node: ?*const Expr, depth: usize) (std.mem.Allocator.Error || error{TooDeep})!?*const Expr {
    const src = node orelse return null;
    const owned = try allocator.create(Expr);
    errdefer allocator.destroy(owned);
    owned.* = try cloneOwnedExprDepth(allocator, src.*, depth + 1);
    return owned;
}

/// Deep-clone a window frame, duplicating any offset expressions.
fn cloneFrame(allocator: std.mem.Allocator, frame: ?WindowFrame, depth: usize) (std.mem.Allocator.Error || error{TooDeep})!?WindowFrame {
    var fr = frame orelse return null;
    fr.startOffset = try cloneOptionalNode(allocator, fr.startOffset, depth);
    errdefer if (fr.startOffset) |n| {
        freeOwnedExpr(allocator, @constCast(n).*);
        allocator.destroy(n);
    };
    fr.endOffset = try cloneOptionalNode(allocator, fr.endOffset, depth);
    return fr;
}

fn cloneOwnedExprDepth(allocator: std.mem.Allocator, expr: Expr, depth: usize) (std.mem.Allocator.Error || error{TooDeep})!Expr {
    if (depth > max_clone_depth) return error.TooDeep;
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
            arg1.* = try cloneOwnedExprDepth(allocator, call.argument.*, depth + 1);
            errdefer freeOwnedExpr(allocator, arg1.*);
            var arg2: ?*const Expr = null;
            if (call.argument2) |a2| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExprDepth(allocator, a2.*, depth + 1);
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
                node.* = try cloneOwnedExprDepth(allocator, a3.*, depth + 1);
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
                    list[idx] = try cloneOwnedExprDepth(allocator, item, depth + 1);
                    count += 1;
                }
                extraArgs = list;
            }
            const filter = try cloneOptionalNode(allocator, call.filter, depth);
            errdefer if (filter) |n| {
                freeOwnedExpr(allocator, @constCast(n).*);
                allocator.destroy(n);
            };
            return .{ .function = .{ .name = ownedName, .argument = arg1, .argument2 = arg2, .argument3 = arg3, .extraArgs = extraArgs, .distinct = call.distinct, .filter = filter } };
        },
        .binary => |bin| {
            const left = try allocator.create(Expr);
            errdefer allocator.destroy(left);
            left.* = try cloneOwnedExprDepth(allocator, bin.left.*, depth + 1);
            errdefer freeOwnedExpr(allocator, left.*);
            const right = try allocator.create(Expr);
            errdefer allocator.destroy(right);
            right.* = try cloneOwnedExprDepth(allocator, bin.right.*, depth + 1);
            return .{ .binary = .{ .op = bin.op, .left = left, .right = right } };
        },
        .unary => |un| {
            const inner = try allocator.create(Expr);
            errdefer allocator.destroy(inner);
            inner.* = try cloneOwnedExprDepth(allocator, un.expr.*, depth + 1);
            return .{ .unary = .{ .op = un.op, .expr = inner } };
        },
        .collate => |col| {
            const ownedName = try allocator.dupe(u8, col.name);
            errdefer allocator.free(ownedName);
            const inner = try allocator.create(Expr);
            errdefer allocator.destroy(inner);
            inner.* = try cloneOwnedExprDepth(allocator, col.expr.*, depth + 1);
            return .{ .collate = .{ .name = ownedName, .expr = inner } };
        },
        .caseExpr => |cs| {
            var baseNode: ?*const Expr = null;
            if (cs.base) |b| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExprDepth(allocator, b.*, depth + 1);
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
                    .condition = try cloneOwnedExprDepth(allocator, w.condition, depth + 1),
                    .result = try cloneOwnedExprDepth(allocator, w.result, depth + 1),
                };
                whensCount += 1;
            }
            var otherwiseNode: ?*const Expr = null;
            if (cs.otherwise) |o| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExprDepth(allocator, o.*, depth + 1);
                otherwiseNode = node;
            }
            return .{ .caseExpr = .{ .base = baseNode, .whens = whens, .otherwise = otherwiseNode } };
        },
        .patternMatch => |pm| {
            const val = try allocator.create(Expr);
            errdefer allocator.destroy(val);
            val.* = try cloneOwnedExprDepth(allocator, pm.value.*, depth + 1);
            errdefer freeOwnedExpr(allocator, val.*);
            const pat = try allocator.create(Expr);
            errdefer allocator.destroy(pat);
            pat.* = try cloneOwnedExprDepth(allocator, pm.pattern.*, depth + 1);
            errdefer freeOwnedExpr(allocator, pat.*);
            var esc: ?*const Expr = null;
            if (pm.escape) |e| {
                const node = try allocator.create(Expr);
                errdefer allocator.destroy(node);
                node.* = try cloneOwnedExprDepth(allocator, e.*, depth + 1);
                esc = node;
            }
            return .{ .patternMatch = .{ .value = val, .pattern = pat, .escape = esc, .negated = pm.negated, .glob = pm.glob, .isRegexp = pm.isRegexp, .isMatch = pm.isMatch } };
        },
        .inList => |il| {
            const target = try allocator.create(Expr);
            errdefer allocator.destroy(target);
            target.* = try cloneOwnedExprDepth(allocator, il.expr.*, depth + 1);
            errdefer freeOwnedExpr(allocator, target.*);
            const list = try allocator.alloc(Expr, il.list.len);
            var listCount: usize = 0;
            errdefer {
                for (list[0..listCount]) |item| freeOwnedExpr(allocator, item);
                allocator.free(list);
            }
            for (il.list, 0..) |item, idx| {
                list[idx] = try cloneOwnedExprDepth(allocator, item, depth + 1);
                listCount += 1;
            }
            return .{ .inList = .{ .expr = target, .list = list, .negated = il.negated } };
        },
        .inSubquery => |is| {
            const target = try allocator.create(Expr);
            errdefer allocator.destroy(target);
            target.* = try cloneOwnedExprDepth(allocator, is.expr.*, depth + 1);
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
                node.* = try cloneOwnedExprDepth(allocator, a1.*, depth + 1);
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
                node.* = try cloneOwnedExprDepth(allocator, a2.*, depth + 1);
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
                    list[idx] = try cloneOwnedExprDepth(allocator, item, depth + 1);
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
                    list[idx] = try cloneOwnedExprDepth(allocator, item, depth + 1);
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
                        .expr = try cloneOwnedExprDepth(allocator, item.expr, depth + 1),
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
                .frame = try cloneFrame(allocator, w.frame, depth),
                .filter = try cloneOptionalNode(allocator, w.filter, depth),
                .distinct = w.distinct,
                .base = if (w.base) |b| try allocator.dupe(u8, b) else null,
            } };
        },
    }
}

/// Free parser-arena expression node structure without freeing borrowed strings.
/// Pair with `Parser.allocations` cleanup which owns the string memory.
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
            if (call.filter) |filter| {
                freeExprRec(gpa, filter.*);
                gpa.destroy(filter);
            }
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
            if (w.frame) |fr| {
                if (fr.startOffset) |off| {
                    freeExprRec(gpa, off.*);
                    gpa.destroy(off);
                }
                if (fr.endOffset) |off| {
                    freeExprRec(gpa, off.*);
                    gpa.destroy(off);
                }
            }
            if (w.filter) |filter| {
                freeExprRec(gpa, filter.*);
                gpa.destroy(filter);
            }
        },
        else => {},
    }
}

/// Free a borrowed condition list and its node structure (strings stay arena-owned).
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

/// Free a whole parser-produced statement (node structure; strings via `Parser.deinit`).
/// Must be called exactly once per successful `Parser.parse`.
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
        .compoundSelect => |value| {
            if (value.orders.len != 0) allocator.free(value.orders);
        },
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
            if (value.having) |items| {
                for (items) |item| {
                    freeExpr(allocator, item.left);
                    freeExpr(allocator, item.right);
                }
                allocator.free(items);
            }
            if (value.orders.len != 0) allocator.free(value.orders);
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

test "ast clone/free round-trips owned expressions" {
    const alloc = std.testing.allocator;
    const l = try alloc.create(Expr);
    defer alloc.destroy(l);
    l.* = .{ .literal = .{ .integer = 1 } };
    const r = try alloc.create(Expr);
    defer alloc.destroy(r);
    r.* = .{ .literal = .{ .integer = 2 } };
    const src: Expr = .{ .binary = .{ .op = .add, .left = l, .right = r } };
    const owned = try cloneOwnedExpr(alloc, src);
    freeOwnedExpr(alloc, owned);
}

test "ast frees deep trees iteratively and refuses to clone them" {
    // 10k-deep left-leaning chain: freeing must not touch the call stack
    // (iterative work list), while cloning fails closed past the cap.
    const alloc = std.testing.allocator;
    var root: Expr = .{ .literal = .{ .integer = 0 } };
    var depth: usize = 0;
    while (depth < 10000) : (depth += 1) {
        const left = try alloc.create(Expr);
        left.* = root;
        errdefer {
            freeOwnedExpr(alloc, left.*);
            alloc.destroy(left);
        }
        const one = try alloc.create(Expr);
        one.* = .{ .literal = .{ .integer = 1 } };
        errdefer alloc.destroy(one);
        root = .{ .binary = .{ .op = .add, .left = left, .right = one } };
    }
    try std.testing.expectError(error.TooDeep, cloneOwnedExpr(alloc, root));
    freeOwnedExpr(alloc, root);
}

test "ast isQuery covers read-like statements only" {
    try std.testing.expect((Statement{ .begin = {} }).isQuery() == false);
    try std.testing.expect((Statement{ .pragma = .{ .name = "x" } }).isQuery());
}
