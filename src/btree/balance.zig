//! Split points and local-payload sizes for b-tree pages.
//!
//! Pure helpers over borrowed slices; no allocation and no failures.

const std = @import("std");

/// Chooses a count-based split index for `itemCount` items.
pub fn splitPoint(itemCount: usize, pageCapacity: usize) usize {
    if (itemCount == 0) return 0;
    if (pageCapacity == 0) return 0;
    const midpoint = itemCount / 2;
    return if (midpoint == 0) 1 else if (midpoint >= pageCapacity) pageCapacity - 1 else midpoint;
}

/// Chooses a byte-based split index so the left side reaches `targetLimit`.
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

/// Maximum payload bytes kept on a leaf page (`pageSize - 35`, else 0).
pub fn maxLocalPayload(pageSize: usize) usize {
    if (pageSize < 35) return 0;
    return pageSize - 35;
}

/// Minimum local payload for overflowed cells, else 0.
pub fn minLocalPayload(pageSize: usize) usize {
    if (pageSize < 12) return 0;
    return ((pageSize - 12) * 32 / 255) - 23;
}

/// Local byte count for `payloadSize` on `pageSize` pages.
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

test "balance degrades safely on degenerate inputs" {
    // Boundary: zero capacity cannot underflow into a huge split index.
    try std.testing.expectEqual(@as(usize, 0), splitPoint(9, 0));
    try std.testing.expectEqual(@as(usize, 0), splitPoint(1, 0));
    // Boundary: single items and exact-capacity midpoints stay in range.
    try std.testing.expectEqual(@as(usize, 1), splitPoint(1, 8));
    try std.testing.expectEqual(@as(usize, 1), splitPoint(2, 8));
    try std.testing.expectEqual(@as(usize, 7), splitPoint(100, 8));
    // Boundary: empty and single-cell byte splits return 0 (never split).
    try std.testing.expectEqual(@as(usize, 0), splitPointByBytes(&[_]usize{}, 100));
    try std.testing.expectEqual(@as(usize, 0), splitPointByBytes(&[_]usize{1000}, 10));
    // Boundary: zero target still yields a valid (non-first) split.
    const sizes = [_]usize{ 100, 200, 300 };
    const splitZero = splitPointByBytes(&sizes, 0);
    try std.testing.expect(splitZero < sizes.len);
    // Boundary: undersized pages report zero local payload, no underflow.
    try std.testing.expectEqual(@as(usize, 0), maxLocalPayload(34));
    try std.testing.expectEqual(@as(usize, 0), minLocalPayload(11));
    try std.testing.expectEqual(@as(usize, 0), localPayloadSize(100, 10));
    // Normal: exact-max payloads stay whole; max+1 spills into range.
    try std.testing.expectEqual(@as(usize, 4061), localPayloadSize(4061, 4096));
    const spilled = localPayloadSize(4062, 4096);
    try std.testing.expect(spilled <= maxLocalPayload(4096));
    try std.testing.expect(spilled >= minLocalPayload(4096));
}
