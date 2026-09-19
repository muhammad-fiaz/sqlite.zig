const std = @import("std");

pub const Cost = struct {
    startup: f64,
    total: f64,
    rows: usize,
    ordered: bool = false,

    pub fn compare(self: Cost, other: Cost) std.math.Order {
        if (self.total < other.total) return .lt;
        if (self.total > other.total) return .gt;
        return std.math.order(self.startup, other.startup);
    }
};

pub fn tableScan(rows: usize) Cost {
    const r: f64 = @floatFromInt(@max(rows, 1));
    return .{
        .startup = 1.0,
        .total = r * 1.0,
        .rows = rows,
        .ordered = false,
    };
}

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

pub fn rowidLookup(rows: usize) Cost {
    _ = rows;
    return .{
        .startup = 1.5,
        .total = 2.5,
        .rows = 1,
        .ordered = true,
    };
}

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
