const std = @import("std");
const Cost = @import("cost.zig").Cost;

pub const Access = enum { tableScan, indexSeek };
pub const Plan = struct { access: Access, cost: Cost };

pub fn choose(rowCount: usize, hasIndex: bool, selective: bool) Plan {
    if (hasIndex and selective) return .{ .access = .indexSeek, .cost = @import("cost.zig").indexSeek(rowCount) };
    return .{ .access = .tableScan, .cost = @import("cost.zig").tableScan(rowCount) };
}

test "planner chooses table scan or index seek" {
    try std.testing.expectEqual(Access.indexSeek, choose(100, true, true).access);
    try std.testing.expectEqual(Access.tableScan, choose(100, false, true).access);
}
