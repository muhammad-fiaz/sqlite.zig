const std = @import("std");
const DatabaseFile = @import("../storage/file.zig").DatabaseFile;
const image = @import("../storage/image.zig");
const sqlite_image = @import("../storage/sqlite_image.zig");
const Schema = @import("../catalog/schema.zig").Schema;
const Table = @import("../catalog/schema.zig").Table;
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");
const Parser = @import("../sql/parser.zig").Parser;
const Prepared = @import("statement.zig").Statement;
const ColumnKey = @import("../dsl/table.zig").ColumnKey;
pub const Result = @import("result.zig").Result;

pub const ForeignKeyOption = struct { column: []const u8 = "", table: []const u8, referenced_column: []const u8, column_key: ?ColumnKey = null, on_delete: ast.ReferentialAction = .restrict, on_update: ast.ReferentialAction = .restrict };
pub const CompositeForeignKeyOption = struct { columns: []const ColumnKey, referenced_columns: []const ColumnKey, on_delete: ast.ReferentialAction = .restrict, on_update: ast.ReferentialAction = .restrict };
pub const TableOptions = struct {
    if_not_exists: bool = false,
    primary_key: ?ColumnKey = null,
    primary_key_name: ?[]const u8 = null,
    unique_columns: []const []const u8 = &.{},
    unique_keys: []const ColumnKey = &.{},
    primary_keys: []const ColumnKey = &.{},
    unique_constraints: []const []const ColumnKey = &.{},
    foreign_key_constraints: []const CompositeForeignKeyOption = &.{},
    foreign_keys: []const ForeignKeyOption = &.{},
};

const Savepoint = struct { name: []u8, schema: Schema };
const OuterRow = struct { table: *const Table, values: []const Value };

pub const Connection = struct {
    allocator: std.mem.Allocator,
    file: DatabaseFile,
    schema: Schema,
    backup: ?Schema = null,
    transaction_active: bool = false,
    savepoints: std.ArrayList(Savepoint),

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Connection {
        const connection = try allocator.create(Connection);
        errdefer allocator.destroy(connection);
        connection.* = .{ .allocator = allocator, .file = try DatabaseFile.open(allocator, path), .schema = Schema.init(allocator), .savepoints = .empty };
        errdefer connection.close();
        if (try connection.file.readPayload()) |payload| {
            defer allocator.free(payload);
            connection.schema.deinit();
            connection.schema = try image.decode(allocator, payload);
            try connection.persist();
        } else {
            const bytes = try connection.file.readImage();
            defer allocator.free(bytes);
            if (bytes[100] == 0x0d) {
                connection.schema.deinit();
                connection.schema = try sqlite_image.decode(allocator, bytes);
            }
        }
        return connection;
    }

    pub fn close(self: *Connection) void {
        if (self.transaction_active) {
            self.rollback() catch {};
        }
        self.persist() catch {};
        if (self.backup) |*backup| backup.deinit();
        self.clearSavepoints();
        self.savepoints.deinit(self.allocator);
        self.schema.deinit();
        self.file.close();
        self.allocator.destroy(self);
    }

    fn persist(self: *Connection) !void {
        const bytes = try sqlite_image.encodeWithPageSize(self.allocator, &self.schema, self.file.page_size);
        defer self.allocator.free(bytes);
        try self.file.writeImage(bytes);
    }

    pub fn exec(self: *Connection, sql: []const u8) !Result {
        var last: ?Result = null;
        errdefer if (last) |*result| result.deinit();
        var start: usize = 0;
        var index: usize = 0;
        var quote: u8 = 0;
        var trigger_definition = false;
        var trigger_depth: usize = 0;
        while (index < sql.len) : (index += 1) {
            const byte = sql[index];
            if (quote != 0) {
                if (byte == quote) {
                    if (index + 1 < sql.len and sql[index + 1] == quote) {
                        index += 1;
                    } else quote = 0;
                }
                continue;
            }
            if (byte == '\'' or byte == '"') {
                quote = byte;
                continue;
            }
            if (std.ascii.isAlphabetic(byte)) {
                const word_start = index;
                while (index + 1 < sql.len and (std.ascii.isAlphanumeric(sql[index + 1]) or sql[index + 1] == '_')) : (index += 1) {}
                const word = sql[word_start .. index + 1];
                if (std.ascii.eqlIgnoreCase(word, "trigger")) trigger_definition = true;
                if (trigger_definition and std.ascii.eqlIgnoreCase(word, "begin")) trigger_depth += 1;
                if (trigger_definition and std.ascii.eqlIgnoreCase(word, "end") and trigger_depth > 0) trigger_depth -= 1;
                continue;
            }
            if (byte == ';' and trigger_depth == 0) {
                const statement_sql = std.mem.trim(u8, sql[start..index], " \t\r\n");
                if (statement_sql.len != 0) {
                    if (last) |*result| result.deinit();
                    last = try self.execute(statement_sql, &.{});
                }
                start = index + 1;
                trigger_definition = false;
            }
        }
        const remainder = std.mem.trim(u8, sql[start..], " \t\r\n");
        if (remainder.len != 0) {
            if (last) |*result| result.deinit();
            last = try self.execute(remainder, &.{});
        }
        return last orelse error.InvalidSql;
    }

    pub fn prepare(self: *Connection, sql: []const u8) !Prepared {
        return .{ .connection = self, .sql = try self.allocator.dupe(u8, sql), .allocator = self.allocator, .parameters = .empty, .execute_fn = executePrepared };
    }

    pub fn from(self: *Connection, comptime source: anytype) if (@TypeOf(source) == type)
        @import("../dsl/query_builder.zig").Query(source)
    else
        @import("../dsl/raw_dsl.zig").RawQuery(executeForRawDsl) {
        if (@TypeOf(source) == type) {
            return @import("../dsl/query_builder.zig").Query(source).init(self, source.table_name, executeForDsl);
        }
        return @import("../dsl/raw_dsl.zig").RawQuery(executeForRawDsl).init(self.allocator, self, source);
    }

    pub fn col(_: *Connection, name: []const u8) @import("../dsl/raw_dsl.zig").RawColumn {
        return .{ .name = name };
    }

    pub fn tableExists(self: *Connection, comptime TableType: type) bool {
        return self.schema.find(TableType.table_name) != null;
    }

    pub fn createTable(self: *Connection, comptime TableType: type, options: TableOptions) !void {
        if (self.tableExists(TableType)) {
            if (options.if_not_exists) return;
            return error.TableExists;
        }
        const Row = TableType.row_type;
        const fields = @typeInfo(Row).@"struct".fields;
        var definitions: [fields.len]ast.ColumnDef = undefined;
        inline for (fields, 0..) |field, index| {
            var definition = ast.ColumnDef{ .name = field.name, .type_name = dslTypeName(field.type), .primary_key = if (options.primary_key_name) |key| std.mem.eql(u8, key, field.name) else if (options.primary_key) |key| std.mem.eql(u8, key.name, field.name) else false };
            for (options.unique_columns) |unique_column| {
                if (std.mem.eql(u8, unique_column, field.name)) definition.unique = true;
            }
            for (options.unique_keys) |unique_column| {
                if (std.mem.eql(u8, unique_column.name, field.name)) definition.unique = true;
            }
            for (options.foreign_keys) |foreign_key| {
                const local_name = if (foreign_key.column_key) |key| key.name else foreign_key.column;
                if (std.mem.eql(u8, local_name, field.name)) definition.foreign_key = .{ .table = foreign_key.table, .column = foreign_key.referenced_column, .on_delete = foreign_key.on_delete, .on_update = foreign_key.on_update };
            }
            definitions[index] = definition;
        }
        var constraints = std.ArrayList(ast.TableConstraint).empty;
        defer {
            for (constraints.items) |constraint| switch (constraint) {
                .primary_key => |names| self.allocator.free(names),
                .unique => |names| self.allocator.free(names),
                .foreign_key => |foreign_key| {
                    self.allocator.free(foreign_key.columns);
                    self.allocator.free(foreign_key.referenced_columns);
                },
            };
            constraints.deinit(self.allocator);
        }
        if (options.primary_keys.len != 0) {
            const names = try self.allocator.alloc([]const u8, options.primary_keys.len);
            errdefer self.allocator.free(names);
            for (options.primary_keys, 0..) |key, index| {
                if (!std.mem.eql(u8, key.table, TableType.table_name) or !hasFieldNamed(fields, key.name)) return error.UnknownColumn;
                names[index] = key.name;
            }
            try constraints.append(self.allocator, .{ .primary_key = names });
        }
        for (options.unique_constraints) |constraint_keys| {
            const names = try self.allocator.alloc([]const u8, constraint_keys.len);
            errdefer self.allocator.free(names);
            for (constraint_keys, 0..) |key, index| {
                if (!std.mem.eql(u8, key.table, TableType.table_name) or !hasFieldNamed(fields, key.name)) return error.UnknownColumn;
                names[index] = key.name;
            }
            try constraints.append(self.allocator, .{ .unique = names });
        }
        for (options.foreign_key_constraints) |foreign_key| {
            if (foreign_key.columns.len == 0 or foreign_key.columns.len != foreign_key.referenced_columns.len) return error.InvalidSql;
            const child_names = try self.allocator.alloc([]const u8, foreign_key.columns.len);
            errdefer self.allocator.free(child_names);
            const parent_names = try self.allocator.alloc([]const u8, foreign_key.referenced_columns.len);
            errdefer self.allocator.free(parent_names);
            var parent_table: []const u8 = "";
            for (foreign_key.columns, 0..) |key, index| {
                if (!std.mem.eql(u8, key.table, TableType.table_name) or !hasFieldNamed(fields, key.name)) return error.UnknownColumn;
                child_names[index] = key.name;
                const parent_key = foreign_key.referenced_columns[index];
                if (index == 0) parent_table = parent_key.table else if (!std.mem.eql(u8, parent_table, parent_key.table)) return error.InvalidSql;
                parent_names[index] = parent_key.name;
            }
            try constraints.append(self.allocator, .{ .foreign_key = .{ .columns = child_names, .table = parent_table, .referenced_columns = parent_names, .on_delete = foreign_key.on_delete, .on_update = foreign_key.on_update } });
        }
        try self.schema.createTable(TableType.table_name, &definitions, constraints.items);
        if (!self.transaction_active) try self.persist();
    }

    pub fn dropTable(self: *Connection, comptime TableType: type) !void {
        try self.schema.dropTable(TableType.table_name);
        if (!self.transaction_active) try self.persist();
    }

    pub fn createIndex(self: *Connection, comptime TableType: type, comptime name: []const u8, comptime columns: []const ColumnKey, unique: bool) !void {
        var names: [columns.len][]const u8 = undefined;
        inline for (columns, 0..) |column, index| {
            if (!@hasField(TableType.row_type, column.name)) @compileError("unknown index column");
            names[index] = column.name;
        }
        try self.schema.createIndex(.{ .name = name, .table = TableType.table_name, .columns = &names, .unique = unique });
        if (!self.transaction_active) try self.persist();
    }

    pub fn dropIndex(self: *Connection, comptime name: []const u8) !void {
        try self.schema.dropIndex(name);
        if (!self.transaction_active) try self.persist();
    }

    pub fn createView(self: *Connection, comptime name: []const u8, sql: []const u8) !void {
        try self.schema.createView(name, sql);
        if (!self.transaction_active) try self.persist();
    }

    pub fn dropView(self: *Connection, comptime name: []const u8) !void {
        try self.schema.dropView(name);
        if (!self.transaction_active) try self.persist();
    }

    pub fn dropTrigger(self: *Connection, comptime name: []const u8) !void {
        try self.schema.dropTrigger(name);
        if (!self.transaction_active) try self.persist();
    }

    pub fn renameTable(self: *Connection, comptime TableType: type, comptime new_name: []const u8) !void {
        try self.schema.renameTable(TableType.table_name, new_name);
        if (!self.transaction_active) try self.persist();
    }

    pub fn truncate(self: *Connection, comptime TableType: type) !void {
        try self.schema.truncateTable(TableType.table_name);
        if (!self.transaction_active) try self.persist();
    }

    pub fn addColumn(self: *Connection, comptime TableType: type, comptime field: []const u8, comptime FieldType: type) !void {
        try self.schema.addColumn(TableType.table_name, .{ .name = field, .type_name = dslTypeName(FieldType) });
        if (!self.transaction_active) try self.persist();
    }

    pub fn renameColumn(self: *Connection, comptime TableType: type, comptime old_name: []const u8, comptime new_name: []const u8) !void {
        try self.schema.renameColumn(TableType.table_name, old_name, new_name);
        if (!self.transaction_active) try self.persist();
    }

    pub fn dropColumn(self: *Connection, comptime TableType: type, comptime field: []const u8) !void {
        try self.schema.dropColumn(TableType.table_name, field);
        if (!self.transaction_active) try self.persist();
    }

    fn executeForDsl(pointer: *anyopaque, sql: []const u8) anyerror!Result {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        return self.execute(sql, &.{});
    }

    fn executeForRawDsl(pointer: *anyopaque, sql: []const u8, parameters: []const Value) anyerror!Result {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        return self.execute(sql, parameters);
    }

    fn dslTypeName(comptime T: type) []const u8 {
        return switch (@typeInfo(T)) {
            .int, .comptime_int, .bool => "INTEGER",
            .float, .comptime_float => "REAL",
            .pointer => |pointer| if (pointer.size == .slice and pointer.child == u8) "TEXT" else "BLOB",
            else => "BLOB",
        };
    }

    fn hasFieldNamed(comptime fields: anytype, name: []const u8) bool {
        inline for (fields) |field| if (std.mem.eql(u8, field.name, name)) return true;
        return false;
    }

    fn executePrepared(pointer: *anyopaque, sql: []const u8, parameters: []const Value) anyerror!void {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        var result = try self.execute(sql, parameters);
        result.deinit();
    }

    pub fn begin(self: *Connection) !void {
        if (self.transaction_active) return error.TransactionActive;
        self.backup = try self.schema.clone();
        self.transaction_active = true;
    }

    pub fn beginImmediate(self: *Connection) !void {
        try self.begin();
    }
    pub fn beginExclusive(self: *Connection) !void {
        try self.begin();
    }
    pub fn commit(self: *Connection) !void {
        if (!self.transaction_active) return error.NotInTransaction;
        try self.persist();
        if (self.backup) |*backup| backup.deinit();
        self.backup = null;
        self.clearSavepoints();
        self.transaction_active = false;
    }
    pub fn rollback(self: *Connection) !void {
        if (!self.transaction_active) return error.NotInTransaction;
        self.schema.deinit();
        self.schema = self.backup.?;
        self.backup = null;
        self.clearSavepoints();
        self.transaction_active = false;
    }

    pub fn transaction(self: *Connection, callback: anytype) !void {
        try self.begin();
        errdefer self.rollback() catch {};
        try callback(self);
        try self.commit();
    }

    pub fn savepoint(self: *Connection, name: []const u8) !void {
        var result = try self.savepointCommand(name);
        result.deinit();
    }

    pub fn releaseSavepoint(self: *Connection, name: []const u8) !void {
        var result = try self.releaseCommand(name);
        result.deinit();
    }

    pub fn rollbackToSavepoint(self: *Connection, name: []const u8) !void {
        var result = try self.rollbackToCommand(name);
        result.deinit();
    }

    fn clearSavepoints(self: *Connection) void {
        for (self.savepoints.items) |*item| {
            self.allocator.free(item.name);
            item.schema.deinit();
        }
        self.savepoints.clearRetainingCapacity();
    }

    fn savepointCommand(self: *Connection, name: []const u8) !Result {
        if (!self.transaction_active) try self.begin();
        var snapshot = try self.schema.clone();
        errdefer snapshot.deinit();
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.savepoints.append(self.allocator, .{ .name = owned_name, .schema = snapshot });
        return try emptyResult(self.allocator);
    }

    fn releaseCommand(self: *Connection, name: []const u8) !Result {
        var index = self.savepoints.items.len;
        while (index > 0) {
            index -= 1;
            if (std.ascii.eqlIgnoreCase(self.savepoints.items[index].name, name)) {
                while (self.savepoints.items.len > index) {
                    var item = self.savepoints.pop().?;
                    self.allocator.free(item.name);
                    item.schema.deinit();
                }
                return try emptyResult(self.allocator);
            }
        }
        return error.NotInTransaction;
    }

    fn rollbackToCommand(self: *Connection, name: []const u8) !Result {
        var index = self.savepoints.items.len;
        while (index > 0) {
            index -= 1;
            if (std.ascii.eqlIgnoreCase(self.savepoints.items[index].name, name)) {
                self.schema.deinit();
                self.schema = try self.savepoints.items[index].schema.clone();
                while (self.savepoints.items.len > index + 1) {
                    var item = self.savepoints.pop().?;
                    self.allocator.free(item.name);
                    item.schema.deinit();
                }
                return try emptyResult(self.allocator);
            }
        }
        return error.NotInTransaction;
    }

    fn execute(self: *Connection, sql: []const u8, parameters: []const Value) !Result {
        var parser = try Parser.init(self.allocator, sql);
        defer parser.deinit();
        var statement = try parser.parse();
        defer ast.deinit(self.allocator, &statement);
        const result = switch (statement) {
            .create_table => |value| try self.createTableCommand(value),
            .create_index => |value| try self.createIndexCommand(value),
            .create_view => |value| try self.createViewCommand(value),
            .create_trigger => |value| try self.createTriggerCommand(value),
            .create_virtual_table => |value| try self.createVirtualTableCommand(value),
            .drop_table => |value| try self.dropTableCommand(value.name, value.if_exists),
            .drop_index => |value| try self.dropIndexCommand(value.name, value.if_exists),
            .drop_view => |value| try self.dropViewCommand(value.name, value.if_exists),
            .drop_trigger => |value| try self.dropTriggerCommand(value.name, value.if_exists),
            .insert => |value| try self.insert(value, parameters),
            .select => |value| try self.select(value, parameters),
            .with_select => |value| try self.executeWith(value, parameters),
            .explain_query_plan => |query_sql| try self.explainQueryPlan(query_sql),
            .pragma => |value| try self.executePragma(value),
            .alter_table => |value| try self.alterTableCommand(value),
            .update => |value| try self.update(value, parameters),
            .delete => |value| try self.delete(value, parameters),
            .begin => blk: {
                try self.begin();
                break :blk try emptyResult(self.allocator);
            },
            .commit => blk: {
                try self.commit();
                break :blk try emptyResult(self.allocator);
            },
            .rollback => blk: {
                try self.rollback();
                break :blk try emptyResult(self.allocator);
            },
            .savepoint => |name| try self.savepointCommand(name),
            .release => |name| try self.releaseCommand(name),
            .rollback_to => |name| try self.rollbackToCommand(name),
        };
        if (!self.transaction_active and !statement.isQuery()) try self.persist();
        return result;
    }

    fn emptyResult(allocator: std.mem.Allocator) !Result {
        return .{ .allocator = allocator, .columns = try allocator.alloc([]const u8, 0), .rows = try allocator.alloc([]Value, 0) };
    }

    fn executePragma(self: *Connection, value: anytype) !Result {
        if (std.ascii.eqlIgnoreCase(value.name, "foreign_keys")) {
            if (value.value) |setting| {
                if (std.ascii.eqlIgnoreCase(setting, "on") or std.mem.eql(u8, setting, "1")) {
                    self.schema.foreign_keys_enabled = true;
                } else if (std.ascii.eqlIgnoreCase(setting, "off") or std.mem.eql(u8, setting, "0")) {
                    self.schema.foreign_keys_enabled = false;
                } else return error.InvalidSql;
            }
            const names = [_][]const u8{"foreign_keys"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = if (self.schema.foreign_keys_enabled) 1 else 0 };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "user_version")) {
            if (value.value) |version_text| {
                const version = std.fmt.parseInt(u32, version_text, 10) catch return error.InvalidSql;
                self.file.setUserVersion(version);
                try self.persist();
            }
            const names = [_][]const u8{"user_version"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = self.file.getUserVersion() };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "application_id")) {
            if (value.value) |application_text| {
                const application_id = std.fmt.parseInt(u32, application_text, 10) catch return error.InvalidSql;
                self.file.setApplicationId(application_id);
                try self.persist();
            }
            const names = [_][]const u8{"application_id"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = self.file.getApplicationId() };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (!std.ascii.eqlIgnoreCase(value.name, "journal_mode")) return error.Unsupported;
        if (value.value) |mode| {
            if (std.ascii.eqlIgnoreCase(mode, "wal")) {
                self.file.enableWal();
                try self.persist();
            } else if (std.ascii.eqlIgnoreCase(mode, "delete") or std.ascii.eqlIgnoreCase(mode, "rollback")) {
                try self.file.disableWal();
                try self.persist();
            } else return error.Unsupported;
        }
        const names = [_][]const u8{"journal_mode"};
        const columns = try self.ownedColumns(&names);
        const rows = try self.allocator.alloc([]Value, 1);
        rows[0] = try self.allocator.alloc(Value, 1);
        rows[0][0] = .{ .text = try self.allocator.dupe(u8, self.file.journalMode()) };
        return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
    }

    fn explainQueryPlan(self: *Connection, sql: []const u8) anyerror!Result {
        var parser = try Parser.init(self.allocator, sql);
        defer parser.deinit();
        var statement = try parser.parse();
        defer ast.deinit(self.allocator, &statement);
        if (statement != .select) return error.InvalidSql;
        const query = statement.select;
        const table_name = query.table orelse return error.Unsupported;
        const table = self.schema.findConst(table_name) orelse return error.UnknownTable;
        var detail = if (query.condition) |conditions| blk: {
            var chosen: ?[]const u8 = null;
            var chosen_column: []const u8 = "";
            if (conditions.len == 1 and conditions[0].op == .equal) {
                for (self.schema.indexes.items) |index| if (index.columns.len == 1 and std.ascii.eqlIgnoreCase(index.table, table.name) and std.ascii.eqlIgnoreCase(index.columns[0], conditions[0].column)) {
                    chosen = index.name;
                    chosen_column = index.columns[0];
                    break;
                };
            }
            if (chosen) |index_name| break :blk try std.fmt.allocPrint(self.allocator, "SEARCH {s} USING INDEX {s} ({s}=?)", .{ table.name, index_name, chosen_column });
            break :blk try std.fmt.allocPrint(self.allocator, "SCAN {s}", .{table.name});
        } else try std.fmt.allocPrint(self.allocator, "SCAN {s}", .{table.name});
        defer self.allocator.free(detail);
        if (query.order != null) {
            const suffix = try self.allocator.dupe(u8, " USE TEMP B-TREE FOR ORDER BY");
            defer self.allocator.free(suffix);
            const combined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ detail, suffix });
            defer self.allocator.free(combined);
            detail = try self.allocator.dupe(u8, combined);
        }
        const columns = [_][]const u8{"detail"};
        const result_columns = try self.ownedColumns(&columns);
        const row = try self.allocator.alloc(Value, 1);
        row[0] = .{ .text = try self.allocator.dupe(u8, detail) };
        const rows = try self.allocator.alloc([]Value, 1);
        rows[0] = row;
        return .{ .allocator = self.allocator, .columns = result_columns, .rows = rows };
    }

    fn ownedColumns(self: *Connection, columns: []const []const u8) ![]const []const u8 {
        const result = try self.allocator.alloc([]const u8, columns.len);
        var count: usize = 0;
        errdefer {
            for (result[0..count]) |column| self.allocator.free(column);
            self.allocator.free(result);
        }
        for (columns, 0..) |column, index| {
            result[index] = try self.allocator.dupe(u8, column);
            count += 1;
        }
        return result;
    }
    fn createTableCommand(self: *Connection, value: anytype) !Result {
        if (self.schema.find(value.name) != null and value.if_not_exists) return try emptyResult(self.allocator);
        try self.schema.createTable(value.name, value.columns, value.constraints);
        return try emptyResult(self.allocator);
    }
    fn alterTableCommand(self: *Connection, value: ast.AlterTable) !Result {
        switch (value) {
            .add_column => |change| try self.schema.addColumn(change.table, change.definition),
            .rename_table => |change| try self.schema.renameTable(change.table, change.new_name),
            .rename_column => |change| try self.schema.renameColumn(change.table, change.old_name, change.new_name),
            .drop_column => |change| try self.schema.dropColumn(change.table, change.column),
        }
        return try emptyResult(self.allocator);
    }
    fn dropTableCommand(self: *Connection, name: []const u8, if_exists: bool) !Result {
        self.schema.dropTable(name) catch |err| if (if_exists and err == error.UnknownTable) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }
    fn createIndexCommand(self: *Connection, value: ast.IndexDef) !Result {
        if (self.schema.findIndexConst(value.name) != null and value.if_not_exists) return try emptyResult(self.allocator);
        try self.schema.createIndex(value);
        return try emptyResult(self.allocator);
    }
    fn dropIndexCommand(self: *Connection, name: []const u8, if_exists: bool) !Result {
        self.schema.dropIndex(name) catch |err| if (if_exists and err == error.UnknownIndex) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }
    fn createViewCommand(self: *Connection, value: anytype) !Result {
        if (self.schema.findViewConst(value.name) != null and value.if_not_exists) return try emptyResult(self.allocator);
        try self.schema.createView(value.name, value.sql);
        return try emptyResult(self.allocator);
    }
    fn dropViewCommand(self: *Connection, name: []const u8, if_exists: bool) !Result {
        self.schema.dropView(name) catch |err| if (if_exists and err == error.UnknownView) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }
    fn createTriggerCommand(self: *Connection, value: ast.TriggerDef) !Result {
        if (self.schema.findTriggerConst(value.name) != null and value.if_not_exists) return try emptyResult(self.allocator);
        try self.schema.createTrigger(value);
        return try emptyResult(self.allocator);
    }
    fn createVirtualTableCommand(self: *Connection, value: ast.VirtualTableDef) !Result {
        if (self.schema.find(value.name) != null) {
            if (value.if_not_exists) return try emptyResult(self.allocator);
            return error.TableExists;
        }
        try self.schema.createVirtualTable(value.name, value.module, value.arguments);
        return try emptyResult(self.allocator);
    }
    fn dropTriggerCommand(self: *Connection, name: []const u8, if_exists: bool) !Result {
        self.schema.dropTrigger(name) catch |err| if (if_exists and err == error.UnknownTrigger) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }

    fn executeWith(self: *Connection, value: ast.WithSelect, parameters: []const Value) anyerror!Result {
        var created: usize = 0;
        errdefer while (created > 0) {
            created -= 1;
            self.schema.dropTable(value.ctes[created].name) catch {};
        };
        for (value.ctes) |cte| {
            var source = try self.execute(cte.query_sql, parameters);
            defer source.deinit();
            const definitions = try self.allocator.alloc(ast.ColumnDef, source.columns.len);
            defer self.allocator.free(definitions);
            for (source.columns, 0..) |column, index| definitions[index] = .{ .name = column, .type_name = if (source.rows.len == 0) "" else source.rows[0][index].typeName() };
            try self.schema.createTable(cte.name, definitions, &.{});
            const table = self.schema.find(cte.name).?;
            for (source.rows) |row| try self.schema.appendRow(table, row);
            if (cte.recursive_sql) |recursive_sql| {
                if (!value.recursive) return error.Unsupported;
                var iteration: usize = 0;
                while (iteration < 1000) : (iteration += 1) {
                    var next = try self.execute(recursive_sql, parameters);
                    defer next.deinit();
                    var added: usize = 0;
                    for (next.rows) |row| {
                        var exists = false;
                        for (table.rows.items) |existing| if (rowsEqual(existing.values, row)) {
                            exists = true;
                            break;
                        };
                        if (!exists) {
                            try self.schema.appendRow(table, row);
                            added += 1;
                        }
                    }
                    if (added == 0) break;
                } else return error.RecursiveCteLimit;
            }
            created += 1;
        }
        defer while (created > 0) {
            created -= 1;
            self.schema.dropTable(value.ctes[created].name) catch {};
        };
        return self.execute(value.body_sql, parameters);
    }

    fn appendTriggerValue(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: Value) !void {
        switch (value) {
            .null => try output.appendSlice(allocator, "NULL"),
            .integer => |number| {
                const text = try std.fmt.allocPrint(allocator, "{d}", .{number});
                defer allocator.free(text);
                try output.appendSlice(allocator, text);
            },
            .real => |number| {
                const text = try std.fmt.allocPrint(allocator, "{d}", .{number});
                defer allocator.free(text);
                try output.appendSlice(allocator, text);
            },
            .text => |text| {
                try output.append(allocator, '\'');
                for (text) |byte| {
                    if (byte == '\'') try output.append(allocator, '\'');
                    try output.append(allocator, byte);
                }
                try output.append(allocator, '\'');
            },
            .blob => |blob| {
                try output.appendSlice(allocator, "X'");
                const hex = "0123456789ABCDEF";
                for (blob) |byte| {
                    try output.append(allocator, hex[byte >> 4]);
                    try output.append(allocator, hex[byte & 15]);
                }
                try output.append(allocator, '\'');
            },
        }
    }

    fn renderTriggerBody(self: *Connection, body: []const u8, table: *const Table, event: ast.TriggerEvent, new_row: ?[]const Value, old_row: ?[]const Value) ![]u8 {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(self.allocator);
        var index: usize = 0;
        while (index < body.len) {
            if (index + 4 < body.len and (std.ascii.eqlIgnoreCase(body[index .. index + 4], "NEW.") or std.ascii.eqlIgnoreCase(body[index .. index + 4], "OLD."))) {
                const is_new = std.ascii.eqlIgnoreCase(body[index .. index + 4], "NEW.");
                var end = index + 4;
                while (end < body.len and (std.ascii.isAlphanumeric(body[end]) or body[end] == '_')) : (end += 1) {}
                const name = body[index + 4 .. end];
                const column = columnIndex(table, name) catch {
                    try output.append(self.allocator, body[index]);
                    index += 1;
                    continue;
                };
                const row = if (is_new) new_row else old_row;
                if (row == null or (is_new and event == .delete) or (!is_new and event == .insert)) return error.InvalidSql;
                try appendTriggerValue(&output, self.allocator, row.?[column]);
                index = end;
            } else {
                try output.append(self.allocator, body[index]);
                index += 1;
            }
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn fireTriggers(self: *Connection, table_name: []const u8, event: ast.TriggerEvent, new_row: ?[]const Value, old_row: ?[]const Value) anyerror!void {
        const table = self.schema.findConst(table_name) orelse return error.UnknownTable;
        var bodies = std.ArrayList([]u8).empty;
        defer {
            for (bodies.items) |body| self.allocator.free(body);
            bodies.deinit(self.allocator);
        }
        for (self.schema.triggers.items) |trigger| {
            if (trigger.event == event and std.ascii.eqlIgnoreCase(trigger.table, table_name)) try bodies.append(self.allocator, try self.renderTriggerBody(trigger.body, table, event, new_row, old_row));
        }
        for (bodies.items) |body| {
            var result = try self.execute(body, &.{});
            result.deinit();
        }
    }

    fn resolve(self: *Connection, expr: ast.Expr, parameters: []const Value) !Value {
        _ = self;
        return switch (expr) {
            .literal => |value| value,
            .parameter => |index| if (index == 0 or index > parameters.len) error.InvalidParameter else parameters[index - 1],
            else => error.InvalidSql,
        };
    }

    fn copyValue(self: *Connection, value: Value) !Value {
        return switch (value) {
            .text => |bytes| .{ .text = try self.allocator.dupe(u8, bytes) },
            .blob => |bytes| .{ .blob = try self.allocator.dupe(u8, bytes) },
            else => value,
        };
    }

    fn columnIndex(table: *const Table, name: []const u8) !usize {
        for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
        return error.UnknownColumn;
    }

    fn compare(left: Value, op: ast.CompareOp, right: Value) bool {
        if (left == .null or right == .null) return false;
        const result: i8 = switch (left) {
            .integer => |l| switch (right) {
                .integer => |r| if (l < r) -1 else if (l > r) 1 else 0,
                .real => |r| if (@as(f64, @floatFromInt(l)) < r) -1 else if (@as(f64, @floatFromInt(l)) > r) 1 else 0,
                else => -1,
            },
            .real => |l| switch (right) {
                .integer => |r| if (l < @as(f64, @floatFromInt(r))) -1 else if (l > @as(f64, @floatFromInt(r))) 1 else 0,
                .real => |r| if (l < r) -1 else if (l > r) 1 else 0,
                else => -1,
            },
            .text => |l| switch (right) {
                .text => |r| if (std.mem.order(u8, l, r) == .lt) -1 else if (std.mem.order(u8, l, r) == .gt) 1 else 0,
                else => -1,
            },
            .blob => |l| switch (right) {
                .blob => |r| if (std.mem.order(u8, l, r) == .lt) -1 else if (std.mem.order(u8, l, r) == .gt) 1 else 0,
                else => -1,
            },
            .null => 0,
        };
        return switch (op) {
            .equal => result == 0,
            .not_equal => result != 0,
            .less => result < 0,
            .less_equal => result <= 0,
            .greater => result > 0,
            .greater_equal => result >= 0,
            .like, .not_like, .glob, .not_glob, .is_null, .is_not_null, .is_value, .is_not_value, .is_distinct, .is_not_distinct, .between, .in, .not_in, .exists, .not_exists => false,
        };
    }

    fn matches(self: *Connection, table: *const Table, row: []const Value, condition: ?ast.Conditions, parameters: []const Value) anyerror!bool {
        return self.matchesContext(table, row, condition, parameters, null);
    }

    fn matchesContext(self: *Connection, table: *const Table, row: []const Value, condition: ?ast.Conditions, parameters: []const Value, outer: ?OuterRow) anyerror!bool {
        if (condition) |items| {
            var result = true;
            for (items) |item| {
                const item_result = if (item.op == .exists or item.op == .not_exists) blk: {
                    const sql = item.subquery orelse return error.InvalidSql;
                    var parser = try Parser.init(self.allocator, sql);
                    defer parser.deinit();
                    var statement = try parser.parse();
                    defer ast.deinit(self.allocator, &statement);
                    if (statement != .select) return error.InvalidSql;
                    const inner = statement.select;
                    const inner_name = inner.table orelse return error.InvalidSql;
                    const inner_table = self.schema.findConst(inner_name) orelse return error.UnknownTable;
                    var found = false;
                    for (inner_table.rows.items) |inner_row| if (try self.matchesContext(inner_table, inner_row.values, inner.condition, parameters, .{ .table = table, .values = row })) {
                        found = true;
                        break;
                    };
                    break :blk if (item.op == .exists) found else !found;
                } else blk: {
                    const current = if (item.left_expr) |left| try self.evalContext(table, row, left, parameters, outer) else current_column: {
                        const condition_column = if (std.mem.indexOfScalar(u8, item.column, '.')) |dot| item.column[dot + 1 ..] else item.column;
                        break :current_column row[try columnIndex(table, condition_column)];
                    };
                    defer if (item.left_expr != null and current == .text) self.allocator.free(current.text);
                    break :blk if (item.op == .is_null) current == .null else if (item.op == .is_not_null) current != .null else if (item.op == .is_value) sameValue(current, try self.evalContext(table, row, item.value, parameters, outer)) else if (item.op == .is_not_value) !sameValue(current, try self.evalContext(table, row, item.value, parameters, outer)) else if (item.op == .is_distinct) !sameValue(current, try self.evalContext(table, row, item.value, parameters, outer)) else if (item.op == .is_not_distinct) sameValue(current, try self.evalContext(table, row, item.value, parameters, outer)) else if (item.op == .in and item.subquery != null) in_subquery: {
                        const sql = item.subquery orelse return error.InvalidSql;
                        var subquery = try self.execute(sql, parameters);
                        defer subquery.deinit();
                        var found = false;
                        if (subquery.columns.len == 1) for (subquery.rows) |subquery_row| if (subquery_row.len != 0 and compare(current, .equal, subquery_row[0])) {
                            found = true;
                            break;
                        };
                        break :in_subquery found;
                    } else if (item.op == .not_in and item.subquery != null) not_in_subquery: {
                        const sql = item.subquery orelse return error.InvalidSql;
                        var subquery = try self.execute(sql, parameters);
                        defer subquery.deinit();
                        var found = false;
                        if (subquery.columns.len == 1) for (subquery.rows) |subquery_row| if (subquery_row.len != 0 and compare(current, .equal, subquery_row[0])) {
                            found = true;
                            break;
                        };
                        break :not_in_subquery !found;
                    } else if ((item.op == .in or item.op == .not_in) and item.list_values.len != 0) list_values: {
                        var found = false;
                        for (item.list_values) |candidate| if (compare(current, .equal, try self.evalContext(table, row, candidate, parameters, outer))) {
                            found = true;
                            break;
                        };
                        break :list_values if (item.op == .in) found else !found;
                    } else if (item.op == .between) compare(current, .greater_equal, try self.evalContext(table, row, item.value, parameters, outer)) and compare(current, .less_equal, try self.evalContext(table, row, item.value2 orelse return error.InvalidSql, parameters, outer)) else if (item.op == .like or item.op == .not_like) like_pattern: {
                        const pattern = try self.evalContext(table, row, item.value, parameters, outer);
                        const comparable = current == .text and pattern == .text;
                        const matched = comparable and likeMatch(current.text, pattern.text);
                        break :like_pattern if (item.op == .like) matched else comparable and !matched;
                    } else if (item.op == .glob or item.op == .not_glob) glob_pattern: {
                        const pattern = try self.evalContext(table, row, item.value, parameters, outer);
                        const comparable = current == .text and pattern == .text;
                        const matched = comparable and globMatch(current.text, pattern.text);
                        break :glob_pattern if (item.op == .glob) matched else comparable and !matched;
                    } else compare(current, item.op, try self.evalContext(table, row, item.value, parameters, outer));
                };
                result = if (item.join_or) result or item_result else result and item_result;
            }
            return result;
        }
        return true;
    }

    fn likeMatch(text: []const u8, pattern: []const u8) bool {
        if (pattern.len == 0) return text.len == 0;
        if (pattern[0] == '%') {
            var index: usize = 0;
            while (index <= text.len) : (index += 1) if (likeMatch(text[index..], pattern[1..])) return true;
            return false;
        }
        if (pattern[0] == '_') return text.len != 0 and likeMatch(text[1..], pattern[1..]);
        return text.len != 0 and std.ascii.toLower(pattern[0]) == std.ascii.toLower(text[0]) and likeMatch(text[1..], pattern[1..]);
    }

    fn rowsEqual(left: []const Value, right: []const Value) bool {
        if (left.len != right.len) return false;
        for (left, right) |a, b| switch (a) {
            .null => if (b != .null) return false,
            .integer => |value| if (b != .integer or b.integer != value) return false,
            .real => |value| if (b != .real or b.real != value) return false,
            .text => |value| if (b != .text or !std.mem.eql(u8, value, b.text)) return false,
            .blob => |value| if (b != .blob or !std.mem.eql(u8, value, b.blob)) return false,
        };
        return true;
    }

    fn eval(self: *Connection, table: *const Table, row: []const Value, expr: ast.Expr, parameters: []const Value) !Value {
        return self.evalContext(table, row, expr, parameters, null);
    }

    fn evalContext(self: *Connection, table: *const Table, row: []const Value, expr: ast.Expr, parameters: []const Value, outer: ?OuterRow) !Value {
        return switch (expr) {
            .literal => |value| value,
            .parameter => |index| if (index == 0 or index > parameters.len) error.InvalidParameter else parameters[index - 1],
            .identifier => |name| {
                const excluded_prefix = "excluded.";
                const column_name = if (name.len > excluded_prefix.len and std.ascii.eqlIgnoreCase(name[0..excluded_prefix.len], excluded_prefix)) name[excluded_prefix.len..] else name;
                if (outer) |context| if (std.mem.indexOfScalar(u8, column_name, '.')) |dot| {
                    const table_name = column_name[0..dot];
                    if (std.ascii.eqlIgnoreCase(table_name, context.table.name)) return context.values[try columnIndex(context.table, column_name[dot + 1 ..])];
                };
                return row[try columnIndex(table, column_name)];
            },
            .wildcard => error.InvalidSql,
            .binary => |binary| blk: {
                const left = try self.evalContext(table, row, binary.left.*, parameters, outer);
                const right = try self.evalContext(table, row, binary.right.*, parameters, outer);
                if (left == .null or right == .null) break :blk .null;
                break :blk switch (left) {
                    .integer => |left_value| switch (right) {
                        .integer => |right_value| .{ .integer = if (binary.op == .add) left_value + right_value else left_value - right_value },
                        .real => |right_value| .{ .real = if (binary.op == .add) @as(f64, @floatFromInt(left_value)) + right_value else @as(f64, @floatFromInt(left_value)) - right_value },
                        else => return error.InvalidSql,
                    },
                    .real => |left_value| switch (right) {
                        .integer => |right_value| .{ .real = if (binary.op == .add) left_value + @as(f64, @floatFromInt(right_value)) else left_value - @as(f64, @floatFromInt(right_value)) },
                        .real => |right_value| .{ .real = if (binary.op == .add) left_value + right_value else left_value - right_value },
                        else => return error.InvalidSql,
                    },
                    else => return error.InvalidSql,
                };
            },
            .function => |call| blk: {
                const argument = if (call.argument.* == .wildcard) .null else try self.evalContext(table, row, call.argument.*, parameters, outer);
                if (std.ascii.eqlIgnoreCase(call.name, "length")) break :blk switch (argument) {
                    .text => |bytes| .{ .integer = @intCast(bytes.len) },
                    .blob => |bytes| .{ .integer = @intCast(bytes.len) },
                    else => .null,
                };
                if (std.ascii.eqlIgnoreCase(call.name, "abs")) break :blk switch (argument) {
                    .integer => |n| .{ .integer = if (n < 0) -n else n },
                    .real => |n| .{ .real = if (n < 0) -n else n },
                    else => .null,
                };
                if (std.ascii.eqlIgnoreCase(call.name, "round")) break :blk switch (argument) {
                    .integer => |n| if (call.argument2 == null) .{ .integer = n } else blk_round: {
                        const precision_value = try self.evalContext(table, row, call.argument2.?.*, parameters, outer);
                        if (precision_value != .integer) break :blk_round .null;
                        var factor: f64 = 1;
                        if (precision_value.integer >= 0) {
                            var count: i64 = 0;
                            while (count < precision_value.integer) : (count += 1) factor *= 10;
                        } else {
                            var count: i64 = 0;
                            while (count > precision_value.integer) : (count -= 1) factor /= 10;
                        }
                        break :blk_round .{ .real = std.math.round(@as(f64, @floatFromInt(n)) * factor) / factor };
                    },
                    .real => |n| if (call.argument2) |precision_expr| blk_round: {
                        const precision_value = try self.evalContext(table, row, precision_expr.*, parameters, outer);
                        if (precision_value != .integer) break :blk_round .null;
                        var factor: f64 = 1;
                        if (precision_value.integer >= 0) {
                            var count: i64 = 0;
                            while (count < precision_value.integer) : (count += 1) factor *= 10;
                        } else {
                            var count: i64 = 0;
                            while (count > precision_value.integer) : (count -= 1) factor /= 10;
                        }
                        break :blk_round .{ .real = std.math.round(n * factor) / factor };
                    } else .{ .real = std.math.round(n) },
                    else => .null,
                };
                if (std.ascii.eqlIgnoreCase(call.name, "typeof")) break :blk .{ .text = argument.typeName() };
                if (std.ascii.eqlIgnoreCase(call.name, "cast")) {
                    const target = call.argument2 orelse return error.InvalidSql;
                    const target_name = switch (target.*) {
                        .identifier => |name| name,
                        else => return error.InvalidSql,
                    };
                    if (std.ascii.eqlIgnoreCase(target_name, "integer") or std.ascii.eqlIgnoreCase(target_name, "int")) break :blk switch (argument) {
                        .integer => argument,
                        .real => |n| .{ .integer = @intFromFloat(n) },
                        .text => |text| .{ .integer = std.fmt.parseInt(i64, text, 10) catch 0 },
                        else => .null,
                    };
                    if (std.ascii.eqlIgnoreCase(target_name, "real") or std.ascii.eqlIgnoreCase(target_name, "float")) break :blk switch (argument) {
                        .integer => |n| .{ .real = @floatFromInt(n) },
                        .real => argument,
                        .text => |text| .{ .real = std.fmt.parseFloat(f64, text) catch 0 },
                        else => .null,
                    };
                    if (std.ascii.eqlIgnoreCase(target_name, "text")) break :blk switch (argument) {
                        .text => argument,
                        else => .null,
                    };
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "lower") or std.ascii.eqlIgnoreCase(call.name, "upper")) {
                    if (argument == .text) {
                        const copy = try self.allocator.dupe(u8, argument.text);
                        for (copy) |*byte| byte.* = if (std.ascii.eqlIgnoreCase(call.name, "lower")) std.ascii.toLower(byte.*) else std.ascii.toUpper(byte.*);
                        break :blk .{ .text = copy };
                    }
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "trim") or std.ascii.eqlIgnoreCase(call.name, "ltrim") or std.ascii.eqlIgnoreCase(call.name, "rtrim")) {
                    if (argument == .text) {
                        var start: usize = 0;
                        var end: usize = argument.text.len;
                        if (!std.ascii.eqlIgnoreCase(call.name, "rtrim")) while (start < end and std.ascii.isWhitespace(argument.text[start])) : (start += 1) {};
                        if (!std.ascii.eqlIgnoreCase(call.name, "ltrim")) while (end > start and std.ascii.isWhitespace(argument.text[end - 1])) : (end -= 1) {};
                        break :blk .{ .text = try self.allocator.dupe(u8, argument.text[start..end]) };
                    }
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "instr")) {
                    const needle_expr = call.argument2 orelse return error.InvalidSql;
                    const needle = try self.evalContext(table, row, needle_expr.*, parameters, outer);
                    if (argument == .text and needle == .text) {
                        const position = std.mem.indexOf(u8, argument.text, needle.text) orelse break :blk .{ .integer = 0 };
                        break :blk .{ .integer = @intCast(position + 1) };
                    }
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "json_extract")) {
                    const path_expr = call.argument2 orelse return error.InvalidSql;
                    const path = try self.evalContext(table, row, path_expr.*, parameters, outer);
                    break :blk try self.extractJsonTopLevel(argument, path);
                }
                if (std.ascii.eqlIgnoreCase(call.name, "nullif")) {
                    const second_expr = call.argument2 orelse return error.InvalidSql;
                    const second = try self.evalContext(table, row, second_expr.*, parameters, outer);
                    if (sameValue(argument, second)) break :blk .null;
                    break :blk argument;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "coalesce") or std.ascii.eqlIgnoreCase(call.name, "ifnull")) {
                    if (argument != .null) break :blk argument;
                    if (call.argument2) |second| {
                        const value = try self.evalContext(table, row, second.*, parameters, outer);
                        if (value != .null or std.ascii.eqlIgnoreCase(call.name, "ifnull")) break :blk value;
                    }
                    if (call.argument3) |third| break :blk try self.evalContext(table, row, third.*, parameters, outer);
                    break :blk .null;
                }
                return error.Unsupported;
            },
        };
    }

    fn extractJsonTopLevel(self: *Connection, source: Value, path: Value) !Value {
        if (source != .text or path != .text or !std.mem.startsWith(u8, path.text, "$.")) return .null;
        const key = path.text[2..];
        var cursor: usize = 0;
        while (cursor < source.text.len) : (cursor += 1) {
            if (source.text[cursor] != '"') continue;
            const key_start = cursor + 1;
            const key_end = std.mem.indexOfScalarPos(u8, source.text, key_start, '"') orelse break;
            if (!std.mem.eql(u8, source.text[key_start..key_end], key)) {
                cursor = key_end;
                continue;
            }
            var value_start = key_end + 1;
            while (value_start < source.text.len and (source.text[value_start] == ' ' or source.text[value_start] == '\t' or source.text[value_start] == ':')) : (value_start += 1) {}
            if (value_start >= source.text.len) break;
            if (source.text[value_start] == '"') {
                const text_start = value_start + 1;
                const text_end = std.mem.indexOfScalarPos(u8, source.text, text_start, '"') orelse break;
                return .{ .text = try self.allocator.dupe(u8, source.text[text_start..text_end]) };
            }
            const value_end = std.mem.indexOfAnyPos(u8, source.text, value_start, ",}") orelse source.text.len;
            const raw = std.mem.trim(u8, source.text[value_start..value_end], " \t\r\n");
            if (std.mem.eql(u8, raw, "null")) return .null;
            if (std.fmt.parseInt(i64, raw, 10)) |number| return .{ .integer = number } else |_| {}
            if (std.fmt.parseFloat(f64, raw)) |number| return .{ .real = number } else |_| {}
            return .null;
        }
        return .null;
    }

    fn globMatch(text: []const u8, pattern: []const u8) bool {
        if (pattern.len == 0) return text.len == 0;
        if (pattern[0] == '*') return globMatch(text, pattern[1..]) or (text.len != 0 and globMatch(text[1..], pattern));
        if (text.len == 0) return false;
        if (pattern[0] == '?') return globMatch(text[1..], pattern[1..]);
        if (pattern[0] == '[') {
            var i: usize = 1;
            var matched = false;
            var negated = false;
            if (i < pattern.len and (pattern[i] == '^' or pattern[i] == '!')) {
                negated = true;
                i += 1;
            }
            while (i < pattern.len and pattern[i] != ']') : (i += 1) {
                if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                    if (text[0] >= pattern[i] and text[0] <= pattern[i + 2]) matched = true;
                    i += 2;
                } else if (text[0] == pattern[i]) matched = true;
            }
            if (i >= pattern.len) return text[0] == '[' and globMatch(text[1..], pattern[1..]);
            if (negated) matched = !matched;
            return matched and globMatch(text[1..], pattern[i + 1 ..]);
        }
        return text[0] == pattern[0] and globMatch(text[1..], pattern[1..]);
    }

    fn materialize(self: *Connection, table: *const Table, row: []const Value, expr: ast.Expr, parameters: []const Value) !Value {
        if (expr == .function) {
            const call = expr.function;
            if (std.ascii.eqlIgnoreCase(call.name, "json_extract")) {
                const path_expr = call.argument2 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const path = try self.eval(table, row, path_expr.*, parameters);
                if (source == .text and path == .text and std.mem.startsWith(u8, path.text, "$.")) {
                    const key = path.text[2..];
                    var cursor: usize = 0;
                    while (cursor < source.text.len) : (cursor += 1) {
                        if (source.text[cursor] != '"') continue;
                        const key_start = cursor + 1;
                        const key_end = std.mem.indexOfScalarPos(u8, source.text, key_start, '"') orelse break;
                        if (!std.mem.eql(u8, source.text[key_start..key_end], key)) {
                            cursor = key_end;
                            continue;
                        }
                        var value_start = key_end + 1;
                        while (value_start < source.text.len and (source.text[value_start] == ' ' or source.text[value_start] == '\t' or source.text[value_start] == ':')) : (value_start += 1) {}
                        if (value_start >= source.text.len) break;
                        if (source.text[value_start] == '"') {
                            const text_start = value_start + 1;
                            const text_end = std.mem.indexOfScalarPos(u8, source.text, text_start, '"') orelse break;
                            return .{ .text = try self.allocator.dupe(u8, source.text[text_start..text_end]) };
                        }
                        const value_end = std.mem.indexOfAnyPos(u8, source.text, value_start, ",}") orelse source.text.len;
                        const raw = std.mem.trim(u8, source.text[value_start..value_end], " \t\r\n");
                        if (std.mem.eql(u8, raw, "null")) return .null;
                        if (std.fmt.parseInt(i64, raw, 10)) |number| return .{ .integer = number } else |_| {}
                        if (std.fmt.parseFloat(f64, raw)) |number| return .{ .real = number } else |_| {}
                        return .null;
                    }
                }
                return .null;
            }
            if (std.ascii.eqlIgnoreCase(call.name, "json_set")) {
                const path_expr = call.argument2 orelse return error.InvalidSql;
                const value_expr = call.argument3 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const path = try self.eval(table, row, path_expr.*, parameters);
                const replacement = try self.eval(table, row, value_expr.*, parameters);
                if (source == .text and path == .text and replacement == .text and std.mem.startsWith(u8, path.text, "$.")) {
                    const key = path.text[2..];
                    var cursor: usize = 0;
                    while (cursor < source.text.len) : (cursor += 1) {
                        if (source.text[cursor] != '"') continue;
                        const key_start = cursor + 1;
                        const key_end = std.mem.indexOfScalarPos(u8, source.text, key_start, '"') orelse break;
                        if (!std.mem.eql(u8, source.text[key_start..key_end], key)) {
                            cursor = key_end;
                            continue;
                        }
                        var value_start = key_end + 1;
                        while (value_start < source.text.len and (source.text[value_start] == ' ' or source.text[value_start] == '\t' or source.text[value_start] == ':')) : (value_start += 1) {}
                        const value_end = if (value_start < source.text.len and source.text[value_start] == '"') (std.mem.indexOfScalarPos(u8, source.text, value_start + 1, '"') orelse return .null) + 1 else (std.mem.indexOfAnyPos(u8, source.text, value_start, ",}") orelse source.text.len);
                        var output = std.ArrayList(u8).empty;
                        defer output.deinit(self.allocator);
                        try output.appendSlice(self.allocator, source.text[0..value_start]);
                        try output.append(self.allocator, '"');
                        try output.appendSlice(self.allocator, replacement.text);
                        try output.append(self.allocator, '"');
                        try output.appendSlice(self.allocator, source.text[value_end..]);
                        return .{ .text = try output.toOwnedSlice(self.allocator) };
                    }
                    if (source.text.len >= 2 and source.text[source.text.len - 1] == '}') {
                        var body_end = source.text.len - 1;
                        while (body_end > 0 and (source.text[body_end - 1] == ' ' or source.text[body_end - 1] == '\t' or source.text[body_end - 1] == '\r' or source.text[body_end - 1] == '\n')) : (body_end -= 1) {}
                        const body = source.text[0..body_end];
                        var output = std.ArrayList(u8).empty;
                        defer output.deinit(self.allocator);
                        try output.appendSlice(self.allocator, body);
                        if (body.len != 1) try output.append(self.allocator, ',');
                        try output.appendSlice(self.allocator, "\"");
                        try output.appendSlice(self.allocator, key);
                        try output.appendSlice(self.allocator, "\":\"");
                        try output.appendSlice(self.allocator, replacement.text);
                        try output.appendSlice(self.allocator, "\"}");
                        return .{ .text = try output.toOwnedSlice(self.allocator) };
                    }
                }
                return .null;
            }
            if (std.ascii.eqlIgnoreCase(call.name, "replace")) {
                const old_expr = call.argument2 orelse return error.InvalidSql;
                const new_expr = call.argument3 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const old = try self.eval(table, row, old_expr.*, parameters);
                const replacement = try self.eval(table, row, new_expr.*, parameters);
                if (source == .text and old == .text and replacement == .text) {
                    var output = std.ArrayList(u8).empty;
                    defer output.deinit(self.allocator);
                    var offset: usize = 0;
                    while (std.mem.indexOfPos(u8, source.text, offset, old.text)) |found| {
                        try output.appendSlice(self.allocator, source.text[offset..found]);
                        try output.appendSlice(self.allocator, replacement.text);
                        offset = found + old.text.len;
                        if (old.text.len == 0) break;
                    }
                    try output.appendSlice(self.allocator, source.text[offset..]);
                    return .{ .text = try output.toOwnedSlice(self.allocator) };
                }
                return .null;
            }
            if (std.ascii.eqlIgnoreCase(call.name, "substr")) {
                const start_expr = call.argument2 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const start = try self.eval(table, row, start_expr.*, parameters);
                if (source == .text and start == .integer) {
                    const start_index: usize = if (start.integer <= 1) 0 else @min(@as(usize, @intCast(start.integer - 1)), source.text.len);
                    var end = source.text.len;
                    if (call.argument3) |length_expr| {
                        const length = try self.eval(table, row, length_expr.*, parameters);
                        if (length != .integer) return .null;
                        end = @min(source.text.len, start_index + @as(usize, @intCast(@max(length.integer, 0))));
                    }
                    return .{ .text = try self.allocator.dupe(u8, source.text[start_index..end]) };
                }
                return .null;
            }
            if (std.ascii.eqlIgnoreCase(call.name, "instr")) {
                const needle_expr = call.argument2 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const needle = try self.eval(table, row, needle_expr.*, parameters);
                if (source == .text and needle == .text) {
                    const position = std.mem.indexOf(u8, source.text, needle.text) orelse return .{ .integer = 0 };
                    return .{ .integer = @intCast(position + 1) };
                }
                return .null;
            }
            if (std.ascii.eqlIgnoreCase(call.name, "lower") or std.ascii.eqlIgnoreCase(call.name, "upper") or std.ascii.eqlIgnoreCase(call.name, "trim") or std.ascii.eqlIgnoreCase(call.name, "ltrim") or std.ascii.eqlIgnoreCase(call.name, "rtrim")) {
                const argument = try self.eval(table, row, call.argument.*, parameters);
                if (argument == .text) {
                    if (std.ascii.eqlIgnoreCase(call.name, "trim") or std.ascii.eqlIgnoreCase(call.name, "ltrim") or std.ascii.eqlIgnoreCase(call.name, "rtrim")) {
                        var start: usize = 0;
                        var end: usize = argument.text.len;
                        if (!std.ascii.eqlIgnoreCase(call.name, "rtrim")) while (start < end and std.ascii.isWhitespace(argument.text[start])) : (start += 1) {};
                        if (!std.ascii.eqlIgnoreCase(call.name, "ltrim")) while (end > start and std.ascii.isWhitespace(argument.text[end - 1])) : (end -= 1) {};
                        return .{ .text = try self.allocator.dupe(u8, argument.text[start..end]) };
                    }
                    const copy = try self.allocator.dupe(u8, argument.text);
                    for (copy) |*byte| byte.* = if (std.ascii.eqlIgnoreCase(call.name, "lower")) std.ascii.toLower(byte.*) else std.ascii.toUpper(byte.*);
                    return .{ .text = copy };
                }
            }
        }
        return try self.copyValue(try self.eval(table, row, expr, parameters));
    }

    fn initializeInsertRow(self: *Connection, table: *const Table, row: []Value) !void {
        _ = self;
        @memset(row, .null);
        for (table.columns, 0..) |column, index| {
            if (column.default_value) |default| row[index] = default;
        }
    }

    fn insert(self: *Connection, value: anytype, parameters: []const Value) anyerror!Result {
        const table = self.schema.find(value.table) orelse return error.UnknownTable;
        if (value.select_sql) |select_sql| {
            var source = try self.execute(select_sql, parameters);
            defer source.deinit();
            var changes: usize = 0;
            for (source.rows) |source_row| {
                var row = try self.allocator.alloc(Value, table.columns.len);
                defer self.allocator.free(row);
                try self.initializeInsertRow(table, row);
                if (value.columns.len == 0) {
                    if (source_row.len != row.len) return error.ColumnCountMismatch;
                    for (source_row, 0..) |item, index| row[index] = item;
                } else {
                    if (value.columns.len != source_row.len) return error.ColumnCountMismatch;
                    for (value.columns, source_row) |name, item| row[try columnIndex(table, name)] = item;
                }
                self.schema.appendRow(table, row) catch |err| {
                    if (value.conflict == .ignore and err == error.ConstraintViolation) continue;
                    if (value.conflict == .replace and err == error.ConstraintViolation) {
                        if (try self.replaceConflict(table, row)) {
                            try self.schema.appendRow(table, row);
                            try self.fireTriggers(table.name, .insert, row, null);
                            changes += 1;
                            continue;
                        }
                    }
                    if (value.conflict == .update and err == error.ConstraintViolation) {
                        switch (try self.applyUpsert(table, row, value.upsert_columns, value.upsert_values, value.upsert_where, parameters)) {
                            .updated => {
                                changes += 1;
                                continue;
                            },
                            .skipped => continue,
                            .no_conflict => {},
                        }
                    }
                    return err;
                };
                try self.fireTriggers(table.name, .insert, row, null);
                changes += 1;
            }
            return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
        }
        var changes: usize = 0;
        for (value.rows) |row_exprs| {
            var row = try self.allocator.alloc(Value, table.columns.len);
            defer self.allocator.free(row);
            try self.initializeInsertRow(table, row);
            if (value.columns.len == 0) {
                if (row_exprs.len != 0 and row_exprs.len != row.len) return error.ColumnCountMismatch;
                for (row_exprs, 0..) |expr, index| row[index] = try self.resolve(expr, parameters);
            } else {
                if (value.columns.len != row_exprs.len) return error.ColumnCountMismatch;
                for (value.columns, row_exprs) |name, expr| row[try columnIndex(table, name)] = try self.resolve(expr, parameters);
            }
            self.schema.appendRow(table, row) catch |err| {
                if (value.conflict == .ignore and err == error.ConstraintViolation) continue;
                if (value.conflict == .replace and err == error.ConstraintViolation) {
                    if (try self.replaceConflict(table, row)) {
                        try self.schema.appendRow(table, row);
                        try self.fireTriggers(table.name, .insert, row, null);
                        changes += 1;
                        continue;
                    }
                }
                if (value.conflict == .update and err == error.ConstraintViolation) {
                    switch (try self.applyUpsert(table, row, value.upsert_columns, value.upsert_values, value.upsert_where, parameters)) {
                        .updated => {
                            changes += 1;
                            continue;
                        },
                        .skipped => continue,
                        .no_conflict => {},
                    }
                }
                return err;
            };
            try self.fireTriggers(table.name, .insert, row, null);
            changes += 1;
        }
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
    }

    fn selectGrouped(self: *Connection, table: *const Table, value: anytype, group_name: []const u8, parameters: []const Value) !Result {
        const Group = struct { key: Value, rows: std.ArrayList(usize) };
        const group_index = try columnIndex(table, group_name);
        var groups = std.ArrayList(Group).empty;
        defer {
            for (groups.items) |*group| {
                if (group.key == .text) self.allocator.free(group.key.text) else if (group.key == .blob) self.allocator.free(group.key.blob);
                group.rows.deinit(self.allocator);
            }
            groups.deinit(self.allocator);
        }
        for (table.rows.items, 0..) |row, row_index| {
            if (!try self.matches(table, row.values, value.condition, parameters)) continue;
            var found: ?usize = null;
            for (groups.items, 0..) |group, position| if (sameValue(group.key, row.values[group_index])) {
                found = position;
                break;
            };
            if (found) |position| {
                try groups.items[position].rows.append(self.allocator, row_index);
            } else {
                try groups.append(self.allocator, .{ .key = try self.copyValue(row.values[group_index]), .rows = .empty });
                try groups.items[groups.items.len - 1].rows.append(self.allocator, row_index);
            }
        }
        var columns = std.ArrayList([]const u8).empty;
        defer columns.deinit(self.allocator);
        for (value.projections) |projection| switch (projection.expr) {
            .identifier => try columns.append(self.allocator, projection.alias orelse projection.expr.identifier),
            .function => try columns.append(self.allocator, projection.alias orelse projection.expr.function.name),
            else => return error.Unsupported,
        };
        var rows = std.ArrayList([]Value).empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        for (groups.items) |group| {
            if (value.having) |having| {
                const left_value: Value = switch (having.left) {
                    .identifier => |name| if (std.ascii.eqlIgnoreCase(name, group_name)) try self.copyValue(group.key) else return error.Unsupported,
                    .function => |function| blk: {
                        if (std.ascii.eqlIgnoreCase(function.name, "count")) break :blk .{ .integer = @intCast(group.rows.items.len) };
                        if (std.ascii.eqlIgnoreCase(function.name, "sum")) {
                            var total: i64 = 0;
                            for (group.rows.items) |row_index| switch (try self.eval(table, table.rows.items[row_index].values, function.argument.*, parameters)) {
                                .integer => |number| total += number,
                                else => {},
                            };
                            break :blk .{ .integer = total };
                        }
                        return error.Unsupported;
                    },
                    else => return error.Unsupported,
                };
                defer if (left_value == .text) self.allocator.free(left_value.text) else if (left_value == .blob) self.allocator.free(left_value.blob);
                const right_value = try self.resolve(having.right, parameters);
                if (!compare(left_value, having.op, right_value)) continue;
            }
            const output = try self.allocator.alloc(Value, value.projections.len);
            errdefer self.allocator.free(output);
            for (value.projections, 0..) |projection, output_index| switch (projection.expr) {
                .identifier => {
                    if (!std.ascii.eqlIgnoreCase(projection.expr.identifier, group_name)) return error.Unsupported;
                    output[output_index] = try self.copyValue(group.key);
                },
                .function => |function| {
                    const is_count = std.ascii.eqlIgnoreCase(function.name, "count");
                    const is_sum = std.ascii.eqlIgnoreCase(function.name, "sum");
                    const is_avg = std.ascii.eqlIgnoreCase(function.name, "avg") or std.ascii.eqlIgnoreCase(function.name, "average");
                    const is_min = std.ascii.eqlIgnoreCase(function.name, "min");
                    const is_max = std.ascii.eqlIgnoreCase(function.name, "max");
                    if (!is_count and !is_sum and !is_avg and !is_min and !is_max) return error.Unsupported;
                    if (is_count) {
                        var count: usize = 0;
                        for (group.rows.items) |row_index| {
                            if (function.argument.* == .wildcard or (try self.eval(table, table.rows.items[row_index].values, function.argument.*, parameters)) != .null) count += 1;
                        }
                        output[output_index] = .{ .integer = @intCast(count) };
                    } else {
                        var total: f64 = 0;
                        var integer_total: i64 = 0;
                        var numeric_count: usize = 0;
                        var real_seen = false;
                        var extremum: f64 = 0;
                        for (group.rows.items) |row_index| switch (try self.eval(table, table.rows.items[row_index].values, function.argument.*, parameters)) {
                            .integer => |number| {
                                const numeric = @as(f64, @floatFromInt(number));
                                total += numeric;
                                integer_total += number;
                                if (numeric_count == 0 or (is_min and numeric < extremum) or (is_max and numeric > extremum)) extremum = numeric;
                                numeric_count += 1;
                            },
                            .real => |number| {
                                real_seen = true;
                                total += number;
                                if (numeric_count == 0 or (is_min and number < extremum) or (is_max and number > extremum)) extremum = number;
                                numeric_count += 1;
                            },
                            else => {},
                        };
                        output[output_index] = if (numeric_count == 0) .null else if (is_avg) .{ .real = total / @as(f64, @floatFromInt(numeric_count)) } else if (is_min or is_max) if (real_seen) .{ .real = extremum } else .{ .integer = @intFromFloat(extremum) } else if (real_seen) .{ .real = total } else .{ .integer = integer_total };
                    }
                },
                else => return error.Unsupported,
            };
            try rows.append(self.allocator, output);
        }
        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn conflictRow(self: *Connection, table: *const Table, values: []const Value) ?usize {
        for (table.rows.items, 0..) |existing, row_index| {
            var matched = false;
            for (table.columns, 0..) |column, column_index| if ((column.primary_key or column.unique) and values[column_index] != .null and sameValue(existing.values[column_index], values[column_index])) {
                matched = true;
                break;
            };
            if (matched) return row_index;
            for (table.constraints) |constraint| {
                if (constraint.kind == .foreign_key) continue;
                var valid = true;
                var has_null = false;
                for (constraint.columns) |name| {
                    const column_index = columnIndex(table, name) catch {
                        valid = false;
                        break;
                    };
                    if (values[column_index] == .null) has_null = true;
                    if (!sameValue(existing.values[column_index], values[column_index])) valid = false;
                }
                if (valid and (constraint.kind == .primary_key or !has_null)) return row_index;
            }
            for (self.schema.indexes.items) |index| if (index.unique and std.ascii.eqlIgnoreCase(index.table, table.name)) {
                var valid = true;
                var has_null = false;
                for (index.columns) |name| {
                    const column_index = columnIndex(table, name) catch {
                        valid = false;
                        break;
                    };
                    if (values[column_index] == .null) has_null = true;
                    if (!sameValue(existing.values[column_index], values[column_index])) valid = false;
                }
                if (valid and !has_null) return row_index;
            };
        }
        return null;
    }

    fn resolveUpsert(self: *Connection, table: *const Table, expression: ast.Expr, excluded: []const Value, parameters: []const Value) !Value {
        if (expression == .identifier) {
            const name = expression.identifier;
            const prefix = "excluded.";
            if (name.len > prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) {
                return excluded[try columnIndex(table, name[prefix.len..])];
            }
        }
        return self.eval(table, excluded, expression, parameters);
    }

    fn applyUpsert(self: *Connection, table: *Table, values: []const Value, columns: []const []const u8, expressions: []const ast.Expr, where: ?ast.Conditions, parameters: []const Value) anyerror!ast.UpsertResult {
        const row_index = self.conflictRow(table, values) orelse return .no_conflict;
        const row = &table.rows.items[row_index];
        const old_snapshot = try self.allocator.alloc(Value, row.values.len);
        defer {
            for (old_snapshot) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
            self.allocator.free(old_snapshot);
        }
        for (row.values, 0..) |item, index| old_snapshot[index] = try self.copyValue(item);
        const candidate = try self.allocator.alloc(Value, row.values.len);
        defer self.allocator.free(candidate);
        @memcpy(candidate, row.values);
        for (columns, expressions) |name, expression| candidate[try columnIndex(table, name)] = try self.resolveUpsert(table, expression, values, parameters);
        if (where) |conditions| if (!try self.matches(table, row.values, conditions, parameters)) return .skipped;
        try self.schema.validateUpdate(table, row_index, candidate);
        try self.applyUpdateActions(table.name, row.values, candidate);
        for (columns, expressions) |name, expression| {
            const index = try columnIndex(table, name);
            const new_value = try self.resolveUpsert(table, expression, values, parameters);
            if (row.values[index] == .text) self.allocator.free(row.values[index].text);
            if (row.values[index] == .blob) self.allocator.free(row.values[index].blob);
            row.values[index] = switch (new_value) {
                .text => |text| .{ .text = try self.allocator.dupe(u8, text) },
                .blob => |blob| .{ .blob = try self.allocator.dupe(u8, blob) },
                else => new_value,
            };
        }
        try self.fireTriggers(table.name, .update, row.values, old_snapshot);
        return .updated;
    }

    fn replaceConflict(self: *Connection, table: *Table, values: []const Value) anyerror!bool {
        const row_index = self.conflictRow(table, values) orelse return false;
        try self.applyDeleteActions(table.name, table.rows.items[row_index].values);
        const removed = table.rows.orderedRemove(row_index);
        try self.fireTriggers(table.name, .delete, null, removed.values);
        for (removed.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
        self.allocator.free(removed.values);
        return true;
    }

    fn select(self: *Connection, value: anytype, parameters: []const Value) anyerror!Result {
        var columns = std.ArrayList([]const u8).empty;
        defer columns.deinit(self.allocator);
        var projections = std.ArrayList(ast.Projection).empty;
        defer projections.deinit(self.allocator);
        if (value.table) |table_name| {
            const table = self.schema.findConst(table_name) orelse {
                const view = self.schema.findViewConst(table_name) orelse return error.UnknownTable;
                if (value.projections.len != 1 or value.projections[0].expr != .wildcard or value.join != null or value.condition != null or value.order != null or value.limit != null or value.offset != null) return error.Unsupported;
                return self.execute(view.sql, parameters);
            };
            if (value.join) |join| return try self.selectJoin(value, table, join);
            if (value.group_by) |group_name| return try self.selectGrouped(table, value, group_name, parameters);
            if (value.projections.len == 1 and value.projections[0].expr == .function and std.ascii.eqlIgnoreCase(value.projections[0].expr.function.name, "count")) {
                var count: usize = 0;
                for (table.rows.items) |row| {
                    if (try self.matches(table, row.values, value.condition, parameters)) count += 1;
                }
                const aggregate_row = try self.allocator.alloc(Value, 1);
                aggregate_row[0] = .{ .integer = @intCast(count) };
                const aggregate_rows = try self.allocator.alloc([]Value, 1);
                aggregate_rows[0] = aggregate_row;
                try columns.append(self.allocator, value.projections[0].alias orelse "count(*)");
                return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = aggregate_rows };
            }
            if (value.projections.len == 1 and value.projections[0].expr == .function) {
                const function = value.projections[0].expr.function;
                const is_sum = std.ascii.eqlIgnoreCase(function.name, "sum");
                const is_avg = std.ascii.eqlIgnoreCase(function.name, "avg") or std.ascii.eqlIgnoreCase(function.name, "average");
                const is_min = std.ascii.eqlIgnoreCase(function.name, "min");
                const is_max = std.ascii.eqlIgnoreCase(function.name, "max");
                if (is_sum or is_avg or is_min or is_max) {
                    var total: f64 = 0;
                    var integer_total: i64 = 0;
                    var numeric_count: usize = 0;
                    var real_seen = false;
                    var extremum: f64 = 0;
                    for (table.rows.items) |row| {
                        if (!try self.matches(table, row.values, value.condition, parameters)) continue;
                        const item = try self.eval(table, row.values, function.argument.*, parameters);
                        switch (item) {
                            .integer => |number| {
                                const numeric = @as(f64, @floatFromInt(number));
                                total += numeric;
                                integer_total += number;
                                if (numeric_count == 0 or (is_min and numeric < extremum) or (is_max and numeric > extremum)) extremum = numeric;
                                numeric_count += 1;
                            },
                            .real => |number| {
                                real_seen = true;
                                total += number;
                                if (numeric_count == 0 or (is_min and number < extremum) or (is_max and number > extremum)) extremum = number;
                                numeric_count += 1;
                            },
                            else => {},
                        }
                    }
                    const aggregate_value: Value = if (numeric_count == 0) .null else if (is_avg) .{ .real = total / @as(f64, @floatFromInt(numeric_count)) } else if (is_min or is_max) if (real_seen) .{ .real = extremum } else .{ .integer = @intFromFloat(extremum) } else if (real_seen) .{ .real = total } else .{ .integer = integer_total };
                    const aggregate_row = try self.allocator.alloc(Value, 1);
                    aggregate_row[0] = aggregate_value;
                    const aggregate_rows = try self.allocator.alloc([]Value, 1);
                    aggregate_rows[0] = aggregate_row;
                    try columns.append(self.allocator, value.projections[0].alias orelse function.name);
                    return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = aggregate_rows };
                }
            }
            for (value.projections) |projection| {
                switch (projection.expr) {
                    .wildcard => for (table.columns) |column| try columns.append(self.allocator, column.name),
                    .identifier => try columns.append(self.allocator, projection.alias orelse projection.expr.identifier),
                    .function => try columns.append(self.allocator, projection.alias orelse projection.expr.function.name),
                    else => {},
                }
            }
            if (columns.items.len == 0) for (value.projections) |projection| try columns.append(self.allocator, projection.alias orelse "?column?");
            var rows = std.ArrayList([]Value).empty;
            errdefer {
                for (rows.items) |row| self.allocator.free(row);
                rows.deinit(self.allocator);
            }
            const ordered_indices = try self.plannedIndices(table, value.condition, parameters);
            defer self.allocator.free(ordered_indices);
            if (value.order) |order| {
                const order_index = try columnIndex(table, order.column);
                var i: usize = 0;
                while (i < ordered_indices.len) : (i += 1) {
                    var j = i + 1;
                    while (j < ordered_indices.len) : (j += 1) {
                        const left = table.rows.items[ordered_indices[i]].values[order_index];
                        const right = table.rows.items[ordered_indices[j]].values[order_index];
                        const swap = if (order.descending) compare(left, .less, right) else compare(left, .greater, right);
                        if (swap) std.mem.swap(usize, &ordered_indices[i], &ordered_indices[j]);
                    }
                }
            }
            var scanned: usize = 0;
            var count: usize = 0;
            for (ordered_indices) |row_index| {
                const row = table.rows.items[row_index];
                if (!try self.matches(table, row.values, value.condition, parameters)) continue;
                if (value.offset) |offset| if (scanned < offset) {
                    scanned += 1;
                    continue;
                };
                scanned += 1;
                const result_row = try self.allocator.alloc(Value, value.projections.len + if (value.projections.len == 1 and value.projections[0].expr == .wildcard) table.columns.len - 1 else 0);
                var out_index: usize = 0;
                for (value.projections) |projection| if (projection.expr == .wildcard) {
                    for (row.values) |item| {
                        result_row[out_index] = try self.copyValue(item);
                        out_index += 1;
                    }
                } else {
                    result_row[out_index] = try self.materialize(table, row.values, projection.expr, parameters);
                    out_index += 1;
                };
                if (value.distinct) {
                    var duplicate = false;
                    for (rows.items) |existing| if (rowsEqual(existing, result_row)) {
                        duplicate = true;
                        break;
                    };
                    if (duplicate) {
                        for (result_row) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                        self.allocator.free(result_row);
                        continue;
                    }
                }
                try rows.append(self.allocator, result_row);
                count += 1;
                if (value.limit) |limit| if (count >= limit) break;
            }
            return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
        }
        const result_row = try self.allocator.alloc(Value, value.projections.len);
        for (value.projections, 0..) |projection, index| result_row[index] = try self.resolve(projection.expr, parameters);
        var rows = try self.allocator.alloc([]Value, 1);
        rows[0] = result_row;
        for (value.projections) |projection| _ = try columns.append(self.allocator, projection.alias orelse "?column?");
        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = rows };
    }

    fn plannedIndices(self: *Connection, table: *const Table, condition: ?ast.Conditions, parameters: []const Value) ![]usize {
        var indexed_column: ?usize = null;
        var lookup: Value = .null;
        if (condition) |conditions| if (conditions.len == 1 and conditions[0].op == .equal) {
            for (self.schema.indexes.items) |index| if (index.columns.len == 1 and std.ascii.eqlIgnoreCase(index.table, table.name) and std.ascii.eqlIgnoreCase(index.columns[0], conditions[0].column)) {
                indexed_column = try columnIndex(table, index.columns[0]);
                lookup = self.resolve(conditions[0].value, parameters) catch .null;
                break;
            };
        };
        var indices = std.ArrayList(usize).empty;
        defer indices.deinit(self.allocator);
        if (indexed_column) |column_index| {
            for (table.rows.items, 0..) |row, row_index| if (compare(row.values[column_index], .equal, lookup)) try indices.append(self.allocator, row_index);
        } else {
            try indices.ensureTotalCapacity(self.allocator, table.rows.items.len);
            for (table.rows.items, 0..) |_, row_index| try indices.append(self.allocator, row_index);
        }
        return indices.toOwnedSlice(self.allocator);
    }

    fn selectJoin(self: *Connection, value: anytype, left: *const Table, join: ast.Join) !Result {
        if (value.condition != null or value.order != null) return error.Unsupported;
        const right = self.schema.findConst(join.table) orelse return error.UnknownTable;
        var left_index: usize = 0;
        var right_index: usize = 0;
        if (join.kind != .cross) {
            const left_name = if (join.left_table.len == 0) left.name else join.left_table;
            const right_name = if (join.right_table.len == 0) right.name else join.right_table;
            if (std.ascii.eqlIgnoreCase(left_name, left.name)) left_index = try columnIndex(left, join.left_column) else left_index = try columnIndex(left, join.right_column);
            if (std.ascii.eqlIgnoreCase(right_name, right.name)) right_index = try columnIndex(right, join.right_column) else right_index = try columnIndex(right, join.left_column);
        }
        var columns = std.ArrayList([]const u8).empty;
        defer columns.deinit(self.allocator);
        for (value.projections) |projection| {
            if (projection.expr == .wildcard) {
                for (left.columns) |column| try columns.append(self.allocator, column.name);
                for (right.columns) |column| try columns.append(self.allocator, column.name);
            } else if (projection.expr == .identifier) {
                const name = projection.expr.identifier;
                const dot = std.mem.indexOfScalar(u8, name, '.');
                const column_name = if (dot) |position| name[position + 1 ..] else name;
                try columns.append(self.allocator, projection.alias orelse column_name);
            } else return error.Unsupported;
        }
        var rows = std.ArrayList([]Value).empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        const right_matched = try self.allocator.alloc(bool, right.rows.items.len);
        defer self.allocator.free(right_matched);
        @memset(right_matched, false);
        for (left.rows.items) |left_row| {
            var matched = false;
            for (right.rows.items, 0..) |right_row, right_row_index| {
                if (join.kind != .cross and !compare(left_row.values[left_index], .equal, right_row.values[right_index])) continue;
                matched = true;
                right_matched[right_row_index] = true;
                const before = rows.items.len;
                try self.appendJoinRow(&rows, value.projections, left, left_row.values, right, right_row.values);
                if (value.distinct and rows.items.len != before) {
                    const newest = rows.items[rows.items.len - 1];
                    var duplicate = false;
                    for (rows.items[0 .. rows.items.len - 1]) |existing| if (rowsEqual(existing, newest)) {
                        duplicate = true;
                        break;
                    };
                    if (duplicate) {
                        for (newest) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                        self.allocator.free(newest);
                        _ = rows.pop();
                    }
                }
            }
            if ((join.kind == .left or join.kind == .full) and !matched) {
                const nulls = try self.allocator.alloc(Value, right.columns.len);
                @memset(nulls, .null);
                defer self.allocator.free(nulls);
                try self.appendJoinRow(&rows, value.projections, left, left_row.values, right, nulls);
            }
        }
        if (join.kind == .right or join.kind == .full) {
            const nulls = try self.allocator.alloc(Value, left.columns.len);
            @memset(nulls, .null);
            defer self.allocator.free(nulls);
            for (right.rows.items, 0..) |right_row, right_row_index| if (!right_matched[right_row_index]) try self.appendJoinRow(&rows, value.projections, left, nulls, right, right_row.values);
        }
        if (value.distinct) {
            var index: usize = 0;
            while (index < rows.items.len) {
                var duplicate_index = index + 1;
                while (duplicate_index < rows.items.len) {
                    if (rowsEqual(rows.items[index], rows.items[duplicate_index])) {
                        const duplicate = rows.orderedRemove(duplicate_index);
                        for (duplicate) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                        self.allocator.free(duplicate);
                    } else duplicate_index += 1;
                }
                index += 1;
            }
        }
        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn appendJoinRow(self: *Connection, rows: *std.ArrayList([]Value), projections: []const ast.Projection, left: *const Table, left_values: []const Value, right: *const Table, right_values: []const Value) !void {
        var width: usize = 0;
        for (projections) |projection| width += if (projection.expr == .wildcard) left.columns.len + right.columns.len else 1;
        const output = try self.allocator.alloc(Value, width);
        var output_index: usize = 0;
        for (projections) |projection| {
            if (projection.expr == .wildcard) {
                for (left_values) |item| {
                    output[output_index] = try self.copyValue(item);
                    output_index += 1;
                }
                for (right_values) |item| {
                    output[output_index] = try self.copyValue(item);
                    output_index += 1;
                }
            } else {
                const name = projection.expr.identifier;
                const dot = std.mem.indexOfScalar(u8, name, '.');
                const table_name = if (dot) |position| name[0..position] else "";
                const column_name = if (dot) |position| name[position + 1 ..] else name;
                if (dot != null and std.ascii.eqlIgnoreCase(table_name, right.name)) {
                    output[output_index] = try self.copyValue(right_values[try columnIndex(right, column_name)]);
                } else if (columnIndex(left, column_name) catch null) |index| {
                    output[output_index] = try self.copyValue(left_values[index]);
                } else {
                    output[output_index] = try self.copyValue(right_values[try columnIndex(right, column_name)]);
                }
                output_index += 1;
            }
        }
        try rows.append(self.allocator, output);
    }

    fn updateFrom(self: *Connection, value: anytype, parameters: []const Value) anyerror!Result {
        const table = self.schema.find(value.table) orelse return error.UnknownTable;
        const source = self.schema.findConst(value.from.?.table) orelse return error.UnknownTable;
        const source_spec = value.from.?;
        const left_table = if (source_spec.left_table.len == 0) table else if (std.ascii.eqlIgnoreCase(source_spec.left_table, table.name)) table else source;
        const right_table = if (source_spec.right_table.len == 0) table else if (std.ascii.eqlIgnoreCase(source_spec.right_table, table.name)) table else source;
        const left_column = try columnIndex(left_table, source_spec.left_column);
        const right_column = try columnIndex(right_table, source_spec.right_column);
        var changes: usize = 0;
        for (table.rows.items, 0..) |*row, row_index| {
            for (source.rows.items) |source_row| {
                const left_value = if (left_table == table) row.values[left_column] else source_row.values[left_column];
                const right_value = if (right_table == table) row.values[right_column] else source_row.values[right_column];
                if (!compare(left_value, .equal, right_value)) continue;
                const candidate = try self.allocator.alloc(Value, row.values.len);
                defer self.allocator.free(candidate);
                @memcpy(candidate, row.values);
                for (value.columns, value.values) |name, expression| {
                    const index = try columnIndex(table, name);
                    const new_value = if (expression == .identifier and std.mem.indexOfScalar(u8, expression.identifier, '.') != null) blk: {
                        const dot = std.mem.indexOfScalar(u8, expression.identifier, '.').?;
                        const qualifier = expression.identifier[0..dot];
                        const column_name = expression.identifier[dot + 1 ..];
                        if (std.ascii.eqlIgnoreCase(qualifier, source.name)) break :blk source_row.values[try columnIndex(source, column_name)];
                        break :blk try self.resolve(expression, parameters);
                    } else try self.resolve(expression, parameters);
                    candidate[index] = new_value;
                }
                try self.schema.validateUpdate(table, row_index, candidate);
                try self.applyUpdateActions(table.name, row.values, candidate);
                const old_snapshot = try self.allocator.alloc(Value, row.values.len);
                defer {
                    for (old_snapshot) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                    self.allocator.free(old_snapshot);
                }
                for (row.values, 0..) |item, snapshot_index| old_snapshot[snapshot_index] = try self.copyValue(item);
                for (value.columns, 0..) |name, update_index| {
                    const target_index = try columnIndex(table, name);
                    const new_value = candidate[target_index];
                    if (row.values[target_index] == .text) self.allocator.free(row.values[target_index].text);
                    if (row.values[target_index] == .blob) self.allocator.free(row.values[target_index].blob);
                    row.values[target_index] = switch (new_value) {
                        .text => |text| .{ .text = try self.allocator.dupe(u8, text) },
                        .blob => |blob| .{ .blob = try self.allocator.dupe(u8, blob) },
                        else => new_value,
                    };
                    _ = update_index;
                }
                try self.fireTriggers(table.name, .update, candidate, old_snapshot);
                changes += 1;
                break;
            }
        }
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
    }

    fn update(self: *Connection, value: anytype, parameters: []const Value) !Result {
        if (value.from != null) return self.updateFrom(value, parameters);
        const table = self.schema.find(value.table) orelse return error.UnknownTable;
        var changes: usize = 0;
        for (table.rows.items, 0..) |*row, row_index| if (try self.matches(table, row.values, value.condition, parameters)) {
            const candidate = try self.allocator.alloc(Value, row.values.len);
            defer self.allocator.free(candidate);
            @memcpy(candidate, row.values);
            for (value.columns, value.values) |name, expr| {
                const index = try columnIndex(table, name);
                const new_value = try self.eval(table, row.values, expr, parameters);
                if (new_value == .null and table.columns[index].not_null) return error.ConstraintViolation;
                candidate[index] = new_value;
            }
            try self.schema.validateUpdate(table, row_index, candidate);
            try self.applyUpdateActions(table.name, row.values, candidate);
            const old_snapshot = try self.allocator.alloc(Value, row.values.len);
            defer {
                for (old_snapshot) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                self.allocator.free(old_snapshot);
            }
            for (row.values, 0..) |item, snapshot_index| old_snapshot[snapshot_index] = try self.copyValue(item);
            for (value.columns, value.values) |name, expr| {
                const index = try columnIndex(table, name);
                const new_value = try self.eval(table, row.values, expr, parameters);
                if (row.values[index] == .text) self.allocator.free(row.values[index].text);
                if (row.values[index] == .blob) self.allocator.free(row.values[index].blob);
                row.values[index] = switch (new_value) {
                    .text => |v| .{ .text = try self.allocator.dupe(u8, v) },
                    .blob => |v| .{ .blob = try self.allocator.dupe(u8, v) },
                    else => new_value,
                };
            }
            changes += 1;
            try self.fireTriggers(table.name, .update, candidate, old_snapshot);
        };
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
    }

    fn sameValue(left: Value, right: Value) bool {
        return switch (left) {
            .null => right == .null,
            .integer => |value| switch (right) {
                .integer => |other| value == other,
                else => false,
            },
            .real => |value| switch (right) {
                .real => |other| value == other,
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

    fn compositeMatches(self: *Connection, child: *const Table, child_values: []const Value, parent: *const Table, parent_values: []const Value, constraint: anytype) !bool {
        _ = self;
        for (constraint.columns, constraint.referenced_columns) |child_name, parent_name| {
            const child_index = try columnIndex(child, child_name);
            const parent_index = try columnIndex(parent, parent_name);
            if (!sameValue(child_values[child_index], parent_values[parent_index])) return false;
        }
        return true;
    }

    fn applyCompositeUpdateActions(self: *Connection, parent_name: []const u8, old_values: []const Value, new_values: []const Value) anyerror!void {
        const parent = self.schema.findConst(parent_name) orelse return error.ConstraintViolation;
        for (self.schema.tables.items) |*child_table| {
            var child_row_index: usize = 0;
            while (child_row_index < child_table.rows.items.len) : (child_row_index += 1) {
                var constraint_index: usize = 0;
                while (constraint_index < child_table.constraints.len) : (constraint_index += 1) {
                    const constraint = child_table.constraints[constraint_index];
                    if (constraint.kind != .foreign_key or !std.ascii.eqlIgnoreCase(constraint.foreign_table.?, parent_name)) continue;
                    var changed = false;
                    for (constraint.referenced_columns) |parent_column| {
                        const parent_index = try columnIndex(parent, parent_column);
                        if (!sameValue(old_values[parent_index], new_values[parent_index])) changed = true;
                    }
                    if (!changed or !try self.compositeMatches(child_table, child_table.rows.items[child_row_index].values, parent, old_values, constraint)) continue;
                    switch (constraint.on_update) {
                        .restrict => return error.ConstraintViolation,
                        .set_null => {
                            for (constraint.columns) |child_column| {
                                const child_index = try columnIndex(child_table, child_column);
                                if (child_table.columns[child_index].not_null) return error.ConstraintViolation;
                            }
                            for (constraint.columns) |child_column| {
                                const child_index = try columnIndex(child_table, child_column);
                                const old = child_table.rows.items[child_row_index].values[child_index];
                                if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                                child_table.rows.items[child_row_index].values[child_index] = .null;
                            }
                        },
                        .cascade => {
                            const row = &child_table.rows.items[child_row_index];
                            const candidate = try self.allocator.alloc(Value, row.values.len);
                            for (row.values, 0..) |item, index| candidate[index] = try self.copyValue(item);
                            for (constraint.columns, constraint.referenced_columns) |child_column, parent_column| {
                                const child_index = try columnIndex(child_table, child_column);
                                const parent_index = try columnIndex(parent, parent_column);
                                if (candidate[child_index] == .text) self.allocator.free(candidate[child_index].text) else if (candidate[child_index] == .blob) self.allocator.free(candidate[child_index].blob);
                                candidate[child_index] = try self.copyValue(new_values[parent_index]);
                            }
                            try self.applyUpdateActions(child_table.name, row.values, candidate);
                            for (row.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(row.values);
                            row.values = candidate;
                        },
                    }
                }
            }
        }
    }

    fn applyCompositeDeleteActions(self: *Connection, parent_name: []const u8, parent_values: []const Value) anyerror!void {
        const parent = self.schema.findConst(parent_name) orelse return error.ConstraintViolation;
        for (self.schema.tables.items) |*child_table| {
            var child_row_index = child_table.rows.items.len;
            while (child_row_index > 0) {
                child_row_index -= 1;
                for (child_table.constraints) |constraint| {
                    if (constraint.kind != .foreign_key or !std.ascii.eqlIgnoreCase(constraint.foreign_table.?, parent_name)) continue;
                    if (!try self.compositeMatches(child_table, child_table.rows.items[child_row_index].values, parent, parent_values, constraint)) continue;
                    switch (constraint.on_delete) {
                        .restrict => return error.ConstraintViolation,
                        .set_null => {
                            for (constraint.columns) |child_column| {
                                const child_index = try columnIndex(child_table, child_column);
                                if (child_table.columns[child_index].not_null) return error.ConstraintViolation;
                            }
                            for (constraint.columns) |child_column| {
                                const child_index = try columnIndex(child_table, child_column);
                                const old = child_table.rows.items[child_row_index].values[child_index];
                                if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                                child_table.rows.items[child_row_index].values[child_index] = .null;
                            }
                        },
                        .cascade => {
                            try self.applyDeleteActions(child_table.name, child_table.rows.items[child_row_index].values);
                            const removed = child_table.rows.orderedRemove(child_row_index);
                            for (removed.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(removed.values);
                        },
                    }
                }
            }
        }
    }

    fn applyUpdateActions(self: *Connection, parent_name: []const u8, old_values: []const Value, new_values: []const Value) anyerror!void {
        if (!self.schema.foreign_keys_enabled) return;
        try self.applyCompositeUpdateActions(parent_name, old_values, new_values);
        const parent = self.schema.findConst(parent_name) orelse return error.ConstraintViolation;
        var child_table_index: usize = 0;
        while (child_table_index < self.schema.tables.items.len) : (child_table_index += 1) {
            const child_table = &self.schema.tables.items[child_table_index];
            var child_column_index: usize = 0;
            while (child_column_index < child_table.columns.len) : (child_column_index += 1) {
                const child_column = child_table.columns[child_column_index];
                const foreign_table = child_column.foreign_table orelse continue;
                if (!std.ascii.eqlIgnoreCase(foreign_table, parent_name)) continue;
                const referenced = child_column.foreign_column orelse return error.ConstraintViolation;
                const parent_column_index = try columnIndex(parent, referenced);
                if (sameValue(old_values[parent_column_index], new_values[parent_column_index])) continue;

                var child_row_index: usize = 0;
                while (child_row_index < child_table.rows.items.len) : (child_row_index += 1) {
                    const child_row = &child_table.rows.items[child_row_index];
                    if (!sameValue(old_values[parent_column_index], child_row.values[child_column_index])) continue;
                    switch (child_column.on_update) {
                        .restrict => return error.ConstraintViolation,
                        .set_null => {
                            if (child_column.not_null) return error.ConstraintViolation;
                            const old = child_row.values[child_column_index];
                            if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                            child_row.values[child_column_index] = .null;
                        },
                        .cascade => {
                            const candidate = try self.allocator.alloc(Value, child_row.values.len);
                            errdefer self.allocator.free(candidate);
                            for (child_row.values, 0..) |item, index| candidate[index] = try self.copyValue(item);
                            const replacement = try self.copyValue(new_values[parent_column_index]);
                            if (candidate[child_column_index] == .text) self.allocator.free(candidate[child_column_index].text) else if (candidate[child_column_index] == .blob) self.allocator.free(candidate[child_column_index].blob);
                            candidate[child_column_index] = replacement;
                            try self.applyUpdateActions(child_table.name, child_row.values, candidate);
                            for (child_row.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(child_row.values);
                            child_row.values = candidate;
                        },
                    }
                }
            }
        }
    }

    fn applyDeleteActions(self: *Connection, parent_name: []const u8, parent_values: []const Value) anyerror!void {
        if (!self.schema.foreign_keys_enabled) return;
        try self.applyCompositeDeleteActions(parent_name, parent_values);
        var child_table_index: usize = 0;
        while (child_table_index < self.schema.tables.items.len) : (child_table_index += 1) {
            var child_row_index = self.schema.tables.items[child_table_index].rows.items.len;
            while (child_row_index > 0) {
                child_row_index -= 1;
                var action: ?ast.ReferentialAction = null;
                var child_column_index: usize = 0;
                var parent_column_index: usize = 0;
                const child_table = &self.schema.tables.items[child_table_index];
                for (child_table.columns, 0..) |column, column_index| if (column.foreign_table) |foreign_table| {
                    if (std.ascii.eqlIgnoreCase(foreign_table, parent_name)) {
                        const parent_table = self.schema.findConst(parent_name) orelse return error.ConstraintViolation;
                        const referenced = column.foreign_column orelse return error.ConstraintViolation;
                        for (parent_table.columns, 0..) |parent_column, index| if (std.ascii.eqlIgnoreCase(parent_column.name, referenced)) {
                            child_column_index = column_index;
                            parent_column_index = index;
                            action = column.on_delete;
                            break;
                        };
                        if (action != null) break;
                    }
                };
                if (action == null or !compare(parent_values[parent_column_index], .equal, child_table.rows.items[child_row_index].values[child_column_index])) continue;
                switch (action.?) {
                    .restrict => return error.ConstraintViolation,
                    .set_null => {
                        if (child_table.columns[child_column_index].not_null) return error.ConstraintViolation;
                        const old = child_table.rows.items[child_row_index].values[child_column_index];
                        if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                        child_table.rows.items[child_row_index].values[child_column_index] = .null;
                    },
                    .cascade => {
                        try self.applyDeleteActions(child_table.name, child_table.rows.items[child_row_index].values);
                        const removed = child_table.rows.orderedRemove(child_row_index);
                        for (removed.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                        self.allocator.free(removed.values);
                    },
                }
            }
        }
    }

    fn delete(self: *Connection, value: anytype, parameters: []const Value) !Result {
        const table = self.schema.find(value.table) orelse return error.UnknownTable;
        var changes: usize = 0;
        var index: usize = 0;
        while (index < table.rows.items.len) {
            if (try self.matches(table, table.rows.items[index].values, value.condition, parameters)) {
                try self.applyDeleteActions(table.name, table.rows.items[index].values);
                const row = table.rows.orderedRemove(index);
                try self.fireTriggers(table.name, .delete, null, row.values);
                for (row.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                self.allocator.free(row.values);
                changes += 1;
            } else index += 1;
        }
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
    }
};

test "connection executes native SQL" {
    const path = "sqlite_zig_connection_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE users (id INTEGER, name TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO users VALUES (1, 'A');");
    result.deinit();
    result = try db.exec("SELECT name FROM users WHERE id = 1;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
    try std.testing.expectEqualStrings("A", result.rows[0][0].text);
}

test "raw and typed indexes validate uniqueness and lifecycle" {
    const Item = @import("../dsl/table.zig").table("index_items", struct { id: i64, label: []const u8 });
    const path = "sqlite_zig_index_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(Item, .{});
    var first = try db.from(Item).insertTyped(.{ .id = 1, .label = "one" });
    first.deinit();
    var create = try db.exec("CREATE UNIQUE INDEX index_items_label ON index_items (label);");
    create.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Item).insertTyped(.{ .id = 2, .label = "one" }));
    var reopened = try Connection.open(std.testing.allocator, path);
    defer reopened.close();
    try std.testing.expect(reopened.schema.findIndexConst("index_items_label") != null);
    try std.testing.expectError(error.ConstraintViolation, reopened.from(Item).insertTyped(.{ .id = 3, .label = "one" }));
    try db.createIndex(Item, "index_items_id", &.{Item.key("id")}, false);
    try db.dropIndex("index_items_id");
    var drop = try db.exec("DROP INDEX index_items_label;");
    drop.deinit();
}

test "connection persists rows and prepared parameters" {
    const path = "sqlite_zig_reopen_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    var setup = try db.exec("CREATE TABLE items (id INTEGER, label TEXT);");
    setup.deinit();
    var statement = try db.prepare("INSERT INTO items VALUES (?, ?);");
    try statement.bind(1, 4);
    try statement.bind(2, "saved");
    try statement.step();
    statement.finalize();
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    var result = try db.exec("SELECT label FROM items WHERE id = 4;");
    defer result.deinit();
    defer db.close();
    try std.testing.expectEqualStrings("saved", result.rows[0][0].text);
}

test "connection supports AND predicates, scalar functions, and count" {
    const path = "sqlite_zig_expression_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE numbers (id INTEGER, label TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO numbers VALUES (1, 'one'), (2, 'two'), (3, 'three');");
    result.deinit();
    result = try db.exec("SELECT length(label), typeof(id) FROM numbers WHERE id > 1 AND id < 3;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
    try std.testing.expectEqual(@as(i64, 3), result.rows[0][0].integer);
    try std.testing.expectEqualStrings("integer", result.rows[0][1].text);
    var count = try db.exec("SELECT count(*) FROM numbers;");
    defer count.deinit();
    try std.testing.expectEqual(@as(i64, 3), count.rows[0][0].integer);
}

test "connection executes order by, lower, and savepoints" {
    const path = "sqlite_zig_query_features_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE items (id INTEGER, label TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO items VALUES (2, 'Beta'), (1, 'Alpha');");
    result.deinit();
    result = try db.exec("SELECT lower(label) AS normalized FROM items ORDER BY id DESC;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.rowCount());
    try std.testing.expectEqualStrings("beta", result.rows[0][0].text);
    try std.testing.expectEqualStrings("alpha", result.rows[1][0].text);
    var paged = try db.exec("SELECT id FROM items ORDER BY id ASC LIMIT 1 OFFSET 1;");
    defer paged.deinit();
    try std.testing.expectEqual(@as(i64, 2), paged.rows[0][0].integer);
    var tx = try db.exec("BEGIN;");
    tx.deinit();
    tx = try db.exec("INSERT INTO items VALUES (3, 'Gamma');");
    tx.deinit();
    tx = try db.exec("SAVEPOINT before_extra;");
    tx.deinit();
    tx = try db.exec("INSERT INTO items VALUES (4, 'Delta');");
    tx.deinit();
    tx = try db.exec("ROLLBACK TO before_extra;");
    tx.deinit();
    tx = try db.exec("RELEASE before_extra;");
    tx.deinit();
    tx = try db.exec("COMMIT;");
    tx.deinit();
    var count = try db.exec("SELECT count(*) FROM items;");
    defer count.deinit();
    try std.testing.expectEqual(@as(i64, 3), count.rows[0][0].integer);
}

test "typed DSL owns table lifecycle operations" {
    const User = @import("../dsl/table.zig").table("schema_dsl_users", struct { id: i64, name: []const u8 });
    const path = "sqlite_zig_schema_dsl_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(User, .{});
    try std.testing.expect(db.tableExists(User));
    try db.createTable(User, .{ .if_not_exists = true });
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "typed" });
    inserted.deinit();
    try db.addColumn(User, "active", bool);
    try db.renameColumn(User, "active", "enabled");
    try db.dropColumn(User, "enabled");
    try db.truncate(User);
    try db.dropTable(User);
    try std.testing.expect(!db.tableExists(User));
}

test "typed keys and foreign keys enforce relational constraints" {
    const Parent = @import("../dsl/table.zig").table("key_dsl_parent", struct { id: i64, email: []const u8 });
    const Child = @import("../dsl/table.zig").table("key_dsl_child", struct { id: i64, parent_id: i64 });
    const path = "sqlite_zig_keys_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(Parent, .{ .primary_key = Parent.key("id"), .unique_keys = &.{Parent.key("email")} });
    try db.createTable(Child, .{ .primary_key = Child.key("id"), .foreign_keys = &.{.{ .table = "key_dsl_parent", .referenced_column = "id", .column_key = Child.key("parent_id") }} });
    var parent = try db.from(Parent).insert(.{ .id = 1, .email = "one@example.test" });
    parent.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Parent).insert(.{ .id = 1, .email = "two@example.test" }));
    try std.testing.expectError(error.ConstraintViolation, db.from(Child).insert(.{ .id = 1, .parent_id = 99 }));
    var child = try db.from(Child).insert(.{ .id = 1, .parent_id = 1 });
    child.deinit();
    var nullable = try db.exec("INSERT INTO key_dsl_parent (id, email) VALUES (2, NULL), (3, NULL);");
    nullable.deinit();
    var child_update = try db.from(Child).update(.{ .parent_id = 99 });
    defer child_update.deinit();
    try std.testing.expectError(error.ConstraintViolation, child_update.where(Child.column("id").eq(1)).execute());
}

test "raw SQL and typed DSL execute inner and left joins" {
    const User = @import("../dsl/table.zig").table("join_dsl_users", struct { id: i64, name: []const u8 });
    const Order = @import("../dsl/table.zig").table("join_dsl_orders", struct { id: i64, user_id: i64 });
    const path = "sqlite_zig_join_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(User, .{ .primary_key_name = "id" });
    try db.createTable(Order, .{ .primary_key_name = "id" });
    var user = try db.from(User).insert(.{ .id = 1, .name = "A" });
    user.deinit();
    var order = try db.from(Order).insert(.{ .id = 10, .user_id = 1 });
    order.deinit();
    var second_user = try db.from(User).insert(.{ .id = 2, .name = "B" });
    second_user.deinit();
    var orphan_order = try db.from(Order).insert(.{ .id = 11, .user_id = 99 });
    orphan_order.deinit();
    var raw = try db.exec("SELECT * FROM join_dsl_users JOIN join_dsl_orders ON join_dsl_users.id = join_dsl_orders.user_id;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 1), raw.rowCount());
    try std.testing.expectEqual(@as(i64, 10), raw.rows[0][2].integer);
    var raw_distinct = try db.exec("SELECT DISTINCT * FROM join_dsl_users JOIN join_dsl_orders ON join_dsl_users.id = join_dsl_orders.user_id;");
    defer raw_distinct.deinit();
    var dsl_distinct = try db.from(User).innerJoinKeys(Order, User.key("id"), Order.key("user_id")).selectAll().distinct().fetchAll();
    defer dsl_distinct.deinit();
    try std.testing.expectEqual(raw_distinct.rowCount(), dsl_distinct.rowCount());
    var typed_sum = try db.from(User).sumColumn(User.key("id")).fetchAll();
    defer typed_sum.deinit();
    try std.testing.expectEqual(@as(i64, 3), typed_sum.rows[0][0].integer);
    var typed_projection = try db.from(User).selectColumns(&.{ User.key("id"), User.key("name") }).fetchAll();
    defer typed_projection.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed_projection.rowCount());
    var left = try db.from(User).leftJoin(Order, "id", "user_id").fetchAll();
    defer left.deinit();
    try std.testing.expectEqual(@as(usize, 2), left.rowCount());
    var right = try db.from(User).rightJoin(Order, "id", "user_id").fetchAll();
    defer right.deinit();
    try std.testing.expectEqual(@as(usize, 2), right.rowCount());
    var full = try db.from(User).fullJoin(Order, "id", "user_id").fetchAll();
    defer full.deinit();
    try std.testing.expectEqual(@as(usize, 3), full.rowCount());
    var cross = try db.from(User).crossJoin(Order).fetchAll();
    defer cross.deinit();
    try std.testing.expectEqual(@as(usize, 4), cross.rowCount());
}

test "raw SQL and DSL support null like and between predicates" {
    const Item = @import("../dsl/table.zig").table("predicate_dsl_items", struct { id: i64, label: []const u8 });
    const path = "sqlite_zig_predicate_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(Item, .{});
    var result = try db.exec("INSERT INTO predicate_dsl_items VALUES (1, 'alpha'), (2, 'beta'), (3, NULL);");
    result.deinit();
    result = try db.exec("INSERT INTO predicate_dsl_items VALUES (4, 'alpha');");
    result.deinit();
    result = try db.exec("SELECT id FROM predicate_dsl_items WHERE id BETWEEN 1 AND 2 OR id = 4;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.rowCount());
    var like_result = try db.from(Item).where(Item.column("label").like("a%")).fetchAll();
    defer like_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), like_result.rowCount());
    var raw_not_like = try db.exec("SELECT id FROM predicate_dsl_items WHERE label NOT LIKE 'a%' ORDER BY id;");
    defer raw_not_like.deinit();
    try std.testing.expectEqual(@as(usize, 1), raw_not_like.rowCount());
    try std.testing.expectEqual(@as(i64, 2), raw_not_like.rows[0][0].integer);
    var not_like_result = try db.from(Item).where(Item.column("label").notLike("a%")).fetchAll();
    defer not_like_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), not_like_result.rowCount());
    var null_result = try db.from(Item).where(Item.column("label").isNull()).fetchAll();
    defer null_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), null_result.rowCount());
    var distinct_result = try db.from(Item).selectFieldNames(&.{"label"}).distinct().fetchAll();
    defer distinct_result.deinit();
    try std.testing.expectEqual(@as(usize, 3), distinct_result.rowCount());
    var raw_in_list = try db.exec("SELECT id FROM predicate_dsl_items WHERE id IN (1, 3, 4) ORDER BY id;");
    defer raw_in_list.deinit();
    try std.testing.expectEqual(@as(usize, 3), raw_in_list.rowCount());
    var typed_in_list = try db.from(Item).whereInValues(Item.key("id"), .{ 1, 3, 4 }).fetchAll();
    defer typed_in_list.deinit();
    try std.testing.expectEqual(@as(usize, 3), typed_in_list.rowCount());
    var raw_not_in_list = try db.exec("SELECT id FROM predicate_dsl_items WHERE id NOT IN (1, 3, 4) ORDER BY id;");
    defer raw_not_in_list.deinit();
    try std.testing.expectEqual(@as(usize, 1), raw_not_in_list.rowCount());
    var typed_not_in_list = try db.from(Item).whereNotInValues(Item.key("id"), .{ 1, 3, 4 }).fetchAll();
    defer typed_not_in_list.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed_not_in_list.rowCount());
    var raw_is = try db.exec("SELECT id FROM predicate_dsl_items WHERE label IS 'alpha' ORDER BY id;");
    defer raw_is.deinit();
    try std.testing.expectEqual(@as(usize, 2), raw_is.rowCount());
    var raw_is_not_null = try db.exec("SELECT id FROM predicate_dsl_items WHERE label IS NOT NULL ORDER BY id;");
    defer raw_is_not_null.deinit();
    try std.testing.expectEqual(@as(usize, 3), raw_is_not_null.rowCount());
    var typed_is = try db.from(Item).where(Item.column("label").isValue("alpha")).fetchAll();
    defer typed_is.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed_is.rowCount());
}

test "transaction SQL modes and invalid SQL return deterministic errors" {
    const path = "sqlite_zig_transaction_modes_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE tx_modes (id INTEGER);");
    result.deinit();
    result = try db.exec("BEGIN IMMEDIATE;");
    result.deinit();
    result = try db.exec("INSERT INTO tx_modes VALUES (1);");
    result.deinit();
    result = try db.exec("ROLLBACK;");
    result.deinit();
    result = try db.exec("START TRANSACTION;");
    result.deinit();
    result = try db.exec("INSERT INTO tx_modes VALUES (2);");
    result.deinit();
    result = try db.exec("COMMIT;");
    result.deinit();
    try std.testing.expectError(error.UnexpectedToken, db.exec("SELECT FROM tx_modes;"));
    var rows = try db.exec("SELECT id FROM tx_modes;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqual(@as(i64, 2), rows.rows[0][0].integer);
}

test "multiple dependent CTEs preserve projected column names" {
    const path = "sqlite_zig_multiple_cte_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE cte_test_items (id INTEGER, label TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO cte_test_items VALUES (1, 'one'), (2, 'two');");
    result.deinit();
    var rows = try db.exec("WITH first_set AS (SELECT id, label FROM cte_test_items WHERE id = 2), second_set AS (SELECT id, label FROM first_set) SELECT id, label FROM second_set;");
    defer rows.deinit();
    try std.testing.expectEqualStrings("id", rows.columns[0]);
    try std.testing.expectEqualStrings("label", rows.columns[1]);
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqual(@as(i64, 2), rows.rows[0][0].integer);
}

test "native WAL journal mode survives reopen and checkpoint" {
    const path = "sqlite_zig_wal_test.db";
    const wal_path = "sqlite_zig_wal_test.db-wal";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, wal_path) catch {};

    var db = try Connection.open(std.testing.allocator, path);
    var mode = try db.exec("PRAGMA journal_mode=WAL;");
    mode.deinit();
    var result = try db.exec("CREATE TABLE wal_items (id INTEGER, value TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO wal_items VALUES (1, 'wal');");
    result.deinit();
    db.close();

    var reopened = try Connection.open(std.testing.allocator, path);
    var rows = try reopened.exec("SELECT id, value FROM wal_items;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqual(@as(i64, 1), rows.rows[0][0].integer);
    try std.testing.expectEqualStrings("wal", rows.rows[0][1].text);
    var checkpoint = try reopened.exec("PRAGMA journal_mode=DELETE;");
    checkpoint.deinit();
    reopened.close();
}

test "triggers substitute OLD and NEW row references" {
    const path = "sqlite_zig_trigger_refs_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE trigger_ref_items (id INTEGER, label TEXT);");
    result.deinit();
    result = try db.exec("CREATE TABLE trigger_ref_audit (kind TEXT, before_label TEXT, after_label TEXT);");
    result.deinit();
    result = try db.exec("CREATE TRIGGER trigger_ref_update AFTER UPDATE ON trigger_ref_items BEGIN INSERT INTO trigger_ref_audit VALUES ('update', OLD.label, NEW.label); END;");
    result.deinit();
    result = try db.exec("CREATE TRIGGER trigger_ref_delete AFTER DELETE ON trigger_ref_items BEGIN INSERT INTO trigger_ref_audit VALUES ('delete', OLD.label, NULL); END;");
    result.deinit();
    result = try db.exec("INSERT INTO trigger_ref_items VALUES (1, 'before');");
    result.deinit();
    result = try db.exec("UPDATE trigger_ref_items SET label = 'after' WHERE id = 1;");
    result.deinit();
    result = try db.exec("DELETE FROM trigger_ref_items WHERE id = 1;");
    result.deinit();
    var audit = try db.exec("SELECT kind, before_label, after_label FROM trigger_ref_audit ORDER BY kind;");
    defer audit.deinit();
    try std.testing.expectEqual(@as(usize, 2), audit.rowCount());
    try std.testing.expectEqualStrings("delete", audit.rows[0][0].text);
    try std.testing.expectEqualStrings("after", audit.rows[0][1].text);
    try std.testing.expectEqualStrings("update", audit.rows[1][0].text);
    try std.testing.expectEqualStrings("before", audit.rows[1][1].text);
    try std.testing.expectEqualStrings("after", audit.rows[1][2].text);
}

test "exec accepts multiple raw SQL statements and preserves trigger bodies" {
    const path = "sqlite_zig_multi_exec_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE multi_items (id INTEGER, label TEXT); CREATE TABLE multi_audit (label TEXT); CREATE TRIGGER multi_insert AFTER INSERT ON multi_items BEGIN INSERT INTO multi_audit VALUES (NEW.label); END; INSERT INTO multi_items VALUES (1, 'combined'); SELECT label FROM multi_audit;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rowCount());
    try std.testing.expectEqualStrings("combined", result.rows[0][0].text);
}

test "insert default values materializes a NULL row" {
    const path = "sqlite_zig_default_values_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE default_value_items (id INTEGER, label TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO default_value_items DEFAULT VALUES;");
    result.deinit();
    var rows = try db.exec("SELECT id, label FROM default_value_items;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expect(rows.rows[0][0] == .null);
    try std.testing.expect(rows.rows[0][1] == .null);
}

test "pragma user_version persists in the SQLite header" {
    const path = "sqlite_zig_user_version_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    var result = try db.exec("PRAGMA user_version = 42;");
    result.deinit();
    result = try db.exec("PRAGMA user_version;");
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 42), result.rows[0][0].integer);
    db.close();
    var reopened = try Connection.open(std.testing.allocator, path);
    defer reopened.close();
    var persisted = try reopened.exec("PRAGMA user_version;");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(i64, 42), persisted.rows[0][0].integer);
}

test "pragma application_id persists in the SQLite header" {
    const path = "sqlite_zig_application_id_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    var result = try db.exec("PRAGMA application_id = 305419896;");
    result.deinit();
    db.close();
    var reopened = try Connection.open(std.testing.allocator, path);
    defer reopened.close();
    var persisted = try reopened.exec("PRAGMA application_id;");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(i64, 305419896), persisted.rows[0][0].integer);
}

test "pragma foreign_keys toggles relational enforcement and actions" {
    const path = "sqlite_zig_foreign_keys_pragma_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE pragma_fk_parent (id INTEGER PRIMARY KEY); ");
    result.deinit();
    result = try db.exec("CREATE TABLE pragma_fk_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES pragma_fk_parent(id) ON DELETE CASCADE);");
    result.deinit();
    result = try db.exec("PRAGMA foreign_keys = OFF;");
    result.deinit();
    result = try db.exec("INSERT INTO pragma_fk_child VALUES (1, 99);");
    result.deinit();
    result = try db.exec("PRAGMA foreign_keys = ON;");
    result.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO pragma_fk_child VALUES (2, 99);"));
}

test "raw SQL grouped aggregates return one row per group" {
    const path = "sqlite_zig_grouped_aggregate_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE grouped_sales (category TEXT, amount INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO grouped_sales VALUES ('a', 10), ('a', 20), ('b', 7);");
    result.deinit();
    var grouped = try db.exec("SELECT category, COUNT(*), SUM(amount), AVG(amount) FROM grouped_sales GROUP BY category;");
    defer grouped.deinit();
    try std.testing.expectEqual(@as(usize, 2), grouped.rowCount());
    try std.testing.expectEqualStrings("category", grouped.columns[0]);
    try std.testing.expectEqual(@as(i64, 2), grouped.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 30), grouped.rows[0][2].integer);
    try std.testing.expectEqual(@as(f64, 15), grouped.rows[0][3].real);
    try std.testing.expectEqual(@as(i64, 1), grouped.rows[1][1].integer);
    const Sale = @import("../dsl/table.zig").table("grouped_sales", struct { category: []const u8, amount: i64 });
    var typed = try db.from(Sale).sumColumn(Sale.key("amount")).groupByColumn(Sale.key("category")).fetchAll();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.rowCount());
    try std.testing.expectEqual(@as(i64, 30), typed.rows[0][0].integer);
}

test "grouped aggregates support HAVING predicates" {
    const path = "sqlite_zig_having_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE having_sales (category TEXT, amount INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO having_sales VALUES ('a', 10), ('a', 20), ('b', 7);");
    result.deinit();
    var rows = try db.exec("SELECT category, SUM(amount) FROM having_sales GROUP BY category HAVING COUNT(*) > 1;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings("a", rows.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 30), rows.rows[0][1].integer);
    const Sale = @import("../dsl/table.zig").table("having_sales", struct { category: []const u8, amount: i64 });
    var typed = try db.from(Sale).sumColumn(Sale.key("amount")).groupByColumn(Sale.key("category")).havingCount(">", 1).fetchAll();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.rowCount());
    try std.testing.expectEqual(@as(i64, 30), typed.rows[0][0].integer);
}

test "insert select copies query results into a destination table" {
    const path = "sqlite_zig_insert_select_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE insert_select_source (id INTEGER, label TEXT); ");
    result.deinit();
    result = try db.exec("CREATE TABLE insert_select_destination (id INTEGER, label TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO insert_select_source VALUES (1, 'one'), (2, 'two');");
    result.deinit();
    result = try db.exec("INSERT INTO insert_select_destination SELECT id, label FROM insert_select_source WHERE id > 1;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.changes);
    var rows = try db.exec("SELECT id, label FROM insert_select_destination;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqual(@as(i64, 2), rows.rows[0][0].integer);
    try std.testing.expectEqualStrings("two", rows.rows[0][1].text);
}

test "insert or ignore skips constraint conflicts" {
    const path = "sqlite_zig_insert_ignore_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE ignore_items (id INTEGER PRIMARY KEY, label TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO ignore_items VALUES (1, 'original');");
    result.deinit();
    result = try db.exec("INSERT OR IGNORE INTO ignore_items VALUES (1, 'duplicate'), (2, 'accepted');");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.changes);
    var rows = try db.exec("SELECT id, label FROM ignore_items ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.rowCount());
    try std.testing.expectEqualStrings("original", rows.rows[0][1].text);
    try std.testing.expectEqualStrings("accepted", rows.rows[1][1].text);
    const Item = @import("../dsl/table.zig").table("ignore_items", struct { id: i64, label: []const u8 });
    var typed = try db.from(Item).insertIgnore(.{ .id = 1, .label = "typed duplicate" });
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 0), typed.changes);
}

test "upsert do nothing shares conflict-ignore semantics" {
    const path = "sqlite_zig_upsert_nothing_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE upsert_items (id INTEGER PRIMARY KEY, label TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO upsert_items VALUES (1, 'original');");
    result.deinit();
    result = try db.exec("INSERT INTO upsert_items VALUES (1, 'duplicate'), (2, 'accepted') ON CONFLICT(id) DO NOTHING;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.changes);
    var rows = try db.exec("SELECT id, label FROM upsert_items ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.rowCount());
    try std.testing.expectEqualStrings("original", rows.rows[0][1].text);
}

test "upsert do update changes the conflicting row" {
    const path = "sqlite_zig_upsert_update_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE upsert_update_items (id INTEGER PRIMARY KEY, label TEXT, amount INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO upsert_update_items VALUES (1, 'original', 10);");
    result.deinit();
    result = try db.exec("INSERT INTO upsert_update_items VALUES (1, 'updated', 99) ON CONFLICT(id) DO UPDATE SET label = excluded.label, amount = excluded.amount + 1;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.changes);
    var rows = try db.exec("SELECT label, amount FROM upsert_update_items;");
    defer rows.deinit();
    try std.testing.expectEqualStrings("updated", rows.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 100), rows.rows[0][1].integer);
}

test "upsert do update where can skip a conflict without changing it" {
    const path = "sqlite_zig_upsert_where_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE upsert_where_items (id INTEGER PRIMARY KEY, label TEXT, enabled INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO upsert_where_items VALUES (1, 'original', 0);");
    result.deinit();
    result = try db.exec("INSERT INTO upsert_where_items VALUES (1, 'updated', 1) ON CONFLICT(id) DO UPDATE SET label = excluded.label WHERE enabled = 1;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.changes);
    var rows = try db.exec("SELECT label FROM upsert_where_items;");
    defer rows.deinit();
    try std.testing.expectEqualStrings("original", rows.rows[0][0].text);
}

test "insert or replace removes the conflicting row and inserts the replacement" {
    const path = "sqlite_zig_insert_replace_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE replace_items (id INTEGER PRIMARY KEY, label TEXT);");
    result.deinit();
    result = try db.exec("INSERT INTO replace_items VALUES (1, 'original');");
    result.deinit();
    result = try db.exec("INSERT OR REPLACE INTO replace_items VALUES (1, 'replacement');");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.changes);
    var rows = try db.exec("SELECT label FROM replace_items;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings("replacement", rows.rows[0][0].text);
}

test "conflict replacement detects table-level and declared unique indexes" {
    const path = "sqlite_zig_replace_unique_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE replace_unique_items (id INTEGER, email TEXT, UNIQUE(email));");
    result.deinit();
    result = try db.exec("INSERT INTO replace_unique_items VALUES (1, 'same@example.test');");
    result.deinit();
    result = try db.exec("INSERT OR REPLACE INTO replace_unique_items VALUES (2, 'same@example.test');");
    result.deinit();
    var rows = try db.exec("SELECT id FROM replace_unique_items;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqual(@as(i64, 2), rows.rows[0][0].integer);
}

test "update from applies source-column assignments through an equi-join" {
    const path = "sqlite_zig_update_from_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE update_from_balances (id INTEGER PRIMARY KEY, amount INTEGER); ");
    result.deinit();
    result = try db.exec("CREATE TABLE update_from_adjustments (id INTEGER, amount INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO update_from_balances VALUES (1, 10), (2, 20);");
    result.deinit();
    result = try db.exec("INSERT INTO update_from_adjustments VALUES (1, 99);");
    result.deinit();
    result = try db.exec("UPDATE update_from_balances SET amount = update_from_adjustments.amount FROM update_from_adjustments WHERE update_from_balances.id = update_from_adjustments.id;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.changes);
    var rows = try db.exec("SELECT id, amount FROM update_from_balances ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 99), rows.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 20), rows.rows[1][1].integer);
}

test "NOT IN subqueries work in raw SQL and typed DSL" {
    const path = "sqlite_zig_not_in_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    const User = @import("../dsl/table.zig").table("not_in_users", struct { id: i64 });
    const Blocked = @import("../dsl/table.zig").table("not_in_blocked", struct { user_id: i64 });
    try db.createTable(User, .{});
    try db.createTable(Blocked, .{});
    var result = try db.exec("INSERT INTO not_in_users VALUES (1), (2), (3);");
    result.deinit();
    result = try db.exec("INSERT INTO not_in_blocked VALUES (2);");
    result.deinit();
    var raw = try db.exec("SELECT id FROM not_in_users WHERE id NOT IN (SELECT user_id FROM not_in_blocked) ORDER BY id;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 2), raw.rowCount());
    var typed = try db.from(User).whereNotInColumn(User.key("id"), Blocked, Blocked.key("user_id")).fetchAll();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.rowCount());
    try std.testing.expectEqual(@as(i64, 1), typed.rows[0][0].integer);
}

test "EXISTS and NOT EXISTS subqueries work in raw SQL" {
    const path = "sqlite_zig_exists_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE exists_users (id INTEGER); CREATE TABLE exists_marker (id INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO exists_users VALUES (1), (2); INSERT INTO exists_marker VALUES (1);");
    result.deinit();
    var present = try db.exec("SELECT id FROM exists_users WHERE EXISTS (SELECT id FROM exists_marker) ORDER BY id;");
    defer present.deinit();
    try std.testing.expectEqual(@as(usize, 2), present.rowCount());
    var correlated = try db.exec("SELECT id FROM exists_users WHERE EXISTS (SELECT id FROM exists_marker WHERE exists_marker.id = exists_users.id) ORDER BY id;");
    defer correlated.deinit();
    try std.testing.expectEqual(@as(usize, 1), correlated.rowCount());
    try std.testing.expectEqual(@as(i64, 1), correlated.rows[0][0].integer);
    const User = @import("../dsl/table.zig").table("exists_users", struct { id: i64 });
    const Marker = @import("../dsl/table.zig").table("exists_marker", struct { id: i64 });
    var typed = try db.from(User).whereExistsKey(Marker, Marker.key("id"), User.key("id")).fetchAll();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.rowCount());
    result = try db.exec("DELETE FROM exists_marker;");
    result.deinit();
    var absent = try db.exec("SELECT id FROM exists_users WHERE NOT EXISTS (SELECT id FROM exists_marker) ORDER BY id;");
    defer absent.deinit();
    try std.testing.expectEqual(@as(usize, 2), absent.rowCount());
}

test "DROP IF EXISTS is accepted for schema objects" {
    const path = "sqlite_zig_drop_if_exists_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("DROP TABLE IF EXISTS missing_drop_table; DROP INDEX IF EXISTS missing_drop_index; DROP VIEW IF EXISTS missing_drop_view; DROP TRIGGER IF EXISTS missing_drop_trigger;");
    defer result.deinit();
    var created = try db.exec("CREATE TABLE drop_items (id INTEGER); CREATE INDEX drop_items_idx ON drop_items (id); CREATE VIEW drop_items_view AS SELECT id FROM drop_items;");
    created.deinit();
    var dropped = try db.exec("DROP VIEW IF EXISTS drop_items_view; DROP INDEX IF EXISTS drop_items_idx; DROP TABLE IF EXISTS drop_items;");
    dropped.deinit();
    var repeated = try db.exec("DROP TABLE IF EXISTS drop_items;");
    repeated.deinit();
}

test "CREATE IF NOT EXISTS is accepted for indexes views and triggers" {
    const path = "sqlite_zig_create_if_not_exists_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE create_if_items (id INTEGER, label TEXT); CREATE TABLE create_if_audit (id INTEGER); CREATE INDEX IF NOT EXISTS create_if_idx ON create_if_items (id); CREATE INDEX IF NOT EXISTS create_if_idx ON create_if_items (id); CREATE VIEW IF NOT EXISTS create_if_view AS SELECT id FROM create_if_items; CREATE VIEW IF NOT EXISTS create_if_view AS SELECT id FROM create_if_items; CREATE TRIGGER IF NOT EXISTS create_if_trigger AFTER INSERT ON create_if_items BEGIN INSERT INTO create_if_audit (id) VALUES (NEW.id); END; CREATE TRIGGER IF NOT EXISTS create_if_trigger AFTER INSERT ON create_if_items BEGIN INSERT INTO create_if_audit (id) VALUES (NEW.id); END;");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.changes);
    var inserted = try db.exec("INSERT INTO create_if_items VALUES (1, 'x');");
    inserted.deinit();
    var rows = try db.exec("SELECT id FROM create_if_audit ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}

test "raw ALTER TABLE supports add rename and drop column" {
    const path = "sqlite_zig_raw_alter_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE raw_alter_items (id INTEGER, label TEXT); INSERT INTO raw_alter_items VALUES (1, 'one'); ALTER TABLE raw_alter_items ADD COLUMN enabled INTEGER; ALTER TABLE raw_alter_items RENAME COLUMN label TO name; ALTER TABLE raw_alter_items DROP COLUMN enabled; ALTER TABLE raw_alter_items RENAME TO raw_alter_records;");
    result.deinit();
    var rows = try db.exec("SELECT id, name FROM raw_alter_records;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings("one", rows.rows[0][1].text);
}

test "literal column defaults apply to omitted inserts and persist" {
    const path = "sqlite_zig_defaults_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE default_items (id INTEGER, label TEXT DEFAULT 'untitled', enabled INTEGER DEFAULT 1); INSERT INTO default_items (id) VALUES (1); INSERT INTO default_items DEFAULT VALUES;");
    result.deinit();
    var rows = try db.exec("SELECT id, label, enabled FROM default_items ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.rowCount());
    try std.testing.expectEqualStrings("untitled", rows.rows[0][1].text);
    try std.testing.expectEqual(@as(i64, 1), rows.rows[1][2].integer);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var reopened = try db.exec("INSERT INTO default_items (id) VALUES (3); SELECT label, enabled FROM default_items WHERE id = 3;");
    defer reopened.deinit();
    try std.testing.expectEqualStrings("untitled", reopened.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 1), reopened.rows[0][1].integer);
}

test "ordinary UPDATE evaluates row expressions" {
    const path = "sqlite_zig_update_expression_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var result = try db.exec("CREATE TABLE update_expression_items (id INTEGER, amount INTEGER, label TEXT); INSERT INTO update_expression_items VALUES (1, 10, 'old'), (2, 20, 'old'); UPDATE update_expression_items SET amount = amount + 5, label = 'new' WHERE id = 1;");
    result.deinit();
    var rows = try db.exec("SELECT amount, label FROM update_expression_items WHERE id = 1;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 15), rows.rows[0][0].integer);
    try std.testing.expectEqualStrings("new", rows.rows[0][1].text);
}

test "GLOB supports wildcards, character classes, and typed DSL" {
    const path = "sqlite_zig_glob_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const User = @import("../dsl/table.zig").table("glob_items", struct { id: i64, name: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE glob_items (id INTEGER, name TEXT); INSERT INTO glob_items VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Rob');");
    created.deinit();
    var raw = try db.exec("SELECT id FROM glob_items WHERE name GLOB '[BR]ob' ORDER BY id;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 2), raw.rowCount());
    var typed = try db.from(User).select("*").where(User.column("name").glob("A*")).fetchAll();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.rowCount());
}

test "trim family works in raw and typed projections" {
    const path = "sqlite_zig_trim_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("trim_items", struct { id: i64, label: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE trim_items (id INTEGER, label TEXT); INSERT INTO trim_items VALUES (1, '  Alpha  ');");
    created.deinit();
    var raw = try db.exec("SELECT TRIM(label), LTRIM(label), RTRIM(label) FROM trim_items;");
    defer raw.deinit();
    try std.testing.expectEqualStrings("Alpha", raw.rows[0][0].text);
    try std.testing.expectEqualStrings("Alpha  ", raw.rows[0][1].text);
    try std.testing.expectEqualStrings("  Alpha", raw.rows[0][2].text);
    var typed = try db.from(Item).trimColumn(Item.key("label")).fetchAll();
    defer typed.deinit();
    try std.testing.expectEqualStrings("Alpha", typed.rows[0][0].text);
}

test "replace and substr support multiple scalar arguments" {
    const path = "sqlite_zig_string_functions_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE string_items (label TEXT); INSERT INTO string_items VALUES ('Alice in SQLite');");
    created.deinit();
    var rows = try db.exec("SELECT REPLACE(label, 'SQLite', 'Zig'), SUBSTR(label, 1, 5) FROM string_items;");
    defer rows.deinit();
    try std.testing.expectEqualStrings("Alice in Zig", rows.rows[0][0].text);
    try std.testing.expectEqualStrings("Alice", rows.rows[0][1].text);
}

test "typed replace and substr projections check columns at compile time" {
    const path = "sqlite_zig_typed_string_functions_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("typed_string_items", struct { id: i64, label: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE typed_string_items (id INTEGER, label TEXT); INSERT INTO typed_string_items VALUES (1, 'Alice in SQLite');");
    created.deinit();
    var replaced = try db.from(Item).replaceColumn(Item.key("label"), "SQLite", "Zig").fetchAll();
    defer replaced.deinit();
    try std.testing.expectEqualStrings("Alice in Zig", replaced.rows[0][0].text);
    var shortened = try db.from(Item).substrColumn(Item.key("label"), 1, 5).fetchAll();
    defer shortened.deinit();
    try std.testing.expectEqualStrings("Alice", shortened.rows[0][0].text);
}

test "typed fetch maps result columns into the table struct" {
    const path = "sqlite_zig_typed_fetch_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("typed_fetch_items", struct { id: i64, label: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE typed_fetch_items (id INTEGER, label TEXT); INSERT INTO typed_fetch_items VALUES (7, 'mapped');");
    created.deinit();
    var typed = try db.from(Item).selectColumns(&.{ Item.key("label"), Item.key("id") }).fetchTyped();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.rowCount());
    try std.testing.expectEqual(@as(i64, 7), typed.rows[0].id);
    try std.testing.expectEqualStrings("mapped", typed.rows[0].label);
}

test "coalesce, ifnull, and instr evaluate their arguments" {
    const path = "sqlite_zig_coalesce_instr_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE scalar_items (a TEXT, b TEXT); INSERT INTO scalar_items VALUES (NULL, 'fallback');");
    created.deinit();
    var rows = try db.exec("SELECT COALESCE(a, NULL, b), IFNULL(a, b), INSTR(b, 'back') FROM scalar_items;");
    defer rows.deinit();
    try std.testing.expectEqualStrings("fallback", rows.rows[0][0].text);
    try std.testing.expectEqualStrings("fallback", rows.rows[0][1].text);
    try std.testing.expectEqual(@as(i64, 5), rows.rows[0][2].integer);
}

test "NOT GLOB works in raw SQL and typed DSL" {
    const path = "sqlite_zig_not_glob_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("not_glob_items", struct { id: i64, name: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE not_glob_items (id INTEGER, name TEXT); INSERT INTO not_glob_items VALUES (1, 'Alice'), (2, 'Bob');");
    created.deinit();
    var raw = try db.exec("SELECT id FROM not_glob_items WHERE name NOT GLOB 'A*';");
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 1), raw.rowCount());
    var typed = try db.from(Item).where(Item.column("name").notGlob("A*")).fetchAll();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.rowCount());
}

test "typed fetch maps SQLite NULL into optional struct fields" {
    const path = "sqlite_zig_typed_optional_fetch_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("typed_optional_items", struct { id: i64, label: ?[]const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE typed_optional_items (id INTEGER, label TEXT); INSERT INTO typed_optional_items VALUES (1, NULL), (2, 'present');");
    created.deinit();
    var typed = try db.from(Item).fetchTyped();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.rowCount());
    try std.testing.expect(typed.rows[0].label == null);
    try std.testing.expectEqualStrings("present", typed.rows[1].label.?);
}

test "typed boolean fields use SQLite INTEGER affinity" {
    const path = "sqlite_zig_typed_bool_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("typed_bool_items", struct { id: i64, enabled: bool });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(Item, .{});
    var inserted = try db.from(Item).insert(.{ .id = 1, .enabled = true });
    inserted.deinit();
    var typed = try db.from(Item).fetchTyped();
    defer typed.deinit();
    try std.testing.expect(typed.rows[0].enabled);
}

test "LIKE is ASCII case-insensitive while GLOB remains case-sensitive" {
    const path = "sqlite_zig_like_case_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE case_items (name TEXT); INSERT INTO case_items VALUES ('Alice');");
    created.deinit();
    var like_rows = try db.exec("SELECT name FROM case_items WHERE name LIKE 'a%';");
    defer like_rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), like_rows.rowCount());
    var glob_rows = try db.exec("SELECT name FROM case_items WHERE name GLOB 'a*';");
    defer glob_rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), glob_rows.rowCount());
}

test "function expressions are valid predicate left-hand sides" {
    const path = "sqlite_zig_function_predicate_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE function_predicate_items (name TEXT); INSERT INTO function_predicate_items VALUES ('Alice'), ('Bob');");
    created.deinit();
    var rows = try db.exec("SELECT name FROM function_predicate_items WHERE LOWER(name) = 'alice';");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings("Alice", rows.rows[0][0].text);
}

test "trim functions work in predicate expressions" {
    const path = "sqlite_zig_trim_predicate_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE trim_predicate_items (name TEXT); INSERT INTO trim_predicate_items VALUES ('  Alice  '), ('Bob');");
    created.deinit();
    var rows = try db.exec("SELECT name FROM trim_predicate_items WHERE TRIM(name) = 'Alice';");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings("  Alice  ", rows.rows[0][0].text);
}

test "INSTR works in numeric predicate expressions" {
    const path = "sqlite_zig_instr_predicate_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE instr_predicate_items (name TEXT); INSERT INTO instr_predicate_items VALUES ('SQLite'), ('Zig');");
    created.deinit();
    var rows = try db.exec("SELECT name FROM instr_predicate_items WHERE INSTR(name, 'ite') > 0;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings("SQLite", rows.rows[0][0].text);
}

test "typed DSL function predicates validate columns" {
    const path = "sqlite_zig_typed_function_predicate_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("typed_function_items", struct { name: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE typed_function_items (name TEXT); INSERT INTO typed_function_items VALUES ('  Alice  '), ('Alice'), ('Bob');");
    created.deinit();
    var lower = try db.from(Item).whereLower(Item.key("name"), "alice").fetchAll();
    defer lower.deinit();
    try std.testing.expectEqual(@as(usize, 1), lower.rowCount());
    var trimmed = try db.from(Item).whereTrim(Item.key("name"), "Alice").fetchAll();
    defer trimmed.deinit();
    try std.testing.expectEqual(@as(usize, 2), trimmed.rowCount());
}

test "generic typed function predicate supports scalar comparisons" {
    const path = "sqlite_zig_generic_function_predicate_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("generic_function_items", struct { name: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE generic_function_items (name TEXT); INSERT INTO generic_function_items VALUES ('long'), ('x');");
    created.deinit();
    var rows = try db.from(Item).whereFunction("LENGTH", Item.key("name"), .greater, 1).fetchAll();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}

test "typed two-argument function predicates support INSTR" {
    const path = "sqlite_zig_typed_function2_predicate_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("typed_function2_items", struct { name: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE typed_function2_items (name TEXT); INSERT INTO typed_function2_items VALUES ('SQLite'), ('Zig');");
    created.deinit();
    var rows = try db.from(Item).whereFunction2("INSTR", Item.key("name"), "ite", .greater, 0).fetchAll();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
}

test "NULL-safe IS DISTINCT FROM works in raw SQL and typed DSL" {
    const path = "sqlite_zig_distinct_predicate_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("distinct_items", struct { id: i64, label: ?[]const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE distinct_items (id INTEGER, label TEXT); INSERT INTO distinct_items VALUES (1, NULL), (2, 'x');");
    created.deinit();
    var raw = try db.exec("SELECT id FROM distinct_items WHERE label IS NOT DISTINCT FROM NULL ORDER BY id;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 1), raw.rowCount());
    try std.testing.expectEqual(@as(i64, 1), raw.rows[0][0].integer);
    var typed = try db.from(Item).where(Item.column("label").isDistinctFrom(@as(Value, .null))).fetchAll();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.rowCount());
    try std.testing.expectEqual(@as(i64, 2), typed.rows[0][0].integer);
}

test "NULLIF returns NULL only when its arguments are equal" {
    const path = "sqlite_zig_nullif_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE nullif_items (value INTEGER); INSERT INTO nullif_items VALUES (0), (7);");
    created.deinit();
    var rows = try db.exec("SELECT NULLIF(value, 0), NULLIF(value, 7) FROM nullif_items ORDER BY value;");
    defer rows.deinit();
    try std.testing.expect(rows.rows[0][0] == .null);
    try std.testing.expectEqual(@as(i64, 0), rows.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 7), rows.rows[1][0].integer);
    try std.testing.expect(rows.rows[1][1] == .null);
}

test "ROUND works in raw and typed projections" {
    const path = "sqlite_zig_round_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("round_items", struct { value: f64 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE round_items (value REAL); INSERT INTO round_items VALUES (1.6), (2.2);");
    created.deinit();
    var raw = try db.exec("SELECT ROUND(value) FROM round_items ORDER BY value;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(f64, 2), raw.rows[0][0].real);
    var typed = try db.from(Item).roundColumn(Item.key("value")).fetchAll();
    defer typed.deinit();
    try std.testing.expectEqual(@as(f64, 2), typed.rows[0][0].real);
}

test "ROUND honors positive and negative precision" {
    const path = "sqlite_zig_round_precision_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE round_precision_items (id INTEGER); INSERT INTO round_precision_items VALUES (1);");
    created.deinit();
    var rows = try db.exec("SELECT ROUND(1.236, 2), ROUND(123, -1) FROM round_precision_items;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(f64, 1.24), rows.rows[0][0].real);
    try std.testing.expectEqual(@as(f64, 120), rows.rows[0][1].real);
}

test "CAST supports INTEGER, REAL, and TEXT affinities" {
    const path = "sqlite_zig_cast_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("cast_items", struct { value: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE cast_items (value TEXT); INSERT INTO cast_items VALUES ('42');");
    created.deinit();
    var raw = try db.exec("SELECT CAST(value AS INTEGER), CAST(value AS REAL), CAST(value AS TEXT) FROM cast_items;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(i64, 42), raw.rows[0][0].integer);
    try std.testing.expectEqual(@as(f64, 42), raw.rows[0][1].real);
    try std.testing.expectEqualStrings("42", raw.rows[0][2].text);
    var typed = try db.from(Item).castColumn(Item.key("value"), "INTEGER").fetchAll();
    defer typed.deinit();
    try std.testing.expectEqual(@as(i64, 42), typed.rows[0][0].integer);
}

test "json_extract reads simple top-level scalar object fields" {
    const path = "sqlite_zig_json_extract_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE json_items (payload TEXT); INSERT INTO json_items VALUES ('{\"name\":\"Alice\",\"age\":42,\"missing\":null}');");
    created.deinit();
    var rows = try db.exec("SELECT json_extract(payload, '$.name'), json_extract(payload, '$.age'), json_extract(payload, '$.missing') FROM json_items;");
    defer rows.deinit();
    try std.testing.expectEqualStrings("Alice", rows.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 42), rows.rows[0][1].integer);
    try std.testing.expect(rows.rows[0][2] == .null);
}

test "typed json_extract validates the source column" {
    const path = "sqlite_zig_typed_json_extract_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("typed_json_items", struct { payload: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE typed_json_items (payload TEXT); INSERT INTO typed_json_items VALUES ('{\"name\":\"Alice\"}'), ('{\"name\":\"Bob\"}');");
    created.deinit();
    var typed = try db.from(Item).jsonExtractColumn(Item.key("payload"), "$.name").fetchAll();
    defer typed.deinit();
    try std.testing.expectEqualStrings("Alice", typed.rows[0][0].text);
    var filtered = try db.from(Item).whereJsonExtract(Item.key("payload"), "$.name", .equal, "Bob").fetchAll();
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.rowCount());
}

test "typed text convenience predicates compile to LIKE" {
    const path = "sqlite_zig_text_predicates_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("text_predicate_items", struct { name: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE text_predicate_items (name TEXT); INSERT INTO text_predicate_items VALUES ('Alice'), ('Malice'), ('Bob');");
    created.deinit();
    var contains = try db.from(Item).where(Item.column("name").contains("ali")).fetchAll();
    defer contains.deinit();
    try std.testing.expectEqual(@as(usize, 2), contains.rowCount());
    var starts = try db.from(Item).where(Item.column("name").startsWith("Al")).fetchAll();
    defer starts.deinit();
    try std.testing.expectEqual(@as(usize, 1), starts.rowCount());
    var ends = try db.from(Item).where(Item.column("name").endsWith("ob")).fetchAll();
    defer ends.deinit();
    try std.testing.expectEqual(@as(usize, 1), ends.rowCount());
    var not_contains = try db.from(Item).where(Item.column("name").notContains("ali")).fetchAll();
    defer not_contains.deinit();
    try std.testing.expectEqual(@as(usize, 1), not_contains.rowCount());
}

test "select accepts typed column arrays" {
    const path = "sqlite_zig_typed_select_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("typed_select_items", struct { id: i64, label: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE typed_select_items (id INTEGER, label TEXT); INSERT INTO typed_select_items VALUES (7, 'seven');");
    created.deinit();
    var rows = try db.from(Item).selectTyped(&.{ Item.key("label"), Item.key("id") }).fetchAll();
    defer rows.deinit();
    try std.testing.expectEqualStrings("seven", rows.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 7), rows.rows[0][1].integer);
}

test "fetchOneTyped returns a mapped row or null" {
    const path = "sqlite_zig_fetch_one_typed_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("fetch_one_items", struct { id: i64, label: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE fetch_one_items (id INTEGER, label TEXT); INSERT INTO fetch_one_items VALUES (3, 'three');");
    created.deinit();
    var row = (try db.from(Item).where(Item.column("id").eq(3)).fetchOneTyped()).?;
    defer db.from(Item).deinitTypedRow(&row);
    try std.testing.expectEqual(@as(i64, 3), row.id);
    try std.testing.expectEqualStrings("three", row.label);
    const missing = try db.from(Item).where(Item.column("id").eq(99)).fetchOneTyped();
    try std.testing.expect(missing == null);
}

test "typed coalesce and ifnull projections use SQLite null semantics" {
    const path = "sqlite_zig_typed_null_functions_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("typed_null_function_items", struct { label: ?[]const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE typed_null_function_items (label TEXT); INSERT INTO typed_null_function_items VALUES (NULL), ('ready');");
    created.deinit();
    var coalesced = try db.from(Item).coalesceColumn(Item.key("label"), "fallback").fetchAll();
    defer coalesced.deinit();
    try std.testing.expectEqualStrings("fallback", coalesced.rows[0][0].text);
    try std.testing.expectEqualStrings("ready", coalesced.rows[1][0].text);
    var ifnulled = try db.from(Item).ifNullColumn(Item.key("label"), 7).fetchAll();
    defer ifnulled.deinit();
    try std.testing.expectEqual(@as(i64, 7), ifnulled.rows[0][0].integer);
}

test "json_set updates a simple top-level scalar key" {
    const path = "sqlite_zig_json_set_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("json_set_items", struct { payload: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE json_set_items (payload TEXT); INSERT INTO json_set_items VALUES ('{\"city\":\"London\"}');");
    created.deinit();
    var raw = try db.exec("SELECT json_set(payload, '$.city', 'Paris') FROM json_set_items;");
    defer raw.deinit();
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", raw.rows[0][0].text);
    var typed = try db.from(Item).jsonSetColumn(Item.key("payload"), "$.city", "Paris").fetchAll();
    defer typed.deinit();
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", typed.rows[0][0].text);
    var inserted = try db.exec("SELECT json_set(payload, '$.country', 'UK') FROM json_set_items;");
    defer inserted.deinit();
    try std.testing.expectEqualStrings("{\"city\":\"London\",\"country\":\"UK\"}", inserted.rows[0][0].text);
}

test "raw DSL queries schema-less tables with runtime columns" {
    const path = "sqlite_zig_dynamic_dsl_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE dynamic_items (id INTEGER, name TEXT); INSERT INTO dynamic_items VALUES (1, 'Alice'), (2, 'Bob');");
    created.deinit();
    var rows = try db.from("dynamic_items").where(db.col("id").gte(2)).select("name").fetchAll();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings("Bob", rows.rows[0][0].text);
    var compound = try db.from("dynamic_items").where(db.col("id").gt(0)).andWhere(db.col("name").like("B%")).fetchAll();
    defer compound.deinit();
    try std.testing.expectEqual(@as(usize, 1), compound.rowCount());
    var glob = try db.from("dynamic_items").where(db.col("name").glob("A*")).fetchAll();
    defer glob.deinit();
    try std.testing.expectEqual(@as(usize, 1), glob.rowCount());
    var nulls = try db.exec("INSERT INTO dynamic_items VALUES (3, NULL);");
    nulls.deinit();
    var missing = try db.from("dynamic_items").where(db.col("name").isNull()).fetchAll();
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 1), missing.rowCount());
}
