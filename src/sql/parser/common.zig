//! Shared parser support: error set, limits, window-spec types, AST
//! copy/free helpers, named-window resolution, and pure grammar classifiers.
//!
//! Responsibility: own everything the recursive-descent grammar in
//! `../parser.zig` needs that does not itself parse tokens. `Parser`-bound
//! helpers take a generic `parser: anytype` (the `Parser` struct with its
//! `allocator`, `copy`, and `allocations`) so this module never imports
//! `parser.zig` and no import cycle forms; grammar behavior stays identical
//! vs `sqlite/src/parse.y` plus `tokenize.c`.
//!
//! Dependencies: `sql/ast.zig` for node types, `sql/lexer.zig` for the error
//! union, `sql/functions.zig` (via `../functions.zig`) for the single
//! aggregate/window registry. Lifetime: copies retain strings in the
//! parser's allocation list (freed by `Parser.deinit`); `freeParserExpr`
//! releases node structure only. Errors: `InvalidSql`/`UnexpectedToken` for
//! bad window references, `OutOfMemory` for copies.

const std = @import("std");
const ast = @import("../ast.zig");
const lexer = @import("../lexer.zig");

/// Parser failure modes: grammar errors plus unioned lexer/allocator errors.
pub const Error = error{ InvalidSql, UnexpectedToken, OutOfMemory, Unsupported, TooDeep } || std.mem.Allocator.Error || lexer.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError;

/// Maximum nesting depth for expressions/subqueries; hostile input fails closed.
pub const max_parse_depth: usize = 200;

/// Window spec with an optional base-window name (`OVER w` keeps the
/// name; `OVER (w ...)` merges the overlay onto the named base).
/// Returned slices are parser-owned; resolution copies them per use.
pub const WindowSpec = struct { base: ?[]const u8 = null, partitionBy: []const ast.Expr = &.{}, orderBy: []const ast.OrderItem = &.{}, frame: ?ast.WindowFrame = null };

/// One `WINDOW name AS (spec)` definition pending resolution.
pub const NamedWindowDef = struct { name: []const u8, spec: WindowSpec };

/// Parses `[NOT] DEFERRABLE [INITIALLY DEFERRED|IMMEDIATE]` after a
/// REFERENCES clause. Bare `DEFERRABLE` means initially deferred;
/// `NOT DEFERRABLE INITIALLY DEFERRED` and a lone `INITIALLY` fail.
/// Peeks before consuming: a bare `NOT` may start a following column
/// constraint (`REFERENCES t(c) NOT NULL`), which is left untouched.
pub const DeferralClause = struct { deferrable: bool = false, initiallyDeferred: bool = false };

pub const BoundResult = struct {
    bound: ast.WindowFrameBound,
    offset: ?*const ast.Expr = null,
};

pub fn freeParserExpr(allocator: std.mem.Allocator, expr: ast.Expr) void {
    switch (expr) {
        .function => |call| {
            freeParserExpr(allocator, call.argument.*);
            allocator.destroy(call.argument);
            if (call.argument2) |argument| {
                freeParserExpr(allocator, argument.*);
                allocator.destroy(argument);
            }
            if (call.argument3) |argument| {
                freeParserExpr(allocator, argument.*);
                allocator.destroy(argument);
            }
            for (call.extraArgs) |argument| {
                freeParserExpr(allocator, argument);
            }
            if (call.extraArgs.len != 0) allocator.free(call.extraArgs);
            if (call.filter) |filter| {
                freeParserExpr(allocator, filter.*);
                allocator.destroy(filter);
            }
        },
        .binary => |binary| {
            freeParserExpr(allocator, binary.left.*);
            freeParserExpr(allocator, binary.right.*);
            allocator.destroy(binary.left);
            allocator.destroy(binary.right);
        },
        .unary => |unary| {
            freeParserExpr(allocator, unary.expr.*);
            allocator.destroy(unary.expr);
        },
        .caseExpr => |caseBlock| {
            if (caseBlock.base) |base| {
                freeParserExpr(allocator, base.*);
                allocator.destroy(base);
            }
            for (caseBlock.whens) |when| {
                freeParserExpr(allocator, when.condition);
                freeParserExpr(allocator, when.result);
            }
            allocator.free(caseBlock.whens);
            if (caseBlock.otherwise) |otherwise| {
                freeParserExpr(allocator, otherwise.*);
                allocator.destroy(otherwise);
            }
        },
        .patternMatch => |match| {
            freeParserExpr(allocator, match.value.*);
            allocator.destroy(match.value);
            freeParserExpr(allocator, match.pattern.*);
            allocator.destroy(match.pattern);
            if (match.escape) |escape| {
                freeParserExpr(allocator, escape.*);
                allocator.destroy(escape);
            }
        },
        .collate => |node| {
            freeParserExpr(allocator, node.expr.*);
            allocator.destroy(node.expr);
        },
        .inSubquery => |inSub| {
            freeParserExpr(allocator, inSub.expr.*);
            allocator.destroy(inSub.expr);
        },
        .inList => |inL| {
            freeParserExpr(allocator, inL.expr.*);
            allocator.destroy(inL.expr);
            for (inL.list) |item| freeParserExpr(allocator, item);
            if (inL.list.len != 0) allocator.free(inL.list);
        },
        .window => |w| {
            if (w.argument) |arg| {
                freeParserExpr(allocator, arg.*);
                allocator.destroy(arg);
            }
            if (w.argument2) |arg| {
                freeParserExpr(allocator, arg.*);
                allocator.destroy(arg);
            }
            for (w.extraArgs) |arg| {
                freeParserExpr(allocator, arg);
            }
            if (w.extraArgs.len != 0) allocator.free(w.extraArgs);
            for (w.partitionBy) |item| freeParserExpr(allocator, item);
            if (w.partitionBy.len != 0) allocator.free(w.partitionBy);
            for (w.orderBy) |item| freeParserExpr(allocator, item.expr);
            if (w.orderBy.len != 0) allocator.free(w.orderBy);
            if (w.frame) |fr| {
                if (fr.startOffset) |off| {
                    freeParserExpr(allocator, off.*);
                    allocator.destroy(off);
                }
                if (fr.endOffset) |off| {
                    freeParserExpr(allocator, off.*);
                    allocator.destroy(off);
                }
            }
            if (w.filter) |filter| {
                freeParserExpr(allocator, filter.*);
                allocator.destroy(filter);
            }
        },
        else => {},
    }
}

/// Deep-copy one parser-arena expression (nodes via `create`, strings via
/// `copy` so `Parser.deinit` still owns everything). Used to expand a named
/// window spec into each `OVER` use; every use owns its copy, so later
/// `freeParserExpr`/`ast.deinit` calls never double-free shared nodes.
pub fn copyParserExpr(parser: anytype, expr: ast.Expr) std.mem.Allocator.Error!ast.Expr {
    return switch (expr) {
        .literal => |lit| .{ .literal = switch (lit) {
            .text => |t| .{ .text = try parser.copy(t) },
            .blob => |b| blk: {
                const owned = try parser.allocator.alloc(u8, b.len);
                errdefer parser.allocator.free(owned);
                @memcpy(owned, b);
                try parser.allocations.append(parser.allocator, owned);
                break :blk .{ .blob = owned };
            },
            else => lit,
        } },
        .identifier => |id| .{ .identifier = try parser.copy(id) },
        .parameter => |p| .{ .parameter = p },
        .wildcard => .wildcard,
        .function => |call| {
            const argument = try parser.allocator.create(ast.Expr);
            errdefer parser.allocator.destroy(argument);
            argument.* = try copyParserExpr(parser, call.argument.*);
            errdefer freeParserExpr(parser.allocator, argument.*);
            var argument2: ?*const ast.Expr = null;
            if (call.argument2) |a2| {
                const node = try parser.allocator.create(ast.Expr);
                errdefer parser.allocator.destroy(node);
                node.* = try copyParserExpr(parser, a2.*);
                argument2 = node;
            }
            errdefer if (argument2) |n| {
                freeParserExpr(parser.allocator, n.*);
                parser.allocator.destroy(n);
            };
            var argument3: ?*const ast.Expr = null;
            if (call.argument3) |a3| {
                const node = try parser.allocator.create(ast.Expr);
                errdefer parser.allocator.destroy(node);
                node.* = try copyParserExpr(parser, a3.*);
                argument3 = node;
            }
            errdefer if (argument3) |n| {
                freeParserExpr(parser.allocator, n.*);
                parser.allocator.destroy(n);
            };
            var extraArgs: []ast.Expr = &.{};
            if (call.extraArgs.len != 0) {
                const list = try parser.allocator.alloc(ast.Expr, call.extraArgs.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeParserExpr(parser.allocator, item);
                    parser.allocator.free(list);
                }
                for (call.extraArgs, 0..) |item, idx| {
                    list[idx] = try copyParserExpr(parser, item);
                    count += 1;
                }
                extraArgs = list;
            }
            const filter = try copyOptionalParserExpr(parser, call.filter);
            errdefer if (filter) |n| {
                freeParserExpr(parser.allocator, n.*);
                parser.allocator.destroy(n);
            };
            return .{ .function = .{ .name = try parser.copy(call.name), .argument = argument, .argument2 = argument2, .argument3 = argument3, .extraArgs = extraArgs, .distinct = call.distinct, .filter = filter } };
        },
        .binary => |bin| {
            const left = try parser.allocator.create(ast.Expr);
            errdefer parser.allocator.destroy(left);
            left.* = try copyParserExpr(parser, bin.left.*);
            errdefer freeParserExpr(parser.allocator, left.*);
            const right = try parser.allocator.create(ast.Expr);
            errdefer parser.allocator.destroy(right);
            right.* = try copyParserExpr(parser, bin.right.*);
            return .{ .binary = .{ .op = bin.op, .left = left, .right = right } };
        },
        .unary => |un| {
            const inner = try parser.allocator.create(ast.Expr);
            errdefer parser.allocator.destroy(inner);
            inner.* = try copyParserExpr(parser, un.expr.*);
            return .{ .unary = .{ .op = un.op, .expr = inner } };
        },
        .caseExpr => |caseBlock| {
            var base: ?*const ast.Expr = null;
            if (caseBlock.base) |b| {
                const node = try parser.allocator.create(ast.Expr);
                errdefer parser.allocator.destroy(node);
                node.* = try copyParserExpr(parser, b.*);
                base = node;
            }
            errdefer if (base) |n| {
                freeParserExpr(parser.allocator, n.*);
                parser.allocator.destroy(n);
            };
            var whens: []ast.CaseWhen = &.{};
            if (caseBlock.whens.len != 0) {
                const list = try parser.allocator.alloc(ast.CaseWhen, caseBlock.whens.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| {
                        freeParserExpr(parser.allocator, item.condition);
                        freeParserExpr(parser.allocator, item.result);
                    }
                    parser.allocator.free(list);
                }
                for (caseBlock.whens, 0..) |item, idx| {
                    list[idx] = .{ .condition = try copyParserExpr(parser, item.condition), .result = try copyParserExpr(parser, item.result) };
                    count += 1;
                }
                whens = list;
            }
            const otherwise = try copyOptionalParserExpr(parser, caseBlock.otherwise);
            return .{ .caseExpr = .{ .base = base, .whens = whens, .otherwise = otherwise } };
        },
        .patternMatch => |match| {
            const value = try parser.allocator.create(ast.Expr);
            errdefer parser.allocator.destroy(value);
            value.* = try copyParserExpr(parser, match.value.*);
            errdefer freeParserExpr(parser.allocator, value.*);
            const pattern = try parser.allocator.create(ast.Expr);
            errdefer parser.allocator.destroy(pattern);
            pattern.* = try copyParserExpr(parser, match.pattern.*);
            const escape = try copyOptionalParserExpr(parser, match.escape);
            return .{ .patternMatch = .{ .value = value, .pattern = pattern, .escape = escape, .negated = match.negated, .glob = match.glob, .isRegexp = match.isRegexp, .isMatch = match.isMatch } };
        },
        .collate => |node| {
            const inner = try parser.allocator.create(ast.Expr);
            errdefer parser.allocator.destroy(inner);
            inner.* = try copyParserExpr(parser, node.expr.*);
            return .{ .collate = .{ .expr = inner, .name = try parser.copy(node.name) } };
        },
        .scalarSubquery => |sub| .{ .scalarSubquery = try parser.copy(sub) },
        .existsSubquery => |sub| .{ .existsSubquery = try parser.copy(sub) },
        .inSubquery => |inSub| {
            const target = try parser.allocator.create(ast.Expr);
            errdefer parser.allocator.destroy(target);
            target.* = try copyParserExpr(parser, inSub.expr.*);
            return .{ .inSubquery = .{ .expr = target, .subquery = try parser.copy(inSub.subquery), .negated = inSub.negated } };
        },
        .inList => |inL| {
            const target = try parser.allocator.create(ast.Expr);
            errdefer parser.allocator.destroy(target);
            target.* = try copyParserExpr(parser, inL.expr.*);
            errdefer freeParserExpr(parser.allocator, target.*);
            var list: []ast.Expr = &.{};
            if (inL.list.len != 0) {
                const owned = try parser.allocator.alloc(ast.Expr, inL.list.len);
                var count: usize = 0;
                errdefer {
                    for (owned[0..count]) |item| freeParserExpr(parser.allocator, item);
                    parser.allocator.free(owned);
                }
                for (inL.list, 0..) |item, idx| {
                    owned[idx] = try copyParserExpr(parser, item);
                    count += 1;
                }
                list = owned;
            }
            return .{ .inList = .{ .expr = target, .list = list, .negated = inL.negated } };
        },
        .window => |w| {
            const argument = try copyOptionalParserExpr(parser, w.argument);
            errdefer if (argument) |n| {
                freeParserExpr(parser.allocator, n.*);
                parser.allocator.destroy(n);
            };
            const argument2 = try copyOptionalParserExpr(parser, w.argument2);
            errdefer if (argument2) |n| {
                freeParserExpr(parser.allocator, n.*);
                parser.allocator.destroy(n);
            };
            var extraArgs: []ast.Expr = &.{};
            if (w.extraArgs.len != 0) {
                const list = try parser.allocator.alloc(ast.Expr, w.extraArgs.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeParserExpr(parser.allocator, item);
                    parser.allocator.free(list);
                }
                for (w.extraArgs, 0..) |item, idx| {
                    list[idx] = try copyParserExpr(parser, item);
                    count += 1;
                }
                extraArgs = list;
            }
            var parts: []ast.Expr = &.{};
            if (w.partitionBy.len != 0) {
                const list = try parser.allocator.alloc(ast.Expr, w.partitionBy.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeParserExpr(parser.allocator, item);
                    parser.allocator.free(list);
                }
                for (w.partitionBy, 0..) |item, idx| {
                    list[idx] = try copyParserExpr(parser, item);
                    count += 1;
                }
                parts = list;
            }
            var orders: []ast.OrderItem = &.{};
            if (w.orderBy.len != 0) {
                const list = try parser.allocator.alloc(ast.OrderItem, w.orderBy.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeParserExpr(parser.allocator, item.expr);
                    parser.allocator.free(list);
                }
                for (w.orderBy, 0..) |item, idx| {
                    list[idx] = .{ .expr = try copyParserExpr(parser, item.expr), .descending = item.descending, .nullsFirst = item.nullsFirst };
                    count += 1;
                }
                orders = list;
            }
            const frame = try copyParserFrame(parser, w.frame);
            errdefer if (frame) |fr| freeParserFrame(parser, fr);
            const filter = try copyOptionalParserExpr(parser, w.filter);
            const base = if (w.base) |b| try parser.copy(b) else null;
            return .{ .window = .{ .funcName = try parser.copy(w.funcName), .argument = argument, .argument2 = argument2, .extraArgs = extraArgs, .partitionBy = parts, .orderBy = orders, .frame = frame, .filter = filter, .distinct = w.distinct, .base = base } };
        },
    };
}

/// Copy one optional heap expression node for `copyParserExpr`.
pub fn copyOptionalParserExpr(parser: anytype, node: ?*const ast.Expr) std.mem.Allocator.Error!?*const ast.Expr {
    const src = node orelse return null;
    const owned = try parser.allocator.create(ast.Expr);
    errdefer parser.allocator.destroy(owned);
    owned.* = try copyParserExpr(parser, src.*);
    return owned;
}

/// Deep-copy a window frame (offset expressions included) for named-window expansion.
pub fn copyParserFrame(parser: anytype, frame: ?ast.WindowFrame) std.mem.Allocator.Error!?ast.WindowFrame {
    var fr = frame orelse return null;
    fr.startOffset = try copyOptionalParserExpr(parser, fr.startOffset);
    errdefer if (fr.startOffset) |n| {
        freeParserExpr(parser.allocator, n.*);
        parser.allocator.destroy(n);
    };
    fr.endOffset = try copyOptionalParserExpr(parser, fr.endOffset);
    return fr;
}

/// Free one parser-arena window frame's offset structure (strings stay arena-owned).
pub fn freeParserFrame(parser: anytype, frame: ast.WindowFrame) void {
    if (frame.startOffset) |off| {
        freeParserExpr(parser.allocator, off.*);
        parser.allocator.destroy(off);
    }
    if (frame.endOffset) |off| {
        freeParserExpr(parser.allocator, off.*);
        parser.allocator.destroy(off);
    }
}

/// Free one parsed window spec's node structure (strings stay arena-owned).
pub fn freeWindowSpec(parser: anytype, spec: WindowSpec) void {
    for (spec.partitionBy) |item| freeParserExpr(parser.allocator, item);
    if (spec.partitionBy.len != 0) parser.allocator.free(spec.partitionBy);
    for (spec.orderBy) |item| freeParserExpr(parser.allocator, item.expr);
    if (spec.orderBy.len != 0) parser.allocator.free(spec.orderBy);
    if (spec.frame) |fr| freeParserFrame(parser, fr);
}

/// Find a WINDOW-clause definition by name (case-insensitive).
pub fn findNamedWindow(defs: []const NamedWindowDef, name: []const u8) ?WindowSpec {
    for (defs) |def| if (std.ascii.eqlIgnoreCase(def.name, name)) return def.spec;
    return null;
}

/// Merge an OVER overlay onto a named base spec. Overlay slices are
/// adopted (caller surrenders them); base parts are deep-copied so the
/// stored definition stays intact for other uses. An overlay PARTITION
/// is always InvalidSql; overlay ORDER BY or frame is InvalidSql when
/// the base already sets the same clause, matching the reference
/// ("cannot override ... of window").
pub fn resolveWindowBase(parser: anytype, overlay: WindowSpec, base: WindowSpec) !WindowSpec {
    if (overlay.partitionBy.len != 0) return Error.InvalidSql;
    if (overlay.orderBy.len != 0 and base.orderBy.len != 0) return Error.InvalidSql;
    if (overlay.frame != null and base.frame != null) return Error.InvalidSql;
    var baseParts: []ast.Expr = &.{};
    var baseOrders: []ast.OrderItem = &.{};
    var baseFrame: ?ast.WindowFrame = null;
    errdefer freeWindowSpec(parser, .{ .partitionBy = baseParts, .orderBy = baseOrders, .frame = baseFrame });
    if (overlay.partitionBy.len == 0 and base.partitionBy.len != 0) {
        const list = try parser.allocator.alloc(ast.Expr, base.partitionBy.len);
        var count: usize = 0;
        errdefer {
            for (list[0..count]) |item| freeParserExpr(parser.allocator, item);
            parser.allocator.free(list);
        }
        for (base.partitionBy, 0..) |item, idx| {
            list[idx] = try copyParserExpr(parser, item);
            count += 1;
        }
        baseParts = list;
    }
    if (overlay.orderBy.len == 0 and base.orderBy.len != 0) {
        const list = try parser.allocator.alloc(ast.OrderItem, base.orderBy.len);
        var count: usize = 0;
        errdefer {
            for (list[0..count]) |item| freeParserExpr(parser.allocator, item.expr);
            parser.allocator.free(list);
        }
        for (base.orderBy, 0..) |item, idx| {
            list[idx] = .{ .expr = try copyParserExpr(parser, item.expr), .descending = item.descending, .nullsFirst = item.nullsFirst };
            count += 1;
        }
        baseOrders = list;
    }
    if (overlay.frame == null) baseFrame = try copyParserFrame(parser, base.frame);
    return .{
        .partitionBy = if (overlay.partitionBy.len != 0) overlay.partitionBy else baseParts,
        .orderBy = if (overlay.orderBy.len != 0) overlay.orderBy else baseOrders,
        .frame = overlay.frame orelse baseFrame,
    };
}

/// Resolve every `OVER name` use inside one expression against the
/// SELECT's WINDOW clause. The parser owns the whole tree, so mutation
/// through const children is sound (single owner, pre-publication).
pub fn resolveWindowRefs(parser: anytype, expr: *ast.Expr, defs: []const NamedWindowDef) !void {
    switch (expr.*) {
        .function => |*call| {
            try resolveWindowRefs(parser, @constCast(call.argument), defs);
            if (call.argument2) |a2| try resolveWindowRefs(parser, @constCast(a2), defs);
            if (call.argument3) |a3| try resolveWindowRefs(parser, @constCast(a3), defs);
            for (0..call.extraArgs.len) |idx| try resolveWindowRefs(parser, @constCast(&call.extraArgs[idx]), defs);
            if (call.filter) |f| try resolveWindowRefs(parser, @constCast(f), defs);
        },
        .binary => |*bin| {
            try resolveWindowRefs(parser, @constCast(bin.left), defs);
            try resolveWindowRefs(parser, @constCast(bin.right), defs);
        },
        .unary => |*un| try resolveWindowRefs(parser, @constCast(un.expr), defs),
        .caseExpr => |*caseBlock| {
            if (caseBlock.base) |b| try resolveWindowRefs(parser, @constCast(b), defs);
            for (caseBlock.whens) |*item| {
                try resolveWindowRefs(parser, &item.condition, defs);
                try resolveWindowRefs(parser, &item.result, defs);
            }
            if (caseBlock.otherwise) |o| try resolveWindowRefs(parser, @constCast(o), defs);
        },
        .patternMatch => |*match| {
            try resolveWindowRefs(parser, @constCast(match.value), defs);
            try resolveWindowRefs(parser, @constCast(match.pattern), defs);
            if (match.escape) |e| try resolveWindowRefs(parser, @constCast(e), defs);
        },
        .collate => |*node| try resolveWindowRefs(parser, @constCast(node.expr), defs),
        .inSubquery => |*inSub| try resolveWindowRefs(parser, @constCast(inSub.expr), defs),
        .inList => |*inL| {
            try resolveWindowRefs(parser, @constCast(inL.expr), defs);
            for (0..inL.list.len) |idx| try resolveWindowRefs(parser, @constCast(&inL.list[idx]), defs);
        },
        .window => |*w| {
            if (w.argument) |a| try resolveWindowRefs(parser, @constCast(a), defs);
            if (w.argument2) |a2| try resolveWindowRefs(parser, @constCast(a2), defs);
            for (0..w.extraArgs.len) |idx| try resolveWindowRefs(parser, @constCast(&w.extraArgs[idx]), defs);
            for (0..w.partitionBy.len) |idx| try resolveWindowRefs(parser, @constCast(&w.partitionBy[idx]), defs);
            for (0..w.orderBy.len) |idx| try resolveWindowRefs(parser, @constCast(&w.orderBy[idx].expr), defs);
            if (w.filter) |f| try resolveWindowRefs(parser, @constCast(f), defs);
            const baseName = w.base orelse return;
            const base = findNamedWindow(defs, baseName) orelse return Error.InvalidSql;
            const overlay = WindowSpec{ .partitionBy = w.partitionBy, .orderBy = w.orderBy, .frame = w.frame };
            const merged = try resolveWindowBase(parser, overlay, base);
            w.partitionBy = merged.partitionBy;
            w.orderBy = merged.orderBy;
            w.frame = merged.frame;
            w.base = null;
        },
        else => {},
    }
}

/// Resolve named-window uses inside a WHERE condition list.
pub fn resolveWindowRefsInConditions(parser: anytype, conditions: []const ast.Condition, defs: []const NamedWindowDef) !void {
    for (0..conditions.len) |idx| {
        const mutable: *ast.Condition = @constCast(&conditions[idx]);
        if (mutable.leftExpr) |*left| try resolveWindowRefs(parser, left, defs);
        try resolveWindowRefs(parser, &mutable.value, defs);
        if (mutable.value2) |*second| try resolveWindowRefs(parser, second, defs);
        if (mutable.escape) |*escape| try resolveWindowRefs(parser, escape, defs);
        for (0..mutable.listValues.len) |itemIdx| try resolveWindowRefs(parser, @constCast(&mutable.listValues[itemIdx]), defs);
    }
}

/// Aggregate/window names that may carry OVER or DISTINCT; delegates to
/// the single function registry so parser, evaluator, and DSL cannot drift.
pub fn isAggregateName(name: []const u8) bool {
    const functions = @import("../functions.zig");
    if (functions.aggregate.AggKind.fromName(name) != null) return true;
    return std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max");
}

/// Window-only function names (rank, lag, ...); with `isAggregateName`
/// this covers every name that may carry OVER.
pub fn isWindowOnlyName(name: []const u8) bool {
    return @import("../functions.zig").isWindowOnly(name);
}

pub fn isTypeNameStop(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "primary") or std.ascii.eqlIgnoreCase(text, "foreign") or std.ascii.eqlIgnoreCase(text, "not") or std.ascii.eqlIgnoreCase(text, "unique") or std.ascii.eqlIgnoreCase(text, "autoincrement") or std.ascii.eqlIgnoreCase(text, "check") or std.ascii.eqlIgnoreCase(text, "default") or std.ascii.eqlIgnoreCase(text, "generated") or std.ascii.eqlIgnoreCase(text, "as") or std.ascii.eqlIgnoreCase(text, "references") or std.ascii.eqlIgnoreCase(text, "collate") or std.ascii.eqlIgnoreCase(text, "constraint");
}

pub fn isReservedQueryKeyword(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "where") or
        std.ascii.eqlIgnoreCase(text, "group") or
        std.ascii.eqlIgnoreCase(text, "having") or
        std.ascii.eqlIgnoreCase(text, "order") or
        std.ascii.eqlIgnoreCase(text, "limit") or
        std.ascii.eqlIgnoreCase(text, "offset") or
        std.ascii.eqlIgnoreCase(text, "inner") or
        std.ascii.eqlIgnoreCase(text, "left") or
        std.ascii.eqlIgnoreCase(text, "right") or
        std.ascii.eqlIgnoreCase(text, "full") or
        std.ascii.eqlIgnoreCase(text, "cross") or
        std.ascii.eqlIgnoreCase(text, "join") or
        std.ascii.eqlIgnoreCase(text, "natural") or
        std.ascii.eqlIgnoreCase(text, "union") or
        std.ascii.eqlIgnoreCase(text, "intersect") or
        std.ascii.eqlIgnoreCase(text, "except") or
        std.ascii.eqlIgnoreCase(text, "on") or
        std.ascii.eqlIgnoreCase(text, "using") or
        std.ascii.eqlIgnoreCase(text, "returning") or
        std.ascii.eqlIgnoreCase(text, "window");
}

pub fn isMinIntMagnitude(text: []const u8) bool {
    var digits = text;
    while (digits.len != 0 and digits[0] == '0') digits = digits[1..];
    if (digits.len == 0) return false;
    if (digits.len != 19) return false;
    return std.mem.eql(u8, digits, "9223372036854775808");
}

pub fn asParserError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnexpectedToken => Error.UnexpectedToken,
        else => Error.InvalidSql,
    };
}

test "aggregate and window-only names follow the function registry" {
    try std.testing.expect(isAggregateName("count"));
    try std.testing.expect(isAggregateName("sum"));
    try std.testing.expect(isAggregateName("min"));
    try std.testing.expect(isAggregateName("MAX"));
    try std.testing.expect(isWindowOnlyName("row_number"));
    try std.testing.expect(isWindowOnlyName("lag"));
    try std.testing.expect(!isWindowOnlyName("count"));
    try std.testing.expect(!isAggregateName("row_number"));
    try std.testing.expect(!isAggregateName("nosuchfn"));
}

test "type-name stops and query keywords classify grammar words" {
    try std.testing.expect(isTypeNameStop("primary"));
    try std.testing.expect(isTypeNameStop("CONSTRAINT"));
    try std.testing.expect(!isTypeNameStop("varchar"));
    try std.testing.expect(isReservedQueryKeyword("where"));
    try std.testing.expect(isReservedQueryKeyword("WINDOW"));
    try std.testing.expect(!isReservedQueryKeyword("users"));
}

test "min-int magnitude detects exactly 9223372036854775808" {
    try std.testing.expect(isMinIntMagnitude("9223372036854775808"));
    try std.testing.expect(isMinIntMagnitude("0009223372036854775808"));
    try std.testing.expect(!isMinIntMagnitude("9223372036854775807"));
    try std.testing.expect(!isMinIntMagnitude("0"));
    try std.testing.expect(!isMinIntMagnitude(""));
}

test "asParserError preserves oom and token errors, closes the rest" {
    try std.testing.expectEqual(Error.OutOfMemory, asParserError(error.OutOfMemory));
    try std.testing.expectEqual(Error.UnexpectedToken, asParserError(error.UnexpectedToken));
    try std.testing.expectEqual(Error.InvalidSql, asParserError(error.SomeRandomFailure));
}

test "findNamedWindow matches case-insensitively" {
    const defs = [_]NamedWindowDef{
        .{ .name = "w", .spec = .{} },
    };
    try std.testing.expect(findNamedWindow(&defs, "W") != null);
    try std.testing.expect(findNamedWindow(&defs, "other") == null);
}

test "freeParserExpr releases a nested tree without leaking nodes" {
    const alloc = std.testing.allocator;
    const left = try alloc.create(ast.Expr);
    left.* = .{ .literal = .{ .integer = 1 } };
    const right = try alloc.create(ast.Expr);
    right.* = .{ .literal = .{ .integer = 2 } };
    freeParserExpr(alloc, .{ .binary = .{ .op = .add, .left = left, .right = right } });
}
