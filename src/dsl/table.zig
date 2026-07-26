const std = @import("std");
const Column = @import("column.zig").Column;

pub fn table(comptime name: []const u8, comptime Row: type) type {
    return struct {
        pub const table_name = name;
        pub const row_type = Row;

        pub fn column(comptime column_name: []const u8) Column(name, column_name, @TypeOf(@field(@as(Row, undefined), column_name))) {
            if (!@hasField(Row, column_name)) @compileError("unknown table column");
            return .{};
        }

        pub fn columns() []const std.builtin.Type.StructField {
            return @typeInfo(Row).@"struct".fields;
        }
    };
}

test "typed table exposes checked column types" {
    const User = table("users", struct { id: i64, name: []const u8 });
    const id = User.column("id");
    try std.testing.expectEqualStrings("id", id.name);
}
