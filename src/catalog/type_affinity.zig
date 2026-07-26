const std = @import("std");
const Value = @import("../vm/value.zig").Value;

pub const Affinity = enum { blob, text, numeric, integer, real };

pub fn fromDeclaration(declaration: []const u8) Affinity {
    if (std.ascii.indexOfIgnoreCase(declaration, "INT")) |_| return .integer;
    if (std.ascii.indexOfIgnoreCase(declaration, "CHAR")) |_| return .text;
    if (std.ascii.indexOfIgnoreCase(declaration, "CLOB")) |_| return .text;
    if (std.ascii.indexOfIgnoreCase(declaration, "TEXT")) |_| return .text;
    if (std.ascii.indexOfIgnoreCase(declaration, "REAL")) |_| return .real;
    if (std.ascii.indexOfIgnoreCase(declaration, "FLOA")) |_| return .real;
    if (std.ascii.indexOfIgnoreCase(declaration, "DOUB")) |_| return .real;
    if (std.ascii.indexOfIgnoreCase(declaration, "BLOB")) |_| return .blob;
    return .numeric;
}

pub fn apply(affinity: Affinity, value: Value) Value {
    return switch (affinity) {
        .integer => switch (value) {
            .real => |n| .{ .integer = @intFromFloat(n) },
            else => value,
        },
        .real => switch (value) {
            .integer => |n| .{ .real = @floatFromInt(n) },
            else => value,
        },
        else => value,
    };
}

test "type declarations map to SQLite affinities" {
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("INTEGER PRIMARY KEY"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("VARCHAR(80)"));
    try std.testing.expectEqual(Affinity.real, fromDeclaration("DOUBLE"));
}
