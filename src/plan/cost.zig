const std = @import("std");

pub const Cost = struct { startup: f64, total: f64, rows: usize };
pub fn tableScan(rows: usize) Cost {
    return .{ .startup = 1, .total = @floatFromInt(rows), .rows = rows };
}
pub fn indexSeek(rows: usize) Cost {
    return .{ .startup = 2, .total = 2 + @as(f64, @floatFromInt(rows)) * 0.1, .rows = rows };
}

test "planner costs favor indexed selective access" {
    try std.testing.expect(indexSeek(10).total < tableScan(1000).total);
}
