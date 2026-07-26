const std = @import("std");
const Cost = @import("cost.zig").Cost;

pub const Access = enum { table_scan, index_seek };
pub const Plan = struct { access: Access, cost: Cost };

pub fn choose(row_count: usize, has_index: bool, selective: bool) Plan {
    if (has_index and selective) return .{ .access = .index_seek, .cost = @import("cost.zig").indexSeek(row_count) };
    return .{ .access = .table_scan, .cost = @import("cost.zig").tableScan(row_count) };
}

test "planner chooses table scan or index seek" {
    try std.testing.expectEqual(Access.index_seek, choose(100, true, true).access);
    try std.testing.expectEqual(Access.table_scan, choose(100, false, true).access);
}
