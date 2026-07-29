const std = @import("std");
const Column = @import("column.zig").Column;

pub const ColumnKey = struct { table: []const u8, name: []const u8 };

pub fn table(comptime name: []const u8, comptime Row: type) type {
    return struct {
        pub const table_name = name;
        pub const row_type = Row;

        pub fn column(comptime column_name: []const u8) Column(name, column_name, @TypeOf(@field(@as(Row, undefined), column_name))) {
            if (!@hasField(Row, column_name)) @compileError("unknown table column");
            return .{};
        }

        pub fn key(comptime column_name: []const u8) ColumnKey {
            if (!@hasField(Row, column_name)) @compileError("unknown table key column");
            return .{ .table = name, .name = column_name };
        }

        pub fn columns() [@typeInfo(Row).@"struct".fields.len][]const u8 {
            var result: [@typeInfo(Row).@"struct".fields.len][]const u8 = undefined;
            inline for (@typeInfo(Row).@"struct".fields, 0..) |field, index| result[index] = field.name;
            return result;
        }
    };
}

test "typed table exposes checked column types" {
    const User = table("users", struct { id: i64, name: []const u8 });
    const id = User.column("id");
    try std.testing.expectEqualStrings("id", @TypeOf(id).name);
}
