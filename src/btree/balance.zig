const std = @import("std");

pub fn splitPoint(itemCount: usize, pageCapacity: usize) usize {
    if (itemCount == 0) return 0;
    const midpoint = itemCount / 2;
    return if (midpoint == 0) 1 else if (midpoint >= pageCapacity) pageCapacity - 1 else midpoint;
}

test "balance chooses a bounded split point" {
    try std.testing.expectEqual(@as(usize, 4), splitPoint(9, 8));
    try std.testing.expectEqual(@as(usize, 0), splitPoint(0, 8));
}
