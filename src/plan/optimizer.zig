const std = @import("std");

pub fn isConstantTrue(value: bool) bool {
    return value;
}
pub fn isConstantFalse(value: bool) bool {
    return !value;
}

test "optimizer identifies boolean constants" {
    try std.testing.expect(isConstantTrue(true));
    try std.testing.expect(isConstantFalse(false));
}
