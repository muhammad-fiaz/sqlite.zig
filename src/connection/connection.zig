const std = @import("std");
const DatabaseFile = @import("../storage/file.zig").DatabaseFile;
const image = @import("../storage/image.zig");
const sqliteImage = @import("../storage/sqlite_image.zig");
const Schema = @import("../catalog/schema.zig").Schema;
const Table = @import("../catalog/schema.zig").Table;
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");
const Parser = @import("../sql/parser.zig").Parser;
const Prepared = @import("statement.zig").Statement;
pub const Result = @import("result.zig").Result;
const DynamicColumn = @import("../dsl/column.zig").DynamicColumn;
const Builder = @import("../dsl/query_builder.zig").Builder;
const DynamicQuery = @import("../dsl/query_builder.zig").DynamicQuery;
const keys = @import("../dsl/keys.zig");

const Savepoint = struct { name: []u8, schema: Schema };
const OuterRow = struct { table: *const Table, values: []const Value };

pub const Connection = struct {
    allocator: std.mem.Allocator,
    file: DatabaseFile,
    store: Schema,
    backup: ?Schema = null,
    transactionActive: bool = false,
    savepoints: std.ArrayList(Savepoint),

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Connection {
        const connection = try allocator.create(Connection);
        errdefer allocator.destroy(connection);
        connection.* = .{ .allocator = allocator, .file = try DatabaseFile.open(allocator, path), .store = Schema.init(allocator), .savepoints = .empty };
        errdefer connection.close();
        if (try connection.file.readPayload()) |payload| {
            defer allocator.free(payload);
            connection.store.deinit();
            connection.store = try image.decode(allocator, payload);
            try connection.persist();
        } else {
            const bytes = try connection.file.readImage();
            defer allocator.free(bytes);
            if (bytes[100] == 0x0d) {
                connection.store.deinit();
                connection.store = try sqliteImage.decode(allocator, bytes);
            }
        }
        return connection;
    }

    pub fn close(self: *Connection) void {
        if (self.transactionActive) {
            self.rollback() catch {};
        }
        self.persist() catch {};
        if (self.backup) |*backup| backup.deinit();
        self.clearSavepoints();
        self.savepoints.deinit(self.allocator);
        self.store.deinit();
        self.file.close();
        self.allocator.destroy(self);
    }

    fn persist(self: *Connection) !void {
        const bytes = try sqliteImage.encodeWithPageSize(self.allocator, &self.store, self.file.pageSize);
        defer self.allocator.free(bytes);
        try self.file.writeImage(bytes);
    }

    pub fn exec(self: *Connection, sql: []const u8) !Result {
        var last: ?Result = null;
        errdefer if (last) |*result| result.deinit();
        var start: usize = 0;
        var index: usize = 0;
        var quote: u8 = 0;
        var triggerDefinition = false;
        var triggerDepth: usize = 0;
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
                const wordStart = index;
                while (index + 1 < sql.len and (std.ascii.isAlphanumeric(sql[index + 1]) or sql[index + 1] == '_')) : (index += 1) {}
                const word = sql[wordStart .. index + 1];
                if (std.ascii.eqlIgnoreCase(word, "trigger")) triggerDefinition = true;
                if (triggerDefinition and std.ascii.eqlIgnoreCase(word, "begin")) triggerDepth += 1;
                if (triggerDefinition and std.ascii.eqlIgnoreCase(word, "end") and triggerDepth > 0) triggerDepth -= 1;
                continue;
            }
            if (byte == ';' and triggerDepth == 0) {
                const statementSql = std.mem.trim(u8, sql[start..index], " \t\r\n");
                if (statementSql.len != 0) {
                    if (last) |*result| result.deinit();
                    last = try self.execute(statementSql, &.{});
                }
                start = index + 1;
                triggerDefinition = false;
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
        return .{ .connection = self, .sql = try self.allocator.dupe(u8, sql), .allocator = self.allocator, .parameters = .empty, .executeFn = executePrepared };
    }

    pub fn from(self: *Connection, source: anytype) if (@TypeOf(source) == type) Builder(source.rowType, @TypeOf(source.columns), true) else DynamicQuery {
        if (@TypeOf(source) == type) {
            if (!@hasDecl(source, "tableName") or !@hasDecl(source, "rowType")) @compileError("db.from() expects a sqlite.table(...) type or a table-name string");
            return Builder(source.rowType, @TypeOf(source.columns), true).init(self, source.tableName, executeForDsl);
        }
        return DynamicQuery.init(self, source, executeForDsl);
    }

    pub fn col(_: *Connection, name: []const u8) DynamicColumn {
        return .{ .name = name };
    }

    pub fn schema(self: *Connection, comptime TableType: type) SchemaValidator(TableType) {
        return .{ .connection = self };
    }

    pub fn tableExists(self: *Connection, comptime TableType: type) bool {
        return self.store.find(TableType.tableName) != null;
    }

    pub fn createTable(self: *Connection, target: anytype, options: anytype) !void {
        const T = @TypeOf(target);
        if (T == type) {
            if (!@hasDecl(target, "tableName") or !@hasDecl(target, "rowType")) @compileError("createTable expects a sqlite.table(...) type or a table-name string");
            if (self.tableExists(target)) {
                if (@hasField(@TypeOf(options), "ifNotExists")) {
                    if (options.ifNotExists) return;
                }
                return error.TableExists;
            }
            try self.createTypedTable(target, options);
        } else {
            if (self.store.find(target) != null) {
                if (@hasField(@TypeOf(options), "ifNotExists")) {
                    if (options.ifNotExists) return;
                }
                return error.TableExists;
            }
            try self.createDynamicTable(target, options);
        }
        if (!self.transactionActive) try self.persist();
    }

    fn createTypedTable(self: *Connection, comptime TableType: type, options: anytype) !void {
        const Row = TableType.rowType;
        const rowFields = @typeInfo(Row).@"struct".fields;
        const colFields = @typeInfo(@TypeOf(TableType.columns)).@"struct".fields;
        if (rowFields.len != colFields.len) @compileError("table columns do not match row fields");
        var definitions: [colFields.len]ast.ColumnDef = undefined;
        inline for (colFields, 0..) |colField, index| {
            const F = colField.type.fieldType;
            if (F != rowFields[index].type) @compileError("table columns do not match row fields");
            definitions[index] = .{
                .name = colField.type.dslName,
                .typeName = keys.dslTypeName(F),
                .notNull = @typeInfo(F) != .optional,
                .defaultValue = keys.zigDefault(rowFields[index].type, rowFields[index].default_value_ptr),
            };
        }
        var expected = keys.ExpectedKeys{};
        const TO = @TypeOf(TableType.tableOptions);
        if (@hasField(@TypeOf(options), "primaryKey")) {
            try keys.parsePkInto(options.primaryKey, TableType.tableName, &expected);
        } else if (@hasField(TO, "primaryKey")) {
            try keys.parsePkInto(TableType.tableOptions.primaryKey, TableType.tableName, &expected);
        }
        if (@hasField(@TypeOf(options), "unique")) {
            try keys.parseUniqueInto(options.unique, TableType.tableName, &expected);
        } else if (@hasField(TO, "unique")) {
            try keys.parseUniqueInto(TableType.tableOptions.unique, TableType.tableName, &expected);
        }
        if (@hasField(@TypeOf(options), "foreignKeys")) {
            try keys.parseFksInto(options.foreignKeys, TableType.tableName, &expected);
        } else if (@hasField(TO, "foreignKeys")) {
            try keys.parseFksInto(TableType.tableOptions.foreignKeys, TableType.tableName, &expected);
        }
        var constraints = std.ArrayList(ast.TableConstraint).empty;
        defer constraints.deinit(self.allocator);
        try self.applyExpectedKeys(TableType.tableName, &definitions, &constraints, &expected);
        try self.store.createTable(TableType.tableName, &definitions, constraints.items);
    }

    fn createDynamicTable(self: *Connection, name: []const u8, options: anytype) !void {
        if (!@hasField(@TypeOf(options), "columns")) @compileError("dynamic createTable needs .columns (use raw SQL otherwise)");
        var definitions = std.ArrayList(ast.ColumnDef).empty;
        defer definitions.deinit(self.allocator);
        const items = if (@typeInfo(@TypeOf(options.columns)) == .pointer) options.columns.* else options.columns;
        const info = @typeInfo(@TypeOf(items));
        if ((info == .@"struct" and info.@"struct".is_tuple) or info == .array) {
            inline for (items) |item| try self.appendDynamicColumn(&definitions, item);
        } else {
            for (items) |item| try self.appendDynamicColumnSerial(&definitions, item);
        }
        var expected = keys.ExpectedKeys{};
        if (@hasField(@TypeOf(options), "primaryKey")) try keys.parsePkInto(options.primaryKey, name, &expected);
        if (@hasField(@TypeOf(options), "unique")) try keys.parseUniqueInto(options.unique, name, &expected);
        if (@hasField(@TypeOf(options), "foreignKeys")) try keys.parseFksInto(options.foreignKeys, name, &expected);
        var constraints = std.ArrayList(ast.TableConstraint).empty;
        defer constraints.deinit(self.allocator);
        try self.applyExpectedKeys(name, definitions.items, &constraints, &expected);
        try self.store.createTable(name, definitions.items, constraints.items);
    }

    fn appendDynamicColumn(self: *Connection, definitions: *std.ArrayList(ast.ColumnDef), spec: anytype) !void {
        try definitions.append(self.allocator, try self.dynamicColumnDef(spec));
    }

    fn appendDynamicColumnSerial(self: *Connection, definitions: *std.ArrayList(ast.ColumnDef), spec: anytype) !void {
        const T = @TypeOf(spec);
        const isName = comptime keys.isStringLike(T);
        if (isName) {
            try definitions.append(self.allocator, .{ .name = keys.coerceName(spec), .typeName = "" });
            return;
        }
        try definitions.append(self.allocator, .{ .name = keys.coerceName(spec.name), .typeName = if (@hasField(T, "type")) keys.coerceName(spec.type) else "" });
    }

    fn dynamicColumnDef(_: *Connection, spec: anytype) !ast.ColumnDef {
        const T = @TypeOf(spec);
        const isName = comptime keys.isStringLike(T);
        if (isName) return .{ .name = keys.coerceName(spec), .typeName = "" };
        const info = @typeInfo(T);
        if (info != .@"struct" or info.@"struct".is_tuple) @compileError("dynamic .columns items must be name strings or structs with .name");
        var def = ast.ColumnDef{ .name = keys.coerceName(spec.name), .typeName = "" };
        if (@hasField(T, "type")) def.typeName = keys.coerceName(spec.type);
        if (@hasField(T, "notNull")) def.notNull = spec.notNull;
        if (@hasField(T, "unique")) def.unique = spec.unique;
        if (@hasField(T, "primaryKey")) def.primaryKey = spec.primaryKey;
        if (@hasField(T, "default")) def.defaultValue = @import("../dsl/column.zig").toValue(spec.default);
        return def;
    }

    fn applyExpectedKeys(self: *Connection, tableName: []const u8, definitions: []ast.ColumnDef, constraints: *std.ArrayList(ast.TableConstraint), expected: *const keys.ExpectedKeys) !void {
        _ = tableName;
        if (expected.hasPk) {
            if (expected.pkCount == 1) {
                (findDefinition(definitions, expected.pk[0]) orelse return error.UnknownColumn).primaryKey = true;
            } else {
                try constraints.append(self.allocator, .{ .primaryKey = expected.pk[0..expected.pkCount] });
            }
        }
        if (expected.hasUnique) {
            for (expected.uniqueSingles[0..expected.uniqueSingleCount]) |colName| {
                (findDefinition(definitions, colName) orelse return error.UnknownColumn).unique = true;
            }
            for (expected.uniqueGroups[0..expected.uniqueGroupCount]) |*group| {
                for (group.names[0..group.count]) |colName| if (findDefinition(definitions, colName) == null) return error.UnknownColumn;
                try constraints.append(self.allocator, .{ .unique = group.names[0..group.count] });
            }
        }
        if (expected.hasFks) {
            for (expected.fks[0..expected.fkCount]) |*fk| {
                for (fk.local[0..fk.localCount]) |colName| if (findDefinition(definitions, colName) == null) return error.UnknownColumn;
                if (fk.localCount == 1 and fk.refCount == 1) {
                    (findDefinition(definitions, fk.local[0]) orelse return error.UnknownColumn).foreignKey = .{
                        .table = fk.refTable,
                        .column = fk.refCols[0],
                        .onDelete = fk.onDelete,
                        .onUpdate = fk.onUpdate,
                    };
                } else {
                    try constraints.append(self.allocator, .{ .foreignKey = .{
                        .columns = fk.local[0..fk.localCount],
                        .table = fk.refTable,
                        .referencedColumns = fk.refCols[0..fk.refCount],
                        .onDelete = fk.onDelete,
                        .onUpdate = fk.onUpdate,
                    } });
                }
            }
        }
    }

    fn findDefinition(definitions: []ast.ColumnDef, name: []const u8) ?*ast.ColumnDef {
        for (definitions) |*def| if (std.ascii.eqlIgnoreCase(def.name, name)) return def;
        return null;
    }

    pub fn dropTable(self: *Connection, comptime TableType: type) !void {
        try self.store.dropTable(TableType.tableName);
        if (!self.transactionActive) try self.persist();
    }

    pub fn createIndex(self: *Connection, target: anytype, name: []const u8, cols: anytype, unique: bool) !void {
        const tableName: []const u8 = if (@TypeOf(target) == type) blk: {
            if (!@hasDecl(target, "tableName")) @compileError("createIndex expects a sqlite.table(...) type or a table-name string");
            break :blk target.tableName;
        } else target;
        var names: [16][]const u8 = undefined;
        const count = try keys.normalizeKey(cols, tableName, &names);
        try self.store.createIndex(.{ .name = name, .table = tableName, .columns = names[0..count], .unique = unique });
        if (!self.transactionActive) try self.persist();
    }

    pub fn dropIndex(self: *Connection, comptime name: []const u8) !void {
        try self.store.dropIndex(name);
        if (!self.transactionActive) try self.persist();
    }

    pub fn createView(self: *Connection, comptime name: []const u8, sql: []const u8) !void {
        try self.store.createView(name, sql);
        if (!self.transactionActive) try self.persist();
    }

    pub fn dropView(self: *Connection, comptime name: []const u8) !void {
        try self.store.dropView(name);
        if (!self.transactionActive) try self.persist();
    }

    pub fn dropTrigger(self: *Connection, comptime name: []const u8) !void {
        try self.store.dropTrigger(name);
        if (!self.transactionActive) try self.persist();
    }

    pub fn renameTable(self: *Connection, comptime TableType: type, comptime newName: []const u8) !void {
        try self.store.renameTable(TableType.tableName, newName);
        if (!self.transactionActive) try self.persist();
    }

    pub fn truncate(self: *Connection, comptime TableType: type) !void {
        try self.store.truncateTable(TableType.tableName);
        if (!self.transactionActive) try self.persist();
    }

    pub fn addColumn(self: *Connection, comptime TableType: type, comptime field: []const u8, comptime FieldType: type) !void {
        try self.store.addColumn(TableType.tableName, .{ .name = field, .typeName = keys.dslTypeName(FieldType) });
        if (!self.transactionActive) try self.persist();
    }

    pub fn renameColumn(self: *Connection, comptime TableType: type, comptime oldName: []const u8, comptime newName: []const u8) !void {
        try self.store.renameColumn(TableType.tableName, oldName, newName);
        if (!self.transactionActive) try self.persist();
    }

    pub fn dropColumn(self: *Connection, comptime TableType: type, comptime field: []const u8) !void {
        try self.store.dropColumn(TableType.tableName, field);
        if (!self.transactionActive) try self.persist();
    }

    fn executeForDsl(pointer: *anyopaque, sql: []const u8, parameters: []const Value) anyerror!Result {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        return self.execute(sql, parameters);
    }

    pub fn SchemaValidator(comptime TableType: type) type {
        return struct {
            connection: *Connection,

            pub fn validate(self: @This()) !void {
                const t = self.connection.store.findConst(TableType.tableName) orelse return error.UnknownTable;
                const rowFields = @typeInfo(TableType.rowType).@"struct".fields;
                const colFields = @typeInfo(@TypeOf(TableType.columns)).@"struct".fields;
                if (t.columns.len != colFields.len) return error.SchemaMismatch;
                if (rowFields.len != colFields.len) return error.SchemaMismatch;
                var pkBuf: [16][]const u8 = undefined;
                const pkCount = keys.actualPk(t, &pkBuf);
                inline for (colFields, 0..) |colField, index| {
                    const F = colField.type.fieldType;
                    if (F != rowFields[index].type) return error.SchemaMismatch;
                    const column = findSchemaColumn(t, colField.type.dslName) orelse return error.SchemaMismatch;
                    if (!keys.affinitiesCompatible(keys.dslTypeName(F), column.typeName)) return error.SchemaMismatch;
                    const expectNotNull = @typeInfo(F) != .optional;
                    const pkMember = column.primaryKey or isNameIn(colField.type.dslName, pkBuf[0..pkCount]);
                    if (column.notNull != expectNotNull and !(expectNotNull and pkMember)) return error.SchemaMismatch;
                    if (!keys.sameDefault(keys.zigDefault(rowFields[index].type, rowFields[index].default_value_ptr), column.defaultValue)) return error.SchemaMismatch;
                }
                var expected = keys.ExpectedKeys{};
                const TO = @TypeOf(TableType.tableOptions);
                if (@hasField(TO, "primaryKey")) try keys.parsePkInto(TableType.tableOptions.primaryKey, TableType.tableName, &expected);
                if (@hasField(TO, "unique")) try keys.parseUniqueInto(TableType.tableOptions.unique, TableType.tableName, &expected);
                if (@hasField(TO, "foreignKeys")) try keys.parseFksInto(TableType.tableOptions.foreignKeys, TableType.tableName, &expected);
                try keys.validateKeys(t, &expected);
            }
        };
    }

    fn findSchemaColumn(t: *const @import("../catalog/schema.zig").Table, name: []const u8) ?*const @import("../catalog/schema.zig").Column {
        for (t.columns) |*column| if (std.ascii.eqlIgnoreCase(column.name, name)) return column;
        return null;
    }

    fn isNameIn(name: []const u8, list: []const []const u8) bool {
        for (list) |item| if (std.ascii.eqlIgnoreCase(item, name)) return true;
        return false;
    }

    fn executePrepared(pointer: *anyopaque, sql: []const u8, parameters: []const Value) anyerror!void {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        var result = try self.execute(sql, parameters);
        result.deinit();
    }

    pub fn begin(self: *Connection) !void {
        if (self.transactionActive) return error.TransactionActive;
        self.backup = try self.store.clone();
        self.transactionActive = true;
    }

    pub fn beginImmediate(self: *Connection) !void {
        try self.begin();
    }
    pub fn beginExclusive(self: *Connection) !void {
        try self.begin();
    }
    pub fn commit(self: *Connection) !void {
        if (!self.transactionActive) return error.NotInTransaction;
        try self.persist();
        if (self.backup) |*backup| backup.deinit();
        self.backup = null;
        self.clearSavepoints();
        self.transactionActive = false;
    }
    pub fn rollback(self: *Connection) !void {
        if (!self.transactionActive) return error.NotInTransaction;
        self.store.deinit();
        self.store = self.backup.?;
        self.backup = null;
        self.clearSavepoints();
        self.transactionActive = false;
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
        if (!self.transactionActive) try self.begin();
        var snapshot = try self.store.clone();
        errdefer snapshot.deinit();
        const ownedName = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(ownedName);
        try self.savepoints.append(self.allocator, .{ .name = ownedName, .schema = snapshot });
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
                self.store.deinit();
                self.store = try self.savepoints.items[index].schema.clone();
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
            .createTable => |value| try self.createTableCommand(value),
            .createIndex => |value| try self.createIndexCommand(value),
            .createView => |value| try self.createViewCommand(value),
            .createTrigger => |value| try self.createTriggerCommand(value),
            .createVirtualTable => |value| try self.createVirtualTableCommand(value),
            .dropTable => |value| try self.dropTableCommand(value.name, value.ifExists),
            .dropIndex => |value| try self.dropIndexCommand(value.name, value.ifExists),
            .dropView => |value| try self.dropViewCommand(value.name, value.ifExists),
            .dropTrigger => |value| try self.dropTriggerCommand(value.name, value.ifExists),
            .insert => |value| try self.insertInto(value, parameters),
            .select => |value| try self.select(value, parameters),
            .withSelect => |value| try self.executeWith(value, parameters),
            .explainQueryPlan => |querySql| try self.explainQueryPlan(querySql),
            .pragma => |value| try self.executePragma(value),
            .alterTable => |value| try self.alterTableCommand(value),
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
            .rollbackTo => |name| try self.rollbackToCommand(name),
        };
        if (!self.transactionActive and !statement.isQuery()) try self.persist();
        return result;
    }

    fn emptyResult(allocator: std.mem.Allocator) !Result {
        return .{ .allocator = allocator, .columns = try allocator.alloc([]const u8, 0), .rows = try allocator.alloc([]Value, 0) };
    }

    fn executePragma(self: *Connection, value: anytype) !Result {
        if (std.ascii.eqlIgnoreCase(value.name, "foreign_keys")) {
            if (value.value) |setting| {
                if (std.ascii.eqlIgnoreCase(setting, "on") or std.mem.eql(u8, setting, "1")) {
                    self.store.foreignKeysEnabled = true;
                } else if (std.ascii.eqlIgnoreCase(setting, "off") or std.mem.eql(u8, setting, "0")) {
                    self.store.foreignKeysEnabled = false;
                } else return error.InvalidSql;
            }
            const names = [_][]const u8{"foreign_keys"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = if (self.store.foreignKeysEnabled) 1 else 0 };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "user_version")) {
            if (value.value) |versionText| {
                const version = std.fmt.parseInt(u32, versionText, 10) catch return error.InvalidSql;
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
            if (value.value) |applicationText| {
                const applicationId = std.fmt.parseInt(u32, applicationText, 10) catch return error.InvalidSql;
                self.file.setApplicationId(applicationId);
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
        const tableName = query.table orelse return error.Unsupported;
        const table = self.store.findConst(tableName) orelse return error.UnknownTable;
        var detail = if (query.condition) |conditions| blk: {
            var chosen: ?[]const u8 = null;
            var chosenColumn: []const u8 = "";
            if (conditions.len == 1 and conditions[0].op == .equal) {
                for (self.store.indexes.items) |index| if (index.columns.len == 1 and std.ascii.eqlIgnoreCase(index.table, table.name) and std.ascii.eqlIgnoreCase(index.columns[0], conditions[0].column)) {
                    chosen = index.name;
                    chosenColumn = index.columns[0];
                    break;
                };
            }
            if (chosen) |indexName| break :blk try std.fmt.allocPrint(self.allocator, "SEARCH {s} USING INDEX {s} ({s}=?)", .{ table.name, indexName, chosenColumn });
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
        const resultColumns = try self.ownedColumns(&columns);
        const row = try self.allocator.alloc(Value, 1);
        row[0] = .{ .text = try self.allocator.dupe(u8, detail) };
        const rows = try self.allocator.alloc([]Value, 1);
        rows[0] = row;
        return .{ .allocator = self.allocator, .columns = resultColumns, .rows = rows };
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
        if (self.store.find(value.name) != null and value.ifNotExists) return try emptyResult(self.allocator);
        try self.store.createTable(value.name, value.columns, value.constraints);
        return try emptyResult(self.allocator);
    }
    fn alterTableCommand(self: *Connection, value: ast.AlterTable) !Result {
        switch (value) {
            .addColumn => |change| try self.store.addColumn(change.table, change.definition),
            .renameTable => |change| try self.store.renameTable(change.table, change.newName),
            .renameColumn => |change| try self.store.renameColumn(change.table, change.oldName, change.newName),
            .dropColumn => |change| try self.store.dropColumn(change.table, change.column),
        }
        return try emptyResult(self.allocator);
    }
    fn dropTableCommand(self: *Connection, name: []const u8, ifExists: bool) !Result {
        self.store.dropTable(name) catch |err| if (ifExists and err == error.UnknownTable) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }
    fn createIndexCommand(self: *Connection, value: ast.IndexDef) !Result {
        if (self.store.findIndexConst(value.name) != null and value.ifNotExists) return try emptyResult(self.allocator);
        try self.store.createIndex(value);
        return try emptyResult(self.allocator);
    }
    fn dropIndexCommand(self: *Connection, name: []const u8, ifExists: bool) !Result {
        self.store.dropIndex(name) catch |err| if (ifExists and err == error.UnknownIndex) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }
    fn createViewCommand(self: *Connection, value: anytype) !Result {
        if (self.store.findViewConst(value.name) != null and value.ifNotExists) return try emptyResult(self.allocator);
        try self.store.createView(value.name, value.sql);
        return try emptyResult(self.allocator);
    }
    fn dropViewCommand(self: *Connection, name: []const u8, ifExists: bool) !Result {
        self.store.dropView(name) catch |err| if (ifExists and err == error.UnknownView) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }
    fn createTriggerCommand(self: *Connection, value: ast.TriggerDef) !Result {
        if (self.store.findTriggerConst(value.name) != null and value.ifNotExists) return try emptyResult(self.allocator);
        try self.store.createTrigger(value);
        return try emptyResult(self.allocator);
    }
    fn createVirtualTableCommand(self: *Connection, value: ast.VirtualTableDef) !Result {
        if (self.store.find(value.name) != null) {
            if (value.ifNotExists) return try emptyResult(self.allocator);
            return error.TableExists;
        }
        try self.store.createVirtualTable(value.name, value.module, value.arguments);
        return try emptyResult(self.allocator);
    }
    fn dropTriggerCommand(self: *Connection, name: []const u8, ifExists: bool) !Result {
        self.store.dropTrigger(name) catch |err| if (ifExists and err == error.UnknownTrigger) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }

    fn executeWith(self: *Connection, value: ast.WithSelect, parameters: []const Value) anyerror!Result {
        var created: usize = 0;
        errdefer while (created > 0) {
            created -= 1;
            self.store.dropTable(value.ctes[created].name) catch {};
        };
        for (value.ctes) |cte| {
            var source = try self.execute(cte.querySql, parameters);
            defer source.deinit();
            const definitions = try self.allocator.alloc(ast.ColumnDef, source.columns.len);
            defer self.allocator.free(definitions);
            for (source.columns, 0..) |column, index| definitions[index] = .{ .name = column, .typeName = if (source.rows.len == 0) "" else source.rows[0][index].typeName() };
            try self.store.createTable(cte.name, definitions, &.{});
            const table = self.store.find(cte.name).?;
            for (source.rows) |row| try self.store.appendRow(table, row);
            if (cte.recursiveSql) |recursiveSql| {
                if (!value.recursive) return error.Unsupported;
                var iteration: usize = 0;
                while (iteration < 1000) : (iteration += 1) {
                    var next = try self.execute(recursiveSql, parameters);
                    defer next.deinit();
                    var added: usize = 0;
                    for (next.rows) |row| {
                        var exists = false;
                        for (table.rows.items) |existing| if (rowsEqual(existing.values, row)) {
                            exists = true;
                            break;
                        };
                        if (!exists) {
                            try self.store.appendRow(table, row);
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
            self.store.dropTable(value.ctes[created].name) catch {};
        };
        return self.execute(value.bodySql, parameters);
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

    fn renderTriggerBody(self: *Connection, body: []const u8, table: *const Table, event: ast.TriggerEvent, newRow: ?[]const Value, oldRow: ?[]const Value) ![]u8 {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(self.allocator);
        var index: usize = 0;
        while (index < body.len) {
            if (index + 4 < body.len and (std.ascii.eqlIgnoreCase(body[index .. index + 4], "NEW.") or std.ascii.eqlIgnoreCase(body[index .. index + 4], "OLD."))) {
                const isNew = std.ascii.eqlIgnoreCase(body[index .. index + 4], "NEW.");
                var end = index + 4;
                while (end < body.len and (std.ascii.isAlphanumeric(body[end]) or body[end] == '_')) : (end += 1) {}
                const name = body[index + 4 .. end];
                const column = columnIndex(table, name) catch {
                    try output.append(self.allocator, body[index]);
                    index += 1;
                    continue;
                };
                const row = if (isNew) newRow else oldRow;
                if (row == null or (isNew and event == .delete) or (!isNew and event == .insert)) return error.InvalidSql;
                try appendTriggerValue(&output, self.allocator, row.?[column]);
                index = end;
            } else {
                try output.append(self.allocator, body[index]);
                index += 1;
            }
        }
        return try output.toOwnedSlice(self.allocator);
    }

    fn fireTriggers(self: *Connection, tableName: []const u8, event: ast.TriggerEvent, newRow: ?[]const Value, oldRow: ?[]const Value) anyerror!void {
        const table = self.store.findConst(tableName) orelse return error.UnknownTable;
        var bodies = std.ArrayList([]u8).empty;
        defer {
            for (bodies.items) |body| self.allocator.free(body);
            bodies.deinit(self.allocator);
        }
        for (self.store.triggers.items) |trigger| {
            if (trigger.event == event and std.ascii.eqlIgnoreCase(trigger.table, tableName)) try bodies.append(self.allocator, try self.renderTriggerBody(trigger.body, table, event, newRow, oldRow));
        }
        for (bodies.items) |body| {
            var result = try self.execute(body, &.{});
            result.deinit();
        }
    }

    fn resolve(self: *Connection, expr: ast.Expr, parameters: []const Value) !Value {
        return self.evalContext(null, &.{}, expr, parameters, null);
    }

    fn copyValue(self: *Connection, value: Value) !Value {
        return switch (value) {
            .text => |bytes| .{ .text = try self.allocator.dupe(u8, bytes) },
            .blob => |bytes| .{ .blob = try self.allocator.dupe(u8, bytes) },
            else => value,
        };
    }

    fn freeResolvedTemps(self: *Connection, table: *const Table, row: []Value, columns: []const []const u8, rowExprs: []const ast.Expr) void {
        if (columns.len == 0) {
            for (rowExprs, 0..) |expr, index| {
                if (index >= row.len) break;
                if (expr == .binary or expr == .unary) self.freeConcatText(row[index]);
            }
            return;
        }
        for (columns, rowExprs) |name, expr| {
            if (expr != .binary and expr != .unary) continue;
            const index = columnIndex(table, name) catch continue;
            self.freeConcatText(row[index]);
        }
    }

    fn freeValueList(self: *Connection, seen: *std.ArrayList(Value)) void {
        for (seen.items) |value| switch (value) {
            .text => |bytes| self.allocator.free(bytes),
            .blob => |bytes| self.allocator.free(bytes),
            else => {},
        };
        seen.deinit(self.allocator);
    }

    fn noteDistinct(self: *Connection, seen: *std.ArrayList(Value), candidate: Value) !bool {
        for (seen.items) |prior| if (compare(prior, .equal, candidate)) return true;
        try seen.append(self.allocator, try self.copyValue(candidate));
        return false;
    }

    fn columnIndex(table: *const Table, name: []const u8) !usize {
        for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
        return error.UnknownColumn;
    }

    fn isNocase(collate: ?[]const u8) bool {
        if (collate) |name| return std.ascii.eqlIgnoreCase(name, "nocase");
        return false;
    }

    fn compare(left: Value, op: ast.CompareOp, right: Value) bool {
        return compareCollated(left, op, right, null);
    }

    fn compareCollated(left: Value, op: ast.CompareOp, right: Value, collate: ?[]const u8) bool {
        if (left == .null or right == .null) return false;
        if (isNocase(collate)) {
            if (left == .text and right == .text) {
                var li: usize = 0;
                var ri: usize = 0;
                const l = left.text;
                const r = right.text;
                while (li < l.len and ri < r.len) : ({
                    li += 1;
                    ri += 1;
                }) {
                    const a = std.ascii.toLower(l[li]);
                    const b = std.ascii.toLower(r[ri]);
                    if (a != b) {
                        const less = a < b;
                        return switch (op) {
                            .equal => false,
                            .notEqual => true,
                            .less => less,
                            .lessEqual => less,
                            .greater => !less,
                            .greaterEqual => !less,
                            else => false,
                        };
                    }
                }
                const result: i8 = if (l.len < r.len) -1 else if (l.len > r.len) 1 else 0;
                return switch (op) {
                    .equal => result == 0,
                    .notEqual => result != 0,
                    .less => result < 0,
                    .lessEqual => result <= 0,
                    .greater => result > 0,
                    .greaterEqual => result >= 0,
                    else => false,
                };
            }
        }
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
            .notEqual => result != 0,
            .less => result < 0,
            .lessEqual => result <= 0,
            .greater => result > 0,
            .greaterEqual => result >= 0,
            .like, .notLike, .glob, .notGlob, .regexp, .notRegexp, .match, .notMatch, .isNull, .isNotNull, .isValue, .isNotValue, .isDistinct, .isNotDistinct, .between, .notBetween, .in, .notIn, .exists, .notExists => false,
        };
    }

    fn matches(self: *Connection, table: *const Table, row: []const Value, condition: ?ast.Conditions, parameters: []const Value) anyerror!bool {
        return self.matchesContext(table, row, condition, parameters, null);
    }

    fn matchesContext(self: *Connection, table: *const Table, row: []const Value, condition: ?ast.Conditions, parameters: []const Value, outer: ?OuterRow) anyerror!bool {
        if (condition) |items| {
            var total = false;
            var group = true;
            var started = false;
            for (items) |item| {
                const itemResult = if (item.op == .exists or item.op == .notExists) blk: {
                    const sql = item.subquery orelse return error.InvalidSql;
                    var parser = try Parser.init(self.allocator, sql);
                    defer parser.deinit();
                    var statement = try parser.parse();
                    defer ast.deinit(self.allocator, &statement);
                    if (statement != .select) return error.InvalidSql;
                    const inner = statement.select;
                    const innerName = inner.table orelse return error.InvalidSql;
                    const innerTable = self.store.findConst(innerName) orelse return error.UnknownTable;
                    var found = false;
                    for (innerTable.rows.items) |innerRow| if (try self.matchesContext(innerTable, innerRow.values, inner.condition, parameters, .{ .table = table, .values = row })) {
                        found = true;
                        break;
                    };
                    break :blk if (item.op == .exists) found else !found;
                } else blk: {
                    const current = if (item.leftExpr) |left| try self.evalContext(table, row, left, parameters, outer) else currentColumn: {
                        const conditionColumn = if (std.mem.indexOfScalar(u8, item.column, '.')) |dot| item.column[dot + 1 ..] else item.column;
                        break :currentColumn row[try columnIndex(table, conditionColumn)];
                    };
                    defer if (item.leftExpr != null) self.freeConcatText(current);
                    const base: bool = if (item.op == .isNull) current == .null else if (item.op == .isNotNull) current != .null else if (item.op == .isValue) sameValue(current, try self.evalContext(table, row, item.value, parameters, outer)) else if (item.op == .isNotValue) !sameValue(current, try self.evalContext(table, row, item.value, parameters, outer)) else if (item.op == .isDistinct) !sameValue(current, try self.evalContext(table, row, item.value, parameters, outer)) else if (item.op == .isNotDistinct) sameValue(current, try self.evalContext(table, row, item.value, parameters, outer)) else if (item.op == .in and item.subquery != null) inSubquery: {
                        const sql = item.subquery orelse return error.InvalidSql;
                        var subquery = try self.execute(sql, parameters);
                        defer subquery.deinit();
                        var found = false;
                        if (subquery.columns.len == 1) for (subquery.rows) |subqueryRow| if (subqueryRow.len != 0 and compareCollated(current, .equal, subqueryRow[0], item.collate)) {
                            found = true;
                            break;
                        };
                        break :inSubquery found;
                    } else if (item.op == .notIn and item.subquery != null) notInSubquery: {
                        if (current == .null) break :notInSubquery false;
                        const sql = item.subquery orelse return error.InvalidSql;
                        var subquery = try self.execute(sql, parameters);
                        defer subquery.deinit();
                        var found = false;
                        if (subquery.columns.len == 1) for (subquery.rows) |subqueryRow| if (subqueryRow.len != 0 and compareCollated(current, .equal, subqueryRow[0], item.collate)) {
                            found = true;
                            break;
                        };
                        break :notInSubquery !found;
                    } else if ((item.op == .in or item.op == .notIn) and item.listValues.len != 0) listValues: {
                        if (current == .null) break :listValues false;
                        var found = false;
                        for (item.listValues) |candidate| if (compareCollated(current, .equal, try self.evalContext(table, row, candidate, parameters, outer), item.collate)) {
                            found = true;
                            break;
                        };
                        break :listValues if (item.op == .in) found else !found;
                    } else if (item.op == .between or item.op == .notBetween) betweenPattern: {
                        if (current == .null) break :betweenPattern false;
                        const inRange = compareCollated(current, .greaterEqual, try self.evalContext(table, row, item.value, parameters, outer), item.collate) and compareCollated(current, .lessEqual, try self.evalContext(table, row, item.value2 orelse return error.InvalidSql, parameters, outer), item.collate);
                        break :betweenPattern if (item.op == .between) inRange else !inRange;
                    } else if (item.op == .like or item.op == .notLike) likePattern: {
                        const pattern = try self.evalContext(table, row, item.value, parameters, outer);
                        var escapeValue: ?Value = null;
                        if (item.escape) |escapeExpr| escapeValue = try self.evalContext(table, row, escapeExpr, parameters, outer);
                        const tri = try self.evalPattern(current, pattern, escapeValue, false);
                        break :likePattern if (tri) |matched| (if (item.op == .like) matched else !matched) else false;
                    } else if (item.op == .glob or item.op == .notGlob) globPattern: {
                        const pattern = try self.evalContext(table, row, item.value, parameters, outer);
                        const tri = try self.evalPattern(current, pattern, null, true);
                        break :globPattern if (tri) |matched| (if (item.op == .glob) matched else !matched) else false;
                    } else if (item.op == .regexp or item.op == .notRegexp) regexpPattern: {
                        const pattern = try self.evalContext(table, row, item.value, parameters, outer);
                        const tri = try self.evalRegexp(current, pattern);
                        break :regexpPattern if (tri) |matched| (if (item.op == .regexp) matched else !matched) else false;
                    } else if (item.op == .match or item.op == .notMatch) matchPattern: {
                        const pattern = try self.evalContext(table, row, item.value, parameters, outer);
                        const tri = try self.evalMatch(current, pattern);
                        break :matchPattern if (tri) |matched| (if (item.op == .match) matched else !matched) else false;
                    } else compareCollated(current, item.op, try self.evalContext(table, row, item.value, parameters, outer), item.collate);
                    if (item.negated) {
                        if (base) break :blk false;
                        const nullSafe = item.op == .isNull or item.op == .isNotNull or item.op == .isValue or item.op == .isNotValue or item.op == .isDistinct or item.op == .isNotDistinct;
                        if (!nullSafe) {
                            if (current == .null) break :blk false;
                            const v = try self.evalContext(table, row, item.value, parameters, outer);
                            if (v == .null) break :blk false;
                            if (item.value2) |second| {
                                const w = try self.evalContext(table, row, second, parameters, outer);
                                if (w == .null) break :blk false;
                            }
                        }
                        break :blk true;
                    }
                    break :blk base;
                };
                if (!started) {
                    group = itemResult;
                    started = true;
                } else if (item.joinOr) {
                    total = total or group;
                    group = itemResult;
                } else {
                    group = group and itemResult;
                }
            }
            return total or group;
        }
        return true;
    }

    fn likeMatch(text: []const u8, pattern: []const u8) bool {
        return likeMatchEscape(text, pattern, null);
    }

    fn likeMatchEscape(text: []const u8, pattern: []const u8, escape: ?u8) bool {
        if (pattern.len == 0) return text.len == 0;
        if (escape) |esc| if (pattern[0] == esc) {
            if (pattern.len == 1) return false;
            return text.len != 0 and std.ascii.toLower(pattern[1]) == std.ascii.toLower(text[0]) and likeMatchEscape(text[1..], pattern[2..], escape);
        };
        if (pattern[0] == '%') {
            var index: usize = 0;
            while (index <= text.len) : (index += 1) if (likeMatchEscape(text[index..], pattern[1..], escape)) return true;
            return false;
        }
        if (pattern[0] == '_') return text.len != 0 and likeMatchEscape(text[1..], pattern[1..], escape);
        return text.len != 0 and std.ascii.toLower(pattern[0]) == std.ascii.toLower(text[0]) and likeMatchEscape(text[1..], pattern[1..], escape);
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

    const RegexEngine = struct {
        text: []const u8,
        pattern: []const u8,

        fn matchFull(text: []const u8, pattern: []const u8) bool {
            var engine = RegexEngine{ .text = text, .pattern = pattern };
            if (pattern.len != 0 and pattern[0] == '^') {
                engine.pattern = pattern[1..];
                return engine.matchAt(0, 0);
            }
            var start: usize = 0;
            while (true) {
                var attempt = engine;
                attempt.text = text[start..];
                if (attempt.matchAt(0, 0)) return true;
                if (start >= text.len) return false;
                start += 1;
            }
        }

        fn matchAt(self: *RegexEngine, ti: usize, pi: usize) bool {
            var t = ti;
            var p = pi;
            while (p < self.pattern.len) {
                if (p + 1 < self.pattern.len and self.pattern[p + 1] == '?') {
                    if (self.atomMatches(t, p)) {
                        var copy = self.*;
                        if (copy.matchAt(if (t < self.text.len) t + 1 else t, p + 2)) return true;
                    }
                    p += 2;
                    continue;
                }
                if (p + 1 < self.pattern.len and (self.pattern[p + 1] == '*' or self.pattern[p + 1] == '+')) {
                    const star = self.pattern[p + 1] == '*';
                    var count: usize = 0;
                    while (self.atomMatches(t, p)) {
                        t += 1;
                        count += 1;
                        if (t > self.text.len) break;
                    }
                    var back = count;
                    while (true) {
                        var copy = self.*;
                        if (copy.matchAt(t, p + 2)) return true;
                        if (back == 0 or (back == count and !star and count == 0)) break;
                        if (back == 0) break;
                        if (t == 0) break;
                        t -= 1;
                        back -= 1;
                        if (!star and back == 0) {
                            var once = self.*;
                            if (once.matchAt(t + 1, p + 2)) return true;
                            break;
                        }
                    }
                    return false;
                }
                if (p < self.pattern.len and self.pattern[p] == '$' and p + 1 == self.pattern.len) return t == self.text.len;
                if (self.pattern[p] == '|') return false;
                if (!self.atomMatches(t, p)) return false;
                t += 1;
                if (t > self.text.len) return false;
                p = self.atomNext(p);
            }
            return true;
        }

        fn atomNext(self: *RegexEngine, p: usize) usize {
            if (self.pattern[p] == '[') {
                var i = p + 1;
                if (i < self.pattern.len and self.pattern[i] == '^') i += 1;
                if (i < self.pattern.len and self.pattern[i] == ']') i += 1;
                while (i < self.pattern.len and self.pattern[i] != ']') : (i += 1) {}
                return @min(i + 1, self.pattern.len);
            }
            if (self.pattern[p] == '\\' and p + 1 < self.pattern.len) return p + 2;
            return p + 1;
        }

        fn atomMatches(self: *RegexEngine, t: usize, p: usize) bool {
            if (p >= self.pattern.len) return false;
            const c = self.pattern[p];
            if (c == '$' and p + 1 == self.pattern.len) return t == self.text.len;
            if (t >= self.text.len) return false;
            const tc = self.text[t];
            if (c == '.') return true;
            if (c == '[') {
                var i = p + 1;
                var neg = false;
                if (i < self.pattern.len and self.pattern[i] == '^') {
                    neg = true;
                    i += 1;
                }
                var hit = false;
                while (i < self.pattern.len and self.pattern[i] != ']') {
                    if (i + 2 < self.pattern.len and self.pattern[i + 1] == '-' and self.pattern[i + 2] != ']') {
                        if (tc >= self.pattern[i] and tc <= self.pattern[i + 2]) hit = true;
                        i += 3;
                    } else {
                        if (tc == self.pattern[i]) hit = true;
                        i += 1;
                    }
                }
                return if (neg) !hit else hit;
            }
            if (c == '\\' and p + 1 < self.pattern.len) {
                const e = self.pattern[p + 1];
                if (e == 'd') return tc >= '0' and tc <= '9';
                if (e == 'w') return std.ascii.isAlphanumeric(tc) or tc == '_';
                if (e == 's') return tc == ' ' or tc == '\t' or tc == '\n' or tc == '\r';
                return tc == e;
            }
            return tc == c;
        }
    };

    fn regexpMatches(text: []const u8, pattern: []const u8) bool {
        if (std.mem.indexOfScalar(u8, pattern, '|')) |bar| {
            if (regexpMatches(text, pattern[0..bar])) return true;
            return regexpMatches(text, pattern[bar + 1 ..]);
        }
        var depth: usize = 0;
        var start: ?usize = null;
        var pi: usize = 0;
        while (pi < pattern.len) : (pi += 1) {
            if (pattern[pi] == '(') {
                if (depth == 0) start = pi;
                depth += 1;
            } else if (pattern[pi] == ')') {
                if (depth > 0) {
                    depth -= 1;
                    if (depth == 0) {
                        if (regexpMatches(text, pattern[start.? + 1 .. pi])) return true;
                    }
                }
            }
        }
        return RegexEngine.matchFull(text, pattern);
    }

    fn matchContains(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var ok = true;
            for (needle, 0..) |b, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(b)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    fn eval(self: *Connection, table: *const Table, row: []const Value, expr: ast.Expr, parameters: []const Value) !Value {
        return self.evalContext(table, row, expr, parameters, null);
    }

    const Numeric = struct { isInt: bool, i: i64, r: f64 };

    fn numericValue(value: Value) ?Numeric {
        return switch (value) {
            .null => null,
            .integer => |n| .{ .isInt = true, .i = n, .r = 0 },
            .real => |n| .{ .isInt = false, .i = 0, .r = n },
            .text => |bytes| parseNumericText(bytes),
            .blob => |bytes| parseNumericText(bytes),
        };
    }

    fn parseNumericText(bytes: []const u8) Numeric {
        var i: usize = 0;
        while (i < bytes.len and isSpaceByte(bytes[i])) i += 1;
        const numStart = i;
        if (i < bytes.len and (bytes[i] == '+' or bytes[i] == '-')) i += 1;
        const intStart = i;
        while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') i += 1;
        const hasIntDigits = i > intStart;
        var isFloat = false;
        if (i < bytes.len and bytes[i] == '.') {
            var j = i + 1;
            while (j < bytes.len and bytes[j] >= '0' and bytes[j] <= '9') j += 1;
            if (j > i + 1) {
                isFloat = true;
                i = j;
            }
        }
        if (i < bytes.len and (bytes[i] == 'e' or bytes[i] == 'E') and (hasIntDigits or isFloat)) {
            var j = i + 1;
            if (j < bytes.len and (bytes[j] == '+' or bytes[j] == '-')) j += 1;
            const expStart = j;
            while (j < bytes.len and bytes[j] >= '0' and bytes[j] <= '9') j += 1;
            if (j > expStart) {
                isFloat = true;
                i = j;
            }
        }
        if (!hasIntDigits and !isFloat) return .{ .isInt = false, .i = 0, .r = 0 };
        const token = bytes[numStart..i];
        if (!isFloat) {
            if (std.fmt.parseInt(i64, token, 10)) |n| return .{ .isInt = true, .i = n, .r = 0 } else |_| {}
            if (std.fmt.parseFloat(f64, token)) |n| return .{ .isInt = false, .i = 0, .r = n } else |_| {}
            return .{ .isInt = false, .i = 0, .r = 0 };
        }
        if (std.fmt.parseFloat(f64, token)) |n| return .{ .isInt = false, .i = 0, .r = n } else |_| {}
        return .{ .isInt = false, .i = 0, .r = 0 };
    }

    fn isSpaceByte(byte: u8) bool {
        return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
    }

    fn intValue(value: Value) ?i64 {
        const numeric = numericValue(value) orelse return null;
        if (numeric.isInt) return numeric.i;
        if (!std.math.isFinite(numeric.r)) return if (numeric.r > 0) std.math.maxInt(i64) else std.math.minInt(i64);
        return @as(i64, @intFromFloat(numeric.r));
    }

    fn isTruthy(value: Value) bool {
        return switch (value) {
            .integer => |n| n != 0,
            .real => |n| n != 0,
            else => false,
        };
    }

    fn realText(self: *Connection, number: f64) ![]u8 {
        const rendered = try std.fmt.allocPrint(self.allocator, "{d}", .{number});
        errdefer self.allocator.free(rendered);
        for (rendered) |byte| if (byte == '.' or byte == 'e' or byte == 'E') return rendered;
        const withDot = try std.fmt.allocPrint(self.allocator, "{s}.0", .{rendered});
        self.allocator.free(rendered);
        return withDot;
    }

    fn stringifyValue(self: *Connection, value: Value) !Value {
        return switch (value) {
            .null => .null,
            .integer => |n| .{ .text = try std.fmt.allocPrint(self.allocator, "{d}", .{n}) },
            .real => |n| .{ .text = try self.realText(n) },
            .text => |bytes| .{ .text = try self.allocator.dupe(u8, bytes) },
            .blob => |bytes| .{ .blob = try self.allocator.dupe(u8, bytes) },
        };
    }

    fn freeBinaryOwned(expr: ast.Expr, value: Value, allocator: std.mem.Allocator) void {
        if (expr == .binary and (value == .text or value == .blob)) {
            if (value == .text) allocator.free(value.text) else allocator.free(value.blob);
        }
    }

    fn evalBinary(self: *Connection, table: ?*const Table, row: []const Value, binary: anytype, parameters: []const Value, outer: ?OuterRow) anyerror!Value {
        const left = try self.evalContext(table, row, binary.left.*, parameters, outer);
        const right = try self.evalContext(table, row, binary.right.*, parameters, outer);
        defer freeBinaryOwned(binary.left.*, left, self.allocator);
        defer freeBinaryOwned(binary.right.*, right, self.allocator);
        if (binary.op == .logicalAnd or binary.op == .logicalOr) {
            const l = if (left == .null) false else isTruthy(left);
            const r = if (right == .null) false else isTruthy(right);
            if (left == .null or right == .null) {
                if (binary.op == .logicalAnd) {
                    if (!l or !r) return .{ .integer = 0 };
                    return .null;
                } else {
                    if (l or r) return .{ .integer = 1 };
                    return .null;
                }
            }
            return .{ .integer = if (binary.op == .logicalAnd) (if (l and r) 1 else 0) else (if (l or r) 1 else 0) };
        }
        if (binary.op == .concat) {
            if (left == .null or right == .null) return .null;
            const leftText = try self.stringifyValue(left);
            errdefer self.freeConcatText(leftText);
            const rightText = try self.stringifyValue(right);
            errdefer self.freeConcatText(rightText);
            if (leftText == .blob or rightText == .blob) {
                const leftBytes = if (leftText == .blob) leftText.blob else leftText.text;
                const rightBytes = if (rightText == .blob) rightText.blob else rightText.text;
                var output = try self.allocator.alloc(u8, leftBytes.len + rightBytes.len);
                errdefer self.allocator.free(output);
                @memcpy(output[0..leftBytes.len], leftBytes);
                @memcpy(output[leftBytes.len..], rightBytes);
                self.freeConcatText(leftText);
                self.freeConcatText(rightText);
                return .{ .blob = output };
            }
            const leftBytes = switch (leftText) {
                .text => |bytes| bytes,
                .blob => |bytes| bytes,
                else => return .null,
            };
            const rightBytes = switch (rightText) {
                .text => |bytes| bytes,
                .blob => |bytes| bytes,
                else => return .null,
            };
            const output = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ leftBytes, rightBytes });
            errdefer self.allocator.free(output);
            self.freeConcatText(leftText);
            self.freeConcatText(rightText);
            return if (leftText == .blob or rightText == .blob) .{ .blob = output } else .{ .text = output };
        }
        if (left == .null or right == .null) return .null;
        if (binary.op == .equal or binary.op == .notEqual or binary.op == .less or binary.op == .lessEqual or binary.op == .greater or binary.op == .greaterEqual) {
            const op: ast.CompareOp = switch (binary.op) {
                .equal => .equal,
                .notEqual => .notEqual,
                .less => .less,
                .lessEqual => .lessEqual,
                .greater => .greater,
                .greaterEqual => .greaterEqual,
                else => return error.InvalidSql,
            };
            return .{ .integer = if (compare(left, op, right)) 1 else 0 };
        }
        const leftNum = numericValue(left).?;
        const rightNum = numericValue(right).?;
        if (binary.op == .bitAnd or binary.op == .bitOr) {
            const a = intValue(left).?;
            const b = intValue(right).?;
            return .{ .integer = if (binary.op == .bitAnd) a & b else a | b };
        }
        if (binary.op == .shiftLeft or binary.op == .shiftRight) {
            var amount = intValue(right).?;
            const value = intValue(left).?;
            var op = binary.op;
            if (amount < 0) {
                op = if (op == .shiftLeft) .shiftRight else .shiftLeft;
                amount = if (amount > -64) -amount else 64;
            }
            if (amount >= 64) return .{ .integer = if (value >= 0 or op == .shiftLeft) 0 else -1 };
            const bits = @as(u64, @bitCast(value));
            if (op == .shiftLeft) return .{ .integer = @as(i64, @bitCast(bits << @as(u6, @intCast(amount)))) };
            return .{ .integer = value >> @as(u6, @intCast(amount)) };
        }
        if (leftNum.isInt and rightNum.isInt) {
            const a = leftNum.i;
            const b = rightNum.i;
            switch (binary.op) {
                .add => {
                    const sum = @addWithOverflow(a, b);
                    if (sum[1] == 0) return .{ .integer = sum[0] };
                    return .{ .real = @as(f64, @floatFromInt(a)) + @as(f64, @floatFromInt(b)) };
                },
                .subtract => {
                    const diff = @subWithOverflow(a, b);
                    if (diff[1] == 0) return .{ .integer = diff[0] };
                    return .{ .real = @as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b)) };
                },
                .multiply => {
                    const prod = @mulWithOverflow(a, b);
                    if (prod[1] == 0) return .{ .integer = prod[0] };
                    return .{ .real = @as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(b)) };
                },
                .divide => {
                    if (b == 0) return .null;
                    if (b == -1 and a == std.math.minInt(i64)) return .{ .real = 9223372036854775808.0 };
                    return .{ .integer = @divTrunc(a, b) };
                },
                .modulo => {
                    if (b == 0) return .null;
                    const divisor = if (b == -1) @as(i64, 1) else b;
                    return .{ .integer = @rem(a, divisor) };
                },
                else => return error.InvalidSql,
            }
        }
        const a = if (leftNum.isInt) @as(f64, @floatFromInt(leftNum.i)) else leftNum.r;
        const b = if (rightNum.isInt) @as(f64, @floatFromInt(rightNum.i)) else rightNum.r;
        switch (binary.op) {
            .add => return .{ .real = a + b },
            .subtract => return .{ .real = a - b },
            .multiply => return .{ .real = a * b },
            .divide => {
                if (b == 0) return .null;
                const quotient = a / b;
                if (std.math.isNan(quotient)) return .null;
                return .{ .real = quotient };
            },
            .modulo => {
                const divisor = intValue(right).?;
                if (divisor == 0) return .null;
                const safe = if (divisor == -1) @as(i64, 1) else divisor;
                const dividend = intValue(left).?;
                return .{ .real = @as(f64, @floatFromInt(@rem(dividend, safe))) };
            },
            else => return error.InvalidSql,
        }
    }

    fn likeOperand(self: *Connection, value: Value) !Value {
        if (value == .null) return .null;
        if (value == .text) return .{ .text = try self.allocator.dupe(u8, value.text) };
        if (value == .blob) return .{ .text = try self.allocator.dupe(u8, value.blob) };
        return self.stringifyValue(value);
    }

    fn evalPattern(self: *Connection, current: Value, pattern: Value, escape: ?Value, glob: bool) !?bool {
        const currentText = try self.likeOperand(current);
        errdefer self.freeConcatText(currentText);
        const patternText = try self.likeOperand(pattern);
        errdefer self.freeConcatText(patternText);
        var escapeChar: ?u8 = null;
        if (escape) |escapeValue| {
            if (escapeValue != .text or escapeValue.text.len != 1) {
                return error.InvalidSql;
            }
            escapeChar = escapeValue.text[0];
        }
        if (currentText == .null or patternText == .null) {
            self.freeConcatText(currentText);
            self.freeConcatText(patternText);
            return null;
        }
        const matched = if (glob) globMatch(currentText.text, patternText.text) else likeMatchEscape(currentText.text, patternText.text, escapeChar);
        self.freeConcatText(currentText);
        self.freeConcatText(patternText);
        return matched;
    }

    fn evalRegexp(self: *Connection, current: Value, pattern: Value) !?bool {
        const currentText = try self.likeOperand(current);
        errdefer self.freeConcatText(currentText);
        const patternText = try self.likeOperand(pattern);
        errdefer self.freeConcatText(patternText);
        if (currentText == .null or patternText == .null) {
            self.freeConcatText(currentText);
            self.freeConcatText(patternText);
            return null;
        }
        const matched = regexpMatches(currentText.text, patternText.text);
        self.freeConcatText(currentText);
        self.freeConcatText(patternText);
        return matched;
    }

    fn evalMatch(self: *Connection, current: Value, pattern: Value) !?bool {
        const currentText = try self.likeOperand(current);
        errdefer self.freeConcatText(currentText);
        const patternText = try self.likeOperand(pattern);
        errdefer self.freeConcatText(patternText);
        if (currentText == .null or patternText == .null) {
            self.freeConcatText(currentText);
            self.freeConcatText(patternText);
            return null;
        }
        const matched = matchContains(currentText.text, patternText.text);
        self.freeConcatText(currentText);
        self.freeConcatText(patternText);
        return matched;
    }

    fn freeConcatText(self: *Connection, value: Value) void {
        switch (value) {
            .text => |bytes| self.allocator.free(bytes),
            .blob => |bytes| self.allocator.free(bytes),
            else => {},
        }
    }

    fn evalContext(self: *Connection, table: ?*const Table, row: []const Value, expr: ast.Expr, parameters: []const Value, outer: ?OuterRow) !Value {
        return switch (expr) {
            .literal => |value| value,
            .parameter => |index| if (index == 0 or index > parameters.len) error.InvalidParameter else parameters[index - 1],
            .identifier => |name| {
                const concrete = table orelse return error.InvalidSql;
                const excludedPrefix = "excluded.";
                const columnName = if (name.len > excludedPrefix.len and std.ascii.eqlIgnoreCase(name[0..excludedPrefix.len], excludedPrefix)) name[excludedPrefix.len..] else name;
                if (outer) |context| if (std.mem.indexOfScalar(u8, columnName, '.')) |dot| {
                    const tableName = columnName[0..dot];
                    if (std.ascii.eqlIgnoreCase(tableName, context.table.name)) return context.values[try columnIndex(context.table, columnName[dot + 1 ..])];
                };
                return row[try columnIndex(concrete, columnName)];
            },
            .wildcard => error.InvalidSql,
            .binary => |binary| try self.evalBinary(table, row, binary, parameters, outer),
            .collate => |node| try self.evalContext(table, row, node.expr.*, parameters, outer),
            .patternMatch => |match| blk: {
                const value = try self.evalContext(table, row, match.value.*, parameters, outer);
                const pattern = try self.evalContext(table, row, match.pattern.*, parameters, outer);
                if (match.isRegexp) {
                    if (try self.evalRegexp(value, pattern)) |matched| {
                        break :blk .{ .integer = if (matched == !match.negated) 1 else 0 };
                    }
                    break :blk .null;
                }
                if (match.isMatch) {
                    if (try self.evalMatch(value, pattern)) |matched| {
                        break :blk .{ .integer = if (matched == !match.negated) 1 else 0 };
                    }
                    break :blk .null;
                }
                var escapeValue: ?Value = null;
                if (match.escape) |escape| escapeValue = try self.evalContext(table, row, escape.*, parameters, outer);
                if (try self.evalPattern(value, pattern, escapeValue, match.glob)) |matched| {
                    break :blk .{ .integer = if (matched == !match.negated) 1 else 0 };
                }
                break :blk .null;
            },
            .unary => |unary| blk: {
                if (unary.op == .logicalNot) {
                    const operand = try self.evalContext(table, row, unary.expr.*, parameters, outer);
                    if (operand == .null) break :blk .null;
                    break :blk .{ .integer = if (isTruthy(operand)) 0 else 1 };
                }
                const operand = try self.evalContext(table, row, unary.expr.*, parameters, outer);
                if (operand == .null) break :blk .null;
                break :blk switch (unary.op) {
                    .negate => blkNeg: {
                        const numeric = numericValue(operand).?;
                        if (!numeric.isInt) break :blkNeg Value{ .real = -numeric.r };
                        if (numeric.i == std.math.minInt(i64)) break :blkNeg Value{ .real = 9223372036854775808.0 };
                        break :blkNeg Value{ .integer = -numeric.i };
                    },
                    .positive => blkPos: {
                        const numeric = numericValue(operand).?;
                        break :blkPos if (numeric.isInt) Value{ .integer = numeric.i } else Value{ .real = numeric.r };
                    },
                    .bitNot => .{ .integer = ~intValue(operand).? },
                    .logicalNot => .{ .integer = if (isTruthy(operand)) 0 else 1 },
                };
            },
            .caseExpr => |caseBlock| blk: {
                if (caseBlock.base) |base| {
                    const baseValue = try self.evalContext(table, row, base.*, parameters, outer);
                    for (caseBlock.whens) |when| {
                        const candidate = try self.evalContext(table, row, when.condition, parameters, outer);
                        if (compare(baseValue, .equal, candidate)) break :blk try self.evalContext(table, row, when.result, parameters, outer);
                    }
                } else {
                    for (caseBlock.whens) |when| {
                        if (isTruthy(try self.evalContext(table, row, when.condition, parameters, outer))) break :blk try self.evalContext(table, row, when.result, parameters, outer);
                    }
                }
                if (caseBlock.otherwise) |otherwise| break :blk try self.evalContext(table, row, otherwise.*, parameters, outer);
                break :blk .null;
            },
            .function => |call| blk: {
                if (call.distinct) return error.Unsupported;
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
                    .integer => |n| if (call.argument2 == null) .{ .integer = n } else blkRound: {
                        const precisionValue = try self.evalContext(table, row, call.argument2.?.*, parameters, outer);
                        if (precisionValue != .integer) break :blkRound .null;
                        var factor: f64 = 1;
                        if (precisionValue.integer >= 0) {
                            var count: i64 = 0;
                            while (count < precisionValue.integer) : (count += 1) factor *= 10;
                        } else {
                            var count: i64 = 0;
                            while (count > precisionValue.integer) : (count -= 1) factor /= 10;
                        }
                        break :blkRound .{ .real = std.math.round(@as(f64, @floatFromInt(n)) * factor) / factor };
                    },
                    .real => |n| if (call.argument2) |precisionExpr| blkRound: {
                        const precisionValue = try self.evalContext(table, row, precisionExpr.*, parameters, outer);
                        if (precisionValue != .integer) break :blkRound .null;
                        var factor: f64 = 1;
                        if (precisionValue.integer >= 0) {
                            var count: i64 = 0;
                            while (count < precisionValue.integer) : (count += 1) factor *= 10;
                        } else {
                            var count: i64 = 0;
                            while (count > precisionValue.integer) : (count -= 1) factor /= 10;
                        }
                        break :blkRound .{ .real = std.math.round(n * factor) / factor };
                    } else .{ .real = std.math.round(n) },
                    else => .null,
                };
                if (std.ascii.eqlIgnoreCase(call.name, "typeof")) break :blk .{ .text = argument.typeName() };
                if (std.ascii.eqlIgnoreCase(call.name, "cast")) {
                    const target = call.argument2 orelse return error.InvalidSql;
                    const targetName = switch (target.*) {
                        .identifier => |name| name,
                        else => return error.InvalidSql,
                    };
                    if (std.ascii.eqlIgnoreCase(targetName, "integer") or std.ascii.eqlIgnoreCase(targetName, "int")) break :blk switch (argument) {
                        .integer => argument,
                        .real => |n| .{ .integer = @intFromFloat(n) },
                        .text => |text| .{ .integer = std.fmt.parseInt(i64, text, 10) catch 0 },
                        else => .null,
                    };
                    if (std.ascii.eqlIgnoreCase(targetName, "real") or std.ascii.eqlIgnoreCase(targetName, "float")) break :blk switch (argument) {
                        .integer => |n| .{ .real = @floatFromInt(n) },
                        .real => argument,
                        .text => |text| .{ .real = std.fmt.parseFloat(f64, text) catch 0 },
                        else => .null,
                    };
                    if (std.ascii.eqlIgnoreCase(targetName, "text")) break :blk switch (argument) {
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
                        if (call.argument2) |charsExpr| {
                            const chars = try self.evalContext(table, row, charsExpr.*, parameters, outer);
                            if (chars != .text) break :blk .null;
                            var start: usize = 0;
                            var end: usize = argument.text.len;
                            if (!std.ascii.eqlIgnoreCase(call.name, "rtrim")) while (start < end and std.mem.indexOfScalar(u8, chars.text, argument.text[start]) != null) : (start += 1) {};
                            if (!std.ascii.eqlIgnoreCase(call.name, "ltrim")) while (end > start and std.mem.indexOfScalar(u8, chars.text, argument.text[end - 1]) != null) : (end -= 1) {};
                            break :blk .{ .text = try self.allocator.dupe(u8, argument.text[start..end]) };
                        }
                        var start: usize = 0;
                        var end: usize = argument.text.len;
                        if (!std.ascii.eqlIgnoreCase(call.name, "rtrim")) while (start < end and std.ascii.isWhitespace(argument.text[start])) : (start += 1) {};
                        if (!std.ascii.eqlIgnoreCase(call.name, "ltrim")) while (end > start and std.ascii.isWhitespace(argument.text[end - 1])) : (end -= 1) {};
                        break :blk .{ .text = try self.allocator.dupe(u8, argument.text[start..end]) };
                    }
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "substr") or std.ascii.eqlIgnoreCase(call.name, "substring")) {
                    const startExpr = call.argument2 orelse return error.InvalidSql;
                    const sourceText: ?[]const u8 = switch (argument) {
                        .text => |b| b,
                        .blob => |b| b,
                        else => null,
                    };
                    if (sourceText) |bytes| {
                        const startVal = try self.evalContext(table, row, startExpr.*, parameters, outer);
                        if (startVal != .integer) break :blk .null;
                        var startIndex: usize = undefined;
                        if (startVal.integer > 0) {
                            startIndex = @min(@as(usize, @intCast(startVal.integer - 1)), bytes.len);
                        } else if (startVal.integer < 0) {
                            const fromEnd: usize = @intCast(-startVal.integer);
                            startIndex = if (fromEnd > bytes.len) 0 else bytes.len - fromEnd;
                        } else {
                            startIndex = 0;
                        }
                        if (startVal.integer == 0) startIndex = 0;
                        var end = bytes.len;
                        if (call.argument3) |lenExpr| {
                            const lenVal = try self.evalContext(table, row, lenExpr.*, parameters, outer);
                            if (lenVal != .integer) break :blk .null;
                            if (lenVal.integer <= 0) {
                                if (argument == .blob) break :blk .{ .blob = try self.allocator.dupe(u8, "") };
                                break :blk .{ .text = try self.allocator.dupe(u8, "") };
                            }
                            end = @min(bytes.len, startIndex + @as(usize, @intCast(lenVal.integer)));
                            if (startVal.integer == 0) end = @min(bytes.len, @as(usize, @intCast(lenVal.integer)));
                        }
                        if (argument == .blob) break :blk .{ .blob = try self.allocator.dupe(u8, bytes[startIndex..end]) };
                        break :blk .{ .text = try self.allocator.dupe(u8, bytes[startIndex..end]) };
                    }
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "replace")) {
                    const oldExpr = call.argument2 orelse return error.InvalidSql;
                    const newExpr = call.argument3 orelse return error.InvalidSql;
                    const old = try self.evalContext(table, row, oldExpr.*, parameters, outer);
                    const replacement = try self.evalContext(table, row, newExpr.*, parameters, outer);
                    if (argument == .text and old == .text and replacement == .text) {
                        if (old.text.len == 0) break :blk argument;
                        var output = std.ArrayList(u8).empty;
                        defer output.deinit(self.allocator);
                        var offset: usize = 0;
                        while (std.mem.indexOfPos(u8, argument.text, offset, old.text)) |found| {
                            try output.appendSlice(self.allocator, argument.text[offset..found]);
                            try output.appendSlice(self.allocator, replacement.text);
                            offset = found + old.text.len;
                        }
                        try output.appendSlice(self.allocator, argument.text[offset..]);
                        break :blk .{ .text = try output.toOwnedSlice(self.allocator) };
                    }
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "hex")) {
                    const toHex = switch (argument) {
                        .text => |b| b,
                        .blob => |b| b,
                        else => null,
                    };
                    if (toHex) |bytes| {
                        const digits = "0123456789ABCDEF";
                        var out = try self.allocator.alloc(u8, bytes.len * 2);
                        for (bytes, 0..) |b, i| {
                            out[i * 2] = digits[b >> 4];
                            out[i * 2 + 1] = digits[b & 15];
                        }
                        break :blk .{ .text = out };
                    }
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "quote")) {
                    switch (argument) {
                        .null => break :blk .{ .text = try self.allocator.dupe(u8, "NULL") },
                        .integer => |n| break :blk .{ .text = try std.fmt.allocPrint(self.allocator, "{d}", .{n}) },
                        .real => |n| break :blk .{ .text = try self.realText(n) },
                        .text => |b| {
                            var out = std.ArrayList(u8).empty;
                            defer out.deinit(self.allocator);
                            try out.append(self.allocator, '\'');
                            for (b) |ch| {
                                if (ch == '\'') try out.append(self.allocator, '\'');
                                try out.append(self.allocator, ch);
                            }
                            try out.append(self.allocator, '\'');
                            break :blk .{ .text = try out.toOwnedSlice(self.allocator) };
                        },
                        .blob => |b| {
                            const digits = "0123456789ABCDEF";
                            var out = std.ArrayList(u8).empty;
                            defer out.deinit(self.allocator);
                            try out.appendSlice(self.allocator, "X'");
                            for (b) |ch| {
                                try out.append(self.allocator, digits[ch >> 4]);
                                try out.append(self.allocator, digits[ch & 15]);
                            }
                            try out.append(self.allocator, '\'');
                            break :blk .{ .text = try out.toOwnedSlice(self.allocator) };
                        },
                    }
                }
                if (std.ascii.eqlIgnoreCase(call.name, "unicode")) {
                    if (argument == .text and argument.text.len != 0) {
                        const len = std.unicode.utf8ByteSequenceLength(argument.text[0]) catch 1;
                        const cp = std.unicode.utf8Decode(argument.text[0..@min(len, argument.text.len)]) catch argument.text[0];
                        break :blk .{ .integer = @intCast(cp) };
                    }
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "char")) {
                    var out = std.ArrayList(u8).empty;
                    defer out.deinit(self.allocator);
                    var buf: [4]u8 = undefined;
                    const first = try self.evalContext(table, row, call.argument.*, parameters, outer);
                    const codes = [_]Value{first};
                    var extra: [2]?*const ast.Expr = .{ call.argument2, call.argument3 };
                    _ = &extra;
                    for (codes) |code| {
                        if (code != .integer) break :blk .null;
                        const len = std.unicode.utf8Encode(@intCast(code.integer), &buf) catch break :blk .null;
                        try out.appendSlice(self.allocator, buf[0..len]);
                    }
                    if (call.argument2) |second| {
                        const code = try self.evalContext(table, row, second.*, parameters, outer);
                        if (code != .integer) break :blk .null;
                        const len = std.unicode.utf8Encode(@intCast(code.integer), &buf) catch break :blk .null;
                        try out.appendSlice(self.allocator, buf[0..len]);
                    }
                    if (call.argument3) |third| {
                        const code = try self.evalContext(table, row, third.*, parameters, outer);
                        if (code != .integer) break :blk .null;
                        const len = std.unicode.utf8Encode(@intCast(code.integer), &buf) catch break :blk .null;
                        try out.appendSlice(self.allocator, buf[0..len]);
                    }
                    break :blk .{ .text = try out.toOwnedSlice(self.allocator) };
                }
                if (std.ascii.eqlIgnoreCase(call.name, "printf") or std.ascii.eqlIgnoreCase(call.name, "format")) {
                    const fmtVal = argument;
                    if (fmtVal != .text) break :blk .null;
                    var out = std.ArrayList(u8).empty;
                    defer out.deinit(self.allocator);
                    var args: [3]?Value = .{ null, null, null };
                    if (call.argument2) |s| args[0] = try self.evalContext(table, row, s.*, parameters, outer);
                    if (call.argument3) |t| args[1] = try self.evalContext(table, row, t.*, parameters, outer);
                    var argIdx: usize = 0;
                    var fi: usize = 0;
                    while (fi < fmtVal.text.len) : (fi += 1) {
                        if (fmtVal.text[fi] == '%' and fi + 1 < fmtVal.text.len) {
                            const spec = fmtVal.text[fi + 1];
                            if (spec == '%') {
                                try out.append(self.allocator, '%');
                                fi += 1;
                                continue;
                            }
                            if ((spec == 'd' or spec == 's' or spec == 'f') and argIdx < args.len and args[argIdx] != null) {
                                const v = args[argIdx].?;
                                argIdx += 1;
                                if (spec == 'd') {
                                    const s = try self.stringifyValue(if (v == .real) Value{ .integer = @intFromFloat(v.real) } else v);
                                    defer self.freeConcatText(s);
                                    if (s == .text) try out.appendSlice(self.allocator, s.text) else if (s == .blob) try out.appendSlice(self.allocator, s.blob);
                                } else if (spec == 's') {
                                    const s = try self.stringifyValue(v);
                                    defer self.freeConcatText(s);
                                    if (s == .text) try out.appendSlice(self.allocator, s.text) else if (s == .blob) try out.appendSlice(self.allocator, s.blob);
                                } else {
                                    const f: f64 = switch (v) {
                                        .integer => |n| @floatFromInt(n),
                                        .real => |n| n,
                                        else => 0,
                                    };
                                    const s = try std.fmt.allocPrint(self.allocator, "{d}", .{f});
                                    defer self.allocator.free(s);
                                    try out.appendSlice(self.allocator, s);
                                }
                                fi += 1;
                                continue;
                            }
                        }
                        try out.append(self.allocator, fmtVal.text[fi]);
                    }
                    break :blk .{ .text = try out.toOwnedSlice(self.allocator) };
                }
                if (std.ascii.eqlIgnoreCase(call.name, "instr")) {
                    const needleExpr = call.argument2 orelse return error.InvalidSql;
                    const needle = try self.evalContext(table, row, needleExpr.*, parameters, outer);
                    if (argument == .text and needle == .text) {
                        const position = std.mem.indexOf(u8, argument.text, needle.text) orelse break :blk .{ .integer = 0 };
                        break :blk .{ .integer = @intCast(position + 1) };
                    }
                    break :blk .null;
                }
                if (std.ascii.eqlIgnoreCase(call.name, "json_extract")) {
                    const pathExpr = call.argument2 orelse return error.InvalidSql;
                    const path = try self.evalContext(table, row, pathExpr.*, parameters, outer);
                    break :blk try self.extractJsonTopLevel(argument, path);
                }
                if (std.ascii.eqlIgnoreCase(call.name, "nullif")) {
                    const secondExpr = call.argument2 orelse return error.InvalidSql;
                    const second = try self.evalContext(table, row, secondExpr.*, parameters, outer);
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
            const keyStart = cursor + 1;
            const keyEnd = std.mem.indexOfScalarPos(u8, source.text, keyStart, '"') orelse break;
            if (!std.mem.eql(u8, source.text[keyStart..keyEnd], key)) {
                cursor = keyEnd;
                continue;
            }
            var valueStart = keyEnd + 1;
            while (valueStart < source.text.len and (source.text[valueStart] == ' ' or source.text[valueStart] == '\t' or source.text[valueStart] == ':')) : (valueStart += 1) {}
            if (valueStart >= source.text.len) break;
            if (source.text[valueStart] == '"') {
                const textStart = valueStart + 1;
                const textEnd = std.mem.indexOfScalarPos(u8, source.text, textStart, '"') orelse break;
                return .{ .text = try self.allocator.dupe(u8, source.text[textStart..textEnd]) };
            }
            const valueEnd = std.mem.indexOfAnyPos(u8, source.text, valueStart, ",}") orelse source.text.len;
            const raw = std.mem.trim(u8, source.text[valueStart..valueEnd], " \t\r\n");
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
                const pathExpr = call.argument2 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const path = try self.eval(table, row, pathExpr.*, parameters);
                if (source == .text and path == .text and std.mem.startsWith(u8, path.text, "$.")) {
                    const key = path.text[2..];
                    var cursor: usize = 0;
                    while (cursor < source.text.len) : (cursor += 1) {
                        if (source.text[cursor] != '"') continue;
                        const keyStart = cursor + 1;
                        const keyEnd = std.mem.indexOfScalarPos(u8, source.text, keyStart, '"') orelse break;
                        if (!std.mem.eql(u8, source.text[keyStart..keyEnd], key)) {
                            cursor = keyEnd;
                            continue;
                        }
                        var valueStart = keyEnd + 1;
                        while (valueStart < source.text.len and (source.text[valueStart] == ' ' or source.text[valueStart] == '\t' or source.text[valueStart] == ':')) : (valueStart += 1) {}
                        if (valueStart >= source.text.len) break;
                        if (source.text[valueStart] == '"') {
                            const textStart = valueStart + 1;
                            const textEnd = std.mem.indexOfScalarPos(u8, source.text, textStart, '"') orelse break;
                            return .{ .text = try self.allocator.dupe(u8, source.text[textStart..textEnd]) };
                        }
                        const valueEnd = std.mem.indexOfAnyPos(u8, source.text, valueStart, ",}") orelse source.text.len;
                        const raw = std.mem.trim(u8, source.text[valueStart..valueEnd], " \t\r\n");
                        if (std.mem.eql(u8, raw, "null")) return .null;
                        if (std.fmt.parseInt(i64, raw, 10)) |number| return .{ .integer = number } else |_| {}
                        if (std.fmt.parseFloat(f64, raw)) |number| return .{ .real = number } else |_| {}
                        return .null;
                    }
                }
                return .null;
            }
            if (std.ascii.eqlIgnoreCase(call.name, "json_set")) {
                const pathExpr = call.argument2 orelse return error.InvalidSql;
                const valueExpr = call.argument3 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const path = try self.eval(table, row, pathExpr.*, parameters);
                const replacement = try self.eval(table, row, valueExpr.*, parameters);
                if (source == .text and path == .text and replacement == .text and std.mem.startsWith(u8, path.text, "$.")) {
                    const key = path.text[2..];
                    var cursor: usize = 0;
                    while (cursor < source.text.len) : (cursor += 1) {
                        if (source.text[cursor] != '"') continue;
                        const keyStart = cursor + 1;
                        const keyEnd = std.mem.indexOfScalarPos(u8, source.text, keyStart, '"') orelse break;
                        if (!std.mem.eql(u8, source.text[keyStart..keyEnd], key)) {
                            cursor = keyEnd;
                            continue;
                        }
                        var valueStart = keyEnd + 1;
                        while (valueStart < source.text.len and (source.text[valueStart] == ' ' or source.text[valueStart] == '\t' or source.text[valueStart] == ':')) : (valueStart += 1) {}
                        const valueEnd = if (valueStart < source.text.len and source.text[valueStart] == '"') (std.mem.indexOfScalarPos(u8, source.text, valueStart + 1, '"') orelse return .null) + 1 else (std.mem.indexOfAnyPos(u8, source.text, valueStart, ",}") orelse source.text.len);
                        var output = std.ArrayList(u8).empty;
                        defer output.deinit(self.allocator);
                        try output.appendSlice(self.allocator, source.text[0..valueStart]);
                        try output.append(self.allocator, '"');
                        try output.appendSlice(self.allocator, replacement.text);
                        try output.append(self.allocator, '"');
                        try output.appendSlice(self.allocator, source.text[valueEnd..]);
                        return .{ .text = try output.toOwnedSlice(self.allocator) };
                    }
                    if (source.text.len >= 2 and source.text[source.text.len - 1] == '}') {
                        var bodyEnd = source.text.len - 1;
                        while (bodyEnd > 0 and (source.text[bodyEnd - 1] == ' ' or source.text[bodyEnd - 1] == '\t' or source.text[bodyEnd - 1] == '\r' or source.text[bodyEnd - 1] == '\n')) : (bodyEnd -= 1) {}
                        const body = source.text[0..bodyEnd];
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
                const oldExpr = call.argument2 orelse return error.InvalidSql;
                const newExpr = call.argument3 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const old = try self.eval(table, row, oldExpr.*, parameters);
                const replacement = try self.eval(table, row, newExpr.*, parameters);
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
                const startExpr = call.argument2 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const start = try self.eval(table, row, startExpr.*, parameters);
                if (source == .text and start == .integer) {
                    const startIndex: usize = if (start.integer <= 1) 0 else @min(@as(usize, @intCast(start.integer - 1)), source.text.len);
                    var end = source.text.len;
                    if (call.argument3) |lengthExpr| {
                        const length = try self.eval(table, row, lengthExpr.*, parameters);
                        if (length != .integer) return .null;
                        end = @min(source.text.len, startIndex + @as(usize, @intCast(@max(length.integer, 0))));
                    }
                    return .{ .text = try self.allocator.dupe(u8, source.text[startIndex..end]) };
                }
                return .null;
            }
            if (std.ascii.eqlIgnoreCase(call.name, "instr")) {
                const needleExpr = call.argument2 orelse return error.InvalidSql;
                const source = try self.eval(table, row, call.argument.*, parameters);
                const needle = try self.eval(table, row, needleExpr.*, parameters);
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
            if (std.ascii.eqlIgnoreCase(call.name, "hex") or std.ascii.eqlIgnoreCase(call.name, "quote") or std.ascii.eqlIgnoreCase(call.name, "unicode") or std.ascii.eqlIgnoreCase(call.name, "char") or std.ascii.eqlIgnoreCase(call.name, "printf") or std.ascii.eqlIgnoreCase(call.name, "format")) {
                return try self.evalContext(table, row, expr, parameters, null);
            }
        }
        const raw = try self.eval(table, row, expr, parameters);
        return switch (expr) {
            .binary, .unary => raw,
            else => try self.copyValue(raw),
        };
    }

    fn initializeInsertRow(self: *Connection, table: *const Table, row: []Value) !void {
        _ = self;
        @memset(row, .null);
        for (table.columns, 0..) |column, index| {
            if (column.defaultValue) |default| row[index] = default;
        }
    }

    fn insertInto(self: *Connection, value: anytype, parameters: []const Value) anyerror!Result {
        const table = self.store.find(value.table) orelse return error.UnknownTable;
        if (value.selectSql) |selectSql| {
            var source = try self.execute(selectSql, parameters);
            defer source.deinit();
            var changes: usize = 0;
            for (source.rows) |sourceRow| {
                var row = try self.allocator.alloc(Value, table.columns.len);
                defer self.allocator.free(row);
                try self.initializeInsertRow(table, row);
                if (value.columns.len == 0) {
                    if (sourceRow.len != row.len) return error.ColumnCountMismatch;
                    for (sourceRow, 0..) |item, index| row[index] = item;
                } else {
                    if (value.columns.len != sourceRow.len) return error.ColumnCountMismatch;
                    for (value.columns, sourceRow) |name, item| row[try columnIndex(table, name)] = item;
                }
                self.store.appendRow(table, row) catch |err| {
                    if (value.conflict == .ignore and err == error.ConstraintViolation) continue;
                    if (value.conflict == .replace and err == error.ConstraintViolation) {
                        if (try self.replaceConflict(table, row)) {
                            try self.store.appendRow(table, row);
                            try self.fireTriggers(table.name, .insert, row, null);
                            changes += 1;
                            continue;
                        }
                    }
                    if (value.conflict == .update and err == error.ConstraintViolation) {
                        switch (try self.applyUpsert(table, row, value.upsertColumns, value.upsertValues, value.upsertWhere, parameters)) {
                            .updated => {
                                changes += 1;
                                continue;
                            },
                            .skipped => continue,
                            .noConflict => {},
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
        for (value.rows) |rowExprs| {
            var row = try self.allocator.alloc(Value, table.columns.len);
            defer self.allocator.free(row);
            try self.initializeInsertRow(table, row);
            if (value.columns.len == 0) {
                if (rowExprs.len != 0 and rowExprs.len != row.len) return error.ColumnCountMismatch;
                for (rowExprs, 0..) |expr, index| row[index] = try self.resolve(expr, parameters);
            } else {
                if (value.columns.len != rowExprs.len) return error.ColumnCountMismatch;
                for (value.columns, rowExprs) |name, expr| row[try columnIndex(table, name)] = try self.resolve(expr, parameters);
            }
            {
                defer self.freeResolvedTemps(table, row, value.columns, rowExprs);
                self.store.appendRow(table, row) catch |err| {
                    if (value.conflict == .ignore and err == error.ConstraintViolation) continue;
                    if (value.conflict == .replace and err == error.ConstraintViolation) {
                        if (try self.replaceConflict(table, row)) {
                            try self.store.appendRow(table, row);
                            try self.fireTriggers(table.name, .insert, row, null);
                            changes += 1;
                            continue;
                        }
                    }
                    if (value.conflict == .update and err == error.ConstraintViolation) {
                        switch (try self.applyUpsert(table, row, value.upsertColumns, value.upsertValues, value.upsertWhere, parameters)) {
                            .updated => {
                                changes += 1;
                                continue;
                            },
                            .skipped => continue,
                            .noConflict => {},
                        }
                    }
                    return err;
                };
                try self.fireTriggers(table.name, .insert, row, null);
                changes += 1;
            }
        }
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
    }

    fn selectGrouped(self: *Connection, table: *const Table, value: anytype, groupName: []const u8, parameters: []const Value) !Result {
        const Group = struct { key: Value, rows: std.ArrayList(usize) };
        const groupIndex = try columnIndex(table, groupName);
        var groups = std.ArrayList(Group).empty;
        defer {
            for (groups.items) |*group| {
                if (group.key == .text) self.allocator.free(group.key.text) else if (group.key == .blob) self.allocator.free(group.key.blob);
                group.rows.deinit(self.allocator);
            }
            groups.deinit(self.allocator);
        }
        for (table.rows.items, 0..) |row, rowIndex| {
            if (!try self.matches(table, row.values, value.condition, parameters)) continue;
            var found: ?usize = null;
            for (groups.items, 0..) |group, position| if (sameValue(group.key, row.values[groupIndex])) {
                found = position;
                break;
            };
            if (found) |position| {
                try groups.items[position].rows.append(self.allocator, rowIndex);
            } else {
                try groups.append(self.allocator, .{ .key = try self.copyValue(row.values[groupIndex]), .rows = .empty });
                try groups.items[groups.items.len - 1].rows.append(self.allocator, rowIndex);
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
                const leftValue: Value = switch (having.left) {
                    .identifier => |name| if (std.ascii.eqlIgnoreCase(name, groupName)) try self.copyValue(group.key) else return error.Unsupported,
                    .function => |function| blk: {
                        if (function.distinct) return error.Unsupported;
                        if (std.ascii.eqlIgnoreCase(function.name, "count")) break :blk .{ .integer = @intCast(group.rows.items.len) };
                        if (std.ascii.eqlIgnoreCase(function.name, "sum")) {
                            var total: i64 = 0;
                            for (group.rows.items) |rowIndex| switch (try self.eval(table, table.rows.items[rowIndex].values, function.argument.*, parameters)) {
                                .integer => |number| total += number,
                                else => {},
                            };
                            break :blk .{ .integer = total };
                        }
                        return error.Unsupported;
                    },
                    else => return error.Unsupported,
                };
                defer if (leftValue == .text) self.allocator.free(leftValue.text) else if (leftValue == .blob) self.allocator.free(leftValue.blob);
                const rightValue = try self.resolve(having.right, parameters);
                const rightOwned = having.right == .binary or having.right == .unary;
                defer if (rightOwned) self.freeConcatText(rightValue);
                if (!compare(leftValue, having.op, rightValue)) continue;
            }
            const output = try self.allocator.alloc(Value, value.projections.len);
            errdefer self.allocator.free(output);
            for (value.projections, 0..) |projection, outputIndex| switch (projection.expr) {
                .identifier => {
                    if (!std.ascii.eqlIgnoreCase(projection.expr.identifier, groupName)) return error.Unsupported;
                    output[outputIndex] = try self.copyValue(group.key);
                },
                .function => |function| {
                    const isCount = std.ascii.eqlIgnoreCase(function.name, "count");
                    const isSum = std.ascii.eqlIgnoreCase(function.name, "sum");
                    const isAvg = std.ascii.eqlIgnoreCase(function.name, "avg") or std.ascii.eqlIgnoreCase(function.name, "average");
                    const isMin = std.ascii.eqlIgnoreCase(function.name, "min");
                    const isMax = std.ascii.eqlIgnoreCase(function.name, "max");
                    if (!isCount and !isSum and !isAvg and !isMin and !isMax) return error.Unsupported;
                    if (isCount) {
                        var count: usize = 0;
                        var seen = std.ArrayList(Value).empty;
                        defer self.freeValueList(&seen);
                        for (group.rows.items) |rowIndex| {
                            if (function.argument.* == .wildcard) {
                                count += 1;
                                continue;
                            }
                            const item = try self.eval(table, table.rows.items[rowIndex].values, function.argument.*, parameters);
                            if (item == .null) continue;
                            if (function.distinct and try self.noteDistinct(&seen, item)) continue;
                            count += 1;
                        }
                        output[outputIndex] = .{ .integer = @intCast(count) };
                    } else {
                        var total: f64 = 0;
                        var integerTotal: i64 = 0;
                        var numericCount: usize = 0;
                        var realSeen = false;
                        var extremum: f64 = 0;
                        var seen = std.ArrayList(Value).empty;
                        defer self.freeValueList(&seen);
                        for (group.rows.items) |rowIndex| {
                            const item = try self.eval(table, table.rows.items[rowIndex].values, function.argument.*, parameters);
                            if (item == .null) continue;
                            if (function.distinct and try self.noteDistinct(&seen, item)) continue;
                            switch (item) {
                                .integer => |number| {
                                    const numeric = @as(f64, @floatFromInt(number));
                                    total += numeric;
                                    integerTotal += number;
                                    if (numericCount == 0 or (isMin and numeric < extremum) or (isMax and numeric > extremum)) extremum = numeric;
                                    numericCount += 1;
                                },
                                .real => |number| {
                                    realSeen = true;
                                    total += number;
                                    if (numericCount == 0 or (isMin and number < extremum) or (isMax and number > extremum)) extremum = number;
                                    numericCount += 1;
                                },
                                else => {},
                            }
                        }
                        output[outputIndex] = if (numericCount == 0) .null else if (isAvg) .{ .real = total / @as(f64, @floatFromInt(numericCount)) } else if (isMin or isMax) if (realSeen) .{ .real = extremum } else .{ .integer = @intFromFloat(extremum) } else if (realSeen) .{ .real = total } else .{ .integer = integerTotal };
                    }
                },
                else => return error.Unsupported,
            };
            try rows.append(self.allocator, output);
        }
        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn conflictRow(self: *Connection, table: *const Table, values: []const Value) ?usize {
        for (table.rows.items, 0..) |existing, rowIndex| {
            var matched = false;
            for (table.columns, 0..) |column, columnIdx| if ((column.primaryKey or column.unique) and values[columnIdx] != .null and sameValue(existing.values[columnIdx], values[columnIdx])) {
                matched = true;
                break;
            };
            if (matched) return rowIndex;
            for (table.constraints) |constraint| {
                if (constraint.kind == .foreignKey) continue;
                var valid = true;
                var hasNull = false;
                for (constraint.columns) |name| {
                    const columnIdx = columnIndex(table, name) catch {
                        valid = false;
                        break;
                    };
                    if (values[columnIdx] == .null) hasNull = true;
                    if (!sameValue(existing.values[columnIdx], values[columnIdx])) valid = false;
                }
                if (valid and (constraint.kind == .primaryKey or !hasNull)) return rowIndex;
            }
            for (self.store.indexes.items) |index| if (index.unique and std.ascii.eqlIgnoreCase(index.table, table.name)) {
                var valid = true;
                var hasNull = false;
                for (index.columns) |name| {
                    const columnIdx = columnIndex(table, name) catch {
                        valid = false;
                        break;
                    };
                    if (values[columnIdx] == .null) hasNull = true;
                    if (!sameValue(existing.values[columnIdx], values[columnIdx])) valid = false;
                }
                if (valid and !hasNull) return rowIndex;
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
        const rowIndex = self.conflictRow(table, values) orelse return .noConflict;
        const row = &table.rows.items[rowIndex];
        const oldSnapshot = try self.allocator.alloc(Value, row.values.len);
        defer {
            for (oldSnapshot) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
            self.allocator.free(oldSnapshot);
        }
        for (row.values, 0..) |item, index| oldSnapshot[index] = try self.copyValue(item);
        const candidate = try self.allocator.alloc(Value, row.values.len);
        defer self.allocator.free(candidate);
        @memcpy(candidate, row.values);
        for (columns, expressions) |name, expression| candidate[try columnIndex(table, name)] = try self.resolveUpsert(table, expression, values, parameters);
        if (where) |conditions| if (!try self.matches(table, row.values, conditions, parameters)) return .skipped;
        try self.store.validateUpdate(table, rowIndex, candidate);
        try self.applyUpdateActions(table.name, row.values, candidate);
        for (columns, expressions) |name, expression| {
            const index = try columnIndex(table, name);
            const newValue = try self.resolveUpsert(table, expression, values, parameters);
            if (row.values[index] == .text) self.allocator.free(row.values[index].text);
            if (row.values[index] == .blob) self.allocator.free(row.values[index].blob);
            row.values[index] = switch (newValue) {
                .text => |text| .{ .text = try self.allocator.dupe(u8, text) },
                .blob => |blob| .{ .blob = try self.allocator.dupe(u8, blob) },
                else => newValue,
            };
        }
        try self.fireTriggers(table.name, .update, row.values, oldSnapshot);
        return .updated;
    }

    fn replaceConflict(self: *Connection, table: *Table, values: []const Value) anyerror!bool {
        const rowIndex = self.conflictRow(table, values) orelse return false;
        try self.applyDeleteActions(table.name, table.rows.items[rowIndex].values);
        const removed = table.rows.orderedRemove(rowIndex);
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
        if (value.table) |tableName| {
            const table = self.store.findConst(tableName) orelse {
                const view = self.store.findViewConst(tableName) orelse return error.UnknownTable;
                if (value.projections.len != 1 or value.projections[0].expr != .wildcard or value.join != null or value.condition != null or value.order != null or value.limit != null or value.offset != null) return error.Unsupported;
                return self.execute(view.sql, parameters);
            };
            if (value.join) |join| return try self.selectJoin(value, table, join);
            if (value.groupBy) |groupName| return try self.selectGrouped(table, value, groupName, parameters);
            if (value.projections.len == 1 and value.projections[0].expr == .function and std.ascii.eqlIgnoreCase(value.projections[0].expr.function.name, "count")) {
                const countFn = value.projections[0].expr.function;
                var count: usize = 0;
                var seen = std.ArrayList(Value).empty;
                defer self.freeValueList(&seen);
                for (table.rows.items) |row| {
                    if (!try self.matches(table, row.values, value.condition, parameters)) continue;
                    if (countFn.argument.* == .wildcard) {
                        count += 1;
                        continue;
                    }
                    const item = try self.eval(table, row.values, countFn.argument.*, parameters);
                    if (item == .null) continue;
                    if (countFn.distinct and try self.noteDistinct(&seen, item)) continue;
                    count += 1;
                }
                const aggregateRow = try self.allocator.alloc(Value, 1);
                aggregateRow[0] = .{ .integer = @intCast(count) };
                const aggregateRows = try self.allocator.alloc([]Value, 1);
                aggregateRows[0] = aggregateRow;
                try columns.append(self.allocator, value.projections[0].alias orelse "count(*)");
                return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = aggregateRows };
            }
            if (value.projections.len == 1 and value.projections[0].expr == .function) {
                const function = value.projections[0].expr.function;
                const isSum = std.ascii.eqlIgnoreCase(function.name, "sum");
                const isAvg = std.ascii.eqlIgnoreCase(function.name, "avg") or std.ascii.eqlIgnoreCase(function.name, "average");
                const isMin = std.ascii.eqlIgnoreCase(function.name, "min");
                const isMax = std.ascii.eqlIgnoreCase(function.name, "max");
                if (isSum or isAvg or isMin or isMax) {
                    var total: f64 = 0;
                    var integerTotal: i64 = 0;
                    var numericCount: usize = 0;
                    var realSeen = false;
                    var extremum: f64 = 0;
                    var seen = std.ArrayList(Value).empty;
                    defer self.freeValueList(&seen);
                    for (table.rows.items) |row| {
                        if (!try self.matches(table, row.values, value.condition, parameters)) continue;
                        const item = try self.eval(table, row.values, function.argument.*, parameters);
                        if (item == .null) continue;
                        if (function.distinct and try self.noteDistinct(&seen, item)) continue;
                        switch (item) {
                            .integer => |number| {
                                const numeric = @as(f64, @floatFromInt(number));
                                total += numeric;
                                integerTotal += number;
                                if (numericCount == 0 or (isMin and numeric < extremum) or (isMax and numeric > extremum)) extremum = numeric;
                                numericCount += 1;
                            },
                            .real => |number| {
                                realSeen = true;
                                total += number;
                                if (numericCount == 0 or (isMin and number < extremum) or (isMax and number > extremum)) extremum = number;
                                numericCount += 1;
                            },
                            else => {},
                        }
                    }
                    const aggregateValue: Value = if (numericCount == 0) .null else if (isAvg) .{ .real = total / @as(f64, @floatFromInt(numericCount)) } else if (isMin or isMax) if (realSeen) .{ .real = extremum } else .{ .integer = @intFromFloat(extremum) } else if (realSeen) .{ .real = total } else .{ .integer = integerTotal };
                    const aggregateRow = try self.allocator.alloc(Value, 1);
                    aggregateRow[0] = aggregateValue;
                    const aggregateRows = try self.allocator.alloc([]Value, 1);
                    aggregateRows[0] = aggregateRow;
                    try columns.append(self.allocator, value.projections[0].alias orelse function.name);
                    return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = aggregateRows };
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
            const orderedIndices = try self.plannedIndices(table, value.condition, parameters);
            defer self.allocator.free(orderedIndices);
            if (value.order) |order| {
                const orderIndex = try columnIndex(table, order.column);
                var i: usize = 0;
                while (i < orderedIndices.len) : (i += 1) {
                    var j = i + 1;
                    while (j < orderedIndices.len) : (j += 1) {
                        const left = table.rows.items[orderedIndices[i]].values[orderIndex];
                        const right = table.rows.items[orderedIndices[j]].values[orderIndex];
                        const swap = if (order.descending) compare(left, .less, right) else compare(left, .greater, right);
                        if (swap) std.mem.swap(usize, &orderedIndices[i], &orderedIndices[j]);
                    }
                }
            }
            var scanned: usize = 0;
            var count: usize = 0;
            for (orderedIndices) |rowIndex| {
                const row = table.rows.items[rowIndex];
                if (!try self.matches(table, row.values, value.condition, parameters)) continue;
                if (value.offset) |offset| if (scanned < offset) {
                    scanned += 1;
                    continue;
                };
                scanned += 1;
                const resultRow = try self.allocator.alloc(Value, value.projections.len + if (value.projections.len == 1 and value.projections[0].expr == .wildcard) table.columns.len - 1 else 0);
                var outIndex: usize = 0;
                var rowOk = false;
                defer {
                    if (!rowOk) {
                        for (resultRow[0..outIndex]) |item| self.freeConcatText(item);
                        self.allocator.free(resultRow);
                    }
                }
                for (value.projections) |projection| if (projection.expr == .wildcard) {
                    for (row.values) |item| {
                        resultRow[outIndex] = try self.copyValue(item);
                        outIndex += 1;
                    }
                } else {
                    resultRow[outIndex] = try self.materialize(table, row.values, projection.expr, parameters);
                    outIndex += 1;
                };
                rowOk = true;
                if (value.distinct) {
                    var duplicate = false;
                    for (rows.items) |existing| if (rowsEqual(existing, resultRow)) {
                        duplicate = true;
                        break;
                    };
                    if (duplicate) {
                        for (resultRow) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                        self.allocator.free(resultRow);
                        continue;
                    }
                }
                rows.append(self.allocator, resultRow) catch |err| {
                    for (resultRow) |item| self.freeConcatText(item);
                    self.allocator.free(resultRow);
                    return err;
                };
                count += 1;
                if (value.limit) |limit| if (count >= limit) break;
            }
            return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
        }
        const resultRow = try self.allocator.alloc(Value, value.projections.len);
        for (value.projections, 0..) |projection, index| {
            const raw = try self.resolve(projection.expr, parameters);
            resultRow[index] = switch (projection.expr) {
                .binary, .unary => raw,
                else => try self.copyValue(raw),
            };
        }
        var rows = try self.allocator.alloc([]Value, 1);
        rows[0] = resultRow;
        for (value.projections) |projection| _ = try columns.append(self.allocator, projection.alias orelse "?column?");
        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = rows };
    }

    fn plannedIndices(self: *Connection, table: *const Table, condition: ?ast.Conditions, parameters: []const Value) ![]usize {
        var indexedColumn: ?usize = null;
        var lookup: Value = .null;
        if (condition) |conditions| if (conditions.len == 1 and conditions[0].op == .equal) {
            for (self.store.indexes.items) |index| if (index.columns.len == 1 and std.ascii.eqlIgnoreCase(index.table, table.name) and std.ascii.eqlIgnoreCase(index.columns[0], conditions[0].column)) {
                indexedColumn = try columnIndex(table, index.columns[0]);
                lookup = self.resolve(conditions[0].value, parameters) catch .null;
                break;
            };
        };
        var indices = std.ArrayList(usize).empty;
        defer indices.deinit(self.allocator);
        if (indexedColumn) |columnIdx| {
            for (table.rows.items, 0..) |row, rowIndex| if (compare(row.values[columnIdx], .equal, lookup)) try indices.append(self.allocator, rowIndex);
        } else {
            try indices.ensureTotalCapacity(self.allocator, table.rows.items.len);
            for (table.rows.items, 0..) |_, rowIndex| try indices.append(self.allocator, rowIndex);
        }
        return indices.toOwnedSlice(self.allocator);
    }

    fn selectJoin(self: *Connection, value: anytype, left: *const Table, join: ast.Join) !Result {
        if (value.condition != null or value.order != null) return error.Unsupported;
        const right = self.store.findConst(join.table) orelse return error.UnknownTable;
        var leftIndex: usize = 0;
        var rightIndex: usize = 0;
        if (join.kind != .cross) {
            const leftName = if (join.leftTable.len == 0) left.name else join.leftTable;
            const rightName = if (join.rightTable.len == 0) right.name else join.rightTable;
            if (std.ascii.eqlIgnoreCase(leftName, left.name)) leftIndex = try columnIndex(left, join.leftColumn) else leftIndex = try columnIndex(left, join.rightColumn);
            if (std.ascii.eqlIgnoreCase(rightName, right.name)) rightIndex = try columnIndex(right, join.rightColumn) else rightIndex = try columnIndex(right, join.leftColumn);
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
                const columnName = if (dot) |position| name[position + 1 ..] else name;
                try columns.append(self.allocator, projection.alias orelse columnName);
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
        const rightMatched = try self.allocator.alloc(bool, right.rows.items.len);
        defer self.allocator.free(rightMatched);
        @memset(rightMatched, false);
        for (left.rows.items) |leftRow| {
            var matched = false;
            for (right.rows.items, 0..) |rightRow, rightRowIndex| {
                if (join.kind != .cross and !compare(leftRow.values[leftIndex], .equal, rightRow.values[rightIndex])) continue;
                matched = true;
                rightMatched[rightRowIndex] = true;
                const before = rows.items.len;
                try self.appendJoinRow(&rows, value.projections, left, leftRow.values, right, rightRow.values);
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
                try self.appendJoinRow(&rows, value.projections, left, leftRow.values, right, nulls);
            }
        }
        if (join.kind == .right or join.kind == .full) {
            const nulls = try self.allocator.alloc(Value, left.columns.len);
            @memset(nulls, .null);
            defer self.allocator.free(nulls);
            for (right.rows.items, 0..) |rightRow, rightRowIndex| if (!rightMatched[rightRowIndex]) try self.appendJoinRow(&rows, value.projections, left, nulls, right, rightRow.values);
        }
        if (value.distinct) {
            var index: usize = 0;
            while (index < rows.items.len) {
                var duplicateIndex = index + 1;
                while (duplicateIndex < rows.items.len) {
                    if (rowsEqual(rows.items[index], rows.items[duplicateIndex])) {
                        const duplicate = rows.orderedRemove(duplicateIndex);
                        for (duplicate) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                        self.allocator.free(duplicate);
                    } else duplicateIndex += 1;
                }
                index += 1;
            }
        }
        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn appendJoinRow(self: *Connection, rows: *std.ArrayList([]Value), projections: []const ast.Projection, left: *const Table, leftValues: []const Value, right: *const Table, rightValues: []const Value) !void {
        var width: usize = 0;
        for (projections) |projection| width += if (projection.expr == .wildcard) left.columns.len + right.columns.len else 1;
        const output = try self.allocator.alloc(Value, width);
        var outputIndex: usize = 0;
        for (projections) |projection| {
            if (projection.expr == .wildcard) {
                for (leftValues) |item| {
                    output[outputIndex] = try self.copyValue(item);
                    outputIndex += 1;
                }
                for (rightValues) |item| {
                    output[outputIndex] = try self.copyValue(item);
                    outputIndex += 1;
                }
            } else {
                const name = projection.expr.identifier;
                const dot = std.mem.indexOfScalar(u8, name, '.');
                const tableName = if (dot) |position| name[0..position] else "";
                const columnName = if (dot) |position| name[position + 1 ..] else name;
                if (dot != null and std.ascii.eqlIgnoreCase(tableName, right.name)) {
                    output[outputIndex] = try self.copyValue(rightValues[try columnIndex(right, columnName)]);
                } else if (columnIndex(left, columnName) catch null) |index| {
                    output[outputIndex] = try self.copyValue(leftValues[index]);
                } else {
                    output[outputIndex] = try self.copyValue(rightValues[try columnIndex(right, columnName)]);
                }
                outputIndex += 1;
            }
        }
        try rows.append(self.allocator, output);
    }

    fn updateFrom(self: *Connection, value: anytype, parameters: []const Value) anyerror!Result {
        const table = self.store.find(value.table) orelse return error.UnknownTable;
        const source = self.store.findConst(value.from.?.table) orelse return error.UnknownTable;
        const sourceSpec = value.from.?;
        const leftTable = if (sourceSpec.leftTable.len == 0) table else if (std.ascii.eqlIgnoreCase(sourceSpec.leftTable, table.name)) table else source;
        const rightTable = if (sourceSpec.rightTable.len == 0) table else if (std.ascii.eqlIgnoreCase(sourceSpec.rightTable, table.name)) table else source;
        const leftColumn = try columnIndex(leftTable, sourceSpec.leftColumn);
        const rightColumn = try columnIndex(rightTable, sourceSpec.rightColumn);
        var changes: usize = 0;
        for (table.rows.items, 0..) |*row, rowIndex| {
            for (source.rows.items) |sourceRow| {
                const leftValue = if (leftTable == table) row.values[leftColumn] else sourceRow.values[leftColumn];
                const rightValue = if (rightTable == table) row.values[rightColumn] else sourceRow.values[rightColumn];
                if (!compare(leftValue, .equal, rightValue)) continue;
                const candidate = try self.allocator.alloc(Value, row.values.len);
                defer {
                    for (value.columns, value.values) |name, expression| {
                        if (expression != .binary and expression != .unary) continue;
                        const index = columnIndex(table, name) catch continue;
                        self.freeConcatText(candidate[index]);
                    }
                    self.allocator.free(candidate);
                }
                @memcpy(candidate, row.values);
                for (value.columns, value.values) |name, expression| {
                    const index = try columnIndex(table, name);
                    const newValue = if (expression == .identifier and std.mem.indexOfScalar(u8, expression.identifier, '.') != null) blk: {
                        const dot = std.mem.indexOfScalar(u8, expression.identifier, '.').?;
                        const qualifier = expression.identifier[0..dot];
                        const columnName = expression.identifier[dot + 1 ..];
                        if (std.ascii.eqlIgnoreCase(qualifier, source.name)) break :blk sourceRow.values[try columnIndex(source, columnName)];
                        break :blk try self.resolve(expression, parameters);
                    } else try self.resolve(expression, parameters);
                    candidate[index] = newValue;
                }
                try self.store.validateUpdate(table, rowIndex, candidate);
                try self.applyUpdateActions(table.name, row.values, candidate);
                const oldSnapshot = try self.allocator.alloc(Value, row.values.len);
                defer {
                    for (oldSnapshot) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                    self.allocator.free(oldSnapshot);
                }
                for (row.values, 0..) |item, snapshotIndex| oldSnapshot[snapshotIndex] = try self.copyValue(item);
                for (value.columns, 0..) |name, updateIndex| {
                    const targetIndex = try columnIndex(table, name);
                    const newValue = candidate[targetIndex];
                    if (row.values[targetIndex] == .text) self.allocator.free(row.values[targetIndex].text);
                    if (row.values[targetIndex] == .blob) self.allocator.free(row.values[targetIndex].blob);
                    row.values[targetIndex] = switch (newValue) {
                        .text => |text| .{ .text = try self.allocator.dupe(u8, text) },
                        .blob => |blob| .{ .blob = try self.allocator.dupe(u8, blob) },
                        else => newValue,
                    };
                    _ = updateIndex;
                }
                try self.fireTriggers(table.name, .update, candidate, oldSnapshot);
                changes += 1;
                break;
            }
        }
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
    }

    fn update(self: *Connection, value: anytype, parameters: []const Value) !Result {
        if (value.from != null) return self.updateFrom(value, parameters);
        const table = self.store.find(value.table) orelse return error.UnknownTable;
        var changes: usize = 0;
        for (table.rows.items, 0..) |*row, rowIndex| if (try self.matches(table, row.values, value.condition, parameters)) {
            const candidate = try self.allocator.alloc(Value, row.values.len);
            defer {
                for (value.columns, value.values) |name, expr| {
                    if (expr != .binary and expr != .unary) continue;
                    const index = columnIndex(table, name) catch continue;
                    self.freeConcatText(candidate[index]);
                }
                self.allocator.free(candidate);
            }
            @memcpy(candidate, row.values);
            for (value.columns, value.values) |name, expr| {
                const index = try columnIndex(table, name);
                const newValue = try self.eval(table, row.values, expr, parameters);
                if (newValue == .null and table.columns[index].notNull) return error.ConstraintViolation;
                candidate[index] = newValue;
            }
            try self.store.validateUpdate(table, rowIndex, candidate);
            try self.applyUpdateActions(table.name, row.values, candidate);
            const oldSnapshot = try self.allocator.alloc(Value, row.values.len);
            defer {
                for (oldSnapshot) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                self.allocator.free(oldSnapshot);
            }
            for (row.values, 0..) |item, snapshotIndex| oldSnapshot[snapshotIndex] = try self.copyValue(item);
            for (value.columns, value.values) |name, expr| {
                const index = try columnIndex(table, name);
                const newValue = try self.eval(table, row.values, expr, parameters);
                if (row.values[index] == .text) self.allocator.free(row.values[index].text);
                if (row.values[index] == .blob) self.allocator.free(row.values[index].blob);
                row.values[index] = switch (newValue) {
                    .text => |v| .{ .text = try self.allocator.dupe(u8, v) },
                    .blob => |v| .{ .blob = try self.allocator.dupe(u8, v) },
                    else => newValue,
                };
            }
            changes += 1;
            try self.fireTriggers(table.name, .update, candidate, oldSnapshot);
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

    fn compositeMatches(self: *Connection, child: *const Table, childValues: []const Value, parent: *const Table, parentValues: []const Value, constraint: anytype) !bool {
        _ = self;
        for (constraint.columns, constraint.referencedColumns) |childName, parentName| {
            const childIndex = try columnIndex(child, childName);
            const parentIndex = try columnIndex(parent, parentName);
            if (!sameValue(childValues[childIndex], parentValues[parentIndex])) return false;
        }
        return true;
    }

    fn applyCompositeUpdateActions(self: *Connection, parentName: []const u8, oldValues: []const Value, newValues: []const Value) anyerror!void {
        const parent = self.store.findConst(parentName) orelse return error.ConstraintViolation;
        for (self.store.tables.items) |*childTable| {
            var childRowIndex: usize = 0;
            while (childRowIndex < childTable.rows.items.len) : (childRowIndex += 1) {
                var constraintIndex: usize = 0;
                while (constraintIndex < childTable.constraints.len) : (constraintIndex += 1) {
                    const constraint = childTable.constraints[constraintIndex];
                    if (constraint.kind != .foreignKey or !std.ascii.eqlIgnoreCase(constraint.foreignTable.?, parentName)) continue;
                    var changed = false;
                    for (constraint.referencedColumns) |parentColumn| {
                        const parentIndex = try columnIndex(parent, parentColumn);
                        if (!sameValue(oldValues[parentIndex], newValues[parentIndex])) changed = true;
                    }
                    if (!changed or !try self.compositeMatches(childTable, childTable.rows.items[childRowIndex].values, parent, oldValues, constraint)) continue;
                    switch (constraint.onUpdate) {
                        .restrict => return error.ConstraintViolation,
                        .setNull => {
                            for (constraint.columns) |childColumn| {
                                const childIndex = try columnIndex(childTable, childColumn);
                                if (childTable.columns[childIndex].notNull) return error.ConstraintViolation;
                            }
                            for (constraint.columns) |childColumn| {
                                const childIndex = try columnIndex(childTable, childColumn);
                                const old = childTable.rows.items[childRowIndex].values[childIndex];
                                if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                                childTable.rows.items[childRowIndex].values[childIndex] = .null;
                            }
                        },
                        .cascade => {
                            const row = &childTable.rows.items[childRowIndex];
                            const candidate = try self.allocator.alloc(Value, row.values.len);
                            for (row.values, 0..) |item, index| candidate[index] = try self.copyValue(item);
                            for (constraint.columns, constraint.referencedColumns) |childColumn, parentColumn| {
                                const childIndex = try columnIndex(childTable, childColumn);
                                const parentIndex = try columnIndex(parent, parentColumn);
                                if (candidate[childIndex] == .text) self.allocator.free(candidate[childIndex].text) else if (candidate[childIndex] == .blob) self.allocator.free(candidate[childIndex].blob);
                                candidate[childIndex] = try self.copyValue(newValues[parentIndex]);
                            }
                            try self.applyUpdateActions(childTable.name, row.values, candidate);
                            for (row.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(row.values);
                            row.values = candidate;
                        },
                    }
                }
            }
        }
    }

    fn applyCompositeDeleteActions(self: *Connection, parentName: []const u8, parentValues: []const Value) anyerror!void {
        const parent = self.store.findConst(parentName) orelse return error.ConstraintViolation;
        for (self.store.tables.items) |*childTable| {
            var childRowIndex = childTable.rows.items.len;
            while (childRowIndex > 0) {
                childRowIndex -= 1;
                for (childTable.constraints) |constraint| {
                    if (constraint.kind != .foreignKey or !std.ascii.eqlIgnoreCase(constraint.foreignTable.?, parentName)) continue;
                    if (!try self.compositeMatches(childTable, childTable.rows.items[childRowIndex].values, parent, parentValues, constraint)) continue;
                    switch (constraint.onDelete) {
                        .restrict => return error.ConstraintViolation,
                        .setNull => {
                            for (constraint.columns) |childColumn| {
                                const childIndex = try columnIndex(childTable, childColumn);
                                if (childTable.columns[childIndex].notNull) return error.ConstraintViolation;
                            }
                            for (constraint.columns) |childColumn| {
                                const childIndex = try columnIndex(childTable, childColumn);
                                const old = childTable.rows.items[childRowIndex].values[childIndex];
                                if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                                childTable.rows.items[childRowIndex].values[childIndex] = .null;
                            }
                        },
                        .cascade => {
                            try self.applyDeleteActions(childTable.name, childTable.rows.items[childRowIndex].values);
                            const removed = childTable.rows.orderedRemove(childRowIndex);
                            for (removed.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(removed.values);
                        },
                    }
                }
            }
        }
    }

    fn applyUpdateActions(self: *Connection, parentName: []const u8, oldValues: []const Value, newValues: []const Value) anyerror!void {
        if (!self.store.foreignKeysEnabled) return;
        try self.applyCompositeUpdateActions(parentName, oldValues, newValues);
        const parent = self.store.findConst(parentName) orelse return error.ConstraintViolation;
        var childTableIndex: usize = 0;
        while (childTableIndex < self.store.tables.items.len) : (childTableIndex += 1) {
            const childTable = &self.store.tables.items[childTableIndex];
            var childColumnIndex: usize = 0;
            while (childColumnIndex < childTable.columns.len) : (childColumnIndex += 1) {
                const childColumn = childTable.columns[childColumnIndex];
                const foreignTable = childColumn.foreignTable orelse continue;
                if (!std.ascii.eqlIgnoreCase(foreignTable, parentName)) continue;
                const referenced = childColumn.foreignColumn orelse return error.ConstraintViolation;
                const parentColumnIndex = try columnIndex(parent, referenced);
                if (sameValue(oldValues[parentColumnIndex], newValues[parentColumnIndex])) continue;

                var childRowIndex: usize = 0;
                while (childRowIndex < childTable.rows.items.len) : (childRowIndex += 1) {
                    const childRow = &childTable.rows.items[childRowIndex];
                    if (!sameValue(oldValues[parentColumnIndex], childRow.values[childColumnIndex])) continue;
                    switch (childColumn.onUpdate) {
                        .restrict => return error.ConstraintViolation,
                        .setNull => {
                            if (childColumn.notNull) return error.ConstraintViolation;
                            const old = childRow.values[childColumnIndex];
                            if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                            childRow.values[childColumnIndex] = .null;
                        },
                        .cascade => {
                            const candidate = try self.allocator.alloc(Value, childRow.values.len);
                            errdefer self.allocator.free(candidate);
                            for (childRow.values, 0..) |item, index| candidate[index] = try self.copyValue(item);
                            const replacement = try self.copyValue(newValues[parentColumnIndex]);
                            if (candidate[childColumnIndex] == .text) self.allocator.free(candidate[childColumnIndex].text) else if (candidate[childColumnIndex] == .blob) self.allocator.free(candidate[childColumnIndex].blob);
                            candidate[childColumnIndex] = replacement;
                            try self.applyUpdateActions(childTable.name, childRow.values, candidate);
                            for (childRow.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(childRow.values);
                            childRow.values = candidate;
                        },
                    }
                }
            }
        }
    }

    fn applyDeleteActions(self: *Connection, parentName: []const u8, parentValues: []const Value) anyerror!void {
        if (!self.store.foreignKeysEnabled) return;
        try self.applyCompositeDeleteActions(parentName, parentValues);
        var childTableIndex: usize = 0;
        while (childTableIndex < self.store.tables.items.len) : (childTableIndex += 1) {
            var childRowIndex = self.store.tables.items[childTableIndex].rows.items.len;
            while (childRowIndex > 0) {
                childRowIndex -= 1;
                var action: ?ast.ReferentialAction = null;
                var childColumnIndex: usize = 0;
                var parentColumnIndex: usize = 0;
                const childTable = &self.store.tables.items[childTableIndex];
                for (childTable.columns, 0..) |column, columnIdx| if (column.foreignTable) |foreignTable| {
                    if (std.ascii.eqlIgnoreCase(foreignTable, parentName)) {
                        const parentTable = self.store.findConst(parentName) orelse return error.ConstraintViolation;
                        const referenced = column.foreignColumn orelse return error.ConstraintViolation;
                        for (parentTable.columns, 0..) |parentColumn, index| if (std.ascii.eqlIgnoreCase(parentColumn.name, referenced)) {
                            childColumnIndex = columnIdx;
                            parentColumnIndex = index;
                            action = column.onDelete;
                            break;
                        };
                        if (action != null) break;
                    }
                };
                if (action == null or !compare(parentValues[parentColumnIndex], .equal, childTable.rows.items[childRowIndex].values[childColumnIndex])) continue;
                switch (action.?) {
                    .restrict => return error.ConstraintViolation,
                    .setNull => {
                        if (childTable.columns[childColumnIndex].notNull) return error.ConstraintViolation;
                        const old = childTable.rows.items[childRowIndex].values[childColumnIndex];
                        if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                        childTable.rows.items[childRowIndex].values[childColumnIndex] = .null;
                    },
                    .cascade => {
                        try self.applyDeleteActions(childTable.name, childTable.rows.items[childRowIndex].values);
                        const removed = childTable.rows.orderedRemove(childRowIndex);
                        for (removed.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                        self.allocator.free(removed.values);
                    },
                }
            }
        }
    }

    fn delete(self: *Connection, value: anytype, parameters: []const Value) !Result {
        const table = self.store.find(value.table) orelse return error.UnknownTable;
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
    var first = try db.from(Item).insert(.{ .id = 1, .label = "one" });
    first.deinit();
    var create = try db.exec("CREATE UNIQUE INDEX index_items_label ON index_items (label);");
    create.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Item).insert(.{ .id = 2, .label = "one" }));
    var reopened = try Connection.open(std.testing.allocator, path);
    defer reopened.close();
    try std.testing.expect(reopened.store.findIndexConst("index_items_label") != null);
    try std.testing.expectError(error.ConstraintViolation, reopened.from(Item).insert(.{ .id = 3, .label = "one" }));
    try db.createIndex(Item, "index_items_id", .{Item.columns.id}, false);
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
    try db.createTable(User, .{ .ifNotExists = true });
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
    const Parent = @import("../dsl/table.zig").table("key_dsl_parent", struct { id: i64, email: ?[]const u8 });
    const Child = @import("../dsl/table.zig").table("key_dsl_child", struct { id: i64, parent_id: i64 });
    const path = "sqlite_zig_keys_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(Parent, .{ .primaryKey = Parent.columns.id, .unique = &.{Parent.columns.email} });
    try db.createTable(Child, .{ .primaryKey = Child.columns.id, .foreignKeys = &.{.{ .column = Child.columns.parent_id, .references = Parent.columns.id }} });
    var parent = try db.from(Parent).insert(.{ .id = 1, .email = "one@example.test" });
    parent.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Parent).insert(.{ .id = 1, .email = "two@example.test" }));
    try std.testing.expectError(error.ConstraintViolation, db.from(Child).insert(.{ .id = 1, .parent_id = 99 }));
    var child = try db.from(Child).insert(.{ .id = 1, .parent_id = 1 });
    child.deinit();
    var nullable = try db.exec("INSERT INTO key_dsl_parent (id, email) VALUES (2, NULL), (3, NULL);");
    nullable.deinit();
    var childUpdate = try db.from(Child).update(.{ .parent_id = 99 });
    try std.testing.expectError(error.ConstraintViolation, childUpdate.where(Child.columns.id.eq(1)).execute());
}

test "raw SQL and typed DSL execute inner and left joins" {
    const User = @import("../dsl/table.zig").table("join_dsl_users", struct { id: i64, name: []const u8 });
    const Order = @import("../dsl/table.zig").table("join_dsl_orders", struct { id: i64, user_id: i64 });
    const path = "sqlite_zig_join_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(User, .{ .primaryKey = User.columns.id });
    try db.createTable(Order, .{ .primaryKey = Order.columns.id });
    var user = try db.from(User).insert(.{ .id = 1, .name = "A" });
    user.deinit();
    var order = try db.from(Order).insert(.{ .id = 10, .user_id = 1 });
    order.deinit();
    var secondUser = try db.from(User).insert(.{ .id = 2, .name = "B" });
    secondUser.deinit();
    var orphanOrder = try db.from(Order).insert(.{ .id = 11, .user_id = 99 });
    orphanOrder.deinit();
    var raw = try db.exec("SELECT * FROM join_dsl_users JOIN join_dsl_orders ON join_dsl_users.id = join_dsl_orders.user_id;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 1), raw.rowCount());
    try std.testing.expectEqual(@as(i64, 10), raw.rows[0][2].integer);
    var rawDistinct = try db.exec("SELECT DISTINCT * FROM join_dsl_users JOIN join_dsl_orders ON join_dsl_users.id = join_dsl_orders.user_id;");
    defer rawDistinct.deinit();
    var dslDistinct = try db.from(User).innerJoin(Order, User.columns.id.eq(Order.columns.user_id)).selectAll().distinct().fetch();
    defer dslDistinct.deinit();
    try std.testing.expectEqual(rawDistinct.rowCount(), dslDistinct.rowCount());
    var typedSum = try db.from(User).select(.{User.columns.id.sum()}).fetch();
    defer typedSum.deinit();
    try std.testing.expectEqual(@as(i64, 3), typedSum.rows[0][0].integer);
    var typedProjection = try db.from(User).select(.{ User.columns.id, User.columns.name }).fetch();
    defer typedProjection.deinit();
    try std.testing.expectEqual(@as(usize, 2), typedProjection.rowCount());
    var left = try db.from(User).leftJoin(Order, User.columns.id.eq(Order.columns.user_id)).fetch();
    defer left.deinit();
    try std.testing.expectEqual(@as(usize, 2), left.rowCount());
    var right = try db.from("join_dsl_users").rightJoin("join_dsl_orders", db.col("join_dsl_users.id").eq(db.col("join_dsl_orders.user_id"))).fetch();
    defer right.deinit();
    try std.testing.expectEqual(@as(usize, 2), right.rowCount());
    var full = try db.from("join_dsl_users").fullJoin("join_dsl_orders", db.col("join_dsl_users.id").eq(db.col("join_dsl_orders.user_id"))).fetch();
    defer full.deinit();
    try std.testing.expectEqual(@as(usize, 3), full.rowCount());
    var cross = try db.from(User).crossJoin(Order).fetch();
    defer cross.deinit();
    try std.testing.expectEqual(@as(usize, 4), cross.rowCount());
}

test "raw SQL and DSL support null like and between predicates" {
    const Item = @import("../dsl/table.zig").table("predicate_dsl_items", struct { id: i64, label: ?[]const u8 });
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
    var likeResult = try db.from(Item).where(Item.columns.label.like("a%")).fetch();
    defer likeResult.deinit();
    try std.testing.expectEqual(@as(usize, 2), likeResult.rowCount());
    var rawNotLike = try db.exec("SELECT id FROM predicate_dsl_items WHERE label NOT LIKE 'a%' ORDER BY id;");
    defer rawNotLike.deinit();
    try std.testing.expectEqual(@as(usize, 1), rawNotLike.rowCount());
    try std.testing.expectEqual(@as(i64, 2), rawNotLike.rows[0][0].integer);
    var notLikeResult = try db.from(Item).where(Item.columns.label.notLike("a%")).fetch();
    defer notLikeResult.deinit();
    try std.testing.expectEqual(@as(usize, 1), notLikeResult.rowCount());
    var nullResult = try db.from(Item).where(Item.columns.label.isNull()).fetch();
    defer nullResult.deinit();
    try std.testing.expectEqual(@as(usize, 1), nullResult.rowCount());
    var distinctResult = try db.from(Item).select(.{Item.columns.label}).distinct().fetch();
    defer distinctResult.deinit();
    try std.testing.expectEqual(@as(usize, 3), distinctResult.rowCount());
    var rawInList = try db.exec("SELECT id FROM predicate_dsl_items WHERE id IN (1, 3, 4) ORDER BY id;");
    defer rawInList.deinit();
    try std.testing.expectEqual(@as(usize, 3), rawInList.rowCount());
    var typedInList = try db.from(Item).whereInValues(Item.columns.id, .{ 1, 3, 4 }).fetch();
    defer typedInList.deinit();
    try std.testing.expectEqual(@as(usize, 3), typedInList.rowCount());
    var rawNotInList = try db.exec("SELECT id FROM predicate_dsl_items WHERE id NOT IN (1, 3, 4) ORDER BY id;");
    defer rawNotInList.deinit();
    try std.testing.expectEqual(@as(usize, 1), rawNotInList.rowCount());
    var typedNotInList = try db.from(Item).whereNotInValues(Item.columns.id, .{ 1, 3, 4 }).fetch();
    defer typedNotInList.deinit();
    try std.testing.expectEqual(@as(usize, 1), typedNotInList.rowCount());
    var rawIs = try db.exec("SELECT id FROM predicate_dsl_items WHERE label IS 'alpha' ORDER BY id;");
    defer rawIs.deinit();
    try std.testing.expectEqual(@as(usize, 2), rawIs.rowCount());
    var rawIsNotNull = try db.exec("SELECT id FROM predicate_dsl_items WHERE label IS NOT NULL ORDER BY id;");
    defer rawIsNotNull.deinit();
    try std.testing.expectEqual(@as(usize, 3), rawIsNotNull.rowCount());
    var typedIs = try db.from(Item).where(Item.columns.label.is("alpha")).fetch();
    defer typedIs.deinit();
    try std.testing.expectEqual(@as(usize, 2), typedIs.rowCount());
    var typedBetween = try db.from(Item).where(Item.columns.id.between(1, 2)).fetch();
    defer typedBetween.deinit();
    try std.testing.expectEqual(@as(usize, 2), typedBetween.rowCount());
    var rawNotBetween = try db.exec("SELECT id FROM predicate_dsl_items WHERE id NOT BETWEEN 2 AND 3 ORDER BY id;");
    defer rawNotBetween.deinit();
    try std.testing.expectEqual(@as(usize, 2), rawNotBetween.rowCount());
    var typedNotBetween = try db.from(Item).where(Item.columns.id.notBetween(2, 3)).fetch();
    defer typedNotBetween.deinit();
    try std.testing.expectEqual(rawNotBetween.rowCount(), typedNotBetween.rowCount());
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
    const walPath = "sqlite_zig_wal_test.db-wal";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, walPath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, walPath) catch {};

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
    var typed = try db.from(Sale).select(.{Sale.columns.amount.sum()}).groupBy(Sale.columns.category).fetch();
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
    var typed = try db.from(Sale).select(.{Sale.columns.amount.sum()}).groupBy(Sale.columns.category).havingCount(">", 1).fetch();
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
    var typed = try db.from(Item).insertOrIgnore(.{ .id = 1, .label = "typed duplicate" });
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
    var typed = try db.from(User).whereNotInQuery(User.columns.id, Blocked, Blocked.columns.user_id).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.rowCount());
    try std.testing.expectEqual(@as(i64, 1), typed.rows[0].id);
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
    var typed = try db.from(User).whereExists(Marker, Marker.columns.id.eq(User.columns.id)).fetch();
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
    var typed = try db.from(User).where(User.columns.name.glob("A*")).fetch();
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
    var typed = try db.from(Item).select(.{Item.columns.label.trim()}).fetch();
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
    var replaced = try db.from(Item).select(.{Item.columns.label.replace("SQLite", "Zig")}).fetch();
    defer replaced.deinit();
    try std.testing.expectEqualStrings("Alice in Zig", replaced.rows[0][0].text);
    var shortened = try db.from(Item).select(.{Item.columns.label.substr(1, 5)}).fetch();
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
    var projected = try db.from(Item).select(.{ Item.columns.label, Item.columns.id }).fetch();
    defer projected.deinit();
    try std.testing.expectEqual(@as(usize, 1), projected.rowCount());
    try std.testing.expectEqualStrings("mapped", projected.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 7), projected.rows[0][1].integer);
    var typed = try db.from(Item).selectAll().fetch();
    defer typed.deinit();
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
    var typed = try db.from(Item).where(Item.columns.name.notGlob("A*")).fetch();
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
    var typed = try db.from(Item).fetch();
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
    var typed = try db.from(Item).fetch();
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
    var likeRows = try db.exec("SELECT name FROM case_items WHERE name LIKE 'a%';");
    defer likeRows.deinit();
    try std.testing.expectEqual(@as(usize, 1), likeRows.rowCount());
    var globRows = try db.exec("SELECT name FROM case_items WHERE name GLOB 'a*';");
    defer globRows.deinit();
    try std.testing.expectEqual(@as(usize, 0), globRows.rowCount());
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
    var lower = try db.from(Item).where(Item.columns.name.lower().eq("alice")).fetch();
    defer lower.deinit();
    try std.testing.expectEqual(@as(usize, 1), lower.rowCount());
    var trimmed = try db.from(Item).where(Item.columns.name.trim().eq("Alice")).fetch();
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
    var rows = try db.from(Item).where(Item.columns.name.length().gt(1)).fetch();
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
    var rows = try db.from(Item).where(Item.columns.name.instr("ite").gt(0)).fetch();
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
    var typed = try db.from(Item).where(Item.columns.label.isDistinctFrom(@as(Value, .null))).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.rowCount());
    try std.testing.expectEqual(@as(i64, 2), typed.rows[0].id);
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
    var typed = try db.from(Item).select(.{Item.columns.value.round(0)}).fetch();
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
    var typed = try db.from(Item).select(.{Item.columns.value.cast("INTEGER")}).fetch();
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
    var typed = try db.from(Item).select(.{Item.columns.payload.jsonExtract("$.name")}).fetch();
    defer typed.deinit();
    try std.testing.expectEqualStrings("Alice", typed.rows[0][0].text);
    var filtered = try db.from(Item).where(Item.columns.payload.jsonExtract("$.name").eq("Bob")).fetch();
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.rowCount());
}

test "typed LIKE patterns match substrings, prefixes, and suffixes" {
    const path = "sqlite_zig_text_predicates_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("text_predicate_items", struct { name: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE text_predicate_items (name TEXT); INSERT INTO text_predicate_items VALUES ('Alice'), ('Malice'), ('Bob');");
    created.deinit();
    var contains = try db.from(Item).where(Item.columns.name.like("%ali%")).fetch();
    defer contains.deinit();
    try std.testing.expectEqual(@as(usize, 2), contains.rowCount());
    var starts = try db.from(Item).where(Item.columns.name.like("Al%")).fetch();
    defer starts.deinit();
    try std.testing.expectEqual(@as(usize, 1), starts.rowCount());
    var ends = try db.from(Item).where(Item.columns.name.like("%ob")).fetch();
    defer ends.deinit();
    try std.testing.expectEqual(@as(usize, 1), ends.rowCount());
    var notContains = try db.from(Item).where(Item.columns.name.notLike("%ali%")).fetch();
    defer notContains.deinit();
    try std.testing.expectEqual(@as(usize, 1), notContains.rowCount());
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
    var rows = try db.from(Item).select(.{ Item.columns.label, Item.columns.id }).fetch();
    defer rows.deinit();
    try std.testing.expectEqualStrings("seven", rows.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 7), rows.rows[0][1].integer);
}

test "fetchOne returns a mapped row or null" {
    const path = "sqlite_zig_fetch_one_typed_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("fetch_one_items", struct { id: i64, label: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE fetch_one_items (id INTEGER, label TEXT); INSERT INTO fetch_one_items VALUES (3, 'three');");
    created.deinit();
    var row = (try db.from(Item).where(Item.columns.id.eq(3)).fetchOne()).?;
    defer db.from(Item).freeRow(&row);
    try std.testing.expectEqual(@as(i64, 3), row.id);
    try std.testing.expectEqualStrings("three", row.label);
    const missing = try db.from(Item).where(Item.columns.id.eq(99)).fetchOne();
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
    var coalesced = try db.from(Item).select(.{Item.columns.label.coalesce("fallback")}).fetch();
    defer coalesced.deinit();
    try std.testing.expectEqualStrings("fallback", coalesced.rows[0][0].text);
    try std.testing.expectEqualStrings("ready", coalesced.rows[1][0].text);
    var ifnulled = try db.from(Item).select(.{Item.columns.label.ifNull(7)}).fetch();
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
    var typed = try db.from(Item).select(.{Item.columns.payload.jsonSet("$.city", "Paris")}).fetch();
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
    var rows = try db.from("dynamic_items").select(.{db.col("name")}).where(db.col("id").gte(2)).fetch();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings("Bob", rows.rows[0][0].text);
    var compound = try db.from("dynamic_items").where(db.col("id").gt(0)).andWhere(db.col("name").like("B%")).fetch();
    defer compound.deinit();
    try std.testing.expectEqual(@as(usize, 1), compound.rowCount());
    var glob = try db.from("dynamic_items").where(db.col("name").glob("A*")).fetch();
    defer glob.deinit();
    try std.testing.expectEqual(@as(usize, 1), glob.rowCount());
    var nulls = try db.exec("INSERT INTO dynamic_items VALUES (3, NULL);");
    nulls.deinit();
    var missing = try db.from("dynamic_items").where(db.col("name").isNull()).fetch();
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 1), missing.rowCount());
}

fn freshDb(path: []const u8) !*Connection {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    return Connection.open(std.testing.allocator, path);
}

fn dropDb(db: *Connection, path: []const u8) void {
    db.close();
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "dynamic DSL covers queries without any struct" {
    const path = "sqlite_zig_final_dynamic_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE dyn (id INTEGER, name TEXT, age INTEGER); INSERT INTO dyn VALUES (1, 'Alice', 30), (2, 'Bob', 17), (3, 'Carol', 42);");
    setup.deinit();

    var adults = try db.from("dyn").select(.{ db.col("id"), db.col("name") }).where(db.col("age").gte(18)).orderBy(db.col("name").asc()).fetch();
    defer adults.deinit();
    try std.testing.expectEqual(@as(usize, 2), adults.rowCount());

    var either = try db.from("dyn").where(db.col("id").eq(2)).orWhere(db.col("id").eq(3)).fetch();
    defer either.deinit();
    try std.testing.expectEqual(@as(usize, 2), either.rowCount());

    var both = try db.from("dyn").where(db.col("age").gte(18)).andWhere(db.col("name").like("C%")).fetch();
    defer both.deinit();
    try std.testing.expectEqual(@as(usize, 1), both.rowCount());

    var paged = try db.from("dyn").selectAll().orderBy(db.col("id").asc()).limit(2).offset(1).fetch();
    defer paged.deinit();
    try std.testing.expectEqual(@as(usize, 2), paged.rowCount());
    try std.testing.expectEqual(@as(i64, 2), paged.rows[0][0].integer);

    var distinct = try db.from("dyn").select(.{db.col("age")}).distinct().fetch();
    defer distinct.deinit();
    try std.testing.expectEqual(@as(usize, 3), distinct.rowCount());

    var sum = try db.from("dyn").select(.{db.col("age").sum()}).fetch();
    defer sum.deinit();
    try std.testing.expectEqual(@as(i64, 89), sum.rows[0][0].integer);
    var avg = try db.from("dyn").select(.{db.col("age").avg()}).fetch();
    defer avg.deinit();
    try std.testing.expectEqual(@as(f64, 89.0 / 3.0), avg.rows[0][0].real);
    var min = try db.from("dyn").select(.{db.col("age").min()}).fetch();
    defer min.deinit();
    try std.testing.expectEqual(@as(i64, 17), min.rows[0][0].integer);
    var max = try db.from("dyn").select(.{db.col("age").max()}).fetch();
    defer max.deinit();
    try std.testing.expectEqual(@as(i64, 42), max.rows[0][0].integer);
    var colCount = try db.from("dyn").select(.{db.col("age").count()}).fetch();
    defer colCount.deinit();
    try std.testing.expectEqual(@as(i64, 3), colCount.rows[0][0].integer);

    var counted = try db.from("dyn").countStar().fetch();
    defer counted.deinit();
    try std.testing.expectEqual(@as(i64, 3), counted.rows[0][0].integer);

    var ranged = try db.from("dyn").where(db.col("age").between(18, 40)).fetch();
    defer ranged.deinit();
    try std.testing.expectEqual(@as(usize, 1), ranged.rowCount());

    var notRanged = try db.from("dyn").where(db.col("age").notBetween(18, 40)).fetch();
    defer notRanged.deinit();
    try std.testing.expectEqual(@as(usize, 2), notRanged.rowCount());

    var globbed = try db.from("dyn").where(db.col("name").glob("A*")).fetch();
    defer globbed.deinit();
    try std.testing.expectEqual(@as(usize, 1), globbed.rowCount());

    var notLike = try db.from("dyn").where(db.col("name").notLike("A%")).fetch();
    defer notLike.deinit();
    try std.testing.expectEqual(@as(usize, 2), notLike.rowCount());

    var lowered = try db.from("dyn").where(db.col("name").lower().eq("alice")).fetch();
    defer lowered.deinit();
    try std.testing.expectEqual(@as(usize, 1), lowered.rowCount());

    var inList = try db.from("dyn").whereInValues(db.col("id"), .{ 1, 3 }).fetch();
    defer inList.deinit();
    try std.testing.expectEqual(@as(usize, 2), inList.rowCount());

    var city = try db.exec("ALTER TABLE dyn ADD COLUMN profile TEXT;");
    city.deinit();
    var profiled = try db.exec("UPDATE dyn SET profile = '{\"city\":\"Oslo\"}' WHERE id = 1;");
    profiled.deinit();
    var foundCity = try db.from("dyn").where(db.col("profile").jsonExtract("$.city").eq("Oslo")).fetch();
    defer foundCity.deinit();
    try std.testing.expectEqual(@as(usize, 1), foundCity.rowCount());

    try std.testing.expectError(error.InvalidSql, db.from("dyn").orderBy(db.col("name").lower().asc()).fetch());
    try std.testing.expectError(error.InvalidSql, db.from("dyn").havingCount("==", 1).fetch());
}

test "raw SQL, dynamic DSL, and typed DSL interoperate on one database" {
    const path = "sqlite_zig_final_interop_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const User = @import("../dsl/table.zig").table("interop_users", struct { id: i64, name: []const u8, age: ?i64 });

    var created = try db.exec("CREATE TABLE interop_users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER); INSERT INTO interop_users VALUES (1, 'Alice', 30);");
    created.deinit();

    var dyn = try db.from("interop_users").where(db.col("age").gte(18)).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(usize, 1), dyn.rowCount());
    var dynInsert = try db.from("interop_users").insert(.{ .id = 2, .name = "Bob", .age = 17 });
    dynInsert.deinit();

    try db.schema(User).validate();
    var typed = try db.from(User).where(User.columns.age.gte(18)).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.rowCount());
    try std.testing.expectEqualStrings("Alice", typed.rows[0].name);

    var updated = try db.exec("UPDATE interop_users SET age = 18 WHERE id = 2;");
    updated.deinit();
    var adults = try db.from(User).where(User.columns.age.gte(18)).fetch();
    defer adults.deinit();
    try std.testing.expectEqual(@as(usize, 2), adults.rowCount());

    var mutation = try db.from("interop_users").delete().where(db.col("id").eq(1)).execute();
    mutation.deinit();
    var remaining = try db.exec("SELECT id FROM interop_users ORDER BY id;");
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 1), remaining.rowCount());
    try std.testing.expectEqual(@as(i64, 2), remaining.rows[0][0].integer);
}

test "schema validation accepts a matching typed table" {
    const path = "sqlite_zig_final_validate_ok_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const User = @import("../dsl/table.zig").tableWith("v_users", struct { id: i64, email: []const u8, age: ?i64 }, .{
        .primaryKey = "id",
        .unique = &.{"email"},
    });
    const Order = @import("../dsl/table.zig").tableWith("v_orders", struct { id: i64, user_id: i64 }, .{
        .primaryKey = "id",
        .foreignKeys = &.{.{
            .column = "user_id",
            .references = .{ .table = "v_users", .column = "id" },
            .onDelete = .cascade,
        }},
    });
    try db.createTable(User, .{});
    try db.createTable(Order, .{});
    try db.schema(User).validate();
    try db.schema(Order).validate();
}

test "schema validation rejects mismatched tables" {
    const path = "sqlite_zig_final_validate_bad_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE m_users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER); CREATE TABLE m_orders (id INTEGER PRIMARY KEY, user_id INTEGER, FOREIGN KEY (user_id) REFERENCES m_users(id) ON DELETE RESTRICT);");
    setup.deinit();

    const WrongType = @import("../dsl/table.zig").table("m_users", struct { id: i64, name: i64, age: i64 });
    try std.testing.expectError(error.SchemaMismatch, db.schema(WrongType).validate());

    const MissingColumn = @import("../dsl/table.zig").table("m_users", struct { id: i64, name: []const u8 });
    try std.testing.expectError(error.SchemaMismatch, db.schema(MissingColumn).validate());

    const ExtraColumn = @import("../dsl/table.zig").table("m_users", struct { id: i64, name: []const u8, age: i64, extra: i64 });
    try std.testing.expectError(error.SchemaMismatch, db.schema(ExtraColumn).validate());

    const WrongNullability = @import("../dsl/table.zig").table("m_users", struct { id: i64, name: ?[]const u8, age: i64 });
    try std.testing.expectError(error.SchemaMismatch, db.schema(WrongNullability).validate());

    const WrongPk = @import("../dsl/table.zig").tableWith("m_users", struct { id: i64, name: []const u8, age: i64 }, .{ .primaryKey = "name" });
    try std.testing.expectError(error.SchemaMismatch, db.schema(WrongPk).validate());

    const MissingTable = @import("../dsl/table.zig").table("m_nope", struct { id: i64 });
    try std.testing.expectError(error.UnknownTable, db.schema(MissingTable).validate());

    const WrongAction = @import("../dsl/table.zig").tableWith("m_orders", struct { id: i64, user_id: i64 }, .{
        .foreignKeys = &.{.{ .column = "user_id", .references = .{ .table = "m_users", .column = "id" }, .onDelete = .cascade }},
    });
    try std.testing.expectError(error.SchemaMismatch, db.schema(WrongAction).validate());

    const WrongUnique = @import("../dsl/table.zig").tableWith("m_users", struct { id: i64, name: []const u8, age: i64 }, .{
        .unique = &.{"email"},
    });
    try std.testing.expectError(error.SchemaMismatch, db.schema(WrongUnique).validate());

    var compat = try db.exec("CREATE TABLE m_compat (id INT NOT NULL, name VARCHAR NOT NULL);");
    compat.deinit();
    const Compat = @import("../dsl/table.zig").table("m_compat", struct { id: i64, name: []const u8 });
    try db.schema(Compat).validate();
}

test "dynamic createTable supports keys without structs" {
    const path = "sqlite_zig_final_dynamic_ddl_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable("d_users", .{
        .columns = &.{
            .{ .name = "id", .type = "INTEGER" },
            .{ .name = "email", .type = "TEXT" },
        },
        .primaryKey = "id",
        .unique = &.{"email"},
    });
    try db.createTable("d_orders", .{
        .columns = &.{
            .{ .name = "id", .type = "INTEGER" },
            .{ .name = "user_id", .type = "INTEGER" },
        },
        .primaryKey = "id",
        .foreignKeys = &.{.{
            .column = "user_id",
            .references = .{ .table = "d_users", .column = "id" },
            .onDelete = .cascade,
        }},
    });
    var user = try db.from("d_users").insert(.{ .id = 1, .email = "a@x.test" });
    user.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from("d_users").insert(.{ .id = 2, .email = "a@x.test" }));
    var order = try db.from("d_orders").insert(.{ .id = 1, .user_id = 1 });
    order.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from("d_orders").insert(.{ .id = 2, .user_id = 99 }));
    var joined = try db.from("d_users").innerJoin("d_orders", db.col("d_users.id").eq(db.col("d_orders.user_id"))).fetch();
    defer joined.deinit();
    try std.testing.expectEqual(@as(usize, 1), joined.rowCount());
    try db.createIndex("d_users", "d_users_email_idx", .{db.col("email")}, true);
    try std.testing.expectError(error.ConstraintViolation, db.from("d_users").insert(.{ .id = 3, .email = "a@x.test" }));
    var ignored = try db.from("d_users").insertOrIgnore(.{ .id = 1, .email = "dup@x.test" });
    ignored.deinit();
    var kept = try db.from("d_users").where(db.col("id").eq(1)).fetch();
    defer kept.deinit();
    try std.testing.expectEqualStrings("a@x.test", kept.rows[0][1].text);
}

test "composite primary keys work in typed and dynamic DSL" {
    const path = "sqlite_zig_final_composite_pk_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const Member = @import("../dsl/table.zig").table("c_members", struct { tenant_id: i64, user_id: i64, label: []const u8 });
    try db.createTable(Member, .{ .primaryKey = &.{ Member.columns.tenant_id, Member.columns.user_id } });
    var first = try db.from(Member).insert(.{ .tenant_id = 1, .user_id = 1, .label = "a" });
    first.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Member).insert(.{ .tenant_id = 1, .user_id = 1, .label = "dup" }));
    var second = try db.from(Member).insert(.{ .tenant_id = 1, .user_id = 2, .label = "b" });
    second.deinit();

    try db.createTable("c_dyn_members", .{
        .columns = &.{
            .{ .name = "tenant_id", .type = "INTEGER" },
            .{ .name = "user_id", .type = "INTEGER" },
        },
        .primaryKey = &.{ "tenant_id", "user_id" },
    });
    var dyn = try db.from("c_dyn_members").insert(.{ .tenant_id = 1, .user_id = 1 });
    dyn.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from("c_dyn_members").insert(.{ .tenant_id = 1, .user_id = 1 }));
}

test "composite foreign keys cascade in typed and dynamic DSL" {
    const path = "sqlite_zig_final_composite_fk_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const Parent = @import("../dsl/table.zig").table("cf_parents", struct { tenant_id: i64, id: i64 });
    const Child = @import("../dsl/table.zig").table("cf_children", struct { tenant_id: i64, parent_id: i64 });
    try db.createTable(Parent, .{ .primaryKey = &.{ Parent.columns.tenant_id, Parent.columns.id } });
    try db.createTable(Child, .{ .foreignKeys = &.{.{
        .columns = &.{ Child.columns.tenant_id, Child.columns.parent_id },
        .references = &.{ Parent.columns.tenant_id, Parent.columns.id },
        .onDelete = .cascade,
    }} });
    var parent = try db.from(Parent).insert(.{ .tenant_id = 1, .id = 7 });
    parent.deinit();
    var child = try db.from(Child).insert(.{ .tenant_id = 1, .parent_id = 7 });
    child.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Child).insert(.{ .tenant_id = 1, .parent_id = 8 }));
    var deleted = try db.from(Parent).delete().where(Parent.columns.tenant_id.eq(1)).execute();
    deleted.deinit();
    var remaining = try db.from(Child).selectAll().fetch();
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 0), remaining.rowCount());

    try db.createTable("cfd_parents", .{
        .columns = &.{ .{ .name = "tenant_id", .type = "INTEGER" }, .{ .name = "id", .type = "INTEGER" } },
        .primaryKey = &.{ "tenant_id", "id" },
    });
    try db.createTable("cfd_children", .{
        .columns = &.{ .{ .name = "tenant_id", .type = "INTEGER" }, .{ .name = "parent_id", .type = "INTEGER" } },
        .foreignKeys = &.{.{
            .columns = &.{ "tenant_id", "parent_id" },
            .references = .{ .table = "cfd_parents", .columns = &.{ "tenant_id", "id" } },
            .onDelete = .cascade,
        }},
    });
    var dparent = try db.from("cfd_parents").insert(.{ .tenant_id = 1, .id = 7 });
    dparent.deinit();
    var dchild = try db.from("cfd_children").insert(.{ .tenant_id = 1, .parent_id = 7 });
    dchild.deinit();
    var ddeleted = try db.from("cfd_parents").delete().where(db.col("tenant_id").eq(1)).execute();
    ddeleted.deinit();
    var dremaining = try db.from("cfd_children").selectAll().fetch();
    defer dremaining.deinit();
    try std.testing.expectEqual(@as(usize, 0), dremaining.rowCount());
}

test "foreign-key actions enforce restrict, cascade, and set null" {
    const path = "sqlite_zig_final_fk_actions_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const Parent = @import("../dsl/table.zig").table("fa_parents", struct { id: i64 });
    const Cascade = @import("../dsl/table.zig").table("fa_cascade", struct { id: i64, parent_id: i64 });
    const Nullable = @import("../dsl/table.zig").table("fa_nullable", struct { id: i64, parent_id: ?i64 });
    const Restricted = @import("../dsl/table.zig").table("fa_restricted", struct { id: i64, parent_id: i64 });
    try db.createTable(Parent, .{ .primaryKey = Parent.columns.id });
    try db.createTable(Cascade, .{ .foreignKeys = &.{.{ .column = Cascade.columns.parent_id, .references = Parent.columns.id, .onDelete = .cascade, .onUpdate = .cascade }} });
    try db.createTable(Nullable, .{ .foreignKeys = &.{.{ .column = Nullable.columns.parent_id, .references = Parent.columns.id, .onDelete = .setNull, .onUpdate = .setNull }} });
    try db.createTable(Restricted, .{ .foreignKeys = &.{.{ .column = Restricted.columns.parent_id, .references = Parent.columns.id }} });
    var parent = try db.from(Parent).insert(.{ .id = 1 });
    parent.deinit();
    var cascade = try db.from(Cascade).insert(.{ .id = 1, .parent_id = 1 });
    cascade.deinit();
    var nullable = try db.from(Nullable).insert(.{ .id = 1, .parent_id = 1 });
    nullable.deinit();
    var restricted = try db.from(Restricted).insert(.{ .id = 1, .parent_id = 1 });
    restricted.deinit();

    var wipeOne = try db.from(Restricted).delete().execute();
    wipeOne.deinit();
    var bump = try db.from(Parent).update(.{ .id = 2 });
    var bumped = try bump.where(Parent.columns.id.eq(1)).execute();
    bumped.deinit();
    var moved = try db.from(Cascade).selectAll().fetch();
    defer moved.deinit();
    try std.testing.expectEqual(@as(i64, 2), moved.rows[0].parent_id);
    var nulled = try db.from(Nullable).selectAll().fetch();
    defer nulled.deinit();
    try std.testing.expect(nulled.rows[0].parent_id == null);

    var restrictedTwo = try db.from(Restricted).insert(.{ .id = 2, .parent_id = 2 });
    restrictedTwo.deinit();
    var blocked = db.from(Parent).delete().where(Parent.columns.id.eq(2));
    try std.testing.expectError(error.ConstraintViolation, blocked.execute());
    var wipeRestricted = try db.from(Restricted).delete().execute();
    wipeRestricted.deinit();
    var wipeNullable = try db.from(Nullable).delete().execute();
    wipeNullable.deinit();
    var wipeCascade = try db.from(Cascade).delete().execute();
    wipeCascade.deinit();
    var gone = try db.from(Parent).delete().where(Parent.columns.id.eq(2)).execute();
    gone.deinit();
    var left = try db.from(Parent).selectAll().fetch();
    defer left.deinit();
    try std.testing.expectEqual(@as(usize, 0), left.rowCount());
}

test "values are bound, never interpolated" {
    const path = "sqlite_zig_final_binding_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const Item = @import("../dsl/table.zig").table("bind_items", struct { id: i64, label: []const u8 });
    try db.createTable(Item, .{});
    const tricky = "O'Brien \"%\" _*";
    var inserted = try db.from(Item).insert(.{ .id = 1, .label = tricky });
    inserted.deinit();
    var found = try db.from(Item).where(Item.columns.label.eq(tricky)).fetch();
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 1), found.rowCount());
    var liked = try db.from(Item).where(Item.columns.label.like("O'Brien%")).fetch();
    defer liked.deinit();
    try std.testing.expectEqual(@as(usize, 1), liked.rowCount());
    var hostile = try db.from("bind_items").where(db.col("label").eq(tricky)).fetch();
    defer hostile.deinit();
    try std.testing.expectEqual(@as(usize, 1), hostile.rowCount());
}

test "joins, exists, and subqueries work in both DSL modes" {
    const path = "sqlite_zig_final_joins_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const User = @import("../dsl/table.zig").table("j_users", struct { id: i64, name: []const u8 });
    const Order = @import("../dsl/table.zig").table("j_orders", struct { id: i64, user_id: i64 });
    try db.createTable(User, .{});
    try db.createTable(Order, .{});
    var setup = try db.exec("INSERT INTO j_users VALUES (1, 'A'), (2, 'B'); INSERT INTO j_orders VALUES (10, 1), (11, 99);");
    setup.deinit();

    var inner = try db.from(User).innerJoin(Order, User.columns.id.eq(Order.columns.user_id)).fetch();
    defer inner.deinit();
    try std.testing.expectEqual(@as(usize, 1), inner.rowCount());

    var left = try db.from(User).leftJoin(Order, User.columns.id.eq(Order.columns.user_id)).fetch();
    defer left.deinit();
    try std.testing.expectEqual(@as(usize, 2), left.rowCount());

    var cross = try db.from(User).crossJoin(Order).fetch();
    defer cross.deinit();
    try std.testing.expectEqual(@as(usize, 4), cross.rowCount());

    var dynInner = try db.from("j_users").innerJoin("j_orders", db.col("j_users.id").eq(db.col("j_orders.user_id"))).fetch();
    defer dynInner.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynInner.rowCount());

    var exists = try db.from(User).whereExists(Order, Order.columns.user_id.eq(User.columns.id)).fetch();
    defer exists.deinit();
    try std.testing.expectEqual(@as(usize, 1), exists.rowCount());

    var notExists = try db.from(User).whereNotExists(Order, Order.columns.user_id.eq(User.columns.id)).fetch();
    defer notExists.deinit();
    try std.testing.expectEqual(@as(usize, 1), notExists.rowCount());

    var inQ = try db.from(User).whereInQuery(User.columns.id, Order, Order.columns.user_id).fetch();
    defer inQ.deinit();
    try std.testing.expectEqual(@as(usize, 1), inQ.rowCount());

    var notInQ = try db.from(User).whereNotInQuery(User.columns.id, Order, Order.columns.user_id).fetch();
    defer notInQ.deinit();
    try std.testing.expectEqual(@as(usize, 1), notInQ.rowCount());

    var dynExists = try db.from("j_users").whereExists("j_orders", db.col("j_orders.user_id").eq(db.col("j_users.id"))).fetch();
    defer dynExists.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynExists.rowCount());

    var dynIn = try db.from("j_users").whereInQuery(db.col("id"), "j_orders", db.col("user_id")).fetch();
    defer dynIn.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynIn.rowCount());
}

test "insert helpers and typed convenience insert share semantics" {
    const path = "sqlite_zig_final_insert_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const Item = @import("../dsl/table.zig").table("ins_items", struct { id: i64, label: []const u8 });
    try db.createTable(Item, .{ .primaryKey = Item.columns.id });
    var first = try db.from(Item).insert(.{ .id = 1, .label = "one" });
    first.deinit();
    var ignored = try db.from(Item).insertOrIgnore(.{ .id = 1, .label = "dup" });
    ignored.deinit();
    var replaced = try db.from(Item).insertOrReplace(.{ .id = 1, .label = "two" });
    replaced.deinit();
    var rows = try db.from(Item).selectAll().fetch();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rowCount());
    try std.testing.expectEqualStrings("two", rows.rows[0].label);
}

test "COUNT DISTINCT deduplicates across raw SQL and both DSL modes" {
    const path = "sqlite_zig_final_distinct_agg_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE daggs (id INTEGER, label TEXT); INSERT INTO daggs VALUES (1, 'a'), (2, 'a'), (3, 'b'), (4, NULL);");
    setup.deinit();

    var raw = try db.exec("SELECT COUNT(DISTINCT label) FROM daggs;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(i64, 2), raw.rows[0][0].integer);

    var rawSum = try db.exec("SELECT SUM(DISTINCT id) FROM daggs;");
    defer rawSum.deinit();
    try std.testing.expectEqual(@as(i64, 10), rawSum.rows[0][0].integer);

    var dyn = try db.from("daggs").select(.{db.col("label").countDistinct()}).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(i64, 2), dyn.rows[0][0].integer);

    const Agg = @import("../dsl/table.zig").table("daggs", struct { id: i64, label: ?[]const u8 });
    var typed = try db.from(Agg).select(.{Agg.columns.label.countDistinct()}).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(i64, 2), typed.rows[0][0].integer);

    var grouped = try db.exec("SELECT label, COUNT(DISTINCT id) FROM daggs GROUP BY label;");
    defer grouped.deinit();
    try std.testing.expectEqual(@as(usize, 3), grouped.rowCount());

    const bad = db.exec("SELECT COUNT(DISTINCT *) FROM daggs;");
    if (bad) |r| {
        var owned = r;
        owned.deinit();
        return error.DistinctStarAccepted;
    } else |_| {}
}

test "expression operators follow SQLite semantics" {
    const path = "sqlite_zig_final_expr_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE exprs (a INTEGER, b INTEGER, c INTEGER, name TEXT); INSERT INTO exprs VALUES (1, 0, 0, 'Alice'), (0, 1, 1, 'Bob'), (1, 1, 0, 'Al'), (2, 3, 4, NULL);");
    setup.deinit();

    var eq = try db.exec("SELECT 1 == 1, 1 != 2, 'a' <> 'b', 1 = 1.0, 2 > 1, 2 >= 2, 1 < 2, 1 <= 1;");
    defer eq.deinit();
    for (eq.rows[0]) |cell| try std.testing.expectEqual(@as(i64, 1), cell.integer);

    var under = try db.exec("SELECT 'Alice' LIKE 'A_ic_', 'Al' LIKE 'A_', 'A' LIKE 'A_' FROM exprs LIMIT 1;");
    defer under.deinit();
    try std.testing.expectEqual(@as(i64, 1), under.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 1), under.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 0), under.rows[0][2].integer);

    var esc = try db.exec("SELECT '100%' LIKE '100\\%%' ESCAPE '\\', '100X' LIKE '100\\%%' ESCAPE '\\', 'a_b' LIKE 'a\\_b' ESCAPE '\\' FROM exprs LIMIT 1;");
    defer esc.deinit();
    try std.testing.expectEqual(@as(i64, 1), esc.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), esc.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 1), esc.rows[0][2].integer);
    const badEscape = db.exec("SELECT 'a' LIKE 'a' ESCAPE '' FROM exprs;");
    if (badEscape) |r| {
        var owned = r;
        owned.deinit();
        return error.EmptyEscapeAccepted;
    } else |_| {}
    const longEscape = db.exec("SELECT 'a' LIKE 'a' ESCAPE 'xy' FROM exprs;");
    if (longEscape) |r| {
        var owned = r;
        owned.deinit();
        return error.LongEscapeAccepted;
    } else |_| {}

    var numLike = try db.exec("SELECT 123 LIKE '12%', 5 NOT LIKE 'x%' FROM exprs LIMIT 1;");
    defer numLike.deinit();
    try std.testing.expectEqual(@as(i64, 1), numLike.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 1), numLike.rows[0][1].integer);

    var glob = try db.from("exprs").where(db.col("name").glob("A*")).fetch();
    defer glob.deinit();
    try std.testing.expectEqual(@as(usize, 2), glob.rowCount());
    var globRaw = try db.exec("SELECT name FROM exprs WHERE name IS NOT NULL AND name GLOB 'A?i*' ORDER BY name;");
    defer globRaw.deinit();
    try std.testing.expectEqual(@as(usize, 1), globRaw.rowCount());
    try std.testing.expectEqualStrings("Alice", globRaw.rows[0][0].text);
    var globClass = try db.exec("SELECT name FROM exprs WHERE name GLOB '[AB]ob' ORDER BY name;");
    defer globClass.deinit();
    try std.testing.expectEqual(@as(usize, 1), globClass.rowCount());
    var globNeg = try db.exec("SELECT name FROM exprs WHERE name GLOB '[^A]*' ORDER BY name;");
    defer globNeg.deinit();
    try std.testing.expectEqual(@as(usize, 1), globNeg.rowCount());
    try std.testing.expectEqualStrings("Bob", globNeg.rows[0][0].text);

    var concat = try db.exec("SELECT 'a' || 'b', 'n=' || 42, 1 || 2, 1.5 || '', NULL || 'x' FROM exprs LIMIT 1;");
    defer concat.deinit();
    try std.testing.expectEqualStrings("ab", concat.rows[0][0].text);
    try std.testing.expectEqualStrings("n=42", concat.rows[0][1].text);
    try std.testing.expectEqualStrings("12", concat.rows[0][2].text);
    try std.testing.expectEqualStrings("1.5", concat.rows[0][3].text);
    try std.testing.expect(concat.rows[0][4] == .null);

    var arith = try db.exec("SELECT 2 + 3 * 4, (2 + 3) * 4, 7 / 2, 7.0 / 2, 7 % 3, 2 * 3 || 'x' FROM exprs LIMIT 1;");
    defer arith.deinit();
    try std.testing.expectEqual(@as(i64, 14), arith.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 20), arith.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 3), arith.rows[0][2].integer);
    try std.testing.expectEqual(@as(f64, 3.5), arith.rows[0][3].real);
    try std.testing.expectEqual(@as(i64, 1), arith.rows[0][4].integer);
    try std.testing.expectEqual(@as(i64, 6), arith.rows[0][5].integer);

    var divZero = try db.exec("SELECT 1 / 0, 7 % 0, 1.0 / 0.0, NULL + 1, '6' * '7', 'abc' + 1 FROM exprs LIMIT 1;");
    defer divZero.deinit();
    try std.testing.expect(divZero.rows[0][0] == .null);
    try std.testing.expect(divZero.rows[0][1] == .null);
    try std.testing.expect(divZero.rows[0][2] == .null);
    try std.testing.expect(divZero.rows[0][3] == .null);
    try std.testing.expectEqual(@as(i64, 42), divZero.rows[0][4].integer);
    try std.testing.expectEqual(@as(f64, 1.0), divZero.rows[0][5].real);

    var overflow = try db.exec("SELECT 9223372036854775807 + 1, 3037000500 * 3037000500 FROM exprs LIMIT 1;");
    defer overflow.deinit();
    try std.testing.expectEqual(@as(f64, 9223372036854775808.0), overflow.rows[0][0].real);
    try std.testing.expect(overflow.rows[0][1] == .real);

    var unary = try db.exec("SELECT -5, +5, -(3 + 2), ~0, ~5, -a, +b FROM exprs WHERE a = 2 AND b = 3 AND c = 4;");
    defer unary.deinit();
    try std.testing.expectEqual(@as(i64, -5), unary.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 5), unary.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, -5), unary.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, -1), unary.rows[0][3].integer);
    try std.testing.expectEqual(@as(i64, -6), unary.rows[0][4].integer);
    try std.testing.expectEqual(@as(i64, -2), unary.rows[0][5].integer);
    try std.testing.expectEqual(@as(i64, 3), unary.rows[0][6].integer);

    var bits = try db.exec("SELECT 6 & 3, 6 | 3, 1 << 4, 256 >> 4, 1 << 64, -1 >> 1, 1 << -1, -8 >> 2 FROM exprs LIMIT 1;");
    defer bits.deinit();
    try std.testing.expectEqual(@as(i64, 2), bits.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 7), bits.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 16), bits.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 16), bits.rows[0][3].integer);
    try std.testing.expectEqual(@as(i64, 0), bits.rows[0][4].integer);
    try std.testing.expectEqual(@as(i64, -1), bits.rows[0][5].integer);
    try std.testing.expectEqual(@as(i64, 0), bits.rows[0][6].integer);
    try std.testing.expectEqual(@as(i64, -2), bits.rows[0][7].integer);

    var searched = try db.exec("SELECT CASE WHEN a = 1 THEN 'one' WHEN a = 2 THEN 'two' ELSE 'other' END, CASE WHEN a = 9 THEN 'x' END, CASE WHEN NULL THEN 'n' ELSE 'e' END FROM exprs WHERE a = 1;");
    defer searched.deinit();
    try std.testing.expectEqualStrings("one", searched.rows[0][0].text);
    try std.testing.expect(searched.rows[0][1] == .null);
    try std.testing.expectEqualStrings("e", searched.rows[0][2].text);

    var simple = try db.exec("SELECT CASE a WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'other' END FROM exprs ORDER BY a LIMIT 2;");
    defer simple.deinit();
    try std.testing.expectEqualStrings("other", simple.rows[0][0].text);
    try std.testing.expectEqualStrings("one", simple.rows[1][0].text);

    var caseWhere = try db.exec("SELECT a FROM exprs WHERE CASE WHEN b = 1 THEN c ELSE 0 END = 1 ORDER BY a;");
    defer caseWhere.deinit();
    try std.testing.expectEqual(@as(usize, 1), caseWhere.rowCount());
    try std.testing.expectEqual(@as(i64, 0), caseWhere.rows[0][0].integer);

    var prec = try db.exec("SELECT a FROM exprs WHERE a = 1 OR b = 0 AND c = 1 ORDER BY a;");
    defer prec.deinit();
    try std.testing.expectEqual(@as(usize, 2), prec.rowCount());
    try std.testing.expectEqual(@as(i64, 1), prec.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 1), prec.rows[1][0].integer);
    var precOr = try db.from("exprs").where(db.col("a").eq(0)).orWhere(db.col("b").eq(1)).fetch();
    defer precOr.deinit();
    try std.testing.expectEqual(@as(usize, 2), precOr.rowCount());

    var substrAlias = try db.exec("SELECT SUBSTRING('hello', 2, 3) FROM exprs LIMIT 1;");
    defer substrAlias.deinit();
    try std.testing.expectEqualStrings("ell", substrAlias.rows[0][0].text);

    var dyn = try db.from("exprs").where(db.col("name").likeEscape("Al%", "\\")).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(usize, 2), dyn.rowCount());

    const ExprItem = @import("../dsl/table.zig").table("exprs", struct { a: i64, b: i64, c: i64, name: ?[]const u8 });
    var typed = try db.from(ExprItem).where(ExprItem.columns.name.likeEscape("Al%", "\\")).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.rowCount());

    var dynNot = try db.from("exprs").where(db.col("name").notLikeEscape("Al%", "\\")).fetch();
    defer dynNot.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynNot.rowCount());
}

test "dynamic and typed DSL build CTE queries" {
    const path = "sqlite_zig_final_cte_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE cte_src (id INTEGER, label TEXT, active INTEGER); INSERT INTO cte_src VALUES (1, 'alpha', 1), (2, 'beta', 0), (3, 'gamma', 1);");
    setup.deinit();

    var dyn = try db.from("live").with("live", "SELECT id, label FROM cte_src WHERE active = 1").orderBy(db.col("id").asc()).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(usize, 2), dyn.rowCount());
    try std.testing.expectEqual(@as(i64, 1), dyn.rows[0][0].integer);

    const Live = @import("../dsl/table.zig").table("live", struct { id: i64, label: []const u8 });
    var typed = try db.from(Live).with("live", "SELECT id, label FROM cte_src WHERE active = 1").orderBy(Live.columns.id.asc()).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.rowCount());
    try std.testing.expectEqualStrings("gamma", typed.rows[1].label);

    var chained = try db.from("second").with("first", "SELECT id FROM cte_src WHERE id >= 2").with("second", "SELECT id FROM first").orderBy(db.col("id").asc()).fetch();
    defer chained.deinit();
    try std.testing.expectEqual(@as(usize, 2), chained.rowCount());

    var rec = try db.from("nums").withRecursive("nums", "SELECT 1 AS n", "SELECT n + 1 AS n FROM nums WHERE n < 5").orderBy(db.col("n").asc()).fetch();
    defer rec.deinit();
    try std.testing.expectEqual(@as(usize, 5), rec.rowCount());
    try std.testing.expectEqual(@as(i64, 5), rec.rows[4][0].integer);
}

test "explicit zig to sql column mapping round-trips" {
    const path = "sqlite_zig_final_mapping_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const col = @import("../dsl/column.zig").column;
    const User = @import("../dsl/table.zig").table("map_users", .{
        .firstName = col("first_name", []const u8),
        .ageYears = col("age_years", i64),
    });
    try db.createTable(User, .{ .primaryKey = User.columns.firstName });
    try db.schema(User).validate();

    var inserted = try db.from(User).insert(.{ .firstName = "Ada", .ageYears = 36 });
    inserted.deinit();

    var dyn = try db.from("map_users").where(db.col("first_name").eq("Ada")).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(usize, 1), dyn.rowCount());
    try std.testing.expectEqual(@as(i64, 36), dyn.rows[0][1].integer);

    var typed = try db.from(User).where(User.columns.ageYears.gte(18)).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.rowCount());
    try std.testing.expectEqualStrings("Ada", typed.rows[0].firstName);
    try std.testing.expectEqual(@as(i64, 36), typed.rows[0].ageYears);

    var pending = try db.from(User).update(.{ .ageYears = 37 });
    var renamed = try pending.where(User.columns.firstName.eq("Ada")).execute();
    renamed.deinit();
    var one = (try db.from(User).where(User.columns.firstName.eq("Ada")).fetchOne()).?;
    defer db.from(User).freeRow(&one);
    try std.testing.expectEqual(@as(i64, 37), one.ageYears);

    var raw = try db.exec("SELECT first_name, age_years FROM map_users;");
    defer raw.deinit();
    try std.testing.expectEqualStrings("Ada", raw.rows[0][0].text);

    const Wrong = @import("../dsl/table.zig").table("map_users", struct { firstName: []const u8, ageYears: []const u8 });
    try std.testing.expectError(error.SchemaMismatch, db.schema(Wrong).validate());
}
