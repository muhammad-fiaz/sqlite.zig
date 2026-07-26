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
    const null_value: Value = .null;
    const integer_value: Value = .{ .integer = 4 };
    try std.testing.expect(null_value.isNull());
    try std.testing.expectEqualStrings("integer", integer_value.typeName());
}
