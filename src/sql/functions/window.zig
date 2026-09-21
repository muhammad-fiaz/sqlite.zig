//! Window SQL functions (`row_number`, `rank`, `lag`, `sum OVER`, ...).
//!
//! Purpose: authoritative window evaluation behind `connection.zig`.
//! Implements partitioning, ORDER BY sorting, peer groups, frames
//! (`ROWS`/`RANGE`/`GROUPS`, `BETWEEN`, offsets), and all ranking, value, and
//! aggregate window functions.
//!
//! Responsibilities: pure computation over `WindowContext.rows`; never touches
//! storage. Ranking (`row_number`, `rank`, `dense_rank`, `percent_rank`,
//! `cume_dist`, `ntile`), navigation (`lag`, `lead`), framing (`first_value`,
//! `last_value`, `nth_value`), and framed aggregates.
//!
//! Dependencies: `std`, `../../vm/value.zig`, `../ast.zig`, `aggregate.zig`.
//!
//! Ownership/lifetime: `evalFn` results are *borrowed* (row memory or
//! connection arenas) and must NOT be freed by this file; every value stored
//! into `results` is cloned with `allocator` and caller-owned (free text/blob
//! results plus the slice). Internal `partitions`/`ranks` buffers are freed
//! before return.
//!
//! Error behavior: OOM only (`![]Value`); unknown functions, missing args, or
//! out-of-range offsets yield `.null` per row, never an error. Empty input
//! yields an empty (owned) slice.
//!
//! Invariants: output length equals input row count; `results[i]` corresponds
//! to `rows[i]` even after partition-internal reordering; default frame is
//! `RANGE UNBOUNDED PRECEDING..CURRENT ROW` with ORDER BY, else whole partition.
//!
//! SQLite compatibility: peer groups follow ORDER BY equality; `ntile(k)`
//! requires k > 0; `lag`/`lead` default offset 1 with optional default value.
// TODO(sql/window): partitioning/sorting is O(n^2) with per-compare `evalFn`
// calls and no spilling; hostile 100k-row partitions can blow time/memory.
// Expected: hash partitioning + sort with a work budget; tests: 10k-row perf
// bound. Subsystem: sql/functions.
// TODO(sql/window): `evalFn` ownership is implicit (borrowed); computed keys
// (`x+1`) may allocate without a free contract. Expected: explicit borrowed
// vs owned contract or arena-scoped eval; tests: computed-key window over
// 1k rows shows no growth. Subsystem: sql/functions.

const std = @import("std");
const Value = @import("../../vm/value.zig").Value;
const ast = @import("../ast.zig");
const AggState = @import("aggregate.zig").AggState;
const AggKind = @import("aggregate.zig").AggKind;

/// Input rows plus a row evaluator for partition/order/argument expressions.
/// `evalFn` results are borrowed and must not be freed by window code.
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

    if (w.partitionBy.len == 0) {
        var allIndices = std.ArrayList(usize).empty;
        try allIndices.ensureTotalCapacity(allocator, numRows);
        for (0..numRows) |i| try allIndices.append(allocator, i);
        try partitions.append(allocator, allIndices);
    } else {
        for (0..numRows) |rowIdx| {
            const curRow = ctx.rows[rowIdx];
            var found = false;
            for (partitions.items) |*part| {
                const repRow = ctx.rows[part.items[0]];
                var matches = true;
                for (w.partitionBy) |pExpr| {
                    const v1 = try ctx.evalFn(ctx.evalCtx, pExpr, curRow);
                    const v2 = try ctx.evalFn(ctx.evalCtx, pExpr, repRow);
                    if (!v1.sameValue(v2)) {
                        matches = false;
                        break;
                    }
                }
                if (matches) {
                    try part.append(allocator, rowIdx);
                    found = true;
                    break;
                }
            }
            if (!found) {
                var newPart = std.ArrayList(usize).empty;
                try newPart.append(allocator, rowIdx);
                try partitions.append(allocator, newPart);
            }
        }
    }

    for (partitions.items) |part| {
        const partIndices = part.items;
        if (w.orderBy.len > 0) {
            var i: usize = 0;
            while (i < partIndices.len) : (i += 1) {
                var j: usize = i + 1;
                while (j < partIndices.len) : (j += 1) {
                    const rowI = ctx.rows[partIndices[i]];
                    const rowJ = ctx.rows[partIndices[j]];
                    var shouldSwap = false;
                    for (w.orderBy) |ord| {
                        const valI = try ctx.evalFn(ctx.evalCtx, ord.expr, rowI);
                        const valJ = try ctx.evalFn(ctx.evalCtx, ord.expr, rowJ);
                        if (valI.sameValue(valJ)) continue;
                        if (valI == .null) {
                            shouldSwap = if (ord.nullsFirst) false else true;
                            break;
                        }
                        if (valJ == .null) {
                            shouldSwap = if (ord.nullsFirst) true else false;
                            break;
                        }
                        const cmp = valI.order(valJ, .binary);
                        if (ord.descending) {
                            shouldSwap = cmp == .lt;
                        } else {
                            shouldSwap = cmp == .gt;
                        }
                        break;
                    }
                    if (shouldSwap) {
                        std.mem.swap(usize, &partIndices[i], &partIndices[j]);
                    }
                }
            }
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
                const rowPrev = ctx.rows[partIndices[p - 1]];
                const rowCur = ctx.rows[partIndices[p]];
                var isPeer = true;
                if (w.orderBy.len == 0) {
                    isPeer = true;
                } else {
                    for (w.orderBy) |ord| {
                        const valPrev = try ctx.evalFn(ctx.evalCtx, ord.expr, rowPrev);
                        const valCur = try ctx.evalFn(ctx.evalCtx, ord.expr, rowCur);
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
                    if (offVal == .integer and offVal.integer >= 0) offset = @intCast(offVal.integer);
                }
                var defaultVal: Value = .null;
                if (w.extraArgs.len > 0) {
                    defaultVal = try ctx.evalFn(ctx.evalCtx, w.extraArgs[0], ctx.rows[originalRowIdx]);
                }
                if (p >= offset and w.argument != null) {
                    const targetRowIdx = partIndices[p - offset];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, ctx.rows[targetRowIdx]);
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
                    if (offVal == .integer and offVal.integer >= 0) offset = @intCast(offVal.integer);
                }
                var defaultVal: Value = .null;
                if (w.extraArgs.len > 0) {
                    defaultVal = try ctx.evalFn(ctx.evalCtx, w.extraArgs[0], ctx.rows[originalRowIdx]);
                }
                if (p + offset < n and w.argument != null) {
                    const targetRowIdx = partIndices[p + offset];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, ctx.rows[targetRowIdx]);
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
