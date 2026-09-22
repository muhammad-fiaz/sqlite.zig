//! SQL parser: tokens -> owned statements.
//!
//! Recursive-descent frontend; the only SQL-string entry point (DSLs build
//! AST nodes directly). Parses one statement plus optional `;`, keeps
//! source slices for lazily re-parsed bodies, and fails closed — never a
//! partial AST. Callers free the statement with `ast.deinit`, then the
//! parser with `Parser.deinit`. Budgets from `limits.zig` fail `SqlTooBig`;
//! nesting depth is capped so hostile input cannot overflow the stack.

const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;
const lexer = @import("lexer.zig");
const limits = @import("limits.zig");
const ast = @import("ast.zig");
const Value = @import("../vm/value.zig").Value;

fn freeParserExpr(allocator: std.mem.Allocator, expr: ast.Expr) void {
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
fn copyParserExpr(self: *Parser, expr: ast.Expr) std.mem.Allocator.Error!ast.Expr {
    return switch (expr) {
        .literal => |lit| .{ .literal = switch (lit) {
            .text => |t| .{ .text = try self.copy(t) },
            .blob => |b| blk: {
                const owned = try self.allocator.alloc(u8, b.len);
                errdefer self.allocator.free(owned);
                @memcpy(owned, b);
                try self.allocations.append(self.allocator, owned);
                break :blk .{ .blob = owned };
            },
            else => lit,
        } },
        .identifier => |id| .{ .identifier = try self.copy(id) },
        .parameter => |p| .{ .parameter = p },
        .wildcard => .wildcard,
        .function => |call| {
            const argument = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(argument);
            argument.* = try copyParserExpr(self, call.argument.*);
            errdefer freeParserExpr(self.allocator, argument.*);
            var argument2: ?*const ast.Expr = null;
            if (call.argument2) |a2| {
                const node = try self.allocator.create(ast.Expr);
                errdefer self.allocator.destroy(node);
                node.* = try copyParserExpr(self, a2.*);
                argument2 = node;
            }
            errdefer if (argument2) |n| {
                freeParserExpr(self.allocator, n.*);
                self.allocator.destroy(n);
            };
            var argument3: ?*const ast.Expr = null;
            if (call.argument3) |a3| {
                const node = try self.allocator.create(ast.Expr);
                errdefer self.allocator.destroy(node);
                node.* = try copyParserExpr(self, a3.*);
                argument3 = node;
            }
            errdefer if (argument3) |n| {
                freeParserExpr(self.allocator, n.*);
                self.allocator.destroy(n);
            };
            var extraArgs: []ast.Expr = &.{};
            if (call.extraArgs.len != 0) {
                const list = try self.allocator.alloc(ast.Expr, call.extraArgs.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeParserExpr(self.allocator, item);
                    self.allocator.free(list);
                }
                for (call.extraArgs, 0..) |item, idx| {
                    list[idx] = try copyParserExpr(self, item);
                    count += 1;
                }
                extraArgs = list;
            }
            const filter = try copyOptionalParserExpr(self, call.filter);
            errdefer if (filter) |n| {
                freeParserExpr(self.allocator, n.*);
                self.allocator.destroy(n);
            };
            return .{ .function = .{ .name = try self.copy(call.name), .argument = argument, .argument2 = argument2, .argument3 = argument3, .extraArgs = extraArgs, .distinct = call.distinct, .filter = filter } };
        },
        .binary => |bin| {
            const left = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(left);
            left.* = try copyParserExpr(self, bin.left.*);
            errdefer freeParserExpr(self.allocator, left.*);
            const right = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(right);
            right.* = try copyParserExpr(self, bin.right.*);
            return .{ .binary = .{ .op = bin.op, .left = left, .right = right } };
        },
        .unary => |un| {
            const inner = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(inner);
            inner.* = try copyParserExpr(self, un.expr.*);
            return .{ .unary = .{ .op = un.op, .expr = inner } };
        },
        .caseExpr => |caseBlock| {
            var base: ?*const ast.Expr = null;
            if (caseBlock.base) |b| {
                const node = try self.allocator.create(ast.Expr);
                errdefer self.allocator.destroy(node);
                node.* = try copyParserExpr(self, b.*);
                base = node;
            }
            errdefer if (base) |n| {
                freeParserExpr(self.allocator, n.*);
                self.allocator.destroy(n);
            };
            var whens: []ast.CaseWhen = &.{};
            if (caseBlock.whens.len != 0) {
                const list = try self.allocator.alloc(ast.CaseWhen, caseBlock.whens.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| {
                        freeParserExpr(self.allocator, item.condition);
                        freeParserExpr(self.allocator, item.result);
                    }
                    self.allocator.free(list);
                }
                for (caseBlock.whens, 0..) |item, idx| {
                    list[idx] = .{ .condition = try copyParserExpr(self, item.condition), .result = try copyParserExpr(self, item.result) };
                    count += 1;
                }
                whens = list;
            }
            const otherwise = try copyOptionalParserExpr(self, caseBlock.otherwise);
            return .{ .caseExpr = .{ .base = base, .whens = whens, .otherwise = otherwise } };
        },
        .patternMatch => |match| {
            const value = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(value);
            value.* = try copyParserExpr(self, match.value.*);
            errdefer freeParserExpr(self.allocator, value.*);
            const pattern = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(pattern);
            pattern.* = try copyParserExpr(self, match.pattern.*);
            const escape = try copyOptionalParserExpr(self, match.escape);
            return .{ .patternMatch = .{ .value = value, .pattern = pattern, .escape = escape, .negated = match.negated, .glob = match.glob, .isRegexp = match.isRegexp, .isMatch = match.isMatch } };
        },
        .collate => |node| {
            const inner = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(inner);
            inner.* = try copyParserExpr(self, node.expr.*);
            return .{ .collate = .{ .expr = inner, .name = try self.copy(node.name) } };
        },
        .scalarSubquery => |sub| .{ .scalarSubquery = try self.copy(sub) },
        .existsSubquery => |sub| .{ .existsSubquery = try self.copy(sub) },
        .inSubquery => |inSub| {
            const target = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(target);
            target.* = try copyParserExpr(self, inSub.expr.*);
            return .{ .inSubquery = .{ .expr = target, .subquery = try self.copy(inSub.subquery), .negated = inSub.negated } };
        },
        .inList => |inL| {
            const target = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(target);
            target.* = try copyParserExpr(self, inL.expr.*);
            errdefer freeParserExpr(self.allocator, target.*);
            var list: []ast.Expr = &.{};
            if (inL.list.len != 0) {
                const owned = try self.allocator.alloc(ast.Expr, inL.list.len);
                var count: usize = 0;
                errdefer {
                    for (owned[0..count]) |item| freeParserExpr(self.allocator, item);
                    self.allocator.free(owned);
                }
                for (inL.list, 0..) |item, idx| {
                    owned[idx] = try copyParserExpr(self, item);
                    count += 1;
                }
                list = owned;
            }
            return .{ .inList = .{ .expr = target, .list = list, .negated = inL.negated } };
        },
        .window => |w| {
            const argument = try copyOptionalParserExpr(self, w.argument);
            errdefer if (argument) |n| {
                freeParserExpr(self.allocator, n.*);
                self.allocator.destroy(n);
            };
            const argument2 = try copyOptionalParserExpr(self, w.argument2);
            errdefer if (argument2) |n| {
                freeParserExpr(self.allocator, n.*);
                self.allocator.destroy(n);
            };
            var extraArgs: []ast.Expr = &.{};
            if (w.extraArgs.len != 0) {
                const list = try self.allocator.alloc(ast.Expr, w.extraArgs.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeParserExpr(self.allocator, item);
                    self.allocator.free(list);
                }
                for (w.extraArgs, 0..) |item, idx| {
                    list[idx] = try copyParserExpr(self, item);
                    count += 1;
                }
                extraArgs = list;
            }
            var parts: []ast.Expr = &.{};
            if (w.partitionBy.len != 0) {
                const list = try self.allocator.alloc(ast.Expr, w.partitionBy.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeParserExpr(self.allocator, item);
                    self.allocator.free(list);
                }
                for (w.partitionBy, 0..) |item, idx| {
                    list[idx] = try copyParserExpr(self, item);
                    count += 1;
                }
                parts = list;
            }
            var orders: []ast.OrderItem = &.{};
            if (w.orderBy.len != 0) {
                const list = try self.allocator.alloc(ast.OrderItem, w.orderBy.len);
                var count: usize = 0;
                errdefer {
                    for (list[0..count]) |item| freeParserExpr(self.allocator, item.expr);
                    self.allocator.free(list);
                }
                for (w.orderBy, 0..) |item, idx| {
                    list[idx] = .{ .expr = try copyParserExpr(self, item.expr), .descending = item.descending, .nullsFirst = item.nullsFirst };
                    count += 1;
                }
                orders = list;
            }
            const frame = try copyParserFrame(self, w.frame);
            errdefer if (frame) |fr| freeParserFrame(self, fr);
            const filter = try copyOptionalParserExpr(self, w.filter);
            const base = if (w.base) |b| try self.copy(b) else null;
            return .{ .window = .{ .funcName = try self.copy(w.funcName), .argument = argument, .argument2 = argument2, .extraArgs = extraArgs, .partitionBy = parts, .orderBy = orders, .frame = frame, .filter = filter, .distinct = w.distinct, .base = base } };
        },
    };
}

/// Copy one optional heap expression node for `copyParserExpr`.
fn copyOptionalParserExpr(self: *Parser, node: ?*const ast.Expr) std.mem.Allocator.Error!?*const ast.Expr {
    const src = node orelse return null;
    const owned = try self.allocator.create(ast.Expr);
    errdefer self.allocator.destroy(owned);
    owned.* = try copyParserExpr(self, src.*);
    return owned;
}

/// Deep-copy a window frame (offset expressions included) for named-window expansion.
fn copyParserFrame(self: *Parser, frame: ?ast.WindowFrame) std.mem.Allocator.Error!?ast.WindowFrame {
    var fr = frame orelse return null;
    fr.startOffset = try copyOptionalParserExpr(self, fr.startOffset);
    errdefer if (fr.startOffset) |n| {
        freeParserExpr(self.allocator, n.*);
        self.allocator.destroy(n);
    };
    fr.endOffset = try copyOptionalParserExpr(self, fr.endOffset);
    return fr;
}

/// Free one parser-arena window frame's offset structure (strings stay arena-owned).
fn freeParserFrame(self: *Parser, frame: ast.WindowFrame) void {
    if (frame.startOffset) |off| {
        freeParserExpr(self.allocator, off.*);
        self.allocator.destroy(off);
    }
    if (frame.endOffset) |off| {
        freeParserExpr(self.allocator, off.*);
        self.allocator.destroy(off);
    }
}

/// Parser failure modes: grammar errors plus unioned lexer/allocator errors.
pub const Error = error{ InvalidSql, UnexpectedToken, OutOfMemory, Unsupported, TooDeep } || std.mem.Allocator.Error || lexer.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError;

/// Maximum nesting depth for expressions/subqueries; hostile input fails closed.
pub const max_parse_depth: usize = 200;

/// Single-statement recursive-descent parser over a token slice.
pub const Parser = struct {
    /// Allocator for tokens, AST nodes, and retained string copies.
    allocator: std.mem.Allocator,
    /// Original SQL text; AST slices borrow it (must outlive parse+use).
    source: []const u8,
    /// Token stream ending in `.eof`, owned by the parser.
    tokens: []Token,
    /// Cursor into `tokens`.
    index: usize = 0,
    /// Next anonymous `?` parameter number (1-based).
    nextParameter: usize = 1,
    /// Owned string copies + blobs retained until `deinit`.
    allocations: std.ArrayList([]const u8),
    /// Current expression nesting depth (guarded by `max_parse_depth`).
    depth: usize = 0,

    /// Tokenize `sql` and return a parser; caller must call `deinit`.
    /// Fails closed on lexer errors with no parser to clean up.
    pub fn init(allocator: std.mem.Allocator, sql: []const u8) !Parser {
        return .{ .allocator = allocator, .source = sql, .tokens = try lexer.tokenize(allocator, sql), .allocations = .empty };
    }

    /// Release the token slice and every retained `copy()` allocation.
    /// Must be called after the AST has been freed with `ast.deinit`.
    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.tokens);
        for (self.allocations.items) |allocation| self.allocator.free(allocation);
        self.allocations.deinit(self.allocator);
    }

    fn current(self: *Parser) Token {
        return self.tokens[self.index];
    }
    fn advance(self: *Parser) Token {
        const token = self.current();
        self.index += 1;
        return token;
    }
    fn acceptTag(self: *Parser, tag: Tag) bool {
        if (self.current().tag == tag) {
            self.index += 1;
            return true;
        }
        return false;
    }
    fn acceptWord(self: *Parser, expected: []const u8) bool {
        if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, expected)) {
            self.index += 1;
            return true;
        }
        return false;
    }
    fn requireTag(self: *Parser, tag: Tag) !void {
        if (!self.acceptTag(tag)) return Error.UnexpectedToken;
    }
    fn requireWord(self: *Parser, expected: []const u8) !void {
        if (!self.acceptWord(expected)) return Error.UnexpectedToken;
    }
    fn word(self: *Parser) ![]const u8 {
        if (self.current().tag != .word) return Error.UnexpectedToken;
        return self.advance().text;
    }

    fn identifierOrNumber(self: *Parser) ![]const u8 {
        if (self.current().tag != .word and self.current().tag != .number) return Error.UnexpectedToken;
        return self.advance().text;
    }

    /// Aggregate/window names that may carry OVER or DISTINCT; delegates to
    /// the single function registry so parser, evaluator, and DSL cannot drift.
    fn isAggregateName(name: []const u8) bool {
        const functions = @import("functions.zig");
        if (functions.aggregate.AggKind.fromName(name) != null) return true;
        return std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max");
    }

    /// Window-only function names (rank, lag, ...); with `isAggregateName`
    /// this covers every name that may carry OVER.
    fn isWindowOnlyName(name: []const u8) bool {
        return @import("functions.zig").isWindowOnly(name);
    }

    /// Free one parsed window spec's node structure (strings stay arena-owned).
    fn freeWindowSpec(self: *Parser, spec: WindowSpec) void {
        for (spec.partitionBy) |item| freeParserExpr(self.allocator, item);
        if (spec.partitionBy.len != 0) self.allocator.free(spec.partitionBy);
        for (spec.orderBy) |item| freeParserExpr(self.allocator, item.expr);
        if (spec.orderBy.len != 0) self.allocator.free(spec.orderBy);
        if (spec.frame) |fr| freeParserFrame(self, fr);
    }

    /// One `WINDOW name AS (spec)` definition pending resolution.
    const NamedWindowDef = struct { name: []const u8, spec: WindowSpec };

    /// Find a WINDOW-clause definition by name (case-insensitive).
    fn findNamedWindow(defs: []const NamedWindowDef, name: []const u8) ?WindowSpec {
        for (defs) |def| if (std.ascii.eqlIgnoreCase(def.name, name)) return def.spec;
        return null;
    }

    /// Merge an OVER overlay onto a named base spec. Overlay slices are
    /// adopted (caller surrenders them); base parts are deep-copied so the
    /// stored definition stays intact for other uses. An overlay PARTITION
    /// is always InvalidSql; overlay ORDER BY or frame is InvalidSql when
    /// the base already sets the same clause, matching the reference
    /// ("cannot override ... of window").
    fn resolveWindowBase(self: *Parser, overlay: WindowSpec, base: WindowSpec) !WindowSpec {
        if (overlay.partitionBy.len != 0) return Error.InvalidSql;
        if (overlay.orderBy.len != 0 and base.orderBy.len != 0) return Error.InvalidSql;
        if (overlay.frame != null and base.frame != null) return Error.InvalidSql;
        var baseParts: []ast.Expr = &.{};
        var baseOrders: []ast.OrderItem = &.{};
        var baseFrame: ?ast.WindowFrame = null;
        errdefer self.freeWindowSpec(.{ .partitionBy = baseParts, .orderBy = baseOrders, .frame = baseFrame });
        if (overlay.partitionBy.len == 0 and base.partitionBy.len != 0) {
            const list = try self.allocator.alloc(ast.Expr, base.partitionBy.len);
            var count: usize = 0;
            errdefer {
                for (list[0..count]) |item| freeParserExpr(self.allocator, item);
                self.allocator.free(list);
            }
            for (base.partitionBy, 0..) |item, idx| {
                list[idx] = try copyParserExpr(self, item);
                count += 1;
            }
            baseParts = list;
        }
        if (overlay.orderBy.len == 0 and base.orderBy.len != 0) {
            const list = try self.allocator.alloc(ast.OrderItem, base.orderBy.len);
            var count: usize = 0;
            errdefer {
                for (list[0..count]) |item| freeParserExpr(self.allocator, item.expr);
                self.allocator.free(list);
            }
            for (base.orderBy, 0..) |item, idx| {
                list[idx] = .{ .expr = try copyParserExpr(self, item.expr), .descending = item.descending, .nullsFirst = item.nullsFirst };
                count += 1;
            }
            baseOrders = list;
        }
        if (overlay.frame == null) baseFrame = try copyParserFrame(self, base.frame);
        return .{
            .partitionBy = if (overlay.partitionBy.len != 0) overlay.partitionBy else baseParts,
            .orderBy = if (overlay.orderBy.len != 0) overlay.orderBy else baseOrders,
            .frame = overlay.frame orelse baseFrame,
        };
    }

    /// Resolve every `OVER name` use inside one expression against the
    /// SELECT's WINDOW clause. The parser owns the whole tree, so mutation
    /// through const children is sound (single owner, pre-publication).
    fn resolveWindowRefs(self: *Parser, expr: *ast.Expr, defs: []const NamedWindowDef) !void {
        switch (expr.*) {
            .function => |*call| {
                try self.resolveWindowRefs(@constCast(call.argument), defs);
                if (call.argument2) |a2| try self.resolveWindowRefs(@constCast(a2), defs);
                if (call.argument3) |a3| try self.resolveWindowRefs(@constCast(a3), defs);
                for (0..call.extraArgs.len) |idx| try self.resolveWindowRefs(@constCast(&call.extraArgs[idx]), defs);
                if (call.filter) |f| try self.resolveWindowRefs(@constCast(f), defs);
            },
            .binary => |*bin| {
                try self.resolveWindowRefs(@constCast(bin.left), defs);
                try self.resolveWindowRefs(@constCast(bin.right), defs);
            },
            .unary => |*un| try self.resolveWindowRefs(@constCast(un.expr), defs),
            .caseExpr => |*caseBlock| {
                if (caseBlock.base) |b| try self.resolveWindowRefs(@constCast(b), defs);
                for (caseBlock.whens) |*item| {
                    try self.resolveWindowRefs(&item.condition, defs);
                    try self.resolveWindowRefs(&item.result, defs);
                }
                if (caseBlock.otherwise) |o| try self.resolveWindowRefs(@constCast(o), defs);
            },
            .patternMatch => |*match| {
                try self.resolveWindowRefs(@constCast(match.value), defs);
                try self.resolveWindowRefs(@constCast(match.pattern), defs);
                if (match.escape) |e| try self.resolveWindowRefs(@constCast(e), defs);
            },
            .collate => |*node| try self.resolveWindowRefs(@constCast(node.expr), defs),
            .inSubquery => |*inSub| try self.resolveWindowRefs(@constCast(inSub.expr), defs),
            .inList => |*inL| {
                try self.resolveWindowRefs(@constCast(inL.expr), defs);
                for (0..inL.list.len) |idx| try self.resolveWindowRefs(@constCast(&inL.list[idx]), defs);
            },
            .window => |*w| {
                if (w.argument) |a| try self.resolveWindowRefs(@constCast(a), defs);
                if (w.argument2) |a2| try self.resolveWindowRefs(@constCast(a2), defs);
                for (0..w.extraArgs.len) |idx| try self.resolveWindowRefs(@constCast(&w.extraArgs[idx]), defs);
                for (0..w.partitionBy.len) |idx| try self.resolveWindowRefs(@constCast(&w.partitionBy[idx]), defs);
                for (0..w.orderBy.len) |idx| try self.resolveWindowRefs(@constCast(&w.orderBy[idx].expr), defs);
                if (w.filter) |f| try self.resolveWindowRefs(@constCast(f), defs);
                const baseName = w.base orelse return;
                const base = findNamedWindow(defs, baseName) orelse return Error.InvalidSql;
                const overlay = WindowSpec{ .partitionBy = w.partitionBy, .orderBy = w.orderBy, .frame = w.frame };
                const merged = try self.resolveWindowBase(overlay, base);
                w.partitionBy = merged.partitionBy;
                w.orderBy = merged.orderBy;
                w.frame = merged.frame;
                w.base = null;
            },
            else => {},
        }
    }

    /// Resolve named-window uses inside a WHERE condition list.
    fn resolveWindowRefsInConditions(self: *Parser, conditions: []const ast.Condition, defs: []const NamedWindowDef) !void {
        for (0..conditions.len) |idx| {
            const mutable: *ast.Condition = @constCast(&conditions[idx]);
            if (mutable.leftExpr) |*left| try self.resolveWindowRefs(left, defs);
            try self.resolveWindowRefs(&mutable.value, defs);
            if (mutable.value2) |*second| try self.resolveWindowRefs(second, defs);
            if (mutable.escape) |*escape| try self.resolveWindowRefs(escape, defs);
            for (0..mutable.listValues.len) |itemIdx| try self.resolveWindowRefs(@constCast(&mutable.listValues[itemIdx]), defs);
        }
    }

    fn qualifiedName(self: *Parser) !struct { table: []const u8, column: []const u8 } {
        const first = try self.word();
        if (!self.acceptTag(.dot)) return .{ .table = "", .column = first };
        const second = try self.word();
        if (!self.acceptTag(.dot)) return .{ .table = first, .column = second };
        const third = try self.word();
        const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ first, second });
        defer self.allocator.free(combined);
        return .{ .table = try self.copy(combined), .column = third };
    }

    fn tableName(self: *Parser) ![]const u8 {
        const first = try self.word();
        if (!self.acceptTag(.dot)) return first;
        const second = try self.word();
        const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ first, second });
        defer self.allocator.free(combined);
        return self.copy(combined);
    }
    fn copy(self: *Parser, bytes: []const u8) ![]const u8 {
        const result = try self.allocator.dupe(u8, bytes);
        try self.allocations.append(self.allocator, result);
        return result;
    }

    /// Copy a `'...'` string literal, collapsing SQLite `''` escapes to `'`.
    /// The lexer preserves the raw interior (e.g. `A''B`); the AST must hold
    /// the unescaped value (`A'B`) so stored data round-trips correctly.
    fn copyStringLiteral(self: *Parser, raw: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, raw, "''") == null) return self.copy(raw);
        var out = try self.allocator.alloc(u8, raw.len);
        errdefer self.allocator.free(out);
        var w: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            out[w] = raw[i];
            w += 1;
            if (raw[i] == '\'' and i + 1 < raw.len and raw[i + 1] == '\'') i += 1;
        }
        const shrunk = try self.allocator.realloc(out, w);
        try self.allocations.append(self.allocator, shrunk);
        return shrunk;
    }

    fn signedPragmaValue(self: *Parser, sign: []const u8, text: []const u8) ![]const u8 {
        const combined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ sign, text });
        defer self.allocator.free(combined);
        return self.copy(combined);
    }

    fn asParserError(err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnexpectedToken => Error.UnexpectedToken,
            else => Error.InvalidSql,
        };
    }

    /// Parse exactly one statement plus optional `;`; reject trailing tokens.
    /// Returns an AST the caller owns (`ast.deinit`); on error nothing leaks.
    pub fn parse(self: *Parser) !ast.Statement {
        var statement: ast.Statement = undefined;
        if (self.acceptWord("pragma")) {
            var pragmaName = try self.word();
            var pragmaSchema: ?[]const u8 = null;
            if (self.acceptTag(.dot)) {
                pragmaSchema = pragmaName;
                pragmaName = try self.word();
            }
            var pragmaValue: ?[]const u8 = null;
            var pragmaArgument: ?[]const u8 = null;
            if (self.acceptTag(.lparen)) {
                const token = self.current();
                if (token.tag != .word and token.tag != .number and token.tag != .string) return Error.UnexpectedToken;
                _ = self.advance();
                if (self.acceptTag(.dot)) {
                    const second = try self.word();
                    const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ token.text, second });
                    defer self.allocator.free(combined);
                    pragmaArgument = try self.copy(combined);
                } else {
                    pragmaArgument = if (token.tag == .string) try self.copyStringLiteral(token.text) else token.text;
                }
                try self.requireTag(.rparen);
            } else if (self.acceptTag(.equal)) {
                const token = self.current();
                if (token.tag == .minus or token.tag == .plus) {
                    const sign = self.advance();
                    const inner = self.current();
                    if (inner.tag != .word and inner.tag != .number and inner.tag != .string) return Error.UnexpectedToken;
                    _ = self.advance();
                    pragmaValue = try self.signedPragmaValue(sign.text, inner.text);
                } else {
                    if (token.tag != .word and token.tag != .number and token.tag != .string) return Error.UnexpectedToken;
                    _ = self.advance();
                    pragmaValue = if (token.tag == .string) try self.copyStringLiteral(token.text) else token.text;
                }
            }
            statement = .{ .pragma = .{ .name = pragmaName, .value = pragmaValue, .argument = pragmaArgument, .schema = pragmaSchema } };
        } else if (self.acceptWord("with")) statement = try self.parseWith() else if (self.acceptWord("explain")) {
            try self.requireWord("query");
            try self.requireWord("plan");
            const start = self.current().position;
            try self.requireWord("select");
            var query = try self.parseSelectOrCompound();
            defer ast.deinit(self.allocator, &query);
            const end = self.current().position;
            statement = .{ .explainQueryPlan = try self.copy(self.source[start..end]) };
        } else if (self.acceptWord("attach")) {
            _ = self.acceptWord("database");
            const expr = try self.parseExpr();
            try self.requireWord("as");
            const schemaName = try self.word();
            statement = .{ .attach = .{ .expr = expr, .schemaName = schemaName } };
        } else if (self.acceptWord("detach")) {
            _ = self.acceptWord("database");
            const schemaName = try self.word();
            statement = .{ .detach = .{ .schemaName = schemaName } };
        } else if (self.acceptWord("vacuum")) {
            var schemaName: ?[]const u8 = null;
            var intoExpr: ?ast.Expr = null;
            if (self.current().tag == .word and !std.ascii.eqlIgnoreCase(self.current().text, "into") and self.current().tag != .semicolon and self.current().tag != .eof) {
                schemaName = try self.word();
            }
            if (self.acceptWord("into")) {
                intoExpr = try self.parseExpr();
            }
            statement = .{ .vacuum = .{ .schemaName = schemaName, .into = intoExpr } };
        } else if (self.acceptWord("analyze")) {
            var target: ?[]const u8 = null;
            if (self.current().tag == .word) target = try self.tableName();
            statement = .{ .analyze = .{ .target = target } };
        } else if (self.acceptWord("reindex")) {
            var target: ?[]const u8 = null;
            if (self.current().tag == .word) target = try self.tableName();
            statement = .{ .reindex = .{ .target = target } };
        } else if (self.acceptWord("create")) statement = try self.parseCreate() else if (self.acceptWord("drop")) statement = try self.parseDrop() else if (self.acceptWord("alter")) statement = try self.parseAlter() else if (self.acceptWord("insert")) statement = try self.parseInsert() else if (self.acceptWord("select")) statement = try self.parseSelectOrCompound() else if (self.acceptWord("update")) statement = try self.parseUpdate() else if (self.acceptWord("delete")) statement = try self.parseDelete() else if (self.acceptWord("begin")) {
            _ = self.acceptWord("deferred");
            _ = self.acceptWord("immediate");
            _ = self.acceptWord("exclusive");
            statement = .begin;
        } else if (self.acceptWord("start")) {
            try self.requireWord("transaction");
            statement = .begin;
        } else if (self.acceptWord("commit")) statement = .commit else if (self.acceptWord("end")) statement = .commit else if (self.acceptWord("rollback")) {
            if (self.acceptWord("to")) statement = .{ .rollbackTo = try self.word() } else statement = .rollback;
        } else if (self.acceptWord("savepoint")) statement = .{ .savepoint = try self.word() } else if (self.acceptWord("release")) {
            _ = self.acceptWord("savepoint");
            statement = .{ .release = try self.word() };
        } else return Error.InvalidSql;
        _ = self.acceptTag(.semicolon);
        if (self.current().tag != .eof) {
            ast.deinit(self.allocator, &statement);
            return Error.UnexpectedToken;
        }
        return statement;
    }

    fn parseWith(self: *Parser) !ast.Statement {
        const recursive = self.acceptWord("recursive");
        var ctes = std.ArrayList(ast.CteDef).empty;
        errdefer {
            for (ctes.items) |cte| if (cte.columns.len != 0) self.allocator.free(cte.columns);
            ctes.deinit(self.allocator);
        }
        while (true) {
            const name = try self.word();
            var columnList = std.ArrayList([]const u8).empty;
            errdefer columnList.deinit(self.allocator);
            if (self.acceptTag(.lparen)) {
                while (true) {
                    try columnList.append(self.allocator, try self.word());
                    if (!self.acceptTag(.comma)) break;
                }
                try self.requireTag(.rparen);
            }
            try self.requireWord("as");
            try self.requireTag(.lparen);
            const queryStart = self.current().position;
            try self.requireWord("select");
            var queryStatement = try self.parseSelect();
            defer ast.deinit(self.allocator, &queryStatement);
            const queryEnd = self.current().position;
            var recursiveSql: ?[]const u8 = null;
            var recursiveAll = false;
            var compoundEnd = queryEnd;
            if (self.acceptWord("union")) {
                const isAll = self.acceptWord("all");
                const recursiveStart = self.current().position;
                try self.requireWord("select");
                var recursiveStatement = try self.parseSelect();
                defer ast.deinit(self.allocator, &recursiveStatement);
                const recursiveEnd = self.current().position;
                if (recursive) {
                    recursiveSql = try self.copy(self.source[recursiveStart..recursiveEnd]);
                    recursiveAll = isAll;
                } else {
                    compoundEnd = recursiveEnd;
                    while (self.acceptWord("union")) {
                        _ = self.acceptWord("all");
                        try self.requireWord("select");
                        var extraStatement = try self.parseSelect();
                        defer ast.deinit(self.allocator, &extraStatement);
                        compoundEnd = self.current().position;
                    }
                }
            }
            try self.requireTag(.rparen);
            try ctes.append(self.allocator, .{ .name = name, .columns = try columnList.toOwnedSlice(self.allocator), .querySql = try self.copy(self.source[queryStart..compoundEnd]), .recursiveSql = recursiveSql, .recursiveAll = recursiveAll });
            if (!self.acceptTag(.comma)) break;
        }
        const bodyStart = self.current().position;
        if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
            _ = self.advance();
            var bodyStatement = try self.parseSelect();
            defer ast.deinit(self.allocator, &bodyStatement);
        } else if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "insert")) {
            _ = self.advance();
            var bodyStatement = try self.parseInsert();
            defer ast.deinit(self.allocator, &bodyStatement);
        } else if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "update")) {
            _ = self.advance();
            var bodyStatement = try self.parseUpdate();
            defer ast.deinit(self.allocator, &bodyStatement);
        } else if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "delete")) {
            _ = self.advance();
            var bodyStatement = try self.parseDelete();
            defer ast.deinit(self.allocator, &bodyStatement);
        } else return Error.UnexpectedToken;
        const bodyEnd = self.current().position;
        return .{ .withSelect = .{ .ctes = try ctes.toOwnedSlice(self.allocator), .bodySql = try self.copy(self.source[bodyStart..bodyEnd]), .recursive = recursive } };
    }

    fn isTypeNameStop(text: []const u8) bool {
        return std.ascii.eqlIgnoreCase(text, "primary") or std.ascii.eqlIgnoreCase(text, "foreign") or std.ascii.eqlIgnoreCase(text, "not") or std.ascii.eqlIgnoreCase(text, "unique") or std.ascii.eqlIgnoreCase(text, "autoincrement") or std.ascii.eqlIgnoreCase(text, "check") or std.ascii.eqlIgnoreCase(text, "default") or std.ascii.eqlIgnoreCase(text, "generated") or std.ascii.eqlIgnoreCase(text, "as") or std.ascii.eqlIgnoreCase(text, "references") or std.ascii.eqlIgnoreCase(text, "collate") or std.ascii.eqlIgnoreCase(text, "constraint");
    }

    fn parseColumnTypeName(self: *Parser) ![]const u8 {
        if (self.current().tag != .word or isTypeNameStop(self.current().text)) return "";
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(self.allocator);
        while (self.current().tag == .word and !isTypeNameStop(self.current().text)) {
            try parts.append(self.allocator, try self.word());
        }
        if (parts.items.len == 1 and self.current().tag != .lparen) return parts.items[0];
        var params: ?[]const u8 = null;
        defer if (params) |p| self.allocator.free(p);
        if (self.current().tag == .lparen) {
            try self.requireTag(.lparen);
            if (self.current().tag != .number) return Error.UnexpectedToken;
            const whole = try self.identifierOrNumber();
            params = try std.fmt.allocPrint(self.allocator, "({s}", .{whole});
            if (self.acceptTag(.comma)) {
                if (self.current().tag != .number) return Error.UnexpectedToken;
                const frac = try self.identifierOrNumber();
                const extended = try std.fmt.allocPrint(self.allocator, "{s},{s}", .{ params.?, frac });
                self.allocator.free(params.?);
                params = extended;
            }
            try self.requireTag(.rparen);
            const closed = try std.fmt.allocPrint(self.allocator, "{s})", .{params.?});
            self.allocator.free(params.?);
            params = closed;
        }
        const names = try std.mem.join(self.allocator, " ", parts.items);
        defer self.allocator.free(names);
        if (params) |p| {
            const combined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ names, p });
            defer self.allocator.free(combined);
            return self.copy(combined);
        }
        return self.copy(names);
    }

    /// Parses `[NOT] DEFERRABLE [INITIALLY DEFERRED|IMMEDIATE]` after a
    /// REFERENCES clause. Bare `DEFERRABLE` means initially deferred;
    /// `NOT DEFERRABLE INITIALLY DEFERRED` and a lone `INITIALLY` fail.
    /// Peeks before consuming: a bare `NOT` may start a following column
    /// constraint (`REFERENCES t(c) NOT NULL`), which is left untouched.
    const DeferralClause = struct { deferrable: bool = false, initiallyDeferred: bool = false };
    fn parseDeferralClause(self: *Parser) !DeferralClause {
        const first = self.current();
        if (first.tag != .word or first.quoted) return .{};
        if (std.ascii.eqlIgnoreCase(first.text, "deferrable")) {
            self.index += 1;
            if (self.acceptWord("initially")) {
                if (self.acceptWord("deferred")) return .{ .deferrable = true, .initiallyDeferred = true };
                try self.requireWord("immediate");
                return .{ .deferrable = true, .initiallyDeferred = false };
            }
            return .{ .deferrable = true, .initiallyDeferred = true };
        }
        if (std.ascii.eqlIgnoreCase(first.text, "not")) {
            if (self.index + 1 >= self.tokens.len) return .{};
            const second = self.tokens[self.index + 1];
            if (second.tag != .word or second.quoted or !std.ascii.eqlIgnoreCase(second.text, "deferrable")) return .{};
            self.index += 2;
            if (self.acceptWord("initially")) {
                if (self.acceptWord("deferred")) return Error.InvalidSql;
                try self.requireWord("immediate");
            }
            return .{};
        }
        return .{};
    }

    fn parseColumnDef(self: *Parser) !ast.ColumnDef {
        const columnName = try self.word();
        const typeName = try self.parseColumnTypeName();
        var primaryKey = false;
        var notNull = false;
        var unique = false;
        var autoincrement = false;
        var foreignKey: ?ast.ForeignKeyDef = null;
        var defaultValue: ?Value = null;
        var checkExpr: ?ast.Expr = null;
        var generatedExpr: ?ast.Expr = null;
        var generatedStored = false;
        while (self.current().tag == .word) {
            if (self.acceptWord("primary")) {
                try self.requireWord("key");
                primaryKey = true;
            } else if (self.acceptWord("not")) {
                try self.requireWord("null");
                notNull = true;
            } else if (self.acceptWord("unique")) {
                unique = true;
            } else if (self.acceptWord("autoincrement")) {
                autoincrement = true;
            } else if (self.acceptWord("check")) {
                try self.requireTag(.lparen);
                checkExpr = try self.parseExpr();
                try self.requireTag(.rparen);
            } else if (self.acceptWord("default")) {
                const expression = try self.parseExpr();
                defaultValue = switch (expression) {
                    .literal => |value| value,
                    else => return Error.InvalidSql,
                };
            } else if (self.acceptWord("generated")) {
                try self.requireWord("always");
                try self.requireWord("as");
                try self.requireTag(.lparen);
                generatedExpr = try self.parseExpr();
                try self.requireTag(.rparen);
                if (self.acceptWord("stored")) {
                    generatedStored = true;
                } else if (self.acceptWord("virtual")) {
                    generatedStored = false;
                }
            } else if (self.acceptWord("as")) {
                try self.requireTag(.lparen);
                generatedExpr = try self.parseExpr();
                try self.requireTag(.rparen);
                if (self.acceptWord("stored")) {
                    generatedStored = true;
                } else if (self.acceptWord("virtual")) {
                    generatedStored = false;
                }
            } else if (self.acceptWord("references")) {
                const foreignTable = try self.word();
                try self.requireTag(.lparen);
                const foreignColumn = try self.word();
                try self.requireTag(.rparen);
                var onDelete: ast.ReferentialAction = .noAction;
                var onUpdate: ast.ReferentialAction = .noAction;
                while (self.acceptWord("on")) {
                    const action = if (self.acceptWord("delete")) blk: {
                        break :blk &onDelete;
                    } else if (self.acceptWord("update")) blk: {
                        break :blk &onUpdate;
                    } else return Error.UnexpectedToken;
                    action.* = if (self.acceptWord("cascade")) .cascade else if (self.acceptWord("set")) blk: {
                        if (self.acceptWord("null")) break :blk .setNull else if (self.acceptWord("default")) break :blk .setDefault else return Error.UnexpectedToken;
                    } else if (self.acceptWord("restrict")) .restrict else if (self.acceptWord("no")) blk: {
                        try self.requireWord("action");
                        break :blk .noAction;
                    } else return Error.UnexpectedToken;
                }
                const deferral = try self.parseDeferralClause();
                foreignKey = .{ .table = foreignTable, .column = foreignColumn, .onDelete = onDelete, .onUpdate = onUpdate, .deferrable = deferral.deferrable, .initiallyDeferred = deferral.initiallyDeferred };
            } else break;
        }
        return .{ .name = columnName, .typeName = typeName, .primaryKey = primaryKey, .notNull = notNull, .unique = unique, .autoincrement = autoincrement, .foreignKey = foreignKey, .defaultValue = defaultValue, .checkExpr = checkExpr, .generatedExpr = generatedExpr, .generatedStored = generatedStored };
    }

    fn parseCreate(self: *Parser) !ast.Statement {
        const temporary = self.acceptWord("temp") or self.acceptWord("temporary");
        if (self.acceptWord("trigger")) return self.parseTrigger(temporary);
        if (self.acceptWord("virtual")) {
            if (temporary) return Error.UnexpectedToken;
            try self.requireWord("table");
            const ifNotExists = if (self.acceptWord("if")) blk: {
                try self.requireWord("not");
                try self.requireWord("exists");
                break :blk true;
            } else false;
            const name = try self.tableName();
            try self.requireWord("using");
            const module = try self.word();
            try self.requireTag(.lparen);
            var arguments = std.ArrayList([]const u8).empty;
            errdefer arguments.deinit(self.allocator);
            if (!self.acceptTag(.rparen)) {
                while (true) {
                    const token = self.current();
                    if (token.tag != .number and token.tag != .word and token.tag != .string and token.tag != .parameter) return Error.UnexpectedToken;
                    _ = self.advance();
                    try arguments.append(self.allocator, token.text);
                    if (!self.acceptTag(.comma)) break;
                }
                try self.requireTag(.rparen);
            }
            return .{ .createVirtualTable = .{ .name = name, .module = module, .arguments = try arguments.toOwnedSlice(self.allocator), .ifNotExists = ifNotExists } };
        }
        if (self.acceptWord("view")) {
            const ifNotExists = if (self.acceptWord("if")) blk: {
                try self.requireWord("not");
                try self.requireWord("exists");
                break :blk true;
            } else false;
            const name = try self.tableName();
            try self.requireWord("as");
            const start = self.current().position;
            try self.requireWord("select");
            var selectStatement = try self.parseSelect();
            defer ast.deinit(self.allocator, &selectStatement);
            if (selectStatement != .select) {
                return Error.InvalidSql;
            }
            const end = self.current().position;
            return .{ .createView = .{ .name = name, .sql = try self.copy(self.source[start..end]), .ifNotExists = ifNotExists, .temporary = temporary } };
        }
        if (self.acceptWord("unique")) {
            try self.requireWord("index");
            if (temporary) return Error.UnexpectedToken;
            return self.parseIndex(true);
        }
        if (self.acceptWord("index")) {
            if (temporary) return Error.UnexpectedToken;
            return self.parseIndex(false);
        }
        try self.requireWord("table");
        const ifNotExists = if (self.acceptWord("if")) blk: {
            try self.requireWord("not");
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.tableName();
        try self.requireTag(.lparen);
        var columns = std.ArrayList(ast.ColumnDef).empty;
        errdefer columns.deinit(self.allocator);
        var constraints = std.ArrayList(ast.TableConstraint).empty;
        errdefer {
            for (constraints.items) |constraint| switch (constraint) {
                .primaryKey => |names| self.allocator.free(names),
                .unique => |names| self.allocator.free(names),
                .foreignKey => |foreignKey| {
                    self.allocator.free(foreignKey.columns);
                    self.allocator.free(foreignKey.referencedColumns);
                },
                .check => |chk| freeParserExpr(self.allocator, chk),
            };
            constraints.deinit(self.allocator);
        }
        while (true) {
            if (self.current().tag == .word and (std.ascii.eqlIgnoreCase(self.current().text, "primary") or std.ascii.eqlIgnoreCase(self.current().text, "unique") or std.ascii.eqlIgnoreCase(self.current().text, "foreign") or std.ascii.eqlIgnoreCase(self.current().text, "check") or std.ascii.eqlIgnoreCase(self.current().text, "constraint"))) {
                if (self.acceptWord("constraint")) _ = try self.word();
                if (self.acceptWord("check")) {
                    try self.requireTag(.lparen);
                    const checkExpr = try self.parseExpr();
                    try self.requireTag(.rparen);
                    try constraints.append(self.allocator, .{ .check = checkExpr });
                } else if (self.acceptWord("foreign")) {
                    try self.requireWord("key");
                    try self.requireTag(.lparen);
                    var childColumns = std.ArrayList([]const u8).empty;
                    errdefer childColumns.deinit(self.allocator);
                    while (true) {
                        try childColumns.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    try self.requireWord("references");
                    const foreignTable = try self.word();
                    try self.requireTag(.lparen);
                    var parentColumns = std.ArrayList([]const u8).empty;
                    errdefer parentColumns.deinit(self.allocator);
                    while (true) {
                        try parentColumns.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    if (childColumns.items.len == 0 or childColumns.items.len != parentColumns.items.len) return Error.InvalidSql;
                    var onDelete: ast.ReferentialAction = .noAction;
                    var onUpdate: ast.ReferentialAction = .noAction;
                    while (self.acceptWord("on")) {
                        const action = if (self.acceptWord("delete")) blk: {
                            break :blk &onDelete;
                        } else if (self.acceptWord("update")) blk: {
                            break :blk &onUpdate;
                        } else return Error.UnexpectedToken;
                        action.* = if (self.acceptWord("cascade")) .cascade else if (self.acceptWord("set")) blk: {
                            if (self.acceptWord("null")) break :blk .setNull else if (self.acceptWord("default")) break :blk .setDefault else return Error.UnexpectedToken;
                        } else if (self.acceptWord("restrict")) .restrict else if (self.acceptWord("no")) blk: {
                            try self.requireWord("action");
                            break :blk .noAction;
                        } else return Error.UnexpectedToken;
                    }
                    const deferral = try self.parseDeferralClause();
                    try constraints.append(self.allocator, .{ .foreignKey = .{ .columns = try childColumns.toOwnedSlice(self.allocator), .table = foreignTable, .referencedColumns = try parentColumns.toOwnedSlice(self.allocator), .onDelete = onDelete, .onUpdate = onUpdate, .deferrable = deferral.deferrable, .initiallyDeferred = deferral.initiallyDeferred } });
                } else {
                    const kind: enum { primaryKey, unique } = if (self.acceptWord("primary")) blk: {
                        try self.requireWord("key");
                        break :blk .primaryKey;
                    } else if (self.acceptWord("unique")) .unique else return Error.UnexpectedToken;
                    try self.requireTag(.lparen);
                    var names = std.ArrayList([]const u8).empty;
                    errdefer names.deinit(self.allocator);
                    while (true) {
                        try names.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    if (names.items.len == 0) return Error.InvalidSql;
                    const ownedNames = try names.toOwnedSlice(self.allocator);
                    try constraints.append(self.allocator, switch (kind) {
                        .primaryKey => .{ .primaryKey = ownedNames },
                        .unique => .{ .unique = ownedNames },
                    });
                }
                if (!self.acceptTag(.comma)) break;
                continue;
            }
            const colDef = try self.parseColumnDef();
            try columns.append(self.allocator, colDef);
            if (!self.acceptTag(.comma)) break;
        }
        // More than 2000 columns fails fast instead of piling up.
        if (columns.items.len > limits.max_columns) return error.SqlTooBig;
        try self.requireTag(.rparen);
        var strict = false;
        var withoutRowid = false;
        while (true) {
            if (self.acceptWord("without")) {
                try self.requireWord("rowid");
                withoutRowid = true;
            } else if (self.acceptWord("strict")) {
                strict = true;
            } else break;
            _ = self.acceptTag(.comma);
        }
        return .{ .createTable = .{ .name = name, .columns = try columns.toOwnedSlice(self.allocator), .constraints = try constraints.toOwnedSlice(self.allocator), .ifNotExists = ifNotExists, .strict = strict, .withoutRowid = withoutRowid, .temporary = temporary } };
    }

    fn parseIndex(self: *Parser, unique: bool) !ast.Statement {
        const ifNotExists = if (self.acceptWord("if")) blk: {
            try self.requireWord("not");
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.tableName();
        try self.requireWord("on");
        const table = try self.tableName();
        try self.requireTag(.lparen);
        var columns = std.ArrayList([]const u8).empty;
        errdefer columns.deinit(self.allocator);
        var keyExprs = std.ArrayList(?ast.Expr).empty;
        errdefer {
            for (keyExprs.items) |maybeKey| if (maybeKey) |key| freeParserExpr(self.allocator, key);
            keyExprs.deinit(self.allocator);
        }
        while (true) {
            if (self.current().tag == .word and self.index + 1 < self.tokens.len and (self.tokens[self.index + 1].tag == .comma or self.tokens[self.index + 1].tag == .rparen)) {
                try columns.append(self.allocator, try self.word());
                try keyExprs.append(self.allocator, null);
            } else {
                const start = self.current().position;
                try keyExprs.append(self.allocator, try self.parseExpr());
                errdefer if (keyExprs.pop()) |maybeKey| if (maybeKey) |key| freeParserExpr(self.allocator, key);
                try columns.append(self.allocator, try self.copy(self.source[start..self.current().position]));
            }
            if (!self.acceptTag(.comma)) break;
        }
        try self.requireTag(.rparen);
        var whereExpr: ?ast.Expr = null;
        var whereSql: ?[]const u8 = null;
        if (self.acceptWord("where")) {
            const start = self.current().position;
            whereExpr = try self.parseExpr();
            whereSql = try self.copy(self.source[start..self.current().position]);
        }
        return .{ .createIndex = .{ .name = name, .table = table, .columns = try columns.toOwnedSlice(self.allocator), .keyExprs = try keyExprs.toOwnedSlice(self.allocator), .unique = unique, .ifNotExists = ifNotExists, .whereExpr = whereExpr, .whereSql = whereSql } };
    }

    fn parseTrigger(self: *Parser, temporary: bool) !ast.Statement {
        const ifNotExists = if (self.acceptWord("if")) blk: {
            try self.requireWord("not");
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.tableName();
        const timing: ast.TriggerTiming = if (self.acceptWord("before")) .before else blk: {
            try self.requireWord("after");
            break :blk .after;
        };
        const event: ast.TriggerEvent = if (self.acceptWord("insert")) .insert else if (self.acceptWord("update")) .update else if (self.acceptWord("delete")) .delete else return Error.UnexpectedToken;
        var updateOf = std.ArrayList([]const u8).empty;
        errdefer updateOf.deinit(self.allocator);
        if (event == .update and self.acceptWord("of")) {
            while (true) {
                try updateOf.append(self.allocator, try self.word());
                if (!self.acceptTag(.comma)) break;
            }
        }
        try self.requireWord("on");
        const table = try self.tableName();
        var whenSql: ?[]const u8 = null;
        if (self.acceptWord("when")) {
            const whenStart = self.current().position;
            const whenExpr = try self.parseExpr();
            defer ast.freeExprRec(self.allocator, whenExpr);
            const whenEnd = self.current().position;
            if (whenEnd <= whenStart) return Error.UnexpectedToken;
            whenSql = try self.copy(std.mem.trim(u8, self.source[whenStart..whenEnd], " \t\r\n"));
            if (whenSql.?.len == 0) return Error.UnexpectedToken;
        }
        try self.requireWord("begin");
        const bodyStart = self.current().position;
        while (self.current().tag != .eof and !(self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "end"))) _ = self.advance();
        if (self.current().tag == .eof or self.current().position == bodyStart) return Error.UnexpectedToken;
        const bodyEnd = self.current().position;
        _ = self.advance();
        return .{ .createTrigger = .{ .name = name, .table = table, .timing = timing, .event = event, .updateOf = try updateOf.toOwnedSlice(self.allocator), .whenSql = whenSql, .body = try self.copy(self.source[bodyStart..bodyEnd]), .ifNotExists = ifNotExists, .temporary = temporary } };
    }

    fn parseDrop(self: *Parser) !ast.Statement {
        const kind: enum { table, index, view, trigger } = if (self.acceptWord("table")) .table else if (self.acceptWord("index")) .index else if (self.acceptWord("view")) .view else if (self.acceptWord("trigger")) .trigger else return Error.UnexpectedToken;
        const ifExists = if (self.acceptWord("if")) blk: {
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.tableName();
        return switch (kind) {
            .table => .{ .dropTable = .{ .name = name, .ifExists = ifExists } },
            .index => .{ .dropIndex = .{ .name = name, .ifExists = ifExists } },
            .view => .{ .dropView = .{ .name = name, .ifExists = ifExists } },
            .trigger => .{ .dropTrigger = .{ .name = name, .ifExists = ifExists } },
        };
    }

    fn parseAlter(self: *Parser) !ast.Statement {
        try self.requireWord("table");
        const table = try self.tableName();
        if (self.acceptWord("add")) {
            _ = self.acceptWord("column");
            const def = try self.parseColumnDef();
            return .{ .alterTable = .{ .addColumn = .{ .table = table, .definition = def } } };
        }
        if (self.acceptWord("rename")) {
            if (self.acceptWord("to")) return .{ .alterTable = .{ .renameTable = .{ .table = table, .newName = try self.word() } } };
            try self.requireWord("column");
            const oldName = try self.word();
            try self.requireWord("to");
            return .{ .alterTable = .{ .renameColumn = .{ .table = table, .oldName = oldName, .newName = try self.word() } } };
        }
        if (self.acceptWord("drop")) {
            _ = self.acceptWord("column");
            return .{ .alterTable = .{ .dropColumn = .{ .table = table, .column = try self.word() } } };
        }
        return Error.UnexpectedToken;
    }

    const BoundResult = struct {
        bound: ast.WindowFrameBound,
        offset: ?*const ast.Expr = null,
    };

    fn parseWindowBound(self: *Parser) !BoundResult {
        if (self.acceptWord("unbounded")) {
            if (self.acceptWord("preceding")) return .{ .bound = .unboundedPreceding };
            if (self.acceptWord("following")) return .{ .bound = .unboundedFollowing };
            return Error.UnexpectedToken;
        }
        if (self.acceptWord("current")) {
            try self.requireWord("row");
            return .{ .bound = .currentRow };
        }
        // Offsets are full expressions (literals, parameters, column refs);
        // the executor requires a non-negative integer per row, like the
        // reference ("frame starting offset must be a non-negative integer").
        const node = try self.allocator.create(ast.Expr);
        errdefer self.allocator.destroy(node);
        node.* = try self.parseExpr();
        errdefer freeParserExpr(self.allocator, node.*);
        if (self.acceptWord("preceding")) return .{ .bound = .preceding, .offset = node };
        if (self.acceptWord("following")) return .{ .bound = .following, .offset = node };
        return Error.UnexpectedToken;
    }

    fn parseWindowFrame(self: *Parser) !?ast.WindowFrame {
        const kind: ast.WindowFrameKind = if (self.acceptWord("rows"))
            .rows
        else if (self.acceptWord("range"))
            .range
        else if (self.acceptWord("groups"))
            .groups
        else
            return null;

        var frame: ast.WindowFrame = .{ .kind = kind };
        if (self.acceptWord("between")) {
            const start = try self.parseWindowBound();
            try self.requireWord("and");
            const end = try self.parseWindowBound();
            frame.start = start.bound;
            frame.startOffset = start.offset;
            frame.end = end.bound;
            frame.endOffset = end.offset;
        } else {
            const start = try self.parseWindowBound();
            frame.start = start.bound;
            frame.startOffset = start.offset;
        }
        if (self.acceptWord("exclude")) {
            if (self.acceptWord("current")) {
                try self.requireWord("row");
                frame.exclude = .currentRow;
            } else if (self.acceptWord("group")) {
                frame.exclude = .group;
            } else if (self.acceptWord("ties")) {
                frame.exclude = .ties;
            } else if (self.acceptWord("no")) {
                try self.requireWord("others");
                frame.exclude = .none;
            } else return Error.UnexpectedToken;
        }
        return frame;
    }

    /// Parse `FILTER (WHERE expr)` after an aggregate call; null when absent.
    /// The caller owns the heap node on success (freed with the call).
    fn parseFilterClause(self: *Parser) !?*const ast.Expr {
        if (!self.acceptWord("filter")) return null;
        try self.requireTag(.lparen);
        try self.requireWord("where");
        const node = try self.allocator.create(ast.Expr);
        errdefer self.allocator.destroy(node);
        node.* = try self.parseExpr();
        errdefer freeParserExpr(self.allocator, node.*);
        try self.requireTag(.rparen);
        return node;
    }

    /// Window spec with an optional base-window name (`OVER w` keeps the
    /// name; `OVER (w ...)` merges the overlay onto the named base).
    /// Returned slices are parser-owned; resolution copies them per use.
    const WindowSpec = struct { base: ?[]const u8 = null, partitionBy: []const ast.Expr = &.{}, orderBy: []const ast.OrderItem = &.{}, frame: ?ast.WindowFrame = null };

    fn parseWindowSpec(self: *Parser) !WindowSpec {
        try self.requireTag(.lparen);
        var base: ?[]const u8 = null;
        // A leading word that is not PARTITION/ORDER/ROWS/RANGE/GROUPS names
        // the base window; `w` alone is also accepted but an empty `()`
        // stays a bare spec.
        if (self.current().tag == .word and !self.current().quoted) {
            const text = self.current().text;
            if (!std.ascii.eqlIgnoreCase(text, "partition") and !std.ascii.eqlIgnoreCase(text, "order") and !std.ascii.eqlIgnoreCase(text, "rows") and !std.ascii.eqlIgnoreCase(text, "range") and !std.ascii.eqlIgnoreCase(text, "groups")) {
                base = self.advance().text;
            }
        }
        var partitionBy = std.ArrayList(ast.Expr).empty;
        errdefer {
            for (partitionBy.items) |item| freeParserExpr(self.allocator, item);
            partitionBy.deinit(self.allocator);
        }
        if (self.acceptWord("partition")) {
            try self.requireWord("by");
            while (true) {
                try partitionBy.append(self.allocator, try self.parseExpr());
                if (!self.acceptTag(.comma)) break;
            }
        }
        var orderBy = std.ArrayList(ast.OrderItem).empty;
        errdefer {
            for (orderBy.items) |item| freeParserExpr(self.allocator, item.expr);
            orderBy.deinit(self.allocator);
        }
        if (self.acceptWord("order")) {
            try self.requireWord("by");
            while (true) {
                const expr = try self.parseExpr();
                const descending = self.acceptWord("desc");
                if (!descending) _ = self.acceptWord("asc");
                var nullsFirst = false;
                if (self.acceptWord("nulls")) {
                    if (self.acceptWord("first")) {
                        nullsFirst = true;
                    } else if (self.acceptWord("last")) {
                        nullsFirst = false;
                    } else return Error.UnexpectedToken;
                }
                try orderBy.append(self.allocator, .{ .expr = expr, .descending = descending, .nullsFirst = nullsFirst });
                if (!self.acceptTag(.comma)) break;
            }
        }
        const frame = try self.parseWindowFrame();
        try self.requireTag(.rparen);
        return .{
            .base = base,
            .partitionBy = try partitionBy.toOwnedSlice(self.allocator),
            .orderBy = try orderBy.toOwnedSlice(self.allocator),
            .frame = frame,
        };
    }

    fn parseLiteral(self: *Parser) Error!ast.Expr {
        if (self.acceptTag(.star)) return .wildcard;
        if (self.acceptTag(.lparen)) {
            if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
                const start = self.current().position;
                _ = self.advance();
                var sub = self.parseSelectOrCompound() catch |err| return asParserError(err);
                defer ast.deinit(self.allocator, &sub);
                const end = self.current().position;
                try self.requireTag(.rparen);
                return .{ .scalarSubquery = try self.copy(self.source[start..end]) };
            }
            const inner = try self.parseExpr();
            try self.requireTag(.rparen);
            return inner;
        }
        if (self.acceptWord("exists")) {
            try self.requireTag(.lparen);
            const start = self.current().position;
            try self.requireWord("select");
            var sub = self.parseSelectOrCompound() catch |err| return asParserError(err);
            defer ast.deinit(self.allocator, &sub);
            const end = self.current().position;
            try self.requireTag(.rparen);
            return .{ .existsSubquery = try self.copy(self.source[start..end]) };
        }
        if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "case")) {
            _ = self.advance();
            return self.parseCase();
        }
        const token = self.current();
        if (token.tag == .parameter) {
            _ = self.advance();
            const index = if (token.text.len > 1) std.fmt.parseInt(usize, token.text[1..], 10) catch self.nextParameter else self.nextParameter;
            if (token.text.len == 1) self.nextParameter += 1;
            // Parameter indices run 1..32766; outside that prepare fails.
            if (index == 0 or index > limits.max_variables) return error.SqlTooBig;
            return .{ .parameter = index };
        }
        if (token.tag == .number) {
            _ = self.advance();
            if (token.text.len > 2 and token.text[0] == '0' and (token.text[1] == 'x' or token.text[1] == 'X')) {
                return .{ .literal = .{ .integer = std.fmt.parseInt(i64, token.text[2..], 16) catch return Error.InvalidSql } };
            }
            if (std.mem.indexOfScalar(u8, token.text, '.') != null or std.mem.indexOfScalar(u8, token.text, 'e') != null or std.mem.indexOfScalar(u8, token.text, 'E') != null) {
                return .{ .literal = .{ .real = std.fmt.parseFloat(f64, token.text) catch return Error.InvalidSql } };
            }
            if (std.fmt.parseInt(i64, token.text, 10)) |number| {
                return .{ .literal = .{ .integer = number } };
            } else |_| {}
            return .{ .literal = .{ .real = std.fmt.parseFloat(f64, token.text) catch return Error.InvalidSql } };
        }
        if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "x") and self.index + 1 < self.tokens.len and self.tokens[self.index + 1].tag == .string) {
            _ = self.advance();
            const strToken = self.advance();
            const hexText = strToken.text;
            if (hexText.len % 2 != 0) return Error.InvalidSql;
            const bytes = try self.allocator.alloc(u8, hexText.len / 2);
            errdefer self.allocator.free(bytes);
            _ = std.fmt.hexToBytes(bytes, hexText) catch return Error.InvalidSql;
            try self.allocations.append(self.allocator, bytes);
            return .{ .literal = .{ .blob = bytes } };
        }
        if (token.tag == .string) {
            _ = self.advance();
            return .{ .literal = .{ .text = try self.copyStringLiteral(token.text) } };
        }
        if (self.acceptWord("null")) return .{ .literal = .null };
        if (self.acceptWord("true")) return .{ .literal = .{ .integer = 1 } };
        if (self.acceptWord("false")) return .{ .literal = .{ .integer = 0 } };
        if (token.tag == .word) {
            var name = self.advance().text;
            if (self.acceptTag(.dot)) {
                const column = try self.word();
                if (self.acceptTag(.dot)) {
                    const third = try self.word();
                    const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ name, column, third });
                    defer self.allocator.free(qualified);
                    name = try self.copy(qualified);
                } else {
                    const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, column });
                    defer self.allocator.free(qualified);
                    name = try self.copy(qualified);
                }
            }
            if (std.ascii.eqlIgnoreCase(name, "substring") and self.current().tag == .lparen) name = "substr";
            if (self.acceptTag(.lparen)) {
                var argument: ?*ast.Expr = null;
                var argument2: ?*const ast.Expr = null;
                var argument3: ?*const ast.Expr = null;
                var extraArgs = std.ArrayList(ast.Expr).empty;
                defer extraArgs.deinit(self.allocator);
                var distinct = false;
                var argCount: usize = 0;
                if (!self.acceptTag(.rparen)) {
                    distinct = self.acceptWord("distinct");
                    if (distinct and !isAggregateName(name)) return Error.UnexpectedToken;
                    const first = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(first);
                    first.* = try self.parseExpr();
                    argument = first;
                    argCount = 1;
                    if (distinct and first.* == .wildcard) return Error.UnexpectedToken;
                    if (std.ascii.eqlIgnoreCase(name, "cast")) {
                        try self.requireWord("as");
                        const target = try self.allocator.create(ast.Expr);
                        errdefer self.allocator.destroy(target);
                        const castTarget = try self.parseColumnTypeName();
                        if (castTarget.len == 0) return Error.UnexpectedToken;
                        target.* = .{ .identifier = castTarget };
                        argument2 = target;
                        try self.requireTag(.rparen);
                    } else {
                        if (self.acceptTag(.comma)) {
                            const second = try self.allocator.create(ast.Expr);
                            errdefer self.allocator.destroy(second);
                            second.* = try self.parseExpr();
                            argument2 = second;
                            argCount = 2;
                            if (self.acceptTag(.comma)) {
                                const third = try self.allocator.create(ast.Expr);
                                errdefer self.allocator.destroy(third);
                                third.* = try self.parseExpr();
                                argument3 = third;
                                argCount = 3;
                                while (self.acceptTag(.comma)) {
                                    try extraArgs.append(self.allocator, try self.parseExpr());
                                    argCount += 1;
                                    // At most 1000 call arguments; fail before
                                    // the tail can grow without bound.
                                    if (argCount > limits.max_function_args) return error.SqlTooBig;
                                }
                            }
                        }
                        try self.requireTag(.rparen);
                    }
                }
                // `FILTER (WHERE ...)` applies to aggregates only and sits
                // between the call and OVER; anything else is InvalidSql,
                // matching the reference ("FILTER clause may only be used
                // with aggregate window functions").
                var filter: ?*const ast.Expr = null;
                errdefer if (filter) |f| {
                    freeParserExpr(self.allocator, f.*);
                    self.allocator.destroy(f);
                };
                if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "filter")) {
                    if (!isAggregateName(name)) return Error.InvalidSql;
                    filter = try self.parseFilterClause();
                }
                if (self.acceptWord("over")) {
                    if (!isAggregateName(name) and !isWindowOnlyName(name)) return Error.InvalidSql;
                    // `OVER name` reuses a WINDOW-clause definition; `OVER (...)`
                    // may start from one (`OVER (w ORDER BY ...)`) or stand alone.
                    // Names resolve in parseSelect; the window keeps `base` until then.
                    var base: ?[]const u8 = null;
                    var spec: WindowSpec = .{};
                    var ownsSpec = false;
                    if (self.current().tag == .lparen) {
                        spec = try self.parseWindowSpec();
                        ownsSpec = true;
                    } else {
                        base = try self.word();
                    }
                    errdefer if (ownsSpec) self.freeWindowSpec(spec);
                    var winExtra = std.ArrayList(ast.Expr).empty;
                    defer winExtra.deinit(self.allocator);
                    if (argument3) |a3| {
                        try winExtra.append(self.allocator, a3.*);
                        self.allocator.destroy(a3);
                    }
                    for (extraArgs.items) |ea| try winExtra.append(self.allocator, ea);
                    return .{ .window = .{
                        .funcName = name,
                        .argument = argument,
                        .argument2 = argument2,
                        .extraArgs = try winExtra.toOwnedSlice(self.allocator),
                        .partitionBy = spec.partitionBy,
                        .orderBy = spec.orderBy,
                        .frame = spec.frame,
                        .filter = filter,
                        .distinct = distinct,
                        .base = base orelse spec.base,
                    } };
                }
                if (argument == null) {
                    const nullArg = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(nullArg);
                    nullArg.* = .wildcard;
                    argument = nullArg;
                }
                return .{ .function = .{
                    .name = name,
                    .argument = argument.?,
                    .argument2 = argument2,
                    .argument3 = argument3,
                    .extraArgs = try extraArgs.toOwnedSlice(self.allocator),
                    .distinct = distinct,
                    .filter = filter,
                } };
            }
            return .{ .identifier = name };
        }
        return Error.UnexpectedToken;
    }

    fn binaryNode(self: *Parser, op: ast.BinaryOp, left: ast.Expr, right: ast.Expr) !ast.Expr {
        const leftNode = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, left);
            self.allocator.destroy(leftNode);
        }
        leftNode.* = left;
        const rightNode = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, right);
            self.allocator.destroy(rightNode);
        }
        rightNode.* = right;
        return .{ .binary = .{ .op = op, .left = leftNode, .right = rightNode } };
    }

    fn unaryNode(self: *Parser, op: ast.UnaryOp, expr: ast.Expr) !ast.Expr {
        const node = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, expr);
            self.allocator.destroy(node);
        }
        node.* = expr;
        return .{ .unary = .{ .op = op, .expr = node } };
    }

    fn parseExpr(self: *Parser) Error!ast.Expr {
        if (self.depth >= max_parse_depth) return Error.InvalidSql;
        self.depth += 1;
        defer self.depth -= 1;
        return self.parseOr();
    }

    fn parseOr(self: *Parser) Error!ast.Expr {
        var left = try self.parseAnd();
        while (self.acceptWord("or")) {
            left = try self.binaryNode(.logicalOr, left, try self.parseAnd());
        }
        return left;
    }

    fn parseAnd(self: *Parser) Error!ast.Expr {
        var left = try self.parseLike();
        while (self.acceptWord("and")) {
            left = try self.binaryNode(.logicalAnd, left, try self.parseLike());
        }
        return left;
    }

    fn patternNode(self: *Parser, value: ast.Expr, pattern: ast.Expr, escape: ?ast.Expr, negated: bool, glob: bool) !ast.Expr {
        return self.patternNodeFull(value, pattern, escape, negated, glob, false, false);
    }

    fn patternNodeFull(self: *Parser, value: ast.Expr, pattern: ast.Expr, escape: ?ast.Expr, negated: bool, glob: bool, isRegexp: bool, isMatch: bool) !ast.Expr {
        const valueNode = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, value);
            self.allocator.destroy(valueNode);
        }
        valueNode.* = value;
        const patternExpr = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, pattern);
            self.allocator.destroy(patternExpr);
        }
        patternExpr.* = pattern;
        var escapeNode: ?*const ast.Expr = null;
        errdefer if (escapeNode) |node| {
            if (escape) |expr| freeParserExpr(self.allocator, expr);
            self.allocator.destroy(node);
        };
        if (escape) |expr| {
            const node = try self.allocator.create(ast.Expr);
            node.* = expr;
            escapeNode = node;
        }
        return .{ .patternMatch = .{ .value = valueNode, .pattern = patternExpr, .escape = escapeNode, .negated = negated, .glob = glob, .isRegexp = isRegexp, .isMatch = isMatch } };
    }

    fn collateNode(self: *Parser, inner: ast.Expr, name: []const u8) !ast.Expr {
        const node = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, inner);
            self.allocator.destroy(node);
        }
        node.* = inner;
        return .{ .collate = .{ .expr = node, .name = name } };
    }

    fn parseLike(self: *Parser) Error!ast.Expr {
        var left = try self.parseCmp();
        left = try self.parseCollateSuffix(left);
        while (true) {
            const negated = self.acceptWord("not");
            if (self.acceptWord("like")) {
                var pattern = try self.parseCmp();
                pattern = try self.parseCollateSuffix(pattern);
                left = try self.patternNode(left, pattern, try self.parseEscape(), negated, false);
            } else if (self.acceptWord("glob")) {
                var pattern = try self.parseCmp();
                pattern = try self.parseCollateSuffix(pattern);
                left = try self.patternNodeFull(left, pattern, null, negated, true, false, false);
            } else if (self.acceptWord("regexp")) {
                var pattern = try self.parseCmp();
                pattern = try self.parseCollateSuffix(pattern);
                left = try self.patternNodeFull(left, pattern, null, negated, false, true, false);
            } else if (self.acceptWord("match")) {
                var pattern = try self.parseCmp();
                pattern = try self.parseCollateSuffix(pattern);
                left = try self.patternNodeFull(left, pattern, null, negated, false, false, true);
            } else if (self.acceptWord("in")) {
                try self.requireTag(.lparen);
                if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
                    const start = self.current().position;
                    _ = self.advance();
                    var sub = self.parseSelectOrCompound() catch |err| return asParserError(err);
                    defer ast.deinit(self.allocator, &sub);
                    const end = self.current().position;
                    try self.requireTag(.rparen);
                    const leftNode = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(leftNode);
                    leftNode.* = left;
                    left = .{ .inSubquery = .{ .expr = leftNode, .subquery = try self.copy(self.source[start..end]), .negated = negated } };
                } else {
                    var list = std.ArrayList(ast.Expr).empty;
                    errdefer {
                        for (list.items) |item| freeParserExpr(self.allocator, item);
                        list.deinit(self.allocator);
                    }
                    while (true) {
                        try list.append(self.allocator, try self.parseExpr());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    const leftNode = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(leftNode);
                    leftNode.* = left;
                    left = .{ .inList = .{ .expr = leftNode, .list = try list.toOwnedSlice(self.allocator), .negated = negated } };
                }
            } else if (self.acceptWord("is")) {
                var isNot = negated or self.acceptWord("not");
                if (self.acceptWord("distinct")) {
                    try self.requireWord("from");
                    isNot = !isNot;
                }
                var right = try self.parseCmp();
                right = try self.parseCollateSuffix(right);
                left = try self.binaryNode(if (isNot) .isNotOp else .isOp, left, right);
            } else if (self.acceptWord("between")) {
                const lower = try self.parseCmp();
                try self.requireWord("and");
                const upper = try self.parseCmp();
                const leftCopy = try ast.cloneOwnedExpr(self.allocator, left);
                if (!negated) {
                    const geNode = try self.binaryNode(.greaterEqual, left, lower);
                    const leNode = try self.binaryNode(.lessEqual, leftCopy, upper);
                    left = try self.binaryNode(.logicalAnd, geNode, leNode);
                } else {
                    const ltNode = try self.binaryNode(.less, left, lower);
                    const gtNode = try self.binaryNode(.greater, leftCopy, upper);
                    left = try self.binaryNode(.logicalOr, ltNode, gtNode);
                }
            } else {
                if (negated) return Error.UnexpectedToken;
                return left;
            }
            left = try self.parseCollateSuffix(left);
        }
    }

    fn parseCollateSuffix(self: *Parser, inner: ast.Expr) !ast.Expr {
        if (!self.acceptWord("collate")) return inner;
        const name = try self.word();
        return self.collateNode(inner, name);
    }

    fn parseCmp(self: *Parser) Error!ast.Expr {
        var left = try self.parseBitOr();
        while (true) {
            const op: ?ast.BinaryOp = if (self.acceptTag(.equal))
                .equal
            else if (self.acceptTag(.notEqual))
                .notEqual
            else if (self.acceptTag(.less))
                .less
            else if (self.acceptTag(.lessEqual))
                .lessEqual
            else if (self.acceptTag(.greater))
                .greater
            else if (self.acceptTag(.greaterEqual))
                .greaterEqual
            else
                null;
            if (op == null) return left;
            left = try self.binaryNode(op.?, left, try self.parseBitOr());
        }
    }

    fn parseBitOr(self: *Parser) Error!ast.Expr {
        var left = try self.parseBitAnd();
        while (self.acceptTag(.pipe)) {
            left = try self.binaryNode(.bitOr, left, try self.parseBitAnd());
        }
        return left;
    }

    fn parseBitAnd(self: *Parser) Error!ast.Expr {
        var left = try self.parseShift();
        while (self.acceptTag(.amp)) {
            left = try self.binaryNode(.bitAnd, left, try self.parseShift());
        }
        return left;
    }

    fn parseShift(self: *Parser) Error!ast.Expr {
        var left = try self.parseAdd();
        while (true) {
            if (self.acceptTag(.lshift)) {
                left = try self.binaryNode(.shiftLeft, left, try self.parseAdd());
            } else if (self.acceptTag(.rshift)) {
                left = try self.binaryNode(.shiftRight, left, try self.parseAdd());
            } else break;
        }
        return left;
    }

    fn parseAdd(self: *Parser) Error!ast.Expr {
        var left = try self.parseMul();
        while (true) {
            if (self.acceptTag(.plus)) {
                left = try self.binaryNode(.add, left, try self.parseMul());
            } else if (self.acceptTag(.minus)) {
                left = try self.binaryNode(.subtract, left, try self.parseMul());
            } else break;
        }
        return left;
    }

    fn parseMul(self: *Parser) Error!ast.Expr {
        var left = try self.parseConcat();
        while (true) {
            if (self.acceptTag(.star)) {
                left = try self.binaryNode(.multiply, left, try self.parseConcat());
            } else if (self.acceptTag(.slash)) {
                left = try self.binaryNode(.divide, left, try self.parseConcat());
            } else if (self.acceptTag(.percent)) {
                left = try self.binaryNode(.modulo, left, try self.parseConcat());
            } else break;
        }
        return left;
    }

    fn parseConcat(self: *Parser) Error!ast.Expr {
        var left = try self.parseUnary();
        while (self.acceptTag(.concat)) {
            left = try self.binaryNode(.concat, left, try self.parseUnary());
        }
        return left;
    }

    fn parseUnary(self: *Parser) Error!ast.Expr {
        if (self.acceptWord("not")) return self.unaryNode(.logicalNot, try self.parseUnary());
        if (self.acceptTag(.minus)) {
            const saved = self.index;
            var depth: usize = 0;
            while (self.current().tag == .lparen) : (depth += 1) _ = self.advance();
            if (self.current().tag == .number and isMinIntMagnitude(self.current().text)) {
                _ = self.advance();
                var closed: usize = 0;
                while (closed < depth and self.current().tag == .rparen) : (closed += 1) _ = self.advance();
                if (closed == depth) return .{ .literal = .{ .integer = std.math.minInt(i64) } };
            }
            self.index = saved;
            return self.unaryNode(.negate, try self.parseUnary());
        }
        if (self.acceptTag(.plus)) return self.unaryNode(.positive, try self.parseUnary());
        if (self.acceptTag(.tilde)) return self.unaryNode(.bitNot, try self.parseUnary());
        return self.parseLiteral();
    }

    fn isMinIntMagnitude(text: []const u8) bool {
        var digits = text;
        while (digits.len != 0 and digits[0] == '0') digits = digits[1..];
        if (digits.len == 0) return false;
        if (digits.len != 19) return false;
        return std.mem.eql(u8, digits, "9223372036854775808");
    }

    fn parseCase(self: *Parser) !ast.Expr {
        var base: ?*const ast.Expr = null;
        errdefer if (base) |node| {
            freeParserExpr(self.allocator, node.*);
            self.allocator.destroy(node);
        };
        if (!(self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "when"))) {
            const baseNode = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(baseNode);
            baseNode.* = try self.parseExpr();
            base = baseNode;
        }
        var whens = std.ArrayList(ast.CaseWhen).empty;
        errdefer {
            for (whens.items) |item| {
                freeParserExpr(self.allocator, item.condition);
                freeParserExpr(self.allocator, item.result);
            }
            whens.deinit(self.allocator);
        }
        while (self.acceptWord("when")) {
            const condition = try self.parseExpr();
            errdefer freeParserExpr(self.allocator, condition);
            try self.requireWord("then");
            const result = try self.parseExpr();
            errdefer freeParserExpr(self.allocator, result);
            try whens.append(self.allocator, .{ .condition = condition, .result = result });
        }
        if (whens.items.len == 0) return Error.UnexpectedToken;
        var otherwise: ?*const ast.Expr = null;
        errdefer if (otherwise) |node| {
            freeParserExpr(self.allocator, node.*);
            self.allocator.destroy(node);
        };
        if (self.acceptWord("else")) {
            const elseNode = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(elseNode);
            elseNode.* = try self.parseExpr();
            otherwise = elseNode;
        }
        try self.requireWord("end");
        return .{ .caseExpr = .{ .base = base, .whens = try whens.toOwnedSlice(self.allocator), .otherwise = otherwise } };
    }

    fn parseReturning(self: *Parser) ![]const ast.Projection {
        if (!self.acceptWord("returning")) return &.{};
        var projections = std.ArrayList(ast.Projection).empty;
        errdefer {
            for (projections.items) |item| freeParserExpr(self.allocator, item.expr);
            projections.deinit(self.allocator);
        }
        while (true) {
            const expr = try self.parseExpr();
            var alias: ?[]const u8 = null;
            if (self.acceptWord("as")) {
                alias = try self.word();
            } else if (self.current().tag == .word and !std.ascii.eqlIgnoreCase(self.current().text, ";") and self.current().tag != .semicolon) {
                alias = try self.word();
            }
            try projections.append(self.allocator, .{ .expr = expr, .alias = alias });
            if (!self.acceptTag(.comma)) break;
        }
        // RETURNING output is capped at 2000 columns like SELECT.
        if (projections.items.len > limits.max_columns) return error.SqlTooBig;
        return try projections.toOwnedSlice(self.allocator);
    }

    fn parseInsert(self: *Parser) !ast.Statement {
        var conflict: ast.ConflictPolicy = .none;
        var upsertColumns: []const []const u8 = &.{};
        var upsertValues: []const ast.Expr = &.{};
        var upsertWhere: ?ast.Conditions = null;
        if (self.acceptWord("or")) {
            if (self.acceptWord("ignore")) conflict = .ignore else if (self.acceptWord("replace")) conflict = .replace else if (self.acceptWord("abort")) conflict = .abort else if (self.acceptWord("fail")) conflict = .fail else if (self.acceptWord("rollback")) conflict = .rollback else return Error.UnexpectedToken;
        }
        try self.requireWord("into");
        const table = try self.tableName();
        var columns = std.ArrayList([]const u8).empty;
        if (self.acceptTag(.lparen)) {
            while (true) {
                try columns.append(self.allocator, try self.word());
                if (!self.acceptTag(.comma)) break;
            }
            try self.requireTag(.rparen);
        }
        if (self.acceptWord("default")) {
            try self.requireWord("values");
            const emptyRow = try self.allocator.alloc(ast.Expr, 0);
            var defaultRows = try self.allocator.alloc([]const ast.Expr, 1);
            defaultRows[0] = emptyRow;
            const returning = try self.parseReturning();
            return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = defaultRows, .conflict = conflict, .returning = returning } };
        }
        if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
            const selectStart = self.current().position;
            _ = self.advance();
            var query = try self.parseSelect();
            defer ast.deinit(self.allocator, &query);
            const selectEnd = self.current().position;
            const emptyRows = try self.allocator.alloc([]const ast.Expr, 0);
            var conflictTargetColumns = std.ArrayList([]const u8).empty;
            var conflictTargetWhere: ?ast.Conditions = null;
            if (self.acceptWord("on")) {
                try self.requireWord("conflict");
                if (self.acceptTag(.lparen)) {
                    while (true) {
                        try conflictTargetColumns.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                }
                if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) conflictTargetWhere = try self.parseCondition();
                try self.requireWord("do");
                if (self.acceptWord("nothing")) {
                    conflict = .ignore;
                } else {
                    try self.requireWord("update");
                    try self.requireWord("set");
                    var names = std.ArrayList([]const u8).empty;
                    var expressions = std.ArrayList(ast.Expr).empty;
                    while (true) {
                        try names.append(self.allocator, try self.word());
                        try self.requireTag(.equal);
                        try expressions.append(self.allocator, try self.parseExpr());
                        if (!self.acceptTag(.comma)) break;
                    }
                    upsertColumns = try names.toOwnedSlice(self.allocator);
                    upsertValues = try expressions.toOwnedSlice(self.allocator);
                    conflict = .update;
                    if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) upsertWhere = try self.parseCondition();
                }
            }
            const returning = try self.parseReturning();
            return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = emptyRows, .selectSql = try self.copy(self.source[selectStart..selectEnd]), .conflict = conflict, .conflictTargetColumns = try conflictTargetColumns.toOwnedSlice(self.allocator), .conflictTargetWhere = conflictTargetWhere, .upsertColumns = upsertColumns, .upsertValues = upsertValues, .upsertWhere = upsertWhere, .returning = returning } };
        }
        try self.requireWord("values");
        var rows = std.ArrayList([]const ast.Expr).empty;
        while (true) {
            try self.requireTag(.lparen);
            var row = std.ArrayList(ast.Expr).empty;
            while (true) {
                try row.append(self.allocator, try self.parseExpr());
                if (!self.acceptTag(.comma)) break;
            }
            try self.requireTag(.rparen);
            try rows.append(self.allocator, try row.toOwnedSlice(self.allocator));
            if (!self.acceptTag(.comma)) break;
        }
        var conflictTargetColumns = std.ArrayList([]const u8).empty;
        var conflictTargetWhere: ?ast.Conditions = null;
        if (self.acceptWord("on")) {
            try self.requireWord("conflict");
            if (self.acceptTag(.lparen)) {
                while (true) {
                    try conflictTargetColumns.append(self.allocator, try self.word());
                    if (!self.acceptTag(.comma)) break;
                }
                try self.requireTag(.rparen);
            }
            if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) conflictTargetWhere = try self.parseCondition();
            try self.requireWord("do");
            if (self.acceptWord("nothing")) {
                conflict = .ignore;
            } else {
                try self.requireWord("update");
                try self.requireWord("set");
                var names = std.ArrayList([]const u8).empty;
                var expressions = std.ArrayList(ast.Expr).empty;
                while (true) {
                    try names.append(self.allocator, try self.word());
                    try self.requireTag(.equal);
                    try expressions.append(self.allocator, try self.parseExpr());
                    if (!self.acceptTag(.comma)) break;
                }
                upsertColumns = try names.toOwnedSlice(self.allocator);
                upsertValues = try expressions.toOwnedSlice(self.allocator);
                conflict = .update;
                if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) upsertWhere = try self.parseCondition();
            }
        }
        const returning = try self.parseReturning();
        return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = try rows.toOwnedSlice(self.allocator), .conflict = conflict, .conflictTargetColumns = try conflictTargetColumns.toOwnedSlice(self.allocator), .conflictTargetWhere = conflictTargetWhere, .upsertColumns = upsertColumns, .upsertValues = upsertValues, .upsertWhere = upsertWhere, .returning = returning } };
    }

    fn parseCondition(self: *Parser) anyerror!?ast.Conditions {
        if (!self.acceptWord("where")) return null;
        return try self.parseConditionRest();
    }

    fn parseConditionRest(self: *Parser) anyerror!?ast.Conditions {
        var conditions = std.ArrayList(ast.Condition).empty;
        var joinOr = false;
        while (true) {
            var leadingNot = false;
            if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "not") and self.index + 1 < self.tokens.len) {
                const next = self.tokens[self.index + 1];
                if (next.tag == .word and (std.ascii.eqlIgnoreCase(next.text, "exists") or std.ascii.eqlIgnoreCase(next.text, "like") or std.ascii.eqlIgnoreCase(next.text, "glob") or std.ascii.eqlIgnoreCase(next.text, "regexp") or std.ascii.eqlIgnoreCase(next.text, "match") or std.ascii.eqlIgnoreCase(next.text, "between") or std.ascii.eqlIgnoreCase(next.text, "in"))) {} else if (!(next.tag == .word and std.ascii.eqlIgnoreCase(next.text, "exists"))) {
                    _ = self.advance();
                    leadingNot = true;
                    if (self.acceptTag(.lparen)) {
                        const inner = try self.parseExpr();
                        try self.requireTag(.rparen);
                        try conditions.append(self.allocator, .{ .column = "", .op = .equal, .value = inner, .leftExpr = .{ .literal = .{ .integer = 0 } }, .joinOr = joinOr, .negated = false });
                        if (self.acceptWord("or")) {
                            joinOr = true;
                        } else if (self.acceptWord("and")) {
                            joinOr = false;
                        } else break;
                        continue;
                    }
                }
            }
            if (self.acceptWord("not")) {
                if (self.acceptWord("exists")) {
                    try self.requireTag(.lparen);
                    const start = self.current().position;
                    try self.requireWord("select");
                    var subquery = try self.parseSelect();
                    defer ast.deinit(self.allocator, &subquery);
                    const end = self.current().position;
                    try self.requireTag(.rparen);
                    try conditions.append(self.allocator, .{ .column = "", .op = .notExists, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .joinOr = joinOr, .negated = leadingNot });
                } else {
                    return Error.UnexpectedToken;
                }
            } else if (self.acceptWord("exists")) {
                try self.requireTag(.lparen);
                const start = self.current().position;
                try self.requireWord("select");
                var subquery = try self.parseSelect();
                defer ast.deinit(self.allocator, &subquery);
                const end = self.current().position;
                try self.requireTag(.rparen);
                try conditions.append(self.allocator, .{ .column = "", .op = .exists, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .joinOr = joinOr, .negated = leadingNot });
            } else {
                var leftExpr: ?ast.Expr = null;
                var column: []const u8 = undefined;
                if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "case")) {
                    _ = self.advance();
                    leftExpr = try self.parseCase();
                    column = "";
                } else if (self.acceptTag(.lparen)) {
                    leftExpr = try self.parseExpr();
                    try self.requireTag(.rparen);
                    column = "";
                } else if (self.current().tag == .word and self.index + 1 < self.tokens.len and self.tokens[self.index + 1].tag == .lparen) {
                    leftExpr = try self.parseLiteral();
                    column = "";
                } else if (self.current().tag == .number or self.current().tag == .string) {
                    leftExpr = try self.parseLiteral();
                    column = "";
                } else {
                    const qualified = try self.qualifiedName();
                    column = if (qualified.table.len == 0) qualified.column else blk: {
                        const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ qualified.table, qualified.column });
                        defer self.allocator.free(combined);
                        break :blk try self.copy(combined);
                    };
                }
                var collate: ?[]const u8 = null;
                if (self.acceptWord("collate")) collate = try self.word();
                if (self.acceptWord("is")) {
                    const isNot = self.acceptWord("not");
                    if (self.acceptWord("null")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = if (isNot) .isNotNull else .isNull, .value = .{ .literal = .null }, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("distinct")) {
                        try self.requireWord("from");
                        try conditions.append(self.allocator, .{ .column = column, .op = if (isNot) .isNotDistinct else .isDistinct, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else {
                        try conditions.append(self.allocator, .{ .column = column, .op = if (isNot) .isNotValue else .isValue, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    }
                } else if (self.acceptWord("between")) {
                    const lower = try self.parseCmp();
                    try self.requireWord("and");
                    try conditions.append(self.allocator, .{ .column = column, .op = .between, .value = lower, .value2 = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                } else if (self.acceptWord("not")) {
                    if (self.acceptWord("like")) {
                        const pattern = try self.parseCmp();
                        try conditions.append(self.allocator, .{ .column = column, .op = .notLike, .value = pattern, .escape = try self.parseEscape(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("glob")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = .notGlob, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("regexp")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = .notRegexp, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("match")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = .notMatch, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("between")) {
                        const lower = try self.parseCmp();
                        try self.requireWord("and");
                        try conditions.append(self.allocator, .{ .column = column, .op = .notBetween, .value = lower, .value2 = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else {
                        try self.requireWord("in");
                        try self.requireTag(.lparen);
                        if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
                            const start = self.current().position;
                            try self.requireWord("select");
                            var subquery = self.parseSelectOrCompound() catch |err| return asParserError(err);
                            defer ast.deinit(self.allocator, &subquery);
                            const end = self.current().position;
                            try self.requireTag(.rparen);
                            try conditions.append(self.allocator, .{ .column = column, .op = .notIn, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                        } else {
                            var values = std.ArrayList(ast.Expr).empty;
                            errdefer {
                                for (values.items) |item| freeParserExpr(self.allocator, item);
                                values.deinit(self.allocator);
                            }
                            while (true) {
                                try values.append(self.allocator, try self.parseCmp());
                                if (!self.acceptTag(.comma)) break;
                            }
                            try self.requireTag(.rparen);
                            try conditions.append(self.allocator, .{ .column = column, .op = .notIn, .value = .{ .literal = .null }, .listValues = try values.toOwnedSlice(self.allocator), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                        }
                    }
                } else if (self.acceptWord("in")) {
                    try self.requireTag(.lparen);
                    if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
                        const start = self.current().position;
                        try self.requireWord("select");
                        var subquery = self.parseSelectOrCompound() catch |err| return asParserError(err);
                        defer ast.deinit(self.allocator, &subquery);
                        const end = self.current().position;
                        try self.requireTag(.rparen);
                        try conditions.append(self.allocator, .{ .column = column, .op = .in, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else {
                        var values = std.ArrayList(ast.Expr).empty;
                        errdefer {
                            for (values.items) |item| freeParserExpr(self.allocator, item);
                            values.deinit(self.allocator);
                        }
                        while (true) {
                            try values.append(self.allocator, try self.parseCmp());
                            if (!self.acceptTag(.comma)) break;
                        }
                        try self.requireTag(.rparen);
                        try conditions.append(self.allocator, .{ .column = column, .op = .in, .value = .{ .literal = .null }, .listValues = try values.toOwnedSlice(self.allocator), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    }
                } else if (self.acceptTag(.equal)) {
                    const pattern = try self.parseCmp();
                    var tailCollate: ?[]const u8 = null;
                    if (self.acceptWord("collate")) tailCollate = try self.word();
                    try conditions.append(self.allocator, .{ .column = column, .op = .equal, .value = pattern, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = tailCollate orelse collate });
                } else if (self.acceptTag(.notEqual)) {
                    const pattern = try self.parseCmp();
                    var tailCollate: ?[]const u8 = null;
                    if (self.acceptWord("collate")) tailCollate = try self.word();
                    try conditions.append(self.allocator, .{ .column = column, .op = .notEqual, .value = pattern, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = tailCollate orelse collate });
                } else if (self.acceptTag(.less)) {
                    const pattern = try self.parseCmp();
                    var tailCollate: ?[]const u8 = null;
                    if (self.acceptWord("collate")) tailCollate = try self.word();
                    try conditions.append(self.allocator, .{ .column = column, .op = .less, .value = pattern, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = tailCollate orelse collate });
                } else if (self.acceptTag(.lessEqual)) {
                    const pattern = try self.parseCmp();
                    var tailCollate: ?[]const u8 = null;
                    if (self.acceptWord("collate")) tailCollate = try self.word();
                    try conditions.append(self.allocator, .{ .column = column, .op = .lessEqual, .value = pattern, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = tailCollate orelse collate });
                } else if (self.acceptTag(.greater)) {
                    const pattern = try self.parseCmp();
                    var tailCollate: ?[]const u8 = null;
                    if (self.acceptWord("collate")) tailCollate = try self.word();
                    try conditions.append(self.allocator, .{ .column = column, .op = .greater, .value = pattern, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = tailCollate orelse collate });
                } else if (self.acceptTag(.greaterEqual)) {
                    const pattern = try self.parseCmp();
                    var tailCollate: ?[]const u8 = null;
                    if (self.acceptWord("collate")) tailCollate = try self.word();
                    try conditions.append(self.allocator, .{ .column = column, .op = .greaterEqual, .value = pattern, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = tailCollate orelse collate });
                } else if (self.acceptWord("like")) {
                    const pattern = try self.parseCmp();
                    const escape: ?ast.Expr = try self.parseEscape();
                    var tailCollate: ?[]const u8 = null;
                    if (self.acceptWord("collate")) tailCollate = try self.word();
                    const useCollate = tailCollate orelse collate;
                    try conditions.append(self.allocator, .{ .column = column, .op = .like, .value = pattern, .escape = escape, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = useCollate });
                } else if (self.acceptWord("glob")) {
                    const pattern = try self.parseCmp();
                    try conditions.append(self.allocator, .{ .column = column, .op = .glob, .value = pattern, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                } else if (self.acceptWord("regexp")) {
                    const pattern = try self.parseCmp();
                    try conditions.append(self.allocator, .{ .column = column, .op = .regexp, .value = pattern, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                } else if (self.acceptWord("match")) {
                    const pattern = try self.parseCmp();
                    try conditions.append(self.allocator, .{ .column = column, .op = .match, .value = pattern, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                } else {
                    try conditions.append(self.allocator, .{ .column = column, .op = .isTrue, .value = .{ .literal = .null }, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                }
            }
            if (self.acceptWord("or")) {
                joinOr = true;
            } else if (self.acceptWord("and")) {
                joinOr = false;
            } else break;
        }
        return try conditions.toOwnedSlice(self.allocator);
    }

    fn parseEscape(self: *Parser) !?ast.Expr {
        if (!self.acceptWord("escape")) return null;
        return try self.parseCmp();
    }

    fn isReservedQueryKeyword(text: []const u8) bool {
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

    fn parseSelect(self: *Parser) !ast.Statement {
        var projections = std.ArrayList(ast.Projection).empty;
        errdefer {
            for (projections.items) |item| freeParserExpr(self.allocator, item.expr);
            projections.deinit(self.allocator);
        }
        const distinct = self.acceptWord("distinct");
        if (!distinct) _ = self.acceptWord("all");
        while (true) {
            if (self.current().tag == .word and !self.current().quoted and std.ascii.eqlIgnoreCase(self.current().text, "from")) return Error.UnexpectedToken;
            const expr = try self.parseExpr();
            var alias: ?[]const u8 = null;
            if (self.acceptWord("as")) {
                alias = try self.word();
            } else if (self.current().tag == .word and (self.current().quoted or !isReservedQueryKeyword(self.current().text)) and self.current().tag != .semicolon and (self.current().quoted or !std.ascii.eqlIgnoreCase(self.current().text, "from"))) {
                alias = try self.word();
            }
            try projections.append(self.allocator, .{ .expr = expr, .alias = alias });
            if (!self.acceptTag(.comma)) break;
        }
        // SELECT output is capped at 2000 columns (`SELECT *` expands
        // later against live tables, validated at CREATE TABLE time).
        if (projections.items.len > limits.max_columns) return error.SqlTooBig;
        var table: ?[]const u8 = null;
        var tableAlias: ?[]const u8 = null;
        var fromSubquery: ?[]const u8 = null;
        if (self.acceptWord("from")) {
            if (self.acceptTag(.lparen)) {
                const subStart = self.current().position;
                try self.requireWord("select");
                var subStmt = try self.parseSelectOrCompound();
                ast.deinit(self.allocator, &subStmt);
                try self.requireTag(.rparen);
                const subEnd = self.tokens[self.index - 1].position;
                fromSubquery = try self.copy(std.mem.trim(u8, self.source[subStart..subEnd], " \t\r\n"));
                if (self.acceptWord("as")) {
                    tableAlias = try self.word();
                } else if (self.current().tag == .word and (self.current().quoted or !isReservedQueryKeyword(self.current().text)) and self.current().tag != .semicolon) {
                    tableAlias = try self.word();
                }
                table = tableAlias orelse "__subquery__";
            } else {
                table = try self.tableName();
                if (self.acceptWord("as")) {
                    tableAlias = try self.word();
                } else if (self.current().tag == .word and (self.current().quoted or !isReservedQueryKeyword(self.current().text)) and self.current().tag != .semicolon) {
                    tableAlias = try self.word();
                }
            }
        }
        var joins = std.ArrayList(ast.Join).empty;
        defer joins.deinit(self.allocator);
        if (table != null) {
            while (true) {
                const natural = self.acceptWord("natural");
                var kind: ?ast.JoinKind = null;
                if (self.acceptWord("inner")) {
                    kind = .inner;
                } else if (self.acceptWord("left")) {
                    _ = self.acceptWord("outer");
                    kind = .left;
                } else if (self.acceptWord("right")) {
                    _ = self.acceptWord("outer");
                    kind = .right;
                } else if (self.acceptWord("full")) {
                    _ = self.acceptWord("outer");
                    kind = .full;
                } else if (self.acceptWord("cross")) {
                    kind = .cross;
                }
                if (kind == null and !natural and !self.acceptWord("join")) break;
                _ = self.acceptWord("join");
                const joinedTable = try self.tableName();
                var joinedAlias: ?[]const u8 = null;
                if (self.acceptWord("as")) {
                    joinedAlias = try self.word();
                } else if (self.current().tag == .word and (self.current().quoted or !isReservedQueryKeyword(self.current().text)) and self.current().tag != .semicolon) {
                    joinedAlias = try self.word();
                }
                const effectiveKind: ast.JoinKind = kind orelse .inner;
                if (effectiveKind != .cross and !natural) {
                    if (self.acceptWord("using")) {
                        try self.requireTag(.lparen);
                        var usingCols = std.ArrayList([]const u8).empty;
                        defer usingCols.deinit(self.allocator);
                        while (true) {
                            try usingCols.append(self.allocator, try self.word());
                            if (!self.acceptTag(.comma)) break;
                        }
                        try self.requireTag(.rparen);
                        if (usingCols.items.len == 1) {
                            const usingCol = usingCols.items[0];
                            try joins.append(self.allocator, .{ .kind = effectiveKind, .table = joinedTable, .tableAlias = joinedAlias, .leftTable = table.?, .leftColumn = usingCol, .rightTable = joinedTable, .rightColumn = usingCol, .mergeOutput = true });
                        } else {
                            const owned = try usingCols.toOwnedSlice(self.allocator);
                            try joins.append(self.allocator, .{ .kind = effectiveKind, .table = joinedTable, .tableAlias = joinedAlias, .leftTable = table.?, .leftColumn = "", .rightTable = joinedTable, .rightColumn = "", .mergeOutput = true, .usingColumns = owned });
                        }
                    } else {
                        try self.requireWord("on");
                        const left = try self.qualifiedName();
                        try self.requireTag(.equal);
                        const right = try self.qualifiedName();
                        try joins.append(self.allocator, .{ .kind = effectiveKind, .table = joinedTable, .tableAlias = joinedAlias, .leftTable = left.table, .leftColumn = left.column, .rightTable = right.table, .rightColumn = right.column });
                    }
                } else {
                    try joins.append(self.allocator, .{ .kind = effectiveKind, .table = joinedTable, .tableAlias = joinedAlias, .leftTable = "", .leftColumn = "", .rightTable = "", .rightColumn = "", .mergeOutput = natural });
                }
            }
        }
        const condition = try self.parseCondition();
        var groupBy: ?[]const u8 = null;
        if (self.acceptWord("group")) {
            try self.requireWord("by");
            const groupQualifier = try self.word();
            if (self.acceptTag(.dot)) {
                const groupColumn = try self.word();
                if (self.acceptTag(.dot)) {
                    const groupThird = try self.word();
                    const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ groupQualifier, groupColumn, groupThird });
                    defer self.allocator.free(combined);
                    groupBy = try self.copy(combined);
                } else {
                    const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ groupQualifier, groupColumn });
                    defer self.allocator.free(combined);
                    groupBy = try self.copy(combined);
                }
            } else groupBy = groupQualifier;
        }
        var havingItems = std.ArrayList(ast.HavingItem).empty;
        errdefer {
            for (havingItems.items) |item| {
                freeParserExpr(self.allocator, item.left);
                freeParserExpr(self.allocator, item.right);
            }
            havingItems.deinit(self.allocator);
        }
        if (self.acceptWord("having")) {
            var joinOr = false;
            while (true) {
                const left = try self.parseBitOr();
                var op: ast.CompareOp = .isTrue;
                var right: ast.Expr = .{ .literal = .null };
                if (self.acceptTag(.equal)) {
                    op = .equal;
                    right = try self.parseBitOr();
                } else if (self.acceptTag(.notEqual)) {
                    op = .notEqual;
                    right = try self.parseBitOr();
                } else if (self.acceptTag(.less)) {
                    op = .less;
                    right = try self.parseBitOr();
                } else if (self.acceptTag(.lessEqual)) {
                    op = .lessEqual;
                    right = try self.parseBitOr();
                } else if (self.acceptTag(.greater)) {
                    op = .greater;
                    right = try self.parseBitOr();
                } else if (self.acceptTag(.greaterEqual)) {
                    op = .greaterEqual;
                    right = try self.parseBitOr();
                }
                try havingItems.append(self.allocator, .{ .left = left, .op = op, .right = right, .joinOr = joinOr });
                if (self.acceptWord("or")) {
                    joinOr = true;
                } else if (self.acceptWord("and")) {
                    joinOr = false;
                } else break;
            }
        }
        var having: ?ast.Having = null;
        errdefer if (having) |items| {
            for (items) |item| {
                freeParserExpr(self.allocator, item.left);
                freeParserExpr(self.allocator, item.right);
            }
            self.allocator.free(items);
        };
        if (havingItems.items.len != 0) having = try havingItems.toOwnedSlice(self.allocator);
        // WINDOW clause (after HAVING, before ORDER BY). Definitions resolve
        // left to right so later names may build on earlier ones; every
        // `OVER name` use in the projections/having/where is expanded into
        // a full spec copy, then the definitions are freed.
        var namedWindows = std.ArrayList(NamedWindowDef).empty;
        defer {
            for (namedWindows.items) |def| self.freeWindowSpec(def.spec);
            namedWindows.deinit(self.allocator);
        }
        if (self.acceptWord("window")) {
            while (true) {
                const defName = try self.word();
                try self.requireWord("as");
                var spec = try self.parseWindowSpec();
                errdefer self.freeWindowSpec(spec);
                if (spec.base) |baseName| {
                    const base = findNamedWindow(namedWindows.items, baseName) orelse return Error.InvalidSql;
                    const overlay = spec;
                    spec = try self.resolveWindowBase(overlay, base);
                }
                try namedWindows.append(self.allocator, .{ .name = defName, .spec = spec });
                if (!self.acceptTag(.comma)) break;
            }
            if (self.acceptWord("window")) return Error.InvalidSql;
        }
        for (projections.items) |*proj| {
            try self.resolveWindowRefs(&proj.expr, namedWindows.items);
        }
        if (having) |arms| {
            for (0..arms.len) |idx| {
                const item: *ast.HavingItem = @constCast(&arms[idx]);
                try self.resolveWindowRefs(&item.left, namedWindows.items);
                try self.resolveWindowRefs(&item.right, namedWindows.items);
            }
        }
        if (condition) |conds| try self.resolveWindowRefsInConditions(conds, namedWindows.items);
        var orders = std.ArrayList(ast.Order).empty;
        errdefer orders.deinit(self.allocator);
        if (self.acceptWord("order")) {
            try self.requireWord("by");
            while (true) {
                var orderColumn = try self.identifierOrNumber();
                while (self.acceptTag(.dot)) {
                    const orderPart = try self.word();
                    const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ orderColumn, orderPart });
                    defer self.allocator.free(combined);
                    orderColumn = try self.copy(combined);
                }
                const descending = self.acceptWord("desc");
                _ = self.acceptWord("asc");
                try orders.append(self.allocator, .{ .column = orderColumn, .descending = descending });
                if (!self.acceptTag(.comma)) break;
            }
        }
        return .{ .select = .{ .projections = try projections.toOwnedSlice(self.allocator), .table = table, .tableAlias = tableAlias, .fromSubquery = fromSubquery, .joins = if (joins.items.len == 0) &.{} else try joins.toOwnedSlice(self.allocator), .condition = condition, .groupBy = groupBy, .having = having, .orders = try orders.toOwnedSlice(self.allocator), .limit = null, .offset = null, .distinct = distinct } };
    }

    fn branchOrderStart(self: *Parser, endIndex: usize) ?usize {
        var j = endIndex;
        if (j == 0) return null;
        j -= 1;
        // Walk back over `key [ASC|DESC] (, key [ASC|DESC])*`, where each key
        // is a word/number with optional dotted qualifiers, then expect BY.
        // Quoted words are identifiers, never the ORDER/BY/ASC/DESC keywords.
        while (true) {
            if (self.tokens[j].tag == .word and !self.tokens[j].quoted and (std.ascii.eqlIgnoreCase(self.tokens[j].text, "desc") or std.ascii.eqlIgnoreCase(self.tokens[j].text, "asc"))) {
                if (j == 0) return null;
                j -= 1;
            }
            if (self.tokens[j].tag != .word and self.tokens[j].tag != .number) return null;
            while (j >= 2 and self.tokens[j - 1].tag == .dot and self.tokens[j - 2].tag == .word) j -= 2;
            if (j == 0) return null;
            j -= 1;
            if (self.tokens[j].tag == .comma) {
                if (j == 0) return null;
                j -= 1;
                continue;
            }
            if (self.tokens[j].tag != .word or self.tokens[j].quoted or !std.ascii.eqlIgnoreCase(self.tokens[j].text, "by")) return null;
            if (j == 0) return null;
            j -= 1;
            if (self.tokens[j].tag != .word or self.tokens[j].quoted or !std.ascii.eqlIgnoreCase(self.tokens[j].text, "order")) return null;
            return j;
        }
    }

    fn parseSelectOrCompound(self: *Parser) anyerror!ast.Statement {
        const startPos = self.tokens[self.index - 1].position;
        var selectStmt = try self.parseSelect();
        errdefer ast.deinit(self.allocator, &selectStmt);
        var hasCompound = false;
        var lastOp: ast.CompoundOp = .unionOp;
        var leftEnd: usize = 0;
        var rightStart: usize = 0;
        var rightEnd: usize = 0;
        var pendingBranchHadOrder = selectStmt.select.orders.len != 0;
        var lastBranchOrders: []const ast.Order = &.{};
        var lastBranchOrderStart: ?usize = null;
        var terms: usize = 1;
        while (true) {
            const op: ast.CompoundOp = if (self.acceptWord("union"))
                (if (self.acceptWord("all")) .unionAllOp else .unionOp)
            else if (self.acceptWord("intersect"))
                .intersectOp
            else if (self.acceptWord("except"))
                .exceptOp
            else
                break;

            if (pendingBranchHadOrder) return Error.InvalidSql;
            hasCompound = true;
            terms += 1;
            // Compound SELECTs cap at 500 UNION/INTERSECT/EXCEPT terms.
            if (terms > limits.max_compound_terms) return error.SqlTooBig;
            lastOp = op;
            leftEnd = self.tokens[self.index - if (op == .unionAllOp) @as(usize, 2) else @as(usize, 1)].position;
            rightStart = self.current().position;
            try self.requireWord("select");
            var nextStmt = try self.parseSelect();
            pendingBranchHadOrder = nextStmt.select.orders.len != 0;
            if (nextStmt.select.orders.len != 0) {
                lastBranchOrderStart = self.branchOrderStart(self.index) orelse return Error.InvalidSql;
                lastBranchOrders = try self.allocator.dupe(ast.Order, nextStmt.select.orders);
            }
            ast.deinit(self.allocator, &nextStmt);
            rightEnd = self.current().position;
        }
        var limit: ?usize = null;
        var offset: ?usize = null;
        if (self.acceptWord("limit")) {
            const token = self.advance();
            limit = std.fmt.parseInt(usize, token.text, 10) catch {
                if (lastBranchOrders.len != 0) self.allocator.free(lastBranchOrders);
                return Error.InvalidSql;
            };
        }
        if (self.acceptWord("offset")) {
            const token = self.advance();
            offset = std.fmt.parseInt(usize, token.text, 10) catch {
                if (lastBranchOrders.len != 0) self.allocator.free(lastBranchOrders);
                return Error.InvalidSql;
            };
        }
        if (hasCompound) {
            if (lastBranchOrderStart) |orderStart| rightEnd = self.tokens[orderStart].position;
            ast.deinit(self.allocator, &selectStmt);
            errdefer if (lastBranchOrders.len != 0) self.allocator.free(lastBranchOrders);
            return .{ .compoundSelect = .{
                .leftSql = try self.copy(std.mem.trim(u8, self.source[startPos..leftEnd], " \t\r\n")),
                .op = lastOp,
                .rightSql = try self.copy(std.mem.trim(u8, self.source[rightStart..rightEnd], " \t\r\n")),
                .orders = lastBranchOrders,
                .limit = limit,
                .offset = offset,
            } };
        }
        selectStmt.select.limit = limit;
        selectStmt.select.offset = offset;
        return selectStmt;
    }

    fn parseUpdate(self: *Parser) !ast.Statement {
        var updateConflict: ast.ConflictPolicy = .none;
        if (self.acceptWord("or")) {
            if (self.acceptWord("ignore")) updateConflict = .ignore else if (self.acceptWord("replace")) updateConflict = .replace else if (self.acceptWord("abort")) updateConflict = .abort else if (self.acceptWord("fail")) updateConflict = .fail else if (self.acceptWord("rollback")) updateConflict = .rollback else return Error.UnexpectedToken;
        }
        const table = try self.tableName();
        try self.requireWord("set");
        var columns = std.ArrayList([]const u8).empty;
        var values = std.ArrayList(ast.Expr).empty;
        while (true) {
            try columns.append(self.allocator, try self.word());
            try self.requireTag(.equal);
            try values.append(self.allocator, try self.parseExpr());
            if (!self.acceptTag(.comma)) break;
        }
        var from: ?ast.UpdateFrom = null;
        var condition: ?ast.Conditions = null;
        if (self.acceptWord("from")) {
            const sourceTable = try self.tableName();
            try self.requireWord("where");
            const pairStart = self.index;
            if (self.tryParseUpdatePair()) |pair| {
                if (self.acceptWord("and")) {
                    condition = try self.parseConditionRest();
                    from = .{ .table = sourceTable, .leftTable = pair.leftTable, .leftColumn = pair.leftColumn, .rightTable = pair.rightTable, .rightColumn = pair.rightColumn };
                } else {
                    const next = self.current();
                    const done = next.tag == .eof or next.tag == .semicolon or (next.tag == .word and std.ascii.eqlIgnoreCase(next.text, "returning"));
                    if (done) {
                        from = .{ .table = sourceTable, .leftTable = pair.leftTable, .leftColumn = pair.leftColumn, .rightTable = pair.rightTable, .rightColumn = pair.rightColumn };
                    } else {
                        self.index = pairStart;
                        from = .{ .table = sourceTable, .leftTable = "", .leftColumn = "", .rightTable = "", .rightColumn = "" };
                        condition = try self.parseConditionRest();
                    }
                }
            } else {
                from = .{ .table = sourceTable, .leftTable = "", .leftColumn = "", .rightTable = "", .rightColumn = "" };
                condition = try self.parseConditionRest();
            }
        } else condition = try self.parseCondition();
        const returning = try self.parseReturning();
        return .{ .update = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .values = try values.toOwnedSlice(self.allocator), .condition = condition, .from = from, .conflict = updateConflict, .returning = returning } };
    }

    fn tryParseUpdatePair(self: *Parser) ?struct { leftTable: []const u8, leftColumn: []const u8, rightTable: []const u8, rightColumn: []const u8 } {
        const saved = self.index;
        const left = self.qualifiedName() catch {
            self.index = saved;
            return null;
        };
        if (!self.acceptTag(.equal)) {
            self.index = saved;
            return null;
        }
        const right = self.qualifiedName() catch {
            self.index = saved;
            return null;
        };
        if (right.table.len == 0) {
            self.index = saved;
            return null;
        }
        return .{ .leftTable = left.table, .leftColumn = left.column, .rightTable = right.table, .rightColumn = right.column };
    }

    fn parseDelete(self: *Parser) !ast.Statement {
        try self.requireWord("from");
        const table = try self.tableName();
        const condition = try self.parseCondition();
        const returning = try self.parseReturning();
        return .{ .delete = .{ .table = table, .condition = condition, .returning = returning } };
    }
};

test "parser builds insert and select statements" {
    var parser = try Parser.init(std.testing.allocator, "INSERT INTO users (name) VALUES ('A');");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .insert);
}

test "parser parses compound select queries with limit and offset" {
    var parser = try Parser.init(std.testing.allocator, "SELECT 1 UNION ALL SELECT 2 LIMIT 10 OFFSET 5;");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .compoundSelect);
    try std.testing.expectEqual(ast.CompoundOp.unionAllOp, statement.compoundSelect.op);
    try std.testing.expectEqual(@as(?usize, 10), statement.compoundSelect.limit);
    try std.testing.expectEqual(@as(?usize, 5), statement.compoundSelect.offset);
    var chained = try Parser.init(std.testing.allocator, "SELECT 1 UNION SELECT 2 UNION SELECT 3 ORDER BY 1;");
    defer chained.deinit();
    var chainedStmt = try chained.parse();
    defer ast.deinit(std.testing.allocator, &chainedStmt);
    try std.testing.expect(chainedStmt == .compoundSelect);
    try std.testing.expectEqual(ast.CompoundOp.unionOp, chainedStmt.compoundSelect.op);
    try std.testing.expectEqualStrings("SELECT 1 UNION SELECT 2", chainedStmt.compoundSelect.leftSql);
    try std.testing.expectEqualStrings("SELECT 3", chainedStmt.compoundSelect.rightSql);
    try std.testing.expect(chainedStmt.compoundSelect.orders.len == 1);
    try std.testing.expectEqualStrings("1", chainedStmt.compoundSelect.orders[0].column);
    var branchOrdered = try Parser.init(std.testing.allocator, "SELECT 1 ORDER BY 1 UNION SELECT 2;");
    defer branchOrdered.deinit();
    if (branchOrdered.parse()) |stale| {
        var owned = stale;
        ast.deinit(std.testing.allocator, &owned);
        return error.ExpectedBranchOrderRejected;
    } else |err| {
        try std.testing.expectEqual(Error.InvalidSql, err);
    }
}

test "parser parses joins with aliases, outer keywords and using" {
    var p1 = try Parser.init(std.testing.allocator, "SELECT u.name, o.id FROM users u LEFT OUTER JOIN orders o ON u.id = o.user_id;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .select);
    try std.testing.expectEqualStrings("u", s1.select.tableAlias.?);
    try std.testing.expect(s1.select.joins.len == 1);
    try std.testing.expectEqual(ast.JoinKind.left, s1.select.joins[0].kind);
    try std.testing.expectEqualStrings("o", s1.select.joins[0].tableAlias.?);

    var p2 = try Parser.init(std.testing.allocator, "SELECT * FROM a JOIN b USING (id);");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .select);
    try std.testing.expect(s2.select.joins.len == 1);
    try std.testing.expectEqualStrings("id", s2.select.joins[0].leftColumn);
    try std.testing.expectEqual(@as(usize, 0), s2.select.joins[0].usingColumns.len);

    var p2m = try Parser.init(std.testing.allocator, "SELECT * FROM a JOIN b USING (id, grp);");
    defer p2m.deinit();
    var s2m = try p2m.parse();
    defer ast.deinit(std.testing.allocator, &s2m);
    try std.testing.expect(s2m == .select);
    try std.testing.expect(s2m.select.joins.len == 1);
    try std.testing.expectEqual(@as(usize, 2), s2m.select.joins[0].usingColumns.len);
    try std.testing.expectEqualStrings("id", s2m.select.joins[0].usingColumns[0]);
    try std.testing.expectEqualStrings("grp", s2m.select.joins[0].usingColumns[1]);

    var p3 = try Parser.init(std.testing.allocator, "SELECT * FROM a NATURAL JOIN b;");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .select);
    try std.testing.expect(s3.select.joins.len == 1);
}

test "parser parses chained joins" {
    var parser = try Parser.init(std.testing.allocator, "SELECT u.name FROM users u JOIN orders o ON u.id = o.uid LEFT JOIN items i ON o.item = i.name CROSS JOIN shippers;");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .select);
    try std.testing.expectEqual(@as(usize, 3), statement.select.joins.len);
    try std.testing.expectEqual(ast.JoinKind.inner, statement.select.joins[0].kind);
    try std.testing.expectEqualStrings("orders", statement.select.joins[0].table);
    try std.testing.expectEqualStrings("o", statement.select.joins[0].tableAlias.?);
    try std.testing.expectEqualStrings("u", statement.select.joins[0].leftTable);
    try std.testing.expectEqualStrings("id", statement.select.joins[0].leftColumn);
    try std.testing.expectEqual(ast.JoinKind.left, statement.select.joins[1].kind);
    try std.testing.expectEqualStrings("items", statement.select.joins[1].table);
    try std.testing.expectEqualStrings("o", statement.select.joins[1].leftTable);
    try std.testing.expectEqual(ast.JoinKind.cross, statement.select.joins[2].kind);
    try std.testing.expectEqualStrings("shippers", statement.select.joins[2].table);
}

test "parser parses subqueries in expressions" {
    var p1 = try Parser.init(std.testing.allocator, "SELECT (SELECT max(age) FROM users) AS max_age;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .select);
    try std.testing.expect(s1.select.projections[0].expr == .scalarSubquery);

    var p2 = try Parser.init(std.testing.allocator, "SELECT id FROM users WHERE id IN (SELECT user_id FROM orders);");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .select);

    var p3 = try Parser.init(std.testing.allocator, "SELECT id FROM users WHERE id IN (1, 2, 3);");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .select);
}

test "parser parses window functions with partition, order, and frame" {
    var parser = try Parser.init(std.testing.allocator, "SELECT id, row_number() OVER (PARTITION BY dept ORDER BY salary DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM emp;");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .select);
    const winExpr = statement.select.projections[1].expr;
    try std.testing.expect(winExpr == .window);
    try std.testing.expectEqualStrings("row_number", winExpr.window.funcName);
    try std.testing.expectEqual(@as(usize, 1), winExpr.window.partitionBy.len);
    try std.testing.expectEqual(@as(usize, 1), winExpr.window.orderBy.len);
    try std.testing.expect(winExpr.window.frame != null);
    try std.testing.expectEqual(ast.WindowFrameKind.rows, winExpr.window.frame.?.kind);
    try std.testing.expectEqual(ast.WindowFrameBound.unboundedPreceding, winExpr.window.frame.?.start);
    try std.testing.expectEqual(ast.WindowFrameBound.currentRow, winExpr.window.frame.?.end.?);
}

test "parser resolves named WINDOW clause references" {
    var p = try Parser.init(std.testing.allocator, "SELECT row_number() OVER w FROM t WINDOW w AS (PARTITION BY dept ORDER BY salary);");
    defer p.deinit();
    var s = try p.parse();
    defer ast.deinit(std.testing.allocator, &s);
    try std.testing.expect(s == .select);
    const win = s.select.projections[0].expr;
    try std.testing.expect(win == .window);
    try std.testing.expectEqual(@as(?[]const u8, null), win.window.base);
    try std.testing.expectEqual(@as(usize, 1), win.window.partitionBy.len);
    try std.testing.expectEqual(@as(usize, 1), win.window.orderBy.len);

    var p2 = try Parser.init(std.testing.allocator, "SELECT sum(x) OVER (w ORDER BY y) FROM t WINDOW w AS (PARTITION BY a);");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    const w2 = s2.select.projections[0].expr;
    try std.testing.expect(w2 == .window);
    try std.testing.expectEqual(@as(?[]const u8, null), w2.window.base);
    try std.testing.expectEqual(@as(usize, 1), w2.window.partitionBy.len);
    try std.testing.expectEqual(@as(usize, 1), w2.window.orderBy.len);

    var p3 = try Parser.init(std.testing.allocator, "SELECT row_number() OVER w2 FROM t WINDOW w AS (PARTITION BY a), w2 AS (w ORDER BY x);");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    const w3 = s3.select.projections[0].expr;
    try std.testing.expect(w3 == .window);
    try std.testing.expectEqual(@as(?[]const u8, null), w3.window.base);
    try std.testing.expectEqual(@as(usize, 1), w3.window.partitionBy.len);
    try std.testing.expectEqual(@as(usize, 1), w3.window.orderBy.len);

    var p4 = try Parser.init(std.testing.allocator, "SELECT row_number() OVER nope FROM t WINDOW w AS ();");
    defer p4.deinit();
    try std.testing.expectError(error.InvalidSql, p4.parse());

    var p5 = try Parser.init(std.testing.allocator, "SELECT row_number() OVER (w PARTITION BY b) FROM t WINDOW w AS (PARTITION BY a);");
    defer p5.deinit();
    try std.testing.expectError(error.InvalidSql, p5.parse());

    var p6 = try Parser.init(std.testing.allocator, "SELECT sum(x) FILTER (WHERE x > 0) OVER w FROM t WINDOW w AS (ORDER BY x);");
    defer p6.deinit();
    var s6 = try p6.parse();
    defer ast.deinit(std.testing.allocator, &s6);
    const w6 = s6.select.projections[0].expr;
    try std.testing.expect(w6 == .window);
    try std.testing.expect(w6.window.filter != null);

    var p7 = try Parser.init(std.testing.allocator, "SELECT 1 window w AS () window v AS ();");
    defer p7.deinit();
    try std.testing.expectError(error.InvalidSql, p7.parse());

    var p8 = try Parser.init(std.testing.allocator, "SELECT row_number() OVER w FROM t WINDOW w AS (ORDER BY x), w AS (ORDER BY y);");
    defer p8.deinit();
    var s8 = try p8.parse();
    defer ast.deinit(std.testing.allocator, &s8);
    const w8 = s8.select.projections[0].expr;
    try std.testing.expect(w8 == .window);
    try std.testing.expectEqual(@as(usize, 1), w8.window.orderBy.len);
}

test "parser parses returning clause for insert, update, and delete" {
    var p1 = try Parser.init(std.testing.allocator, "INSERT INTO users (name) VALUES ('Alice') RETURNING id, name AS user_name;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .insert);
    try std.testing.expectEqual(@as(usize, 2), s1.insert.returning.len);
    try std.testing.expectEqualStrings("user_name", s1.insert.returning[1].alias.?);

    var p2 = try Parser.init(std.testing.allocator, "UPDATE users SET name = 'Bob' WHERE id = 1 RETURNING name;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .update);
    try std.testing.expectEqual(@as(usize, 1), s2.update.returning.len);

    var p3 = try Parser.init(std.testing.allocator, "DELETE FROM users WHERE id = 1 RETURNING id;");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .delete);
    try std.testing.expectEqual(@as(usize, 1), s3.delete.returning.len);
}

test "parser parses with clause backing mutations" {
    var p1 = try Parser.init(std.testing.allocator, "WITH big AS (SELECT id FROM items) INSERT INTO archive SELECT id FROM big;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .withSelect);
    try std.testing.expectEqual(@as(usize, 1), s1.withSelect.ctes.len);
    var p2 = try Parser.init(std.testing.allocator, "WITH RECURSIVE nums AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM nums WHERE n < 4) INSERT INTO fib SELECT n FROM nums;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .withSelect);
    var p3 = try Parser.init(std.testing.allocator, "INSERT INTO fib SELECT n FROM nums RETURNING n;");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .insert);
    var p4 = try Parser.init(std.testing.allocator, "CREATE TRIGGER t AFTER UPDATE OF a, b ON t BEGIN SELECT 1; END;");
    defer p4.deinit();
    var s4 = try p4.parse();
    defer ast.deinit(std.testing.allocator, &s4);
    try std.testing.expect(s4 == .createTrigger);
    try std.testing.expectEqual(@as(usize, 2), s4.createTrigger.updateOf.len);
    try std.testing.expectEqualStrings("a", s4.createTrigger.updateOf[0]);
    var p5 = try Parser.init(std.testing.allocator, "CREATE TRIGGER u BEFORE UPDATE ON t BEGIN SELECT 1; END;");
    defer p5.deinit();
    var s5 = try p5.parse();
    defer ast.deinit(std.testing.allocator, &s5);
    try std.testing.expectEqual(@as(usize, 0), s5.createTrigger.updateOf.len);
}

test "parser parses analyze with optional target" {
    var p1 = try Parser.init(std.testing.allocator, "ANALYZE;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .analyze);
    try std.testing.expect(s1.analyze.target == null);
    var p2 = try Parser.init(std.testing.allocator, "ANALYZE mytable;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expectEqualStrings("mytable", s2.analyze.target.?);
    var p3 = try Parser.init(std.testing.allocator, "ANALYZE myindex;");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expectEqualStrings("myindex", s3.analyze.target.?);
}

test "parser parses reindex with optional target" {
    var p1 = try Parser.init(std.testing.allocator, "REINDEX;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .reindex);
    try std.testing.expect(s1.reindex.target == null);
    var p2 = try Parser.init(std.testing.allocator, "REINDEX mytable;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expectEqualStrings("mytable", s2.reindex.target.?);
    var p3 = try Parser.init(std.testing.allocator, "REINDEX myindex;");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expectEqualStrings("myindex", s3.reindex.target.?);
    var p4 = try Parser.init(std.testing.allocator, "REINDEX main.mytable;");
    defer p4.deinit();
    var s4 = try p4.parse();
    defer ast.deinit(std.testing.allocator, &s4);
    try std.testing.expectEqualStrings("main.mytable", s4.reindex.target.?);
}

test "parser parses having and alter table statements" {
    var p = try Parser.init(std.testing.allocator, "SELECT grp, count(*) FROM t GROUP BY grp HAVING count(*) > 1;");
    defer p.deinit();
    var s = try p.parse();
    defer ast.deinit(std.testing.allocator, &s);
    try std.testing.expect(s == .select);
    try std.testing.expect(s.select.having != null);
    try std.testing.expectEqual(@as(usize, 1), s.select.having.?.len);

    var pc = try Parser.init(std.testing.allocator, "SELECT grp, count(*), sum(v) FROM t GROUP BY grp HAVING count(*) > 1 AND sum(v) < 100 OR grp = 'x';");
    defer pc.deinit();
    var sc = try pc.parse();
    defer ast.deinit(std.testing.allocator, &sc);
    try std.testing.expect(sc == .select);
    try std.testing.expectEqual(@as(usize, 3), sc.select.having.?.len);
    try std.testing.expect(!sc.select.having.?[0].joinOr);
    try std.testing.expect(!sc.select.having.?[1].joinOr);
    try std.testing.expect(sc.select.having.?[2].joinOr);
    try std.testing.expectEqual(ast.CompareOp.greater, sc.select.having.?[0].op);
    try std.testing.expectEqual(ast.CompareOp.less, sc.select.having.?[1].op);
    try std.testing.expectEqual(ast.CompareOp.equal, sc.select.having.?[2].op);

    var p2 = try Parser.init(std.testing.allocator, "ALTER TABLE t ADD COLUMN extra TEXT;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .alterTable);
    try std.testing.expect(s2.alterTable == .addColumn);
    try std.testing.expectEqualStrings("t", s2.alterTable.addColumn.table);

    var p3 = try Parser.init(std.testing.allocator, "ALTER TABLE t RENAME COLUMN old TO new;");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3.alterTable == .renameColumn);
    try std.testing.expectEqualStrings("old", s3.alterTable.renameColumn.oldName);
    try std.testing.expectEqualStrings("new", s3.alterTable.renameColumn.newName);

    var p4 = try Parser.init(std.testing.allocator, "ALTER TABLE t DROP COLUMN extra;");
    defer p4.deinit();
    var s4 = try p4.parse();
    defer ast.deinit(std.testing.allocator, &s4);
    try std.testing.expect(s4.alterTable == .dropColumn);
    try std.testing.expectEqualStrings("extra", s4.alterTable.dropColumn.column);

    var p5 = try Parser.init(std.testing.allocator, "ALTER TABLE t RENAME TO u;");
    defer p5.deinit();
    var s5 = try p5.parse();
    defer ast.deinit(std.testing.allocator, &s5);
    try std.testing.expect(s5.alterTable == .renameTable);
    try std.testing.expectEqualStrings("u", s5.alterTable.renameTable.newName);
}

test "parser parses conflict policies on insert and update" {
    var p1 = try Parser.init(std.testing.allocator, "INSERT OR ROLLBACK INTO users VALUES (1);");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .insert);
    try std.testing.expectEqual(ast.ConflictPolicy.rollback, s1.insert.conflict);
    var p2 = try Parser.init(std.testing.allocator, "INSERT OR FAIL INTO users VALUES (1);");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expectEqual(ast.ConflictPolicy.fail, s2.insert.conflict);
    var p3 = try Parser.init(std.testing.allocator, "UPDATE OR IGNORE users SET name = 'x';");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .update);
    try std.testing.expectEqual(ast.ConflictPolicy.ignore, s3.update.conflict);
    var p4 = try Parser.init(std.testing.allocator, "UPDATE OR REPLACE users SET name = 'x';");
    defer p4.deinit();
    var s4 = try p4.parse();
    defer ast.deinit(std.testing.allocator, &s4);
    try std.testing.expectEqual(ast.ConflictPolicy.replace, s4.update.conflict);
}

test "parser parses table constraints, generated columns, strict, and without rowid" {
    var parser = try Parser.init(std.testing.allocator, "CREATE TABLE items (id INTEGER PRIMARY KEY, price REAL CHECK (price > 0), doubled REAL GENERATED ALWAYS AS (price * 2) STORED, CONSTRAINT valid_item CHECK (id > 0)) STRICT, WITHOUT ROWID;");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .createTable);
    try std.testing.expect(statement.createTable.strict);
    try std.testing.expect(statement.createTable.withoutRowid);
    try std.testing.expect(statement.createTable.columns[1].checkExpr != null);
    try std.testing.expect(statement.createTable.columns[2].generatedExpr != null);
    try std.testing.expect(statement.createTable.columns[2].generatedStored);
    try std.testing.expectEqual(@as(usize, 1), statement.createTable.constraints.len);
    try std.testing.expect(statement.createTable.constraints[0] == .check);
}

test "parser parses deferrable foreign key clauses" {
    var p1 = try Parser.init(std.testing.allocator, "CREATE TABLE c (id INTEGER, pid INTEGER REFERENCES p(id) DEFERRABLE INITIALLY DEFERRED);");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1.createTable.columns[1].foreignKey.?.deferrable);
    try std.testing.expect(s1.createTable.columns[1].foreignKey.?.initiallyDeferred);

    var p2 = try Parser.init(std.testing.allocator, "CREATE TABLE c (id INTEGER, pid INTEGER REFERENCES p(id) DEFERRABLE INITIALLY IMMEDIATE);");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2.createTable.columns[1].foreignKey.?.deferrable);
    try std.testing.expect(!s2.createTable.columns[1].foreignKey.?.initiallyDeferred);

    var p3 = try Parser.init(std.testing.allocator, "CREATE TABLE c (id INTEGER, pid INTEGER REFERENCES p(id) NOT NULL, FOREIGN KEY (pid) REFERENCES p(id) NOT DEFERRABLE);");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(!s3.createTable.columns[1].foreignKey.?.deferrable);
    try std.testing.expect(s3.createTable.constraints[0] == .foreignKey);
    try std.testing.expect(!s3.createTable.constraints[0].foreignKey.deferrable);

    var p4 = try Parser.init(std.testing.allocator, "CREATE TABLE c (id INTEGER, FOREIGN KEY (id) REFERENCES p(id) DEFERRABLE);");
    defer p4.deinit();
    var s4 = try p4.parse();
    defer ast.deinit(std.testing.allocator, &s4);
    try std.testing.expect(s4.createTable.constraints[0].foreignKey.deferrable);
    try std.testing.expect(s4.createTable.constraints[0].foreignKey.initiallyDeferred);

    var p5 = try Parser.init(std.testing.allocator, "CREATE TABLE c (id INTEGER REFERENCES p(id) NOT DEFERRABLE INITIALLY DEFERRED);");
    defer p5.deinit();
    try std.testing.expectError(error.InvalidSql, p5.parse());

    var p6 = try Parser.init(std.testing.allocator, "CREATE TABLE c (id INTEGER REFERENCES p(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED);");
    defer p6.deinit();
    var s6 = try p6.parse();
    defer ast.deinit(std.testing.allocator, &s6);
    try std.testing.expect(s6.createTable.columns[0].foreignKey.?.onDelete == .cascade);
    try std.testing.expect(s6.createTable.columns[0].foreignKey.?.initiallyDeferred);
}

test "parser parses attach, detach, and vacuum statements" {
    var p1 = try Parser.init(std.testing.allocator, "ATTACH DATABASE 'test.db' AS test_schema;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .attach);
    try std.testing.expectEqualStrings("test_schema", s1.attach.schemaName);

    var p2 = try Parser.init(std.testing.allocator, "DETACH DATABASE test_schema;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .detach);
    try std.testing.expectEqualStrings("test_schema", s2.detach.schemaName);

    var p3 = try Parser.init(std.testing.allocator, "VACUUM main INTO 'backup.db';");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .vacuum);
    try std.testing.expectEqualStrings("main", s3.vacuum.schemaName.?);
    try std.testing.expect(s3.vacuum.into != null);
}

test "parser parses pragma values, signs, and arguments" {
    var p1 = try Parser.init(std.testing.allocator, "PRAGMA cache_size = -100;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .pragma);
    try std.testing.expectEqualStrings("cache_size", s1.pragma.name);
    try std.testing.expectEqualStrings("-100", s1.pragma.value.?);
    try std.testing.expect(s1.pragma.argument == null);

    var p2 = try Parser.init(std.testing.allocator, "PRAGMA synchronous = OFF;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .pragma);
    try std.testing.expectEqualStrings("OFF", s2.pragma.value.?);

    var p3 = try Parser.init(std.testing.allocator, "PRAGMA foreign_key_check(kids);");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .pragma);
    try std.testing.expect(s3.pragma.value == null);
    try std.testing.expectEqualStrings("kids", s3.pragma.argument.?);

    var p4 = try Parser.init(std.testing.allocator, "PRAGMA integrity_check(10);");
    defer p4.deinit();
    var s4 = try p4.parse();
    defer ast.deinit(std.testing.allocator, &s4);
    try std.testing.expect(s4 == .pragma);
    try std.testing.expectEqualStrings("10", s4.pragma.argument.?);

    var p5 = try Parser.init(std.testing.allocator, "PRAGMA integrity_check;");
    defer p5.deinit();
    var s5 = try p5.parse();
    defer ast.deinit(std.testing.allocator, &s5);
    try std.testing.expect(s5 == .pragma);
    try std.testing.expect(s5.pragma.value == null);
    try std.testing.expect(s5.pragma.argument == null);
}

test "parser parses multi-word column type names with precision" {
    var parser = try Parser.init(std.testing.allocator, "CREATE TABLE matrix (a INT, b INTEGER PRIMARY KEY, c TINYINT, d SMALLINT, e MEDIUMINT, f BIGINT, g UNSIGNED BIG INT, h INT2, i INT8, j CHARACTER(20), k VARCHAR(255), l VARYING CHARACTER(255), m NCHAR(55), n NATIVE CHARACTER(70), o NVARCHAR(100), p TEXT, q CLOB, r REAL, s DOUBLE, t DOUBLE PRECISION, u FLOAT, v FLOATING POINT, w NUMERIC, x DECIMAL(10,5), y BOOLEAN, z DATE, aa DATETIME, ab BLOB, ac VARCHAR(10) NOT NULL);");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .createTable);
    const columns = statement.createTable.columns;
    const expected = [_][]const u8{ "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT", "UNSIGNED BIG INT", "INT2", "INT8", "CHARACTER(20)", "VARCHAR(255)", "VARYING CHARACTER(255)", "NCHAR(55)", "NATIVE CHARACTER(70)", "NVARCHAR(100)", "TEXT", "CLOB", "REAL", "DOUBLE", "DOUBLE PRECISION", "FLOAT", "FLOATING POINT", "NUMERIC", "DECIMAL(10,5)", "BOOLEAN", "DATE", "DATETIME", "BLOB", "VARCHAR(10)" };
    try std.testing.expectEqual(expected.len, columns.len);
    for (expected, 0..) |name, index| try std.testing.expectEqualStrings(name, columns[index].typeName);
    try std.testing.expect(columns[1].primaryKey);
    try std.testing.expect(columns[columns.len - 1].notNull);

    var untyped = try Parser.init(std.testing.allocator, "CREATE TABLE bare (id PRIMARY KEY);");
    defer untyped.deinit();
    var untypedStatement = try untyped.parse();
    defer ast.deinit(std.testing.allocator, &untypedStatement);
    try std.testing.expectEqualStrings("", untypedStatement.createTable.columns[0].typeName);
    try std.testing.expect(untypedStatement.createTable.columns[0].primaryKey);

    var casted = try Parser.init(std.testing.allocator, "SELECT CAST(x AS DOUBLE PRECISION) FROM t;");
    defer casted.deinit();
    var castedStatement = try casted.parse();
    defer ast.deinit(std.testing.allocator, &castedStatement);
    try std.testing.expect(castedStatement == .select);
    const call = castedStatement.select.projections[0].expr;
    try std.testing.expect(call == .function);
    try std.testing.expectEqualStrings("DOUBLE PRECISION", call.function.argument2.?.identifier);

    var empty = try Parser.init(std.testing.allocator, "SELECT CAST(x AS ) FROM t;");
    defer empty.deinit();
    try std.testing.expectError(Error.UnexpectedToken, empty.parse());
}

test "parser keeps group by qualifiers" {
    var qualified = try Parser.init(std.testing.allocator, "SELECT a.id, count(*) FROM a JOIN b ON a.id = b.aid GROUP BY a.id;");
    defer qualified.deinit();
    var qualifiedStatement = try qualified.parse();
    defer ast.deinit(std.testing.allocator, &qualifiedStatement);
    try std.testing.expect(qualifiedStatement == .select);
    try std.testing.expectEqualStrings("a.id", qualifiedStatement.select.groupBy.?);

    var bare = try Parser.init(std.testing.allocator, "SELECT id, count(*) FROM a GROUP BY id;");
    defer bare.deinit();
    var bareStatement = try bare.parse();
    defer ast.deinit(std.testing.allocator, &bareStatement);
    try std.testing.expectEqualStrings("id", bareStatement.select.groupBy.?);
}

test "parser parses multi-key order by with per-key direction" {
    var parser = try Parser.init(std.testing.allocator, "SELECT a, b FROM t ORDER BY a DESC, b ASC, 3;");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .select);
    try std.testing.expectEqual(@as(usize, 3), statement.select.orders.len);
    try std.testing.expectEqualStrings("a", statement.select.orders[0].column);
    try std.testing.expect(statement.select.orders[0].descending);
    try std.testing.expectEqualStrings("b", statement.select.orders[1].column);
    try std.testing.expect(!statement.select.orders[1].descending);
    try std.testing.expectEqualStrings("3", statement.select.orders[2].column);

    var qualified = try Parser.init(std.testing.allocator, "SELECT * FROM t ORDER BY u.name DESC, id;");
    defer qualified.deinit();
    var qualifiedStatement = try qualified.parse();
    defer ast.deinit(std.testing.allocator, &qualifiedStatement);
    try std.testing.expectEqual(@as(usize, 2), qualifiedStatement.select.orders.len);
    try std.testing.expectEqualStrings("u.name", qualifiedStatement.select.orders[0].column);
    try std.testing.expect(qualifiedStatement.select.orders[0].descending);
    try std.testing.expectEqualStrings("id", qualifiedStatement.select.orders[1].column);

    var single = try Parser.init(std.testing.allocator, "SELECT * FROM t ORDER BY id;");
    defer single.deinit();
    var singleStatement = try single.parse();
    defer ast.deinit(std.testing.allocator, &singleStatement);
    try std.testing.expectEqual(@as(usize, 1), singleStatement.select.orders.len);

    var none = try Parser.init(std.testing.allocator, "SELECT * FROM t;");
    defer none.deinit();
    var noneStatement = try none.parse();
    defer ast.deinit(std.testing.allocator, &noneStatement);
    try std.testing.expectEqual(@as(usize, 0), noneStatement.select.orders.len);

    var trailing = try Parser.init(std.testing.allocator, "SELECT * FROM t ORDER BY a,;");
    defer trailing.deinit();
    try std.testing.expectError(Error.UnexpectedToken, trailing.parse());

    var compound = try Parser.init(std.testing.allocator, "SELECT a FROM t UNION SELECT a FROM u ORDER BY a DESC, 1;");
    defer compound.deinit();
    var compoundStatement = try compound.parse();
    defer ast.deinit(std.testing.allocator, &compoundStatement);
    try std.testing.expect(compoundStatement == .compoundSelect);
    try std.testing.expectEqual(@as(usize, 2), compoundStatement.compoundSelect.orders.len);
    try std.testing.expect(compoundStatement.compoundSelect.orders[0].descending);
    try std.testing.expectEqualStrings("1", compoundStatement.compoundSelect.orders[1].column);
    try std.testing.expectEqualStrings("SELECT a FROM u", compoundStatement.compoundSelect.rightSql);

    var midOrdered = try Parser.init(std.testing.allocator, "SELECT a FROM t ORDER BY a, b UNION SELECT a FROM u;");
    defer midOrdered.deinit();
    try std.testing.expectError(Error.InvalidSql, midOrdered.parse());
}

test "parser treats quoted keywords as identifiers" {
    // Quoted names are always identifiers, never keywords (SQLite semantics).
    var allCol = try Parser.init(std.testing.allocator, "SELECT \"all\", \"count\" FROM t WHERE \"where\" = 'w' ORDER BY \"limit\";");
    defer allCol.deinit();
    var allStmt = try allCol.parse();
    defer ast.deinit(std.testing.allocator, &allStmt);
    try std.testing.expect(allStmt == .select);
    try std.testing.expectEqualStrings("all", allStmt.select.projections[0].expr.identifier);
    try std.testing.expectEqualStrings("count", allStmt.select.projections[1].expr.identifier);
    try std.testing.expectEqualStrings("where", allStmt.select.condition.?[0].column);
    try std.testing.expectEqual(@as(usize, 1), allStmt.select.orders.len);
    try std.testing.expectEqualStrings("limit", allStmt.select.orders[0].column);

    var ticked = try Parser.init(std.testing.allocator, "SELECT `select` FROM `from` ORDER BY `by`;");
    defer ticked.deinit();
    var tickedStmt = try ticked.parse();
    defer ast.deinit(std.testing.allocator, &tickedStmt);
    try std.testing.expect(tickedStmt == .select);
    try std.testing.expectEqualStrings("select", tickedStmt.select.projections[0].expr.identifier);
    try std.testing.expectEqualStrings("by", tickedStmt.select.orders[0].column);

    // Unquoted keywords keep their meaning.
    var bareAll = try Parser.init(std.testing.allocator, "SELECT ALL a FROM t;");
    defer bareAll.deinit();
    var bareAllStmt = try bareAll.parse();
    defer ast.deinit(std.testing.allocator, &bareAllStmt);
    try std.testing.expect(bareAllStmt == .select);
    try std.testing.expect(bareAllStmt.select.distinct == false);
    try std.testing.expectEqualStrings("a", bareAllStmt.select.projections[0].expr.identifier);

    var quotedAlias = try Parser.init(std.testing.allocator, "SELECT a AS \"where\", b \"limit\" FROM t;");
    defer quotedAlias.deinit();
    var quotedAliasStmt = try quotedAlias.parse();
    defer ast.deinit(std.testing.allocator, &quotedAliasStmt);
    try std.testing.expectEqualStrings("where", quotedAliasStmt.select.projections[0].alias.?);
    try std.testing.expectEqualStrings("limit", quotedAliasStmt.select.projections[1].alias.?);
}

test "parser fails closed on malformed input" {
    const bad = [_][]const u8{
        "SELECT;",
        "SELECT * FROM;",
        "SELECT * FROM t WHERE;",
        "INSERT INTO t VALUES;",
        "CREATE TABLE t (",
        "SELECT 1 UNION;",
        "SELECT (1;",
        "SELECT CASE WHEN 1 THEN;",
    };
    for (bad) |sql| {
        var p = try Parser.init(std.testing.allocator, sql);
        defer p.deinit();
        if (p.parse()) |stale| {
            var owned = stale;
            ast.deinit(std.testing.allocator, &owned);
            return error.ExpectedParseFailure;
        } else |_| {}
    }
    // Empty input is not a statement.
    var empty = try Parser.init(std.testing.allocator, "");
    defer empty.deinit();
    if (empty.parse()) |stale| {
        var owned = stale;
        ast.deinit(std.testing.allocator, &owned);
        return error.ExpectedParseFailure;
    } else |_| {}
    // Trailing garbage after a valid statement is rejected.
    var extra = try Parser.init(std.testing.allocator, "SELECT 1; SELECT 2;");
    defer extra.deinit();
    try std.testing.expectError(Error.UnexpectedToken, extra.parse());
    // Unterminated string surfaces the lexer error, not a partial AST.
    // Note: the lexer rejects it inside Parser.init, so either stage may
    // report UnterminatedString depending on where tokenization fails.
    var unterminated = Parser.init(std.testing.allocator, "SELECT 'abc;") catch |err| {
        try std.testing.expectEqual(Error.UnterminatedString, err);
        return;
    };
    defer unterminated.deinit();
    try std.testing.expectError(Error.UnterminatedString, unterminated.parse());
}

test "parser depth cap rejects hostile nesting fail-closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const depth = max_parse_depth + 50;
    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(alloc);
    for (0..depth) |_| try sql.appendSlice(alloc, "(");
    try sql.appendSlice(alloc, "1");
    for (0..depth) |_| try sql.appendSlice(alloc, ")");
    try sql.appendSlice(alloc, ";");
    var p = try Parser.init(std.testing.allocator, sql.items);
    defer p.deinit();
    try std.testing.expectError(Error.InvalidSql, p.parse());
}

test "parser unescapes doubled single quotes in string literals" {
    // Regression: the lexer preserves raw interiors (o''brien); the AST must
    // hold the SQLite-unescaped value (o'brien) so stored data round-trips.
    var p = try Parser.init(std.testing.allocator, "SELECT 'o''brien';");
    defer p.deinit();
    var stmt = try p.parse();
    defer ast.deinit(std.testing.allocator, &stmt);
    try std.testing.expect(stmt == .select);
    const proj = stmt.select.projections[0];
    try std.testing.expect(proj.expr == .literal);
    try std.testing.expectEqualStrings("o'brien", proj.expr.literal.text);
}

test "parser enforces the variable-number budget" {
    // Over the 32766 parameter budget.
    var over = try Parser.init(std.testing.allocator, "SELECT ?32767;");
    defer over.deinit();
    try std.testing.expectError(error.SqlTooBig, over.parse());
    // Zero is outside the 1-based range.
    var zero = try Parser.init(std.testing.allocator, "SELECT ?0;");
    defer zero.deinit();
    try std.testing.expectError(error.SqlTooBig, zero.parse());
    // Boundary index parses to the same parameter node.
    var edge = try Parser.init(std.testing.allocator, "SELECT ?32766;");
    defer edge.deinit();
    var stmt = try edge.parse();
    defer ast.deinit(std.testing.allocator, &stmt);
    try std.testing.expectEqual(@as(usize, 32766), stmt.select.projections[0].expr.parameter);
}

test "parser enforces the compound-terms budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Exactly 500 terms (boundary) is accepted.
    var ok_sql = std.ArrayList(u8).empty;
    defer ok_sql.deinit(alloc);
    for (0..500) |i| {
        if (i != 0) try ok_sql.appendSlice(alloc, " UNION ");
        try ok_sql.appendSlice(alloc, "SELECT 1");
    }
    try ok_sql.appendSlice(alloc, ";");
    var ok_p = try Parser.init(std.testing.allocator, ok_sql.items);
    defer ok_p.deinit();
    var ok_stmt = try ok_p.parse();
    defer ast.deinit(std.testing.allocator, &ok_stmt);
    try std.testing.expect(ok_stmt == .compoundSelect);
    // The 501st compound term exceeds the 500-term budget.
    var big_sql = std.ArrayList(u8).empty;
    defer big_sql.deinit(alloc);
    for (0..501) |i| {
        if (i != 0) try big_sql.appendSlice(alloc, " UNION ");
        try big_sql.appendSlice(alloc, "SELECT 1");
    }
    try big_sql.appendSlice(alloc, ";");
    var big_p = try Parser.init(std.testing.allocator, big_sql.items);
    defer big_p.deinit();
    try std.testing.expectError(error.SqlTooBig, big_p.parse());
}

test "parser enforces the function-argument budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // 1001 arguments exceeds the 1000-argument budget.
    var big_sql = std.ArrayList(u8).empty;
    defer big_sql.deinit(alloc);
    try big_sql.appendSlice(alloc, "SELECT f(");
    for (0..1001) |i| {
        if (i != 0) try big_sql.appendSlice(alloc, ", ");
        try big_sql.appendSlice(alloc, "1");
    }
    try big_sql.appendSlice(alloc, ");");
    var big_p = try Parser.init(std.testing.allocator, big_sql.items);
    defer big_p.deinit();
    try std.testing.expectError(error.SqlTooBig, big_p.parse());
    // Exactly 1000 arguments (boundary) parses.
    var ok_sql = std.ArrayList(u8).empty;
    defer ok_sql.deinit(alloc);
    try ok_sql.appendSlice(alloc, "SELECT f(");
    for (0..1000) |i| {
        if (i != 0) try ok_sql.appendSlice(alloc, ", ");
        try ok_sql.appendSlice(alloc, "1");
    }
    try ok_sql.appendSlice(alloc, ");");
    var ok_p = try Parser.init(std.testing.allocator, ok_sql.items);
    defer ok_p.deinit();
    var ok_stmt = try ok_p.parse();
    defer ast.deinit(std.testing.allocator, &ok_stmt);
    try std.testing.expect(ok_stmt == .select);
}

test "parser enforces the column budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // CREATE TABLE with 2001 columns exceeds the 2000-column budget.
    var big_sql = std.ArrayList(u8).empty;
    defer big_sql.deinit(alloc);
    try big_sql.appendSlice(alloc, "CREATE TABLE t (");
    for (0..2001) |i| {
        if (i != 0) try big_sql.appendSlice(alloc, ", ");
        {
            const name = try std.fmt.allocPrint(alloc, "c{d} INTEGER", .{i});
            defer alloc.free(name);
            try big_sql.appendSlice(alloc, name);
        }
    }
    try big_sql.appendSlice(alloc, ");");
    var big_p = try Parser.init(std.testing.allocator, big_sql.items);
    defer big_p.deinit();
    try std.testing.expectError(error.SqlTooBig, big_p.parse());
    // SELECT with 2001 projections exceeds the same budget.
    var sel_sql = std.ArrayList(u8).empty;
    defer sel_sql.deinit(alloc);
    try sel_sql.appendSlice(alloc, "SELECT ");
    for (0..2001) |i| {
        if (i != 0) try sel_sql.appendSlice(alloc, ", ");
        {
            const num = try std.fmt.allocPrint(alloc, "{d}", .{i});
            defer alloc.free(num);
            try sel_sql.appendSlice(alloc, num);
        }
    }
    try sel_sql.appendSlice(alloc, ";");
    var sel_p = try Parser.init(std.testing.allocator, sel_sql.items);
    defer sel_p.deinit();
    try std.testing.expectError(error.SqlTooBig, sel_p.parse());
    // Boundary: 2000 columns parses.
    var ok_sql = std.ArrayList(u8).empty;
    defer ok_sql.deinit(alloc);
    try ok_sql.appendSlice(alloc, "CREATE TABLE t (");
    for (0..2000) |i| {
        if (i != 0) try ok_sql.appendSlice(alloc, ", ");
        {
            const name = try std.fmt.allocPrint(alloc, "c{d} INTEGER", .{i});
            defer alloc.free(name);
            try ok_sql.appendSlice(alloc, name);
        }
    }
    try ok_sql.appendSlice(alloc, ");");
    var ok_p = try Parser.init(std.testing.allocator, ok_sql.items);
    defer ok_p.deinit();
    var ok_stmt = try ok_p.parse();
    defer ast.deinit(std.testing.allocator, &ok_stmt);
    try std.testing.expectEqual(@as(usize, 2000), ok_stmt.createTable.columns.len);
}
