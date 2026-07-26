const std = @import("std");

pub fn splitPoint(item_count: usize, page_capacity: usize) usize {
    if (item_count == 0) return 0;
    const midpoint = item_count / 2;
    return if (midpoint == 0) 1 else if (midpoint >= page_capacity) page_capacity - 1 else midpoint;
}

test "balance chooses a bounded split point" {
    try std.testing.expectEqual(@as(usize, 4), splitPoint(9, 8));
    try std.testing.expectEqual(@as(usize, 0), splitPoint(0, 8));
}
