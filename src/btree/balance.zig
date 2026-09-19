const std = @import("std");

pub fn splitPoint(itemCount: usize, pageCapacity: usize) usize {
    if (itemCount == 0) return 0;
    const midpoint = itemCount / 2;
    return if (midpoint == 0) 1 else if (midpoint >= pageCapacity) pageCapacity - 1 else midpoint;
}

pub fn splitPointByBytes(cellSizes: []const usize, targetLimit: usize) usize {
    if (cellSizes.len == 0) return 0;
    var accumulated: usize = 0;
    for (cellSizes, 0..) |size, index| {
        accumulated += size + 2;
        if (accumulated >= targetLimit and index > 0) {
            return index;
        }
    }
    return if (cellSizes.len > 1) cellSizes.len / 2 else 0;
}

pub fn maxLocalPayload(pageSize: usize) usize {
    if (pageSize < 35) return 0;
    return pageSize - 35;
}

pub fn minLocalPayload(pageSize: usize) usize {
    if (pageSize < 12) return 0;
    return ((pageSize - 12) * 32 / 255) - 23;
}

pub fn localPayloadSize(payloadSize: usize, pageSize: usize) usize {
    const maxLocal = maxLocalPayload(pageSize);
    if (payloadSize <= maxLocal) return payloadSize;
    const minLocal = minLocalPayload(pageSize);
    const usableMinus4 = if (pageSize > 4) pageSize - 4 else 1;
    const surplus = minLocal + (payloadSize - minLocal) % usableMinus4;
    return if (surplus <= maxLocal) surplus else minLocal;
}

test "balance chooses a bounded split point" {
    try std.testing.expectEqual(@as(usize, 4), splitPoint(9, 8));
    try std.testing.expectEqual(@as(usize, 0), splitPoint(0, 8));
}

test "balance chooses byte-based split point" {
    const sizes = [_]usize{ 100, 200, 300, 400 };
    const split = splitPointByBytes(&sizes, 350);
    try std.testing.expectEqual(@as(usize, 2), split);
}

test "payload local size calculation matches SQLite formulas" {
    const pageSize: usize = 4096;
    const maxLocal = maxLocalPayload(pageSize);
    try std.testing.expectEqual(@as(usize, 4061), maxLocal);
    const smallPayload: usize = 500;
    try std.testing.expectEqual(smallPayload, localPayloadSize(smallPayload, pageSize));
    const largePayload: usize = 10000;
    const local = localPayloadSize(largePayload, pageSize);
    try std.testing.expect(local <= maxLocal);
    try std.testing.expect(local >= minLocalPayload(pageSize));
}
