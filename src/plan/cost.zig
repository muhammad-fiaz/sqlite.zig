//! Query-plan cost model: unitless estimates comparing access paths.
//!
//! Purpose: tiny heuristic model behind `planner.zig` — table scans scale
//! with row count, index seeks divide by 10^eq-columns (x2 for ranges),
//! unique point lookups cost ~constant, sorts cost N log N, nested-loop joins
//! multiply. `Cost.compare` breaks ties on startup cost.
//!
//! Responsibilities: pure functions only; no schema access, no I/O. The
//! planner calls these to pick the cheapest `QueryPlan`.
//!
//! Dependencies: `std` only.
//!
//! Ownership/lifetime: all values (no allocation, no strings).
//!
//! Error behavior: infallible; row counts of 0 are clamped to 1 internally.
//!
//! Invariants: `rows` estimates are >= 1 for seeks; `ordered` is true exactly
//! for index-produced orders; costs are monotonic in row count.
//!
//! SQLite compatibility: heuristics only (SQLite uses sqlite_stat1); relative
//! order (unique < range < scan; covering cheaper) matches SQLite's planner.
// TODO(plan/cost): constants (10x per equality, 0.1/row, 0.05 sort factor)
// are untuned guesses with no calibration. Expected: stat-driven calibration
// or at least sensitivity tests locking relative order; tests: TPC-H-ish row
// counts asserting plan stability. Subsystem: plan/cost.

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
