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
    var idName = "id".*;
    var intName = "INTEGER".*;
    const columns = [_]Column{.{ .name = &idName, .typeName = &intName, .primaryKey = false, .notNull = false }};
    const definition = TableDef{ .name = "users", .columns = &columns };
    try std.testing.expect(definition.column("ID") != null);
}
