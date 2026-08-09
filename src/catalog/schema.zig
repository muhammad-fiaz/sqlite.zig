const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");

pub const Column = struct { name: []u8, type_name: []u8, primary_key: bool, not_null: bool, unique: bool = false, default_value: ?Value = null, foreign_table: ?[]u8 = null, foreign_column: ?[]u8 = null, on_delete: ast.ReferentialAction = .restrict, on_update: ast.ReferentialAction = .restrict };
pub const Row = struct { values: []Value };
pub const Constraint = struct { kind: enum { primary_key, unique, foreign_key }, columns: [][]u8, foreign_table: ?[]u8 = null, referenced_columns: [][]u8 = &.{}, on_delete: ast.ReferentialAction = .restrict, on_update: ast.ReferentialAction = .restrict };
pub const Table = struct { name: []u8, columns: []Column, constraints: []Constraint, rows: std.ArrayList(Row), virtual_module: ?[]u8 = null, virtual_arguments: [][]u8 = &.{} };
pub const Index = struct { name: []u8, table: []u8, columns: [][]u8, unique: bool = false };
pub const View = struct { name: []u8, sql: []u8 };
pub const Trigger = struct { name: []u8, table: []u8, event: ast.TriggerEvent, body: []u8 };

pub const Schema = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(Table),
    indexes: std.ArrayList(Index),
    views: std.ArrayList(View),
    triggers: std.ArrayList(Trigger),
    foreign_keys_enabled: bool = true,

    pub fn init(allocator: std.mem.Allocator) Schema {
        return .{ .allocator = allocator, .tables = .empty, .indexes = .empty, .views = .empty, .triggers = .empty };
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
                if (column.default_value) |value| freeValue(self.allocator, value);
                if (column.foreign_table) |value| self.allocator.free(value);
                if (column.foreign_column) |value| self.allocator.free(value);
            }
            self.allocator.free(table.columns);
            for (table.constraints) |constraint| {
                for (constraint.columns) |column| self.allocator.free(column);
                self.allocator.free(constraint.columns);
                if (constraint.foreign_table) |foreign_table| self.allocator.free(foreign_table);
                for (constraint.referenced_columns) |column| self.allocator.free(column);
                self.allocator.free(constraint.referenced_columns);
            }
            self.allocator.free(table.constraints);
            if (table.virtual_module) |module| self.allocator.free(module);
            for (table.virtual_arguments) |argument| self.allocator.free(argument);
            self.allocator.free(table.virtual_arguments);
            self.allocator.free(table.name);
        }
        self.tables.deinit(self.allocator);
        for (self.indexes.items) |index| {
            self.allocator.free(index.name);
            self.allocator.free(index.table);
            for (index.columns) |column| self.allocator.free(column);
            self.allocator.free(index.columns);
        }
        self.indexes.deinit(self.allocator);
        for (self.views.items) |view| {
            self.allocator.free(view.name);
            self.allocator.free(view.sql);
        }
        self.views.deinit(self.allocator);
        for (self.triggers.items) |trigger| {
            self.allocator.free(trigger.name);
            self.allocator.free(trigger.table);
            self.allocator.free(trigger.body);
        }
        self.triggers.deinit(self.allocator);
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

    pub fn findIndex(self: *Schema, name: []const u8) ?*Index {
        for (self.indexes.items) |*index| if (std.ascii.eqlIgnoreCase(index.name, name)) return index;
        return null;
    }

    pub fn findIndexConst(self: *const Schema, name: []const u8) ?*const Index {
        for (self.indexes.items) |*index| if (std.ascii.eqlIgnoreCase(index.name, name)) return index;
        return null;
    }

    pub fn findView(self: *Schema, name: []const u8) ?*View {
        for (self.views.items) |*view| if (std.ascii.eqlIgnoreCase(view.name, name)) return view;
        return null;
    }

    pub fn findViewConst(self: *const Schema, name: []const u8) ?*const View {
        for (self.views.items) |*view| if (std.ascii.eqlIgnoreCase(view.name, name)) return view;
        return null;
    }

    pub fn createView(self: *Schema, name: []const u8, sql: []const u8) !void {
        if (self.find(name) != null or self.findIndexConst(name) != null or self.findView(name) != null) return error.ViewExists;
        try self.views.append(self.allocator, .{ .name = try self.allocator.dupe(u8, name), .sql = try self.allocator.dupe(u8, sql) });
    }

    pub fn dropView(self: *Schema, name: []const u8) !void {
        for (self.views.items, 0..) |view, position| if (std.ascii.eqlIgnoreCase(view.name, name)) {
            const removed = self.views.orderedRemove(position);
            self.allocator.free(removed.name);
            self.allocator.free(removed.sql);
            return;
        };
        return error.UnknownView;
    }

    pub fn findTrigger(self: *Schema, name: []const u8) ?*Trigger {
        for (self.triggers.items) |*trigger| if (std.ascii.eqlIgnoreCase(trigger.name, name)) return trigger;
        return null;
    }

    pub fn findTriggerConst(self: *const Schema, name: []const u8) ?*const Trigger {
        for (self.triggers.items) |*trigger| if (std.ascii.eqlIgnoreCase(trigger.name, name)) return trigger;
        return null;
    }

    pub fn createTrigger(self: *Schema, definition: ast.TriggerDef) !void {
        if (self.findTrigger(definition.name) != null) return error.TriggerExists;
        if (self.find(definition.table) == null) return error.UnknownTable;
        try self.triggers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, definition.name), .table = try self.allocator.dupe(u8, definition.table), .event = definition.event, .body = try self.allocator.dupe(u8, definition.body) });
    }

    pub fn dropTrigger(self: *Schema, name: []const u8) !void {
        for (self.triggers.items, 0..) |trigger, position| if (std.ascii.eqlIgnoreCase(trigger.name, name)) {
            const removed = self.triggers.orderedRemove(position);
            self.allocator.free(removed.name);
            self.allocator.free(removed.table);
            self.allocator.free(removed.body);
            return;
        };
        return error.UnknownTrigger;
    }

    pub fn createIndex(self: *Schema, definition: ast.IndexDef) !void {
        if (self.findIndex(definition.name) != null) return error.IndexExists;
        const table = self.find(definition.table) orelse return error.UnknownTable;
        if (definition.columns.len == 0) return error.InvalidSql;
        for (definition.columns) |name| if (self.columnIndex(table, name) == null) return error.UnknownColumn;
        const name = try self.allocator.dupe(u8, definition.name);
        errdefer self.allocator.free(name);
        const table_name = try self.allocator.dupe(u8, definition.table);
        errdefer self.allocator.free(table_name);
        const columns = try self.allocator.alloc([]u8, definition.columns.len);
        errdefer self.allocator.free(columns);
        var copied: usize = 0;
        errdefer for (columns[0..copied]) |column| self.allocator.free(column);
        for (definition.columns, 0..) |column, index| {
            columns[index] = try self.allocator.dupe(u8, column);
            copied += 1;
        }
        try self.indexes.append(self.allocator, .{ .name = name, .table = table_name, .columns = columns, .unique = definition.unique });
        if (definition.unique) {
            errdefer _ = self.indexes.pop();
            for (table.rows.items, 0..) |row, row_index| {
                for (table.rows.items[row_index + 1 ..]) |other| if (indexValuesEqual(table, row.values, other.values, definition.columns)) return error.ConstraintViolation;
            }
        }
    }

    pub fn dropIndex(self: *Schema, name: []const u8) !void {
        for (self.indexes.items, 0..) |index, position| if (std.ascii.eqlIgnoreCase(index.name, name)) {
            const removed = self.indexes.orderedRemove(position);
            self.allocator.free(removed.name);
            self.allocator.free(removed.table);
            for (removed.columns) |column| self.allocator.free(column);
            self.allocator.free(removed.columns);
            return;
        };
        return error.UnknownIndex;
    }

    pub fn createTable(self: *Schema, name: []const u8, definitions: []const ast.ColumnDef, definitions_constraints: []const ast.TableConstraint) !void {
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
            columns[index] = .{ .name = try self.allocator.dupe(u8, definition.name), .type_name = try self.allocator.dupe(u8, definition.type_name), .primary_key = definition.primary_key, .not_null = definition.not_null, .unique = definition.unique, .default_value = if (definition.default_value) |value| try self.copyValue(value) else null, .foreign_table = if (definition.foreign_key) |foreign_key| try self.allocator.dupe(u8, foreign_key.table) else null, .foreign_column = if (definition.foreign_key) |foreign_key| try self.allocator.dupe(u8, foreign_key.column) else null, .on_delete = if (definition.foreign_key) |foreign_key| foreign_key.on_delete else .restrict, .on_update = if (definition.foreign_key) |foreign_key| foreign_key.on_update else .restrict };
            count += 1;
        }
        const constraints = try self.allocator.alloc(Constraint, definitions_constraints.len);
        errdefer self.allocator.free(constraints);
        var constraint_count: usize = 0;
        errdefer for (constraints[0..constraint_count]) |constraint| {
            for (constraint.columns) |column| self.allocator.free(column);
            self.allocator.free(constraint.columns);
            if (constraint.foreign_table) |foreign_table| self.allocator.free(foreign_table);
            for (constraint.referenced_columns) |column| self.allocator.free(column);
            self.allocator.free(constraint.referenced_columns);
        };
        for (definitions_constraints, 0..) |definition, index| {
            const source_columns = switch (definition) {
                .primary_key => |value| value,
                .unique => |value| value,
                .foreign_key => |value| value.columns,
            };
            const copied_columns = try self.allocator.alloc([]u8, source_columns.len);
            var copied_count: usize = 0;
            errdefer for (copied_columns[0..copied_count]) |column| self.allocator.free(column);
            for (source_columns, 0..) |column, column_index| {
                if (self.columnIndexByName(definitions, column) == null) return error.UnknownColumn;
                copied_columns[column_index] = try self.allocator.dupe(u8, column);
                copied_count += 1;
            }
            constraints[index] = .{ .kind = switch (definition) {
                .primary_key => .primary_key,
                .unique => .unique,
                .foreign_key => .foreign_key,
            }, .columns = copied_columns };
            switch (definition) {
                .foreign_key => |foreign_key| {
                    if (foreign_key.referenced_columns.len != source_columns.len) return error.ConstraintViolation;
                    const referenced_columns = try self.allocator.alloc([]u8, foreign_key.referenced_columns.len);
                    for (foreign_key.referenced_columns, 0..) |column, column_index| {
                        referenced_columns[column_index] = try self.allocator.dupe(u8, column);
                        if (self.findConst(foreign_key.table)) |parent| {
                            if (self.columnIndex(parent, column) == null) return error.UnknownColumn;
                        }
                    }
                    constraints[index].foreign_table = try self.allocator.dupe(u8, foreign_key.table);
                    constraints[index].referenced_columns = referenced_columns;
                    constraints[index].on_delete = foreign_key.on_delete;
                    constraints[index].on_update = foreign_key.on_update;
                },
                else => {},
            }
            constraint_count += 1;
        }
        try self.tables.append(self.allocator, .{ .name = owned_name, .columns = columns, .constraints = constraints, .rows = .empty });
        var autoindex_number: usize = 0;
        for (constraints) |constraint| {
            if (constraint.kind == .foreign_key) continue;
            autoindex_number += 1;
            const index_name = try std.fmt.allocPrint(self.allocator, "sqlite_autoindex_{s}_{d}", .{ name, autoindex_number });
            const index_table = try self.allocator.dupe(u8, name);
            const index_columns = try self.allocator.alloc([]u8, constraint.columns.len);
            for (constraint.columns, 0..) |column, column_index| {
                index_columns[column_index] = try self.allocator.dupe(u8, column);
            }
            try self.indexes.append(self.allocator, .{ .name = index_name, .table = index_table, .columns = index_columns, .unique = true });
        }
    }

    pub fn createVirtualTable(self: *Schema, name: []const u8, module: []const u8, arguments: []const []const u8) !void {
        if (self.find(name) != null) return error.TableExists;
        if (!std.ascii.eqlIgnoreCase(module, "generate_series")) return error.Unsupported;
        if (arguments.len < 2 or arguments.len > 3) return error.InvalidSql;
        const start = std.fmt.parseInt(i64, arguments[0], 10) catch return error.InvalidSql;
        const stop = std.fmt.parseInt(i64, arguments[1], 10) catch return error.InvalidSql;
        const step = if (arguments.len == 3) std.fmt.parseInt(i64, arguments[2], 10) catch return error.InvalidSql else if (start <= stop) @as(i64, 1) else @as(i64, -1);
        if (step == 0) return error.InvalidSql;
        const definitions = [_]ast.ColumnDef{.{ .name = "value", .type_name = "INTEGER" }};
        try self.createTable(name, &definitions, &.{});
        const table = self.find(name).?;
        table.virtual_module = try self.allocator.dupe(u8, module);
        const copied_arguments = try self.allocator.alloc([]u8, arguments.len);
        for (arguments, 0..) |argument, index| copied_arguments[index] = try self.allocator.dupe(u8, argument);
        table.virtual_arguments = copied_arguments;
        var current = start;
        var count: usize = 0;
        while (if (step > 0) current <= stop else current >= stop) : (current += step) {
            if (count >= 1_000_000) return error.VirtualTableTooLarge;
            const row = [_]Value{.{ .integer = current }};
            try self.appendRow(table, &row);
            count += 1;
        }
    }

    pub fn dropTable(self: *Schema, name: []const u8) !void {
        for (self.tables.items, 0..) |*table, index| {
            if (std.ascii.eqlIgnoreCase(table.name, name)) {
                var index_position: usize = 0;
                while (index_position < self.indexes.items.len) {
                    if (std.ascii.eqlIgnoreCase(self.indexes.items[index_position].table, name)) {
                        const removed = self.indexes.orderedRemove(index_position);
                        self.allocator.free(removed.name);
                        self.allocator.free(removed.table);
                        for (removed.columns) |column| self.allocator.free(column);
                        self.allocator.free(removed.columns);
                    } else index_position += 1;
                }
                var trigger_position: usize = 0;
                while (trigger_position < self.triggers.items.len) {
                    if (std.ascii.eqlIgnoreCase(self.triggers.items[trigger_position].table, name)) {
                        const removed = self.triggers.orderedRemove(trigger_position);
                        self.allocator.free(removed.name);
                        self.allocator.free(removed.table);
                        self.allocator.free(removed.body);
                    } else trigger_position += 1;
                }
                self.removeTable(index);
                return;
            }
        }
        return error.UnknownTable;
    }

    pub fn renameTable(self: *Schema, old_name: []const u8, new_name: []const u8) !void {
        if (self.find(new_name) != null) return error.TableExists;
        const table = self.find(old_name) orelse return error.UnknownTable;
        const owned = try self.allocator.dupe(u8, new_name);
        self.allocator.free(table.name);
        table.name = owned;
    }

    pub fn truncateTable(self: *Schema, name: []const u8) !void {
        const table = self.find(name) orelse return error.UnknownTable;
        for (table.rows.items) |row| {
            for (row.values) |value| freeValue(self.allocator, value);
            self.allocator.free(row.values);
        }
        table.rows.clearRetainingCapacity();
    }

    pub fn addColumn(self: *Schema, table_name: []const u8, definition: ast.ColumnDef) !void {
        const table = self.find(table_name) orelse return error.UnknownTable;
        for (table.columns) |column| if (std.ascii.eqlIgnoreCase(column.name, definition.name)) return error.ColumnExists;
        if (definition.not_null and table.rows.items.len != 0) return error.ConstraintViolation;
        const new_columns = try self.allocator.alloc(Column, table.columns.len + 1);
        errdefer self.allocator.free(new_columns);
        for (table.columns, 0..) |column, index| new_columns[index] = column;
        new_columns[table.columns.len] = .{ .name = try self.allocator.dupe(u8, definition.name), .type_name = try self.allocator.dupe(u8, definition.type_name), .primary_key = definition.primary_key, .not_null = definition.not_null, .default_value = if (definition.default_value) |value| try self.copyValue(value) else null, .on_delete = if (definition.foreign_key) |foreign_key| foreign_key.on_delete else .restrict, .on_update = if (definition.foreign_key) |foreign_key| foreign_key.on_update else .restrict };
        errdefer {
            self.allocator.free(new_columns[table.columns.len].name);
            self.allocator.free(new_columns[table.columns.len].type_name);
        }
        for (table.rows.items) |*row| {
            const values = try self.allocator.realloc(row.values, row.values.len + 1);
            row.values = values;
            row.values[row.values.len - 1] = .null;
        }
        self.allocator.free(table.columns);
        table.columns = new_columns;
    }

    pub fn renameColumn(self: *Schema, table_name: []const u8, old_name: []const u8, new_name: []const u8) !void {
        const table = self.find(table_name) orelse return error.UnknownTable;
        if (self.columnIndex(table, new_name)) |_| return error.ColumnExists;
        const index = self.columnIndex(table, old_name) orelse return error.UnknownColumn;
        const owned = try self.allocator.dupe(u8, new_name);
        self.allocator.free(table.columns[index].name);
        table.columns[index].name = owned;
    }

    pub fn dropColumn(self: *Schema, table_name: []const u8, column_name: []const u8) !void {
        const table = self.find(table_name) orelse return error.UnknownTable;
        const index = self.columnIndex(table, column_name) orelse return error.UnknownColumn;
        if (table.columns.len == 1) return error.ConstraintViolation;
        const old_column = table.columns[index];
        var new_columns = try self.allocator.alloc(Column, table.columns.len - 1);
        var target_index: usize = 0;
        for (table.columns, 0..) |column, source_index| {
            if (source_index == index) continue;
            new_columns[target_index] = column;
            target_index += 1;
        }
        for (table.rows.items) |*row| {
            const new_values = try self.allocator.alloc(Value, row.values.len - 1);
            var value_index: usize = 0;
            for (row.values, 0..) |value, source_index| {
                if (source_index == index) {
                    freeValue(self.allocator, value);
                } else {
                    new_values[value_index] = value;
                    value_index += 1;
                }
            }
            self.allocator.free(row.values);
            row.values = new_values;
        }
        self.allocator.free(old_column.name);
        self.allocator.free(old_column.type_name);
        if (old_column.default_value) |value| freeValue(self.allocator, value);
        self.allocator.free(table.columns);
        table.columns = new_columns;
    }

    fn columnIndex(self: *const Schema, table: *const Table, name: []const u8) ?usize {
        _ = self;
        for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
        return null;
    }

    fn columnIndexByName(self: *const Schema, definitions: []const ast.ColumnDef, name: []const u8) ?usize {
        _ = self;
        for (definitions, 0..) |definition, index| if (std.ascii.eqlIgnoreCase(definition.name, name)) return index;
        return null;
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
            if (column.foreign_table) |value| self.allocator.free(value);
            if (column.foreign_column) |value| self.allocator.free(value);
        }
        self.allocator.free(table.columns);
        for (table.constraints) |constraint| {
            for (constraint.columns) |column| self.allocator.free(column);
            self.allocator.free(constraint.columns);
            if (constraint.foreign_table) |foreign_table| self.allocator.free(foreign_table);
            for (constraint.referenced_columns) |column| self.allocator.free(column);
            self.allocator.free(constraint.referenced_columns);
        }
        self.allocator.free(table.constraints);
        if (table.virtual_module) |module| self.allocator.free(module);
        for (table.virtual_arguments) |argument| self.allocator.free(argument);
        self.allocator.free(table.virtual_arguments);
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
        try self.validateConstraints(table, owned, null);
        try table.rows.append(self.allocator, .{ .values = owned });
    }

    pub fn validateUpdate(self: *const Schema, table: *const Table, row_index: usize, values: []const Value) !void {
        try self.validateConstraints(table, values, row_index);
    }

    fn validateConstraints(self: *const Schema, table: *const Table, values: []const Value, ignored_row: ?usize) !void {
        for (table.columns, 0..) |column, index| {
            if (column.primary_key and values[index] == .null) return error.ConstraintViolation;
            if (column.unique or column.primary_key) {
                if (values[index] != .null) for (table.rows.items, 0..) |existing, existing_index| {
                    if (ignored_row != null and ignored_row.? == existing_index) continue;
                    if (valuesEqual(existing.values[index], values[index])) return error.ConstraintViolation;
                };
            }
            if (self.foreign_keys_enabled) {
                if (column.foreign_table) |foreign_table_name| {
                    const foreign_table = self.findConst(foreign_table_name) orelse return error.ConstraintViolation;
                    const foreign_column_name = column.foreign_column orelse return error.ConstraintViolation;
                    const foreign_index = self.columnIndex(foreign_table, foreign_column_name) orelse return error.ConstraintViolation;
                    if (values[index] != .null) {
                        var found = false;
                        for (foreign_table.rows.items) |foreign_row| if (valuesEqual(foreign_row.values[foreign_index], values[index])) {
                            found = true;
                            break;
                        };
                        if (!found) return error.ConstraintViolation;
                    }
                }
            }
        }
        for (table.constraints) |constraint| {
            var has_null = false;
            for (constraint.columns) |name| {
                const index = self.columnIndex(table, name) orelse return error.UnknownColumn;
                if (values[index] == .null) has_null = true;
            }
            if (constraint.kind == .primary_key and has_null) return error.ConstraintViolation;
            if (constraint.kind == .unique and has_null) continue;
            if (constraint.kind == .foreign_key and self.foreign_keys_enabled) {
                if (has_null) continue;
                const foreign_table = self.findConst(constraint.foreign_table orelse return error.ConstraintViolation) orelse return error.ConstraintViolation;
                for (foreign_table.rows.items) |foreign_row| {
                    var matched = true;
                    for (constraint.columns, constraint.referenced_columns) |child_name, parent_name| {
                        const child_index = self.columnIndex(table, child_name) orelse return error.UnknownColumn;
                        const parent_index = self.columnIndex(foreign_table, parent_name) orelse return error.UnknownColumn;
                        if (!valuesEqual(values[child_index], foreign_row.values[parent_index])) matched = false;
                    }
                    if (matched) break;
                } else return error.ConstraintViolation;
                continue;
            }
            for (table.rows.items, 0..) |existing, existing_index| {
                if (ignored_row != null and ignored_row.? == existing_index) continue;
                if (indexValuesEqual(table, values, existing.values, constraint.columns)) return error.ConstraintViolation;
            }
        }
        for (self.indexes.items) |index| if (index.unique and std.ascii.eqlIgnoreCase(index.table, table.name)) {
            var has_null = false;
            for (index.columns) |name| {
                const column_index = self.columnIndex(table, name) orelse continue;
                if (values[column_index] == .null) has_null = true;
            }
            if (!has_null) for (table.rows.items, 0..) |existing, existing_index| {
                if (ignored_row != null and ignored_row.? == existing_index) continue;
                if (indexValuesEqual(table, values, existing.values, index.columns)) return error.ConstraintViolation;
            };
        };
    }

    pub fn clone(self: *const Schema) !Schema {
        var result = Schema.init(self.allocator);
        result.foreign_keys_enabled = self.foreign_keys_enabled;
        errdefer result.deinit();
        for (self.tables.items) |table| {
            if (table.virtual_module) |module| {
                try result.createVirtualTable(table.name, module, table.virtual_arguments);
                continue;
            }
            const definitions = try self.allocator.alloc(ast.ColumnDef, table.columns.len);
            defer self.allocator.free(definitions);
            for (table.columns, 0..) |column, index| definitions[index] = .{ .name = column.name, .type_name = column.type_name, .primary_key = column.primary_key, .not_null = column.not_null, .unique = column.unique, .default_value = column.default_value, .foreign_key = if (column.foreign_table != null) .{ .table = column.foreign_table.?, .column = column.foreign_column.?, .on_delete = column.on_delete, .on_update = column.on_update } else null };
            const constraint_definitions = try self.allocator.alloc(ast.TableConstraint, table.constraints.len);
            defer self.allocator.free(constraint_definitions);
            for (table.constraints, 0..) |constraint, index| constraint_definitions[index] = switch (constraint.kind) {
                .primary_key => .{ .primary_key = constraint.columns },
                .unique => .{ .unique = constraint.columns },
                .foreign_key => .{ .foreign_key = .{ .columns = constraint.columns, .table = constraint.foreign_table.?, .referenced_columns = constraint.referenced_columns, .on_delete = constraint.on_delete, .on_update = constraint.on_update } },
            };
            try result.createTable(table.name, definitions, constraint_definitions);
            const target = result.find(table.name).?;
            for (table.rows.items) |row| try result.appendRow(target, row.values);
        }
        for (self.indexes.items) |index| {
            if (std.mem.startsWith(u8, index.name, "sqlite_autoindex_")) continue;
            const columns = try self.allocator.alloc([]const u8, index.columns.len);
            defer self.allocator.free(columns);
            for (index.columns, 0..) |column, position| columns[position] = column;
            try result.createIndex(.{ .name = index.name, .table = index.table, .columns = columns, .unique = index.unique });
        }
        for (self.views.items) |view| try result.createView(view.name, view.sql);
        for (self.triggers.items) |trigger| try result.createTrigger(.{ .name = trigger.name, .table = trigger.table, .event = trigger.event, .body = trigger.body });
        return result;
    }
};

fn valuesEqual(left: Value, right: Value) bool {
    return switch (left) {
        .null => right == .null,
        .integer => |value| switch (right) {
            .integer => |other| value == other,
            else => false,
        },
        .real => |value| switch (right) {
            .real => |other| value == other,
            .integer => |other| value == @as(f64, @floatFromInt(other)),
            else => false,
        },
        .text => |value| switch (right) {
            .text => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .blob => |value| switch (right) {
            .blob => |other| std.mem.eql(u8, value, other),
            else => false,
        },
    };
}

fn indexValuesEqual(table: *const Table, left: []const Value, right: []const Value, columns: []const []const u8) bool {
    for (columns) |name| {
        var column_index: ?usize = null;
        for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) {
            column_index = index;
            break;
        };
        const index = column_index orelse return false;
        if (left[index] == .null or right[index] == .null) continue;
        if (!valuesEqual(left[index], right[index])) return false;
    }
    return true;
}

test "schema owns tables and rows" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{ .{ .name = "id", .type_name = "INTEGER" }, .{ .name = "name", .type_name = "TEXT" } };
    try schema.createTable("users", &defs, &.{});
    var values = [_]Value{ .{ .integer = 1 }, .{ .text = "A" } };
    try schema.appendRow(schema.find("users").?, &values);
    try std.testing.expectEqual(@as(usize, 1), schema.find("users").?.rows.items.len);
}
