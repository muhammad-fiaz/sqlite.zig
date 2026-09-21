//! Heuristic costs for comparing query plans.
//!
//! Pure functions over row counts; no allocation.
//! Zero rows clamp to one; cheaper `total` wins.

const std = @import("std");

/// Estimated cost of one access path: startup + total + row estimate.
pub const Cost = struct {
    /// One-time setup cost (seek open, sort init).
    startup: f64,
    /// Total cost used for comparison (startup + per-row work).
    total: f64,
    /// Estimated output rows.
    rows: usize,
    /// True when output arrives in index order (can elide sorts).
    ordered: bool = false,

    /// Cheapest-first order: lower `total` wins, ties broken by `startup`.
    pub fn compare(self: Cost, other: Cost) std.math.Order {
        if (self.total < other.total) return .lt;
        if (self.total > other.total) return .gt;
        return std.math.order(self.startup, other.startup);
    }
};

/// Full table scan: O(N) with unit per-row cost; never ordered.
pub fn tableScan(rows: usize) Cost {
    const r: f64 = @floatFromInt(@max(rows, 1));
    return .{
        .startup = 1.0,
        .total = r * 1.0,
        .rows = rows,
        .ordered = false,
    };
}

/// Index seek: unique point lookup is ~constant; else rows shrink 10x per equality (2x for range).
pub fn indexSeek(rows: usize, eqCount: usize, hasRange: bool, isUnique: bool) Cost {
    const totalRows: f64 = @floatFromInt(@max(rows, 1));
    const seekStartup = 2.0;
    if (isUnique and eqCount > 0 and !hasRange) {
        return .{
            .startup = seekStartup,
            .total = seekStartup + 1.0,
            .rows = 1,
            .ordered = true,
        };
    }
    var reduction: f64 = 1.0;
    var i: usize = 0;
    while (i < eqCount) : (i += 1) {
        reduction *= 10.0;
    }
    if (hasRange) {
        reduction *= 2.0;
    }
    const estRows = @max(1, @as(usize, @intFromFloat(@ceil(totalRows / reduction))));
    const scanCost = @as(f64, @floatFromInt(estRows)) * 0.1;
    return .{
        .startup = seekStartup,
        .total = seekStartup + scanCost,
        .rows = estRows,
        .ordered = true,
    };
}

/// Rowid point lookup: ~constant cost, one row, ordered.
pub fn rowidLookup(rows: usize) Cost {
    _ = rows;
    return .{
        .startup = 1.5,
        .total = 2.5,
        .rows = 1,
        .ordered = true,
    };
}

/// Temp B-tree sort: N log N scaled by 0.05; output ordered.
pub fn sortCost(rows: usize) Cost {
    const r: f64 = @floatFromInt(@max(rows, 1));
    const logVal = if (r > 1.0) @log2(r) else 1.0;
    const cost = r * logVal * 0.05;
    return .{
        .startup = cost,
        .total = cost,
        .rows = rows,
        .ordered = true,
    };
}

/// Nested-loop join: outer + outer-rows * inner; inherits outer ordering.
pub fn joinCost(outerCost: Cost, innerCost: Cost) Cost {
    const outerRows: f64 = @floatFromInt(@max(outerCost.rows, 1));
    return .{
        .startup = outerCost.startup + innerCost.startup,
        .total = outerCost.total + (outerRows * innerCost.total),
        .rows = outerCost.rows * @max(1, innerCost.rows / 10),
        .ordered = outerCost.ordered,
    };
}

test "planner costs favor indexed selective access" {
    try std.testing.expect(indexSeek(10, 1, false, false).total < tableScan(1000).total);
}

test "cost calculation models unique lookup and range scans" {
    const uniqueCost = indexSeek(10000, 1, false, true);
    const rangeCost = indexSeek(10000, 1, true, false);
    const scan = tableScan(10000);

    try std.testing.expect(uniqueCost.total < rangeCost.total);
    try std.testing.expect(rangeCost.total < scan.total);
    try std.testing.expectEqual(@as(usize, 1), uniqueCost.rows);
}

test "sort cost scales with row count" {
    const sortSmall = sortCost(10);
    const sortLarge = sortCost(1000);
    try std.testing.expect(sortSmall.total < sortLarge.total);
}

test "cost edge cases clamp and order deterministically" {
    // Zero-row tables clamp to 1 row internally rather than costing zero.
    try std.testing.expectEqual(@as(usize, 1), indexSeek(0, 0, false, false).rows);
    try std.testing.expect(tableScan(0).total > 0);
    // Tie-break on startup: identical totals compare by startup.
    const a = Cost{ .startup = 1.0, .total = 5.0, .rows = 1 };
    const b = Cost{ .startup = 2.0, .total = 5.0, .rows = 1 };
    try std.testing.expectEqual(std.math.Order.lt, a.compare(b));
    // Join cost grows with inner size.
    const j1 = joinCost(tableScan(10), tableScan(10));
    const j2 = joinCost(tableScan(10), tableScan(100));
    try std.testing.expect(j1.total < j2.total);
}

test "cost plan choices stay stable across row-count scales" {
    // Sensitivity pins: these relative orders are what the planner decides
    // by. Retuning the constants above must update these expectations on
    // purpose, not by accident.
    const scales = [_]usize{ 10, 1000, 100000, 1000000 };
    for (scales) |rows| {
        // A selective single-equality seek beats a full scan at every scale.
        try std.testing.expect(indexSeek(rows, 1, false, false).total < tableScan(rows).total);
        // Unique seeks stay constant while scans grow.
        try std.testing.expect(indexSeek(rows, 1, false, true).total < tableScan(rows).total);
        // Rowid lookups stay constant too.
        try std.testing.expect(rowidLookup(rows).total < tableScan(rows).total);
        // Nested-loop inner seeks beat inner scans as the inner side grows.
        const nestedSeek = joinCost(tableScan(100), indexSeek(rows, 1, false, false));
        const nestedScan = joinCost(tableScan(100), tableScan(rows));
        try std.testing.expect(nestedSeek.total < nestedScan.total);
    }
    // Tiny tables scan: the seek startup cost exceeds a 1-row scan.
    try std.testing.expect(tableScan(1).total < indexSeek(1, 1, false, false).total);
    try std.testing.expect(tableScan(0).total < rowidLookup(0).total);
    // More equality terms only ever narrow the estimate.
    try std.testing.expect(indexSeek(100000, 2, false, false).rows < indexSeek(100000, 1, false, false).rows);
}
