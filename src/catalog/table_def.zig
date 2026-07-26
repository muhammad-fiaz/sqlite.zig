const std = @import("std");
const Column = @import("schema.zig").Column;

pub const TableDef = struct {
    name: []const u8,
    columns: []const Column,

    pub fn column(self: TableDef, name: []const u8) ?Column {
        for (self.columns) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) return item;
        return null;
    }
};

test "table definition resolves columns case insensitively" {
    const columns = [_]Column{.{ .name = "id", .type_name = "INTEGER", .primary_key = false, .not_null = false }};
    const definition = TableDef{ .name = "users", .columns = &columns };
    try std.testing.expect(definition.column("ID") != null);
}
