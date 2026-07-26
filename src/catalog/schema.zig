const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");

pub const Column = struct { name: []u8, type_name: []u8, primary_key: bool, not_null: bool };
pub const Row = struct { values: []Value };
pub const Table = struct { name: []u8, columns: []Column, rows: std.ArrayList(Row) };

pub const Schema = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(Table),

    pub fn init(allocator: std.mem.Allocator) Schema {
        return .{ .allocator = allocator, .tables = .empty };
    }

    pub fn deinit(self: *Schema) void {
        for (self.tables.items) |*table| {
            for (table.rows.items) |row| {
                for (row.values) |value| freeValue(self.allocator, value);
                self.allocator.free(row.values);
            }
            table.rows.deinit(self.allocator);
            for (table.columns) |column| {
                self.allocator.free(column.name);
                self.allocator.free(column.type_name);
            }
            self.allocator.free(table.columns);
            self.allocator.free(table.name);
        }
        self.tables.deinit(self.allocator);
    }

    fn freeValue(allocator: std.mem.Allocator, value: Value) void {
        switch (value) {
            .text => |v| allocator.free(v),
            .blob => |v| allocator.free(v),
            else => {},
        }
    }
    fn copyValue(self: *Schema, value: Value) !Value {
        return switch (value) {
            .text => |v| .{ .text = try self.allocator.dupe(u8, v) },
            .blob => |v| .{ .blob = try self.allocator.dupe(u8, v) },
            else => value,
        };
    }

    pub fn find(self: *Schema, name: []const u8) ?*Table {
        for (self.tables.items) |*table| if (std.ascii.eqlIgnoreCase(table.name, name)) return table;
        return null;
    }
    pub fn findConst(self: *const Schema, name: []const u8) ?*const Table {
        for (self.tables.items) |*table| if (std.ascii.eqlIgnoreCase(table.name, name)) return table;
        return null;
    }

    pub fn createTable(self: *Schema, name: []const u8, definitions: []const ast.ColumnDef) !void {
        if (self.find(name) != null) return error.TableExists;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const columns = try self.allocator.alloc(Column, definitions.len);
        errdefer self.allocator.free(columns);
        var count: usize = 0;
        errdefer for (columns[0..count]) |column| {
            self.allocator.free(column.name);
            self.allocator.free(column.type_name);
        };
        for (definitions, 0..) |definition, index| {
            columns[index] = .{ .name = try self.allocator.dupe(u8, definition.name), .type_name = try self.allocator.dupe(u8, definition.type_name), .primary_key = definition.primary_key, .not_null = definition.not_null };
            count += 1;
        }
        try self.tables.append(self.allocator, .{ .name = owned_name, .columns = columns, .rows = .empty });
    }

    pub fn dropTable(self: *Schema, name: []const u8) !void {
        for (self.tables.items, 0..) |*table, index| {
            if (std.ascii.eqlIgnoreCase(table.name, name)) {
                self.removeTable(index);
                return;
            }
        }
        return error.UnknownTable;
    }

    fn removeTable(self: *Schema, index: usize) void {
        var table = self.tables.orderedRemove(index);
        for (table.rows.items) |row| {
            for (row.values) |value| freeValue(self.allocator, value);
            self.allocator.free(row.values);
        }
        table.rows.deinit(self.allocator);
        for (table.columns) |column| {
            self.allocator.free(column.name);
            self.allocator.free(column.type_name);
        }
        self.allocator.free(table.columns);
        self.allocator.free(table.name);
    }

    pub fn appendRow(self: *Schema, table: *Table, values: []const Value) !void {
        if (values.len != table.columns.len) return error.ColumnCountMismatch;
        const owned = try self.allocator.alloc(Value, values.len);
        errdefer self.allocator.free(owned);
        var count: usize = 0;
        errdefer for (owned[0..count]) |value| freeValue(self.allocator, value);
        for (values, 0..) |value, index| {
            if (table.columns[index].not_null and value == .null) return error.ConstraintViolation;
            owned[index] = try self.copyValue(value);
            count += 1;
        }
        try table.rows.append(self.allocator, .{ .values = owned });
    }

    pub fn clone(self: *const Schema) !Schema {
        var result = Schema.init(self.allocator);
        errdefer result.deinit();
        for (self.tables.items) |table| {
            const definitions = try self.allocator.alloc(ast.ColumnDef, table.columns.len);
            defer self.allocator.free(definitions);
            for (table.columns, 0..) |column, index| definitions[index] = .{ .name = column.name, .type_name = column.type_name, .primary_key = column.primary_key, .not_null = column.not_null };
            try result.createTable(table.name, definitions);
            const target = result.find(table.name).?;
            for (table.rows.items) |row| try result.appendRow(target, row.values);
        }
        return result;
    }
};

test "schema owns tables and rows" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{ .{ .name = "id", .type_name = "INTEGER" }, .{ .name = "name", .type_name = "TEXT" } };
    try schema.createTable("users", &defs);
    var values = [_]Value{ .{ .integer = 1 }, .{ .text = "A" } };
    try schema.appendRow(schema.find("users").?, &values);
    try std.testing.expectEqual(@as(usize, 1), schema.find("users").?.rows.items.len);
}
