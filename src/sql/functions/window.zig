//! Window functions over query rows.
//!
//! Results are caller-owned clones aligned with input rows.
//! Bad functions or offsets yield NULL per row.

const std = @import("std");
const Value = @import("../../vm/value.zig").Value;
const ast = @import("../ast.zig");
const AggState = @import("aggregate.zig").AggState;
const AggKind = @import("aggregate.zig").AggKind;

/// Free an evalFn temp whose expression may own its payload: binary, unary,
/// and function results clone or allocate text/blob, while identifiers,
/// literals, and parameters borrow. Anything else is left alone (freeing a
/// borrowed payload would corrupt; the remaining shapes are rare as keys).
fn freeWindowTemp(allocator: std.mem.Allocator, expr: ast.Expr, value: Value) void {
    switch (expr) {
        .binary, .unary, .function => if (value == .text) allocator.free(value.text) else if (value == .blob) allocator.free(value.blob),
        else => {},
    }
}

/// True when two rows share every precomputed key (sameValue per key, so
/// NaN stays singleton and int 1 stays apart from real 1.0).
fn sameKeyTuple(keys: []const Value, stride: usize, a: usize, b: usize) bool {
    var k: usize = 0;
    while (k < stride) : (k += 1) {
        if (!keys[a * stride + k].sameValue(keys[b * stride + k])) return false;
    }
    return true;
}

/// Input rows plus a row evaluator for partition/order/argument expressions.
/// `evalFn` results follow the interpreter contract: identifiers, literals,
/// and parameters borrow; computed binary/unary/function results may own
/// text/blob (free those with `freeWindowTemp` once cloned or consumed).
pub const WindowContext = struct {
    /// Allocator for `results` clones and internal buffers.
    allocator: std.mem.Allocator,
    /// Input rows in original order; output aligns by index.
    rows: []const []const Value,
    /// Evaluate `expr` against `row`; borrowed result, OOM/errors propagate.
    evalFn: *const fn (ctx: *const anyopaque, expr: ast.Expr, row: []const Value) anyerror!Value,
    /// Opaque pointer passed through to `evalFn`.
    evalCtx: *const anyopaque,
};

/// Evaluate window expression `win` over `ctx.rows`; returns caller-owned `[]Value`.
/// Length equals row count; each element owned (free text/blob + slice).
pub fn evaluateWindowFunction(
    allocator: std.mem.Allocator,
    win: ast.Expr,
    ctx: WindowContext,
) ![]Value {
    const w = win.window;
    const numRows = ctx.rows.len;
    const results = try allocator.alloc(Value, numRows);
    errdefer {
        for (results) |v| {
            switch (v) {
                .text => |t| allocator.free(t),
                .blob => |b| allocator.free(b),
                else => {},
            }
        }
        allocator.free(results);
    }
    @memset(results, .null);

    if (numRows == 0) return results;

    var partitions = std.ArrayList(std.ArrayList(usize)).empty;
    defer {
        for (partitions.items) |*part| part.deinit(allocator);
        partitions.deinit(allocator);
    }

    // Partition and order keys are evaluated once per row into owned clones,
    // then grouping and sorting compare keys without re-evaluating. Each
    // eval temp is freed right after cloning (see `freeWindowTemp`).
    const numPartKeys = w.partitionBy.len;
    const numOrderKeys = w.orderBy.len;
    var partKeys = std.ArrayList(Value).empty;
    defer {
        for (partKeys.items) |v| v.free(allocator);
        partKeys.deinit(allocator);
    }
    var orderKeys = std.ArrayList(Value).empty;
    defer {
        for (orderKeys.items) |v| v.free(allocator);
        orderKeys.deinit(allocator);
    }
    for (ctx.rows) |row| {
        for (w.partitionBy) |pExpr| {
            const v = try ctx.evalFn(ctx.evalCtx, pExpr, row);
            try partKeys.append(allocator, try v.clone(allocator));
            freeWindowTemp(allocator, pExpr, v);
        }
        for (w.orderBy) |ord| {
            const v = try ctx.evalFn(ctx.evalCtx, ord.expr, row);
            try orderKeys.append(allocator, try v.clone(allocator));
            freeWindowTemp(allocator, ord.expr, v);
        }
    }

    if (numPartKeys == 0) {
        var allIndices = std.ArrayList(usize).empty;
        try allIndices.ensureTotalCapacity(allocator, numRows);
        for (0..numRows) |i| try allIndices.append(allocator, i);
        try partitions.append(allocator, allIndices);
    } else {
        // Sort row indices by key tuple (original index breaks ties, so
        // groups keep insertion order), then cut on sameValue boundaries.
        // NaN keys never match, so they correctly land alone.
        var perm = std.ArrayList(usize).empty;
        defer perm.deinit(allocator);
        for (0..numRows) |i| try perm.append(allocator, i);
        const PartCtx = struct {
            keys: []const Value,
            stride: usize,
            pub fn lessThan(cx: @This(), a: usize, b: usize) bool {
                var k: usize = 0;
                while (k < cx.stride) : (k += 1) {
                    const va = cx.keys[a * cx.stride + k];
                    const vb = cx.keys[b * cx.stride + k];
                    if (va.sameValue(vb)) continue;
                    return va.order(vb, .binary) == .lt;
                }
                return a < b;
            }
        };
        std.sort.pdq(usize, perm.items, PartCtx{ .keys = partKeys.items, .stride = numPartKeys }, PartCtx.lessThan);
        var runStart: usize = 0;
        var r: usize = 1;
        while (r <= numRows) : (r += 1) {
            const boundary = r == numRows or !sameKeyTuple(partKeys.items, numPartKeys, perm.items[r - 1], perm.items[r]);
            if (!boundary) continue;
            var group = std.ArrayList(usize).empty;
            errdefer group.deinit(allocator);
            for (perm.items[runStart..r]) |idx| try group.append(allocator, idx);
            try partitions.append(allocator, group);
            runStart = r;
        }
    }

    for (partitions.items) |part| {
        const partIndices = part.items;
        if (w.orderBy.len > 0 and partIndices.len > 1) {
            // Sort by precomputed keys (no re-evaluation); the original row
            // index breaks ties, reproducing the old stable order exactly.
            const OrderCtx = struct {
                keys: []const Value,
                stride: usize,
                orders: []const ast.OrderItem,
                pub fn lessThan(cx: @This(), a: usize, b: usize) bool {
                    for (cx.orders, 0..) |ord, k| {
                        const va = cx.keys[a * cx.stride + k];
                        const vb = cx.keys[b * cx.stride + k];
                        if (va.sameValue(vb)) continue;
                        if (va == .null) return ord.nullsFirst;
                        if (vb == .null) return !ord.nullsFirst;
                        const cmp = va.order(vb, .binary);
                        if (cmp == .eq) continue;
                        return if (ord.descending) cmp == .gt else cmp == .lt;
                    }
                    return a < b;
                }
            };
            std.sort.pdq(usize, partIndices, OrderCtx{ .keys = orderKeys.items, .stride = numOrderKeys, .orders = w.orderBy }, OrderCtx.lessThan);
        }

        const n = partIndices.len;
        const ranks = try allocator.alloc(usize, n);
        defer allocator.free(ranks);
        const denseRanks = try allocator.alloc(usize, n);
        defer allocator.free(denseRanks);
        const peerStarts = try allocator.alloc(usize, n);
        defer allocator.free(peerStarts);
        const peerEnds = try allocator.alloc(usize, n);
        defer allocator.free(peerEnds);

        var curRank: usize = 1;
        var curDense: usize = 1;
        var peerStartIdx: usize = 0;

        for (0..n) |p| {
            if (p == 0) {
                ranks[p] = 1;
                denseRanks[p] = 1;
            } else {
                // Peers compare precomputed order keys (same evaluation the
                // sort above used, so ranking agrees with ordering).
                const prevIdx = partIndices[p - 1];
                const curIdx = partIndices[p];
                var isPeer = true;
                if (w.orderBy.len == 0) {
                    isPeer = true;
                } else {
                    var kk: usize = 0;
                    while (kk < numOrderKeys) : (kk += 1) {
                        const valPrev = orderKeys.items[prevIdx * numOrderKeys + kk];
                        const valCur = orderKeys.items[curIdx * numOrderKeys + kk];
                        if (!valPrev.sameValue(valCur)) {
                            isPeer = false;
                            break;
                        }
                    }
                }
                if (isPeer) {
                    ranks[p] = curRank;
                    denseRanks[p] = curDense;
                } else {
                    for (peerStartIdx..p) |k| peerEnds[k] = p - 1;
                    peerStartIdx = p;
                    curRank = p + 1;
                    curDense += 1;
                    ranks[p] = curRank;
                    denseRanks[p] = curDense;
                }
            }
            peerStarts[p] = peerStartIdx;
        }
        for (peerStartIdx..n) |k| peerEnds[k] = n - 1;

        for (0..n) |p| {
            const originalRowIdx = partIndices[p];
            const name = w.funcName;

            if (std.ascii.eqlIgnoreCase(name, "row_number")) {
                results[originalRowIdx] = .{ .integer = @intCast(p + 1) };
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "rank")) {
                results[originalRowIdx] = .{ .integer = @intCast(ranks[p]) };
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "dense_rank")) {
                results[originalRowIdx] = .{ .integer = @intCast(denseRanks[p]) };
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "percent_rank")) {
                if (n <= 1) {
                    results[originalRowIdx] = .{ .real = 0.0 };
                } else {
                    const r = @as(f64, @floatFromInt(ranks[p] - 1)) / @as(f64, @floatFromInt(n - 1));
                    results[originalRowIdx] = .{ .real = r };
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "cume_dist")) {
                const r = @as(f64, @floatFromInt(peerEnds[p] + 1)) / @as(f64, @floatFromInt(n));
                results[originalRowIdx] = .{ .real = r };
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "ntile")) {
                if (w.argument == null) {
                    results[originalRowIdx] = .null;
                    continue;
                }
                const kVal = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, ctx.rows[originalRowIdx]);
                defer freeWindowTemp(allocator, w.argument.?.*, kVal);
                const k: i64 = switch (kVal) {
                    .integer => |i| i,
                    .real => |r| @intFromFloat(r),
                    else => 0,
                };
                if (k <= 0) {
                    results[originalRowIdx] = .null;
                    continue;
                }
                const nK: usize = @intCast(k);
                const q = n / nK;
                const r = n % nK;
                const bucket: usize = if (p < r * (q + 1))
                    p / (q + 1) + 1
                else
                    r + (p - r * (q + 1)) / (if (q == 0) 1 else q) + 1;
                results[originalRowIdx] = .{ .integer = @intCast(bucket) };
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "lag")) {
                var offset: usize = 1;
                if (w.argument2) |arg2| {
                    const offVal = try ctx.evalFn(ctx.evalCtx, arg2.*, ctx.rows[originalRowIdx]);
                    defer freeWindowTemp(allocator, arg2.*, offVal);
                    if (offVal == .integer and offVal.integer >= 0) offset = @intCast(offVal.integer);
                }
                var defaultVal: Value = .null;
                var hasDefault = false;
                if (w.extraArgs.len > 0) {
                    defaultVal = try ctx.evalFn(ctx.evalCtx, w.extraArgs[0], ctx.rows[originalRowIdx]);
                    hasDefault = true;
                }
                defer if (hasDefault) freeWindowTemp(allocator, w.extraArgs[0], defaultVal);
                if (p >= offset and w.argument != null) {
                    const targetRowIdx = partIndices[p - offset];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, ctx.rows[targetRowIdx]);
                    defer freeWindowTemp(allocator, w.argument.?.*, raw);
                    results[originalRowIdx] = try raw.clone(allocator);
                } else {
                    results[originalRowIdx] = try defaultVal.clone(allocator);
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "lead")) {
                var offset: usize = 1;
                if (w.argument2) |arg2| {
                    const offVal = try ctx.evalFn(ctx.evalCtx, arg2.*, ctx.rows[originalRowIdx]);
                    defer freeWindowTemp(allocator, arg2.*, offVal);
                    if (offVal == .integer and offVal.integer >= 0) offset = @intCast(offVal.integer);
                }
                var defaultVal: Value = .null;
                var hasDefault = false;
                if (w.extraArgs.len > 0) {
                    defaultVal = try ctx.evalFn(ctx.evalCtx, w.extraArgs[0], ctx.rows[originalRowIdx]);
                    hasDefault = true;
                }
                defer if (hasDefault) freeWindowTemp(allocator, w.extraArgs[0], defaultVal);
                if (p + offset < n and w.argument != null) {
                    const targetRowIdx = partIndices[p + offset];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, ctx.rows[targetRowIdx]);
                    defer freeWindowTemp(allocator, w.argument.?.*, raw);
                    results[originalRowIdx] = try raw.clone(allocator);
                } else {
                    results[originalRowIdx] = try defaultVal.clone(allocator);
                }
                continue;
            }

            var frameStart: usize = 0;
            var frameEnd: usize = n - 1;

            if (w.frame) |fr| {
                switch (fr.start) {
                    .unboundedPreceding => frameStart = 0,
                    .currentRow => frameStart = if (fr.kind == .range) peerStarts[p] else p,
                    .preceding => frameStart = if (p < fr.startOffset) 0 else p - fr.startOffset,
                    .following => frameStart = @min(n, p + fr.startOffset),
                    .unboundedFollowing => frameStart = n - 1,
                }
                if (fr.end) |endBound| {
                    switch (endBound) {
                        .unboundedPreceding => frameEnd = 0,
                        .currentRow => frameEnd = if (fr.kind == .range) peerEnds[p] else p,
                        .preceding => frameEnd = if (p < fr.endOffset) 0 else p - fr.endOffset,
                        .following => frameEnd = @min(n - 1, p + fr.endOffset),
                        .unboundedFollowing => frameEnd = n - 1,
                    }
                } else {
                    frameEnd = if (fr.kind == .range) peerEnds[p] else p;
                }
            } else {
                if (w.orderBy.len > 0) {
                    frameStart = 0;
                    frameEnd = peerEnds[p];
                } else {
                    frameStart = 0;
                    frameEnd = n - 1;
                }
            }

            if (std.ascii.eqlIgnoreCase(name, "first_value")) {
                if (frameStart > frameEnd or frameStart >= n or w.argument == null) {
                    results[originalRowIdx] = .null;
                } else {
                    const targetRow = ctx.rows[partIndices[frameStart]];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, targetRow);
                    defer freeWindowTemp(allocator, w.argument.?.*, raw);
                    results[originalRowIdx] = try raw.clone(allocator);
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "last_value")) {
                if (frameStart > frameEnd or frameEnd >= n or w.argument == null) {
                    results[originalRowIdx] = .null;
                } else {
                    const targetRow = ctx.rows[partIndices[frameEnd]];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, targetRow);
                    defer freeWindowTemp(allocator, w.argument.?.*, raw);
                    results[originalRowIdx] = try raw.clone(allocator);
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "nth_value")) {
                if (frameStart > frameEnd or w.argument == null or w.argument2 == null) {
                    results[originalRowIdx] = .null;
                    continue;
                }
                const nVal = try ctx.evalFn(ctx.evalCtx, w.argument2.?.*, ctx.rows[originalRowIdx]);
                defer freeWindowTemp(allocator, w.argument2.?.*, nVal);
                const nth: i64 = switch (nVal) {
                    .integer => |i| i,
                    .real => |r| @intFromFloat(r),
                    else => 0,
                };
                if (nth <= 0) {
                    results[originalRowIdx] = .null;
                    continue;
                }
                const targetOffset = @as(usize, @intCast(nth - 1));
                const targetIdx = frameStart + targetOffset;
                if (targetIdx > frameEnd or targetIdx >= n) {
                    results[originalRowIdx] = .null;
                } else {
                    const targetRow = ctx.rows[partIndices[targetIdx]];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, targetRow);
                    defer freeWindowTemp(allocator, w.argument.?.*, raw);
                    results[originalRowIdx] = try raw.clone(allocator);
                }
                continue;
            }

            if (AggKind.fromName(name)) |aggKind| {
                var aggState = AggState.init(allocator, aggKind, ",");
                defer aggState.deinit();

                if (frameStart <= frameEnd and frameStart < n) {
                    const endBound = @min(n - 1, frameEnd);
                    var idx = frameStart;
                    while (idx <= endBound) : (idx += 1) {
                        const targetRow = ctx.rows[partIndices[idx]];
                        if (w.argument) |arg| {
                            if (arg.* == .wildcard) {
                                aggState.stepWildcard();
                            } else {
                                const argVal = try ctx.evalFn(ctx.evalCtx, arg.*, targetRow);
                                defer freeWindowTemp(allocator, arg.*, argVal);
                                try aggState.step(argVal, false);
                            }
                        } else {
                            aggState.stepWildcard();
                        }
                    }
                }
                results[originalRowIdx] = try aggState.final();
                continue;
            }

            results[originalRowIdx] = .null;
        }
    }

    return results;
}

fn testEvalFn(ctx: *const anyopaque, expr: ast.Expr, row: []const Value) anyerror!Value {
    _ = ctx;
    return switch (expr) {
        .identifier => |id| blk: {
            if (std.ascii.eqlIgnoreCase(id, "x")) break :blk row[0];
            if (std.ascii.eqlIgnoreCase(id, "g")) break :blk row[1];
            break :blk .null;
        },
        .literal => |lit| lit,
        else => .null,
    };
}

test "window ranking functions" {
    const alloc = std.testing.allocator;
    const r1 = [_]Value{ .{ .integer = 10 }, .{ .integer = 1 } };
    const r2 = [_]Value{ .{ .integer = 20 }, .{ .integer = 1 } };
    const r3 = [_]Value{ .{ .integer = 30 }, .{ .integer = 2 } };
    const rows = [_][]const Value{ &r1, &r2, &r3 };
    const ctx = WindowContext{ .allocator = alloc, .rows = &rows, .evalFn = testEvalFn, .evalCtx = undefined };
    const win = ast.Expr{ .window = .{ .funcName = "row_number" } };
    const res = try evaluateWindowFunction(alloc, win, ctx);
    defer {
        for (res) |v| v.free(alloc);
        alloc.free(res);
    }
    try std.testing.expectEqual(@as(usize, 3), res.len);
    try std.testing.expectEqual(@as(i64, 1), res[0].integer);
    try std.testing.expectEqual(@as(i64, 2), res[1].integer);
    try std.testing.expectEqual(@as(i64, 3), res[2].integer);
}

test "window partition and null boundaries" {
    const alloc = std.testing.allocator;
    // Empty input yields empty output.
    const empty_ctx = WindowContext{ .allocator = alloc, .rows = &.{}, .evalFn = testEvalFn, .evalCtx = undefined };
    const empty = try evaluateWindowFunction(alloc, .{ .window = .{ .funcName = "rank" } }, empty_ctx);
    defer alloc.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    // ntile with k<=0 is NULL; unknown functions are NULL.
    const r1 = [_]Value{ .{ .integer = 1 }, .{ .integer = 1 } };
    const rows = [_][]const Value{&r1};
    const ctx = WindowContext{ .allocator = alloc, .rows = &rows, .evalFn = testEvalFn, .evalCtx = undefined };
    const bad_ntile = ast.Expr{ .window = .{ .funcName = "ntile", .argument = &.{ .literal = .{ .integer = 0 } } } };
    const bad_res = try evaluateWindowFunction(alloc, bad_ntile, ctx);
    defer {
        for (bad_res) |v| v.free(alloc);
        alloc.free(bad_res);
    }
    try std.testing.expect(bad_res[0] == .null);
    const unknown = try evaluateWindowFunction(alloc, .{ .window = .{ .funcName = "nope" } }, ctx);
    defer {
        for (unknown) |v| v.free(alloc);
        alloc.free(unknown);
    }
    try std.testing.expect(unknown[0] == .null);
}

test "window lag lead and frame aggregates" {
    const alloc = std.testing.allocator;
    const r1 = [_]Value{ .{ .integer = 10 }, .{ .integer = 1 } };
    const r2 = [_]Value{ .{ .integer = 20 }, .{ .integer = 1 } };
    const rows = [_][]const Value{ &r1, &r2 };
    const ctx = WindowContext{ .allocator = alloc, .rows = &rows, .evalFn = testEvalFn, .evalCtx = undefined };
    const x_ident = ast.Expr{ .identifier = "x" };
    const lag = ast.Expr{ .window = .{ .funcName = "lag", .argument = &x_ident } };
    const lag_res = try evaluateWindowFunction(alloc, lag, ctx);
    defer {
        for (lag_res) |v| v.free(alloc);
        alloc.free(lag_res);
    }
    try std.testing.expect(lag_res[0] == .null);
    try std.testing.expectEqual(@as(i64, 10), lag_res[1].integer);
    const sum = ast.Expr{ .window = .{ .funcName = "sum", .argument = &x_ident } };
    const sum_res = try evaluateWindowFunction(alloc, sum, ctx);
    defer {
        for (sum_res) |v| v.free(alloc);
        alloc.free(sum_res);
    }
    try std.testing.expectEqual(@as(i64, 30), sum_res[0].integer);
}

test "window computed keys group and order without leaking" {
    // evalFn returning OWNED text for binary exprs: every temp the engine
    // makes must be freed (the testing allocator fails on leak), and the
    // single computed partition must still order by the real column.
    const ownedEval = struct {
        fn eval(ctxPtr: *const anyopaque, expr: ast.Expr, row: []const Value) anyerror!Value {
            _ = ctxPtr;
            return switch (expr) {
                .identifier => |id| if (std.ascii.eqlIgnoreCase(id, "g")) row[0] else .null,
                .binary => .{ .text = try std.testing.allocator.dupe(u8, "k") },
                else => .null,
            };
        }
    }.eval;
    const alloc = std.testing.allocator;
    const r0 = [_]Value{.{ .text = "b" }};
    const r1 = [_]Value{.{ .text = "a" }};
    const r2 = [_]Value{.{ .text = "b" }};
    const r3 = [_]Value{.{ .text = "a" }};
    const rows = [_][]const Value{ &r0, &r1, &r2, &r3 };
    const ctx = WindowContext{ .allocator = alloc, .rows = &rows, .evalFn = ownedEval, .evalCtx = undefined };
    var keyLeft = ast.Expr{ .identifier = "g" };
    var keyRight = ast.Expr{ .literal = .{ .text = "" } };
    const partKey = ast.Expr{ .binary = .{ .op = .concat, .left = &keyLeft, .right = &keyRight } };
    const orderKey = ast.Expr{ .identifier = "g" };
    const win = ast.Expr{ .window = .{ .funcName = "row_number", .partitionBy = &.{partKey}, .orderBy = &.{.{ .expr = orderKey }} } };
    const res = try evaluateWindowFunction(alloc, win, ctx);
    defer {
        for (res) |v| v.free(alloc);
        alloc.free(res);
    }
    // One partition ("k" everywhere), ordered a,a,b,b by insertion order.
    try std.testing.expectEqual(@as(i64, 3), res[0].integer);
    try std.testing.expectEqual(@as(i64, 1), res[1].integer);
    try std.testing.expectEqual(@as(i64, 4), res[2].integer);
    try std.testing.expectEqual(@as(i64, 2), res[3].integer);
}

test "window scales to thousands of rows" {
    const alloc = std.testing.allocator;
    const rowCount = 5000;
    var rows = std.ArrayList([]const Value).empty;
    defer rows.deinit(alloc);
    var owned: std.ArrayList([]Value) = .empty;
    defer {
        for (owned.items) |pair| alloc.free(pair);
        owned.deinit(alloc);
    }
    var i: usize = 0;
    while (i < rowCount) : (i += 1) {
        const pair = try alloc.alloc(Value, 2);
        pair[0] = .{ .integer = @intCast(i % 2) };
        pair[1] = .{ .integer = @intCast(i % 7) };
        try owned.append(alloc, pair);
        try rows.append(alloc, pair);
    }
    const ctx = WindowContext{ .allocator = alloc, .rows = rows.items, .evalFn = testEvalFn, .evalCtx = undefined };
    // testEvalFn maps "x" to row[0] and "g" to row[1].
    const xIdent = ast.Expr{ .identifier = "x" };
    const gIdent = ast.Expr{ .identifier = "g" };
    const win = ast.Expr{ .window = .{ .funcName = "rank", .partitionBy = &.{gIdent}, .orderBy = &.{.{ .expr = xIdent }} } };
    const res = try evaluateWindowFunction(alloc, win, ctx);
    defer {
        for (res) |v| v.free(alloc);
        alloc.free(res);
    }
    try std.testing.expectEqual(@as(usize, rowCount), res.len);
    // Row 0 leads partition g=0 (rank 1); rows 1 and 15 share partition g=1
    // with equal x, so they tie each other at a rank above 1.
    try std.testing.expectEqual(@as(i64, 1), res[0].integer);
    try std.testing.expect(res[1].integer > 1);
    try std.testing.expectEqual(res[1].integer, res[15].integer);
}
