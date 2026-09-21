//! Window functions over query rows.
//!
//! Results are caller-owned clones aligned with input rows.
//! Bad functions or offsets yield NULL per row.

const std = @import("std");
const Value = @import("../../vm/value.zig").Value;
const ast = @import("../ast.zig");
const AggState = @import("aggregate.zig").AggState;
const AggKind = @import("aggregate.zig").AggKind;
const scalar = @import("scalar.zig");

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

/// Evaluate one frame offset expression against the current row. Offsets
/// are full expressions but must yield a non-negative integer per row —
/// integer-valued reals (1.0) pass, anything else (NULL, text, negative,
/// fractional) fails with `InvalidSql`, like the reference.
fn evalFrameOffset(allocator: std.mem.Allocator, ctx: WindowContext, offsetExpr: ?*const ast.Expr, row: []const Value) !usize {
    const node = offsetExpr orelse return 0;
    const v = try ctx.evalFn(ctx.evalCtx, node.*, row);
    defer freeWindowTemp(allocator, node.*, v);
    switch (v) {
        .integer => |i| return std.math.cast(usize, i) orelse error.InvalidSql,
        .real => |r| {
            if (r != @trunc(r)) return error.InvalidSql;
            if (r < 0 or r > 9223372036854775807.0) return error.InvalidSql;
            return std.math.cast(usize, @as(i64, @intFromFloat(r))) orelse error.InvalidSql;
        },
        else => return error.InvalidSql,
    }
}

/// True when a FILTER clause keeps `row` (or there is no clause).
fn windowRowPassesFilter(allocator: std.mem.Allocator, ctx: WindowContext, filter: ?*const ast.Expr, row: []const Value) !bool {
    const node = filter orelse return true;
    const v = try ctx.evalFn(ctx.evalCtx, node.*, row);
    defer freeWindowTemp(allocator, node.*, v);
    return scalar.isTruthyValue(v);
}

/// True for PRECEDING/FOLLOWING bounds (the ones carrying offsets).
fn isOffsetBound(bound: ast.WindowFrameBound) bool {
    return bound == .preceding or bound == .following;
}

/// True when position `j` is cut from row `p`'s frame by EXCLUDE:
/// CURRENT ROW drops just `p`, GROUP drops the whole peer group,
/// TIES drops the peers but keeps `p` itself.
fn frameRowExcluded(exclude: ast.WindowExclude, p: usize, j: usize, peerStarts: []const usize, peerEnds: []const usize) bool {
    return switch (exclude) {
        .none => false,
        .currentRow => j == p,
        .group => j >= peerStarts[p] and j <= peerEnds[p],
        .ties => j != p and j >= peerStarts[p] and j <= peerEnds[p],
    };
}

/// Numeric RANGE key or bound: integers stay exact (`i128` survives any
/// `i64` key plus `usize` offset); reals compare as `f64`.
const RangeNum = union(enum) { int: i128, real: f64 };

/// Numeric view of a RANGE order key; text/blob keys (and NULL) have none —
/// the reference excludes non-numeric keys from value ranges.
fn rangeNumber(key: Value) ?RangeNum {
    return switch (key) {
        .integer => |i| .{ .int = i },
        .real => |r| .{ .real = r },
        else => null,
    };
}

/// One end of a numeric RANGE interval; infinities model UNBOUNDED bounds.
const RangeEdge = union(enum) { negInf, num: RangeNum, posInf };

/// Numeric `a <= b` across the int/real mix (exact for int/int).
fn rangeNumLessEqual(a: RangeNum, b: RangeNum) bool {
    if (a == .int and b == .int) return a.int <= b.int;
    const af: f64 = if (a == .int) @floatFromInt(a.int) else a.real;
    const bf: f64 = if (b == .int) @floatFromInt(b.int) else b.real;
    return af <= bf;
}

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

        // Peer-group layout: `groupStarts` holds each group's first
        // position, `groupOf[p]` its group index. GROUPS offsets and
        // EXCLUDE GROUP/TIES address groups through these.
        var groupStarts = std.ArrayList(usize).empty;
        defer groupStarts.deinit(allocator);
        for (0..n) |j| if (peerStarts[j] == j) try groupStarts.append(allocator, j);
        const groupOf = try allocator.alloc(usize, n);
        defer allocator.free(groupOf);
        var groupScan: usize = 0;
        for (0..n) |j| {
            if (j != 0 and peerStarts[j] == j) groupScan += 1;
            groupOf[j] = groupScan;
        }
        // Scratch frame positions for the current row, reused per row.
        var included = std.ArrayList(usize).empty;
        defer included.deinit(allocator);

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
            var frameEnd: usize = 0;

            // Scratch positions refill every row (ranking/lead/lag rows above
            // `continue` with it empty, so no stale entries survive).
            included.clearRetainingCapacity();

            if (w.frame) |fr| {
                const currentValues = ctx.rows[originalRowIdx];
                const rangeByValue = fr.kind == .range and (isOffsetBound(fr.start) or (fr.end != null and isOffsetBound(fr.end.?)));
                if (fr.kind == .groups) {
                    // GROUPS offsets count peer groups, not rows.
                    const sOff = try evalFrameOffset(allocator, ctx, fr.startOffset, currentValues);
                    const eOff = try evalFrameOffset(allocator, ctx, fr.endOffset, currentValues);
                    const g = groupOf[p];
                    const gCount = groupStarts.items.len;
                    const satAdd = struct {
                        fn run(a: usize, b: usize, cap: usize) usize {
                            if (b >= cap or a >= cap) return cap - 1;
                            return @min(cap - 1, a + b);
                        }
                    }.run;
                    switch (fr.start) {
                        .unboundedPreceding => frameStart = 0,
                        .currentRow => frameStart = peerStarts[p],
                        .preceding => frameStart = groupStarts.items[if (sOff >= g) 0 else g - sOff],
                        .following => frameStart = groupStarts.items[satAdd(g, sOff, gCount)],
                        .unboundedFollowing => frameStart = n - 1,
                    }
                    const endBound = fr.end orelse .currentRow;
                    switch (endBound) {
                        .unboundedPreceding => frameEnd = 0,
                        .currentRow => frameEnd = peerEnds[p],
                        .preceding => frameEnd = peerEnds[groupStarts.items[if (eOff >= g) 0 else g - eOff]],
                        .following => frameEnd = peerEnds[groupStarts.items[satAdd(g, eOff, gCount)]],
                        .unboundedFollowing => frameEnd = n - 1,
                    }
                } else if (rangeByValue) {
                    // RANGE with offsets compares the single ORDER BY key by
                    // value (`key in [K-off, K+off]`); NULL keys keep peers
                    // only, non-numeric keys collapse offsets to CURRENT ROW.
                    if (numOrderKeys != 1) return error.InvalidSql;
                    const key = orderKeys.items[originalRowIdx];
                    if (key == .null) {
                        frameStart = peerStarts[p];
                        frameEnd = peerEnds[p];
                    } else if (rangeNumber(key)) |knum| {
                        const sOff = if (isOffsetBound(fr.start)) try evalFrameOffset(allocator, ctx, fr.startOffset, currentValues) else 0;
                        const eOff = if (fr.end != null and isOffsetBound(fr.end.?)) try evalFrameOffset(allocator, ctx, fr.endOffset, currentValues) else 0;
                        const shift = struct {
                            fn run(base: RangeNum, off: usize, negative: bool) RangeNum {
                                if (base == .real) {
                                    const delta: f64 = @floatFromInt(off);
                                    return .{ .real = if (negative) base.real - delta else base.real + delta };
                                }
                                const wide: i128 = base.int;
                                return .{ .int = if (negative) wide - off else wide + off };
                            }
                        }.run;
                        const lower: RangeEdge = switch (fr.start) {
                            .unboundedPreceding => .negInf,
                            .currentRow => .{ .num = knum },
                            .preceding => .{ .num = shift(knum, sOff, true) },
                            .following => .{ .num = shift(knum, sOff, false) },
                            .unboundedFollowing => .posInf,
                        };
                        const endBound = fr.end orelse .currentRow;
                        const upper: RangeEdge = switch (endBound) {
                            .unboundedPreceding => .negInf,
                            .currentRow => .{ .num = knum },
                            .preceding => .{ .num = shift(knum, eOff, true) },
                            .following => .{ .num = shift(knum, eOff, false) },
                            .unboundedFollowing => .posInf,
                        };
                        for (0..n) |j| {
                            if (frameRowExcluded(fr.exclude, p, j, peerStarts, peerEnds)) continue;
                            const candidate = orderKeys.items[partIndices[j]];
                            if (candidate == .null) continue;
                            const jnum = rangeNumber(candidate) orelse continue;
                            const aboveLower = lower == .negInf or rangeNumLessEqual(lower.num, jnum);
                            const belowUpper = upper == .posInf or rangeNumLessEqual(jnum, upper.num);
                            if (aboveLower and belowUpper) try included.append(allocator, j);
                        }
                    } else {
                        // Non-numeric key: still validate offsets, then treat
                        // offset bounds as CURRENT ROW (reference behavior).
                        if (isOffsetBound(fr.start)) _ = try evalFrameOffset(allocator, ctx, fr.startOffset, currentValues);
                        if (fr.end != null and isOffsetBound(fr.end.?)) _ = try evalFrameOffset(allocator, ctx, fr.endOffset, currentValues);
                        switch (fr.start) {
                            .unboundedPreceding => frameStart = 0,
                            .currentRow, .preceding, .following => frameStart = peerStarts[p],
                            .unboundedFollowing => frameStart = n - 1,
                        }
                        const endBound = fr.end orelse .currentRow;
                        switch (endBound) {
                            .unboundedPreceding => frameEnd = 0,
                            .currentRow, .preceding, .following => frameEnd = peerEnds[p],
                            .unboundedFollowing => frameEnd = n - 1,
                        }
                    }
                } else {
                    // ROWS, or RANGE over CURRENT ROW/UNBOUNDED bounds only
                    // (peer semantics, no value scan needed).
                    const sOff = try evalFrameOffset(allocator, ctx, fr.startOffset, currentValues);
                    const eOff = try evalFrameOffset(allocator, ctx, fr.endOffset, currentValues);
                    switch (fr.start) {
                        .unboundedPreceding => frameStart = 0,
                        .currentRow => frameStart = if (fr.kind == .range) peerStarts[p] else p,
                        .preceding => frameStart = if (sOff > p) 0 else p - sOff,
                        .following => frameStart = if (sOff >= n) n else @min(n, p + sOff),
                        .unboundedFollowing => frameStart = n - 1,
                    }
                    const endBound = fr.end orelse .currentRow;
                    switch (endBound) {
                        .unboundedPreceding => frameEnd = 0,
                        .currentRow => frameEnd = if (fr.kind == .range) peerEnds[p] else p,
                        .preceding => frameEnd = if (eOff > p) 0 else p - eOff,
                        .following => frameEnd = @min(n - 1, p + @min(eOff, n)),
                        .unboundedFollowing => frameEnd = n - 1,
                    }
                }
                if (frameStart <= frameEnd and frameStart < n) {
                    const stop = @min(n - 1, frameEnd);
                    var idx = frameStart;
                    while (idx <= stop) : (idx += 1) {
                        if (!frameRowExcluded(fr.exclude, p, idx, peerStarts, peerEnds)) try included.append(allocator, idx);
                    }
                }
            } else {
                if (w.orderBy.len > 0) {
                    frameStart = 0;
                    frameEnd = peerEnds[p];
                } else {
                    frameStart = 0;
                    frameEnd = n - 1;
                }
                if (frameStart <= frameEnd and frameStart < n) {
                    const stop = @min(n - 1, frameEnd);
                    var idx = frameStart;
                    while (idx <= stop) : (idx += 1) try included.append(allocator, idx);
                }
            }

            if (std.ascii.eqlIgnoreCase(name, "first_value")) {
                if (included.items.len == 0 or w.argument == null) {
                    results[originalRowIdx] = .null;
                } else {
                    const targetRow = ctx.rows[partIndices[included.items[0]]];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, targetRow);
                    defer freeWindowTemp(allocator, w.argument.?.*, raw);
                    results[originalRowIdx] = try raw.clone(allocator);
                }
                included.clearRetainingCapacity();
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "last_value")) {
                if (included.items.len == 0 or w.argument == null) {
                    results[originalRowIdx] = .null;
                } else {
                    const targetRow = ctx.rows[partIndices[included.items[included.items.len - 1]]];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, targetRow);
                    defer freeWindowTemp(allocator, w.argument.?.*, raw);
                    results[originalRowIdx] = try raw.clone(allocator);
                }
                included.clearRetainingCapacity();
                continue;
            }
            if (std.ascii.eqlIgnoreCase(name, "nth_value")) {
                if (included.items.len == 0 or w.argument == null or w.argument2 == null) {
                    results[originalRowIdx] = .null;
                    included.clearRetainingCapacity();
                    continue;
                }
                const nVal = try ctx.evalFn(ctx.evalCtx, w.argument2.?.*, ctx.rows[originalRowIdx]);
                defer freeWindowTemp(allocator, w.argument2.?.*, nVal);
                const nth: i64 = switch (nVal) {
                    .integer => |i| i,
                    .real => |r| @intFromFloat(r),
                    else => 0,
                };
                if (nth <= 0 or @as(usize, @intCast(nth - 1)) >= included.items.len) {
                    results[originalRowIdx] = .null;
                } else {
                    const targetOffset = @as(usize, @intCast(nth - 1));
                    const targetRow = ctx.rows[partIndices[included.items[targetOffset]]];
                    const raw = try ctx.evalFn(ctx.evalCtx, w.argument.?.*, targetRow);
                    defer freeWindowTemp(allocator, w.argument.?.*, raw);
                    results[originalRowIdx] = try raw.clone(allocator);
                }
                included.clearRetainingCapacity();
                continue;
            }

            if (AggKind.fromName(name)) |aggKind| {
                var aggState = AggState.init(allocator, aggKind, ",");
                defer aggState.deinit();

                for (included.items) |idx| {
                    const targetRow = ctx.rows[partIndices[idx]];
                    if (!try windowRowPassesFilter(allocator, ctx, w.filter, targetRow)) continue;
                    if (w.argument) |arg| {
                        if (arg.* == .wildcard) {
                            aggState.stepWildcard();
                        } else {
                            const argVal = try ctx.evalFn(ctx.evalCtx, arg.*, targetRow);
                            defer freeWindowTemp(allocator, arg.*, argVal);
                            try aggState.step(argVal, w.distinct);
                        }
                    } else {
                        aggState.stepWildcard();
                    }
                }
                results[originalRowIdx] = try aggState.final();
                included.clearRetainingCapacity();
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
