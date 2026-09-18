const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");

pub const Column = struct { name: []u8, typeName: []u8, primaryKey: bool, notNull: bool, unique: bool = false, defaultValue: ?Value = null, foreignTable: ?[]u8 = null, foreignColumn: ?[]u8 = null, onDelete: ast.ReferentialAction = .restrict, onUpdate: ast.ReferentialAction = .restrict };
pub const Row = struct { values: []Value };
pub const Constraint = struct { kind: enum { primaryKey, unique, foreignKey }, columns: [][]u8, foreignTable: ?[]u8 = null, referencedColumns: [][]u8 = &.{}, onDelete: ast.ReferentialAction = .restrict, onUpdate: ast.ReferentialAction = .restrict };
pub const Table = struct { name: []u8, columns: []Column, constraints: []Constraint, rows: std.ArrayList(Row), virtualModule: ?[]u8 = null, virtualArguments: [][]u8 = &.{} };
pub const Index = struct { name: []u8, table: []u8, columns: [][]u8, unique: bool = false };
pub const View = struct { name: []u8, sql: []u8 };
pub const Trigger = struct { name: []u8, table: []u8, event: ast.TriggerEvent, body: []u8 };

pub const Schema = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(Table),
    indexes: std.ArrayList(Index),
    views: std.ArrayList(View),
    triggers: std.ArrayList(Trigger),
    foreignKeysEnabled: bool = true,

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
                self.allocator.free(column.typeName);
                if (column.defaultValue) |value| freeValue(self.allocator, value);
                if (column.foreignTable) |value| self.allocator.free(value);
                if (column.foreignColumn) |value| self.allocator.free(value);
            }
            self.allocator.free(table.columns);
            for (table.constraints) |constraint| {
                for (constraint.columns) |column| self.allocator.free(column);
                self.allocator.free(constraint.columns);
                if (constraint.foreignTable) |foreignTable| self.allocator.free(foreignTable);
                for (constraint.referencedColumns) |column| self.allocator.free(column);
                self.allocator.free(constraint.referencedColumns);
            }
            self.allocator.free(table.constraints);
            if (table.virtualModule) |module| self.allocator.free(module);
            for (table.virtualArguments) |argument| self.allocator.free(argument);
            self.allocator.free(table.virtualArguments);
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
        const tableName = try self.allocator.dupe(u8, definition.table);
        errdefer self.allocator.free(tableName);
        const columns = try self.allocator.alloc([]u8, definition.columns.len);
        errdefer self.allocator.free(columns);
        var copied: usize = 0;
        errdefer for (columns[0..copied]) |column| self.allocator.free(column);
        for (definition.columns, 0..) |column, index| {
            columns[index] = try self.allocator.dupe(u8, column);
            copied += 1;
        }
        try self.indexes.append(self.allocator, .{ .name = name, .table = tableName, .columns = columns, .unique = definition.unique });
        if (definition.unique) {
            errdefer _ = self.indexes.pop();
            for (table.rows.items, 0..) |row, rowIndex| {
                for (table.rows.items[rowIndex + 1 ..]) |other| if (indexValuesEqual(table, row.values, other.values, definition.columns)) return error.ConstraintViolation;
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

    pub fn createTable(self: *Schema, name: []const u8, definitions: []const ast.ColumnDef, definitionsConstraints: []const ast.TableConstraint) !void {
        if (self.find(name) != null) return error.TableExists;
        const ownedName = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(ownedName);
        const columns = try self.allocator.alloc(Column, definitions.len);
        errdefer self.allocator.free(columns);
        var count: usize = 0;
        errdefer for (columns[0..count]) |column| {
            self.allocator.free(column.name);
            self.allocator.free(column.typeName);
        };
        for (definitions, 0..) |definition, index| {
            columns[index] = .{ .name = try self.allocator.dupe(u8, definition.name), .typeName = try self.allocator.dupe(u8, definition.typeName), .primaryKey = definition.primaryKey, .notNull = definition.notNull, .unique = definition.unique, .defaultValue = if (definition.defaultValue) |value| try self.copyValue(value) else null, .foreignTable = if (definition.foreignKey) |foreignKey| try self.allocator.dupe(u8, foreignKey.table) else null, .foreignColumn = if (definition.foreignKey) |foreignKey| try self.allocator.dupe(u8, foreignKey.column) else null, .onDelete = if (definition.foreignKey) |foreignKey| foreignKey.onDelete else .restrict, .onUpdate = if (definition.foreignKey) |foreignKey| foreignKey.onUpdate else .restrict };
            count += 1;
        }
        const constraints = try self.allocator.alloc(Constraint, definitionsConstraints.len);
        errdefer self.allocator.free(constraints);
        var constraintCount: usize = 0;
        errdefer for (constraints[0..constraintCount]) |constraint| {
            for (constraint.columns) |column| self.allocator.free(column);
            self.allocator.free(constraint.columns);
            if (constraint.foreignTable) |foreignTable| self.allocator.free(foreignTable);
            for (constraint.referencedColumns) |column| self.allocator.free(column);
            self.allocator.free(constraint.referencedColumns);
        };
        for (definitionsConstraints, 0..) |definition, index| {
            const sourceColumns = switch (definition) {
                .primaryKey => |value| value,
                .unique => |value| value,
                .foreignKey => |value| value.columns,
            };
            const copiedColumns = try self.allocator.alloc([]u8, sourceColumns.len);
            var copiedCount: usize = 0;
            errdefer for (copiedColumns[0..copiedCount]) |column| self.allocator.free(column);
            for (sourceColumns, 0..) |column, columnIdx| {
                if (self.columnIndexByName(definitions, column) == null) return error.UnknownColumn;
                copiedColumns[columnIdx] = try self.allocator.dupe(u8, column);
                copiedCount += 1;
            }
            constraints[index] = .{ .kind = switch (definition) {
                .primaryKey => .primaryKey,
                .unique => .unique,
                .foreignKey => .foreignKey,
            }, .columns = copiedColumns };
            switch (definition) {
                .foreignKey => |foreignKey| {
                    if (foreignKey.referencedColumns.len != sourceColumns.len) return error.ConstraintViolation;
                    const referencedColumns = try self.allocator.alloc([]u8, foreignKey.referencedColumns.len);
                    for (foreignKey.referencedColumns, 0..) |column, columnIdx| {
                        referencedColumns[columnIdx] = try self.allocator.dupe(u8, column);
                        if (self.findConst(foreignKey.table)) |parent| {
                            if (self.columnIndex(parent, column) == null) return error.UnknownColumn;
                        }
                    }
                    constraints[index].foreignTable = try self.allocator.dupe(u8, foreignKey.table);
                    constraints[index].referencedColumns = referencedColumns;
                    constraints[index].onDelete = foreignKey.onDelete;
                    constraints[index].onUpdate = foreignKey.onUpdate;
                },
                else => {},
            }
            constraintCount += 1;
        }
        try self.tables.append(self.allocator, .{ .name = ownedName, .columns = columns, .constraints = constraints, .rows = .empty });
        var autoindexNumber: usize = 0;
        for (constraints) |constraint| {
            if (constraint.kind == .foreignKey) continue;
            autoindexNumber += 1;
            const indexName = try std.fmt.allocPrint(self.allocator, "sqlite_autoindex_{s}_{d}", .{ name, autoindexNumber });
            const indexTable = try self.allocator.dupe(u8, name);
            const indexColumns = try self.allocator.alloc([]u8, constraint.columns.len);
            for (constraint.columns, 0..) |column, columnIdx| {
                indexColumns[columnIdx] = try self.allocator.dupe(u8, column);
            }
            try self.indexes.append(self.allocator, .{ .name = indexName, .table = indexTable, .columns = indexColumns, .unique = true });
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
        const definitions = [_]ast.ColumnDef{.{ .name = "value", .typeName = "INTEGER" }};
        try self.createTable(name, &definitions, &.{});
        const table = self.find(name).?;
        table.virtualModule = try self.allocator.dupe(u8, module);
        const copiedArguments = try self.allocator.alloc([]u8, arguments.len);
        for (arguments, 0..) |argument, index| copiedArguments[index] = try self.allocator.dupe(u8, argument);
        table.virtualArguments = copiedArguments;
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
                var indexPosition: usize = 0;
                while (indexPosition < self.indexes.items.len) {
                    if (std.ascii.eqlIgnoreCase(self.indexes.items[indexPosition].table, name)) {
                        const removed = self.indexes.orderedRemove(indexPosition);
                        self.allocator.free(removed.name);
                        self.allocator.free(removed.table);
                        for (removed.columns) |column| self.allocator.free(column);
                        self.allocator.free(removed.columns);
                    } else indexPosition += 1;
                }
                var triggerPosition: usize = 0;
                while (triggerPosition < self.triggers.items.len) {
                    if (std.ascii.eqlIgnoreCase(self.triggers.items[triggerPosition].table, name)) {
                        const removed = self.triggers.orderedRemove(triggerPosition);
                        self.allocator.free(removed.name);
                        self.allocator.free(removed.table);
                        self.allocator.free(removed.body);
                    } else triggerPosition += 1;
                }
                self.removeTable(index);
                return;
            }
        }
        return error.UnknownTable;
    }

    pub fn renameTable(self: *Schema, oldName: []const u8, newName: []const u8) !void {
        if (self.find(newName) != null) return error.TableExists;
        const table = self.find(oldName) orelse return error.UnknownTable;
        const owned = try self.allocator.dupe(u8, newName);
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

    pub fn addColumn(self: *Schema, tableName: []const u8, definition: ast.ColumnDef) !void {
        const table = self.find(tableName) orelse return error.UnknownTable;
        for (table.columns) |column| if (std.ascii.eqlIgnoreCase(column.name, definition.name)) return error.ColumnExists;
        if (definition.notNull and table.rows.items.len != 0) return error.ConstraintViolation;
        const newColumns = try self.allocator.alloc(Column, table.columns.len + 1);
        errdefer self.allocator.free(newColumns);
        for (table.columns, 0..) |column, index| newColumns[index] = column;
        newColumns[table.columns.len] = .{ .name = try self.allocator.dupe(u8, definition.name), .typeName = try self.allocator.dupe(u8, definition.typeName), .primaryKey = definition.primaryKey, .notNull = definition.notNull, .defaultValue = if (definition.defaultValue) |value| try self.copyValue(value) else null, .onDelete = if (definition.foreignKey) |foreignKey| foreignKey.onDelete else .restrict, .onUpdate = if (definition.foreignKey) |foreignKey| foreignKey.onUpdate else .restrict };
        errdefer {
            self.allocator.free(newColumns[table.columns.len].name);
            self.allocator.free(newColumns[table.columns.len].typeName);
        }
        for (table.rows.items) |*row| {
            const values = try self.allocator.realloc(row.values, row.values.len + 1);
            row.values = values;
            row.values[row.values.len - 1] = .null;
        }
        self.allocator.free(table.columns);
        table.columns = newColumns;
    }

    pub fn renameColumn(self: *Schema, tableName: []const u8, oldName: []const u8, newName: []const u8) !void {
        const table = self.find(tableName) orelse return error.UnknownTable;
        if (self.columnIndex(table, newName)) |_| return error.ColumnExists;
        const index = self.columnIndex(table, oldName) orelse return error.UnknownColumn;
        const owned = try self.allocator.dupe(u8, newName);
        self.allocator.free(table.columns[index].name);
        table.columns[index].name = owned;
    }

    pub fn dropColumn(self: *Schema, tableName: []const u8, columnName: []const u8) !void {
        const table = self.find(tableName) orelse return error.UnknownTable;
        const index = self.columnIndex(table, columnName) orelse return error.UnknownColumn;
        if (table.columns.len == 1) return error.ConstraintViolation;
        const oldColumn = table.columns[index];
        var newColumns = try self.allocator.alloc(Column, table.columns.len - 1);
        var targetIndex: usize = 0;
        for (table.columns, 0..) |column, sourceIndex| {
            if (sourceIndex == index) continue;
            newColumns[targetIndex] = column;
            targetIndex += 1;
        }
        for (table.rows.items) |*row| {
            const newValues = try self.allocator.alloc(Value, row.values.len - 1);
            var valueIndex: usize = 0;
            for (row.values, 0..) |value, sourceIndex| {
                if (sourceIndex == index) {
                    freeValue(self.allocator, value);
                } else {
                    newValues[valueIndex] = value;
                    valueIndex += 1;
                }
            }
            self.allocator.free(row.values);
            row.values = newValues;
        }
        self.allocator.free(oldColumn.name);
        self.allocator.free(oldColumn.typeName);
        if (oldColumn.defaultValue) |value| freeValue(self.allocator, value);
        self.allocator.free(table.columns);
        table.columns = newColumns;
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
            self.allocator.free(column.typeName);
            if (column.foreignTable) |value| self.allocator.free(value);
            if (column.foreignColumn) |value| self.allocator.free(value);
        }
        self.allocator.free(table.columns);
        for (table.constraints) |constraint| {
            for (constraint.columns) |column| self.allocator.free(column);
            self.allocator.free(constraint.columns);
            if (constraint.foreignTable) |foreignTable| self.allocator.free(foreignTable);
            for (constraint.referencedColumns) |column| self.allocator.free(column);
            self.allocator.free(constraint.referencedColumns);
        }
        self.allocator.free(table.constraints);
        if (table.virtualModule) |module| self.allocator.free(module);
        for (table.virtualArguments) |argument| self.allocator.free(argument);
        self.allocator.free(table.virtualArguments);
        self.allocator.free(table.name);
    }

    pub fn appendRow(self: *Schema, table: *Table, values: []const Value) !void {
        if (values.len != table.columns.len) return error.ColumnCountMismatch;
        const owned = try self.allocator.alloc(Value, values.len);
        errdefer self.allocator.free(owned);
        var count: usize = 0;
        errdefer for (owned[0..count]) |value| freeValue(self.allocator, value);
        for (values, 0..) |value, index| {
            if (table.columns[index].notNull and value == .null) return error.ConstraintViolation;
            owned[index] = try self.copyValue(value);
            count += 1;
        }
        try self.validateConstraints(table, owned, null);
        try table.rows.append(self.allocator, .{ .values = owned });
    }

    pub fn validateUpdate(self: *const Schema, table: *const Table, rowIndex: usize, values: []const Value) !void {
        try self.validateConstraints(table, values, rowIndex);
    }

    fn validateConstraints(self: *const Schema, table: *const Table, values: []const Value, ignoredRow: ?usize) !void {
        for (table.columns, 0..) |column, index| {
            if (column.primaryKey and values[index] == .null) return error.ConstraintViolation;
            if (column.unique or column.primaryKey) {
                if (values[index] != .null) for (table.rows.items, 0..) |existing, existingIndex| {
                    if (ignoredRow != null and ignoredRow.? == existingIndex) continue;
                    if (valuesEqual(existing.values[index], values[index])) return error.ConstraintViolation;
                };
            }
            if (self.foreignKeysEnabled) {
                if (column.foreignTable) |foreignTableName| {
                    const foreignTable = self.findConst(foreignTableName) orelse return error.ConstraintViolation;
                    const foreignColumnName = column.foreignColumn orelse return error.ConstraintViolation;
                    const foreignIndex = self.columnIndex(foreignTable, foreignColumnName) orelse return error.ConstraintViolation;
                    if (values[index] != .null) {
                        var found = false;
                        for (foreignTable.rows.items) |foreignRow| if (valuesEqual(foreignRow.values[foreignIndex], values[index])) {
                            found = true;
                            break;
                        };
                        if (!found) return error.ConstraintViolation;
                    }
                }
            }
        }
        for (table.constraints) |constraint| {
            var hasNull = false;
            for (constraint.columns) |name| {
                const index = self.columnIndex(table, name) orelse return error.UnknownColumn;
                if (values[index] == .null) hasNull = true;
            }
            if (constraint.kind == .primaryKey and hasNull) return error.ConstraintViolation;
            if (constraint.kind == .unique and hasNull) continue;
            if (constraint.kind == .foreignKey and self.foreignKeysEnabled) {
                if (hasNull) continue;
                const foreignTable = self.findConst(constraint.foreignTable orelse return error.ConstraintViolation) orelse return error.ConstraintViolation;
                for (foreignTable.rows.items) |foreignRow| {
                    var matched = true;
                    for (constraint.columns, constraint.referencedColumns) |childName, parentName| {
                        const childIndex = self.columnIndex(table, childName) orelse return error.UnknownColumn;
                        const parentIndex = self.columnIndex(foreignTable, parentName) orelse return error.UnknownColumn;
                        if (!valuesEqual(values[childIndex], foreignRow.values[parentIndex])) matched = false;
                    }
                    if (matched) break;
                } else return error.ConstraintViolation;
                continue;
            }
            for (table.rows.items, 0..) |existing, existingIndex| {
                if (ignoredRow != null and ignoredRow.? == existingIndex) continue;
                if (indexValuesEqual(table, values, existing.values, constraint.columns)) return error.ConstraintViolation;
            }
        }
        for (self.indexes.items) |index| if (index.unique and std.ascii.eqlIgnoreCase(index.table, table.name)) {
            var hasNull = false;
            for (index.columns) |name| {
                const columnIdx = self.columnIndex(table, name) orelse continue;
                if (values[columnIdx] == .null) hasNull = true;
            }
            if (!hasNull) for (table.rows.items, 0..) |existing, existingIndex| {
                if (ignoredRow != null and ignoredRow.? == existingIndex) continue;
                if (indexValuesEqual(table, values, existing.values, index.columns)) return error.ConstraintViolation;
            };
        };
    }

    pub fn clone(self: *const Schema) !Schema {
        var result = Schema.init(self.allocator);
        result.foreignKeysEnabled = self.foreignKeysEnabled;
        errdefer result.deinit();
        for (self.tables.items) |table| {
            if (table.virtualModule) |module| {
                try result.createVirtualTable(table.name, module, table.virtualArguments);
                continue;
            }
            const definitions = try self.allocator.alloc(ast.ColumnDef, table.columns.len);
            defer self.allocator.free(definitions);
            for (table.columns, 0..) |column, index| definitions[index] = .{ .name = column.name, .typeName = column.typeName, .primaryKey = column.primaryKey, .notNull = column.notNull, .unique = column.unique, .defaultValue = column.defaultValue, .foreignKey = if (column.foreignTable != null) .{ .table = column.foreignTable.?, .column = column.foreignColumn.?, .onDelete = column.onDelete, .onUpdate = column.onUpdate } else null };
            const constraintDefinitions = try self.allocator.alloc(ast.TableConstraint, table.constraints.len);
            defer self.allocator.free(constraintDefinitions);
            for (table.constraints, 0..) |constraint, index| constraintDefinitions[index] = switch (constraint.kind) {
                .primaryKey => .{ .primaryKey = constraint.columns },
                .unique => .{ .unique = constraint.columns },
                .foreignKey => .{ .foreignKey = .{ .columns = constraint.columns, .table = constraint.foreignTable.?, .referencedColumns = constraint.referencedColumns, .onDelete = constraint.onDelete, .onUpdate = constraint.onUpdate } },
            };
            try result.createTable(table.name, definitions, constraintDefinitions);
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
        var columnIndex: ?usize = null;
        for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) {
            columnIndex = index;
            break;
        };
        const index = columnIndex orelse return false;
        if (left[index] == .null or right[index] == .null) continue;
        if (!valuesEqual(left[index], right[index])) return false;
    }
    return true;
}

test "schema owns tables and rows" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{ .{ .name = "id", .typeName = "INTEGER" }, .{ .name = "name", .typeName = "TEXT" } };
    try schema.createTable("users", &defs, &.{});
    var values = [_]Value{ .{ .integer = 1 }, .{ .text = "A" } };
    try schema.appendRow(schema.find("users").?, &values);
    try std.testing.expectEqual(@as(usize, 1), schema.find("users").?.rows.items.len);
}
