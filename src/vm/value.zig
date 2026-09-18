const std = @import("std");

pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null => "null",
            .integer => "integer",
            .real => "real",
            .text => "text",
            .blob => "blob",
        };
    }
};

test "sql values expose stable types" {
    const nullValue: Value = .null;
    const integerValue: Value = .{ .integer = 4 };
    try std.testing.expect(nullValue.isNull());
    try std.testing.expectEqualStrings("integer", integerValue.typeName());
}
