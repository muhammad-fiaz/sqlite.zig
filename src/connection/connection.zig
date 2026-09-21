const std = @import("std");
const DatabaseFile = @import("../storage/file.zig").DatabaseFile;
const image = @import("../storage/image.zig");
const sqliteImage = @import("../storage/sqlite_image.zig");
const Schema = @import("../catalog/schema.zig").Schema;
const Table = @import("../catalog/schema.zig").Table;
const View = @import("../catalog/schema.zig").View;
const Index = @import("../catalog/schema.zig").Index;
const Trigger = @import("../catalog/schema.zig").Trigger;
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");
const Parser = @import("../sql/parser.zig").Parser;
const Prepared = @import("statement.zig").Statement;
pub const Result = @import("result.zig").Result;
const DynamicColumn = @import("../dsl/column.zig").DynamicColumn;
const ExcludedColumn = @import("../dsl/column.zig").ExcludedColumn;
const Builder = @import("../dsl/query_builder.zig").Builder;
const Query = @import("../dsl/query_builder.zig").Query;
const DynamicQuery = @import("../dsl/query_builder.zig").DynamicQuery;
const DynamicTable = @import("../dsl/dynamic.zig").DynamicTable;
const SchemaHandle = @import("../dsl/dynamic.zig").SchemaHandle;
const keys = @import("../dsl/keys.zig");
const planner = @import("../plan/planner.zig");
const exprEvaluator = @import("../sql/expr.zig");
const functions = @import("../sql/functions.zig");

const maxTriggerDepth: usize = 64;

const Savepoint = struct { name: []u8, schema: Schema, tempSchema: Schema, attached: std.ArrayList(AttachedBackup) };
const AttachedDb = struct { name: []u8, file: DatabaseFile, store: Schema };
const AttachedBackup = struct { name: []u8, store: Schema };
const SchemaRef = union(enum) { main, temp, attached: usize };
const OuterRow = struct { table: *const Table, alias: ?[]const u8 = null, values: []const Value, prev: ?*const OuterRow = null };
const JoinSegment = struct { table: *const Table, alias: ?[]const u8, values: []const Value };
const JoinRow = struct { segments: []JoinSegment, frames: []OuterRow };
const ChainMergePair = struct { seg: usize, left: usize, right: usize };
const ChainMerge = struct { pairs: []ChainMergePair, droppedRight: []bool };
const MergeMember = struct { seg: usize, col: usize };
const MergedGroup = struct { name: []const u8, members: std.ArrayList(MergeMember) };

pub const Connection = struct {
    allocator: std.mem.Allocator,
    file: DatabaseFile,
    store: Schema,
    tempStore: Schema,
    attached: std.ArrayList(AttachedDb) = .empty,
    backup: ?Schema = null,
    tempBackup: ?Schema = null,
    attachedBackup: std.ArrayList(AttachedBackup) = .empty,
    statementBackup: ?Schema = null,
    tempStatementBackup: ?Schema = null,
    attachedStatementBackup: std.ArrayList(AttachedBackup) = .empty,
    inAtomicStatement: bool = false,
    activeCtes: std.ArrayList([]const u8) = .empty,
    recursiveTriggers: bool = false,
    triggerStack: std.ArrayList([]const u8) = .empty,
    transactionActive: bool = false,
    savepoints: std.ArrayList(Savepoint),
    lastRowid: i64 = 0,
    lastChanges: i64 = 0,
    totalChanges: i64 = 0,
    parseCount: usize = 0,
    cacheSize: i32 = -2000,
    synchronousLevel: u8 = 2,
    busyTimeout: u32 = 0,
    lockingModeExclusive: bool = false,
    autoVacuum: u8 = 0,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Connection {
        const connection = try allocator.create(Connection);
        const file = DatabaseFile.open(allocator, path) catch |err| {
            allocator.destroy(connection);
            return err;
        };
        connection.* = .{ .allocator = allocator, .file = file, .store = Schema.init(allocator), .tempStore = Schema.init(allocator), .savepoints = .empty };
        errdefer connection.close();
        if (try connection.file.readPayload()) |payload| {
            defer allocator.free(payload);
            const decoded = try image.decode(allocator, payload);
            connection.store.deinit();
            connection.store = decoded;
            try connection.persist();
        } else {
            const bytes = try connection.file.readImage();
            defer allocator.free(bytes);
            if (bytes.len <= 100) return error.InvalidHeader;
            if (bytes[100] == 0x0d) {
                const decoded = try sqliteImage.decode(allocator, bytes);
                connection.store.deinit();
                connection.store = decoded;
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
        if (self.tempBackup) |*backup| backup.deinit();
        self.deinitAttachedBackup(&self.attachedBackup);
        if (self.statementBackup) |*backup| backup.deinit();
        if (self.tempStatementBackup) |*backup| backup.deinit();
        self.deinitAttachedBackup(&self.attachedStatementBackup);
        self.activeCtes.deinit(self.allocator);
        self.triggerStack.deinit(self.allocator);
        self.clearSavepoints();
        self.savepoints.deinit(self.allocator);
        self.store.deinit();
        self.tempStore.deinit();
        for (self.attached.items) |*db| {
            db.store.deinit();
            db.file.close();
            self.allocator.free(db.name);
        }
        self.attached.deinit(self.allocator);
        self.file.close();
        self.allocator.destroy(self);
    }

    fn persist(self: *Connection) !void {
        try self.persistSchema(&self.file, &self.store);
        for (self.attached.items) |*db| try self.persistSchema(&db.file, &db.store);
    }

    fn persistSchema(self: *Connection, file: *DatabaseFile, store: *Schema) !void {
        const bytes = try sqliteImage.encodeWithPageSize(self.allocator, store, file.pageSize);
        defer self.allocator.free(bytes);
        try file.writeImage(bytes);
        if (self.synchronousLevel >= 2) try file.file.sync(file.threaded.io());
    }

    fn clearAttachedBackup(self: *Connection, backups: *std.ArrayList(AttachedBackup)) void {
        for (backups.items) |*item| {
            self.allocator.free(item.name);
            item.store.deinit();
        }
        backups.clearRetainingCapacity();
    }

    fn deinitAttachedBackup(self: *Connection, backups: *std.ArrayList(AttachedBackup)) void {
        self.clearAttachedBackup(backups);
        backups.deinit(self.allocator);
    }

    fn snapshotAttached(self: *Connection, backups: *std.ArrayList(AttachedBackup)) !void {
        for (self.attached.items) |db| {
            const ownedName = try self.allocator.dupe(u8, db.name);
            errdefer self.allocator.free(ownedName);
            var cloned = try db.store.clone();
            errdefer cloned.deinit();
            try backups.append(self.allocator, .{ .name = ownedName, .store = cloned });
        }
    }

    fn restoreAttached(self: *Connection, backups: *std.ArrayList(AttachedBackup)) void {
        for (self.attached.items) |*db| {
            for (backups.items) |*item| {
                if (!std.ascii.eqlIgnoreCase(item.name, db.name)) continue;
                db.store.deinit();
                db.store = item.store;
                item.store = Schema.init(self.allocator);
            }
        }
        self.clearAttachedBackup(backups);
    }

    fn snapshotSchemas(self: *Connection) !void {
        self.backup = try self.store.clone();
        errdefer {
            if (self.backup) |*backup| backup.deinit();
            self.backup = null;
        }
        self.tempBackup = try self.tempStore.clone();
        errdefer {
            if (self.tempBackup) |*backup| backup.deinit();
            self.tempBackup = null;
        }
        try self.snapshotAttached(&self.attachedBackup);
    }

    fn restoreSchemas(self: *Connection) void {
        self.store.deinit();
        self.store = self.backup.?;
        self.backup = null;
        self.tempStore.deinit();
        self.tempStore = self.tempBackup.?;
        self.tempBackup = null;
        self.restoreAttached(&self.attachedBackup);
    }

    fn clearSchemaBackups(self: *Connection) void {
        if (self.backup) |*backup| backup.deinit();
        self.backup = null;
        if (self.tempBackup) |*backup| backup.deinit();
        self.tempBackup = null;
        self.clearAttachedBackup(&self.attachedBackup);
    }

    fn snapshotStatementSchemas(self: *Connection) !void {
        self.statementBackup = try self.store.clone();
        errdefer {
            if (self.statementBackup) |*backup| backup.deinit();
            self.statementBackup = null;
        }
        self.tempStatementBackup = try self.tempStore.clone();
        errdefer {
            if (self.tempStatementBackup) |*backup| backup.deinit();
            self.tempStatementBackup = null;
        }
        try self.snapshotAttached(&self.attachedStatementBackup);
    }

    fn restoreStatementSchemas(self: *Connection) void {
        if (self.statementBackup != null) {
            self.store.deinit();
            self.store = self.statementBackup.?;
            self.statementBackup = null;
        }
        if (self.tempStatementBackup != null) {
            self.tempStore.deinit();
            self.tempStore = self.tempStatementBackup.?;
            self.tempStatementBackup = null;
        }
        self.restoreAttached(&self.attachedStatementBackup);
    }

    fn clearStatementBackups(self: *Connection) void {
        if (self.statementBackup) |*backup| backup.deinit();
        self.statementBackup = null;
        if (self.tempStatementBackup) |*backup| backup.deinit();
        self.tempStatementBackup = null;
        self.clearAttachedBackup(&self.attachedStatementBackup);
    }

    fn splitSchemaName(name: []const u8) struct { qualifier: ?[]const u8, object: []const u8 } {
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            return .{ .qualifier = name[0..dot], .object = name[dot + 1 ..] };
        }
        return .{ .qualifier = null, .object = name };
    }

    fn resolveSchema(self: *Connection, qualifier: ?[]const u8) ?SchemaRef {
        const name = qualifier orelse return null;
        if (std.ascii.eqlIgnoreCase(name, "main")) return .main;
        if (std.ascii.eqlIgnoreCase(name, "temp")) return .temp;
        for (self.attached.items, 0..) |db, index| {
            if (std.ascii.eqlIgnoreCase(db.name, name)) return .{ .attached = index };
        }
        return null;
    }

    fn storeFor(self: *Connection, ref: SchemaRef) *Schema {
        return switch (ref) {
            .main => &self.store,
            .temp => &self.tempStore,
            .attached => |index| &self.attached.items[index].store,
        };
    }

    const ResolvedTable = struct { ref: SchemaRef, table: *Table };
    const ResolvedView = struct { ref: SchemaRef, view: *View };
    const ResolvedIndex = struct { ref: SchemaRef, index: *Index };
    const ResolvedTrigger = struct { ref: SchemaRef, trigger: *Trigger };

    fn findTableQualified(self: *Connection, qualifier: ?[]const u8, name: []const u8) ?ResolvedTable {
        const ref = self.resolveSchema(qualifier) orelse return null;
        const tbl = self.storeFor(ref).find(name) orelse return null;
        return .{ .ref = ref, .table = tbl };
    }

    fn findTableOrdered(self: *Connection, name: []const u8) ?ResolvedTable {
        if (self.cteActive(name)) {
            if (self.store.find(name)) |tbl| return .{ .ref = .main, .table = tbl };
            return null;
        }
        if (self.tempStore.find(name)) |tbl| return .{ .ref = .temp, .table = tbl };
        if (self.store.find(name)) |tbl| return .{ .ref = .main, .table = tbl };
        for (self.attached.items, 0..) |*db, index| {
            if (db.store.find(name)) |tbl| return .{ .ref = .{ .attached = index }, .table = tbl };
        }
        return null;
    }

    fn resolveTableName(self: *Connection, name: []const u8) ?ResolvedTable {
        const parts = splitSchemaName(name);
        if (parts.qualifier) |qualifier| return self.findTableQualified(qualifier, parts.object);
        return self.findTableOrdered(parts.object);
    }

    fn resolveViewName(self: *Connection, name: []const u8) ?ResolvedView {
        const parts = splitSchemaName(name);
        if (parts.qualifier) |qualifier| {
            const ref = self.resolveSchema(qualifier) orelse return null;
            const view = self.storeFor(ref).findView(parts.object) orelse return null;
            return .{ .ref = ref, .view = view };
        }
        if (self.tempStore.findView(parts.object)) |view| return .{ .ref = .temp, .view = view };
        if (self.store.findView(parts.object)) |view| return .{ .ref = .main, .view = view };
        for (self.attached.items, 0..) |*db, index| {
            if (db.store.findView(parts.object)) |view| return .{ .ref = .{ .attached = index }, .view = view };
        }
        return null;
    }

    fn resolveIndexName(self: *Connection, name: []const u8) ?ResolvedIndex {
        const parts = splitSchemaName(name);
        if (parts.qualifier) |qualifier| {
            const ref = self.resolveSchema(qualifier) orelse return null;
            const index = self.storeFor(ref).findIndex(parts.object) orelse return null;
            return .{ .ref = ref, .index = index };
        }
        if (self.tempStore.findIndex(parts.object)) |index| return .{ .ref = .temp, .index = index };
        if (self.store.findIndex(parts.object)) |index| return .{ .ref = .main, .index = index };
        for (self.attached.items, 0..) |*db, index| {
            if (db.store.findIndex(parts.object)) |found| return .{ .ref = .{ .attached = index }, .index = found };
        }
        return null;
    }

    fn schemaRefName(self: *Connection, ref: SchemaRef) []const u8 {
        return switch (ref) {
            .main => "main",
            .temp => "temp",
            .attached => |index| self.attached.items[index].name,
        };
    }

    const DdlTarget = struct { store: *Schema, ref: SchemaRef, name: []const u8 };

    fn createTarget(self: *Connection, name: []const u8, temporary: bool) !DdlTarget {
        const parts = splitSchemaName(name);
        if (temporary) {
            if (parts.qualifier) |qualifier| {
                const ref = self.resolveSchema(qualifier) orelse return error.UnknownDatabase;
                if (ref != .temp) return error.InvalidSql;
            }
            return .{ .store = &self.tempStore, .ref = .temp, .name = parts.object };
        }
        if (parts.qualifier) |qualifier| {
            const ref = self.resolveSchema(qualifier) orelse return error.UnknownDatabase;
            return .{ .store = self.storeFor(ref), .ref = ref, .name = parts.object };
        }
        return .{ .store = &self.store, .ref = .main, .name = parts.object };
    }

    fn resolveTriggerName(self: *Connection, name: []const u8) ?ResolvedTrigger {
        const parts = splitSchemaName(name);
        if (parts.qualifier) |qualifier| {
            const ref = self.resolveSchema(qualifier) orelse return null;
            const trigger = self.storeFor(ref).findTrigger(parts.object) orelse return null;
            return .{ .ref = ref, .trigger = trigger };
        }
        if (self.tempStore.findTrigger(parts.object)) |trigger| return .{ .ref = .temp, .trigger = trigger };
        if (self.store.findTrigger(parts.object)) |trigger| return .{ .ref = .main, .trigger = trigger };
        for (self.attached.items, 0..) |*db, index| {
            if (db.store.findTrigger(parts.object)) |found| return .{ .ref = .{ .attached = index }, .trigger = found };
        }
        return null;
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
        return .{ .connection = self, .sql = try self.allocator.dupe(u8, sql), .allocator = self.allocator, .parameters = .empty, .executeFn = executePrepared, .queryFn = queryPrepared };
    }

    fn executeBytecode(self: *Connection, sql: []const u8) !Result {
        var parser = try Parser.init(self.allocator, sql);
        defer parser.deinit();
        var stmt = try parser.parse();
        defer ast.deinit(self.allocator, &stmt);
        var comp = @import("../vm/compiler.zig").Compiler.init(self.allocator, &self.store);
        var compiled = try comp.compile(stmt);
        defer compiled.deinit();
        var virtualMachine = @import("../vm/vm.zig").VirtualMachine.init(self.allocator, &self.store);
        defer virtualMachine.deinit();
        return virtualMachine.execute(&compiled.program, compiled.columnNames);
    }

    pub fn from(self: *Connection, source: anytype) FromOut(@TypeOf(source)) {
        const T = @TypeOf(source);
        if (comptime T != type and @typeInfo(T) == .@"struct" and @hasDecl(T, "isDynamicTable")) {
            var q = DynamicQuery.initRaw(self.allocator, self, source.name, executeForDsl, executeCompoundForDsl, executeDerivedForDsl);
            q.schema = source.schema;
            q.tableAlias = if (source.alias.len != 0) source.alias else null;
            return q;
        }
        var q = Query(T).init(self, source.tableName, executeForDsl, executeCompoundForDsl, executeDerivedForDsl);
        q.tableAlias = if (source.tableAlias.len != 0) source.tableAlias else null;
        return q;
    }

    fn FromOut(comptime T: type) type {
        if (T != type and @typeInfo(T) == .@"struct" and @hasDecl(T, "isDynamicTable")) return DynamicQuery;
        return Query(T);
    }

    // The returned handle borrows this connection; do not use it after close.
    pub fn table(self: *Connection, name: []const u8) DynamicTable {
        return DynamicTable.init(self.allocator, self, executeForDsl, executeCompoundForDsl, executeDerivedForDsl, "", name);
    }

    pub fn col(_: *Connection, name: []const u8) DynamicColumn {
        return .{ .name = name };
    }

    pub fn excluded(_: *Connection, name: []const u8) ExcludedColumn {
        return .{ .name = name };
    }

    pub fn schema(self: *Connection, source: anytype) SchemaTarget(@TypeOf(source)) {
        const T = @TypeOf(source);
        if (comptime keys.isStringLike(T)) {
            return SchemaHandle{
                .allocator = self.allocator,
                .connection = self,
                .executeFn = executeForDsl,
                .compoundExecuteFn = executeCompoundForDsl,
                .derivedExecuteFn = executeDerivedForDsl,
                .name = keys.coerceName(source),
            };
        }
        return SchemaValidator(T){ .connection = self, .tableName = targetTableName(source) };
    }

    fn SchemaTarget(comptime T: type) type {
        if (comptime keys.isStringLike(T)) return SchemaHandle;
        return SchemaValidator(T);
    }

    pub fn tableExists(self: *Connection, source: anytype) bool {
        const T = @TypeOf(source);
        if (comptime @import("../dsl/table.zig").isTableValue(T)) {
            return self.store.find(source.tableName) != null;
        }
        if (T == type) {
            return self.store.find(source.tableName) != null;
        }
        return self.store.find(source) != null;
    }

    pub fn userVersion(self: *Connection) u32 {
        return self.file.getUserVersion();
    }

    pub fn setUserVersion(self: *Connection, version: u32) !void {
        self.file.setUserVersion(version);
        try self.persistSchema(&self.file, &self.store);
    }

    pub fn schemaVersion(self: *Connection) u32 {
        return self.file.getSchemaVersion();
    }

    pub fn setSchemaVersion(self: *Connection, version: u32) !void {
        self.file.setSchemaVersion(version);
        try self.persistSchema(&self.file, &self.store);
    }

    pub fn applicationId(self: *Connection) u32 {
        return self.file.getApplicationId();
    }

    pub fn setApplicationId(self: *Connection, id: u32) !void {
        self.file.setApplicationId(id);
        try self.persistSchema(&self.file, &self.store);
    }

    pub fn createTable(self: *Connection, target: anytype, options: anytype) !void {
        const T = @TypeOf(target);
        if (comptime @import("../dsl/table.zig").isTableValue(T)) {
            if (self.store.find(target.tableName) != null) {
                if (!@hasField(@TypeOf(options), "overWrite") or !options.overWrite) return error.TableExists;
                try self.store.dropTable(target.tableName);
            }
            try self.createTypedTableValue(target, options);
        } else if (T == type) {
            if (!@hasDecl(target, "tableName") or !@hasDecl(target, "rowType")) @compileError("createTable expects a sqlite.table(...) value or a table-name string");
            if (self.tableExists(target)) {
                if (!@hasField(@TypeOf(options), "overWrite") or !options.overWrite) return error.TableExists;
                try self.store.dropTable(target.tableName);
            }
            try self.createTypedTable(target, options);
        } else {
            if (self.store.find(target) != null) {
                if (!@hasField(@TypeOf(options), "overWrite") or !options.overWrite) return error.TableExists;
                try self.store.dropTable(target);
            }
            try self.createDynamicTable(target, options);
        }
        self.bumpSchemaVersion();
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
        if (@hasField(@TypeOf(options), "autoincrement")) {
            var autoNames: [16][]const u8 = undefined;
            const autoCount = try keys.normalizeKey(options.autoincrement, TableType.tableName, &autoNames);
            if (autoCount != 1) return error.InvalidSql;
            (findDefinition(definitions[0..], autoNames[0]) orelse return error.UnknownColumn).autoincrement = true;
        } else if (@hasField(TO, "autoincrement")) {
            var autoNames: [16][]const u8 = undefined;
            const autoCount = try keys.normalizeKey(TableType.tableOptions.autoincrement, TableType.tableName, &autoNames);
            if (autoCount != 1) return error.InvalidSql;
            (findDefinition(definitions[0..], autoNames[0]) orelse return error.UnknownColumn).autoincrement = true;
        }
        var constraints = std.ArrayList(ast.TableConstraint).empty;
        defer constraints.deinit(self.allocator);
        try self.applyExpectedKeys(TableType.tableName, &definitions, &constraints, &expected);
        var isStrict = false;
        var isWithoutRowid = false;
        if (@hasField(@TypeOf(options), "strict")) isStrict = options.strict;
        if (@hasField(TO, "strict")) isStrict = TableType.tableOptions.strict;
        if (@hasField(@TypeOf(options), "withoutRowid")) isWithoutRowid = options.withoutRowid;
        if (@hasField(TO, "withoutRowid")) isWithoutRowid = TableType.tableOptions.withoutRowid;
        try self.store.createTableWithOptions(TableType.tableName, &definitions, constraints.items, .{ .strict = isStrict, .withoutRowid = isWithoutRowid });
    }

    fn createTypedTableValue(self: *Connection, target: anytype, options: anytype) !void {
        const tableMod = @import("../dsl/table.zig");
        const T = @TypeOf(target);
        const Row = tableMod.rowTypeOfValue(T);
        const Cols = tableMod.columnsTypeOfValue(T);
        const tableOpts = tableMod.tableOptionsField(T).value;
        const tname: []const u8 = target.tableName;
        const rowFields = @typeInfo(Row).@"struct".fields;
        const colFields = @typeInfo(Cols).@"struct".fields;
        var definitions: [colFields.len]ast.ColumnDef = undefined;
        inline for (colFields, 0..) |colField, index| {
            const F = colField.type.fieldType;
            definitions[index] = .{
                .name = colField.type.dslName,
                .typeName = keys.dslTypeName(F),
                .notNull = @typeInfo(F) != .optional,
                .defaultValue = keys.zigDefault(rowFields[index].type, rowFields[index].default_value_ptr),
            };
        }
        var expected = keys.ExpectedKeys{};
        const TO = @TypeOf(tableOpts);
        if (@hasField(@TypeOf(options), "primaryKey")) {
            try keys.parsePkInto(options.primaryKey, tname, &expected);
        } else if (@hasField(TO, "primaryKey")) {
            try keys.parsePkInto(tableOpts.primaryKey, tname, &expected);
        }
        if (@hasField(@TypeOf(options), "unique")) {
            try keys.parseUniqueInto(options.unique, tname, &expected);
        } else if (@hasField(TO, "unique")) {
            try keys.parseUniqueInto(tableOpts.unique, tname, &expected);
        }
        if (@hasField(@TypeOf(options), "foreignKeys")) {
            try keys.parseFksInto(options.foreignKeys, tname, &expected);
        } else if (@hasField(TO, "foreignKeys")) {
            try keys.parseFksInto(tableOpts.foreignKeys, tname, &expected);
        }
        if (@hasField(@TypeOf(options), "autoincrement")) {
            var autoNames: [16][]const u8 = undefined;
            const autoCount = try keys.normalizeKey(options.autoincrement, tname, &autoNames);
            if (autoCount != 1) return error.InvalidSql;
            (findDefinition(definitions[0..], autoNames[0]) orelse return error.UnknownColumn).autoincrement = true;
        } else if (@hasField(TO, "autoincrement")) {
            var autoNames: [16][]const u8 = undefined;
            const autoCount = try keys.normalizeKey(tableOpts.autoincrement, tname, &autoNames);
            if (autoCount != 1) return error.InvalidSql;
            (findDefinition(definitions[0..], autoNames[0]) orelse return error.UnknownColumn).autoincrement = true;
        }
        var constraints = std.ArrayList(ast.TableConstraint).empty;
        defer constraints.deinit(self.allocator);
        try self.applyExpectedKeys(tname, &definitions, &constraints, &expected);
        var isStrict = false;
        var isWithoutRowid = false;
        if (@hasField(@TypeOf(options), "strict")) isStrict = options.strict;
        if (@hasField(TO, "strict")) isStrict = tableOpts.strict;
        if (@hasField(@TypeOf(options), "withoutRowid")) isWithoutRowid = options.withoutRowid;
        if (@hasField(TO, "withoutRowid")) isWithoutRowid = tableOpts.withoutRowid;
        try self.store.createTableWithOptions(tname, &definitions, constraints.items, .{ .strict = isStrict, .withoutRowid = isWithoutRowid });
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
        var isStrict = false;
        var isWithoutRowid = false;
        if (@hasField(@TypeOf(options), "strict")) isStrict = options.strict;
        if (@hasField(@TypeOf(options), "withoutRowid")) isWithoutRowid = options.withoutRowid;
        try self.store.createTableWithOptions(name, definitions.items, constraints.items, .{ .strict = isStrict, .withoutRowid = isWithoutRowid });
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
        if (@hasField(T, "autoincrement")) def.autoincrement = spec.autoincrement;
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

    fn targetTableName(target: anytype) []const u8 {
        const T = @TypeOf(target);
        if (comptime @import("../dsl/table.zig").isTableValue(T)) return target.tableName;
        if (T == type) {
            if (!@hasDecl(target, "tableName")) @compileError("expected a sqlite.table(...) value or a table-name string");
            return target.tableName;
        }
        return target;
    }

    pub fn dropTable(self: *Connection, target: anytype) !void {
        const tableName: []const u8 = targetTableName(target);
        try self.store.dropTable(tableName);
        self.bumpSchemaVersion();
        if (!self.transactionActive) try self.persist();
    }

    pub fn createIndex(self: *Connection, target: anytype, name: []const u8, cols: anytype, unique: bool) !void {
        const tableName: []const u8 = targetTableName(target);
        var names: [16][]const u8 = undefined;
        const count = try keys.normalizeKey(cols, tableName, &names);
        try self.store.createIndex(.{ .name = name, .table = tableName, .columns = names[0..count], .unique = unique });
        self.bumpSchemaVersion();
        if (!self.transactionActive) try self.persist();
    }

    pub fn dropIndex(self: *Connection, name: []const u8) !void {
        try self.store.dropIndex(name);
        self.bumpSchemaVersion();
        if (!self.transactionActive) try self.persist();
    }

    pub fn createIndexWhere(self: *Connection, target: anytype, name: []const u8, cols: anytype, unique: bool, whereSql: []const u8) !void {
        if (whereSql.len == 0) return error.InvalidSql;
        const tableName: []const u8 = targetTableName(target);
        var names: [16][]const u8 = undefined;
        const count = try keys.normalizeKey(cols, tableName, &names);
        var ddl = std.ArrayList(u8).empty;
        defer ddl.deinit(self.allocator);
        try ddl.appendSlice(self.allocator, "CREATE ");
        if (unique) try ddl.appendSlice(self.allocator, "UNIQUE ");
        try ddl.appendSlice(self.allocator, "INDEX ");
        try ddl.appendSlice(self.allocator, name);
        try ddl.appendSlice(self.allocator, " ON ");
        try ddl.appendSlice(self.allocator, tableName);
        try ddl.appendSlice(self.allocator, " (");
        for (names[0..count], 0..) |column, position| {
            if (position != 0) try ddl.appendSlice(self.allocator, ", ");
            try ddl.appendSlice(self.allocator, column);
        }
        try ddl.appendSlice(self.allocator, ") WHERE ");
        try ddl.appendSlice(self.allocator, whereSql);
        var result = try self.exec(ddl.items);
        result.deinit();
    }

    pub fn createIndexExpr(self: *Connection, target: anytype, name: []const u8, indexKeys: []const []const u8, unique: bool, whereSql: ?[]const u8) !void {
        if (indexKeys.len == 0) return error.InvalidSql;
        if (whereSql) |predicate| if (predicate.len == 0) return error.InvalidSql;
        const tableName: []const u8 = targetTableName(target);
        var ddl = std.ArrayList(u8).empty;
        defer ddl.deinit(self.allocator);
        try ddl.appendSlice(self.allocator, "CREATE ");
        if (unique) try ddl.appendSlice(self.allocator, "UNIQUE ");
        try ddl.appendSlice(self.allocator, "INDEX ");
        try ddl.appendSlice(self.allocator, name);
        try ddl.appendSlice(self.allocator, " ON ");
        try ddl.appendSlice(self.allocator, tableName);
        try ddl.appendSlice(self.allocator, " (");
        for (indexKeys, 0..) |key, position| {
            if (position != 0) try ddl.appendSlice(self.allocator, ", ");
            try ddl.appendSlice(self.allocator, key);
        }
        try ddl.appendSlice(self.allocator, ")");
        if (whereSql) |predicate| {
            try ddl.appendSlice(self.allocator, " WHERE ");
            try ddl.appendSlice(self.allocator, predicate);
        }
        var result = try self.exec(ddl.items);
        result.deinit();
    }

    pub fn createView(self: *Connection, name: []const u8, sql: []const u8) !void {
        try self.store.createView(name, sql);
        self.bumpSchemaVersion();
        if (!self.transactionActive) try self.persist();
    }

    pub fn dropView(self: *Connection, name: []const u8) !void {
        try self.store.dropView(name);
        self.bumpSchemaVersion();
        if (!self.transactionActive) try self.persist();
    }

    pub fn dropTrigger(self: *Connection, name: []const u8) !void {
        try self.store.dropTrigger(name);
        self.bumpSchemaVersion();
        if (!self.transactionActive) try self.persist();
    }

    pub fn renameTable(self: *Connection, target: anytype, newName: []const u8) !void {
        const tableName: []const u8 = targetTableName(target);
        try self.store.renameTable(tableName, newName);
        self.bumpSchemaVersion();
        if (!self.transactionActive) try self.persist();
    }

    pub fn truncate(self: *Connection, target: anytype) !void {
        const tableName: []const u8 = targetTableName(target);
        try self.store.truncateTable(tableName);
        if (!self.transactionActive) try self.persist();
    }

    pub fn addColumn(self: *Connection, target: anytype, field: []const u8, FieldType: type) !void {
        const tableName: []const u8 = targetTableName(target);
        try self.store.addColumn(tableName, .{ .name = field, .typeName = keys.dslTypeName(FieldType) });
        self.bumpSchemaVersion();
        if (!self.transactionActive) try self.persist();
    }

    pub fn renameColumn(self: *Connection, source: anytype, comptime oldName: []const u8, comptime newName: []const u8) !void {
        try self.store.renameColumn(targetTableName(source), oldName, newName);
        if (!self.transactionActive) try self.persist();
    }

    pub fn dropColumn(self: *Connection, source: anytype, comptime field: []const u8) !void {
        try self.store.dropColumn(targetTableName(source), field);
        if (!self.transactionActive) try self.persist();
    }

    fn executeForDsl(pointer: *anyopaque, stmt: *const ast.Statement, ctes: []const @import("../dsl/ast_builder.zig").CteInput, recursive: bool) anyerror!Result {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        return self.executeDslStatement(stmt, ctes, recursive);
    }

    fn executeDslStatement(self: *Connection, stmt: *const ast.Statement, ctes: []const @import("../dsl/ast_builder.zig").CteInput, recursive: bool) anyerror!Result {
        if (ctes.len == 0) return self.executeStatement(stmt.*, &.{}, null);
        var defs = try self.allocator.alloc(ast.CteDef, ctes.len);
        defer self.allocator.free(defs);
        for (ctes, 0..) |cte, index| defs[index] = .{ .name = cte.name, .querySql = cte.querySql, .recursiveSql = cte.recursiveSql, .recursiveAll = cte.recursiveAll };
        const created = try self.setupCtes(defs, recursive, &.{});
        errdefer self.teardownCtes(defs[0..created]);
        const result = try self.executeStatement(stmt.*, &.{}, null);
        self.teardownCtes(defs[0..created]);
        return result;
    }

    pub fn SchemaValidator(comptime TableValueType: type) type {
        const tableMod = @import("../dsl/table.zig");
        const Row = if (comptime tableMod.isTableValue(TableValueType)) tableMod.rowTypeOfValue(TableValueType) else TableValueType.rowType;
        const Cols = if (comptime tableMod.isTableValue(TableValueType)) tableMod.columnsTypeOfValue(TableValueType) else @TypeOf(TableValueType.columns);
        const TableOpts = if (comptime tableMod.isTableValue(TableValueType)) tableMod.tableOptionsField(TableValueType).value else TableValueType.tableOptions;
        return struct {
            connection: *Connection,
            tableName: []const u8,

            pub fn validate(self: @This()) !void {
                const t = self.connection.store.findConst(self.tableName) orelse return error.UnknownTable;
                const rowFields = @typeInfo(Row).@"struct".fields;
                const colFields = @typeInfo(Cols).@"struct".fields;
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
                const TO = @TypeOf(TableOpts);
                if (@hasField(TO, "primaryKey")) try keys.parsePkInto(TableOpts.primaryKey, self.tableName, &expected);
                if (@hasField(TO, "unique")) try keys.parseUniqueInto(TableOpts.unique, self.tableName, &expected);
                if (@hasField(TO, "foreignKeys")) try keys.parseFksInto(TableOpts.foreignKeys, self.tableName, &expected);
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

    fn queryPrepared(pointer: *anyopaque, sql: []const u8, parameters: []const Value) anyerror!Result {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        return self.execute(sql, parameters);
    }

    pub fn begin(self: *Connection) !void {
        if (self.transactionActive) return error.TransactionActive;
        try self.snapshotSchemas();
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
        self.clearSchemaBackups();
        self.clearSavepoints();
        self.transactionActive = false;
    }
    pub fn rollback(self: *Connection) !void {
        if (!self.transactionActive) return error.NotInTransaction;
        self.restoreSchemas();
        self.clearSavepoints();
        self.transactionActive = false;
    }

    fn beginStatementAtomic(self: *Connection) !void {
        if (self.inAtomicStatement) return;
        try self.snapshotStatementSchemas();
        self.inAtomicStatement = true;
    }

    fn endStatementAtomic(self: *Connection) void {
        if (!self.inAtomicStatement) return;
        self.clearStatementBackups();
        self.inAtomicStatement = false;
    }

    fn abortStatementAtomic(self: *Connection) void {
        if (!self.inAtomicStatement) return;
        self.restoreStatementSchemas();
        self.inAtomicStatement = false;
    }

    fn resolveStatementError(self: *Connection, policy: ast.ConflictPolicy) void {
        switch (policy) {
            .none, .abort, .update => self.abortStatementAtomic(),
            .fail => self.endStatementAtomic(),
            .rollback => {
                if (self.transactionActive) {
                    self.rollback() catch {};
                    self.endStatementAtomic();
                } else self.abortStatementAtomic();
            },
            .ignore, .replace => self.endStatementAtomic(),
        }
    }

    fn executeInsertAtomic(self: *Connection, value: anytype, parameters: []const Value) !Result {
        const nested = self.inAtomicStatement;
        if (!nested) try self.beginStatementAtomic();
        const result = self.insertInto(value, parameters) catch |err| {
            if (!nested) self.resolveStatementError(value.conflict);
            return err;
        };
        if (!nested) self.endStatementAtomic();
        return result;
    }

    fn executeUpdateAtomic(self: *Connection, value: anytype, parameters: []const Value) !Result {
        const nested = self.inAtomicStatement;
        if (!nested) try self.beginStatementAtomic();
        const result = self.update(value, parameters) catch |err| {
            if (!nested) self.resolveStatementError(value.conflict);
            return err;
        };
        if (!nested) self.endStatementAtomic();
        return result;
    }

    fn executeDeleteAtomic(self: *Connection, value: anytype, parameters: []const Value) !Result {
        const nested = self.inAtomicStatement;
        if (!nested) try self.beginStatementAtomic();
        const result = self.delete(value, parameters) catch |err| {
            if (!nested) self.abortStatementAtomic();
            return err;
        };
        if (!nested) self.endStatementAtomic();
        return result;
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
        for (self.savepoints.items) |*item| self.releaseSavepointEntry(item);
        self.savepoints.clearRetainingCapacity();
    }

    fn savepointCommand(self: *Connection, name: []const u8) !Result {
        if (!self.transactionActive) try self.begin();
        var snapshot = try self.store.clone();
        errdefer snapshot.deinit();
        var tempSnapshot = try self.tempStore.clone();
        errdefer tempSnapshot.deinit();
        var attachedSnapshot = std.ArrayList(AttachedBackup).empty;
        errdefer {
            for (attachedSnapshot.items) |*item| {
                self.allocator.free(item.name);
                item.store.deinit();
            }
            attachedSnapshot.deinit(self.allocator);
        }
        try self.snapshotAttached(&attachedSnapshot);
        const ownedName = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(ownedName);
        try self.savepoints.append(self.allocator, .{ .name = ownedName, .schema = snapshot, .tempSchema = tempSnapshot, .attached = attachedSnapshot });
        return try emptyResult(self.allocator);
    }

    fn releaseSavepointEntry(self: *Connection, item: *Savepoint) void {
        self.allocator.free(item.name);
        item.schema.deinit();
        item.tempSchema.deinit();
        self.deinitAttachedBackup(&item.attached);
    }

    fn releaseCommand(self: *Connection, name: []const u8) !Result {
        var index = self.savepoints.items.len;
        while (index > 0) {
            index -= 1;
            if (std.ascii.eqlIgnoreCase(self.savepoints.items[index].name, name)) {
                while (self.savepoints.items.len > index) {
                    var item = self.savepoints.pop().?;
                    self.releaseSavepointEntry(&item);
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
                var restoredMain = try self.savepoints.items[index].schema.clone();
                errdefer restoredMain.deinit();
                var restoredTemp = try self.savepoints.items[index].tempSchema.clone();
                errdefer restoredTemp.deinit();
                var restoredAttached = std.ArrayList(AttachedBackup).empty;
                errdefer {
                    for (restoredAttached.items) |*item| {
                        self.allocator.free(item.name);
                        item.store.deinit();
                    }
                    restoredAttached.deinit(self.allocator);
                }
                for (self.savepoints.items[index].attached.items) |*item| {
                    const ownedName = try self.allocator.dupe(u8, item.name);
                    errdefer self.allocator.free(ownedName);
                    var cloned = try item.store.clone();
                    errdefer cloned.deinit();
                    try restoredAttached.append(self.allocator, .{ .name = ownedName, .store = cloned });
                }
                self.store.deinit();
                self.store = restoredMain;
                self.tempStore.deinit();
                self.tempStore = restoredTemp;
                for (self.attached.items) |*db| {
                    for (restoredAttached.items) |*item| {
                        if (!std.ascii.eqlIgnoreCase(item.name, db.name)) continue;
                        db.store.deinit();
                        db.store = item.store;
                        item.store = Schema.init(self.allocator);
                    }
                }
                self.deinitAttachedBackup(&restoredAttached);
                while (self.savepoints.items.len > index + 1) {
                    var item = self.savepoints.pop().?;
                    self.releaseSavepointEntry(&item);
                }
                return try emptyResult(self.allocator);
            }
        }
        return error.NotInTransaction;
    }

    fn execute(self: *Connection, sql: []const u8, parameters: []const Value) anyerror!Result {
        return self.executeWithOuter(sql, parameters, null);
    }

    fn executeWithOuter(self: *Connection, sql: []const u8, parameters: []const Value, outer: ?*const OuterRow) anyerror!Result {
        self.parseCount += 1;
        var parser = try Parser.init(self.allocator, sql);
        defer parser.deinit();
        var statement = try parser.parse();
        defer ast.deinit(self.allocator, &statement);
        return self.executeStatement(statement, parameters, outer);
    }

    fn executeStatement(self: *Connection, statement: ast.Statement, parameters: []const Value, outer: ?*const OuterRow) anyerror!Result {
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
            .insert => |value| try self.executeInsertAtomic(value, parameters),
            .select => |value| try self.selectWithOuter(value, parameters, outer),
            .withSelect => |value| try self.executeWith(value, parameters),
            .compoundSelect => |compound| try self.executeCompoundWithOuter(compound, parameters, outer),
            .explainQueryPlan => |querySql| try self.explainQueryPlan(querySql),
            .pragma => |value| try self.executePragma(value),
            .alterTable => |value| try self.alterTableCommand(value),
            .update => |value| try self.executeUpdateAtomic(value, parameters),
            .delete => |value| try self.executeDeleteAtomic(value, parameters),
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
            .attach => |value| try self.attachCommand(value),
            .detach => |value| try self.detachCommand(value.schemaName),
            .vacuum => |value| try self.vacuumCommand(value.schemaName, value.into),
            .analyze => |value| blk: {
                const nested = self.inAtomicStatement;
                if (!nested) try self.beginStatementAtomic();
                self.analyzeDatabase(value.target) catch |err| {
                    if (!nested) self.abortStatementAtomic();
                    return err;
                };
                if (!nested) self.endStatementAtomic();
                break :blk try emptyResult(self.allocator);
            },
        };
        if (isSchemaChange(statement)) self.bumpSchemaVersionFor(statement);
        switch (statement) {
            .insert, .update, .delete => {
                self.lastChanges = @intCast(result.changes);
                self.totalChanges += @as(i64, @intCast(result.changes));
            },
            else => {},
        }
        if (!self.transactionActive and !statement.isQuery()) try self.persist();
        return result;
    }

    fn isSchemaChange(statement: ast.Statement) bool {
        return switch (statement) {
            .createTable, .createIndex, .createView, .createTrigger, .createVirtualTable, .dropTable, .dropIndex, .dropView, .dropTrigger, .alterTable => true,
            else => false,
        };
    }

    fn bumpSchemaVersion(self: *Connection) void {
        self.file.setSchemaVersion(self.file.getSchemaVersion() +% 1);
    }

    fn bumpSchemaVersionFor(self: *Connection, statement: ast.Statement) void {
        const target: ?[]const u8 = switch (statement) {
            .createTable => |value| if (value.temporary) null else value.name,
            .createIndex => |value| value.table,
            .createView => |value| if (value.temporary) null else value.name,
            .createTrigger => |value| if (value.temporary) null else value.table,
            .createVirtualTable => |value| value.name,
            .dropTable => |value| value.name,
            .dropIndex => |value| value.name,
            .dropView => |value| value.name,
            .dropTrigger => |value| value.name,
            .alterTable => |value| switch (value) {
                .addColumn => |change| change.table,
                .renameTable => |change| change.table,
                .renameColumn => |change| change.table,
                .dropColumn => |change| change.table,
            },
            else => return,
        };
        const name = target orelse return;
        const parts = splitSchemaName(name);
        if (parts.qualifier) |qualifier| {
            if (self.resolveSchema(qualifier)) |ref| {
                if (ref == .attached) {
                    const file = &self.attached.items[ref.attached].file;
                    file.setSchemaVersion(file.getSchemaVersion() +% 1);
                    return;
                }
            }
        }
        self.bumpSchemaVersion();
    }

    fn emptyResult(allocator: std.mem.Allocator) !Result {
        return .{ .allocator = allocator, .columns = try allocator.alloc([]const u8, 0), .rows = try allocator.alloc([]Value, 0) };
    }

    fn executePragma(self: *Connection, value: anytype) !Result {
        if (value.schema) |schemaName| {
            if (!std.ascii.eqlIgnoreCase(schemaName, "main") and !std.ascii.eqlIgnoreCase(schemaName, "temp") and self.resolveSchema(schemaName) == null) return error.Unsupported;
        }
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
            const target = self.pragmaFileStore(value.schema);
            if (value.value) |versionText| {
                const version = std.fmt.parseInt(u32, versionText, 10) catch return error.InvalidSql;
                target.file.setUserVersion(version);
                try self.persistSchema(target.file, target.store);
            }
            const names = [_][]const u8{"user_version"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = target.file.getUserVersion() };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "application_id")) {
            const target = self.pragmaFileStore(value.schema);
            if (value.value) |applicationText| {
                const parsedId = std.fmt.parseInt(u32, applicationText, 10) catch return error.InvalidSql;
                target.file.setApplicationId(parsedId);
                try self.persistSchema(target.file, target.store);
            }
            const names = [_][]const u8{"application_id"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = target.file.getApplicationId() };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "journal_mode")) {
            const target = self.pragmaFileStore(value.schema);
            if (value.value) |mode| {
                if (std.ascii.eqlIgnoreCase(mode, "wal")) {
                    target.file.enableWal();
                    try self.persistSchema(target.file, target.store);
                } else if (std.ascii.eqlIgnoreCase(mode, "delete") or std.ascii.eqlIgnoreCase(mode, "rollback")) {
                    try target.file.disableWal();
                    if (self.synchronousLevel >= 1) try target.file.file.sync(target.file.threaded.io());
                    try self.persistSchema(target.file, target.store);
                } else return error.Unsupported;
            }
            const names = [_][]const u8{"journal_mode"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .text = try self.allocator.dupe(u8, target.file.journalMode()) };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "integrity_check")) return try self.pragmaIntegrityCheck(value);
        if (std.ascii.eqlIgnoreCase(value.name, "foreign_key_check")) return try self.pragmaForeignKeyCheck(value);
        if (std.ascii.eqlIgnoreCase(value.name, "cache_size")) {
            if (value.argument != null) return error.InvalidSql;
            if (value.value) |text| {
                self.cacheSize = std.fmt.parseInt(i32, text, 10) catch return error.InvalidSql;
            }
            const names = [_][]const u8{"cache_size"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = @intCast(self.cacheSize) };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "synchronous")) {
            if (value.argument != null) return error.InvalidSql;
            if (value.value) |text| {
                if (std.fmt.parseInt(u8, text, 10)) |level| {
                    if (level > 3) return error.InvalidSql;
                    self.synchronousLevel = level;
                } else |_| {
                    if (std.ascii.eqlIgnoreCase(text, "off")) {
                        self.synchronousLevel = 0;
                    } else if (std.ascii.eqlIgnoreCase(text, "normal")) {
                        self.synchronousLevel = 1;
                    } else if (std.ascii.eqlIgnoreCase(text, "full")) {
                        self.synchronousLevel = 2;
                    } else if (std.ascii.eqlIgnoreCase(text, "extra")) {
                        self.synchronousLevel = 3;
                    } else return error.InvalidSql;
                }
            }
            const names = [_][]const u8{"synchronous"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = @intCast(self.synchronousLevel) };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "page_size")) {
            const target = self.pragmaFileStore(value.schema);
            if (value.argument != null) return error.InvalidSql;
            if (value.value) |text| {
                const size = std.fmt.parseInt(usize, text, 10) catch return error.InvalidSql;
                if (size < 512 or size > 32768 or (size & (size - 1)) != 0) return error.InvalidSql;
                target.file.pageSize = size;
                try self.persistSchema(target.file, target.store);
            }
            const names = [_][]const u8{"page_size"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = @intCast(target.file.pageSize) };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "encoding")) {
            if (value.argument != null) return error.InvalidSql;
            if (value.value) |text| {
                if (std.ascii.eqlIgnoreCase(text, "UTF-8") or std.ascii.eqlIgnoreCase(text, "UTF8")) {
                    // Engine stores TEXT as UTF-8; accepting is a no-op.
                } else return error.Unsupported;
            }
            const names = [_][]const u8{"encoding"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .text = try self.allocator.dupe(u8, "UTF-8") };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "busy_timeout")) {
            if (value.argument != null) return error.InvalidSql;
            if (value.value) |text| {
                const parsed = std.fmt.parseInt(i64, text, 10) catch return error.InvalidSql;
                self.busyTimeout = if (parsed < 0) 0 else @intCast(parsed);
            }
            const names = [_][]const u8{"busy_timeout"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = @intCast(self.busyTimeout) };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "locking_mode")) {
            if (value.argument != null) return error.InvalidSql;
            if (value.value) |text| {
                if (std.ascii.eqlIgnoreCase(text, "normal")) {
                    self.lockingModeExclusive = false;
                } else if (std.ascii.eqlIgnoreCase(text, "exclusive")) {
                    self.lockingModeExclusive = true;
                } else return error.InvalidSql;
            }
            const names = [_][]const u8{"locking_mode"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .text = try self.allocator.dupe(u8, if (self.lockingModeExclusive) "exclusive" else "normal") };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "auto_vacuum")) {
            if (value.argument != null) return error.InvalidSql;
            if (value.value) |text| {
                if (std.ascii.eqlIgnoreCase(text, "none") or std.mem.eql(u8, text, "0")) {
                    self.autoVacuum = 0;
                } else if (std.ascii.eqlIgnoreCase(text, "full") or std.mem.eql(u8, text, "1")) {
                    self.autoVacuum = 1;
                } else if (std.ascii.eqlIgnoreCase(text, "incremental") or std.mem.eql(u8, text, "2")) {
                    self.autoVacuum = 2;
                } else return error.InvalidSql;
            }
            const names = [_][]const u8{"auto_vacuum"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = @intCast(self.autoVacuum) };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "schema_version")) {
            const target = self.pragmaFileStore(value.schema);
            if (value.argument != null) return error.InvalidSql;
            if (value.value) |text| {
                const version = std.fmt.parseInt(u32, text, 10) catch return error.InvalidSql;
                target.file.setSchemaVersion(version);
                try self.persistSchema(target.file, target.store);
            }
            const names = [_][]const u8{"schema_version"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = target.file.getSchemaVersion() };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "recursive_triggers")) {
            if (value.argument != null) return error.InvalidSql;
            if (value.value) |text| {
                if (std.ascii.eqlIgnoreCase(text, "on") or std.mem.eql(u8, text, "1")) {
                    self.recursiveTriggers = true;
                } else if (std.ascii.eqlIgnoreCase(text, "off") or std.mem.eql(u8, text, "0")) {
                    self.recursiveTriggers = false;
                } else return error.InvalidSql;
            }
            const names = [_][]const u8{"recursive_triggers"};
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 1);
            rows[0][0] = .{ .integer = if (self.recursiveTriggers) 1 else 0 };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "wal_checkpoint")) {
            const target = self.pragmaFileStore(value.schema);
            if (value.value != null) return error.InvalidSql;
            if (value.argument) |mode| {
                if (!std.ascii.eqlIgnoreCase(mode, "passive") and !std.ascii.eqlIgnoreCase(mode, "full") and !std.ascii.eqlIgnoreCase(mode, "restart") and !std.ascii.eqlIgnoreCase(mode, "truncate")) return error.InvalidSql;
            }
            const checkpoint = try target.file.checkpointWal();
            if (self.synchronousLevel >= 1) try target.file.file.sync(target.file.threaded.io());
            const names = [_][]const u8{ "busy", "log", "checkpointed" };
            const columns = try self.ownedColumns(&names);
            const rows = try self.allocator.alloc([]Value, 1);
            rows[0] = try self.allocator.alloc(Value, 3);
            rows[0][0] = .{ .integer = checkpoint.busy };
            rows[0][1] = .{ .integer = checkpoint.log };
            rows[0][2] = .{ .integer = checkpoint.checkpointed };
            return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
        }
        if (std.ascii.eqlIgnoreCase(value.name, "table_info")) return try self.pragmaTableInfo(value, false);
        if (std.ascii.eqlIgnoreCase(value.name, "table_xinfo")) return try self.pragmaTableInfo(value, true);
        if (std.ascii.eqlIgnoreCase(value.name, "index_list")) return try self.pragmaIndexList(value);
        if (std.ascii.eqlIgnoreCase(value.name, "index_info")) return try self.pragmaIndexInfo(value, false);
        if (std.ascii.eqlIgnoreCase(value.name, "index_xinfo")) return try self.pragmaIndexInfo(value, true);
        if (std.ascii.eqlIgnoreCase(value.name, "foreign_key_list")) return try self.pragmaForeignKeyList(value);
        if (std.ascii.eqlIgnoreCase(value.name, "database_list")) return try self.pragmaDatabaseList();
        if (std.ascii.eqlIgnoreCase(value.name, "table_list")) return try self.pragmaTableList(value);
        return error.Unsupported;
    }

    fn pragmaTargetName(text: ?[]const u8) ?[]const u8 {
        const raw = text orelse return null;
        if (raw.len == 0) return null;
        var name = raw;
        if (name.len >= 2) {
            const first = name[0];
            const last = name[name.len - 1];
            if ((first == '\'' and last == '\'') or (first == '"' and last == '"') or (first == '`' and last == '`') or (first == '[' and last == ']')) name = name[1 .. name.len - 1];
        }
        if (name.len == 0) return null;
        return name;
    }

    fn pragmaArgumentName(value: anytype) ?[]const u8 {
        if (pragmaTargetName(value.argument)) |name| return name;
        return pragmaTargetName(value.value);
    }

    fn pragmaScopedTarget(self: *Connection, value: anytype, owned: *?[]u8) ?[]const u8 {
        const target = pragmaArgumentName(value) orelse return null;
        if (value.schema) |schemaName| {
            if (splitSchemaName(target).qualifier == null) {
                const combined = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ schemaName, target }) catch return null;
                owned.* = combined;
                return combined;
            }
        }
        return target;
    }

    fn pragmaSchemaIsTemp(value: anytype) bool {
        if (value.schema) |schemaName| return std.ascii.eqlIgnoreCase(schemaName, "temp");
        return false;
    }

    const PragmaFile = struct { file: *DatabaseFile, store: *Schema };

    fn pragmaFileStore(self: *Connection, schemaName: ?[]const u8) PragmaFile {
        if (schemaName) |name| {
            if (self.resolveSchema(name)) |ref| {
                if (ref == .attached) {
                    const index = ref.attached;
                    return .{ .file = &self.attached.items[index].file, .store = &self.attached.items[index].store };
                }
            }
        }
        return .{ .file = &self.file, .store = &self.store };
    }

    fn fkActionName(action: ast.ReferentialAction) []const u8 {
        return switch (action) {
            .cascade => "CASCADE",
            .restrict => "RESTRICT",
            .setNull => "SET NULL",
            .setDefault => "SET DEFAULT",
            .noAction => "NO ACTION",
        };
    }

    fn defaultValueSql(self: *Connection, value: Value) !?[]u8 {
        return switch (value) {
            .null => null,
            .integer => |i| try std.fmt.allocPrint(self.allocator, "{d}", .{i}),
            .real => |r| try std.fmt.allocPrint(self.allocator, "{d}", .{r}),
            .text => |text| blk: {
                var out = std.ArrayList(u8).empty;
                errdefer out.deinit(self.allocator);
                try out.append(self.allocator, '\'');
                for (text) |c| {
                    if (c == '\'') try out.appendSlice(self.allocator, "''") else try out.append(self.allocator, c);
                }
                try out.append(self.allocator, '\'');
                break :blk try out.toOwnedSlice(self.allocator);
            },
            .blob => |blob| blk: {
                const hex = "0123456789ABCDEF";
                var out = std.ArrayList(u8).empty;
                errdefer out.deinit(self.allocator);
                try out.appendSlice(self.allocator, "X'");
                for (blob) |c| {
                    try out.append(self.allocator, hex[c >> 4]);
                    try out.append(self.allocator, hex[c & 15]);
                }
                try out.append(self.allocator, '\'');
                break :blk try out.toOwnedSlice(self.allocator);
            },
        };
    }

    fn pragmaTableInfo(self: *Connection, value: anytype, extended: bool) !Result {
        const headers: []const []const u8 = if (extended) &[_][]const u8{ "cid", "name", "type", "notnull", "dflt_value", "pk", "hidden" } else &[_][]const u8{ "cid", "name", "type", "notnull", "dflt_value", "pk" };
        const columns = try self.ownedColumns(headers);
        var rows = std.ArrayList([]Value).empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |item| self.freeConcatText(item);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        var ownedTarget: ?[]u8 = null;
        defer if (ownedTarget) |target| self.allocator.free(target);
        const target = self.pragmaScopedTarget(value, &ownedTarget);
        if (target) |name| {
            if (!pragmaSchemaIsTemp(value)) {
                const resolvedTable = self.resolveTableName(name);
                if (resolvedTable) |resolved| {
                    const tbl = resolved.table;
                    var pkOrder: [64][]const u8 = undefined;
                    var pkCount: usize = 0;
                    for (tbl.columns) |column| {
                        if (column.primaryKey and pkCount < pkOrder.len) {
                            pkOrder[pkCount] = column.name;
                            pkCount += 1;
                        }
                    }
                    if (pkCount == 0) {
                        for (tbl.constraints) |constraint| {
                            if (constraint.kind != .primaryKey) continue;
                            for (constraint.columns) |columnName| {
                                if (pkCount >= pkOrder.len) break;
                                pkOrder[pkCount] = columnName;
                                pkCount += 1;
                            }
                        }
                    }
                    var cid: i64 = 0;
                    for (tbl.columns) |column| {
                        const generated = column.generatedExpr != null;
                        if (generated and !extended) continue;
                        const row = try self.allocator.alloc(Value, headers.len);
                        errdefer self.allocator.free(row);
                        row[0] = .{ .integer = cid };
                        row[1] = .{ .text = try self.allocator.dupe(u8, column.name) };
                        row[2] = .{ .text = try self.allocator.dupe(u8, column.typeName) };
                        row[3] = .{ .integer = if (column.notNull) 1 else 0 };
                        if (generated) {
                            row[4] = .null;
                        } else if (column.defaultValue) |default| {
                            row[4] = if (try self.defaultValueSql(default)) |sql| .{ .text = sql } else .null;
                        } else row[4] = .null;
                        var pk: i64 = 0;
                        for (pkOrder[0..pkCount], 0..) |pkName, position| if (std.ascii.eqlIgnoreCase(pkName, column.name)) {
                            pk = @intCast(position + 1);
                            break;
                        };
                        row[5] = .{ .integer = pk };
                        if (extended) row[6] = .{ .integer = if (!generated) 0 else if (column.generatedStored) 3 else 2 };
                        try rows.append(self.allocator, row);
                        cid += 1;
                    }
                } else if (self.resolveViewName(name)) |resolvedView| {
                    const view = resolvedView.view;
                    const viewColumns = try self.viewColumnNames(view);
                    defer {
                        for (viewColumns) |columnName| self.allocator.free(columnName);
                        self.allocator.free(viewColumns);
                    }
                    for (viewColumns, 0..) |columnName, position| {
                        const row = try self.allocator.alloc(Value, headers.len);
                        errdefer self.allocator.free(row);
                        row[0] = .{ .integer = @intCast(position) };
                        row[1] = .{ .text = try self.allocator.dupe(u8, columnName) };
                        row[2] = .{ .text = try self.allocator.dupe(u8, "") };
                        row[3] = .{ .integer = 0 };
                        row[4] = .null;
                        row[5] = .{ .integer = 0 };
                        if (extended) row[6] = .{ .integer = 0 };
                        try rows.append(self.allocator, row);
                    }
                }
            }
        }
        return .{ .allocator = self.allocator, .columns = columns, .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn viewColumnNames(self: *Connection, view: *const View) ![][]const u8 {
        var quoted = std.ArrayList(u8).empty;
        defer quoted.deinit(self.allocator);
        try quoted.append(self.allocator, '"');
        for (view.name) |c| {
            if (c == '"') try quoted.appendSlice(self.allocator, "\"\"") else try quoted.append(self.allocator, c);
        }
        try quoted.appendSlice(self.allocator, "\" LIMIT 0");
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{quoted.items});
        defer self.allocator.free(sql);
        var result = try self.exec(sql);
        defer result.deinit();
        const names = try self.allocator.alloc([]const u8, result.columns.len);
        errdefer self.allocator.free(names);
        for (result.columns, 0..) |column, index| names[index] = try self.allocator.dupe(u8, column);
        return names;
    }

    fn pragmaIndexList(self: *Connection, value: anytype) !Result {
        const names = [_][]const u8{ "seq", "name", "unique", "origin", "partial" };
        const columns = try self.ownedColumns(&names);
        var rows = std.ArrayList([]Value).empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |item| self.freeConcatText(item);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        var scopedOwned: ?[]u8 = null;
        defer if (scopedOwned) |owned| self.allocator.free(owned);
        if (self.pragmaScopedTarget(value, &scopedOwned)) |name| {
            if (!pragmaSchemaIsTemp(value)) {
                const resolvedTable = self.resolveTableName(name);
                if (resolvedTable) |resolved| {
                    const tbl = resolved.table;
                    const store = self.storeFor(resolved.ref);
                    var seq: i64 = 0;
                    for (store.indexes.items) |index| {
                        if (!std.ascii.eqlIgnoreCase(index.table, tbl.name)) continue;
                        const row = try self.allocator.alloc(Value, names.len);
                        errdefer self.allocator.free(row);
                        row[0] = .{ .integer = seq };
                        row[1] = .{ .text = try self.allocator.dupe(u8, index.name) };
                        row[2] = .{ .integer = if (index.unique) 1 else 0 };
                        row[3] = .{ .text = try self.allocator.dupe(u8, self.indexOrigin(tbl, &index)) };
                        row[4] = .{ .integer = if (index.whereExpr != null) 1 else 0 };
                        try rows.append(self.allocator, row);
                        seq += 1;
                    }
                }
            }
        }
        return .{ .allocator = self.allocator, .columns = columns, .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn indexOrigin(self: *Connection, tbl: *const Table, index: *const Index) []const u8 {
        _ = self;
        if (!std.mem.startsWith(u8, index.name, "sqlite_autoindex_")) return "c";
        for (tbl.constraints) |constraint| {
            if (constraint.kind != .primaryKey and constraint.kind != .unique) continue;
            if (constraint.columns.len != index.columns.len) continue;
            var columnsMatch = true;
            for (constraint.columns, 0..) |constraintColumn, position| {
                if (index.keyExpr(position) != null or !std.ascii.eqlIgnoreCase(constraintColumn, index.columns[position])) {
                    columnsMatch = false;
                    break;
                }
            }
            if (columnsMatch) return if (constraint.kind == .primaryKey) "pk" else "u";
        }
        if (index.columns.len == 1 and index.keyExpr(0) == null) {
            if (columnIndex(tbl, index.columns[0])) |position| {
                if (tbl.columns[position].primaryKey) return "pk";
            } else |_| {}
        }
        return "u";
    }

    fn pragmaIndexInfo(self: *Connection, value: anytype, extended: bool) !Result {
        const headers: []const []const u8 = if (extended) &[_][]const u8{ "seqno", "cid", "name", "desc", "coll", "key" } else &[_][]const u8{ "seqno", "cid", "name" };
        const columns = try self.ownedColumns(headers);
        var rows = std.ArrayList([]Value).empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |item| self.freeConcatText(item);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        var scopedOwned: ?[]u8 = null;
        defer if (scopedOwned) |owned| self.allocator.free(owned);
        if (self.pragmaScopedTarget(value, &scopedOwned)) |name| {
            if (!pragmaSchemaIsTemp(value)) {
                const resolvedIndex = self.resolveIndexName(name);
                if (resolvedIndex) |resolved| {
                    const index = resolved.index;
                    const store = self.storeFor(resolved.ref);
                    if (store.findConst(index.table)) |tbl| {
                        for (index.columns, 0..) |keyColumn, position| {
                            const row = try self.allocator.alloc(Value, headers.len);
                            errdefer self.allocator.free(row);
                            row[0] = .{ .integer = @intCast(position) };
                            if (index.keyExpr(position) != null) {
                                row[1] = .{ .integer = -1 };
                                row[2] = .null;
                            } else if (columnIndex(tbl, keyColumn)) |columnPosition| {
                                row[1] = .{ .integer = @intCast(columnPosition) };
                                row[2] = .{ .text = try self.allocator.dupe(u8, tbl.columns[columnPosition].name) };
                            } else |_| {
                                row[1] = .{ .integer = -1 };
                                row[2] = .null;
                            }
                            if (extended) {
                                row[3] = .{ .integer = 0 };
                                row[4] = .{ .text = try self.allocator.dupe(u8, "BINARY") };
                                row[5] = .{ .integer = 1 };
                            }
                            try rows.append(self.allocator, row);
                        }
                    }
                }
            }
        }
        return .{ .allocator = self.allocator, .columns = columns, .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn pragmaForeignKeyList(self: *Connection, value: anytype) !Result {
        const names = [_][]const u8{ "id", "seq", "table", "from", "to", "on_update", "on_delete", "match" };
        const columns = try self.ownedColumns(&names);
        var rows = std.ArrayList([]Value).empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |item| self.freeConcatText(item);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        var scopedOwned: ?[]u8 = null;
        defer if (scopedOwned) |owned| self.allocator.free(owned);
        if (self.pragmaScopedTarget(value, &scopedOwned)) |name| {
            if (!pragmaSchemaIsTemp(value)) {
                const resolvedTable = self.resolveTableName(name);
                if (resolvedTable) |resolved| {
                    const tbl = resolved.table;
                    var id: i64 = 0;
                    for (tbl.columns) |column| {
                        const foreignTable = column.foreignTable orelse continue;
                        const row = try self.allocator.alloc(Value, names.len);
                        errdefer self.allocator.free(row);
                        row[0] = .{ .integer = id };
                        row[1] = .{ .integer = 0 };
                        row[2] = .{ .text = try self.allocator.dupe(u8, foreignTable) };
                        row[3] = .{ .text = try self.allocator.dupe(u8, column.name) };
                        row[4] = if (column.foreignColumn) |foreignColumn| .{ .text = try self.allocator.dupe(u8, foreignColumn) } else .null;
                        row[5] = .{ .text = try self.allocator.dupe(u8, fkActionName(column.onUpdate)) };
                        row[6] = .{ .text = try self.allocator.dupe(u8, fkActionName(column.onDelete)) };
                        row[7] = .{ .text = try self.allocator.dupe(u8, "NONE") };
                        try rows.append(self.allocator, row);
                        id += 1;
                    }
                    for (tbl.constraints) |constraint| {
                        if (constraint.kind != .foreignKey) continue;
                        const foreignTable = constraint.foreignTable orelse continue;
                        for (constraint.columns, 0..) |childColumn, position| {
                            const row = try self.allocator.alloc(Value, names.len);
                            errdefer self.allocator.free(row);
                            row[0] = .{ .integer = id };
                            row[1] = .{ .integer = @intCast(position) };
                            row[2] = .{ .text = try self.allocator.dupe(u8, foreignTable) };
                            row[3] = .{ .text = try self.allocator.dupe(u8, childColumn) };
                            if (position < constraint.referencedColumns.len) {
                                row[4] = .{ .text = try self.allocator.dupe(u8, constraint.referencedColumns[position]) };
                            } else row[4] = .null;
                            row[5] = .{ .text = try self.allocator.dupe(u8, fkActionName(constraint.onUpdate)) };
                            row[6] = .{ .text = try self.allocator.dupe(u8, fkActionName(constraint.onDelete)) };
                            row[7] = .{ .text = try self.allocator.dupe(u8, "NONE") };
                            try rows.append(self.allocator, row);
                        }
                        id += 1;
                    }
                }
            }
        }
        return .{ .allocator = self.allocator, .columns = columns, .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn pragmaDatabaseList(self: *Connection) !Result {
        const names = [_][]const u8{ "seq", "name", "file" };
        const columns = try self.ownedColumns(&names);
        var rows = std.ArrayList([]Value).empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |item| self.freeConcatText(item);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        const mainRow = try self.allocator.alloc(Value, names.len);
        errdefer self.allocator.free(mainRow);
        mainRow[0] = .{ .integer = 0 };
        mainRow[1] = .{ .text = try self.allocator.dupe(u8, "main") };
        mainRow[2] = .{ .text = try self.allocator.dupe(u8, self.file.path) };
        try rows.append(self.allocator, mainRow);
        const tempRow = try self.allocator.alloc(Value, names.len);
        errdefer self.allocator.free(tempRow);
        tempRow[0] = .{ .integer = 1 };
        tempRow[1] = .{ .text = try self.allocator.dupe(u8, "temp") };
        tempRow[2] = .{ .text = try self.allocator.dupe(u8, "") };
        try rows.append(self.allocator, tempRow);
        for (self.attached.items, 0..) |db, index| {
            const attachedRow = try self.allocator.alloc(Value, names.len);
            errdefer self.allocator.free(attachedRow);
            attachedRow[0] = .{ .integer = @intCast(index + 2) };
            attachedRow[1] = .{ .text = try self.allocator.dupe(u8, db.name) };
            attachedRow[2] = .{ .text = try self.allocator.dupe(u8, db.file.path) };
            try rows.append(self.allocator, attachedRow);
        }
        return .{ .allocator = self.allocator, .columns = columns, .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn pragmaTableList(self: *Connection, value: anytype) !Result {
        const names = [_][]const u8{ "schema", "name", "type", "ncol", "wr", "strict" };
        const columns = try self.ownedColumns(&names);
        var rows = std.ArrayList([]Value).empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |item| self.freeConcatText(item);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        const filter = pragmaArgumentName(value);
        const filterObject = if (filter) |wanted| splitSchemaName(wanted).object else null;
        if (value.schema) |schemaName| {
            const ref = self.resolveSchema(schemaName) orelse return .{ .allocator = self.allocator, .columns = columns, .rows = try rows.toOwnedSlice(self.allocator) };
            try self.appendTableListRows(self.storeFor(ref), self.schemaRefName(ref), filterObject, &rows);
        } else {
            try self.appendTableListRows(&self.store, "main", filterObject, &rows);
            try self.appendTableListRows(&self.tempStore, "temp", filterObject, &rows);
            for (self.attached.items) |db| try self.appendTableListRows(&db.store, db.name, filterObject, &rows);
        }
        return .{ .allocator = self.allocator, .columns = columns, .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn appendTableListRows(self: *Connection, store: *const Schema, schemaName: []const u8, filter: ?[]const u8, rows: *std.ArrayList([]Value)) !void {
        for (store.tables.items) |tbl| {
            if (filter) |wanted| if (!std.ascii.eqlIgnoreCase(wanted, tbl.name)) continue;
            const row = try self.allocator.alloc(Value, 6);
            errdefer self.allocator.free(row);
            row[0] = .{ .text = try self.allocator.dupe(u8, schemaName) };
            row[1] = .{ .text = try self.allocator.dupe(u8, tbl.name) };
            row[2] = .{ .text = try self.allocator.dupe(u8, if (tbl.virtualModule != null) "virtual" else "table") };
            row[3] = .{ .integer = @intCast(tbl.columns.len) };
            row[4] = .{ .integer = if (tbl.withoutRowid) 1 else 0 };
            row[5] = .{ .integer = if (tbl.strict) 1 else 0 };
            try rows.append(self.allocator, row);
        }
        for (store.views.items) |view| {
            if (filter) |wanted| if (!std.ascii.eqlIgnoreCase(wanted, view.name)) continue;
            const viewColumns = try self.viewColumnNames(&view);
            defer {
                for (viewColumns) |columnName| self.allocator.free(columnName);
                self.allocator.free(viewColumns);
            }
            const row = try self.allocator.alloc(Value, 6);
            errdefer self.allocator.free(row);
            row[0] = .{ .text = try self.allocator.dupe(u8, schemaName) };
            row[1] = .{ .text = try self.allocator.dupe(u8, view.name) };
            row[2] = .{ .text = try self.allocator.dupe(u8, "view") };
            row[3] = .{ .integer = @intCast(viewColumns.len) };
            row[4] = .{ .integer = 0 };
            row[5] = .{ .integer = 0 };
            try rows.append(self.allocator, row);
        }
    }

    fn attachCommand(self: *Connection, value: anytype) !Result {
        if (self.transactionActive or self.inAtomicStatement or self.savepoints.items.len != 0) return error.TransactionActive;
        if (std.ascii.eqlIgnoreCase(value.schemaName, "main") or std.ascii.eqlIgnoreCase(value.schemaName, "temp")) return error.InvalidSql;
        if (value.schemaName.len == 0 or self.resolveSchema(value.schemaName) != null) return error.InvalidSql;
        const pathValue = try self.resolve(value.expr, &.{});
        const ownedPath = value.expr == .binary or value.expr == .unary or value.expr == .function or value.expr == .caseExpr;
        defer if (ownedPath) self.freeConcatText(pathValue);
        const path = switch (pathValue) {
            .text => |text| text,
            .blob => |blob| blob,
            else => return error.InvalidSql,
        };
        if (path.len == 0 or std.mem.eql(u8, path, ":memory:")) return error.InvalidSql;
        var file = try DatabaseFile.open(self.allocator, path);
        errdefer file.close();
        var store = Schema.init(self.allocator);
        errdefer store.deinit();
        if (try file.readPayload()) |payload| {
            defer self.allocator.free(payload);
            const decoded = try image.decode(self.allocator, payload);
            store.deinit();
            store = decoded;
            try self.persistSchema(&file, &store);
        } else {
            const bytes = try file.readImage();
            defer self.allocator.free(bytes);
            if (bytes.len <= 100) return error.InvalidHeader;
            if (bytes[100] == 0x0d) {
                const decoded = try sqliteImage.decode(self.allocator, bytes);
                store.deinit();
                store = decoded;
            }
        }
        const ownedName = try self.allocator.dupe(u8, value.schemaName);
        errdefer self.allocator.free(ownedName);
        try self.attached.append(self.allocator, .{ .name = ownedName, .file = file, .store = store });
        return try emptyResult(self.allocator);
    }

    fn detachCommand(self: *Connection, name: []const u8) !Result {
        if (std.ascii.eqlIgnoreCase(name, "main") or std.ascii.eqlIgnoreCase(name, "temp")) return error.InvalidSql;
        if (self.transactionActive or self.inAtomicStatement or self.savepoints.items.len != 0) return error.TransactionActive;
        for (self.attached.items, 0..) |db, index| {
            if (!std.ascii.eqlIgnoreCase(db.name, name)) continue;
            var removed = self.attached.orderedRemove(index);
            removed.store.deinit();
            removed.file.close();
            self.allocator.free(removed.name);
            return try emptyResult(self.allocator);
        }
        return error.UnknownDatabase;
    }

    fn vacuumCommand(self: *Connection, schemaName: ?[]const u8, into: ?ast.Expr) !Result {
        if (self.transactionActive or self.savepoints.items.len != 0) return error.TransactionActive;
        var vacuumRef: SchemaRef = .main;
        if (schemaName) |name| {
            if (std.ascii.eqlIgnoreCase(name, "temp")) return error.Unsupported;
            if (!std.ascii.eqlIgnoreCase(name, "main")) {
                const resolved = self.resolveSchema(name) orelse return error.UnknownDatabase;
                if (resolved != .attached) return error.Unsupported;
                vacuumRef = resolved;
            }
        }
        const vacuumFile = switch (vacuumRef) {
            .main => &self.file,
            .temp => return error.Unsupported,
            .attached => |index| &self.attached.items[index].file,
        };
        const vacuumStore = self.storeFor(vacuumRef);
        if (into) |intoExpr| {
            const target = switch (intoExpr) {
                .literal => |lit| switch (lit) {
                    .text => |t| t,
                    else => return error.InvalidSql,
                },
                else => return error.InvalidSql,
            };
            if (target.len == 0) return error.InvalidSql;
            if (std.ascii.eqlIgnoreCase(target, vacuumFile.path)) return error.InvalidSql;
            const bytes = try sqliteImage.encodeWithPageSize(self.allocator, vacuumStore, vacuumFile.pageSize);
            defer self.allocator.free(bytes);
            const io = vacuumFile.threaded.io();
            var outFile = std.Io.Dir.cwd().openFile(io, target, .{ .mode = .read_write }) catch |err| switch (err) {
                error.FileNotFound => try std.Io.Dir.cwd().createFile(io, target, .{ .read = true, .truncate = true }),
                else => return err,
            };
            defer outFile.close(io);
            try outFile.writePositionalAll(io, bytes, 0);
            try outFile.setLength(io, bytes.len);
            if (self.synchronousLevel >= 1) try outFile.sync(io);
            return try emptyResult(self.allocator);
        }
        try self.persistSchema(vacuumFile, vacuumStore);
        return try emptyResult(self.allocator);
    }

    fn analyzeDatabase(self: *Connection, target: ?[]const u8) !void {
        if (target) |name| {
            const parts = splitSchemaName(name);
            if (parts.qualifier) |qualifier| {
                const ref = self.resolveSchema(qualifier) orelse return error.UnknownDatabase;
                return self.analyzeDatabaseOn(self.storeFor(ref), ref, parts.object);
            }
            if (std.ascii.eqlIgnoreCase(name, "main")) return self.analyzeDatabaseOn(&self.store, .main, null);
            if (std.ascii.eqlIgnoreCase(name, "temp")) return self.analyzeDatabaseOn(&self.tempStore, .temp, null);
            if (self.tempStore.find(name) != null) return self.analyzeDatabaseOn(&self.tempStore, .temp, name);
            if (self.store.find(name) != null) return self.analyzeDatabaseOn(&self.store, .main, name);
            for (self.attached.items, 0..) |*db, index| {
                if (db.store.find(name) != null) return self.analyzeDatabaseOn(&db.store, .{ .attached = index }, name);
            }
            if (self.tempStore.findIndexConst(name) != null) return self.analyzeDatabaseOn(&self.tempStore, .temp, name);
            if (self.store.findIndexConst(name) != null) return self.analyzeDatabaseOn(&self.store, .main, name);
            for (self.attached.items, 0..) |*db, index| {
                if (db.store.findIndexConst(name) != null) return self.analyzeDatabaseOn(&db.store, .{ .attached = index }, name);
            }
            return error.UnknownTable;
        }
        return self.analyzeDatabaseOn(&self.store, .main, null);
    }

    fn analyzeDatabaseOn(self: *Connection, store: *Schema, ref: SchemaRef, target: ?[]const u8) !void {
        if (target) |name| {
            if (store.find(name) != null) {
                return self.analyzeScopeOn(store, ref, name);
            }
            for (store.indexes.items) |index| {
                if (std.ascii.eqlIgnoreCase(index.name, name)) {
                    const tbl = store.find(index.table) orelse return error.UnknownTable;
                    store.clearStatScope(tbl.name, index.name);
                    return store.collectIndexStats(tbl, &index);
                }
            }
            return error.UnknownTable;
        }
        return self.analyzeScopeOn(store, ref, null);
    }

    fn analyzeScope(self: *Connection, tableName: ?[]const u8) !void {
        return self.analyzeScopeOn(&self.store, .main, tableName);
    }

    fn analyzeScopeOn(self: *Connection, store: *Schema, ref: SchemaRef, tableName: ?[]const u8) !void {
        const hadStat = store.find("sqlite_stat1") != null;
        _ = try store.ensureStatTable();
        if (!hadStat) {
            if (ref == .attached) {
                const file = &self.attached.items[ref.attached].file;
                file.setSchemaVersion(file.getSchemaVersion() +% 1);
            } else if (ref == .main) {
                self.bumpSchemaVersion();
            }
        }
        for (store.tables.items) |tbl| {
            if (std.ascii.eqlIgnoreCase(tbl.name, "sqlite_stat1")) continue;
            if (tableName) |wanted| if (!std.ascii.eqlIgnoreCase(tbl.name, wanted)) continue;
            store.clearStatScope(tbl.name, null);
            try store.collectTableStats(tbl);
            for (store.indexes.items) |index| {
                if (!std.ascii.eqlIgnoreCase(index.table, tbl.name)) continue;
                try store.collectIndexStats(tbl, &index);
            }
        }
    }

    fn integrityProblem(self: *Connection, rows: *std.ArrayList([]Value), cap: usize, comptime fmt: []const u8, args: anytype) !void {
        if (rows.items.len >= cap) return;
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(text);
        const row = try self.allocator.alloc(Value, 1);
        errdefer self.allocator.free(row);
        row[0] = .{ .text = text };
        try rows.append(self.allocator, row);
    }

    fn pragmaIntegrityCheck(self: *Connection, value: anytype) !Result {
        if (value.value != null) return error.InvalidSql;
        var cap: usize = 100;
        var scope: ?[]const u8 = null;
        if (value.argument) |arg| {
            if (std.fmt.parseInt(isize, arg, 10)) |n| {
                if (n > 0) cap = @intCast(n);
            } else |_| {
                if (self.store.findConst(arg) == null) return error.UnknownTable;
                scope = arg;
            }
        }
        var rowList = std.ArrayList([]Value).empty;
        errdefer {
            for (rowList.items) |r| {
                for (r) |v| if (v == .text) self.allocator.free(v.text);
                self.allocator.free(r);
            }
            rowList.deinit(self.allocator);
        }
        try self.checkStoredImage(&rowList, cap, scope);
        try self.checkStoredRows(&rowList, cap, scope);
        if (rowList.items.len == 0) try self.integrityProblem(&rowList, cap, "ok", .{});
        const names = [_][]const u8{"integrity_check"};
        const columns = try self.ownedColumns(&names);
        const rows = try rowList.toOwnedSlice(self.allocator);
        return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
    }

    fn checkStoredImage(self: *Connection, rows: *std.ArrayList([]Value), cap: usize, scope: ?[]const u8) !void {
        const stat = try self.file.file.stat(self.file.threaded.io());
        const bytes = try self.file.readBytes(0, @intCast(stat.size));
        defer self.allocator.free(bytes);
        if (try self.file.readPayload()) |payload| {
            defer self.allocator.free(payload);
            var stored = @import("../storage/image.zig").decode(self.allocator, payload) catch |err| {
                try self.integrityProblem(rows, cap, "stored payload failed to decode: {s}", .{@errorName(err)});
                return;
            };
            defer stored.deinit();
            try self.compareStoredSchema(rows, cap, &stored, scope);
            return;
        }
        if (bytes.len < 100) {
            try self.integrityProblem(rows, cap, "database file is smaller than the 100-byte header", .{});
            return;
        }
        var header: [100]u8 = undefined;
        @memcpy(header[0..], bytes[0..100]);
        _ = @import("../format/header.zig").Header.decode(&header) catch {
            try self.integrityProblem(rows, cap, "database file header is malformed", .{});
        };
        var stored = @import("../storage/sqlite_image.zig").decode(self.allocator, bytes) catch |err| {
            try self.integrityProblem(rows, cap, "database image failed to decode: {s}", .{@errorName(err)});
            return;
        };
        defer stored.deinit();
        try self.compareStoredSchema(rows, cap, &stored, scope);
    }

    fn compareStoredSchema(self: *Connection, rows: *std.ArrayList([]Value), cap: usize, stored: *const Schema, scope: ?[]const u8) !void {
        for (self.store.tables.items) |live| {
            if (scope != null and !std.ascii.eqlIgnoreCase(scope.?, live.name)) continue;
            if (live.virtualModule != null) continue;
            const saved = stored.findConst(live.name) orelse {
                try self.integrityProblem(rows, cap, "table {s} is missing from the stored image", .{live.name});
                continue;
            };
            if (saved.rows.items.len != live.rows.items.len) {
                try self.integrityProblem(rows, cap, "table {s} has {d} live rows but stored image has {d}", .{ live.name, live.rows.items.len, saved.rows.items.len });
                continue;
            }
            const matched = try self.allocator.alloc(bool, saved.rows.items.len);
            defer self.allocator.free(matched);
            @memset(matched, false);
            var missing: usize = 0;
            for (live.rows.items) |row| {
                var found = false;
                for (saved.rows.items, 0..) |savedRow, index| {
                    if (!matched[index] and rowsEqual(row.values, savedRow.values)) {
                        matched[index] = true;
                        found = true;
                        break;
                    }
                }
                if (!found) missing += 1;
            }
            var extra: usize = 0;
            for (matched) |wasMatched| {
                if (!wasMatched) extra += 1;
            }
            if (missing != 0 or extra != 0) {
                try self.integrityProblem(rows, cap, "table {s} content differs from the stored image: {d} live rows unmatched, {d} stored rows unmatched", .{ live.name, missing, extra });
            }
        }
        for (stored.tables.items) |saved| {
            if (scope != null and !std.ascii.eqlIgnoreCase(scope.?, saved.name)) continue;
            if (self.store.findConst(saved.name) == null) {
                try self.integrityProblem(rows, cap, "table {s} is missing from the live schema", .{saved.name});
            }
        }
        for (self.store.indexes.items) |*index| {
            if (stored.findIndexConst(index.name) == null) {
                try self.integrityProblem(rows, cap, "index {s} is missing from the stored image", .{index.name});
            }
        }
        for (stored.indexes.items) |*index| {
            if (self.store.findIndexConst(index.name) == null) {
                try self.integrityProblem(rows, cap, "index {s} is missing from the live schema", .{index.name});
            }
        }
    }

    fn checkStoredRows(self: *Connection, rows: *std.ArrayList([]Value), cap: usize, scope: ?[]const u8) !void {
        const savedFlag = self.store.foreignKeysEnabled;
        self.store.foreignKeysEnabled = false;
        defer self.store.foreignKeysEnabled = savedFlag;
        for (self.store.tables.items) |tbl| {
            if (scope != null and !std.ascii.eqlIgnoreCase(scope.?, tbl.name)) continue;
            if (tbl.virtualModule != null) continue;
            for (tbl.rows.items, 0..) |row, rowIndex| {
                if (row.values.len != tbl.columns.len) {
                    try self.integrityProblem(rows, cap, "table {s} row {d} has {d} values but table has {d} columns", .{ tbl.name, rowIndex + 1, row.values.len, tbl.columns.len });
                    continue;
                }
                self.store.validateExistingRow(tbl, rowIndex) catch |err| switch (err) {
                    error.ConstraintViolation, error.UnknownColumn => try self.integrityProblem(rows, cap, "table {s} row {d} violates a stored constraint", .{ tbl.name, rowIndex + 1 }),
                    else => return err,
                };
            }
        }
    }

    fn pragmaForeignKeyCheck(self: *Connection, value: anytype) !Result {
        if (value.value != null) return error.InvalidSql;
        var scope: ?[]const u8 = null;
        if (value.argument) |arg| {
            if (self.store.findConst(arg) == null) return error.UnknownTable;
            scope = arg;
        }
        const names = [_][]const u8{ "table", "rowid", "fktable", "fkid" };
        const columns = try self.ownedColumns(&names);
        errdefer {
            for (columns) |column| self.allocator.free(column);
            self.allocator.free(columns);
        }
        var rowList = std.ArrayList([]Value).empty;
        errdefer {
            for (rowList.items) |r| {
                for (r) |v| if (v == .text) self.allocator.free(v.text);
                self.allocator.free(r);
            }
            rowList.deinit(self.allocator);
        }
        for (self.store.tables.items) |tbl| {
            if (scope != null and !std.ascii.eqlIgnoreCase(scope.?, tbl.name)) continue;
            if (tbl.virtualModule != null) continue;
            for (tbl.rows.items, 0..) |row, rowIndex| {
                if (row.values.len != tbl.columns.len) continue;
                var fkid: i64 = 0;
                for (tbl.columns, 0..) |*column, childIndex| {
                    const foreignTableName = column.foreignTable orelse continue;
                    const parent = self.store.findConst(foreignTableName) orelse return error.ConstraintViolation;
                    const foreignColumnName = column.foreignColumn orelse return error.ConstraintViolation;
                    const parentIndex = columnIndex(parent, foreignColumnName) catch return error.ConstraintViolation;
                    defer fkid += 1;
                    if (row.values[childIndex] == .null) continue;
                    var found = false;
                    for (parent.rows.items) |parentRow| {
                        if (parentRow.values.len != parent.columns.len) continue;
                        if (@import("../catalog/schema.zig").valuesEqual(parentRow.values[parentIndex], row.values[childIndex])) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try self.foreignKeyViolation(&rowList, tbl, rowIndex, foreignTableName, fkid);
                }
                for (tbl.constraints) |*constraint| {
                    if (constraint.kind != .foreignKey) continue;
                    const foreignTableName = constraint.foreignTable orelse return error.ConstraintViolation;
                    const parent = self.store.findConst(foreignTableName) orelse return error.ConstraintViolation;
                    defer fkid += 1;
                    var hasNull = false;
                    for (constraint.columns) |childName| {
                        const childIndex = columnIndex(tbl, childName) catch return error.ConstraintViolation;
                        if (row.values[childIndex] == .null) hasNull = true;
                    }
                    if (hasNull) continue;
                    var found = false;
                    for (parent.rows.items) |parentRow| {
                        if (parentRow.values.len != parent.columns.len) continue;
                        var matched = true;
                        for (constraint.columns, constraint.referencedColumns) |childName, parentName| {
                            const childIndex = columnIndex(tbl, childName) catch return error.ConstraintViolation;
                            const parentIndex = columnIndex(parent, parentName) catch return error.ConstraintViolation;
                            if (!@import("../catalog/schema.zig").valuesEqual(row.values[childIndex], parentRow.values[parentIndex])) matched = false;
                        }
                        if (matched) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try self.foreignKeyViolation(&rowList, tbl, rowIndex, foreignTableName, fkid);
                }
            }
        }
        const rows = try rowList.toOwnedSlice(self.allocator);
        return .{ .allocator = self.allocator, .columns = columns, .rows = rows };
    }

    fn foreignKeyViolation(self: *Connection, rows: *std.ArrayList([]Value), tbl: *const Table, rowIndex: usize, parentName: []const u8, fkid: i64) !void {
        const row = try self.allocator.alloc(Value, 4);
        row[0] = .null;
        row[1] = .null;
        row[2] = .null;
        row[3] = .null;
        errdefer self.freeCompoundRow(row);
        row[0] = .{ .text = try self.allocator.dupe(u8, tbl.name) };
        row[1] = if (tbl.withoutRowid) .null else .{ .integer = @intCast(rowIndex + 1) };
        row[2] = .{ .text = try self.allocator.dupe(u8, parentName) };
        row[3] = .{ .integer = fkid };
        try rows.append(self.allocator, row);
    }

    fn explainQueryPlan(self: *Connection, sql: []const u8) anyerror!Result {
        var parser = try Parser.init(self.allocator, sql);
        defer parser.deinit();
        var statement = try parser.parse();
        defer ast.deinit(self.allocator, &statement);
        if (statement != .select) return error.InvalidSql;
        const query = statement.select;
        var plan = try self.planSelectQuery(query);
        defer plan.deinit();
        const detail = try plan.explain(self.allocator);
        defer self.allocator.free(detail);
        const columns = [_][]const u8{"detail"};
        const resultColumns = try self.ownedColumns(&columns);
        var lines = std.mem.splitScalar(u8, detail, '\n');
        var rowList = std.ArrayList([]Value).empty;
        errdefer {
            for (rowList.items) |r| {
                for (r) |v| if (v == .text) self.allocator.free(v.text);
                self.allocator.free(r);
            }
            rowList.deinit(self.allocator);
        }
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const row = try self.allocator.alloc(Value, 1);
            row[0] = .{ .text = try self.allocator.dupe(u8, line) };
            try rowList.append(self.allocator, row);
        }
        const rows = try rowList.toOwnedSlice(self.allocator);
        return .{ .allocator = self.allocator, .columns = resultColumns, .rows = rows };
    }

    fn planSelectQuery(self: *Connection, query: anytype) !planner.QueryPlan {
        if (query.table) |tableName| {
            const parts = splitSchemaName(tableName);
            if (parts.qualifier) |qualifier| {
                const ref = self.resolveSchema(qualifier) orelse return error.UnknownDatabase;
                var stripped = query;
                stripped.table = parts.object;
                return planner.planSelect(self.allocator, self.storeFor(ref), stripped);
            }
        }
        return planner.planSelect(self.allocator, &self.store, query);
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
        const target = try self.createTarget(value.name, value.temporary);
        if (target.store.find(target.name) != null and value.ifNotExists) return try emptyResult(self.allocator);
        try target.store.createTableWithOptions(target.name, value.columns, value.constraints, .{ .strict = value.strict, .withoutRowid = value.withoutRowid });
        return try emptyResult(self.allocator);
    }
    fn alterTableCommand(self: *Connection, value: ast.AlterTable) !Result {
        switch (value) {
            .addColumn => |change| {
                const resolved = self.resolveTableName(change.table) orelse return error.UnknownTable;
                try self.storeFor(resolved.ref).addColumn(splitSchemaName(change.table).object, change.definition);
            },
            .renameTable => |change| {
                if (splitSchemaName(change.newName).qualifier != null) return error.InvalidSql;
                const resolved = self.resolveTableName(change.table) orelse return error.UnknownTable;
                try self.storeFor(resolved.ref).renameTable(splitSchemaName(change.table).object, change.newName);
            },
            .renameColumn => |change| {
                const resolved = self.resolveTableName(change.table) orelse return error.UnknownTable;
                try self.storeFor(resolved.ref).renameColumn(splitSchemaName(change.table).object, change.oldName, change.newName);
            },
            .dropColumn => |change| {
                const resolved = self.resolveTableName(change.table) orelse return error.UnknownTable;
                try self.storeFor(resolved.ref).dropColumn(splitSchemaName(change.table).object, change.column);
            },
        }
        return try emptyResult(self.allocator);
    }
    fn dropTableCommand(self: *Connection, name: []const u8, ifExists: bool) !Result {
        const resolved = self.resolveTableName(name) orelse {
            if (ifExists) return try emptyResult(self.allocator);
            const parts = splitSchemaName(name);
            if (parts.qualifier != null and self.resolveSchema(parts.qualifier.?) == null) return error.UnknownDatabase;
            return error.UnknownTable;
        };
        self.storeFor(resolved.ref).dropTable(splitSchemaName(name).object) catch |err| if (ifExists and err == error.UnknownTable) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }
    fn createIndexCommand(self: *Connection, value: ast.IndexDef) !Result {
        const resolvedTable = self.resolveTableName(value.table) orelse return error.UnknownTable;
        const tableStore = self.storeFor(resolvedTable.ref);
        const nameParts = splitSchemaName(value.name);
        if (nameParts.qualifier) |qualifier| {
            const indexRef = self.resolveSchema(qualifier) orelse return error.UnknownDatabase;
            if (!std.meta.eql(indexRef, resolvedTable.ref)) return error.InvalidSql;
        }
        if (tableStore.findIndexConst(nameParts.object) != null and value.ifNotExists) return try emptyResult(self.allocator);
        var scoped = value;
        scoped.name = nameParts.object;
        scoped.table = resolvedTable.table.name;
        try tableStore.createIndex(scoped);
        return try emptyResult(self.allocator);
    }
    fn dropIndexCommand(self: *Connection, name: []const u8, ifExists: bool) !Result {
        const resolved = self.resolveIndexName(name) orelse {
            if (ifExists) return try emptyResult(self.allocator);
            const parts = splitSchemaName(name);
            if (parts.qualifier != null and self.resolveSchema(parts.qualifier.?) == null) return error.UnknownDatabase;
            return error.UnknownIndex;
        };
        self.storeFor(resolved.ref).dropIndex(splitSchemaName(name).object) catch |err| if (ifExists and err == error.UnknownIndex) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }
    fn createViewCommand(self: *Connection, value: anytype) !Result {
        const target = try self.createTarget(value.name, value.temporary);
        if (target.store.findViewConst(target.name) != null and value.ifNotExists) return try emptyResult(self.allocator);
        try target.store.createView(target.name, value.sql);
        return try emptyResult(self.allocator);
    }
    fn dropViewCommand(self: *Connection, name: []const u8, ifExists: bool) !Result {
        const resolved = self.resolveViewName(name) orelse {
            if (ifExists) return try emptyResult(self.allocator);
            const parts = splitSchemaName(name);
            if (parts.qualifier != null and self.resolveSchema(parts.qualifier.?) == null) return error.UnknownDatabase;
            return error.UnknownView;
        };
        self.storeFor(resolved.ref).dropView(splitSchemaName(name).object) catch |err| if (ifExists and err == error.UnknownView) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }
    fn createTriggerCommand(self: *Connection, value: ast.TriggerDef) !Result {
        const resolvedTable = self.resolveTableName(value.table) orelse return error.UnknownTable;
        const tableStore = self.storeFor(resolvedTable.ref);
        const nameParts = splitSchemaName(value.name);
        if (nameParts.qualifier) |qualifier| {
            const triggerRef = self.resolveSchema(qualifier) orelse return error.UnknownDatabase;
            if (!std.meta.eql(triggerRef, resolvedTable.ref)) return error.InvalidSql;
        }
        if (value.temporary and resolvedTable.ref != .temp) return error.InvalidSql;
        if (!value.temporary and resolvedTable.ref == .temp) return error.InvalidSql;
        if (tableStore.findTriggerConst(nameParts.object) != null and value.ifNotExists) return try emptyResult(self.allocator);
        var scoped = value;
        scoped.name = nameParts.object;
        scoped.table = resolvedTable.table.name;
        try tableStore.createTrigger(scoped);
        return try emptyResult(self.allocator);
    }
    fn createVirtualTableCommand(self: *Connection, value: ast.VirtualTableDef) !Result {
        const target = try self.createTarget(value.name, false);
        if (target.store.find(target.name) != null) {
            if (value.ifNotExists) return try emptyResult(self.allocator);
            return error.TableExists;
        }
        try target.store.createVirtualTable(target.name, value.module, value.arguments);
        return try emptyResult(self.allocator);
    }
    fn dropTriggerCommand(self: *Connection, name: []const u8, ifExists: bool) !Result {
        const resolved = self.resolveTriggerName(name) orelse {
            if (ifExists) return try emptyResult(self.allocator);
            const parts = splitSchemaName(name);
            if (parts.qualifier != null and self.resolveSchema(parts.qualifier.?) == null) return error.UnknownDatabase;
            return error.UnknownTrigger;
        };
        self.storeFor(resolved.ref).dropTrigger(splitSchemaName(name).object) catch |err| if (ifExists and err == error.UnknownTrigger) return try emptyResult(self.allocator) else return err;
        return try emptyResult(self.allocator);
    }

    fn setupCtes(self: *Connection, ctes: []const ast.CteDef, recursive: bool, parameters: []const Value) anyerror!usize {
        var created: usize = 0;
        errdefer self.teardownCtes(ctes[0..created]);
        for (ctes) |cte| {
            var source = try self.execute(cte.querySql, parameters);
            defer source.deinit();
            if (cte.columns.len != 0 and cte.columns.len != source.columns.len) return error.ColumnCountMismatch;
            const definitions = try self.allocator.alloc(ast.ColumnDef, source.columns.len);
            defer self.allocator.free(definitions);
            for (source.columns, 0..) |column, index| {
                const resolved = if (cte.columns.len != 0) cte.columns[index] else column;
                definitions[index] = .{ .name = resolved, .typeName = if (source.rows.len == 0) "" else source.rows[0][index].typeName() };
            }
            try self.store.createTable(cte.name, definitions, &.{});
            const tbl = self.store.find(cte.name).?;
            for (source.rows) |row| try self.store.appendRow(tbl, row);
            if (cte.recursiveSql) |recursiveSql| {
                if (!recursive) return error.Unsupported;
                if (cte.recursiveAll) {
                    var acc = std.ArrayList([]Value).empty;
                    defer {
                        for (acc.items) |row| {
                            for (row) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(row);
                        }
                        acc.deinit(self.allocator);
                    }
                    for (tbl.rows.items) |row| try acc.append(self.allocator, try self.cloneCompoundRow(row.values));
                    var iteration: usize = 0;
                    while (iteration < 1000) : (iteration += 1) {
                        var next = try self.execute(recursiveSql, parameters);
                        defer next.deinit();
                        if (next.rows.len == 0) break;
                        for (next.rows) |row| try acc.append(self.allocator, try self.cloneCompoundRow(row));
                        try self.store.truncateTable(cte.name);
                        const batch = self.store.find(cte.name).?;
                        for (next.rows) |row| try self.store.appendRow(batch, row);
                    } else return error.RecursiveCteLimit;
                    try self.store.truncateTable(cte.name);
                    const full = self.store.find(cte.name).?;
                    for (acc.items) |row| try self.store.appendRow(full, row);
                } else {
                    var iteration: usize = 0;
                    while (iteration < 1000) : (iteration += 1) {
                        var next = try self.execute(recursiveSql, parameters);
                        defer next.deinit();
                        var added: usize = 0;
                        for (next.rows) |row| {
                            var exists = false;
                            for (tbl.rows.items) |existing| if (rowsEqual(existing.values, row)) {
                                exists = true;
                                break;
                            };
                            if (!exists) {
                                try self.store.appendRow(tbl, row);
                                added += 1;
                            }
                        }
                        if (added == 0) break;
                    } else return error.RecursiveCteLimit;
                }
            }
            try self.activeCtes.append(self.allocator, cte.name);
            created += 1;
        }
        return created;
    }

    fn teardownCtes(self: *Connection, ctes: []const ast.CteDef) void {
        var remaining = ctes.len;
        while (remaining > 0) {
            remaining -= 1;
            if (self.activeCtes.items.len != 0) _ = self.activeCtes.pop();
            self.store.dropTable(ctes[remaining].name) catch {};
        }
    }

    fn cteActive(self: *Connection, name: []const u8) bool {
        for (self.activeCtes.items) |active| if (std.ascii.eqlIgnoreCase(active, name)) return true;
        return false;
    }

    fn executeWith(self: *Connection, value: ast.WithSelect, parameters: []const Value) anyerror!Result {
        const created = try self.setupCtes(value.ctes, value.recursive, parameters);
        defer self.teardownCtes(value.ctes[0..created]);
        return self.execute(value.bodySql, parameters);
    }

    fn executeCompound(self: *Connection, compound: ast.CompoundSelect, parameters: []const Value) anyerror!Result {
        return self.executeCompoundWithOuter(compound, parameters, null);
    }

    fn compoundRowsContain(rows: []const []Value, row: []const Value) bool {
        for (rows) |existing| {
            if (existing.len != row.len) continue;
            var same = true;
            for (existing, row) |a, b| {
                if (a == .null and b == .null) continue;
                if (!compare(a, .equal, b)) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }

    fn cloneCompoundRow(self: *Connection, row: []const Value) ![]Value {
        const cloned = try self.allocator.alloc(Value, row.len);
        for (row, 0..) |v, idx| cloned[idx] = try self.copyValue(v);
        return cloned;
    }

    fn freeCompoundRow(self: *Connection, row: []Value) void {
        for (row) |v| if (v == .text) self.allocator.free(v.text) else if (v == .blob) self.allocator.free(v.blob);
        self.allocator.free(row);
    }

    fn appendCompoundClone(self: *Connection, list: *std.ArrayList([]Value), row: []const Value) !void {
        const cloned = try self.cloneCompoundRow(row);
        errdefer self.freeCompoundRow(cloned);
        try list.append(self.allocator, cloned);
    }

    fn dedupCompoundRows(self: *Connection, list: *std.ArrayList([]Value)) void {
        var keep: usize = 0;
        while (keep < list.items.len) : (keep += 1) {
            var scan: usize = keep + 1;
            while (scan < list.items.len) {
                if (compoundRowsContain(list.items[keep .. keep + 1], list.items[scan])) {
                    self.freeCompoundRow(list.orderedRemove(scan));
                } else scan += 1;
            }
        }
    }

    fn mergeCompoundRightIntoLeft(self: *Connection, acc: *Result, right: *Result, op: ast.CompoundOp) !void {
        defer right.deinit();
        if (acc.columns.len != right.columns.len) return error.SchemaMismatch;
        var list = std.ArrayList([]Value).fromOwnedSlice(@constCast(acc.rows));
        errdefer acc.rows = list.items;
        switch (op) {
            .unionAllOp => {
                for (right.rows) |row| try self.appendCompoundClone(&list, row);
            },
            .unionOp => {
                self.dedupCompoundRows(&list);
                for (right.rows) |row| if (!compoundRowsContain(list.items, row)) try self.appendCompoundClone(&list, row);
            },
            .intersectOp => {
                var keep: usize = 0;
                while (keep < list.items.len) {
                    if (!compoundRowsContain(right.rows, list.items[keep])) {
                        self.freeCompoundRow(list.orderedRemove(keep));
                    } else keep += 1;
                }
                self.dedupCompoundRows(&list);
            },
            .exceptOp => {
                var keep: usize = 0;
                while (keep < list.items.len) {
                    if (compoundRowsContain(right.rows, list.items[keep])) {
                        self.freeCompoundRow(list.orderedRemove(keep));
                    } else keep += 1;
                }
                self.dedupCompoundRows(&list);
            },
        }
        acc.rows = try list.toOwnedSlice(self.allocator);
    }

    fn finalizeCompound(self: *Connection, result: *Result, orders: []const ast.Order, limit: ?usize, offset: ?usize) !void {
        if (orders.len != 0) {
            const sortKeys = try self.allocator.alloc(ResolvedSortKey, orders.len);
            defer self.allocator.free(sortKeys);
            for (orders, 0..) |ord, keyIndex| {
                var sortIdx: ?usize = null;
                if (std.fmt.parseInt(usize, ord.column, 10)) |pos| {
                    if (pos >= 1 and pos <= result.columns.len) sortIdx = pos - 1;
                } else |_| {
                    for (result.columns, 0..) |colName, idx| {
                        if (std.ascii.eqlIgnoreCase(colName, ord.column)) {
                            sortIdx = idx;
                            break;
                        }
                    }
                    if (sortIdx == null) {
                        const want = splitQualifier(ord.column).column;
                        for (result.columns, 0..) |colName, idx| {
                            if (std.ascii.eqlIgnoreCase(splitQualifier(colName).column, want)) {
                                sortIdx = idx;
                                break;
                            }
                        }
                    }
                }
                sortKeys[keyIndex] = .{ .colIdx = sortIdx orelse return error.UnknownColumn, .descending = ord.descending };
            }
            const SortCtx = struct {
                keys: []const ResolvedSortKey,
                pub fn lessThan(ctx: @This(), a: []Value, b: []Value) bool {
                    return compareRowsByKeys(a, b, ctx.keys) == .lt;
                }
            };
            std.sort.pdq([]Value, @constCast(result.rows), SortCtx{ .keys = sortKeys }, SortCtx.lessThan);
        }
        const startIdx: usize = offset orelse 0;
        var keptCount: usize = 0;
        for (result.rows, 0..) |_, position| {
            if (position < startIdx) continue;
            if (limit) |lim| if (keptCount >= lim) break;
            keptCount += 1;
        }
        const newRows = try self.allocator.alloc([]Value, keptCount);
        var write: usize = 0;
        for (result.rows, 0..) |row, position| {
            var capped = false;
            if (limit) |lim| capped = write >= lim;
            if (position < startIdx or capped) {
                self.freeCompoundRow(row);
                continue;
            }
            newRows[write] = row;
            write += 1;
        }
        self.allocator.free(result.rows);
        result.rows = newRows;
    }

    fn executeCompoundWithOuter(self: *Connection, compound: ast.CompoundSelect, parameters: []const Value, outer: ?*const OuterRow) anyerror!Result {
        var left = try self.executeWithOuter(compound.leftSql, parameters, outer);
        errdefer left.deinit();
        var right = try self.executeWithOuter(compound.rightSql, parameters, outer);
        try self.mergeCompoundRightIntoLeft(&left, &right, compound.op);
        try self.finalizeCompound(&left, compound.orders, compound.limit, compound.offset);
        return left;
    }

    fn executeCompoundForDsl(pointer: *anyopaque, arms: []const @import("../dsl/ast_builder.zig").CompoundArm, ops: []const ast.CompoundOp, orders: []const ast.Order, limit: ?usize, offset: ?usize) anyerror!Result {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        return self.executeCompoundArms(arms, ops, orders, limit, offset);
    }

    fn executeCompoundArms(self: *Connection, arms: []const @import("../dsl/ast_builder.zig").CompoundArm, ops: []const ast.CompoundOp, orders: []const ast.Order, limit: ?usize, offset: ?usize) anyerror!Result {
        if (arms.len < 2 or ops.len != arms.len - 1) return error.InvalidSql;
        var acc = try self.executeDslStatement(arms[0].stmt, arms[0].ctes, arms[0].recursive);
        errdefer acc.deinit();
        for (arms[1..], ops) |arm, op| {
            var nxt = try self.executeDslStatement(arm.stmt, arm.ctes, arm.recursive);
            try self.mergeCompoundRightIntoLeft(&acc, &nxt, op);
        }
        try self.finalizeCompound(&acc, orders, limit, offset);
        return acc;
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

    fn renderTriggerBody(self: *Connection, body: []const u8, tbl: *const Table, event: ast.TriggerEvent, newRow: ?[]const Value, oldRow: ?[]const Value) ![]u8 {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(self.allocator);
        var index: usize = 0;
        while (index < body.len) {
            if (index + 4 < body.len and (std.ascii.eqlIgnoreCase(body[index .. index + 4], "NEW.") or std.ascii.eqlIgnoreCase(body[index .. index + 4], "OLD."))) {
                const isNew = std.ascii.eqlIgnoreCase(body[index .. index + 4], "NEW.");
                var end = index + 4;
                while (end < body.len and (std.ascii.isAlphanumeric(body[end]) or body[end] == '_')) : (end += 1) {}
                const name = body[index + 4 .. end];
                const column = columnIndex(tbl, name) catch {
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

    fn triggerWhenMatched(self: *Connection, tbl: *const Table, trigger: anytype, event: ast.TriggerEvent, newRow: ?[]const Value, oldRow: ?[]const Value) anyerror!bool {
        const whenSql = trigger.whenSql orelse return true;
        const rendered = try self.renderTriggerBody(whenSql, tbl, event, newRow, oldRow);
        defer self.allocator.free(rendered);
        const wrapped = try std.fmt.allocPrint(self.allocator, "SELECT ({s})", .{rendered});
        defer self.allocator.free(wrapped);
        var result = try self.execute(wrapped, &.{});
        defer result.deinit();
        if (result.rows.len == 0 or result.at(0).len == 0) return false;
        return isTruthy(result.at(0)[0]);
    }

    fn fireTriggers(self: *Connection, store: *Schema, tbl: *const Table, timing: ast.TriggerTiming, event: ast.TriggerEvent, newRow: ?[]const Value, oldRow: ?[]const Value, updatedColumns: []const []const u8) anyerror!void {
        const tableName = tbl.name;
        const PendingBody = struct { name: []u8, sql: []u8 };
        var pending = std.ArrayList(PendingBody).empty;
        defer {
            for (pending.items) |item| {
                self.allocator.free(item.name);
                self.allocator.free(item.sql);
            }
            pending.deinit(self.allocator);
        }
        for (store.triggers.items) |trigger| {
            if (trigger.timing != timing) continue;
            if (trigger.event == event and std.ascii.eqlIgnoreCase(trigger.table, tableName)) {
                if (!trigger.firesOnUpdate(updatedColumns)) continue;
                if (!try self.triggerWhenMatched(tbl, trigger, event, newRow, oldRow)) continue;
                const ownedName = try self.allocator.dupe(u8, trigger.name);
                errdefer self.allocator.free(ownedName);
                const sql = try self.renderTriggerBody(trigger.body, tbl, event, newRow, oldRow);
                errdefer self.allocator.free(sql);
                try pending.append(self.allocator, .{ .name = ownedName, .sql = sql });
            }
        }
        for (pending.items) |item| {
            if (self.triggerOnStack(item.name)) {
                if (!self.recursiveTriggers) continue;
                if (self.triggerStack.items.len >= maxTriggerDepth) return error.TriggerDepthExceeded;
            } else if (self.triggerStack.items.len >= maxTriggerDepth) {
                return error.TriggerDepthExceeded;
            }
            const owned = try self.allocator.dupe(u8, item.name);
            try self.triggerStack.append(self.allocator, owned);
            var result = self.execute(item.sql, &.{}) catch |err| {
                const dropped = self.triggerStack.pop() orelse unreachable;
                self.allocator.free(dropped);
                return err;
            };
            result.deinit();
            const dropped = self.triggerStack.pop() orelse unreachable;
            self.allocator.free(dropped);
        }
    }

    fn triggerOnStack(self: *Connection, name: []const u8) bool {
        for (self.triggerStack.items) |active| if (std.ascii.eqlIgnoreCase(active, name)) return true;
        return false;
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

    fn freeResolvedTemps(self: *Connection, tbl: *const Table, row: []Value, columns: []const []const u8, rowExprs: []const ast.Expr) void {
        if (columns.len == 0) {
            var nonGenIdx: usize = 0;
            for (tbl.columns, 0..) |column, index| {
                if (column.generatedExpr == null) {
                    if (nonGenIdx < rowExprs.len) {
                        const expr = rowExprs[nonGenIdx];
                        if (expr == .binary or expr == .unary) self.freeConcatText(row[index]);
                        nonGenIdx += 1;
                    }
                }
            }
            return;
        }
        for (columns, rowExprs) |name, expr| {
            if (expr != .binary and expr != .unary) continue;
            const index = columnIndex(tbl, name) catch continue;
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

    fn columnIndex(tbl: *const Table, name: []const u8) !usize {
        for (tbl.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
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
            .like, .notLike, .glob, .notGlob, .regexp, .notRegexp, .match, .notMatch, .isNull, .isNotNull, .isValue, .isNotValue, .isDistinct, .isNotDistinct, .between, .notBetween, .in, .notIn, .exists, .notExists, .isTrue => false,
        };
    }

    fn matches(self: *Connection, tbl: *const Table, row: []const Value, condition: ?ast.Conditions, parameters: []const Value) anyerror!bool {
        return self.matchesContext(tbl, row, condition, parameters, null);
    }

    fn matchesContext(self: *Connection, tbl: *const Table, row: []const Value, condition: ?ast.Conditions, parameters: []const Value, outer: ?*const OuterRow) anyerror!bool {
        if (condition) |items| {
            var total = false;
            var group = true;
            var started = false;
            for (items) |item| {
                const itemResult = if ((item.op == .exists or item.op == .notExists) and item.tableScan != null) tableScanExists: {
                    const ts = item.tableScan.?;
                    const resolvedInner = self.resolveTableName(ts.table) orelse return error.UnknownTable;
                    const inner = resolvedInner.table;
                    const currentOuter = OuterRow{ .table = tbl, .alias = if (outer) |o| (if (o.table == tbl) o.alias else null) else null, .values = row, .prev = if (outer != null and outer.?.table == tbl) outer.?.prev else outer };
                    var found = false;
                    for (inner.rows.items) |innerRow| {
                        const matched = if (ts.conditions) |conds| try self.matchesContext(inner, innerRow.values, conds, parameters, &currentOuter) else true;
                        if (matched) {
                            found = true;
                            break;
                        }
                    }
                    break :tableScanExists if (item.op == .exists) found else !found;
                } else if (item.op == .exists or item.op == .notExists) blk: {
                    const sql = item.subquery orelse return error.InvalidSql;
                    const currentOuter = OuterRow{ .table = tbl, .alias = if (outer) |o| (if (o.table == tbl) o.alias else null) else null, .values = row, .prev = if (outer != null and outer.?.table == tbl) outer.?.prev else outer };
                    var sub = try self.executeWithOuter(sql, parameters, &currentOuter);
                    defer sub.deinit();
                    const hasRows = sub.rows.len > 0;
                    break :blk if (item.op == .exists) hasRows else !hasRows;
                } else blk: {
                    const current = if (item.leftExpr) |left| try self.evalContext(tbl, row, left, parameters, outer) else currentColumn: {
                        const parts = splitQualifier(item.column);
                        if (parts.qualifier.len != 0) {
                            const outerAlias = if (outer) |ctx| ctx.alias else null;
                            if (groupQualifierMatches(parts.qualifier, tbl, outerAlias)) {
                                break :currentColumn row[try columnIndex(tbl, parts.column)];
                            }
                            var currOuter = outer;
                            while (currOuter) |ctx| {
                                if (groupQualifierMatches(parts.qualifier, ctx.table, ctx.alias)) {
                                    break :currentColumn ctx.values[try columnIndex(ctx.table, parts.column)];
                                }
                                currOuter = ctx.prev;
                            }
                            break :currentColumn row[try columnIndex(tbl, parts.column)];
                        }
                        if (columnIndex(tbl, item.column)) |idx| {
                            break :currentColumn row[idx];
                        } else |_| {
                            var currOuter = outer;
                            while (currOuter) |ctx| {
                                if (columnIndex(ctx.table, item.column)) |idx| {
                                    break :currentColumn ctx.values[idx];
                                } else |_| {}
                                currOuter = ctx.prev;
                            }
                        }
                        break :currentColumn row[try columnIndex(tbl, item.column)];
                    };
                    defer if (item.leftExpr) |left| {
                        if (left == .binary or left == .unary or left == .function) self.freeConcatText(current);
                    };
                    const base: bool = if (item.op == .isTrue) functions.scalar.isTruthyValue(current) else if (item.op == .isNull) current == .null else if (item.op == .isNotNull) current != .null else if (item.op == .isValue) sameValue(current, try self.evalContext(tbl, row, item.value, parameters, outer)) else if (item.op == .isNotValue) !sameValue(current, try self.evalContext(tbl, row, item.value, parameters, outer)) else if (item.op == .isDistinct) !sameValue(current, try self.evalContext(tbl, row, item.value, parameters, outer)) else if (item.op == .isNotDistinct) sameValue(current, try self.evalContext(tbl, row, item.value, parameters, outer)) else if (item.op == .in and item.subquery != null) inSubquery: {
                        const sql = item.subquery orelse return error.InvalidSql;
                        const currentOuter = OuterRow{ .table = tbl, .alias = if (outer) |o| (if (o.table == tbl) o.alias else null) else null, .values = row, .prev = if (outer != null and outer.?.table == tbl) outer.?.prev else outer };
                        var subquery = try self.executeWithOuter(sql, parameters, &currentOuter);
                        defer subquery.deinit();
                        var found = false;
                        if (subquery.columns.len == 1) for (subquery.rows) |subqueryRow| if (subqueryRow.len != 0 and compareCollated(current, .equal, subqueryRow[0], item.collate)) {
                            found = true;
                            break;
                        };
                        break :inSubquery found;
                    } else if ((item.op == .in or item.op == .notIn) and item.tableScan != null) tableScanIn: {
                        if (current == .null) break :tableScanIn false;
                        const scan = item.tableScan.?;
                        const resolvedScan = self.resolveTableName(scan.table) orelse return error.UnknownTable;
                        const inner = resolvedScan.table;
                        const scanIdx = try columnIndex(inner, scan.column);
                        var scanFound = false;
                        for (inner.rows.items) |innerRow| if (compareCollated(current, .equal, innerRow.values[scanIdx], item.collate)) {
                            scanFound = true;
                            break;
                        };
                        break :tableScanIn if (item.op == .in) scanFound else !scanFound;
                    } else if (item.op == .notIn and item.subquery != null) notInSubquery: {
                        if (current == .null) break :notInSubquery false;
                        const sql = item.subquery orelse return error.InvalidSql;
                        const currentOuter = OuterRow{ .table = tbl, .alias = if (outer) |o| (if (o.table == tbl) o.alias else null) else null, .values = row, .prev = if (outer != null and outer.?.table == tbl) outer.?.prev else outer };
                        var subquery = try self.executeWithOuter(sql, parameters, &currentOuter);
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
                        for (item.listValues) |candidate| if (compareCollated(current, .equal, try self.evalContext(tbl, row, candidate, parameters, outer), item.collate)) {
                            found = true;
                            break;
                        };
                        break :listValues if (item.op == .in) found else !found;
                    } else if (item.op == .between or item.op == .notBetween) betweenPattern: {
                        if (current == .null) break :betweenPattern false;
                        const inRange = compareCollated(current, .greaterEqual, try self.evalContext(tbl, row, item.value, parameters, outer), item.collate) and compareCollated(current, .lessEqual, try self.evalContext(tbl, row, item.value2 orelse return error.InvalidSql, parameters, outer), item.collate);
                        break :betweenPattern if (item.op == .between) inRange else !inRange;
                    } else if (item.op == .like or item.op == .notLike) likePattern: {
                        const pattern = try self.evalContext(tbl, row, item.value, parameters, outer);
                        var escapeValue: ?Value = null;
                        if (item.escape) |escapeExpr| escapeValue = try self.evalContext(tbl, row, escapeExpr, parameters, outer);
                        const tri = try self.evalPattern(current, pattern, escapeValue, false);
                        break :likePattern if (tri) |matched| (if (item.op == .like) matched else !matched) else false;
                    } else if (item.op == .glob or item.op == .notGlob) globPattern: {
                        const pattern = try self.evalContext(tbl, row, item.value, parameters, outer);
                        const tri = try self.evalPattern(current, pattern, null, true);
                        break :globPattern if (tri) |matched| (if (item.op == .glob) matched else !matched) else false;
                    } else if (item.op == .regexp or item.op == .notRegexp) regexpPattern: {
                        const pattern = try self.evalContext(tbl, row, item.value, parameters, outer);
                        const tri = try self.evalRegexp(current, pattern);
                        break :regexpPattern if (tri) |matched| (if (item.op == .regexp) matched else !matched) else false;
                    } else if (item.op == .match or item.op == .notMatch) matchPattern: {
                        const pattern = try self.evalContext(tbl, row, item.value, parameters, outer);
                        const tri = try self.evalMatch(current, pattern);
                        break :matchPattern if (tri) |matched| (if (item.op == .match) matched else !matched) else false;
                    } else compareCollated(current, item.op, try self.evalContext(tbl, row, item.value, parameters, outer), item.collate);
                    if (item.negated) {
                        if (base) break :blk false;
                        const nullSafe = item.op == .isNull or item.op == .isNotNull or item.op == .isValue or item.op == .isNotValue or item.op == .isDistinct or item.op == .isNotDistinct or item.op == .isTrue;
                        if (!nullSafe) {
                            if (current == .null) break :blk false;
                            const v = try self.evalContext(tbl, row, item.value, parameters, outer);
                            if (v == .null) break :blk false;
                            if (item.value2) |second| {
                                const w = try self.evalContext(tbl, row, second, parameters, outer);
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

    fn eval(self: *Connection, tbl: *const Table, row: []const Value, expr: ast.Expr, parameters: []const Value) !Value {
        return self.evalContext(tbl, row, expr, parameters, null);
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
        return functions.scalar.isTruthyValue(value);
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

    fn evalBinary(self: *Connection, tbl: ?*const Table, row: []const Value, binary: anytype, parameters: []const Value, outer: ?*const OuterRow) anyerror!Value {
        const left = try self.evalContext(tbl, row, binary.left.*, parameters, outer);
        const right = try self.evalContext(tbl, row, binary.right.*, parameters, outer);
        defer freeBinaryOwned(binary.left.*, left, self.allocator);
        defer freeBinaryOwned(binary.right.*, right, self.allocator);
        if (binary.op == .logicalAnd or binary.op == .logicalOr) {
            // SQLite three-valued logic: a decisive non-NULL side wins,
            // otherwise NULL propagates. (Matches sql/expr.zig eval.)
            const lNull = left == .null;
            const rNull = right == .null;
            const l = !lNull and isTruthy(left);
            const r = !rNull and isTruthy(right);
            if (binary.op == .logicalAnd) {
                if (!lNull and !l) return .{ .integer = 0 };
                if (!rNull and !r) return .{ .integer = 0 };
                if (lNull or rNull) return .null;
                return .{ .integer = 1 };
            } else {
                if (l) return .{ .integer = 1 };
                if (r) return .{ .integer = 1 };
                if (lNull or rNull) return .null;
                return .{ .integer = 0 };
            }
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
        if (binary.op == .isOp) {
            return .{ .integer = if (sameValue(left, right)) 1 else 0 };
        }
        if (binary.op == .isNotOp) {
            return .{ .integer = if (!sameValue(left, right)) 1 else 0 };
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

    fn valueBorrowsFrom(value: Value, pools: []const []const Value) bool {
        const bytes = switch (value) {
            .text => |b| b,
            .blob => |b| b,
            else => return false,
        };
        for (pools) |pool| for (pool) |item| {
            const owned = switch (item) {
                .text => |b| b,
                .blob => |b| b,
                else => continue,
            };
            if (owned.ptr == bytes.ptr and owned.len == bytes.len) return true;
        };
        return false;
    }

    fn evalContext(self: *Connection, tbl: ?*const Table, row: []const Value, expr: ast.Expr, parameters: []const Value, outer: ?*const OuterRow) anyerror!Value {
        return switch (expr) {
            .literal => |value| value,
            .parameter => |index| if (index == 0) error.InvalidParameter else if (index > parameters.len) .null else parameters[index - 1],
            .identifier => |rawName| {
                const name = self.stripSchemaQualifier(rawName);
                if (tbl) |concrete| {
                    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
                        const prefix = name[0..dot];
                        const colName = name[dot + 1 ..];
                        if (std.ascii.eqlIgnoreCase(prefix, concrete.name)) {
                            return row[try columnIndex(concrete, colName)];
                        }
                        var currOuter = outer;
                        while (currOuter) |ctx| {
                            if (std.ascii.eqlIgnoreCase(prefix, ctx.table.name) or (ctx.alias != null and std.ascii.eqlIgnoreCase(prefix, ctx.alias.?))) {
                                return ctx.values[try columnIndex(ctx.table, colName)];
                            }
                            currOuter = ctx.prev;
                        }
                        return error.UnknownColumn;
                    }
                    if (columnIndex(concrete, name)) |idx| {
                        return row[idx];
                    } else |_| {}
                }
                var currOuter = outer;
                while (currOuter) |ctx| {
                    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
                        const prefix = name[0..dot];
                        const colName = name[dot + 1 ..];
                        if (std.ascii.eqlIgnoreCase(prefix, ctx.table.name) or (ctx.alias != null and std.ascii.eqlIgnoreCase(prefix, ctx.alias.?))) {
                            return ctx.values[try columnIndex(ctx.table, colName)];
                        }
                    } else {
                        if (columnIndex(ctx.table, name)) |idx| {
                            return ctx.values[idx];
                        } else |_| {}
                    }
                    currOuter = ctx.prev;
                }
                return error.UnknownColumn;
            },
            .wildcard => error.InvalidSql,
            .binary => |binary| try self.evalBinary(tbl, row, binary, parameters, outer),
            .collate => |node| try self.evalContext(tbl, row, node.expr.*, parameters, outer),
            .patternMatch => |match| blk: {
                const value = try self.evalContext(tbl, row, match.value.*, parameters, outer);
                const pattern = try self.evalContext(tbl, row, match.pattern.*, parameters, outer);
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
                if (match.escape) |escape| escapeValue = try self.evalContext(tbl, row, escape.*, parameters, outer);
                if (try self.evalPattern(value, pattern, escapeValue, match.glob)) |matched| {
                    break :blk .{ .integer = if (matched == !match.negated) 1 else 0 };
                }
                break :blk .null;
            },
            .unary => |unary| blk: {
                if (unary.op == .logicalNot) {
                    const operand = try self.evalContext(tbl, row, unary.expr.*, parameters, outer);
                    if (operand == .null) break :blk .null;
                    break :blk .{ .integer = if (isTruthy(operand)) 0 else 1 };
                }
                const operand = try self.evalContext(tbl, row, unary.expr.*, parameters, outer);
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
                    const baseValue = try self.evalContext(tbl, row, base.*, parameters, outer);
                    const baseOwned = base.* == .binary or base.* == .unary or base.* == .function;
                    for (caseBlock.whens) |when| {
                        const candidate = try self.evalContext(tbl, row, when.condition, parameters, outer);
                        const candOwned = when.condition == .binary or when.condition == .unary or when.condition == .function;
                        if (compare(baseValue, .equal, candidate)) {
                            if (candOwned) self.freeConcatText(candidate);
                            if (baseOwned) self.freeConcatText(baseValue);
                            break :blk try self.evalContext(tbl, row, when.result, parameters, outer);
                        }
                        if (candOwned) self.freeConcatText(candidate);
                    }
                    if (baseOwned) self.freeConcatText(baseValue);
                } else {
                    for (caseBlock.whens) |when| {
                        const candidate = try self.evalContext(tbl, row, when.condition, parameters, outer);
                        const candOwned = when.condition == .binary or when.condition == .unary or when.condition == .function;
                        const taken = isTruthy(candidate);
                        if (candOwned) self.freeConcatText(candidate);
                        if (taken) break :blk try self.evalContext(tbl, row, when.result, parameters, outer);
                    }
                }
                if (caseBlock.otherwise) |otherwise| break :blk try self.evalContext(tbl, row, otherwise.*, parameters, outer);
                break :blk .null;
            },
            .function => |call| blk: {
                if (call.argument.* == .wildcard and call.argument2 == null and call.argument3 == null and call.extraArgs.len == 0) {
                    if (std.ascii.eqlIgnoreCase(call.name, "last_insert_rowid")) break :blk .{ .integer = self.lastRowid };
                    if (std.ascii.eqlIgnoreCase(call.name, "changes")) break :blk .{ .integer = self.lastChanges };
                    if (std.ascii.eqlIgnoreCase(call.name, "total_changes")) break :blk .{ .integer = self.totalChanges };
                }
                if (call.distinct) return error.Unsupported;
                var argList = std.ArrayList(Value).empty;
                var ownedList = std.ArrayList(bool).empty;
                defer {
                    for (argList.items, 0..) |v, idx| {
                        if (ownedList.items[idx]) self.freeConcatText(v);
                    }
                    argList.deinit(self.allocator);
                    ownedList.deinit(self.allocator);
                }
                if (call.argument.* != .wildcard) {
                    const v1 = try self.evalContext(tbl, row, call.argument.*, parameters, outer);
                    try argList.append(self.allocator, v1);
                    try ownedList.append(self.allocator, call.argument.* == .function or call.argument.* == .binary);
                }
                if (call.argument2) |a2| {
                    if (a2.* == .identifier and std.ascii.eqlIgnoreCase(call.name, "cast")) {
                        try argList.append(self.allocator, .{ .text = a2.identifier });
                        try ownedList.append(self.allocator, false);
                    } else {
                        const v2 = try self.evalContext(tbl, row, a2.*, parameters, outer);
                        try argList.append(self.allocator, v2);
                        try ownedList.append(self.allocator, a2.* == .function or a2.* == .binary);
                    }
                }
                if (call.argument3) |a3| {
                    const v3 = try self.evalContext(tbl, row, a3.*, parameters, outer);
                    try argList.append(self.allocator, v3);
                    try ownedList.append(self.allocator, a3.* == .function or a3.* == .binary);
                }
                for (call.extraArgs) |ea| {
                    const vea = try self.evalContext(tbl, row, ea, parameters, outer);
                    try argList.append(self.allocator, vea);
                    try ownedList.append(self.allocator, ea == .function or ea == .binary);
                }
                break :blk functions.evalScalar(self.allocator, call.name, argList.items) catch return error.Unsupported;
            },
            .scalarSubquery => |sql| blk: {
                const currentOuter: OuterRow = if (tbl != null and row.len > 0) .{ .table = tbl.?, .alias = if (outer) |o| (if (o.table == tbl.?) o.alias else null) else null, .values = row, .prev = if (outer != null and outer.?.table == tbl.?) outer.?.prev else outer } else if (outer) |o| o.* else .{ .table = undefined, .values = &.{} };
                const effectiveOuter: ?*const OuterRow = if (tbl != null and row.len > 0) &currentOuter else outer;
                var sub = try self.executeWithOuter(sql, parameters, effectiveOuter);
                defer sub.deinit();
                if (sub.rows.len == 0 or sub.columns.len == 0) break :blk .null;
                break :blk try self.copyValue(sub.rows[0][0]);
            },
            .existsSubquery => |sql| blk: {
                const currentOuter: OuterRow = if (tbl != null and row.len > 0) .{ .table = tbl.?, .alias = if (outer) |o| (if (o.table == tbl.?) o.alias else null) else null, .values = row, .prev = if (outer != null and outer.?.table == tbl.?) outer.?.prev else outer } else if (outer) |o| o.* else .{ .table = undefined, .values = &.{} };
                const effectiveOuter: ?*const OuterRow = if (tbl != null and row.len > 0) &currentOuter else outer;
                var sub = try self.executeWithOuter(sql, parameters, effectiveOuter);
                defer sub.deinit();
                break :blk .{ .integer = if (sub.rows.len > 0) 1 else 0 };
            },
            .inSubquery => |inSub| blk: {
                const target = try self.evalContext(tbl, row, inSub.expr.*, parameters, outer);
                defer freeBinaryOwned(inSub.expr.*, target, self.allocator);
                if (target == .null) break :blk .null;
                const currentOuter: OuterRow = if (tbl != null and row.len > 0) .{ .table = tbl.?, .alias = if (outer) |o| (if (o.table == tbl.?) o.alias else null) else null, .values = row, .prev = if (outer != null and outer.?.table == tbl.?) outer.?.prev else outer } else if (outer) |o| o.* else .{ .table = undefined, .values = &.{} };
                const effectiveOuter: ?*const OuterRow = if (tbl != null and row.len > 0) &currentOuter else outer;
                var sub = try self.executeWithOuter(inSub.subquery, parameters, effectiveOuter);
                defer sub.deinit();
                var found = false;
                var sawNull = false;
                for (sub.rows) |r| {
                    if (r.len == 0) continue;
                    if (r[0] == .null) {
                        sawNull = true;
                        continue;
                    }
                    if (compare(target, .equal, r[0])) {
                        found = true;
                        break;
                    }
                }
                // No match but a NULL was seen: the answer is unknown, not false.
                if (!found and sawNull) break :blk .null;
                const result = if (inSub.negated) !found else found;
                break :blk .{ .integer = if (result) 1 else 0 };
            },
            .inList => |inL| blk: {
                const target = try self.evalContext(tbl, row, inL.expr.*, parameters, outer);
                defer freeBinaryOwned(inL.expr.*, target, self.allocator);
                if (target == .null) break :blk .null;
                var found = false;
                var sawNull = false;
                for (inL.list) |candidate| {
                    const candidateVal = try self.evalContext(tbl, row, candidate, parameters, outer);
                    defer freeBinaryOwned(candidate, candidateVal, self.allocator);
                    if (candidateVal == .null) {
                        sawNull = true;
                        continue;
                    }
                    if (compare(target, .equal, candidateVal)) {
                        found = true;
                        break;
                    }
                }
                if (!found and sawNull) break :blk .null;
                const result = if (inL.negated) !found else found;
                break :blk .{ .integer = if (result) 1 else 0 };
            },
            .window => error.Unsupported,
        };
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

    fn materialize(self: *Connection, tbl: *const Table, row: []const Value, expr: ast.Expr, parameters: []const Value) !Value {
        return self.materializeContext(tbl, row, expr, parameters, null);
    }

    fn materializeContext(self: *Connection, tbl: *const Table, row: []const Value, expr: ast.Expr, parameters: []const Value, outer: ?*const OuterRow) !Value {
        const raw = try self.evalContext(tbl, row, expr, parameters, outer);
        return switch (expr) {
            .binary, .unary, .function => raw,
            else => try self.copyValue(raw),
        };
    }

    fn initializeInsertRow(self: *Connection, tbl: *const Table, row: []Value) !void {
        _ = self;
        @memset(row, .null);
        for (tbl.columns, 0..) |column, index| {
            if (column.defaultValue) |default| row[index] = default;
        }
    }

    fn validateReturningExpr(tbl: *const Table, expr: ast.Expr) !void {
        switch (expr) {
            .wildcard, .literal, .parameter, .scalarSubquery, .existsSubquery => {},
            .identifier => |name| {
                const colName = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else name;
                _ = try columnIndex(tbl, colName);
            },
            .function => |call| {
                try validateReturningExpr(tbl, call.argument.*);
                if (call.argument2) |arg| try validateReturningExpr(tbl, arg.*);
                if (call.argument3) |arg| try validateReturningExpr(tbl, arg.*);
                for (call.extraArgs) |arg| try validateReturningExpr(tbl, arg);
            },
            .binary => |binary| {
                try validateReturningExpr(tbl, binary.left.*);
                try validateReturningExpr(tbl, binary.right.*);
            },
            .unary => |unary| try validateReturningExpr(tbl, unary.expr.*),
            .caseExpr => |caseBlock| {
                if (caseBlock.base) |base| try validateReturningExpr(tbl, base.*);
                for (caseBlock.whens) |when| {
                    try validateReturningExpr(tbl, when.condition);
                    try validateReturningExpr(tbl, when.result);
                }
                if (caseBlock.otherwise) |otherwise| try validateReturningExpr(tbl, otherwise.*);
            },
            .patternMatch => |match| {
                try validateReturningExpr(tbl, match.value.*);
                try validateReturningExpr(tbl, match.pattern.*);
                if (match.escape) |escape| try validateReturningExpr(tbl, escape.*);
            },
            .collate => |node| try validateReturningExpr(tbl, node.expr.*),
            .inList => |inL| {
                try validateReturningExpr(tbl, inL.expr.*);
                for (inL.list) |item| try validateReturningExpr(tbl, item);
            },
            .inSubquery => |inSub| try validateReturningExpr(tbl, inSub.expr.*),
            .window => |w| {
                if (w.argument) |arg| try validateReturningExpr(tbl, arg.*);
                if (w.argument2) |arg| try validateReturningExpr(tbl, arg.*);
                for (w.extraArgs) |arg| try validateReturningExpr(tbl, arg);
                for (w.partitionBy) |arg| try validateReturningExpr(tbl, arg);
                for (w.orderBy) |item| try validateReturningExpr(tbl, item.expr);
            },
        }
    }

    fn validateReturningColumns(tbl: *const Table, returning: []const ast.Projection) !void {
        for (returning) |projection| try validateReturningExpr(tbl, projection.expr);
    }

    fn evaluateReturning(self: *Connection, tbl: *const Table, returning: []const ast.Projection, affectedRows: []const []const Value, parameters: []const Value) !Result {
        var columns = std.ArrayList([]const u8).empty;
        defer columns.deinit(self.allocator);
        for (returning) |projection| {
            switch (projection.expr) {
                .wildcard => for (tbl.columns) |column| try columns.append(self.allocator, column.name),
                .identifier => try columns.append(self.allocator, projection.alias orelse projection.expr.identifier),
                .function => try columns.append(self.allocator, projection.alias orelse projection.expr.function.name),
                else => try columns.append(self.allocator, projection.alias orelse "?column?"),
            }
        }
        var rows = std.ArrayList([]Value).empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        for (affectedRows) |rowValues| {
            const resultRow = try self.allocator.alloc(Value, columns.items.len);
            var outIndex: usize = 0;
            var rowOk = false;
            defer if (!rowOk) {
                for (resultRow[0..outIndex]) |item| self.freeConcatText(item);
                self.allocator.free(resultRow);
            };
            for (returning) |projection| {
                if (projection.expr == .wildcard) {
                    for (rowValues) |item| {
                        resultRow[outIndex] = try self.copyValue(item);
                        outIndex += 1;
                    }
                } else {
                    resultRow[outIndex] = try self.materialize(tbl, rowValues, projection.expr, parameters);
                    outIndex += 1;
                }
            }
            rowOk = true;
            try rows.append(self.allocator, resultRow);
        }
        return .{
            .allocator = self.allocator,
            .columns = try self.ownedColumns(columns.items),
            .rows = try rows.toOwnedSlice(self.allocator),
            .changes = affectedRows.len,
        };
    }

    fn noteInsertedRowid(self: *Connection, tbl: *const Table) void {
        if (Schema.rowidAliasColumn(tbl)) |alias| {
            if (tbl.rows.items.len == 0) return;
            switch (tbl.rows.items[tbl.rows.items.len - 1].values[alias]) {
                .integer => |id| self.lastRowid = id,
                else => {},
            }
        }
    }

    fn insertInto(self: *Connection, value: anytype, parameters: []const Value) anyerror!Result {
        if (self.cteActive(value.table)) return error.InvalidSql;
        const resolved = self.resolveTableName(value.table) orelse return error.UnknownTable;
        const store = self.storeFor(resolved.ref);
        const tbl = resolved.table;
        try validateReturningColumns(tbl, value.returning);
        var nonGenCount: usize = 0;
        for (tbl.columns) |c| if (c.generatedExpr == null) {
            nonGenCount += 1;
        };
        if (value.columns.len > 0) {
            for (value.columns) |name| {
                const idx = try columnIndex(tbl, name);
                if (tbl.columns[idx].generatedExpr != null) return error.ConstraintViolation;
            }
        }
        var affectedRows = std.ArrayList([]const Value).empty;
        defer affectedRows.deinit(self.allocator);
        if (value.selectSql) |selectSql| {
            var source = try self.execute(selectSql, parameters);
            defer source.deinit();
            var changes: usize = 0;
            for (source.rows) |sourceRow| {
                var row = try self.allocator.alloc(Value, tbl.columns.len);
                defer self.allocator.free(row);
                try self.initializeInsertRow(tbl, row);
                if (value.columns.len == 0) {
                    if (sourceRow.len != nonGenCount) return error.ColumnCountMismatch;
                    var nonGenIdx: usize = 0;
                    for (tbl.columns, 0..) |column, index| {
                        if (column.generatedExpr == null) {
                            row[index] = sourceRow[nonGenIdx];
                            nonGenIdx += 1;
                        }
                    }
                } else {
                    if (value.columns.len != sourceRow.len) return error.ColumnCountMismatch;
                    for (value.columns, sourceRow) |name, item| row[try columnIndex(tbl, name)] = item;
                }
                try self.fireTriggers(store, tbl, .before, .insert, row, null, &.{});
                store.appendRow(tbl, row) catch |err| {
                    if (value.conflict == .ignore and err == error.ConstraintViolation) {
                        if (value.conflictTargetColumns.len > 0 or value.conflictTargetWhere != null) {
                            if (try self.conflictRowTarget(store, tbl, row, value.conflictTargetColumns, value.conflictTargetWhere, parameters) != null) {
                                continue;
                            } else {
                                return err;
                            }
                        }
                        continue;
                    }
                    if (value.conflict == .replace and err == error.ConstraintViolation) {
                        if (try self.replaceConflict(store, tbl, row)) {
                            try store.appendRow(tbl, row);
                            self.noteInsertedRowid(tbl);
                            try self.fireTriggers(store, tbl, .after, .insert, row, null, &.{});
                            changes += 1;
                            try affectedRows.append(self.allocator, tbl.rows.items[tbl.rows.items.len - 1].values);
                            continue;
                        }
                    }
                    if (value.conflict == .update and err == error.ConstraintViolation) {
                        switch (try self.applyUpsert(store, tbl, row, value.conflictTargetColumns, value.conflictTargetWhere, value.upsertColumns, value.upsertValues, value.upsertWhere, parameters)) {
                            .updated => |upIdx| {
                                changes += 1;
                                try affectedRows.append(self.allocator, tbl.rows.items[upIdx].values);
                                continue;
                            },
                            .skipped => continue,
                            .noConflict => {},
                        }
                    }
                    return err;
                };
                self.noteInsertedRowid(tbl);
                try self.fireTriggers(store, tbl, .after, .insert, row, null, &.{});
                changes += 1;
                try affectedRows.append(self.allocator, tbl.rows.items[tbl.rows.items.len - 1].values);
            }
            if (value.returning.len > 0) return self.evaluateReturning(tbl, value.returning, affectedRows.items, parameters);
            return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
        }
        var changes: usize = 0;
        for (value.rows) |rowExprs| {
            var row = try self.allocator.alloc(Value, tbl.columns.len);
            defer self.allocator.free(row);
            try self.initializeInsertRow(tbl, row);
            if (value.columns.len == 0) {
                if (rowExprs.len != 0 and rowExprs.len != nonGenCount) return error.ColumnCountMismatch;
                var nonGenIdx: usize = 0;
                for (tbl.columns, 0..) |column, index| {
                    if (column.generatedExpr == null) {
                        if (nonGenIdx < rowExprs.len) {
                            row[index] = try self.resolve(rowExprs[nonGenIdx], parameters);
                            nonGenIdx += 1;
                        }
                    }
                }
            } else {
                if (value.columns.len != rowExprs.len) return error.ColumnCountMismatch;
                for (value.columns, rowExprs) |name, expr| row[try columnIndex(tbl, name)] = try self.resolve(expr, parameters);
            }
            {
                defer self.freeResolvedTemps(tbl, row, value.columns, rowExprs);
                try self.fireTriggers(store, tbl, .before, .insert, row, null, &.{});
                store.appendRow(tbl, row) catch |err| {
                    if (value.conflict == .ignore and err == error.ConstraintViolation) {
                        if (value.conflictTargetColumns.len > 0 or value.conflictTargetWhere != null) {
                            if (try self.conflictRowTarget(store, tbl, row, value.conflictTargetColumns, value.conflictTargetWhere, parameters) != null) {
                                continue;
                            } else {
                                return err;
                            }
                        }
                        continue;
                    }
                    if (value.conflict == .replace and err == error.ConstraintViolation) {
                        if (try self.replaceConflict(store, tbl, row)) {
                            try store.appendRow(tbl, row);
                            self.noteInsertedRowid(tbl);
                            try self.fireTriggers(store, tbl, .after, .insert, row, null, &.{});
                            changes += 1;
                            try affectedRows.append(self.allocator, tbl.rows.items[tbl.rows.items.len - 1].values);
                            continue;
                        }
                    }
                    if (value.conflict == .update and err == error.ConstraintViolation) {
                        switch (try self.applyUpsert(store, tbl, row, value.conflictTargetColumns, value.conflictTargetWhere, value.upsertColumns, value.upsertValues, value.upsertWhere, parameters)) {
                            .updated => |upIdx| {
                                changes += 1;
                                try affectedRows.append(self.allocator, tbl.rows.items[upIdx].values);
                                continue;
                            },
                            .skipped => continue,
                            .noConflict => {},
                        }
                    }
                    return err;
                };
                self.noteInsertedRowid(tbl);
                try self.fireTriggers(store, tbl, .after, .insert, row, null, &.{});
                changes += 1;
                try affectedRows.append(self.allocator, tbl.rows.items[tbl.rows.items.len - 1].values);
            }
        }
        if (value.returning.len > 0) return self.evaluateReturning(tbl, value.returning, affectedRows.items, parameters);
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
    }

    fn selectGrouped(self: *Connection, tbl: *const Table, value: anytype, groupName: []const u8, parameters: []const Value) !Result {
        const Group = struct { key: Value, rows: std.ArrayList(usize) };
        const groupParts = splitQualifier(groupName);
        if (!groupQualifierMatches(groupParts.qualifier, tbl, value.tableAlias)) return error.UnknownColumn;
        const groupIndex = try columnIndex(tbl, groupParts.column);
        var groups = std.ArrayList(Group).empty;
        defer {
            for (groups.items) |*group| {
                if (group.key == .text) self.allocator.free(group.key.text) else if (group.key == .blob) self.allocator.free(group.key.blob);
                group.rows.deinit(self.allocator);
            }
            groups.deinit(self.allocator);
        }
        for (tbl.rows.items, 0..) |row, rowIndex| {
            if (!try self.matches(tbl, row.values, value.condition, parameters)) continue;
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
        var sortAfter = false;
        if (value.orders.len != 0) {
            sortAfter = true;
            for (value.orders) |keyOrder| {
                if (resolveSortOutputIndex(columns.items, value.projections, keyOrder.column) == null) {
                    sortAfter = false;
                    break;
                }
            }
            if (!sortAfter) {
                if (value.orders.len != 1) return error.Unsupported;
                const ord = value.orders[0];
                const orderName = splitQualifier(ord.column).column;
                if (!std.ascii.eqlIgnoreCase(orderName, groupParts.column) or !groupQualifierMatches(splitQualifier(ord.column).qualifier, tbl, value.tableAlias)) return error.Unsupported;
                var gi: usize = 0;
                while (gi < groups.items.len) : (gi += 1) {
                    var gj = gi + 1;
                    while (gj < groups.items.len) : (gj += 1) {
                        const placed = groups.items[gi].key.order(groups.items[gj].key, .binary);
                        if ((if (ord.descending) placed.invert() else placed) == .gt)
                            std.mem.swap(Group, &groups.items[gi], &groups.items[gj]);
                    }
                }
            }
        }
        for (groups.items) |group| {
            if (value.having) |having| {
                const leftValue: Value = switch (having.left) {
                    .identifier => |name| blk: {
                        const parts = splitQualifier(name);
                        if (!std.ascii.eqlIgnoreCase(parts.column, groupParts.column) or !groupQualifierMatches(parts.qualifier, tbl, value.tableAlias)) return error.Unsupported;
                        break :blk try self.copyValue(group.key);
                    },
                    .function => |function| blk: {
                        if (functions.aggregate.AggKind.fromName(function.name)) |kind| {
                            var sep: ?[]const u8 = null;
                            if (function.argument2) |a2| {
                                const sVal = try self.resolve(a2.*, parameters);
                                if (sVal == .text) sep = sVal.text;
                            }
                            var agg = functions.aggregate.AggState.init(self.allocator, kind, sep);
                            defer agg.deinit();
                            for (group.rows.items) |rowIndex| {
                                if (function.argument.* == .wildcard) {
                                    agg.stepWildcard();
                                } else {
                                    const item = try self.eval(tbl, tbl.rows.items[rowIndex].values, function.argument.*, parameters);
                                    try agg.step(item, function.distinct);
                                }
                            }
                            break :blk try agg.result();
                        }
                        return error.Unsupported;
                    },
                    else => return error.Unsupported,
                };
                defer if (leftValue == .text) self.allocator.free(leftValue.text) else if (leftValue == .blob) self.allocator.free(leftValue.blob);
                if (having.op == .isTrue and !functions.scalar.isTruthyValue(leftValue)) continue;
                const rightValue = try self.resolve(having.right, parameters);
                const rightOwned = having.right == .binary or having.right == .unary;
                defer if (rightOwned) self.freeConcatText(rightValue);
                if (having.op != .isTrue and !compare(leftValue, having.op, rightValue)) continue;
            }
            const output = try self.allocator.alloc(Value, value.projections.len);
            errdefer self.allocator.free(output);
            for (value.projections, 0..) |projection, outputIndex| switch (projection.expr) {
                .identifier => {
                    const parts = splitQualifier(projection.expr.identifier);
                    if (!std.ascii.eqlIgnoreCase(parts.column, groupParts.column) or !groupQualifierMatches(parts.qualifier, tbl, value.tableAlias)) return error.Unsupported;
                    output[outputIndex] = try self.copyValue(group.key);
                },
                .function => |function| {
                    if (functions.aggregate.AggKind.fromName(function.name)) |kind| {
                        var sep: ?[]const u8 = null;
                        if (function.argument2) |a2| {
                            const sVal = try self.resolve(a2.*, parameters);
                            if (sVal == .text) sep = sVal.text;
                        }
                        var agg = functions.aggregate.AggState.init(self.allocator, kind, sep);
                        defer agg.deinit();
                        for (group.rows.items) |rowIndex| {
                            if (function.argument.* == .wildcard) {
                                agg.stepWildcard();
                            } else {
                                const item = try self.eval(tbl, tbl.rows.items[rowIndex].values, function.argument.*, parameters);
                                try agg.step(item, function.distinct);
                            }
                        }
                        output[outputIndex] = try agg.result();
                    } else {
                        return error.Unsupported;
                    }
                },
                else => return error.Unsupported,
            };
            try rows.append(self.allocator, output);
        }
        if (sortAfter) try self.sortJoinRows(&rows, columns.items, value.projections, value.orders);
        try self.paginateJoinRows(&rows, value.limit, value.offset);
        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn conflictRow(self: *Connection, store: *Schema, tbl: *const Table, values: []const Value, ignoreIndex: ?usize) anyerror!?usize {
        for (tbl.rows.items, 0..) |existing, rowIndex| {
            if (ignoreIndex != null and ignoreIndex.? == rowIndex) continue;
            var matched = false;
            for (tbl.columns, 0..) |column, columnIdx| if ((column.primaryKey or column.unique) and values[columnIdx] != .null and sameValue(existing.values[columnIdx], values[columnIdx])) {
                matched = true;
                break;
            };
            if (matched) return rowIndex;
            for (tbl.constraints) |constraint| {
                if (constraint.kind == .foreignKey) continue;
                var valid = true;
                var hasNull = false;
                for (constraint.columns) |name| {
                    const columnIdx = columnIndex(tbl, name) catch {
                        valid = false;
                        break;
                    };
                    if (values[columnIdx] == .null) hasNull = true;
                    if (!sameValue(existing.values[columnIdx], values[columnIdx])) valid = false;
                }
                if (valid and (constraint.kind == .primaryKey or !hasNull)) return rowIndex;
            }
            for (store.indexes.items) |index| if (index.unique and std.ascii.eqlIgnoreCase(index.table, tbl.name)) {
                var colNames: ?[][]const u8 = null;
                defer if (colNames) |names| self.allocator.free(names);
                var valid = true;
                var hasNull = false;
                for (index.columns, 0..) |name, position| {
                    if (index.keyExpr(position) != null) {
                        if (colNames == null) {
                            const names = try self.allocator.alloc([]const u8, tbl.columns.len);
                            for (tbl.columns, 0..) |tableColumn, idx| names[idx] = tableColumn.name;
                            colNames = names;
                        }
                        const leftVal = try exprEvaluator.evalTemp(self.allocator, colNames.?, existing.values, index.keyExpr(position).?);
                        defer exprEvaluator.freeValue(self.allocator, leftVal);
                        const rightVal = try exprEvaluator.evalTemp(self.allocator, colNames.?, values, index.keyExpr(position).?);
                        defer exprEvaluator.freeValue(self.allocator, rightVal);
                        if (leftVal == .null or rightVal == .null) {
                            valid = false;
                            break;
                        }
                        if (!leftVal.sameValue(rightVal)) valid = false;
                        continue;
                    }
                    const columnIdx = columnIndex(tbl, name) catch {
                        valid = false;
                        break;
                    };
                    if (values[columnIdx] == .null) hasNull = true;
                    if (!sameValue(existing.values[columnIdx], values[columnIdx])) valid = false;
                }
                if (!valid or hasNull) continue;
                if (!try store.indexPredicateHolds(tbl, &index, values)) continue;
                if (!try store.indexPredicateHolds(tbl, &index, existing.values)) continue;
                return rowIndex;
            };
        }
        return null;
    }

    fn conflictRowTarget(self: *Connection, store: *Schema, tbl: *const Table, values: []const Value, targetColumns: []const []const u8, targetWhere: ?ast.Conditions, parameters: []const Value) anyerror!?usize {
        if (targetColumns.len == 0) {
            const rowIdx = (try self.conflictRow(store, tbl, values, null)) orelse return null;
            if (targetWhere) |whereCond| {
                if (!try self.matches(tbl, tbl.rows.items[rowIdx].values, whereCond, parameters)) return null;
            }
            return rowIdx;
        }
        for (tbl.rows.items, 0..) |existing, rowIndex| {
            var allMatch = true;
            for (targetColumns) |name| {
                const columnIdx = columnIndex(tbl, name) catch {
                    allMatch = false;
                    break;
                };
                if (values[columnIdx] == .null or !sameValue(existing.values[columnIdx], values[columnIdx])) {
                    allMatch = false;
                    break;
                }
            }
            if (!allMatch) continue;
            if (targetWhere) |whereCond| {
                if (!try self.matches(tbl, existing.values, whereCond, parameters)) continue;
            }
            return rowIndex;
        }
        return null;
    }

    pub const UpsertOutcome = union(enum) {
        noConflict,
        skipped,
        updated: usize,
    };

    fn recomputeGeneratedColumns(self: *Connection, tbl: *const Table, row: []Value, freeOld: bool) !void {
        var colNames = try self.allocator.alloc([]const u8, tbl.columns.len);
        defer self.allocator.free(colNames);
        for (tbl.columns, 0..) |column, idx| colNames[idx] = column.name;

        var pass: usize = 0;
        while (pass < tbl.columns.len) : (pass += 1) {
            var anyChanged = false;
            for (tbl.columns, 0..) |column, index| {
                if (column.generatedExpr) |genExpr| {
                    const genVal = try exprEvaluator.eval(self.allocator, colNames, row, genExpr);
                    if (!sameValue(row[index], genVal)) {
                        if (freeOld or pass > 0) {
                            if (row[index] == .text) self.allocator.free(row[index].text);
                            if (row[index] == .blob) self.allocator.free(row[index].blob);
                        }
                        row[index] = genVal;
                        anyChanged = true;
                    } else {
                        exprEvaluator.freeValue(self.allocator, genVal);
                    }
                }
            }
            if (!anyChanged) break;
        }
    }

    fn applyUpsert(
        self: *Connection,
        store: *Schema,
        tbl: *Table,
        values: []const Value,
        targetColumns: []const []const u8,
        targetWhere: ?ast.Conditions,
        columns: []const []const u8,
        expressions: []const ast.Expr,
        where: ?ast.Conditions,
        parameters: []const Value,
    ) anyerror!UpsertOutcome {
        for (columns) |name| {
            const index = try columnIndex(tbl, name);
            if (tbl.columns[index].generatedExpr != null) return error.ConstraintViolation;
        }
        const rowIndex = (try self.conflictRowTarget(store, tbl, values, targetColumns, targetWhere, parameters)) orelse return .noConflict;
        const row = &tbl.rows.items[rowIndex];
        const excludedOuter = OuterRow{
            .table = tbl,
            .alias = "excluded",
            .values = values,
            .prev = null,
        };
        if (where) |conditions| {
            if (!try self.matchesContext(tbl, row.values, conditions, parameters, &excludedOuter)) return .skipped;
        }
        const oldSnapshot = try self.allocator.alloc(Value, row.values.len);
        defer {
            for (oldSnapshot) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
            self.allocator.free(oldSnapshot);
        }
        for (row.values, 0..) |item, index| oldSnapshot[index] = try self.copyValue(item);
        const candidate = try self.allocator.alloc(Value, row.values.len);
        defer {
            for (columns, expressions) |name, expr| {
                if (expr != .binary and expr != .unary and expr != .function and expr != .caseExpr) continue;
                const index = columnIndex(tbl, name) catch continue;
                self.freeConcatText(candidate[index]);
            }
            for (tbl.columns, 0..) |column, index| {
                if (column.generatedExpr != null and !sameValue(candidate[index], row.values[index])) {
                    exprEvaluator.freeValue(self.allocator, candidate[index]);
                }
            }
            self.allocator.free(candidate);
        }
        @memcpy(candidate, row.values);
        for (columns, expressions) |name, expression| {
            const index = try columnIndex(tbl, name);
            var newValue = try self.evalContext(tbl, row.values, expression, parameters, &excludedOuter);
            if (tbl.strict) newValue = try Schema.coerceStrict(tbl.columns[index].typeName, newValue);
            candidate[index] = newValue;
        }
        try self.recomputeGeneratedColumns(tbl, candidate, false);
        try self.fireTriggers(store, tbl, .before, .update, candidate, oldSnapshot, columns);
        try store.validateUpdate(tbl, rowIndex, candidate);
        try self.applyUpdateActions(store, tbl.name, row.values, candidate);
        for (columns, expressions) |name, expression| {
            const index = try columnIndex(tbl, name);
            var newValue = try self.evalContext(tbl, row.values, expression, parameters, &excludedOuter);
            // Tracks eval-produced ownership: complex expressions yield fresh
            // text/blobs that must be freed; plain references borrow storage.
            var ownedResult = expression == .binary or expression == .unary or expression == .function or expression == .caseExpr;
            if (newValue == .null and candidate[index] != .null) {
                newValue = candidate[index];
                ownedResult = false;
            }
            if (tbl.strict) newValue = try Schema.coerceStrict(tbl.columns[index].typeName, newValue);
            // Duplicate before freeing: newValue may borrow the storage being
            // replaced (e.g. DO UPDATE SET label = label).
            const ownedCopy: Value = switch (newValue) {
                .text => |text| .{ .text = try self.allocator.dupe(u8, text) },
                .blob => |blob| .{ .blob = try self.allocator.dupe(u8, blob) },
                else => newValue,
            };
            if (row.values[index] == .text) self.allocator.free(row.values[index].text);
            if (row.values[index] == .blob) self.allocator.free(row.values[index].blob);
            row.values[index] = ownedCopy;
            // Free eval-owned text only when it cannot alias live storage
            // (CASE branches may pass a borrowed column through).
            if (ownedResult and !valueBorrowsFrom(newValue, &.{ row.values, candidate, excludedOuter.values })) self.freeConcatText(newValue);
        }
        try self.recomputeGeneratedColumns(tbl, row.values, true);
        try self.fireTriggers(store, tbl, .after, .update, row.values, oldSnapshot, columns);
        return .{ .updated = rowIndex };
    }

    fn deleteRowAt(self: *Connection, store: *Schema, tbl: *Table, rowIndex: usize) !void {
        try self.applyDeleteActions(store, tbl.name, tbl.rows.items[rowIndex].values);
        try self.fireTriggers(store, tbl, .before, .delete, null, tbl.rows.items[rowIndex].values, &.{});
        const removed = tbl.rows.orderedRemove(rowIndex);
        try self.fireTriggers(store, tbl, .after, .delete, null, removed.values, &.{});
        for (removed.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
        self.allocator.free(removed.values);
    }

    fn replaceConflict(self: *Connection, store: *Schema, tbl: *Table, values: []const Value) anyerror!bool {
        const rowIndex = (try self.conflictRow(store, tbl, values, null)) orelse return false;
        try self.deleteRowAt(store, tbl, rowIndex);
        return true;
    }

    fn resolveOrderColumnIndex(tbl: *const Table, projections: []const ast.Projection, orderCol: []const u8) ?usize {
        const targetCol = if (std.mem.lastIndexOfScalar(u8, orderCol, '.')) |dot| orderCol[dot + 1 ..] else orderCol;
        if (std.fmt.parseInt(usize, targetCol, 10)) |num| {
            if (num >= 1 and num <= tbl.columns.len) return num - 1;
        } else |_| {}
        if (columnIndex(tbl, targetCol)) |idx| return idx else |_| {}
        for (projections, 0..) |p, pIdx| {
            if (p.alias) |a| {
                if (std.ascii.eqlIgnoreCase(a, targetCol)) {
                    if (p.expr == .identifier) {
                        const pCol = if (std.mem.lastIndexOfScalar(u8, p.expr.identifier, '.')) |dot| p.expr.identifier[dot + 1 ..] else p.expr.identifier;
                        if (columnIndex(tbl, pCol)) |idx| return idx else |_| {}
                    }
                    if (pIdx < tbl.columns.len) return pIdx;
                }
            }
        }
        return null;
    }

    fn select(self: *Connection, value: anytype, parameters: []const Value) anyerror!Result {
        return self.selectWithOuter(value, parameters, null);
    }

    fn restoreStashedTable(self: *Connection, stashed: *?*Table, index: usize) void {
        const tbl = stashed.* orelse return;
        stashed.* = null;
        self.store.tables.insert(self.allocator, index, tbl) catch {
            self.store.tables.append(self.allocator, tbl) catch {};
        };
    }

    const EphemeralScope = struct {
        connection: *Connection,
        name: []const u8,
        stashed: ?*Table,
        stashIndex: usize,

        fn deinit(self: *@This()) void {
            self.connection.store.dropTable(self.name) catch {};
            self.connection.restoreStashedTable(&self.stashed, self.stashIndex);
        }
    };

    fn materializeDerivedTable(self: *Connection, ephemeralName: []const u8, source: *const Result) !EphemeralScope {
        const definitions = try self.allocator.alloc(ast.ColumnDef, source.columns.len);
        defer self.allocator.free(definitions);
        for (source.columns, 0..) |column, index| definitions[index] = .{ .name = column, .typeName = if (source.rows.len == 0) "" else source.rows[0][index].typeName() };
        try self.store.tables.ensureTotalCapacity(self.allocator, self.store.tables.items.len + 2);
        var scope = EphemeralScope{ .connection = self, .name = ephemeralName, .stashed = null, .stashIndex = 0 };
        for (self.store.tables.items, 0..) |existing, position| if (std.ascii.eqlIgnoreCase(existing.name, ephemeralName)) {
            scope.stashed = self.store.tables.orderedRemove(position);
            scope.stashIndex = position;
            break;
        };
        errdefer scope.deinit();
        try self.store.createTable(ephemeralName, definitions, &.{});
        const ephTable = self.store.find(ephemeralName).?;
        for (source.rows) |row| try self.store.appendRow(ephTable, row);
        return scope;
    }

    fn executeDerivedForDsl(pointer: *anyopaque, sub: @import("../dsl/ast_builder.zig").CompoundArm, outer: @import("../dsl/ast_builder.zig").CompoundArm) anyerror!Result {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        return self.executeDerivedTable(sub, outer);
    }

    fn executeDerivedTable(self: *Connection, sub: @import("../dsl/ast_builder.zig").CompoundArm, outer: @import("../dsl/ast_builder.zig").CompoundArm) anyerror!Result {
        if (outer.stmt.* != .select) return error.InvalidSql;
        if (sub.stmt.* != .select or sub.stmt.select.fromSubquery != null) return error.InvalidSql;
        var source = try self.executeDslStatement(sub.stmt, sub.ctes, sub.recursive);
        defer source.deinit();
        const ephemeralName = outer.stmt.select.table orelse "__subquery__";
        var scope = try self.materializeDerivedTable(ephemeralName, &source);
        defer scope.deinit();
        return self.executeDslStatement(outer.stmt, outer.ctes, outer.recursive);
    }

    fn selectWithOuter(self: *Connection, value: anytype, parameters: []const Value, outer: ?*const OuterRow) anyerror!Result {
        if (value.fromSubquery) |fromSubquery| {
            var source = try self.executeWithOuter(fromSubquery, parameters, outer);
            defer source.deinit();
            const ephemeralName = value.table orelse "__subquery__";
            var scope = try self.materializeDerivedTable(ephemeralName, &source);
            defer scope.deinit();
            var subValue = value;
            subValue.fromSubquery = null;
            return self.selectWithOuter(subValue, parameters, outer);
        }
        var columns = std.ArrayList([]const u8).empty;
        defer columns.deinit(self.allocator);
        var projections = std.ArrayList(ast.Projection).empty;
        defer projections.deinit(self.allocator);
        if (value.table) |tableName| {
            const resolved = self.resolveTableName(tableName) orelse {
                const resolvedView = self.resolveViewName(tableName) orelse return error.UnknownTable;
                const view = resolvedView.view;
                var source = try self.execute(view.sql, parameters);
                defer source.deinit();
                const ephemeralName = try std.fmt.allocPrint(self.allocator, "__view__{s}", .{tableName});
                defer self.allocator.free(ephemeralName);
                var scope = try self.materializeDerivedTable(ephemeralName, &source);
                defer scope.deinit();
                var subValue = value;
                subValue.table = ephemeralName;
                return self.selectWithOuter(subValue, parameters, outer);
            };
            const tbl = resolved.table;
            if (value.joins.len != 0) return try self.selectJoin(value, tbl, parameters, outer);
            if (value.groupBy) |groupName| return try self.selectGrouped(tbl, value, groupName, parameters);
            var anyAgg = false;
            for (value.projections) |p| {
                if (p.expr == .function and functions.aggregate.AggKind.fromName(p.expr.function.name) != null) {
                    anyAgg = true;
                    break;
                }
            }
            if (anyAgg) {
                var aggStates = try self.allocator.alloc(?functions.aggregate.AggState, value.projections.len);
                defer self.allocator.free(aggStates);
                for (value.projections, 0..) |p, i| {
                    if (p.expr == .function) {
                        if (functions.aggregate.AggKind.fromName(p.expr.function.name)) |kind| {
                            var sep: ?[]const u8 = null;
                            if (p.expr.function.argument2) |a2| {
                                const sVal = try self.resolve(a2.*, parameters);
                                if (sVal == .text) sep = sVal.text;
                            }
                            aggStates[i] = functions.aggregate.AggState.init(self.allocator, kind, sep);
                            try columns.append(self.allocator, p.alias orelse p.expr.function.name);
                            continue;
                        }
                    }
                    aggStates[i] = null;
                    switch (p.expr) {
                        .identifier => try columns.append(self.allocator, p.alias orelse p.expr.identifier),
                        else => try columns.append(self.allocator, p.alias orelse "?column?"),
                    }
                }
                defer {
                    for (aggStates) |*st| {
                        if (st.*) |*s| s.deinit();
                    }
                }
                var firstRow: ?[]const Value = null;
                for (tbl.rows.items) |row| {
                    const rowOuter = OuterRow{ .table = tbl, .alias = value.tableAlias, .values = row.values, .prev = outer };
                    if (!try self.matchesContext(tbl, row.values, value.condition, parameters, &rowOuter)) continue;
                    if (firstRow == null) firstRow = row.values;
                    for (value.projections, 0..) |p, i| {
                        if (aggStates[i]) |*agg| {
                            if (p.expr.function.argument.* == .wildcard) {
                                agg.stepWildcard();
                            } else {
                                const item = try self.evalContext(tbl, row.values, p.expr.function.argument.*, parameters, &rowOuter);
                                try agg.step(item, p.expr.function.distinct);
                            }
                        }
                    }
                }
                if (value.having) |having| {
                    const leftValue: Value = switch (having.left) {
                        .function => |function| blk: {
                            if (functions.aggregate.AggKind.fromName(function.name)) |kind| {
                                var sep: ?[]const u8 = null;
                                if (function.argument2) |a2| {
                                    const sVal = try self.resolve(a2.*, parameters);
                                    if (sVal == .text) sep = sVal.text;
                                }
                                var havingAgg = functions.aggregate.AggState.init(self.allocator, kind, sep);
                                defer havingAgg.deinit();
                                for (tbl.rows.items) |row| {
                                    const rowOuter = OuterRow{ .table = tbl, .alias = value.tableAlias, .values = row.values, .prev = outer };
                                    if (!try self.matchesContext(tbl, row.values, value.condition, parameters, &rowOuter)) continue;
                                    if (function.argument.* == .wildcard) {
                                        havingAgg.stepWildcard();
                                    } else {
                                        const item = try self.evalContext(tbl, row.values, function.argument.*, parameters, &rowOuter);
                                        try havingAgg.step(item, function.distinct);
                                    }
                                }
                                break :blk try havingAgg.result();
                            }
                            return error.Unsupported;
                        },
                        else => if (firstRow) |frow| try self.materializeContext(tbl, frow, having.left, parameters, null) else .null,
                    };
                    defer if (leftValue == .text) self.allocator.free(leftValue.text) else if (leftValue == .blob) self.allocator.free(leftValue.blob);
                    if (having.op == .isTrue and !functions.scalar.isTruthyValue(leftValue)) {
                        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try self.allocator.alloc([]Value, 0) };
                    }
                    const rightValue = try self.resolve(having.right, parameters);
                    const rightOwned = having.right == .binary or having.right == .unary;
                    defer if (rightOwned) self.freeConcatText(rightValue);
                    if (having.op != .isTrue and !compare(leftValue, having.op, rightValue)) {
                        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try self.allocator.alloc([]Value, 0) };
                    }
                }
                const aggregateRow = try self.allocator.alloc(Value, value.projections.len);
                for (value.projections, 0..) |p, i| {
                    if (aggStates[i]) |*agg| {
                        aggregateRow[i] = try agg.result();
                    } else if (firstRow) |frow| {
                        const rowOuter = OuterRow{ .table = tbl, .alias = value.tableAlias, .values = frow, .prev = outer };
                        aggregateRow[i] = try self.materializeContext(tbl, frow, p.expr, parameters, &rowOuter);
                    } else {
                        aggregateRow[i] = .null;
                    }
                }
                const aggregateRows = try self.allocator.alloc([]Value, 1);
                aggregateRows[0] = aggregateRow;
                return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = aggregateRows };
            }
            var hasWindow = false;
            for (value.projections) |projection| {
                switch (projection.expr) {
                    .wildcard => for (tbl.columns) |column| try columns.append(self.allocator, column.name),
                    .identifier => try columns.append(self.allocator, projection.alias orelse projection.expr.identifier),
                    .function => try columns.append(self.allocator, projection.alias orelse projection.expr.function.name),
                    .window => |w| {
                        hasWindow = true;
                        try columns.append(self.allocator, projection.alias orelse w.funcName);
                    },
                    else => {},
                }
            }
            if (columns.items.len == 0) for (value.projections) |projection| try columns.append(self.allocator, projection.alias orelse "?column?");
            var rows = std.ArrayList([]Value).empty;
            errdefer {
                for (rows.items) |row| self.allocator.free(row);
                rows.deinit(self.allocator);
            }
            const orderedIndices = try self.plannedIndices(tbl, value.condition, parameters);
            defer self.allocator.free(orderedIndices);
            if (value.orders.len != 0) {
                // A bare rowid key orders by storage order (the engine's
                // rowid): ascending is already storage order, descending
                // reverses it. WITHOUT ROWID tables have no rowid at all.
                if (value.orders.len == 1) {
                    const sole = splitQualifier(value.orders[0].column).column;
                    if (isRowidAlias(sole)) {
                        if (tbl.withoutRowid) return error.UnknownColumn;
                        if (value.orders[0].descending) std.mem.reverse(usize, orderedIndices);
                    } else {
                        try self.sortIndexRows(tbl, value, orderedIndices);
                    }
                } else {
                    try self.sortIndexRows(tbl, value, orderedIndices);
                }
            }
            if (hasWindow) {
                var matchingRows = std.ArrayList([]const Value).empty;
                defer matchingRows.deinit(self.allocator);
                for (orderedIndices) |rowIndex| {
                    const row = tbl.rows.items[rowIndex];
                    const rowOuter = OuterRow{ .table = tbl, .alias = value.tableAlias, .values = row.values, .prev = outer };
                    if (!try self.matchesContext(tbl, row.values, value.condition, parameters, &rowOuter)) continue;
                    try matchingRows.append(self.allocator, row.values);
                }
                const EvalHelper = struct {
                    conn: *Connection,
                    tbl: *const Table,
                    params: []const Value,

                    fn evalExpr(ctxPtr: *const anyopaque, expr: ast.Expr, row: []const Value) anyerror!Value {
                        const selfCtx: *const @This() = @ptrCast(@alignCast(ctxPtr));
                        return selfCtx.conn.eval(selfCtx.tbl, row, expr, selfCtx.params);
                    }
                };
                const helper = EvalHelper{ .conn = self, .tbl = tbl, .params = parameters };
                const winCtx = functions.window.WindowContext{
                    .allocator = self.allocator,
                    .rows = matchingRows.items,
                    .evalFn = EvalHelper.evalExpr,
                    .evalCtx = &helper,
                };
                var windowCols = try self.allocator.alloc(?[]Value, value.projections.len);
                @memset(windowCols, null);
                defer {
                    for (windowCols) |cOpt| {
                        if (cOpt) |cSlice| {
                            for (cSlice) |item| self.freeConcatText(item);
                            self.allocator.free(cSlice);
                        }
                    }
                    self.allocator.free(windowCols);
                }
                for (value.projections, 0..) |projection, pIdx| {
                    if (projection.expr == .window) {
                        windowCols[pIdx] = try functions.window.evaluateWindowFunction(self.allocator, projection.expr, winCtx);
                    }
                }
                var scanned: usize = 0;
                var count: usize = 0;
                for (matchingRows.items, 0..) |rowValues, rowIdx| {
                    if (value.offset) |offset| if (scanned < offset) {
                        scanned += 1;
                        continue;
                    };
                    scanned += 1;
                    const resultRow = try self.allocator.alloc(Value, value.projections.len);
                    var outIndex: usize = 0;
                    var rowOk = false;
                    defer {
                        if (!rowOk) {
                            for (resultRow[0..outIndex]) |item| self.freeConcatText(item);
                            self.allocator.free(resultRow);
                        }
                    }
                    const rowOuter = OuterRow{ .table = tbl, .alias = value.tableAlias, .values = rowValues, .prev = outer };
                    for (value.projections, 0..) |projection, pIdx| {
                        if (projection.expr == .window) {
                            resultRow[outIndex] = windowCols[pIdx].?[rowIdx];
                            windowCols[pIdx].?[rowIdx] = .null;
                            outIndex += 1;
                        } else {
                            resultRow[outIndex] = try self.materializeContext(tbl, rowValues, projection.expr, parameters, &rowOuter);
                            outIndex += 1;
                        }
                    }
                    rowOk = true;
                    if (value.distinct) {
                        var duplicate = false;
                        for (rows.items) |existing| if (rowsEqual(existing, resultRow)) {
                            duplicate = true;
                            break;
                        };
                        if (duplicate) {
                            for (resultRow) |item| self.freeConcatText(item);
                            self.allocator.free(resultRow);
                            continue;
                        }
                    }
                    try rows.append(self.allocator, resultRow);
                    count += 1;
                    if (value.limit) |limit| if (count >= limit) break;
                }
                return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
            }
            var scanned: usize = 0;
            var count: usize = 0;
            for (orderedIndices) |rowIndex| {
                const row = tbl.rows.items[rowIndex];
                const rowOuter = OuterRow{ .table = tbl, .alias = value.tableAlias, .values = row.values, .prev = outer };
                if (!try self.matchesContext(tbl, row.values, value.condition, parameters, &rowOuter)) continue;
                if (value.offset) |offset| if (scanned < offset) {
                    scanned += 1;
                    continue;
                };
                scanned += 1;
                const resultRow = try self.allocator.alloc(Value, value.projections.len + if (value.projections.len == 1 and value.projections[0].expr == .wildcard) tbl.columns.len - 1 else 0);
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
                    resultRow[outIndex] = try self.materializeContext(tbl, row.values, projection.expr, parameters, &rowOuter);
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
        var done: usize = 0;
        errdefer {
            for (resultRow[0..done]) |item| self.freeConcatText(item);
            self.allocator.free(resultRow);
        }
        for (value.projections, 0..) |projection, index| {
            const raw = try self.evalContext(null, &.{}, projection.expr, parameters, outer);
            resultRow[index] = switch (projection.expr) {
                .binary, .unary, .function => raw,
                else => try self.copyValue(raw),
            };
            done = index + 1;
        }
        var rows = try self.allocator.alloc([]Value, 1);
        rows[0] = resultRow;
        for (value.projections) |projection| _ = try columns.append(self.allocator, projection.alias orelse "?column?");
        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = rows };
    }

    fn plannedIndices(self: *Connection, tbl: *const Table, condition: ?ast.Conditions, parameters: []const Value) ![]usize {
        var indexedColumn: ?usize = null;
        var lookup: Value = .null;
        if (condition) |conditions| if (conditions.len == 1 and conditions[0].op == .equal) {
            for (self.store.indexes.items) |index| if (index.columns.len == 1 and std.ascii.eqlIgnoreCase(index.table, tbl.name) and std.ascii.eqlIgnoreCase(index.columns[0], conditions[0].column)) {
                if (index.whereExpr) |predicate| {
                    if (!exprEvaluator.partialPredicateImpliedBy(predicate, conditions)) continue;
                }
                indexedColumn = try columnIndex(tbl, index.columns[0]);
                lookup = self.resolve(conditions[0].value, parameters) catch .null;
                break;
            };
        };
        var indices = std.ArrayList(usize).empty;
        defer indices.deinit(self.allocator);
        if (indexedColumn) |columnIdx| {
            for (tbl.rows.items, 0..) |row, rowIndex| if (compare(row.values[columnIdx], .equal, lookup)) try indices.append(self.allocator, rowIndex);
        } else {
            try indices.ensureTotalCapacity(self.allocator, tbl.rows.items.len);
            for (tbl.rows.items, 0..) |_, rowIndex| try indices.append(self.allocator, rowIndex);
        }
        return indices.toOwnedSlice(self.allocator);
    }

    fn freeJoinRow(allocator: std.mem.Allocator, row: *JoinRow) void {
        allocator.free(row.segments);
        allocator.free(row.frames);
    }

    fn freeJoinRows(allocator: std.mem.Allocator, rows: *std.ArrayList(JoinRow)) void {
        for (rows.items) |*row| freeJoinRow(allocator, row);
        rows.deinit(allocator);
    }

    fn extendJoinRow(self: *Connection, prev: ?*const JoinRow, tbl: *const Table, alias: ?[]const u8, values: []const Value, segCount: usize, outer: ?*const OuterRow) !JoinRow {
        const segments = try self.allocator.alloc(JoinSegment, segCount);
        errdefer self.allocator.free(segments);
        const frames = try self.allocator.alloc(OuterRow, segCount);
        errdefer self.allocator.free(frames);
        if (prev) |existing| std.mem.copyForwards(JoinSegment, segments[0 .. segCount - 1], existing.segments);
        segments[segCount - 1] = .{ .table = tbl, .alias = alias, .values = values };
        for (frames, 0..) |*frame, index| frame.* = .{ .table = segments[index].table, .alias = segments[index].alias, .values = segments[index].values, .prev = if (index + 1 < segCount) &frames[index + 1] else outer };
        return .{ .segments = segments, .frames = frames };
    }

    fn chainSideValue(segments: []const JoinSegment, right: *const Table, rightAlias: ?[]const u8, rightValues: []const Value, tableName: []const u8, column: []const u8, leftSide: bool) !Value {
        if (tableName.len == 0) {
            if (leftSide) {
                var found: ?usize = null;
                var foundIndex: usize = 0;
                for (segments, 0..) |seg, si| if (columnIndex(seg.table, column) catch null) |index| {
                    if (found != null) return error.AmbiguousColumn;
                    found = si;
                    foundIndex = index;
                };
                if (found) |si| return segments[si].values[foundIndex];
                return error.UnknownColumn;
            }
            return rightValues[try columnIndex(right, column)];
        }
        for (segments) |seg| if (groupQualifierMatches(tableName, seg.table, seg.alias)) return seg.values[try columnIndex(seg.table, column)];
        if (groupQualifierMatches(tableName, right, rightAlias)) return rightValues[try columnIndex(right, column)];
        return error.UnknownColumn;
    }

    fn chainPairMatches(segments: []const JoinSegment, right: *const Table, rightAlias: ?[]const u8, rightValues: []const Value, join: ast.Join, merge: ChainMerge) !bool {
        if (join.kind == .cross and !join.mergeOutput) return true;
        if (join.mergeOutput) {
            for (merge.pairs) |pair| if (!compare(segments[pair.seg].values[pair.left], .equal, rightValues[pair.right])) return false;
            return true;
        }
        const leftValue = try chainSideValue(segments, right, rightAlias, rightValues, join.leftTable, join.leftColumn, true);
        const rightValue = try chainSideValue(segments, right, rightAlias, rightValues, join.rightTable, join.rightColumn, false);
        return compare(leftValue, .equal, rightValue);
    }

    fn findMergedGroup(groups: []const MergedGroup, name: []const u8) ?usize {
        for (groups, 0..) |group, index| if (std.ascii.eqlIgnoreCase(group.name, name)) return index;
        return null;
    }

    fn collectJoinBareIdents(self: *Connection, expr: ast.Expr, out: *std.ArrayList([]const u8)) !void {
        switch (expr) {
            .identifier => |name| if (std.mem.indexOfScalar(u8, name, '.') == null) try out.append(self.allocator, name),
            .binary => |b| {
                try self.collectJoinBareIdents(b.left.*, out);
                try self.collectJoinBareIdents(b.right.*, out);
            },
            .unary => |u| try self.collectJoinBareIdents(u.expr.*, out),
            .function => |f| {
                try self.collectJoinBareIdents(f.argument.*, out);
                if (f.argument2) |a| try self.collectJoinBareIdents(a.*, out);
                if (f.argument3) |a| try self.collectJoinBareIdents(a.*, out);
                for (f.extraArgs) |a| try self.collectJoinBareIdents(a, out);
            },
            .caseExpr => |c| {
                if (c.base) |b| try self.collectJoinBareIdents(b.*, out);
                for (c.whens) |when| {
                    try self.collectJoinBareIdents(when.condition, out);
                    try self.collectJoinBareIdents(when.result, out);
                }
                if (c.otherwise) |o| try self.collectJoinBareIdents(o.*, out);
            },
            .patternMatch => |m| {
                try self.collectJoinBareIdents(m.value.*, out);
                try self.collectJoinBareIdents(m.pattern.*, out);
                if (m.escape) |e| try self.collectJoinBareIdents(e.*, out);
            },
            .collate => |node| try self.collectJoinBareIdents(node.expr.*, out),
            .inList => |l| {
                try self.collectJoinBareIdents(l.expr.*, out);
                for (l.list) |item| try self.collectJoinBareIdents(item, out);
            },
            .inSubquery => |s| try self.collectJoinBareIdents(s.expr.*, out),
            .window => |w| {
                if (w.argument) |a| try self.collectJoinBareIdents(a.*, out);
                if (w.argument2) |a| try self.collectJoinBareIdents(a.*, out);
                for (w.extraArgs) |a| try self.collectJoinBareIdents(a, out);
                for (w.partitionBy) |a| try self.collectJoinBareIdents(a, out);
                for (w.orderBy) |o| try self.collectJoinBareIdents(o.expr, out);
            },
            else => {},
        }
    }

    fn checkJoinAmbiguous(self: *Connection, tables: []const *const Table, groups: []const MergedGroup, names: []const []const u8) !void {
        _ = self;
        for (names) |name| {
            if (name.len == 0) continue;
            if (findMergedGroup(groups, name) != null) continue;
            var count: usize = 0;
            for (tables) |tbl| if (columnIndex(tbl, name) catch null) |_| {
                count += 1;
                if (count > 1) return error.AmbiguousColumn;
            };
        }
    }

    fn joinRowField(row: JoinRow, groups: []const MergedGroup, qualifier: []const u8, column: []const u8) !Value {
        if (qualifier.len != 0) {
            for (row.segments) |seg| if (groupQualifierMatches(qualifier, seg.table, seg.alias)) return seg.values[try columnIndex(seg.table, column)];
            return error.UnknownColumn;
        }
        if (findMergedGroup(groups, column)) |index| {
            var result: Value = .null;
            for (groups[index].members.items) |member| {
                const candidate = row.segments[member.seg].values[member.col];
                if (result == .null and candidate != .null) result = candidate;
            }
            return result;
        }
        for (row.segments, 0..) |seg, si| if (columnIndex(seg.table, column) catch null) |index| {
            for (row.segments, 0..) |other, oi| {
                if (oi == si) continue;
                if (columnIndex(other.table, column) catch null) |_| return error.AmbiguousColumn;
            }
            return seg.values[index];
        };
        return error.UnknownColumn;
    }

    fn joinRowPasses(self: *Connection, row: JoinRow, condition: ?ast.Conditions, parameters: []const Value) !bool {
        if (condition == null) return true;
        return self.matchesContext(row.segments[0].table, row.segments[0].values, condition, parameters, &row.frames[0]);
    }

    fn evalJoinRowExpr(self: *Connection, row: JoinRow, expr: ast.Expr, parameters: []const Value) !Value {
        return self.evalContext(null, &.{}, expr, parameters, &row.frames[0]);
    }

    fn materializeJoinRowExpr(self: *Connection, row: JoinRow, expr: ast.Expr, parameters: []const Value) !Value {
        const raw = try self.evalJoinRowExpr(row, expr, parameters);
        return switch (expr) {
            .binary, .unary, .function => raw,
            else => try self.copyValue(raw),
        };
    }

    fn freeJoinResultRows(self: *Connection, rows: *std.ArrayList([]Value)) void {
        for (rows.items) |row| {
            for (row) |item| self.freeConcatText(item);
            self.allocator.free(row);
        }
        rows.deinit(self.allocator);
    }

    const ResolvedSortKey = struct { colIdx: usize, descending: bool };

    fn isRowidAlias(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "rowid") or std.ascii.eqlIgnoreCase(name, "_rowid_") or std.ascii.eqlIgnoreCase(name, "oid");
    }

    fn compareRowsByKeys(a: []const Value, b: []const Value, sortKeys: []const ResolvedSortKey) std.math.Order {
        for (sortKeys) |key| {
            const ord = a[key.colIdx].order(b[key.colIdx], .binary);
            if (ord == .eq) continue;
            return if (key.descending) ord.invert() else ord;
        }
        return .eq;
    }

    fn resolveSortOutputIndex(columns: []const []const u8, projections: ?[]const ast.Projection, orderColumn: []const u8) ?usize {
        if (std.fmt.parseInt(usize, orderColumn, 10)) |pos| {
            if (pos >= 1 and pos <= columns.len) return pos - 1;
        } else |_| {}
        for (columns, 0..) |name, idx| if (std.ascii.eqlIgnoreCase(name, orderColumn)) return idx;
        const parts = splitQualifier(orderColumn);
        if (parts.qualifier.len != 0) {
            if (projections) |projs| {
                for (projs, 0..) |proj, idx| {
                    if (proj.expr == .identifier) {
                        const exprParts = splitQualifier(proj.expr.identifier);
                        if (exprParts.qualifier.len != 0 and std.ascii.eqlIgnoreCase(exprParts.qualifier, parts.qualifier) and std.ascii.eqlIgnoreCase(exprParts.column, parts.column)) return idx;
                    }
                }
            }
        }
        // A qualified key never falls back to a bare-column match: qualifiers
        // are load-bearing scope, and guessing a same-named column from another
        // table silently sorts by the wrong key. Unresolvable qualified keys
        // return null so callers use table-scope resolution or report the
        // construct as unsupported.
        if (parts.qualifier.len == 0) {
            for (columns, 0..) |name, idx| if (std.ascii.eqlIgnoreCase(splitQualifier(name).column, parts.column)) return idx;
        }
        return null;
    }

    fn sortIndexRows(self: *Connection, tbl: *const Table, value: anytype, orderedIndices: []usize) !void {
        const sortKeys = try self.allocator.alloc(ResolvedSortKey, value.orders.len);
        defer self.allocator.free(sortKeys);
        for (value.orders, 0..) |keyOrder, keyIndex| {
            sortKeys[keyIndex] = .{ .colIdx = resolveOrderColumnIndex(tbl, value.projections, keyOrder.column) orelse try columnIndex(tbl, keyOrder.column), .descending = keyOrder.descending };
        }
        var i: usize = 0;
        while (i < orderedIndices.len) : (i += 1) {
            var j = i + 1;
            while (j < orderedIndices.len) : (j += 1) {
                if (compareRowsByKeys(tbl.rows.items[orderedIndices[i]].values, tbl.rows.items[orderedIndices[j]].values, sortKeys) == .gt)
                    std.mem.swap(usize, &orderedIndices[i], &orderedIndices[j]);
            }
        }
    }

    fn sortJoinRows(self: *Connection, rows: *std.ArrayList([]Value), columns: []const []const u8, projections: ?[]const ast.Projection, orders: []const ast.Order) !void {
        if (orders.len == 0) return;
        const sortKeys = try self.allocator.alloc(ResolvedSortKey, orders.len);
        defer self.allocator.free(sortKeys);
        for (orders, 0..) |ord, keyIndex| {
            sortKeys[keyIndex] = .{ .colIdx = resolveSortOutputIndex(columns, projections, ord.column) orelse return error.Unsupported, .descending = ord.descending };
        }
        var i: usize = 0;
        while (i < rows.items.len) : (i += 1) {
            var j = i + 1;
            while (j < rows.items.len) : (j += 1) {
                if (compareRowsByKeys(rows.items[i], rows.items[j], sortKeys) == .gt)
                    std.mem.swap([]Value, &rows.items[i], &rows.items[j]);
            }
        }
    }

    fn paginateJoinRows(self: *Connection, rows: *std.ArrayList([]Value), limit: ?usize, offset: ?usize) !void {
        if (limit == null and offset == null) return;
        const start = @min(offset orelse 0, rows.items.len);
        var end = rows.items.len;
        if (limit) |max| end = @min(start +| max, rows.items.len);
        var kept = std.ArrayList([]Value).empty;
        errdefer kept.deinit(self.allocator);
        for (rows.items, 0..) |row, index| {
            if (index >= start and index < end) try kept.append(self.allocator, row);
        }
        for (rows.items, 0..) |row, index| {
            if (index < start or index >= end) {
                for (row) |item| self.freeConcatText(item);
                self.allocator.free(row);
            }
        }
        rows.deinit(self.allocator);
        rows.* = kept;
    }

    const QualifierParts = struct { qualifier: []const u8, column: []const u8 };

    fn splitQualifier(name: []const u8) QualifierParts {
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| return .{ .qualifier = name[0..dot], .column = name[dot + 1 ..] };
        return .{ .qualifier = "", .column = name };
    }

    fn qualifierTablePart(qualifier: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, qualifier, '.')) |dot| return qualifier[dot + 1 ..];
        return qualifier;
    }

    fn groupQualifierMatches(qualifier: []const u8, tbl: *const Table, alias: ?[]const u8) bool {
        if (qualifier.len == 0) return true;
        const tablePart = qualifierTablePart(qualifier);
        if (std.ascii.eqlIgnoreCase(tablePart, tbl.name)) return true;
        if (alias) |name| if (std.ascii.eqlIgnoreCase(tablePart, name)) return true;
        return false;
    }

    fn stripSchemaQualifier(self: *Connection, name: []const u8) []const u8 {
        const firstDot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
        if (std.mem.indexOfScalar(u8, name[firstDot + 1 ..], '.') == null) return name;
        const schemaName = name[0..firstDot];
        if (std.ascii.eqlIgnoreCase(schemaName, "main") or std.ascii.eqlIgnoreCase(schemaName, "temp")) return name[firstDot + 1 ..];
        for (self.attached.items) |*db| if (std.ascii.eqlIgnoreCase(db.name, schemaName)) return name[firstDot + 1 ..];
        return name;
    }

    const KeyLoc = struct { provider: usize, group: ?usize };

    fn resolveJoinKey(tables: []const *const Table, aliases: []const ?[]const u8, groups: []const MergedGroup, qualifier: []const u8, column: []const u8) !KeyLoc {
        if (qualifier.len != 0) {
            for (tables, 0..) |tbl, index| if (groupQualifierMatches(qualifier, tbl, aliases[index])) {
                _ = try columnIndex(tbl, column);
                return .{ .provider = index, .group = null };
            };
            return error.UnknownColumn;
        }
        if (findMergedGroup(groups, column)) |index| return .{ .provider = groups[index].members.items[0].seg, .group = index };
        var found: ?usize = null;
        for (tables, 0..) |tbl, index| if (columnIndex(tbl, column) catch null) |_| {
            if (found != null) return error.AmbiguousColumn;
            found = index;
        };
        if (found) |index| return .{ .provider = index, .group = null };
        return error.UnknownColumn;
    }

    fn keyQualifierOk(parts: QualifierParts, keyName: []const u8, tables: []const *const Table, aliases: []const ?[]const u8, loc: KeyLoc, groups: []const MergedGroup) bool {
        if (!std.ascii.eqlIgnoreCase(parts.column, keyName)) return false;
        if (parts.qualifier.len == 0) return true;
        if (groupQualifierMatches(parts.qualifier, tables[loc.provider], aliases[loc.provider])) return true;
        if (loc.group) |gi| {
            for (groups[gi].members.items) |member| if (groupQualifierMatches(parts.qualifier, tables[member.seg], aliases[member.seg])) return true;
        }
        return false;
    }

    fn joinKeyValue(self: *Connection, row: JoinRow, groups: []const MergedGroup, parts: QualifierParts, loc: KeyLoc) !Value {
        if (loc.group) |gi| {
            var result: Value = .null;
            for (groups[gi].members.items) |member| {
                const candidate = row.segments[member.seg].values[member.col];
                if (result == .null and candidate != .null) result = try self.copyValue(candidate);
            }
            return result;
        }
        const seg = row.segments[loc.provider];
        return try self.copyValue(seg.values[try columnIndex(seg.table, parts.column)]);
    }

    fn nullExtendJoinRow(self: *Connection, tables: []const *const Table, aliases: []const ?[]const u8, slabs: []const []Value, right: *const Table, rightAlias: ?[]const u8, rightValues: []const Value, segCount: usize, outer: ?*const OuterRow) !JoinRow {
        const segments = try self.allocator.alloc(JoinSegment, segCount);
        errdefer self.allocator.free(segments);
        const frames = try self.allocator.alloc(OuterRow, segCount);
        errdefer self.allocator.free(frames);
        for (0..segCount - 1) |index| segments[index] = .{ .table = tables[index], .alias = aliases[index], .values = slabs[index] };
        segments[segCount - 1] = .{ .table = right, .alias = rightAlias, .values = rightValues };
        for (frames, 0..) |*frame, index| frame.* = .{ .table = segments[index].table, .alias = segments[index].alias, .values = segments[index].values, .prev = if (index + 1 < segCount) &frames[index + 1] else outer };
        return .{ .segments = segments, .frames = frames };
    }

    fn selectJoin(self: *Connection, value: anytype, left: *const Table, parameters: []const Value, outer: ?*const OuterRow) !Result {
        const joins = value.joins;
        var tables = std.ArrayList(*const Table).empty;
        defer tables.deinit(self.allocator);
        try tables.append(self.allocator, left);
        for (joins) |join| {
            const resolved = self.resolveTableName(join.table) orelse return error.UnknownTable;
            try tables.append(self.allocator, resolved.table);
        }
        var aliases = std.ArrayList(?[]const u8).empty;
        defer aliases.deinit(self.allocator);
        try aliases.append(self.allocator, value.tableAlias);
        for (joins) |join| try aliases.append(self.allocator, join.tableAlias);
        var merges = std.ArrayList(ChainMerge).empty;
        defer {
            for (merges.items) |merge| {
                if (merge.pairs.len != 0) self.allocator.free(merge.pairs);
                if (merge.droppedRight.len != 0) self.allocator.free(merge.droppedRight);
            }
            merges.deinit(self.allocator);
        }
        var mergedGroups = std.ArrayList(MergedGroup).empty;
        defer {
            for (mergedGroups.items) |*group| group.members.deinit(self.allocator);
            mergedGroups.deinit(self.allocator);
        }
        for (joins, 0..) |join, joinIndex| {
            const right = tables.items[joinIndex + 1];
            var mergePairs = std.ArrayList(ChainMergePair).empty;
            errdefer mergePairs.deinit(self.allocator);
            var dropped = std.ArrayList(bool).empty;
            errdefer dropped.deinit(self.allocator);
            try dropped.appendNTimes(self.allocator, false, right.columns.len);
            if (join.mergeOutput) {
                if (join.leftTable.len == 0) {
                    for (right.columns, 0..) |rightColumn, rightIdx| {
                        var found = false;
                        for (tables.items[0 .. joinIndex + 1], 0..) |segTable, segIdx| {
                            if (columnIndex(segTable, rightColumn.name) catch null) |leftIdx| {
                                try mergePairs.append(self.allocator, .{ .seg = segIdx, .left = leftIdx, .right = rightIdx });
                                found = true;
                                break;
                            }
                        }
                        if (found) dropped.items[rightIdx] = true;
                    }
                } else {
                    const mergeNames: []const []const u8 = if (join.usingColumns.len != 0) join.usingColumns else &[_][]const u8{join.leftColumn};
                    for (mergeNames) |name| {
                        var accSeg: ?usize = null;
                        var accIdx: usize = 0;
                        for (tables.items[0 .. joinIndex + 1], 0..) |segTable, segIdx| {
                            if (columnIndex(segTable, name) catch null) |idx| {
                                accSeg = segIdx;
                                accIdx = idx;
                                break;
                            }
                        }
                        const found = accSeg orelse return error.UnknownColumn;
                        const rightIdx = try columnIndex(right, name);
                        try mergePairs.append(self.allocator, .{ .seg = found, .left = accIdx, .right = rightIdx });
                        dropped.items[rightIdx] = true;
                    }
                }
                for (mergePairs.items) |pair| {
                    const colName = tables.items[pair.seg].columns[pair.left].name;
                    if (findMergedGroup(mergedGroups.items, colName)) |groupIndex| {
                        try mergedGroups.items[groupIndex].members.append(self.allocator, .{ .seg = joinIndex + 1, .col = pair.right });
                    } else {
                        var members = std.ArrayList(MergeMember).empty;
                        errdefer members.deinit(self.allocator);
                        try members.append(self.allocator, .{ .seg = pair.seg, .col = pair.left });
                        try members.append(self.allocator, .{ .seg = joinIndex + 1, .col = pair.right });
                        try mergedGroups.append(self.allocator, .{ .name = colName, .members = members });
                    }
                }
            }
            try merges.append(self.allocator, .{
                .pairs = if (mergePairs.items.len == 0) &.{} else try mergePairs.toOwnedSlice(self.allocator),
                .droppedRight = if (dropped.items.len == 0) &.{} else try dropped.toOwnedSlice(self.allocator),
            });
        }
        // SQLite resolves unqualified join references against every table in
        // scope and reports ambiguity instead of guessing. USING/NATURAL
        // merged columns coalesce and are exempt.
        {
            var bare = std.ArrayList([]const u8).empty;
            defer bare.deinit(self.allocator);
            if (value.condition) |conds| for (conds) |cond| {
                if (cond.column.len != 0 and std.mem.indexOfScalar(u8, cond.column, '.') == null) try bare.append(self.allocator, cond.column);
                if (cond.leftExpr) |e| try self.collectJoinBareIdents(e, &bare);
                try self.collectJoinBareIdents(cond.value, &bare);
                if (cond.value2) |v| try self.collectJoinBareIdents(v, &bare);
                for (cond.listValues) |v| try self.collectJoinBareIdents(v, &bare);
                if (cond.escape) |e| try self.collectJoinBareIdents(e, &bare);
            };
            for (value.projections) |projection| try self.collectJoinBareIdents(projection.expr, &bare);
            if (value.having) |having| {
                try self.collectJoinBareIdents(having.left, &bare);
                try self.collectJoinBareIdents(having.right, &bare);
            }
            for (value.orders) |ord| {
                const parts = splitQualifier(ord.column);
                if (parts.qualifier.len == 0) {
                    var inOutput = false;
                    for (value.projections) |projection| {
                        if (projection.alias) |a| {
                            if (std.ascii.eqlIgnoreCase(a, parts.column)) {
                                inOutput = true;
                                break;
                            }
                        } else if (projection.expr == .identifier) {
                            if (std.ascii.eqlIgnoreCase(splitQualifier(projection.expr.identifier).column, parts.column)) {
                                inOutput = true;
                                break;
                            }
                        }
                    }
                    if (!inOutput) try bare.append(self.allocator, parts.column);
                }
            }
            try self.checkJoinAmbiguous(tables.items, mergedGroups.items, bare.items);
        }
        var slabs = std.ArrayList([]Value).empty;
        defer {
            for (slabs.items) |slab| self.allocator.free(slab);
            slabs.deinit(self.allocator);
        }
        for (tables.items) |tbl| {
            const slab = try self.allocator.alloc(Value, tbl.columns.len);
            @memset(slab, .null);
            try slabs.append(self.allocator, slab);
        }
        var current = std.ArrayList(JoinRow).empty;
        defer freeJoinRows(self.allocator, &current);
        for (left.rows.items) |leftRow| try current.append(self.allocator, try self.extendJoinRow(null, left, value.tableAlias, leftRow.values, 1, outer));
        for (joins, 0..) |join, joinIndex| {
            const right = tables.items[joinIndex + 1];
            const rightAlias = join.tableAlias;
            const merge = merges.items[joinIndex];
            var next = std.ArrayList(JoinRow).empty;
            errdefer freeJoinRows(self.allocator, &next);
            const rightMatched = try self.allocator.alloc(bool, right.rows.items.len);
            defer self.allocator.free(rightMatched);
            @memset(rightMatched, false);
            for (current.items) |*row| {
                var matched = false;
                for (right.rows.items, 0..) |rightRow, rightRowIndex| {
                    if (!try chainPairMatches(row.segments, right, rightAlias, rightRow.values, join, merge)) continue;
                    matched = true;
                    rightMatched[rightRowIndex] = true;
                    try next.append(self.allocator, try self.extendJoinRow(row, right, rightAlias, rightRow.values, joinIndex + 2, outer));
                }
                if ((join.kind == .left or join.kind == .full) and !matched) {
                    try next.append(self.allocator, try self.extendJoinRow(row, right, rightAlias, slabs.items[joinIndex + 1], joinIndex + 2, outer));
                }
            }
            if (join.kind == .right or join.kind == .full) {
                for (right.rows.items, 0..) |rightRow, rightRowIndex| if (!rightMatched[rightRowIndex]) {
                    try next.append(self.allocator, try self.nullExtendJoinRow(tables.items, aliases.items, slabs.items, right, rightAlias, rightRow.values, joinIndex + 2, outer));
                };
            }
            freeJoinRows(self.allocator, &current);
            current = next;
        }
        var pairs = std.ArrayList(JoinRow).empty;
        defer pairs.deinit(self.allocator);
        for (current.items) |row| if (try self.joinRowPasses(row, value.condition, parameters)) try pairs.append(self.allocator, row);
        if (value.groupBy) |groupName| {
            var groupedRows = std.ArrayList([]Value).empty;
            errdefer self.freeJoinResultRows(&groupedRows);
            var groupedColumns = std.ArrayList([]const u8).empty;
            defer groupedColumns.deinit(self.allocator);
            const sortGrouped = try self.collectJoinGrouped(pairs.items, mergedGroups.items, tables.items, aliases.items, value, groupName, parameters, &groupedRows, &groupedColumns);
            if (sortGrouped) try self.sortJoinRows(&groupedRows, groupedColumns.items, value.projections, value.orders);
            try self.paginateJoinRows(&groupedRows, value.limit, value.offset);
            return .{ .allocator = self.allocator, .columns = try self.ownedColumns(groupedColumns.items), .rows = try groupedRows.toOwnedSlice(self.allocator) };
        }
        var anyAgg = false;
        for (value.projections) |projection| {
            if (projection.expr == .function and functions.aggregate.AggKind.fromName(projection.expr.function.name) != null) {
                anyAgg = true;
                break;
            }
        }
        if (anyAgg) {
            var aggRows = std.ArrayList([]Value).empty;
            errdefer self.freeJoinResultRows(&aggRows);
            var aggColumns = std.ArrayList([]const u8).empty;
            defer aggColumns.deinit(self.allocator);
            try self.collectJoinAggregate(pairs.items, value, parameters, &aggRows, &aggColumns);
            try self.sortJoinRows(&aggRows, aggColumns.items, value.projections, value.orders);
            try self.paginateJoinRows(&aggRows, value.limit, value.offset);
            return .{ .allocator = self.allocator, .columns = try self.ownedColumns(aggColumns.items), .rows = try aggRows.toOwnedSlice(self.allocator) };
        }
        var columns = std.ArrayList([]const u8).empty;
        defer columns.deinit(self.allocator);
        for (value.projections) |projection| {
            if (projection.expr == .wildcard) {
                for (tables.items, 0..) |segTable, segIdx| {
                    for (segTable.columns, 0..) |column, colIdx| {
                        if (segIdx != 0 and merges.items[segIdx - 1].droppedRight[colIdx]) continue;
                        try columns.append(self.allocator, column.name);
                    }
                }
            } else if (projection.expr == .identifier) {
                const name = projection.expr.identifier;
                const dot = std.mem.lastIndexOfScalar(u8, name, '.');
                const columnName = if (dot) |position| name[position + 1 ..] else name;
                try columns.append(self.allocator, projection.alias orelse columnName);
            } else if (projection.expr == .function) {
                try columns.append(self.allocator, projection.alias orelse projection.expr.function.name);
            } else if (projection.expr == .window) {
                try columns.append(self.allocator, projection.alias orelse projection.expr.window.funcName);
            } else {
                try columns.append(self.allocator, projection.alias orelse "?column?");
            }
        }
        var rows = std.ArrayList([]Value).empty;
        errdefer self.freeJoinResultRows(&rows);
        var pairOrder: ?[]usize = null;
        defer if (pairOrder) |indices| self.allocator.free(indices);
        if (value.orders.len != 0) {
            var allInOutput = true;
            for (value.orders) |keyOrder| {
                if (resolveSortOutputIndex(columns.items, value.projections, keyOrder.column) == null) {
                    allInOutput = false;
                    break;
                }
            }
            if (!allInOutput) {
                if (value.distinct) return error.Unsupported;
                const indices = try self.allocator.alloc(usize, pairs.items.len);
                errdefer self.allocator.free(indices);
                for (indices, 0..) |*slot, position| slot.* = position;
                var i: usize = 0;
                while (i < indices.len) : (i += 1) {
                    var j = i + 1;
                    while (j < indices.len) : (j += 1) {
                        // Multi-key compare over pre-projection pairs, using
                        // the same first-non-equal-key plus per-key DESC
                        // inversion as compareRowsByKeys. joinRowField
                        // resolves qualifiers against the joined tables (with
                        // ambiguity detection) and borrows values, so no
                        // per-comparison allocation occurs.
                        var swap = false;
                        for (value.orders) |ord| {
                            const orderParts = splitQualifier(ord.column);
                            const first = try joinRowField(pairs.items[indices[i]], mergedGroups.items, orderParts.qualifier, orderParts.column);
                            const second = try joinRowField(pairs.items[indices[j]], mergedGroups.items, orderParts.qualifier, orderParts.column);
                            const placed = first.order(second, .binary);
                            const resolved = if (ord.descending) placed.invert() else placed;
                            if (resolved == .eq) continue;
                            swap = resolved == .gt;
                            break;
                        }
                        if (swap) std.mem.swap(usize, &indices[i], &indices[j]);
                    }
                }
                pairOrder = indices;
            }
        }
        if (pairOrder) |indices| {
            for (indices) |pairIndex| try self.appendJoinRow(&rows, value.projections, pairs.items[pairIndex], tables.items, merges.items, mergedGroups.items, parameters);
        } else {
            for (pairs.items) |pair| try self.appendJoinRow(&rows, value.projections, pair, tables.items, merges.items, mergedGroups.items, parameters);
            if (value.distinct) {
                var index: usize = 0;
                while (index < rows.items.len) {
                    var duplicateIndex = index + 1;
                    while (duplicateIndex < rows.items.len) {
                        if (rowsEqual(rows.items[index], rows.items[duplicateIndex])) {
                            const duplicate = rows.orderedRemove(duplicateIndex);
                            for (duplicate) |item| self.freeConcatText(item);
                            self.allocator.free(duplicate);
                        } else duplicateIndex += 1;
                    }
                    index += 1;
                }
            }
            try self.sortJoinRows(&rows, columns.items, value.projections, value.orders);
        }
        try self.paginateJoinRows(&rows, value.limit, value.offset);
        return .{ .allocator = self.allocator, .columns = try self.ownedColumns(columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
    }

    fn appendJoinRow(self: *Connection, rows: *std.ArrayList([]Value), projections: []const ast.Projection, row: JoinRow, tables: []const *const Table, merges: []const ChainMerge, groups: []const MergedGroup, parameters: []const Value) !void {
        var width: usize = 0;
        for (projections) |projection| {
            if (projection.expr == .wildcard) {
                for (tables, 0..) |segTable, segIdx| {
                    for (segTable.columns, 0..) |_, colIdx| {
                        if (segIdx != 0 and merges[segIdx - 1].droppedRight[colIdx]) continue;
                        width += 1;
                    }
                }
            } else width += 1;
        }
        const output = try self.allocator.alloc(Value, width);
        var outputIndex: usize = 0;
        errdefer {
            for (output[0..outputIndex]) |item| self.freeConcatText(item);
            self.allocator.free(output);
        }
        for (projections) |projection| {
            if (projection.expr == .wildcard) {
                for (row.segments, 0..) |seg, segIdx| {
                    for (seg.values, 0..) |item, colIdx| {
                        if (segIdx != 0 and merges[segIdx - 1].droppedRight[colIdx]) continue;
                        output[outputIndex] = try self.copyValue(item);
                        outputIndex += 1;
                    }
                }
            } else if (projection.expr == .identifier) {
                const parts = splitQualifier(projection.expr.identifier);
                if (parts.qualifier.len == 0) {
                    if (findMergedGroup(groups, parts.column)) |groupIndex| {
                        var merged: Value = .null;
                        for (groups[groupIndex].members.items) |member| {
                            const candidate = row.segments[member.seg].values[member.col];
                            if (merged == .null and candidate != .null) merged = try self.copyValue(candidate);
                        }
                        output[outputIndex] = merged;
                        outputIndex += 1;
                        continue;
                    }
                }
                const raw = try self.evalJoinRowExpr(row, projection.expr, parameters);
                output[outputIndex] = try self.copyValue(raw);
                outputIndex += 1;
            } else {
                const raw = try self.evalJoinRowExpr(row, projection.expr, parameters);
                output[outputIndex] = switch (projection.expr) {
                    .binary, .unary, .function => raw,
                    else => try self.copyValue(raw),
                };
                outputIndex += 1;
            }
        }
        try rows.append(self.allocator, output);
    }

    fn collectJoinAggregate(self: *Connection, pairs: []const JoinRow, value: anytype, parameters: []const Value, rows: *std.ArrayList([]Value), columns: *std.ArrayList([]const u8)) !void {
        var aggStates = try self.allocator.alloc(?functions.aggregate.AggState, value.projections.len);
        defer self.allocator.free(aggStates);
        for (value.projections, 0..) |projection, index| {
            if (projection.expr == .function) {
                if (functions.aggregate.AggKind.fromName(projection.expr.function.name)) |kind| {
                    var sep: ?[]const u8 = null;
                    if (projection.expr.function.argument2) |a2| {
                        const sVal = try self.resolve(a2.*, parameters);
                        if (sVal == .text) sep = sVal.text;
                    }
                    aggStates[index] = functions.aggregate.AggState.init(self.allocator, kind, sep);
                    try columns.append(self.allocator, projection.alias orelse projection.expr.function.name);
                    continue;
                }
            }
            aggStates[index] = null;
            switch (projection.expr) {
                .identifier => try columns.append(self.allocator, projection.alias orelse projection.expr.identifier),
                else => try columns.append(self.allocator, projection.alias orelse "?column?"),
            }
        }
        defer {
            for (aggStates) |*state| {
                if (state.*) |*agg| agg.deinit();
            }
        }
        var firstPair: ?JoinRow = null;
        for (pairs) |pair| {
            if (firstPair == null) firstPair = pair;
            for (value.projections, 0..) |projection, index| {
                if (aggStates[index]) |*agg| {
                    if (projection.expr.function.argument.* == .wildcard) {
                        agg.stepWildcard();
                    } else {
                        const item = try self.evalJoinRowExpr(pair, projection.expr.function.argument.*, parameters);
                        try agg.step(item, projection.expr.function.distinct);
                    }
                }
            }
        }
        const aggregateRow = try self.allocator.alloc(Value, value.projections.len);
        var done: usize = 0;
        errdefer {
            for (aggregateRow[0..done]) |item| self.freeConcatText(item);
            self.allocator.free(aggregateRow);
        }
        for (value.projections, 0..) |projection, index| {
            done = index;
            if (aggStates[index]) |*agg| {
                aggregateRow[index] = try agg.result();
            } else if (firstPair) |pair| {
                aggregateRow[index] = try self.materializeJoinRowExpr(pair, projection.expr, parameters);
            } else {
                aggregateRow[index] = .null;
            }
            done = index + 1;
        }
        try rows.append(self.allocator, aggregateRow);
    }

    fn collectJoinGrouped(self: *Connection, pairs: []const JoinRow, groups: []const MergedGroup, tables: []const *const Table, aliases: []const ?[]const u8, value: anytype, groupName: []const u8, parameters: []const Value, rows: *std.ArrayList([]Value), columns: *std.ArrayList([]const u8)) !bool {
        const groupParts = splitQualifier(groupName);
        const keyName = groupParts.column;
        const loc = try resolveJoinKey(tables, aliases, groups, groupParts.qualifier, keyName);
        const Group = struct { key: Value, rows: std.ArrayList(usize) };
        var grouped = std.ArrayList(Group).empty;
        defer {
            for (grouped.items) |*group| {
                self.freeConcatText(group.key);
                group.rows.deinit(self.allocator);
            }
            grouped.deinit(self.allocator);
        }
        for (pairs, 0..) |pair, pairIndex| {
            const key = try self.joinKeyValue(pair, groups, groupParts, loc);
            var found: ?usize = null;
            for (grouped.items, 0..) |group, position| if (sameValue(group.key, key)) {
                found = position;
                break;
            };
            if (found) |position| {
                self.freeConcatText(key);
                try grouped.items[position].rows.append(self.allocator, pairIndex);
            } else {
                try grouped.append(self.allocator, .{ .key = key, .rows = .empty });
                try grouped.items[grouped.items.len - 1].rows.append(self.allocator, pairIndex);
            }
        }
        for (value.projections) |projection| switch (projection.expr) {
            .identifier => |name| try columns.append(self.allocator, projection.alias orelse splitQualifier(name).column),
            .function => try columns.append(self.allocator, projection.alias orelse projection.expr.function.name),
            else => return error.Unsupported,
        };
        var sortAfter = false;
        if (value.orders.len != 0) {
            sortAfter = true;
            for (value.orders) |keyOrder| {
                if (resolveSortOutputIndex(columns.items, value.projections, keyOrder.column) == null) {
                    sortAfter = false;
                    break;
                }
            }
            if (!sortAfter) {
                if (value.orders.len != 1) return error.Unsupported;
                const ord = value.orders[0];
                if (!keyQualifierOk(splitQualifier(ord.column), keyName, tables, aliases, loc, groups)) return error.Unsupported;
                var gi: usize = 0;
                while (gi < grouped.items.len) : (gi += 1) {
                    var gj = gi + 1;
                    while (gj < grouped.items.len) : (gj += 1) {
                        const placed = grouped.items[gi].key.order(grouped.items[gj].key, .binary);
                        if ((if (ord.descending) placed.invert() else placed) == .gt)
                            std.mem.swap(Group, &grouped.items[gi], &grouped.items[gj]);
                    }
                }
            }
        }
        for (grouped.items) |group| {
            if (value.having) |having| {
                const leftValue: Value = switch (having.left) {
                    .identifier => |name| blk: {
                        if (!keyQualifierOk(splitQualifier(name), keyName, tables, aliases, loc, groups)) return error.Unsupported;
                        break :blk try self.copyValue(group.key);
                    },
                    .function => |function| blk: {
                        if (functions.aggregate.AggKind.fromName(function.name)) |kind| {
                            var sep: ?[]const u8 = null;
                            if (function.argument2) |a2| {
                                const sVal = try self.resolve(a2.*, parameters);
                                if (sVal == .text) sep = sVal.text;
                            }
                            var agg = functions.aggregate.AggState.init(self.allocator, kind, sep);
                            defer agg.deinit();
                            for (group.rows.items) |pairIndex| {
                                const pair = pairs[pairIndex];
                                if (function.argument.* == .wildcard) {
                                    agg.stepWildcard();
                                } else {
                                    const item = try self.evalJoinRowExpr(pair, function.argument.*, parameters);
                                    try agg.step(item, function.distinct);
                                }
                            }
                            break :blk try agg.result();
                        }
                        return error.Unsupported;
                    },
                    else => return error.Unsupported,
                };
                defer self.freeConcatText(leftValue);
                if (having.op == .isTrue and !functions.scalar.isTruthyValue(leftValue)) continue;
                const rightValue = try self.resolve(having.right, parameters);
                const rightOwned = having.right == .binary or having.right == .unary;
                defer if (rightOwned) self.freeConcatText(rightValue);
                if (having.op != .isTrue and !compare(leftValue, having.op, rightValue)) continue;
            }
            const output = try self.allocator.alloc(Value, value.projections.len);
            var done: usize = 0;
            errdefer {
                for (output[0..done]) |item| self.freeConcatText(item);
                self.allocator.free(output);
            }
            for (value.projections, 0..) |projection, outputIndex| {
                done = outputIndex;
                switch (projection.expr) {
                    .identifier => {
                        if (!keyQualifierOk(splitQualifier(projection.expr.identifier), keyName, tables, aliases, loc, groups)) return error.Unsupported;
                        output[outputIndex] = try self.copyValue(group.key);
                    },
                    .function => |function| {
                        if (functions.aggregate.AggKind.fromName(function.name)) |kind| {
                            var sep: ?[]const u8 = null;
                            if (function.argument2) |a2| {
                                const sVal = try self.resolve(a2.*, parameters);
                                if (sVal == .text) sep = sVal.text;
                            }
                            var agg = functions.aggregate.AggState.init(self.allocator, kind, sep);
                            defer agg.deinit();
                            for (group.rows.items) |pairIndex| {
                                const pair = pairs[pairIndex];
                                if (function.argument.* == .wildcard) {
                                    agg.stepWildcard();
                                } else {
                                    const item = try self.evalJoinRowExpr(pair, function.argument.*, parameters);
                                    try agg.step(item, function.distinct);
                                }
                            }
                            output[outputIndex] = try agg.result();
                        } else {
                            return error.Unsupported;
                        }
                    },
                    else => return error.Unsupported,
                }
                done = outputIndex + 1;
            }
            try rows.append(self.allocator, output);
        }
        return sortAfter;
    }

    fn updateFrom(self: *Connection, value: anytype, parameters: []const Value) anyerror!Result {
        if (self.cteActive(value.table)) return error.InvalidSql;
        const resolved = self.resolveTableName(value.table) orelse return error.UnknownTable;
        const store = self.storeFor(resolved.ref);
        const tbl = resolved.table;
        for (value.columns) |name| {
            const index = try columnIndex(tbl, name);
            if (tbl.columns[index].generatedExpr != null) return error.ConstraintViolation;
        }
        const resolvedSource = if (value.from.?.tableSchema.len != 0)
            self.findTableQualified(value.from.?.tableSchema, splitSchemaName(value.from.?.table).object) orelse return error.UnknownTable
        else
            self.resolveTableName(value.from.?.table) orelse return error.UnknownTable;
        const source = resolvedSource.table;
        const sourceSpec = value.from.?;
        const hasPair = sourceSpec.leftColumn.len != 0 and sourceSpec.rightColumn.len != 0;
        const leftTable = if (sourceSpec.leftTable.len == 0) tbl else if (std.ascii.eqlIgnoreCase(sourceSpec.leftTable, tbl.name)) tbl else source;
        const rightTable = if (sourceSpec.rightTable.len == 0) tbl else if (std.ascii.eqlIgnoreCase(sourceSpec.rightTable, tbl.name)) tbl else source;
        const leftColumn: usize = if (hasPair) try columnIndex(leftTable, sourceSpec.leftColumn) else 0;
        const rightColumn: usize = if (hasPair) try columnIndex(rightTable, sourceSpec.rightColumn) else 0;
        var changes: usize = 0;
        var affectedRows = std.ArrayList([]const Value).empty;
        defer affectedRows.deinit(self.allocator);
        for (tbl.rows.items, 0..) |*row, rowIndex| {
            for (source.rows.items) |sourceRow| {
                if (hasPair) {
                    const leftValue = if (leftTable == tbl) row.values[leftColumn] else sourceRow.values[leftColumn];
                    const rightValue = if (rightTable == tbl) row.values[rightColumn] else sourceRow.values[rightColumn];
                    if (!compare(leftValue, .equal, rightValue)) continue;
                }
                if (value.condition) |conds| {
                    const sourceOuter = OuterRow{ .table = source, .alias = null, .values = sourceRow.values, .prev = null };
                    if (!try self.matchesContext(tbl, row.values, conds, parameters, &sourceOuter)) continue;
                }
                const candidate = try self.allocator.alloc(Value, row.values.len);
                defer {
                    for (value.columns, value.values) |name, expression| {
                        if (expression != .binary and expression != .unary) continue;
                        const index = columnIndex(tbl, name) catch continue;
                        self.freeConcatText(candidate[index]);
                    }
                    for (tbl.columns, 0..) |column, index| {
                        if (column.generatedExpr != null and !sameValue(candidate[index], row.values[index])) {
                            exprEvaluator.freeValue(self.allocator, candidate[index]);
                        }
                    }
                    self.allocator.free(candidate);
                }
                @memcpy(candidate, row.values);
                for (value.columns, value.values) |name, expression| {
                    const index = try columnIndex(tbl, name);
                    var newValue = if (expression == .identifier and std.mem.indexOfScalar(u8, expression.identifier, '.') != null) blk: {
                        const dot = std.mem.indexOfScalar(u8, expression.identifier, '.').?;
                        const qualifier = expression.identifier[0..dot];
                        const columnName = expression.identifier[dot + 1 ..];
                        if (std.ascii.eqlIgnoreCase(qualifier, source.name)) break :blk sourceRow.values[try columnIndex(source, columnName)];
                        break :blk try self.resolve(expression, parameters);
                    } else try self.resolve(expression, parameters);
                    if (tbl.strict) newValue = try Schema.coerceStrict(tbl.columns[index].typeName, newValue);
                    candidate[index] = newValue;
                }
                try self.recomputeGeneratedColumns(tbl, candidate, false);
                try self.fireTriggers(store, tbl, .before, .update, candidate, row.values, value.columns);
                store.validateUpdate(tbl, rowIndex, candidate) catch |err| {
                    if (err != error.ConstraintViolation) return err;
                    if (value.conflict == .ignore) continue;
                    return err;
                };
                self.applyUpdateActions(store, tbl.name, row.values, candidate) catch |err| {
                    if (err != error.ConstraintViolation) return err;
                    if (value.conflict == .ignore) continue;
                    return err;
                };
                const oldSnapshot = try self.allocator.alloc(Value, row.values.len);
                defer {
                    for (oldSnapshot) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                    self.allocator.free(oldSnapshot);
                }
                for (row.values, 0..) |item, snapshotIndex| oldSnapshot[snapshotIndex] = try self.copyValue(item);
                for (value.columns, 0..) |name, updateIndex| {
                    const targetIndex = try columnIndex(tbl, name);
                    const newValue = candidate[targetIndex];
                    // Duplicate before freeing: newValue may borrow the storage
                    // being replaced (e.g. SET label = label).
                    const ownedCopy: Value = switch (newValue) {
                        .text => |text| .{ .text = try self.allocator.dupe(u8, text) },
                        .blob => |blob| .{ .blob = try self.allocator.dupe(u8, blob) },
                        else => newValue,
                    };
                    if (row.values[targetIndex] == .text) self.allocator.free(row.values[targetIndex].text);
                    if (row.values[targetIndex] == .blob) self.allocator.free(row.values[targetIndex].blob);
                    row.values[targetIndex] = ownedCopy;
                    _ = updateIndex;
                }
                try self.recomputeGeneratedColumns(tbl, row.values, true);
                try self.fireTriggers(store, tbl, .after, .update, candidate, oldSnapshot, value.columns);
                changes += 1;
                try affectedRows.append(self.allocator, row.values);
                break;
            }
        }
        if (value.returning.len > 0) return self.evaluateReturning(tbl, value.returning, affectedRows.items, parameters);
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
    }

    fn update(self: *Connection, value: anytype, parameters: []const Value) !Result {
        if (value.from != null) return self.updateFrom(value, parameters);
        if (self.cteActive(value.table)) return error.InvalidSql;
        const resolved = self.resolveTableName(value.table) orelse return error.UnknownTable;
        const store = self.storeFor(resolved.ref);
        const tbl = resolved.table;
        try validateReturningColumns(tbl, value.returning);
        for (value.columns) |name| {
            const index = try columnIndex(tbl, name);
            if (tbl.columns[index].generatedExpr != null) return error.ConstraintViolation;
        }
        var affectedRows = std.ArrayList([]const Value).empty;
        defer affectedRows.deinit(self.allocator);
        var changes: usize = 0;
        var cursor: usize = 0;
        outer: while (cursor < tbl.rows.items.len) {
            var rowIndex = cursor;
            cursor += 1;
            var row = &tbl.rows.items[rowIndex];
            if (!(try self.matches(tbl, row.values, value.condition, parameters))) continue :outer;
            const candidate = try self.allocator.alloc(Value, row.values.len);
            defer {
                for (value.columns, value.values) |name, expr| {
                    if (expr != .binary and expr != .unary) continue;
                    const index = columnIndex(tbl, name) catch continue;
                    self.freeConcatText(candidate[index]);
                }
                for (tbl.columns, 0..) |column, index| {
                    if (column.generatedExpr != null and !sameValue(candidate[index], row.values[index])) {
                        exprEvaluator.freeValue(self.allocator, candidate[index]);
                    }
                }
                self.allocator.free(candidate);
            }
            @memcpy(candidate, row.values);
            for (value.columns, value.values) |name, expr| {
                const index = try columnIndex(tbl, name);
                var newValue = try self.eval(tbl, row.values, expr, parameters);
                if (newValue == .null and tbl.columns[index].notNull) {
                    if (value.conflict == .ignore) continue :outer;
                    return error.ConstraintViolation;
                }
                if (tbl.strict) newValue = Schema.coerceStrict(tbl.columns[index].typeName, newValue) catch |err| {
                    if (err == error.ConstraintViolation and value.conflict == .ignore) continue :outer;
                    return err;
                };
                candidate[index] = newValue;
            }
            try self.recomputeGeneratedColumns(tbl, candidate, false);
            try self.fireTriggers(store, tbl, .before, .update, candidate, row.values, value.columns);
            store.validateUpdate(tbl, rowIndex, candidate) catch |err| {
                if (err != error.ConstraintViolation) return err;
                switch (value.conflict) {
                    .ignore => continue :outer,
                    .replace => {
                        while (try self.conflictRow(store, tbl, candidate, rowIndex)) |bad| {
                            try self.deleteRowAt(store, tbl, bad);
                            if (bad < rowIndex) rowIndex -= 1;
                            if (rowIndex >= tbl.rows.items.len) continue :outer;
                            row = &tbl.rows.items[rowIndex];
                            if (!(try self.matches(tbl, row.values, value.condition, parameters))) continue :outer;
                        }
                        try store.validateUpdate(tbl, rowIndex, candidate);
                    },
                    else => return err,
                }
            };
            self.applyUpdateActions(store, tbl.name, row.values, candidate) catch |err| {
                if (err != error.ConstraintViolation) return err;
                switch (value.conflict) {
                    .ignore => continue :outer,
                    else => return err,
                }
            };
            const oldSnapshot = try self.allocator.alloc(Value, row.values.len);
            defer {
                for (oldSnapshot) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                self.allocator.free(oldSnapshot);
            }
            for (row.values, 0..) |item, snapshotIndex| oldSnapshot[snapshotIndex] = try self.copyValue(item);
            for (value.columns, value.values) |name, expr| {
                const index = try columnIndex(tbl, name);
                var newValue = try self.eval(tbl, row.values, expr, parameters);
                // Tracks eval-produced ownership: complex expressions yield
                // fresh text/blobs that must be freed; plain references borrow.
                var ownedResult = expr == .binary or expr == .unary or expr == .function or expr == .caseExpr;
                if (newValue == .null and candidate[index] != .null) {
                    newValue = candidate[index];
                    ownedResult = false;
                }
                if (tbl.strict) newValue = try Schema.coerceStrict(tbl.columns[index].typeName, newValue);
                // Duplicate before freeing: newValue may borrow the storage
                // being replaced (e.g. SET label = label).
                const ownedCopy: Value = switch (newValue) {
                    .text => |v| .{ .text = try self.allocator.dupe(u8, v) },
                    .blob => |v| .{ .blob = try self.allocator.dupe(u8, v) },
                    else => newValue,
                };
                if (row.values[index] == .text) self.allocator.free(row.values[index].text);
                if (row.values[index] == .blob) self.allocator.free(row.values[index].blob);
                row.values[index] = ownedCopy;
                // Free eval-owned text only when it cannot alias live storage
                // (CASE branches may pass a borrowed column through).
                if (ownedResult and !valueBorrowsFrom(newValue, &.{ row.values, candidate })) self.freeConcatText(newValue);
            }
            try self.recomputeGeneratedColumns(tbl, row.values, true);
            changes += 1;
            try affectedRows.append(self.allocator, row.values);
            try self.fireTriggers(store, tbl, .after, .update, candidate, oldSnapshot, value.columns);
        }
        if (value.returning.len > 0) return self.evaluateReturning(tbl, value.returning, affectedRows.items, parameters);
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

    fn applyCompositeUpdateActions(self: *Connection, store: *Schema, parentName: []const u8, oldValues: []const Value, newValues: []const Value) anyerror!void {
        const parent = store.findConst(parentName) orelse return error.ConstraintViolation;
        for (store.tables.items) |childTable| {
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
                        .restrict, .noAction => return error.ConstraintViolation,
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
                        .setDefault => {
                            for (constraint.columns) |childColumn| {
                                const childIndex = try columnIndex(childTable, childColumn);
                                const def = childTable.columns[childIndex].defaultValue orelse .null;
                                if (childTable.columns[childIndex].notNull and def == .null) return error.ConstraintViolation;
                            }
                            for (constraint.columns) |childColumn| {
                                const childIndex = try columnIndex(childTable, childColumn);
                                const def = childTable.columns[childIndex].defaultValue orelse .null;
                                const old = childTable.rows.items[childRowIndex].values[childIndex];
                                if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                                childTable.rows.items[childRowIndex].values[childIndex] = .null;
                                childTable.rows.items[childRowIndex].values[childIndex] = try self.copyValue(def);
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
                            try self.applyUpdateActions(store, childTable.name, row.values, candidate);
                            for (row.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(row.values);
                            row.values = candidate;
                        },
                    }
                }
            }
        }
    }

    fn applyCompositeDeleteActions(self: *Connection, store: *Schema, parentName: []const u8, parentValues: []const Value) anyerror!void {
        const parent = store.findConst(parentName) orelse return error.ConstraintViolation;
        for (store.tables.items) |childTable| {
            var childRowIndex = childTable.rows.items.len;
            while (childRowIndex > 0) {
                childRowIndex -= 1;
                for (childTable.constraints) |constraint| {
                    if (constraint.kind != .foreignKey or !std.ascii.eqlIgnoreCase(constraint.foreignTable.?, parentName)) continue;
                    if (!try self.compositeMatches(childTable, childTable.rows.items[childRowIndex].values, parent, parentValues, constraint)) continue;
                    switch (constraint.onDelete) {
                        .restrict, .noAction => return error.ConstraintViolation,
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
                        .setDefault => {
                            for (constraint.columns) |childColumn| {
                                const childIndex = try columnIndex(childTable, childColumn);
                                const def = childTable.columns[childIndex].defaultValue orelse .null;
                                if (childTable.columns[childIndex].notNull and def == .null) return error.ConstraintViolation;
                            }
                            for (constraint.columns) |childColumn| {
                                const childIndex = try columnIndex(childTable, childColumn);
                                const def = childTable.columns[childIndex].defaultValue orelse .null;
                                const old = childTable.rows.items[childRowIndex].values[childIndex];
                                if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                                childTable.rows.items[childRowIndex].values[childIndex] = .null;
                                childTable.rows.items[childRowIndex].values[childIndex] = try self.copyValue(def);
                            }
                        },
                        .cascade => {
                            try self.applyDeleteActions(store, childTable.name, childTable.rows.items[childRowIndex].values);
                            const removed = childTable.rows.orderedRemove(childRowIndex);
                            for (removed.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(removed.values);
                        },
                    }
                }
            }
        }
    }

    fn applyUpdateActions(self: *Connection, store: *Schema, parentName: []const u8, oldValues: []const Value, newValues: []const Value) anyerror!void {
        if (!store.foreignKeysEnabled) return;
        try self.applyCompositeUpdateActions(store, parentName, oldValues, newValues);
        const parent = store.findConst(parentName) orelse return error.ConstraintViolation;
        var childTableIndex: usize = 0;
        while (childTableIndex < store.tables.items.len) : (childTableIndex += 1) {
            const childTable = store.tables.items[childTableIndex];
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
                        .restrict, .noAction => return error.ConstraintViolation,
                        .setNull => {
                            if (childColumn.notNull) return error.ConstraintViolation;
                            const old = childRow.values[childColumnIndex];
                            if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                            childRow.values[childColumnIndex] = .null;
                        },
                        .setDefault => {
                            const def = childColumn.defaultValue orelse .null;
                            if (childColumn.notNull and def == .null) return error.ConstraintViolation;
                            const old = childRow.values[childColumnIndex];
                            if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                            childRow.values[childColumnIndex] = .null;
                            childRow.values[childColumnIndex] = try self.copyValue(def);
                        },
                        .cascade => {
                            const candidate = try self.allocator.alloc(Value, childRow.values.len);
                            errdefer self.allocator.free(candidate);
                            for (childRow.values, 0..) |item, index| candidate[index] = try self.copyValue(item);
                            const replacement = try self.copyValue(newValues[parentColumnIndex]);
                            if (candidate[childColumnIndex] == .text) self.allocator.free(candidate[childColumnIndex].text) else if (candidate[childColumnIndex] == .blob) self.allocator.free(candidate[childColumnIndex].blob);
                            candidate[childColumnIndex] = replacement;
                            try self.applyUpdateActions(store, childTable.name, childRow.values, candidate);
                            for (childRow.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                            self.allocator.free(childRow.values);
                            childRow.values = candidate;
                        },
                    }
                }
            }
        }
    }

    fn applyDeleteActions(self: *Connection, store: *Schema, parentName: []const u8, parentValues: []const Value) anyerror!void {
        if (!store.foreignKeysEnabled) return;
        try self.applyCompositeDeleteActions(store, parentName, parentValues);
        var childTableIndex: usize = 0;
        while (childTableIndex < store.tables.items.len) : (childTableIndex += 1) {
            var childRowIndex = store.tables.items[childTableIndex].rows.items.len;
            while (childRowIndex > 0) {
                childRowIndex -= 1;
                var action: ?ast.ReferentialAction = null;
                var childColumnIndex: usize = 0;
                var parentColumnIndex: usize = 0;
                const childTable = store.tables.items[childTableIndex];
                for (childTable.columns, 0..) |column, columnIdx| if (column.foreignTable) |foreignTable| {
                    if (std.ascii.eqlIgnoreCase(foreignTable, parentName)) {
                        const parentTable = store.findConst(parentName) orelse return error.ConstraintViolation;
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
                    .restrict, .noAction => return error.ConstraintViolation,
                    .setNull => {
                        if (childTable.columns[childColumnIndex].notNull) return error.ConstraintViolation;
                        const old = childTable.rows.items[childRowIndex].values[childColumnIndex];
                        if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                        childTable.rows.items[childRowIndex].values[childColumnIndex] = .null;
                    },
                    .setDefault => {
                        const def = childTable.columns[childColumnIndex].defaultValue orelse .null;
                        if (childTable.columns[childColumnIndex].notNull and def == .null) return error.ConstraintViolation;
                        const old = childTable.rows.items[childRowIndex].values[childColumnIndex];
                        if (old == .text) self.allocator.free(old.text) else if (old == .blob) self.allocator.free(old.blob);
                        childTable.rows.items[childRowIndex].values[childColumnIndex] = .null;
                        childTable.rows.items[childRowIndex].values[childColumnIndex] = try self.copyValue(def);
                    },
                    .cascade => {
                        try self.applyDeleteActions(store, childTable.name, childTable.rows.items[childRowIndex].values);
                        const removed = childTable.rows.orderedRemove(childRowIndex);
                        for (removed.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                        self.allocator.free(removed.values);
                    },
                }
            }
        }
    }

    fn delete(self: *Connection, value: anytype, parameters: []const Value) !Result {
        if (self.cteActive(value.table)) return error.InvalidSql;
        const resolved = self.resolveTableName(value.table) orelse return error.UnknownTable;
        const store = self.storeFor(resolved.ref);
        const tbl = resolved.table;
        try validateReturningColumns(tbl, value.returning);
        var affectedRows = std.ArrayList([]Value).empty;
        defer {
            for (affectedRows.items) |r| {
                for (r) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                self.allocator.free(r);
            }
            affectedRows.deinit(self.allocator);
        }
        var changes: usize = 0;
        var index: usize = 0;
        while (index < tbl.rows.items.len) {
            if (try self.matches(tbl, tbl.rows.items[index].values, value.condition, parameters)) {
                try self.fireTriggers(store, tbl, .before, .delete, null, tbl.rows.items[index].values, &.{});
                try self.applyDeleteActions(store, tbl.name, tbl.rows.items[index].values);
                const row = tbl.rows.orderedRemove(index);
                try self.fireTriggers(store, tbl, .after, .delete, null, row.values, &.{});
                if (value.returning.len > 0) {
                    const cloned = try self.allocator.alloc(Value, row.values.len);
                    for (row.values, 0..) |item, i| cloned[i] = try self.copyValue(item);
                    try affectedRows.append(self.allocator, cloned);
                }
                for (row.values) |item| if (item == .text) self.allocator.free(item.text) else if (item == .blob) self.allocator.free(item.blob);
                self.allocator.free(row.values);
                changes += 1;
            } else index += 1;
        }
        if (value.returning.len > 0) {
            const sliceOfSlices = try self.allocator.alloc([]const Value, affectedRows.items.len);
            defer self.allocator.free(sliceOfSlices);
            for (affectedRows.items, 0..) |r, i| sliceOfSlices[i] = r;
            return self.evaluateReturning(tbl, value.returning, sliceOfSlices, parameters);
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
    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expectEqualStrings("A", result.at(0)[0].text);
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
    try db.createIndex(Item, "index_items_id", .{Item.id}, false);
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
    try std.testing.expectEqualStrings("saved", result.at(0)[0].text);
}

test "prepared statements query rows with bound parameters" {
    const path = "sqlite_zig_prepared_query_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var setup = try db.exec("CREATE TABLE lookup (id INTEGER, label TEXT); INSERT INTO lookup VALUES (1, 'one'), (2, 'two');");
    setup.deinit();
    var statement = try db.prepare("SELECT label FROM lookup WHERE id = ?;");
    try statement.bind(1, 2);
    var rows = try statement.query();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("two", rows.at(0)[0].text);
    statement.reset();
    try statement.bind(1, 1);
    var again = try statement.query();
    defer again.deinit();
    try std.testing.expectEqualStrings("one", again.rows[0][0].text);
    statement.reset();
    var missing = try statement.query();
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.count());
    try std.testing.expectError(error.InvalidParameter, statement.bind(0, 1));
    statement.finalize();
    var rebound = try db.prepare("SELECT id FROM lookup WHERE label = ? AND id > ?;");
    defer rebound.finalize();
    try rebound.bind(1, "two");
    try rebound.bind(2, 1);
    var filtered = try rebound.query();
    defer filtered.deinit();
    try std.testing.expectEqual(@as(i64, 2), filtered.rows[0][0].integer);
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
    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expectEqual(@as(i64, 3), result.at(0)[0].integer);
    try std.testing.expectEqualStrings("integer", result.at(0)[1].text);
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
    try std.testing.expectEqual(@as(usize, 2), result.count());
    try std.testing.expectEqualStrings("beta", result.at(0)[0].text);
    try std.testing.expectEqualStrings("alpha", result.at(1)[0].text);
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
    try std.testing.expectError(error.TableExists, db.createTable(User, .{}));
    try std.testing.expectError(error.TableExists, db.createTable(User, .{ .overWrite = false }));
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "typed" });
    inserted.deinit();
    try db.createTable(User, .{ .overWrite = true });
    var wiped = try db.exec("SELECT count(*) FROM schema_dsl_users;");
    defer wiped.deinit();
    try std.testing.expectEqual(@as(i64, 0), wiped.rows[0][0].integer);
    var insertedAgain = try db.from(User).insert(.{ .id = 2, .name = "after-overwrite" });
    insertedAgain.deinit();
    try db.addColumn(User, "active", bool);
    try db.renameColumn(User, "active", "enabled");
    try db.dropColumn(User, "enabled");
    try db.truncate(User);
    try db.dropTable(User);
    try std.testing.expect(!db.tableExists(User));
}

test "createTable overWrite drops and recreates tables" {
    const V1 = @import("../dsl/table.zig").table("ow_items", struct { id: i64 });
    const V2 = @import("../dsl/table.zig").table("ow_items", struct { id: i64, label: []const u8 });
    const path = "sqlite_zig_overwrite_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(V1, .{});
    var first = try db.from(V1).insert(.{ .id = 1 });
    first.deinit();
    var index = try db.exec("CREATE INDEX ow_items_id_idx ON ow_items (id);");
    index.deinit();
    try std.testing.expect(db.store.findIndexConst("ow_items_id_idx") != null);
    try db.createTable(V2, .{ .overWrite = true });
    try std.testing.expect(db.store.findIndexConst("ow_items_id_idx") == null);
    var empty = try db.exec("SELECT count(*) FROM ow_items;");
    defer empty.deinit();
    try std.testing.expectEqual(@as(i64, 0), empty.rows[0][0].integer);
    var second = try db.from(V2).insert(.{ .id = 2, .label = "v2" });
    second.deinit();
    var relabeled = try db.exec("SELECT label FROM ow_items WHERE id = 2;");
    defer relabeled.deinit();
    try std.testing.expectEqualStrings("v2", relabeled.rows[0][0].text);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var persisted = try db.exec("SELECT label FROM ow_items WHERE id = 2;");
    defer persisted.deinit();
    try std.testing.expectEqualStrings("v2", persisted.at(0)[0].text);
    try std.testing.expectError(error.TableExists, db.createTable("ow_items", .{ .columns = &.{"id"} }));
    var dyn = try db.exec("CREATE TABLE ow_dyn (id INTEGER); INSERT INTO ow_dyn VALUES (1);");
    dyn.deinit();
    try db.createTable("ow_dyn", .{ .columns = &.{"id"}, .overWrite = true });
    var dynEmpty = try db.exec("SELECT count(*) FROM ow_dyn;");
    defer dynEmpty.deinit();
    try std.testing.expectEqual(@as(i64, 0), dynEmpty.rows[0][0].integer);
}

test "typed keys and foreign keys enforce relational constraints" {
    const Parent = @import("../dsl/table.zig").table("key_dsl_parent", struct { id: i64, email: ?[]const u8 });
    const Child = @import("../dsl/table.zig").table("key_dsl_child", struct { id: i64, parent_id: i64 });
    const path = "sqlite_zig_keys_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    try db.createTable(Parent, .{ .primaryKey = Parent.id, .unique = &.{Parent.email} });
    try db.createTable(Child, .{ .primaryKey = Child.id, .foreignKeys = &.{.{ .column = Child.parent_id, .references = Parent.id }} });
    var parent = try db.from(Parent).insert(.{ .id = 1, .email = "one@example.test" });
    parent.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Parent).insert(.{ .id = 1, .email = "two@example.test" }));
    try std.testing.expectError(error.ConstraintViolation, db.from(Child).insert(.{ .id = 1, .parent_id = 99 }));
    var child = try db.from(Child).insert(.{ .id = 1, .parent_id = 1 });
    child.deinit();
    var nullable = try db.exec("INSERT INTO key_dsl_parent (id, email) VALUES (2, NULL), (3, NULL);");
    nullable.deinit();
    var childUpdate = try db.from(Child).update(.{ .parent_id = 99 });
    try std.testing.expectError(error.ConstraintViolation, childUpdate.where(Child.id.eq(1)).execute());
}

test "raw SQL and typed DSL execute inner and left joins" {
    const User = @import("../dsl/table.zig").table("join_dsl_users", struct { id: i64, name: []const u8 });
    const Order = @import("../dsl/table.zig").table("join_dsl_orders", struct { id: i64, user_id: i64 });
    const path = "sqlite_zig_join_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    const t_db_join_dsl_orders = db.table("join_dsl_orders");
    const t_db_join_dsl_users = db.table("join_dsl_users");
    defer db.close();
    try db.createTable(User, .{ .primaryKey = User.id });
    try db.createTable(Order, .{ .primaryKey = Order.id });
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
    try std.testing.expectEqual(@as(usize, 1), raw.count());
    try std.testing.expectEqual(@as(i64, 10), raw.at(0)[2].integer);
    var rawDistinct = try db.exec("SELECT DISTINCT * FROM join_dsl_users JOIN join_dsl_orders ON join_dsl_users.id = join_dsl_orders.user_id;");
    defer rawDistinct.deinit();
    var dslDistinct = try db.from(User).innerJoin(Order, User.id.eq(Order.user_id)).selectAll().distinct().fetch();
    defer dslDistinct.deinit();
    try std.testing.expectEqual(rawDistinct.count(), dslDistinct.count());
    var typedSum = try db.from(User).select(.{User.id.sum()}).fetch();
    defer typedSum.deinit();
    try std.testing.expectEqual(@as(i64, 3), typedSum.rows[0][0].integer);
    var typedProjection = try db.from(User).select(.{ User.id, User.name }).fetch();
    defer typedProjection.deinit();
    try std.testing.expectEqual(@as(usize, 2), typedProjection.count());
    var left = try db.from(User).leftJoin(Order, User.id.eq(Order.user_id)).fetch();
    defer left.deinit();
    try std.testing.expectEqual(@as(usize, 2), left.count());
    var right = try t_db_join_dsl_users.rightJoin(t_db_join_dsl_orders, t_db_join_dsl_users.column("id").eq(t_db_join_dsl_orders.column("user_id"))).fetch();
    defer right.deinit();
    try std.testing.expectEqual(@as(usize, 2), right.count());
    var full = try t_db_join_dsl_users.fullJoin(t_db_join_dsl_orders, t_db_join_dsl_users.column("id").eq(t_db_join_dsl_orders.column("user_id"))).fetch();
    defer full.deinit();
    try std.testing.expectEqual(@as(usize, 3), full.count());
    var cross = try db.from(User).crossJoin(Order).fetch();
    defer cross.deinit();
    try std.testing.expectEqual(@as(usize, 4), cross.count());
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
    try std.testing.expectEqual(@as(usize, 3), result.count());
    var likeResult = try db.from(Item).where(Item.label.like("a%")).fetch();
    defer likeResult.deinit();
    try std.testing.expectEqual(@as(usize, 2), likeResult.count());
    var rawNotLike = try db.exec("SELECT id FROM predicate_dsl_items WHERE label NOT LIKE 'a%' ORDER BY id;");
    defer rawNotLike.deinit();
    try std.testing.expectEqual(@as(usize, 1), rawNotLike.count());
    try std.testing.expectEqual(@as(i64, 2), rawNotLike.rows[0][0].integer);
    var notLikeResult = try db.from(Item).where(Item.label.notLike("a%")).fetch();
    defer notLikeResult.deinit();
    try std.testing.expectEqual(@as(usize, 1), notLikeResult.count());
    var nullResult = try db.from(Item).where(Item.label.isNull()).fetch();
    defer nullResult.deinit();
    try std.testing.expectEqual(@as(usize, 1), nullResult.count());
    var distinctResult = try db.from(Item).select(.{Item.label}).distinct().fetch();
    defer distinctResult.deinit();
    try std.testing.expectEqual(@as(usize, 3), distinctResult.count());
    var rawInList = try db.exec("SELECT id FROM predicate_dsl_items WHERE id IN (1, 3, 4) ORDER BY id;");
    defer rawInList.deinit();
    try std.testing.expectEqual(@as(usize, 3), rawInList.count());
    var typedInList = try db.from(Item).whereInValues(Item.id, .{ 1, 3, 4 }).fetch();
    defer typedInList.deinit();
    try std.testing.expectEqual(@as(usize, 3), typedInList.count());
    var rawNotInList = try db.exec("SELECT id FROM predicate_dsl_items WHERE id NOT IN (1, 3, 4) ORDER BY id;");
    defer rawNotInList.deinit();
    try std.testing.expectEqual(@as(usize, 1), rawNotInList.count());
    var typedNotInList = try db.from(Item).whereNotInValues(Item.id, .{ 1, 3, 4 }).fetch();
    defer typedNotInList.deinit();
    try std.testing.expectEqual(@as(usize, 1), typedNotInList.count());
    var rawIs = try db.exec("SELECT id FROM predicate_dsl_items WHERE label IS 'alpha' ORDER BY id;");
    defer rawIs.deinit();
    try std.testing.expectEqual(@as(usize, 2), rawIs.count());
    var rawIsNotNull = try db.exec("SELECT id FROM predicate_dsl_items WHERE label IS NOT NULL ORDER BY id;");
    defer rawIsNotNull.deinit();
    try std.testing.expectEqual(@as(usize, 3), rawIsNotNull.count());
    var typedIs = try db.from(Item).where(Item.label.is("alpha")).fetch();
    defer typedIs.deinit();
    try std.testing.expectEqual(@as(usize, 2), typedIs.count());
    var typedBetween = try db.from(Item).where(Item.id.between(1, 2)).fetch();
    defer typedBetween.deinit();
    try std.testing.expectEqual(@as(usize, 2), typedBetween.count());
    var rawNotBetween = try db.exec("SELECT id FROM predicate_dsl_items WHERE id NOT BETWEEN 2 AND 3 ORDER BY id;");
    defer rawNotBetween.deinit();
    try std.testing.expectEqual(@as(usize, 2), rawNotBetween.count());
    var typedNotBetween = try db.from(Item).where(Item.id.notBetween(2, 3)).fetch();
    defer typedNotBetween.deinit();
    try std.testing.expectEqual(rawNotBetween.count(), typedNotBetween.count());
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqual(@as(i64, 2), rows.at(0)[0].integer);
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqual(@as(i64, 2), rows.at(0)[0].integer);
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[0].integer);
    try std.testing.expectEqualStrings("wal", rows.at(0)[1].text);
    var checkpoint = try reopened.exec("PRAGMA journal_mode=DELETE;");
    checkpoint.deinit();
    reopened.close();
}

test "pragma foreign_key_check reports violations with rowids" {
    const path = "sqlite_zig_fk_check_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var setup = try db.exec("CREATE TABLE fk_parent (id INTEGER PRIMARY KEY, label TEXT); CREATE TABLE fk_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES fk_parent(id), tag TEXT, other_id INTEGER REFERENCES fk_other(id)); CREATE TABLE fk_cparent (a INTEGER, b INTEGER, PRIMARY KEY (a, b)); CREATE TABLE fk_cchild (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, solo INTEGER REFERENCES fk_parent(id), FOREIGN KEY (a, b) REFERENCES fk_cparent(a, b)); CREATE TABLE fk_other (id INTEGER PRIMARY KEY, label TEXT); CREATE TABLE fk_wrparent (k INTEGER PRIMARY KEY, v TEXT); CREATE TABLE fk_wrchild (k INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES fk_wrparent(k)) WITHOUT ROWID; INSERT INTO fk_parent VALUES (1, 'one'), (2, 'two'); INSERT INTO fk_other VALUES (7, 'seven'); INSERT INTO fk_cparent VALUES (1, 1), (2, 2); INSERT INTO fk_wrparent VALUES (1, 'p'); INSERT INTO fk_child VALUES (10, 1, 'ok', 7), (11, NULL, 'null-skipped', 7), (12, 2, 'ok2', 7); INSERT INTO fk_cchild VALUES (20, 1, 1, 1); INSERT INTO fk_wrchild VALUES (5, 1);");
    setup.deinit();
    var clean = try db.exec("PRAGMA foreign_key_check;");
    defer clean.deinit();
    try std.testing.expectEqualStrings("table", clean.columns[0]);
    try std.testing.expectEqualStrings("rowid", clean.columns[1]);
    try std.testing.expectEqualStrings("fktable", clean.columns[2]);
    try std.testing.expectEqualStrings("fkid", clean.columns[3]);
    try std.testing.expectEqual(@as(usize, 0), clean.count());
    var off = try db.exec("PRAGMA foreign_keys = OFF;");
    off.deinit();
    var orphans = try db.exec("INSERT INTO fk_child VALUES (13, 99, 'orphan', 7), (14, 1, 'x', 8); INSERT INTO fk_cchild VALUES (21, 1, 99, 1), (22, NULL, 1, 1), (23, 2, 2, 99); INSERT INTO fk_wrchild VALUES (6, 99);");
    orphans.deinit();
    var on = try db.exec("PRAGMA foreign_keys = ON;");
    on.deinit();
    var check = try db.exec("PRAGMA foreign_key_check;");
    defer check.deinit();
    try std.testing.expectEqual(@as(usize, 5), check.count());
    try std.testing.expectEqualStrings("fk_child", check.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 4), check.rows[0][1].integer);
    try std.testing.expectEqualStrings("fk_parent", check.rows[0][2].text);
    try std.testing.expectEqual(@as(i64, 0), check.rows[0][3].integer);
    try std.testing.expectEqualStrings("fk_child", check.rows[1][0].text);
    try std.testing.expectEqual(@as(i64, 5), check.rows[1][1].integer);
    try std.testing.expectEqualStrings("fk_other", check.rows[1][2].text);
    try std.testing.expectEqual(@as(i64, 1), check.rows[1][3].integer);
    try std.testing.expectEqualStrings("fk_cchild", check.rows[2][0].text);
    try std.testing.expectEqual(@as(i64, 2), check.rows[2][1].integer);
    try std.testing.expectEqualStrings("fk_cparent", check.rows[2][2].text);
    try std.testing.expectEqual(@as(i64, 1), check.rows[2][3].integer);
    try std.testing.expectEqualStrings("fk_cchild", check.rows[3][0].text);
    try std.testing.expectEqual(@as(i64, 4), check.rows[3][1].integer);
    try std.testing.expectEqualStrings("fk_parent", check.rows[3][2].text);
    try std.testing.expectEqual(@as(i64, 0), check.rows[3][3].integer);
    try std.testing.expectEqualStrings("fk_wrchild", check.rows[4][0].text);
    try std.testing.expect(check.rows[4][1] == .null);
    try std.testing.expectEqualStrings("fk_wrparent", check.rows[4][2].text);
    try std.testing.expectEqual(@as(i64, 0), check.rows[4][3].integer);
    var scoped = try db.exec("PRAGMA foreign_key_check(fk_cchild);");
    defer scoped.deinit();
    try std.testing.expectEqual(@as(usize, 2), scoped.count());
    var cleanScoped = try db.exec("PRAGMA foreign_key_check(fk_parent);");
    defer cleanScoped.deinit();
    try std.testing.expectEqual(@as(usize, 0), cleanScoped.count());
    try std.testing.expectError(error.UnknownTable, db.exec("PRAGMA foreign_key_check(nope);"));
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA foreign_key_check = 1;"));
    var intactChild = try db.exec("SELECT count(*) FROM fk_child;");
    defer intactChild.deinit();
    try std.testing.expectEqual(@as(i64, 5), intactChild.rows[0][0].integer);
    var intactComposite = try db.exec("SELECT count(*) FROM fk_cchild;");
    defer intactComposite.deinit();
    try std.testing.expectEqual(@as(i64, 4), intactComposite.rows[0][0].integer);
}

test "pragma integrity_check validates file and store" {
    const path = "sqlite_zig_integrity_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var setup = try db.exec("CREATE TABLE ic_parent (id INTEGER PRIMARY KEY, score REAL, payload BLOB, note TEXT); CREATE TABLE ic_child (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES ic_parent(id), tag TEXT UNIQUE); CREATE INDEX ic_child_tag_idx ON ic_child (tag); INSERT INTO ic_parent VALUES (1, 1.5, X'0102', 'zzqj-marker'), (2, NULL, NULL, 'plain'); INSERT INTO ic_child VALUES (10, 1, 't10'), (11, 2, 't11');");
    setup.deinit();
    var ok = try db.exec("PRAGMA integrity_check;");
    defer ok.deinit();
    try std.testing.expectEqualStrings("integrity_check", ok.columns[0]);
    try std.testing.expectEqual(@as(usize, 1), ok.count());
    try std.testing.expectEqualStrings("ok", ok.rows[0][0].text);
    var scoped = try db.exec("PRAGMA integrity_check(ic_child);");
    defer scoped.deinit();
    try std.testing.expectEqual(@as(usize, 1), scoped.count());
    try std.testing.expectEqualStrings("ok", scoped.rows[0][0].text);
    var capped = try db.exec("PRAGMA integrity_check(10);");
    defer capped.deinit();
    try std.testing.expectEqualStrings("ok", capped.rows[0][0].text);
    var zeroCap = try db.exec("PRAGMA integrity_check(0);");
    defer zeroCap.deinit();
    try std.testing.expectEqualStrings("ok", zeroCap.rows[0][0].text);
    try std.testing.expectError(error.UnknownTable, db.exec("PRAGMA integrity_check(nope);"));
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA integrity_check = 1;"));
    {
        var raw = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
        defer raw.close(std.testing.io);
        const stat = try raw.stat(std.testing.io);
        const bytes = try std.testing.allocator.alloc(u8, @intCast(stat.size));
        defer std.testing.allocator.free(bytes);
        const n = try raw.readPositionalAll(std.testing.io, bytes, 0);
        try std.testing.expectEqual(bytes.len, n);
        const at = std.mem.indexOf(u8, bytes, "zzqj-marker") orelse return error.TestUnexpectedResult;
        try raw.writePositionalAll(std.testing.io, "y", @intCast(at));
    }
    var drifted = try db.exec("PRAGMA integrity_check;");
    defer drifted.deinit();
    try std.testing.expectEqual(@as(usize, 1), drifted.count());
    try std.testing.expect(!std.mem.eql(u8, drifted.rows[0][0].text, "ok"));
    {
        var raw = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
        defer raw.close(std.testing.io);
        try raw.writePositionalAll(std.testing.io, "XX", 0);
    }
    var broken = try db.exec("PRAGMA integrity_check;");
    defer broken.deinit();
    try std.testing.expectEqual(@as(usize, 2), broken.count());
    var cappedBroken = try db.exec("PRAGMA integrity_check(1);");
    defer cappedBroken.deinit();
    try std.testing.expectEqual(@as(usize, 1), cappedBroken.count());
}

test "pragma cache_size and synchronous round-trip with validation" {
    const path = "sqlite_zig_settings_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var cacheDefault = try db.exec("PRAGMA cache_size;");
    defer cacheDefault.deinit();
    try std.testing.expectEqualStrings("cache_size", cacheDefault.columns[0]);
    try std.testing.expectEqual(@as(i64, -2000), cacheDefault.rows[0][0].integer);
    var syncDefault = try db.exec("PRAGMA synchronous;");
    defer syncDefault.deinit();
    try std.testing.expectEqualStrings("synchronous", syncDefault.columns[0]);
    try std.testing.expectEqual(@as(i64, 2), syncDefault.rows[0][0].integer);
    var setCache = try db.exec("PRAGMA cache_size = 500;");
    defer setCache.deinit();
    try std.testing.expectEqual(@as(i64, 500), setCache.rows[0][0].integer);
    var setNegative = try db.exec("PRAGMA cache_size = -100;");
    defer setNegative.deinit();
    try std.testing.expectEqual(@as(i64, -100), setNegative.rows[0][0].integer);
    var setZero = try db.exec("PRAGMA cache_size = 0;");
    defer setZero.deinit();
    try std.testing.expectEqual(@as(i64, 0), setZero.rows[0][0].integer);
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA cache_size = 'abc';"));
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA cache_size(5);"));
    var stillZero = try db.exec("PRAGMA cache_size;");
    defer stillZero.deinit();
    try std.testing.expectEqual(@as(i64, 0), stillZero.rows[0][0].integer);
    var setNormal = try db.exec("PRAGMA synchronous = NORMAL;");
    defer setNormal.deinit();
    try std.testing.expectEqual(@as(i64, 1), setNormal.rows[0][0].integer);
    var setOff = try db.exec("PRAGMA synchronous = off;");
    defer setOff.deinit();
    try std.testing.expectEqual(@as(i64, 0), setOff.rows[0][0].integer);
    var setExtra = try db.exec("PRAGMA synchronous = EXTRA;");
    defer setExtra.deinit();
    try std.testing.expectEqual(@as(i64, 3), setExtra.rows[0][0].integer);
    var setFull = try db.exec("PRAGMA synchronous = FULL;");
    defer setFull.deinit();
    try std.testing.expectEqual(@as(i64, 2), setFull.rows[0][0].integer);
    var setNumeric = try db.exec("PRAGMA synchronous = 1;");
    defer setNumeric.deinit();
    try std.testing.expectEqual(@as(i64, 1), setNumeric.rows[0][0].integer);
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA synchronous = 5;"));
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA synchronous = bogus;"));
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA synchronous(1);"));
    var stillOne = try db.exec("PRAGMA synchronous;");
    defer stillOne.deinit();
    try std.testing.expectEqual(@as(i64, 1), stillOne.rows[0][0].integer);
    var setup = try db.exec("CREATE TABLE sync_items (id INTEGER, label TEXT); INSERT INTO sync_items VALUES (1, 'durable');");
    setup.deinit();
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var persisted = try db.exec("SELECT label FROM sync_items;");
    defer persisted.deinit();
    try std.testing.expectEqualStrings("durable", persisted.at(0)[0].text);
    var resetCache = try db.exec("PRAGMA cache_size;");
    defer resetCache.deinit();
    try std.testing.expectEqual(@as(i64, -2000), resetCache.rows[0][0].integer);
    var resetSync = try db.exec("PRAGMA synchronous;");
    defer resetSync.deinit();
    try std.testing.expectEqual(@as(i64, 2), resetSync.rows[0][0].integer);
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
    try std.testing.expectEqual(@as(usize, 2), audit.count());
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
    try std.testing.expectEqual(@as(usize, 1), result.count());
    try std.testing.expectEqualStrings("combined", result.at(0)[0].text);
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expect(rows.at(0)[0] == .null);
    try std.testing.expect(rows.at(0)[1] == .null);
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
    try std.testing.expectEqual(@as(i64, 42), result.at(0)[0].integer);
    db.close();
    var reopened = try Connection.open(std.testing.allocator, path);
    defer reopened.close();
    var persisted = try reopened.exec("PRAGMA user_version;");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(i64, 42), persisted.at(0)[0].integer);
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
    try std.testing.expectEqual(@as(i64, 305419896), persisted.at(0)[0].integer);
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
    try std.testing.expectEqual(@as(usize, 2), grouped.count());
    try std.testing.expectEqualStrings("category", grouped.columns[0]);
    try std.testing.expectEqual(@as(i64, 2), grouped.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 30), grouped.rows[0][2].integer);
    try std.testing.expectEqual(@as(f64, 15), grouped.rows[0][3].real);
    try std.testing.expectEqual(@as(i64, 1), grouped.rows[1][1].integer);
    const Sale = @import("../dsl/table.zig").table("grouped_sales", struct { category: []const u8, amount: i64 });
    var typed = try db.from(Sale).select(.{Sale.amount.sum()}).groupBy(Sale.category).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.count());
    try std.testing.expectEqual(@as(i64, 30), typed.at(0)[0].integer);
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("a", rows.at(0)[0].text);
    try std.testing.expectEqual(@as(i64, 30), rows.at(0)[1].integer);
    const Sale = @import("../dsl/table.zig").table("having_sales", struct { category: []const u8, amount: i64 });
    var typed = try db.from(Sale).select(.{Sale.amount.sum()}).groupBy(Sale.category).having(@import("../dsl/expr.zig").countStar().gt(1)).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.count());
    try std.testing.expectEqual(@as(i64, 30), typed.at(0)[0].integer);
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqual(@as(i64, 2), rows.at(0)[0].integer);
    try std.testing.expectEqualStrings("two", rows.at(0)[1].text);
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
    try std.testing.expectEqual(@as(usize, 2), rows.count());
    try std.testing.expectEqualStrings("original", rows.at(0)[1].text);
    try std.testing.expectEqualStrings("accepted", rows.at(1)[1].text);
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
    try std.testing.expectEqual(@as(usize, 2), rows.count());
    try std.testing.expectEqualStrings("original", rows.at(0)[1].text);
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
    try std.testing.expectEqualStrings("updated", rows.at(0)[0].text);
    try std.testing.expectEqual(@as(i64, 100), rows.at(0)[1].integer);
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
    try std.testing.expectEqualStrings("original", rows.at(0)[0].text);
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("replacement", rows.at(0)[0].text);
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqual(@as(i64, 2), rows.at(0)[0].integer);
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
    try std.testing.expectEqual(@as(i64, 99), rows.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 20), rows.at(1)[1].integer);
}

test "update from applies trailing filters and cartesian sources" {
    const path = "sqlite_zig_update_from_filter_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var setup = try db.exec("CREATE TABLE uf_balances (id INTEGER PRIMARY KEY, amount INTEGER, flag INTEGER); CREATE TABLE uf_adjustments (id INTEGER, bal_id INTEGER, bonus INTEGER); INSERT INTO uf_balances VALUES (1, 10, 0), (2, 20, 0); INSERT INTO uf_adjustments VALUES (1, 1, 5), (2, 2, 7);");
    setup.deinit();
    var filtered = try db.exec("UPDATE uf_balances SET flag = 1 FROM uf_adjustments WHERE uf_balances.id = uf_adjustments.bal_id AND uf_adjustments.bonus > 6;");
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.changes);
    var rows = try db.exec("SELECT id, flag FROM uf_balances ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 0), rows.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 1), rows.at(1)[1].integer);
    var cartesian = try db.exec("UPDATE uf_balances SET flag = 9 FROM uf_adjustments WHERE uf_balances.id = 1;");
    defer cartesian.deinit();
    try std.testing.expectEqual(@as(usize, 1), cartesian.changes);
    var again = try db.exec("SELECT flag FROM uf_balances WHERE id = 1;");
    defer again.deinit();
    try std.testing.expectEqual(@as(i64, 9), again.rows[0][0].integer);
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
    try std.testing.expectEqual(@as(usize, 2), raw.count());
    var typed = try db.from(User).whereNotInQuery(User.id, Blocked, Blocked.user_id).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.count());
    try std.testing.expectEqual(@as(i64, 1), typed.at(0).id);
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
    try std.testing.expectEqual(@as(usize, 2), present.count());
    var correlated = try db.exec("SELECT id FROM exists_users WHERE EXISTS (SELECT id FROM exists_marker WHERE exists_marker.id = exists_users.id) ORDER BY id;");
    defer correlated.deinit();
    try std.testing.expectEqual(@as(usize, 1), correlated.count());
    try std.testing.expectEqual(@as(i64, 1), correlated.rows[0][0].integer);
    const User = @import("../dsl/table.zig").table("exists_users", struct { id: i64 });
    const Marker = @import("../dsl/table.zig").table("exists_marker", struct { id: i64 });
    var typed = try db.from(User).whereExists(Marker, Marker.id.eq(User.id)).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.count());
    result = try db.exec("DELETE FROM exists_marker;");
    result.deinit();
    var absent = try db.exec("SELECT id FROM exists_users WHERE NOT EXISTS (SELECT id FROM exists_marker) ORDER BY id;");
    defer absent.deinit();
    try std.testing.expectEqual(@as(usize, 2), absent.count());
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("one", rows.at(0)[1].text);
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
    try std.testing.expectEqual(@as(usize, 2), rows.count());
    try std.testing.expectEqualStrings("untitled", rows.at(0)[1].text);
    try std.testing.expectEqual(@as(i64, 1), rows.at(1)[2].integer);
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
    try std.testing.expectEqual(@as(i64, 15), rows.at(0)[0].integer);
    try std.testing.expectEqualStrings("new", rows.at(0)[1].text);
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
    try std.testing.expectEqual(@as(usize, 2), raw.count());
    var typed = try db.from(User).where(User.name.glob("A*")).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.count());
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
    try std.testing.expectEqualStrings("Alpha", raw.at(0)[0].text);
    try std.testing.expectEqualStrings("Alpha  ", raw.at(0)[1].text);
    try std.testing.expectEqualStrings("  Alpha", raw.at(0)[2].text);
    var typed = try db.from(Item).select(.{Item.label.trim()}).fetch();
    defer typed.deinit();
    try std.testing.expectEqualStrings("Alpha", typed.at(0)[0].text);
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
    try std.testing.expectEqualStrings("Alice in Zig", rows.at(0)[0].text);
    try std.testing.expectEqualStrings("Alice", rows.at(0)[1].text);
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
    var replaced = try db.from(Item).select(.{Item.label.replace("SQLite", "Zig")}).fetch();
    defer replaced.deinit();
    try std.testing.expectEqualStrings("Alice in Zig", replaced.rows[0][0].text);
    var shortened = try db.from(Item).select(.{Item.label.substr(1, 5)}).fetch();
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
    var projected = try db.from(Item).select(.{ Item.label, Item.id }).fetch();
    defer projected.deinit();
    try std.testing.expectEqual(@as(usize, 1), projected.count());
    try std.testing.expectEqualStrings("mapped", projected.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 7), projected.rows[0][1].integer);
    var typed = try db.from(Item).selectAll().fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(i64, 7), typed.at(0).id);
    try std.testing.expectEqualStrings("mapped", typed.at(0).label);
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
    try std.testing.expectEqualStrings("fallback", rows.at(0)[0].text);
    try std.testing.expectEqualStrings("fallback", rows.at(0)[1].text);
    try std.testing.expectEqual(@as(i64, 5), rows.at(0)[2].integer);
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
    try std.testing.expectEqual(@as(usize, 1), raw.count());
    var typed = try db.from(Item).where(Item.name.notGlob("A*")).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.count());
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
    try std.testing.expectEqual(@as(usize, 2), typed.count());
    try std.testing.expect(typed.at(0).label == null);
    try std.testing.expectEqualStrings("present", typed.at(1).label.?);
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
    try std.testing.expect(typed.at(0).enabled);
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
    try std.testing.expectEqual(@as(usize, 1), likeRows.count());
    var globRows = try db.exec("SELECT name FROM case_items WHERE name GLOB 'a*';");
    defer globRows.deinit();
    try std.testing.expectEqual(@as(usize, 0), globRows.count());
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("Alice", rows.at(0)[0].text);
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("  Alice  ", rows.at(0)[0].text);
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
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("SQLite", rows.at(0)[0].text);
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
    var lower = try db.from(Item).where(Item.name.lower().eq("alice")).fetch();
    defer lower.deinit();
    try std.testing.expectEqual(@as(usize, 1), lower.count());
    var trimmed = try db.from(Item).where(Item.name.trim().eq("Alice")).fetch();
    defer trimmed.deinit();
    try std.testing.expectEqual(@as(usize, 2), trimmed.count());
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
    var rows = try db.from(Item).where(Item.name.length().gt(1)).fetch();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.count());
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
    var rows = try db.from(Item).where(Item.name.instr("ite").gt(0)).fetch();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.count());
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
    try std.testing.expectEqual(@as(usize, 1), raw.count());
    try std.testing.expectEqual(@as(i64, 1), raw.at(0)[0].integer);
    var typed = try db.from(Item).where(Item.label.isDistinctFrom(@as(Value, .null))).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.count());
    try std.testing.expectEqual(@as(i64, 2), typed.at(0).id);
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
    try std.testing.expect(rows.at(0)[0] == .null);
    try std.testing.expectEqual(@as(i64, 0), rows.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 7), rows.at(1)[0].integer);
    try std.testing.expect(rows.at(1)[1] == .null);
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
    try std.testing.expectEqual(@as(f64, 2), raw.at(0)[0].real);
    var typed = try db.from(Item).select(.{Item.value.round(0)}).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(f64, 2), typed.at(0)[0].real);
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
    try std.testing.expectEqual(@as(f64, 1.24), rows.at(0)[0].real);
    try std.testing.expectEqual(@as(f64, 120), rows.at(0)[1].real);
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
    try std.testing.expectEqual(@as(i64, 42), raw.at(0)[0].integer);
    try std.testing.expectEqual(@as(f64, 42), raw.at(0)[1].real);
    try std.testing.expectEqualStrings("42", raw.at(0)[2].text);
    var typed = try db.from(Item).select(.{Item.value.cast("INTEGER")}).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(i64, 42), typed.at(0)[0].integer);
}

test "column type declarations accept SQLite type names with constraints" {
    const path = "sqlite_zig_type_names_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE type_matrix (id SMALLINT PRIMARY KEY, tiny TINYINT, big BIGINT, ubi UNSIGNED BIG INT, label VARCHAR(20) NOT NULL, code CHARACTER(5) UNIQUE, amount DECIMAL(10,2) CHECK (amount > 0), score DOUBLE PRECISION, flag BOOLEAN DEFAULT 1, stamp DATETIME, payload BLOB, note NCHAR(10));");
    created.deinit();
    var inserted = try db.exec("INSERT INTO type_matrix VALUES (1, 2, 3, 4, 'red', 'A', 9.99, 1.5, 0, '2026-09-19', X'0102', 'hello');");
    inserted.deinit();
    var defaulted = try db.exec("INSERT INTO type_matrix (id, label, code, amount, score, stamp, payload, note) VALUES (2, 'blue', 'B', 1.25, 2.5, '2026-09-20', X'00', 'world');");
    defaulted.deinit();
    var rows = try db.exec("SELECT id, tiny, big, ubi, label, code, amount, score, flag, stamp, payload, note FROM type_matrix ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[0].integer);
    try std.testing.expectEqual(@as(i64, 2), rows.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 3), rows.at(0)[2].integer);
    try std.testing.expectEqual(@as(i64, 4), rows.at(0)[3].integer);
    try std.testing.expectEqualStrings("red", rows.at(0)[4].text);
    try std.testing.expectEqualStrings("A", rows.at(0)[5].text);
    try std.testing.expectEqual(@as(f64, 9.99), rows.at(0)[6].real);
    try std.testing.expectEqual(@as(f64, 1.5), rows.at(0)[7].real);
    try std.testing.expectEqual(@as(i64, 0), rows.at(0)[8].integer);
    try std.testing.expectEqualStrings("2026-09-19", rows.at(0)[9].text);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, rows.at(0)[10].blob);
    try std.testing.expectEqualStrings("hello", rows.at(0)[11].text);
    try std.testing.expectEqual(@as(i64, 1), rows.at(1)[8].integer);
    var casted = try db.exec("SELECT CAST(big AS BIGINT), CAST(score AS DOUBLE PRECISION), CAST(label AS VARCHAR(20)), CAST(amount AS DECIMAL(10,2)), CAST(flag AS BOOLEAN) FROM type_matrix WHERE id = 1;");
    defer casted.deinit();
    try std.testing.expectEqual(@as(i64, 3), casted.rows[0][0].integer);
    try std.testing.expectEqual(@as(f64, 1.5), casted.rows[0][1].real);
    try std.testing.expectEqualStrings("red", casted.rows[0][2].text);
    try std.testing.expectEqual(@as(f64, 9.99), casted.rows[0][3].real);
    try std.testing.expectEqual(@as(i64, 0), casted.rows[0][4].integer);
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO type_matrix VALUES (3, 0, 0, 0, NULL, 'C', 1.0, 0.0, 1, '2026-09-21', X'00', 'x');"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO type_matrix VALUES (3, 0, 0, 0, 'green', 'A', 1.0, 0.0, 1, '2026-09-21', X'00', 'x');"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO type_matrix VALUES (3, 0, 0, 0, 'green', 'C', -1.0, 0.0, 1, '2026-09-21', X'00', 'x');"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO type_matrix VALUES (1, 0, 0, 0, 'green', 'C', 1.0, 0.0, 1, '2026-09-21', X'00', 'x');"));
    var counted = try db.exec("SELECT count(*) FROM type_matrix;");
    defer counted.deinit();
    try std.testing.expectEqual(@as(i64, 2), counted.rows[0][0].integer);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var reopened = try db.exec("SELECT label, amount FROM type_matrix ORDER BY id;");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.rows.len);
    try std.testing.expectEqualStrings("red", reopened.rows[0][0].text);
    try std.testing.expectEqual(@as(f64, 9.99), reopened.rows[0][1].real);
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
    try std.testing.expectEqualStrings("Alice", rows.at(0)[0].text);
    try std.testing.expectEqual(@as(i64, 42), rows.at(0)[1].integer);
    try std.testing.expect(rows.at(0)[2] == .null);
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
    var typed = try db.from(Item).select(.{Item.payload.jsonExtract("$.name")}).fetch();
    defer typed.deinit();
    try std.testing.expectEqualStrings("Alice", typed.at(0)[0].text);
    var filtered = try db.from(Item).where(Item.payload.jsonExtract("$.name").eq("Bob")).fetch();
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.count());
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
    var contains = try db.from(Item).where(Item.name.like("%ali%")).fetch();
    defer contains.deinit();
    try std.testing.expectEqual(@as(usize, 2), contains.count());
    var starts = try db.from(Item).where(Item.name.like("Al%")).fetch();
    defer starts.deinit();
    try std.testing.expectEqual(@as(usize, 1), starts.count());
    var ends = try db.from(Item).where(Item.name.like("%ob")).fetch();
    defer ends.deinit();
    try std.testing.expectEqual(@as(usize, 1), ends.count());
    var notContains = try db.from(Item).where(Item.name.notLike("%ali%")).fetch();
    defer notContains.deinit();
    try std.testing.expectEqual(@as(usize, 1), notContains.count());
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
    var rows = try db.from(Item).select(.{ Item.label, Item.id }).fetch();
    defer rows.deinit();
    try std.testing.expectEqualStrings("seven", rows.at(0)[0].text);
    try std.testing.expectEqual(@as(i64, 7), rows.at(0)[1].integer);
}

test "fetchOne and fetchOptional enforce single-row cardinality" {
    const path = "sqlite_zig_fetch_one_typed_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const Item = @import("../dsl/table.zig").table("fetch_one_items", struct { id: i64, label: []const u8 });
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var created = try db.exec("CREATE TABLE fetch_one_items (id INTEGER, label TEXT); INSERT INTO fetch_one_items VALUES (3, 'three');");
    created.deinit();
    var row = try db.from(Item).where(Item.id.eq(3)).fetchOne();
    defer db.from(Item).freeRow(&row);
    try std.testing.expectEqual(@as(i64, 3), row.id);
    try std.testing.expectEqualStrings("three", row.label);
    try std.testing.expectError(error.NoRows, db.from(Item).where(Item.id.eq(99)).fetchOne());
    const missing = try db.from(Item).where(Item.id.eq(99)).fetchOptional();
    try std.testing.expect(missing == null);
    var present = try db.from(Item).where(Item.id.eq(3)).fetchOptional();
    defer if (present) |*value| db.from(Item).freeRow(value);
    try std.testing.expectEqual(@as(i64, 3), present.?.id);
    var second = try db.from(Item).insert(.{ .id = 4, .label = "four" });
    second.deinit();
    try std.testing.expectError(error.TooManyRows, db.from(Item).fetchOne());
    try std.testing.expectError(error.TooManyRows, db.from(Item).fetchOptional());
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
    var coalesced = try db.from(Item).select(.{Item.label.coalesce("fallback")}).fetch();
    defer coalesced.deinit();
    try std.testing.expectEqualStrings("fallback", coalesced.rows[0][0].text);
    try std.testing.expectEqualStrings("ready", coalesced.rows[1][0].text);
    var ifnulled = try db.from(Item).select(.{Item.label.ifNull(7)}).fetch();
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
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", raw.at(0)[0].text);
    var typed = try db.from(Item).select(.{Item.payload.jsonSet("$.city", "Paris")}).fetch();
    defer typed.deinit();
    try std.testing.expectEqualStrings("{\"city\":\"Paris\"}", typed.at(0)[0].text);
    var inserted = try db.exec("SELECT json_set(payload, '$.country', 'UK') FROM json_set_items;");
    defer inserted.deinit();
    try std.testing.expectEqualStrings("{\"city\":\"London\",\"country\":\"UK\"}", inserted.rows[0][0].text);
}

test "raw DSL queries schema-less tables with runtime columns" {
    const path = "sqlite_zig_dynamic_dsl_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    const t_db_dynamic_items = db.table("dynamic_items");
    defer db.close();
    var created = try db.exec("CREATE TABLE dynamic_items (id INTEGER, name TEXT); INSERT INTO dynamic_items VALUES (1, 'Alice'), (2, 'Bob');");
    created.deinit();
    var rows = try t_db_dynamic_items.select(.{t_db_dynamic_items.column("name")}).where(t_db_dynamic_items.column("id").gte(2)).fetch();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("Bob", rows.at(0)[0].text);
    var compound = try t_db_dynamic_items.selectAll().where(t_db_dynamic_items.column("id").gt(0)).andWhere(t_db_dynamic_items.column("name").like("B%")).fetch();
    defer compound.deinit();
    try std.testing.expectEqual(@as(usize, 1), compound.count());
    var glob = try t_db_dynamic_items.selectAll().where(t_db_dynamic_items.column("name").glob("A*")).fetch();
    defer glob.deinit();
    try std.testing.expectEqual(@as(usize, 1), glob.count());
    var nulls = try db.exec("INSERT INTO dynamic_items VALUES (3, NULL);");
    nulls.deinit();
    var missing = try t_db_dynamic_items.selectAll().where(t_db_dynamic_items.column("name").isNull()).fetch();
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 1), missing.count());
}

fn freshDb(path: []const u8) !*Connection {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    return Connection.open(std.testing.allocator, path);
}

fn dropDb(db: *Connection, path: []const u8) void {
    db.close();
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
}

test "explicit values and expression assignments share native DML semantics" {
    const Widget = @import("../dsl/table.zig").table("exp_widgets", struct {
        id: i64,
        label: []const u8 = "untitled",
        stock: i64 = 0,
        parent_id: ?i64 = null,
    });
    const path = "sqlite_zig_explicit_dml_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(Widget, .{ .primaryKey = Widget.id });
    // Concise and explicit inserts agree.
    var a = try db.from(Widget).insert(.{ .id = 1, .label = "a", .stock = 5, .parent_id = null });
    a.deinit();
    var b = try db.from(Widget).insert(.{
        .id = Widget.id.value(2),
        .label = Widget.label.value("b"),
        .stock = Widget.stock.value(7),
        .parent_id = Widget.parent_id.nullValue(),
    });
    b.deinit();
    // defaultValue() omits the column so the database DEFAULT applies.
    var c = try db.from(Widget).insert(.{
        .id = 3,
        .label = Widget.label.defaultValue(),
        .stock = Widget.stock.defaultValue(),
        .parent_id = Widget.parent_id.nullValue(),
    });
    c.deinit();
    var rows = try db.from(Widget).select(Widget.all()).orderBy(Widget.id.asc()).fetch();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 3), rows.count());
    try std.testing.expectEqualStrings("untitled", rows.at(2).label);
    try std.testing.expectEqual(@as(i64, 0), rows.at(2).stock);
    try std.testing.expect(rows.at(2).parent_id == null);
    // Explicit update literals match concise updates.
    var upd1 = try (try db.from(Widget).update(.{ .label = Widget.label.value("a2") })).where(Widget.id.eq(1)).execute();
    upd1.deinit();
    // Arithmetic assignment evaluates natively: stock = stock + 10.
    var upd2 = try (try db.from(Widget).update(.{ .stock = Widget.stock.add(10) })).where(Widget.id.eq(1)).execute();
    upd2.deinit();
    // Column-to-column assignment within the same row scope.
    var upd3 = try (try db.from(Widget).update(.{ .label = Widget.label })).where(Widget.id.eq(1)).execute();
    upd3.deinit();
    var check = try db.from(Widget).select(Widget.all()).where(Widget.id.eq(1)).fetchOne();
    defer db.from(Widget).freeRow(&check);
    try std.testing.expectEqualStrings("a2", check.label);
    try std.testing.expectEqual(@as(i64, 15), check.stock);
    // Dynamic explicit values behave the same.
    const widgets = db.table("exp_widgets");
    var d = try widgets.insert(.{
        .id = widgets.column("id").value(4),
        .label = widgets.column("label").value("d"),
        .stock = widgets.column("stock").value(1),
        .parent_id = widgets.column("parent_id").nullValue(),
    });
    d.deinit();
    var du = try (try widgets.update(.{ .stock = widgets.column("stock").mul(3) })).where(widgets.column("id").eq(4)).execute();
    du.deinit();
    var got = try db.from(Widget).select(Widget.all()).where(Widget.id.eq(4)).fetchOne();
    defer db.from(Widget).freeRow(&got);
    try std.testing.expectEqual(@as(i64, 3), got.stock);
    // Upsert DO UPDATE accepts explicit values and expressions.
    var up = try (try db.from(Widget).onConflict(Widget.id).doUpdate(.{
        .stock = Widget.stock.add(100),
        .label = Widget.label.value("up"),
    })).insert(.{ .id = 1, .label = "ignored", .stock = 0 });
    up.deinit();
    var after = try db.from(Widget).select(Widget.all()).where(Widget.id.eq(1)).fetchOne();
    defer db.from(Widget).freeRow(&after);
    try std.testing.expectEqualStrings("up", after.label);
    try std.testing.expectEqual(@as(i64, 115), after.stock);
}

test "insertFrom maps source columns onto destination fields" {
    const Parent = @import("../dsl/table.zig").table("map_parent", struct { id: i64, label: []const u8 });
    const Child = @import("../dsl/table.zig").table("map_child", struct { id: i64, parent_id: i64, name: []const u8 });
    const path = "sqlite_zig_insert_from_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(Parent, .{ .primaryKey = Parent.id });
    try db.createTable(Child, .{ .primaryKey = Child.id });
    var seed = try db.from(Parent).insert(.{ .id = 10, .label = "root" });
    seed.deinit();
    var copied = try db.from(Child).insertFrom(Parent, .{
        .id = Parent.id,
        .parent_id = Parent.id,
        .name = Parent.label,
    });
    copied.deinit();
    var kids = try db.from(Child).select(Child.all()).fetch();
    defer kids.deinit();
    try std.testing.expectEqual(@as(usize, 1), kids.count());
    try std.testing.expectEqual(@as(i64, 10), kids.at(0).id);
    try std.testing.expectEqual(@as(i64, 10), kids.at(0).parent_id);
    try std.testing.expectEqualStrings("root", kids.at(0).name);
    // Dynamic mapping with differently ordered fields.
    var raw = try db.exec("CREATE TABLE map_src (a INTEGER, b TEXT); INSERT INTO map_src VALUES (20, 'dyn'); CREATE TABLE map_dst (x INTEGER, y TEXT);");
    raw.deinit();
    const src = db.table("map_src");
    const dst = db.table("map_dst");
    var dcopied = try dst.insertFrom(src, .{
        .y = src.column("b"),
        .x = src.column("a"),
    });
    dcopied.deinit();
    var got = try dst.selectAll().fetch();
    defer got.deinit();
    try std.testing.expectEqual(@as(usize, 1), got.count());
    try std.testing.expectEqual(@as(i64, 20), got.rows[0][0].integer);
    try std.testing.expectEqualStrings("dyn", got.rows[0][1].text);
}

test "ambiguous unqualified join references report an error" {
    const path = "sqlite_zig_ambiguous_join_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE amb_a (id INTEGER, v TEXT); CREATE TABLE amb_b (id INTEGER, w TEXT); INSERT INTO amb_a VALUES (1, 'a'); INSERT INTO amb_b VALUES (1, 'b');");
    setup.deinit();
    // Raw SQL parity: SQLite itself rejects these.
    try std.testing.expectError(error.AmbiguousColumn, db.exec("SELECT id FROM amb_a JOIN amb_b ON amb_a.id = amb_b.id;"));
    try std.testing.expectError(error.AmbiguousColumn, db.exec("SELECT amb_a.v FROM amb_a JOIN amb_b ON amb_a.id = amb_b.id WHERE id = 1;"));
    try std.testing.expectError(error.AmbiguousColumn, db.exec("SELECT amb_a.v FROM amb_a JOIN amb_b ON amb_a.id = amb_b.id GROUP BY id;"));
    // Qualified references resolve.
    var ok = try db.exec("SELECT amb_a.id FROM amb_a JOIN amb_b ON amb_a.id = amb_b.id;");
    defer ok.deinit();
    try std.testing.expectEqual(@as(usize, 1), ok.count());
    // USING-merged columns coalesce and stay legal unqualified.
    var merged = try db.exec("SELECT id FROM amb_a JOIN amb_b USING (id);");
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 1), merged.count());
    // Dynamic DSL: unqualified sugar errors, table-bound columns work.
    const a = db.table("amb_a");
    const b = db.table("amb_b");
    try std.testing.expectError(error.AmbiguousColumn, a.innerJoin(b, a.column("id").eq(b.column("id"))).select(db.col("id")).fetch());
    // SELECT * keeps duplicate output names legally (SQLite parity).
    var star = try a.innerJoin(b, a.column("id").eq(b.column("id"))).selectAll().fetch();
    defer star.deinit();
    try std.testing.expectEqual(@as(usize, 1), star.count());
    var dynOk = try a
        .innerJoin(b, a.column("id").eq(b.column("id")))
        .select(.{ a.column("id").as("aid"), b.column("id").as("bid") })
        .fetch();
    defer dynOk.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynOk.count());
    // Table aliases disambiguate self-joins.
    var setup2 = try db.exec("CREATE TABLE amb_e (id INTEGER, boss INTEGER); INSERT INTO amb_e VALUES (1, NULL), (2, 1);");
    setup2.deinit();
    const e1 = db.table("amb_e").as("e1");
    const e2 = db.table("amb_e").as("e2");
    var selfJoin = try db
        .from(e1)
        .innerJoin(e2, e1.column("id").eq(e2.column("boss")))
        .select(.{ e1.column("id").as("eid"), e2.column("id").as("bid") })
        .fetch();
    defer selfJoin.deinit();
    try std.testing.expectEqual(@as(usize, 1), selfJoin.count());
    try std.testing.expectError(error.AmbiguousColumn, db.exec("SELECT id FROM amb_e e1 JOIN amb_e e2 ON e1.id = e2.boss;"));
    // Typed aliases keep compile-time columns while rebinding qualifiers.
    const Emp = @import("../dsl/table.zig").table("amb_e", struct { id: i64, boss: ?i64 });
    const m1 = @import("../dsl/table.zig").aliased(Emp, "m1");
    const m2 = @import("../dsl/table.zig").aliased(Emp, "m2");
    var typedSelf = try db
        .from(m1)
        .innerJoin(m2, m1.id.eq(m2.boss))
        .select(.{ m1.id.as("eid"), m2.id.as("bid") })
        .fetch();
    defer typedSelf.deinit();
    try std.testing.expectEqual(@as(usize, 1), typedSelf.count());
    try std.testing.expectEqualStrings("eid", typedSelf.columns[0]);
    try std.testing.expectEqual(@as(i64, 1), (try typedSelf.get(0, "eid")).integer);
}

test "dynamic DSL covers queries without any struct" {
    const path = "sqlite_zig_final_dynamic_test.db";
    var db = try freshDb(path);
    const t_db_dyn = db.table("dyn");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE dyn (id INTEGER, name TEXT, age INTEGER); INSERT INTO dyn VALUES (1, 'Alice', 30), (2, 'Bob', 17), (3, 'Carol', 42);");
    setup.deinit();

    var adults = try t_db_dyn.select(.{ t_db_dyn.column("id"), t_db_dyn.column("name") }).where(t_db_dyn.column("age").gte(18)).orderBy(t_db_dyn.column("name").asc()).fetch();
    defer adults.deinit();
    try std.testing.expectEqual(@as(usize, 2), adults.count());

    var either = try t_db_dyn.selectAll().where(t_db_dyn.column("id").eq(2)).orWhere(t_db_dyn.column("id").eq(3)).fetch();
    defer either.deinit();
    try std.testing.expectEqual(@as(usize, 2), either.count());

    var both = try t_db_dyn.selectAll().where(t_db_dyn.column("age").gte(18)).andWhere(t_db_dyn.column("name").like("C%")).fetch();
    defer both.deinit();
    try std.testing.expectEqual(@as(usize, 1), both.count());

    var paged = try t_db_dyn.selectAll().orderBy(t_db_dyn.column("id").asc()).limit(2).offset(1).fetch();
    defer paged.deinit();
    try std.testing.expectEqual(@as(usize, 2), paged.count());
    try std.testing.expectEqual(@as(i64, 2), paged.rows[0][0].integer);

    var distinct = try t_db_dyn.select(.{t_db_dyn.column("age")}).distinct().fetch();
    defer distinct.deinit();
    try std.testing.expectEqual(@as(usize, 3), distinct.count());

    var sum = try t_db_dyn.select(.{t_db_dyn.column("age").sum()}).fetch();
    defer sum.deinit();
    try std.testing.expectEqual(@as(i64, 89), sum.rows[0][0].integer);
    var avg = try t_db_dyn.select(.{t_db_dyn.column("age").avg()}).fetch();
    defer avg.deinit();
    try std.testing.expectEqual(@as(f64, 89.0 / 3.0), avg.rows[0][0].real);
    var min = try t_db_dyn.select(.{t_db_dyn.column("age").min()}).fetch();
    defer min.deinit();
    try std.testing.expectEqual(@as(i64, 17), min.rows[0][0].integer);
    var max = try t_db_dyn.select(.{t_db_dyn.column("age").max()}).fetch();
    defer max.deinit();
    try std.testing.expectEqual(@as(i64, 42), max.rows[0][0].integer);
    var colCount = try t_db_dyn.select(.{t_db_dyn.column("age").count()}).fetch();
    defer colCount.deinit();
    try std.testing.expectEqual(@as(i64, 3), colCount.rows[0][0].integer);

    var counted = try t_db_dyn.selectAll().countStar().fetch();
    defer counted.deinit();
    try std.testing.expectEqual(@as(i64, 3), counted.rows[0][0].integer);

    var ranged = try t_db_dyn.selectAll().where(t_db_dyn.column("age").between(18, 40)).fetch();
    defer ranged.deinit();
    try std.testing.expectEqual(@as(usize, 1), ranged.count());

    var notRanged = try t_db_dyn.selectAll().where(t_db_dyn.column("age").notBetween(18, 40)).fetch();
    defer notRanged.deinit();
    try std.testing.expectEqual(@as(usize, 2), notRanged.count());

    var globbed = try t_db_dyn.selectAll().where(t_db_dyn.column("name").glob("A*")).fetch();
    defer globbed.deinit();
    try std.testing.expectEqual(@as(usize, 1), globbed.count());

    var notLike = try t_db_dyn.selectAll().where(t_db_dyn.column("name").notLike("A%")).fetch();
    defer notLike.deinit();
    try std.testing.expectEqual(@as(usize, 2), notLike.count());

    var lowered = try t_db_dyn.selectAll().where(t_db_dyn.column("name").lower().eq("alice")).fetch();
    defer lowered.deinit();
    try std.testing.expectEqual(@as(usize, 1), lowered.count());

    var inList = try t_db_dyn.selectAll().whereInValues(t_db_dyn.column("id"), .{ 1, 3 }).fetch();
    defer inList.deinit();
    try std.testing.expectEqual(@as(usize, 2), inList.count());

    var city = try db.exec("ALTER TABLE dyn ADD COLUMN profile TEXT;");
    city.deinit();
    var profiled = try db.exec("UPDATE dyn SET profile = '{\"city\":\"Oslo\"}' WHERE id = 1;");
    profiled.deinit();
    var foundCity = try t_db_dyn.selectAll().where(t_db_dyn.column("profile").jsonExtract("$.city").eq("Oslo")).fetch();
    defer foundCity.deinit();
    try std.testing.expectEqual(@as(usize, 1), foundCity.count());

    try std.testing.expectError(error.InvalidSql, t_db_dyn.selectAll().orderBy(t_db_dyn.column("name").lower().asc()).fetch());
    try std.testing.expectError(error.InvalidSql, t_db_dyn.selectAll().having(t_db_dyn.column("id").eq(t_db_dyn.column("name"))).fetch());
}

test "raw SQL, dynamic DSL, and typed DSL interoperate on one database" {
    const path = "sqlite_zig_final_interop_test.db";
    var db = try freshDb(path);
    const t_db_interop_users = db.table("interop_users");
    defer dropDb(db, path);
    const User = @import("../dsl/table.zig").table("interop_users", struct { id: i64, name: []const u8, age: ?i64 });

    var created = try db.exec("CREATE TABLE interop_users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER); INSERT INTO interop_users VALUES (1, 'Alice', 30);");
    created.deinit();

    var dyn = try t_db_interop_users.selectAll().where(t_db_interop_users.column("age").gte(18)).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(usize, 1), dyn.count());
    var dynInsert = try t_db_interop_users.insert(.{ .id = 2, .name = "Bob", .age = 17 });
    dynInsert.deinit();

    try db.schema(User).validate();
    var typed = try db.from(User).where(User.age.gte(18)).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.count());
    try std.testing.expectEqualStrings("Alice", typed.at(0).name);

    var updated = try db.exec("UPDATE interop_users SET age = 18 WHERE id = 2;");
    updated.deinit();
    var adults = try db.from(User).where(User.age.gte(18)).fetch();
    defer adults.deinit();
    try std.testing.expectEqual(@as(usize, 2), adults.count());

    var mutation = try t_db_interop_users.delete().where(t_db_interop_users.column("id").eq(1)).execute();
    mutation.deinit();
    var remaining = try db.exec("SELECT id FROM interop_users ORDER BY id;");
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 1), remaining.count());
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
    const t_db_d_orders = db.table("d_orders");
    const t_db_d_users = db.table("d_users");
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
    var user = try t_db_d_users.insert(.{ .id = 1, .email = "a@x.test" });
    user.deinit();
    try std.testing.expectError(error.ConstraintViolation, t_db_d_users.insert(.{ .id = 2, .email = "a@x.test" }));
    var order = try t_db_d_orders.insert(.{ .id = 1, .user_id = 1 });
    order.deinit();
    try std.testing.expectError(error.ConstraintViolation, t_db_d_orders.insert(.{ .id = 2, .user_id = 99 }));
    var joined = try t_db_d_users.innerJoin("d_orders", t_db_d_users.column("id").eq(t_db_d_orders.column("user_id"))).fetch();
    defer joined.deinit();
    try std.testing.expectEqual(@as(usize, 1), joined.count());
    try db.createIndex("d_users", "d_users_email_idx", .{t_db_d_users.column("email")}, true);
    try std.testing.expectError(error.ConstraintViolation, t_db_d_users.insert(.{ .id = 3, .email = "a@x.test" }));
    var ignored = try t_db_d_users.insertOrIgnore(.{ .id = 1, .email = "dup@x.test" });
    ignored.deinit();
    var kept = try t_db_d_users.selectAll().where(t_db_d_users.column("id").eq(1)).fetch();
    defer kept.deinit();
    try std.testing.expectEqualStrings("a@x.test", kept.rows[0][1].text);
}

test "composite primary keys work in typed and dynamic DSL" {
    const path = "sqlite_zig_final_composite_pk_test.db";
    var db = try freshDb(path);
    const t_db_c_dyn_members = db.table("c_dyn_members");
    defer dropDb(db, path);
    const Member = @import("../dsl/table.zig").table("c_members", struct { tenant_id: i64, user_id: i64, label: []const u8 });
    try db.createTable(Member, .{ .primaryKey = &.{ Member.tenant_id, Member.user_id } });
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
    var dyn = try t_db_c_dyn_members.insert(.{ .tenant_id = 1, .user_id = 1 });
    dyn.deinit();
    try std.testing.expectError(error.ConstraintViolation, t_db_c_dyn_members.insert(.{ .tenant_id = 1, .user_id = 1 }));
}

test "composite foreign keys cascade in typed and dynamic DSL" {
    const path = "sqlite_zig_final_composite_fk_test.db";
    var db = try freshDb(path);
    const t_db_cfd_parents = db.table("cfd_parents");
    const t_db_cfd_children = db.table("cfd_children");
    defer dropDb(db, path);
    const Parent = @import("../dsl/table.zig").table("cf_parents", struct { tenant_id: i64, id: i64 });
    const Child = @import("../dsl/table.zig").table("cf_children", struct { tenant_id: i64, parent_id: i64 });
    try db.createTable(Parent, .{ .primaryKey = &.{ Parent.tenant_id, Parent.id } });
    try db.createTable(Child, .{ .foreignKeys = &.{.{
        .columns = &.{ Child.tenant_id, Child.parent_id },
        .references = &.{ Parent.tenant_id, Parent.id },
        .onDelete = .cascade,
    }} });
    var parent = try db.from(Parent).insert(.{ .tenant_id = 1, .id = 7 });
    parent.deinit();
    var child = try db.from(Child).insert(.{ .tenant_id = 1, .parent_id = 7 });
    child.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Child).insert(.{ .tenant_id = 1, .parent_id = 8 }));
    var deleted = try db.from(Parent).delete().where(Parent.tenant_id.eq(1)).execute();
    deleted.deinit();
    var remaining = try db.from(Child).selectAll().fetch();
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 0), remaining.count());

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
    var dparent = try t_db_cfd_parents.insert(.{ .tenant_id = 1, .id = 7 });
    dparent.deinit();
    var dchild = try t_db_cfd_children.insert(.{ .tenant_id = 1, .parent_id = 7 });
    dchild.deinit();
    var ddeleted = try t_db_cfd_parents.delete().where(t_db_cfd_parents.column("tenant_id").eq(1)).execute();
    ddeleted.deinit();
    var dremaining = try t_db_cfd_children.selectAll().fetch();
    defer dremaining.deinit();
    try std.testing.expectEqual(@as(usize, 0), dremaining.count());
}

test "foreign-key actions enforce restrict, cascade, and set null" {
    const path = "sqlite_zig_final_fk_actions_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const Parent = @import("../dsl/table.zig").table("fa_parents", struct { id: i64 });
    const Cascade = @import("../dsl/table.zig").table("fa_cascade", struct { id: i64, parent_id: i64 });
    const Nullable = @import("../dsl/table.zig").table("fa_nullable", struct { id: i64, parent_id: ?i64 });
    const Restricted = @import("../dsl/table.zig").table("fa_restricted", struct { id: i64, parent_id: i64 });
    try db.createTable(Parent, .{ .primaryKey = Parent.id });
    try db.createTable(Cascade, .{ .foreignKeys = &.{.{ .column = Cascade.parent_id, .references = Parent.id, .onDelete = .cascade, .onUpdate = .cascade }} });
    try db.createTable(Nullable, .{ .foreignKeys = &.{.{ .column = Nullable.parent_id, .references = Parent.id, .onDelete = .setNull, .onUpdate = .setNull }} });
    try db.createTable(Restricted, .{ .foreignKeys = &.{.{ .column = Restricted.parent_id, .references = Parent.id }} });
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
    var bumped = try bump.where(Parent.id.eq(1)).execute();
    bumped.deinit();
    var moved = try db.from(Cascade).selectAll().fetch();
    defer moved.deinit();
    try std.testing.expectEqual(@as(i64, 2), moved.rows[0].parent_id);
    var nulled = try db.from(Nullable).selectAll().fetch();
    defer nulled.deinit();
    try std.testing.expect(nulled.rows[0].parent_id == null);

    var restrictedTwo = try db.from(Restricted).insert(.{ .id = 2, .parent_id = 2 });
    restrictedTwo.deinit();
    var blocked = db.from(Parent).delete().where(Parent.id.eq(2));
    try std.testing.expectError(error.ConstraintViolation, blocked.execute());
    var wipeRestricted = try db.from(Restricted).delete().execute();
    wipeRestricted.deinit();
    var wipeNullable = try db.from(Nullable).delete().execute();
    wipeNullable.deinit();
    var wipeCascade = try db.from(Cascade).delete().execute();
    wipeCascade.deinit();
    var gone = try db.from(Parent).delete().where(Parent.id.eq(2)).execute();
    gone.deinit();
    var left = try db.from(Parent).selectAll().fetch();
    defer left.deinit();
    try std.testing.expectEqual(@as(usize, 0), left.count());
}

test "values are bound, never interpolated" {
    const path = "sqlite_zig_final_binding_test.db";
    var db = try freshDb(path);
    const t_db_bind_items = db.table("bind_items");
    defer dropDb(db, path);
    const Item = @import("../dsl/table.zig").table("bind_items", struct { id: i64, label: []const u8 });
    try db.createTable(Item, .{});
    const tricky = "O'Brien \"%\" _*";
    var inserted = try db.from(Item).insert(.{ .id = 1, .label = tricky });
    inserted.deinit();
    var found = try db.from(Item).where(Item.label.eq(tricky)).fetch();
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 1), found.count());
    var liked = try db.from(Item).where(Item.label.like("O'Brien%")).fetch();
    defer liked.deinit();
    try std.testing.expectEqual(@as(usize, 1), liked.count());
    var hostile = try t_db_bind_items.selectAll().where(t_db_bind_items.column("label").eq(tricky)).fetch();
    defer hostile.deinit();
    try std.testing.expectEqual(@as(usize, 1), hostile.count());
}

test "joins, exists, and subqueries work in both DSL modes" {
    const path = "sqlite_zig_final_joins_test.db";
    var db = try freshDb(path);
    const t_db_j_users = db.table("j_users");
    const t_db_j_orders = db.table("j_orders");
    defer dropDb(db, path);
    const User = @import("../dsl/table.zig").table("j_users", struct { id: i64, name: []const u8 });
    const Order = @import("../dsl/table.zig").table("j_orders", struct { id: i64, user_id: i64 });
    try db.createTable(User, .{});
    try db.createTable(Order, .{});
    var setup = try db.exec("INSERT INTO j_users VALUES (1, 'A'), (2, 'B'); INSERT INTO j_orders VALUES (10, 1), (11, 99);");
    setup.deinit();

    var inner = try db.from(User).innerJoin(Order, User.id.eq(Order.user_id)).fetch();
    defer inner.deinit();
    try std.testing.expectEqual(@as(usize, 1), inner.count());

    var left = try db.from(User).leftJoin(Order, User.id.eq(Order.user_id)).fetch();
    defer left.deinit();
    try std.testing.expectEqual(@as(usize, 2), left.count());

    var cross = try db.from(User).crossJoin(Order).fetch();
    defer cross.deinit();
    try std.testing.expectEqual(@as(usize, 4), cross.count());

    var dynInner = try t_db_j_users.innerJoin(t_db_j_orders, t_db_j_users.column("id").eq(t_db_j_orders.column("user_id"))).fetch();
    defer dynInner.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynInner.count());

    var exists = try db.from(User).whereExists(Order, Order.user_id.eq(User.id)).fetch();
    defer exists.deinit();
    try std.testing.expectEqual(@as(usize, 1), exists.count());

    var notExists = try db.from(User).whereNotExists(Order, Order.user_id.eq(User.id)).fetch();
    defer notExists.deinit();
    try std.testing.expectEqual(@as(usize, 1), notExists.count());

    var inQ = try db.from(User).whereInQuery(User.id, Order, Order.user_id).fetch();
    defer inQ.deinit();
    try std.testing.expectEqual(@as(usize, 1), inQ.count());

    var notInQ = try db.from(User).whereNotInQuery(User.id, Order, Order.user_id).fetch();
    defer notInQ.deinit();
    try std.testing.expectEqual(@as(usize, 1), notInQ.count());

    var dynExists = try t_db_j_users.selectAll().whereExists(t_db_j_orders, t_db_j_orders.column("user_id").eq(t_db_j_users.column("id"))).fetch();
    defer dynExists.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynExists.count());

    var dynIn = try t_db_j_users.selectAll().whereInQuery(t_db_j_users.column("id"), t_db_j_orders, t_db_j_orders.column("user_id")).fetch();
    defer dynIn.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynIn.count());
}

test "insert helpers and typed convenience insert share semantics" {
    const path = "sqlite_zig_final_insert_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const Item = @import("../dsl/table.zig").table("ins_items", struct { id: i64, label: []const u8 });
    try db.createTable(Item, .{ .primaryKey = Item.id });
    var first = try db.from(Item).insert(.{ .id = 1, .label = "one" });
    first.deinit();
    var ignored = try db.from(Item).insertOrIgnore(.{ .id = 1, .label = "dup" });
    ignored.deinit();
    var replaced = try db.from(Item).insertOrReplace(.{ .id = 1, .label = "two" });
    replaced.deinit();
    var rows = try db.from(Item).selectAll().fetch();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("two", rows.at(0).label);
}

test "COUNT DISTINCT deduplicates across raw SQL and both DSL modes" {
    const path = "sqlite_zig_final_distinct_agg_test.db";
    var db = try freshDb(path);
    const t_db_daggs = db.table("daggs");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE daggs (id INTEGER, label TEXT); INSERT INTO daggs VALUES (1, 'a'), (2, 'a'), (3, 'b'), (4, NULL);");
    setup.deinit();

    var raw = try db.exec("SELECT COUNT(DISTINCT label) FROM daggs;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(i64, 2), raw.at(0)[0].integer);

    var rawSum = try db.exec("SELECT SUM(DISTINCT id) FROM daggs;");
    defer rawSum.deinit();
    try std.testing.expectEqual(@as(i64, 10), rawSum.rows[0][0].integer);

    var dyn = try t_db_daggs.select(.{t_db_daggs.column("label").countDistinct()}).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(i64, 2), dyn.at(0)[0].integer);

    const Agg = @import("../dsl/table.zig").table("daggs", struct { id: i64, label: ?[]const u8 });
    var typed = try db.from(Agg).select(.{Agg.label.countDistinct()}).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(i64, 2), typed.at(0)[0].integer);

    var grouped = try db.exec("SELECT label, COUNT(DISTINCT id) FROM daggs GROUP BY label;");
    defer grouped.deinit();
    try std.testing.expectEqual(@as(usize, 3), grouped.count());

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
    const t_db_exprs = db.table("exprs");
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

    var glob = try t_db_exprs.selectAll().where(t_db_exprs.column("name").glob("A*")).fetch();
    defer glob.deinit();
    try std.testing.expectEqual(@as(usize, 2), glob.count());
    var globRaw = try db.exec("SELECT name FROM exprs WHERE name IS NOT NULL AND name GLOB 'A?i*' ORDER BY name;");
    defer globRaw.deinit();
    try std.testing.expectEqual(@as(usize, 1), globRaw.count());
    try std.testing.expectEqualStrings("Alice", globRaw.rows[0][0].text);
    var globClass = try db.exec("SELECT name FROM exprs WHERE name GLOB '[AB]ob' ORDER BY name;");
    defer globClass.deinit();
    try std.testing.expectEqual(@as(usize, 1), globClass.count());
    var globNeg = try db.exec("SELECT name FROM exprs WHERE name GLOB '[^A]*' ORDER BY name;");
    defer globNeg.deinit();
    try std.testing.expectEqual(@as(usize, 1), globNeg.count());
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
    try std.testing.expectEqual(@as(usize, 1), caseWhere.count());
    try std.testing.expectEqual(@as(i64, 0), caseWhere.rows[0][0].integer);

    var prec = try db.exec("SELECT a FROM exprs WHERE a = 1 OR b = 0 AND c = 1 ORDER BY a;");
    defer prec.deinit();
    try std.testing.expectEqual(@as(usize, 2), prec.count());
    try std.testing.expectEqual(@as(i64, 1), prec.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 1), prec.rows[1][0].integer);
    var precOr = try t_db_exprs.selectAll().where(t_db_exprs.column("a").eq(0)).orWhere(t_db_exprs.column("b").eq(1)).fetch();
    defer precOr.deinit();
    try std.testing.expectEqual(@as(usize, 2), precOr.count());

    var substrAlias = try db.exec("SELECT SUBSTRING('hello', 2, 3) FROM exprs LIMIT 1;");
    defer substrAlias.deinit();
    try std.testing.expectEqualStrings("ell", substrAlias.rows[0][0].text);

    var dyn = try t_db_exprs.selectAll().where(t_db_exprs.column("name").likeEscape("Al%", "\\")).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(usize, 2), dyn.count());

    const ExprItem = @import("../dsl/table.zig").table("exprs", struct { a: i64, b: i64, c: i64, name: ?[]const u8 });
    var typed = try db.from(ExprItem).where(ExprItem.name.likeEscape("Al%", "\\")).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.count());

    var dynNot = try t_db_exprs.selectAll().where(t_db_exprs.column("name").notLikeEscape("Al%", "\\")).fetch();
    defer dynNot.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynNot.count());
}

test "dynamic and typed DSL build CTE queries" {
    const path = "sqlite_zig_final_cte_test.db";
    var db = try freshDb(path);
    const t_db_nums = db.table("nums");
    const t_db_live = db.table("live");
    const t_db_second = db.table("second");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE cte_src (id INTEGER, label TEXT, active INTEGER); INSERT INTO cte_src VALUES (1, 'alpha', 1), (2, 'beta', 0), (3, 'gamma', 1);");
    setup.deinit();

    var dyn = try t_db_live.with("live", "SELECT id, label FROM cte_src WHERE active = 1").orderBy(t_db_live.column("id").asc()).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(usize, 2), dyn.count());
    try std.testing.expectEqual(@as(i64, 1), dyn.at(0)[0].integer);

    const Live = @import("../dsl/table.zig").table("live", struct { id: i64, label: []const u8 });
    var typed = try db.from(Live).with("live", "SELECT id, label FROM cte_src WHERE active = 1").orderBy(Live.id.asc()).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 2), typed.count());
    try std.testing.expectEqualStrings("gamma", typed.at(1).label);

    var chained = try t_db_second.with("first", "SELECT id FROM cte_src WHERE id >= 2").with("second", "SELECT id FROM first").orderBy(t_db_second.column("id").asc()).fetch();
    defer chained.deinit();
    try std.testing.expectEqual(@as(usize, 2), chained.count());

    var rec = try t_db_nums.withRecursive("nums", "SELECT 1 AS n", "SELECT n + 1 AS n FROM nums WHERE n < 5").orderBy(t_db_nums.column("n").asc()).fetch();
    defer rec.deinit();
    try std.testing.expectEqual(@as(usize, 5), rec.count());
    try std.testing.expectEqual(@as(i64, 5), rec.rows[4][0].integer);
}

test "explicit zig to sql column mapping round-trips" {
    const path = "sqlite_zig_final_mapping_test.db";
    var db = try freshDb(path);
    const t_db_map_users = db.table("map_users");
    defer dropDb(db, path);
    const col = @import("../dsl/column.zig").column;
    const User = @import("../dsl/table.zig").table("map_users", .{
        .firstName = col("first_name", []const u8),
        .ageYears = col("age_years", i64),
    });
    try db.createTable(User, .{ .primaryKey = User.firstName });
    try db.schema(User).validate();

    var inserted = try db.from(User).insert(.{ .firstName = "Ada", .ageYears = 36 });
    inserted.deinit();

    var dyn = try t_db_map_users.selectAll().where(t_db_map_users.column("first_name").eq("Ada")).fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(usize, 1), dyn.count());
    try std.testing.expectEqual(@as(i64, 36), dyn.at(0)[1].integer);

    var typed = try db.from(User).where(User.ageYears.gte(18)).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 1), typed.count());
    try std.testing.expectEqualStrings("Ada", typed.at(0).firstName);
    try std.testing.expectEqual(@as(i64, 36), typed.at(0).ageYears);

    var pending = try db.from(User).update(.{ .ageYears = 37 });
    var renamed = try pending.where(User.firstName.eq("Ada")).execute();
    renamed.deinit();
    var one = try db.from(User).where(User.firstName.eq("Ada")).fetchOne();
    defer db.from(User).freeRow(&one);
    try std.testing.expectEqual(@as(i64, 37), one.ageYears);

    var raw = try db.exec("SELECT first_name, age_years FROM map_users;");
    defer raw.deinit();
    try std.testing.expectEqualStrings("Ada", raw.at(0)[0].text);

    const Wrong = @import("../dsl/table.zig").table("map_users", struct { firstName: []const u8, ageYears: []const u8 });
    try std.testing.expectError(error.SchemaMismatch, db.schema(Wrong).validate());
}

test "insert, update, and delete support returning clause" {
    const path = "sqlite_zig_returning_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var schema = try db.exec("CREATE TABLE ret_users (id INTEGER PRIMARY KEY, name TEXT, score INTEGER);");
    schema.deinit();

    var ins = try db.exec("INSERT INTO ret_users (id, name, score) VALUES (1, 'Alice', 100), (2, 'Bob', 200) RETURNING id, name, score * 2 AS doubled;");
    defer ins.deinit();
    try std.testing.expectEqual(@as(usize, 2), ins.count());
    try std.testing.expectEqual(@as(usize, 3), ins.columns.len);
    try std.testing.expectEqualStrings("id", ins.columns[0]);
    try std.testing.expectEqualStrings("name", ins.columns[1]);
    try std.testing.expectEqualStrings("doubled", ins.columns[2]);
    try std.testing.expectEqual(@as(i64, 1), ins.rows[0][0].integer);
    try std.testing.expectEqualStrings("Alice", ins.rows[0][1].text);
    try std.testing.expectEqual(@as(i64, 200), ins.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 2), ins.rows[1][0].integer);
    try std.testing.expectEqualStrings("Bob", ins.rows[1][1].text);
    try std.testing.expectEqual(@as(i64, 400), ins.rows[1][2].integer);

    var upd = try db.exec("UPDATE ret_users SET score = 150 WHERE id = 1 RETURNING id, score;");
    defer upd.deinit();
    try std.testing.expectEqual(@as(usize, 1), upd.count());
    try std.testing.expectEqual(@as(i64, 1), upd.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 150), upd.rows[0][1].integer);

    var del = try db.exec("DELETE FROM ret_users WHERE id = 2 RETURNING id, name;");
    defer del.deinit();
    try std.testing.expectEqual(@as(usize, 1), del.count());
    try std.testing.expectEqual(@as(i64, 2), del.rows[0][0].integer);
    try std.testing.expectEqualStrings("Bob", del.rows[0][1].text);
}

test "connection executes queries through bytecode virtual machine" {
    const path = "test_bytecode_vm.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();

    var res1 = try db.executeBytecode("SELECT 10 + 20 * 2 AS calculated;");
    defer res1.deinit();
    try std.testing.expectEqual(@as(usize, 1), res1.count());
    try std.testing.expectEqualStrings("calculated", res1.columns[0]);
    try std.testing.expectEqual(@as(i64, 50), res1.rows[0][0].integer);

    var res2 = try db.executeBytecode("SELECT 'SQLite' || '.zig' AS name, abs(-99) AS positive;");
    defer res2.deinit();
    try std.testing.expectEqual(@as(usize, 1), res2.count());
    try std.testing.expectEqualStrings("SQLite.zig", res2.at(0)[0].text);
    try std.testing.expectEqual(@as(i64, 99), res2.at(0)[1].integer);

    var initDdl = try db.exec("CREATE TABLE vm_items (id INTEGER PRIMARY KEY, title TEXT, price REAL);");
    initDdl.deinit();
    var insertDml = try db.exec("INSERT INTO vm_items VALUES (1, 'Book', 12.5), (2, 'Pen', 1.5), (3, 'Laptop', 999.0);");
    insertDml.deinit();

    var res3 = try db.executeBytecode("SELECT id, title, price FROM vm_items WHERE id > 1;");
    defer res3.deinit();
    try std.testing.expectEqual(@as(usize, 2), res3.count());
    try std.testing.expectEqual(@as(i64, 2), res3.rows[0][0].integer);
    try std.testing.expectEqualStrings("Pen", res3.rows[0][1].text);
    try std.testing.expectEqual(@as(i64, 3), res3.rows[1][0].integer);
    try std.testing.expectEqualStrings("Laptop", res3.rows[1][1].text);
}

test "CHECK constraints on INSERT and UPDATE enforce SQLite rules" {
    const path = "sqlite_zig_check_constraint_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var tbl = try db.exec("CREATE TABLE chk_test (id INT PRIMARY KEY, val INT CHECK (val > 0), max_val INT, CHECK (val <= max_val));");
    tbl.deinit();

    var ins1 = try db.exec("INSERT INTO chk_test VALUES (1, 10, 20);");
    ins1.deinit();

    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO chk_test VALUES (2, -5, 20);"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO chk_test VALUES (3, 30, 20);"));

    var insNull1 = try db.exec("INSERT INTO chk_test VALUES (4, NULL, 20);");
    insNull1.deinit();
    var insNull2 = try db.exec("INSERT INTO chk_test VALUES (5, 10, NULL);");
    insNull2.deinit();

    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE chk_test SET val = -1 WHERE id = 1;"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE chk_test SET val = 25 WHERE id = 1;"));

    var chkRow = try db.exec("SELECT val FROM chk_test WHERE id = 1;");
    defer chkRow.deinit();
    try std.testing.expectEqual(@as(i64, 10), chkRow.rows[0][0].integer);

    var updOk = try db.exec("UPDATE chk_test SET val = 15 WHERE id = 1;");
    updOk.deinit();

    var chkRow2 = try db.exec("SELECT val FROM chk_test WHERE id = 1;");
    defer chkRow2.deinit();
    try std.testing.expectEqual(@as(i64, 15), chkRow2.rows[0][0].integer);
}

test "STRICT tables enforce SQLite strict type affinity and coercion" {
    const path = "sqlite_zig_strict_table_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    try std.testing.expectError(error.ConstraintViolation, db.exec("CREATE TABLE strict_bad (id INT, extra VARCHAR) STRICT;"));

    var tbl = try db.exec("CREATE TABLE strict_ok (i INT, r REAL, t TEXT, b BLOB, a ANY) STRICT;");
    tbl.deinit();

    var ins1 = try db.exec("INSERT INTO strict_ok VALUES (10, 3.14, 'hello', X'0102', 'anything');");
    ins1.deinit();
    var ins2 = try db.exec("INSERT INTO strict_ok VALUES (20, 2.0, 'world', X'0304', 12345);");
    ins2.deinit();

    var insCoerce = try db.exec("INSERT INTO strict_ok VALUES (30, 42, 'coerced', X'00', 3.14);");
    insCoerce.deinit();

    var insCoerceInt = try db.exec("INSERT INTO strict_ok VALUES (50.0, 1.0, 'int_from_float', X'00', NULL);");
    insCoerceInt.deinit();

    var sel = try db.exec("SELECT i, r, a FROM strict_ok WHERE i = 30;");
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel.count());
    try std.testing.expectEqual(@as(f64, 42.0), sel.rows[0][1].real);

    var sel2 = try db.exec("SELECT i, r FROM strict_ok WHERE i = 50;");
    defer sel2.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel2.count());
    try std.testing.expectEqual(@as(i64, 50), sel2.rows[0][0].integer);

    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO strict_ok (i, r, t, b, a) VALUES ('not_an_int', 1.0, 'x', X'00', 1);"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO strict_ok (i, r, t, b, a) VALUES (1, 'not_a_real', 'x', X'00', 1);"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO strict_ok (i, r, t, b, a) VALUES (1, 1.0, 999, X'00', 1);"));

    try std.testing.expectError(error.ConstraintViolation, db.exec("ALTER TABLE strict_ok ADD COLUMN bad_col VARCHAR;"));
    var addOk = try db.exec("ALTER TABLE strict_ok ADD COLUMN good_col TEXT;");
    addOk.deinit();
}

test "WITHOUT ROWID tables enforce primary key and not-null semantics" {
    const path = "sqlite_zig_without_rowid_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    try std.testing.expectError(error.ConstraintViolation, db.exec("CREATE TABLE norowid_nopk (a INT, b TEXT) WITHOUT ROWID;"));

    var tbl = try db.exec("CREATE TABLE norowid_tbl (k1 INT, k2 TEXT, val REAL, PRIMARY KEY (k1, k2)) WITHOUT ROWID;");
    tbl.deinit();

    var ins = try db.exec("INSERT INTO norowid_tbl VALUES (1, 'a', 1.5), (2, 'b', 2.5);");
    ins.deinit();

    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO norowid_tbl VALUES (NULL, 'c', 3.5);"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO norowid_tbl VALUES (3, NULL, 3.5);"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO norowid_tbl VALUES (1, 'a', 9.9);"));

    var sel = try db.exec("SELECT val FROM norowid_tbl WHERE k1 = 2 AND k2 = 'b';");
    defer sel.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel.count());
    try std.testing.expectEqual(@as(f64, 2.5), sel.rows[0][0].real);
}

test "generated columns compute values and reject direct writes" {
    const path = "sqlite_zig_gen_columns_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var tbl = try db.exec("CREATE TABLE gen_items (x INT, y INT, s INT GENERATED ALWAYS AS (x + y) STORED, v INT AS (x * y) VIRTUAL);");
    tbl.deinit();

    var insExplicit = try db.exec("INSERT INTO gen_items (x, y) VALUES (3, 4);");
    insExplicit.deinit();

    var sel1 = try db.exec("SELECT x, y, s, v FROM gen_items WHERE x = 3;");
    defer sel1.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel1.count());
    try std.testing.expectEqual(@as(i64, 7), sel1.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 12), sel1.rows[0][3].integer);

    var insOmitted = try db.exec("INSERT INTO gen_items VALUES (5, 6);");
    insOmitted.deinit();

    var sel2 = try db.exec("SELECT s, v FROM gen_items WHERE x = 5;");
    defer sel2.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel2.count());
    try std.testing.expectEqual(@as(i64, 11), sel2.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 30), sel2.rows[0][1].integer);

    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO gen_items (x, y, s) VALUES (1, 2, 99);"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE gen_items SET s = 100 WHERE x = 3;"));

    var upd = try db.exec("UPDATE gen_items SET y = 10 WHERE x = 3;");
    upd.deinit();

    var sel3 = try db.exec("SELECT s, v FROM gen_items WHERE x = 3;");
    defer sel3.deinit();
    try std.testing.expectEqual(@as(usize, 1), sel3.count());
    try std.testing.expectEqual(@as(i64, 13), sel3.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 30), sel3.rows[0][1].integer);

    var chainTbl = try db.exec("CREATE TABLE gen_chain (a INT, b INT AS (a * 2), c INT AS (b + 5));");
    chainTbl.deinit();

    var chainIns = try db.exec("INSERT INTO gen_chain (a) VALUES (10);");
    chainIns.deinit();

    var chainSel = try db.exec("SELECT b, c FROM gen_chain;");
    defer chainSel.deinit();
    try std.testing.expectEqual(@as(usize, 1), chainSel.count());
    try std.testing.expectEqual(@as(i64, 20), chainSel.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 25), chainSel.rows[0][1].integer);
}

test "foreign key referential actions SET DEFAULT and NO ACTION" {
    const path = "sqlite_zig_fk_actions_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var pragma = try db.exec("PRAGMA foreign_keys = ON;");
    pragma.deinit();

    var pTbl = try db.exec("CREATE TABLE parent (id INT PRIMARY KEY, name TEXT);");
    pTbl.deinit();
    var cDefTbl = try db.exec("CREATE TABLE child_def (id INT PRIMARY KEY, p_id INT DEFAULT 999, FOREIGN KEY (p_id) REFERENCES parent(id) ON DELETE SET DEFAULT);");
    cDefTbl.deinit();
    var cNoActTbl = try db.exec("CREATE TABLE child_noact (id INT PRIMARY KEY, p_id INT, FOREIGN KEY (p_id) REFERENCES parent(id) ON DELETE NO ACTION);");
    cNoActTbl.deinit();

    var pIns = try db.exec("INSERT INTO parent VALUES (1, 'One'), (999, 'Default');");
    pIns.deinit();
    var cDefIns = try db.exec("INSERT INTO child_def VALUES (10, 1);");
    cDefIns.deinit();
    var cNoActIns = try db.exec("INSERT INTO child_noact VALUES (20, 1);");
    cNoActIns.deinit();

    try std.testing.expectError(error.ConstraintViolation, db.exec("DELETE FROM parent WHERE id = 1;"));

    var delChild = try db.exec("DELETE FROM child_noact WHERE id = 20;");
    delChild.deinit();

    var delParent = try db.exec("DELETE FROM parent WHERE id = 1;");
    delParent.deinit();

    var selChildDef = try db.exec("SELECT p_id FROM child_def WHERE id = 10;");
    defer selChildDef.deinit();
    try std.testing.expectEqual(@as(usize, 1), selChildDef.count());
    try std.testing.expectEqual(@as(i64, 999), selChildDef.rows[0][0].integer);
}

test "ALTER TABLE operations cascade and preserve constraints" {
    const path = "sqlite_zig_alter_cascade_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var srcTbl = try db.exec("CREATE TABLE alt_src (id INT PRIMARY KEY, val INT);");
    srcTbl.deinit();
    var srcIns = try db.exec("INSERT INTO alt_src VALUES (1, 10);");
    srcIns.deinit();

    var addCol = try db.exec("ALTER TABLE alt_src ADD COLUMN score INT DEFAULT 50 CHECK (score >= 0);");
    addCol.deinit();

    var selScore = try db.exec("SELECT score FROM alt_src WHERE id = 1;");
    defer selScore.deinit();
    try std.testing.expectEqual(@as(usize, 1), selScore.count());
    try std.testing.expectEqual(@as(i64, 50), selScore.rows[0][0].integer);

    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO alt_src VALUES (2, 20, -1);"));

    var idx = try db.exec("CREATE INDEX idx_alt ON alt_src (val);");
    idx.deinit();

    var renTbl = try db.exec("ALTER TABLE alt_src RENAME TO alt_renamed;");
    renTbl.deinit();

    var selRen = try db.exec("SELECT val FROM alt_renamed WHERE id = 1;");
    defer selRen.deinit();
    try std.testing.expectEqual(@as(usize, 1), selRen.count());
    try std.testing.expectEqual(@as(i64, 10), selRen.rows[0][0].integer);

    var renCol = try db.exec("ALTER TABLE alt_renamed RENAME COLUMN val TO amount;");
    renCol.deinit();

    var selCol = try db.exec("SELECT amount FROM alt_renamed WHERE id = 1;");
    defer selCol.deinit();
    try std.testing.expectEqual(@as(usize, 1), selCol.count());
    try std.testing.expectEqual(@as(i64, 10), selCol.rows[0][0].integer);

    try std.testing.expectError(error.ConstraintViolation, db.exec("ALTER TABLE alt_renamed DROP COLUMN amount;"));

    var dropIdx = try db.exec("DROP INDEX idx_alt;");
    dropIdx.deinit();

    var dropCol = try db.exec("ALTER TABLE alt_renamed DROP COLUMN amount;");
    dropCol.deinit();

    var selFinal = try db.exec("SELECT id, score FROM alt_renamed WHERE id = 1;");
    defer selFinal.deinit();
    try std.testing.expectEqual(@as(usize, 1), selFinal.count());
    try std.testing.expectEqual(@as(i64, 1), selFinal.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 50), selFinal.rows[0][1].integer);
}

test "Phase 7: scalar functions" {
    const path = "sqlite_zig_phase7_scalar_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var res1 = try db.exec("SELECT trim('  hello  '), ltrim('  hello'), rtrim('hello  ');");
    defer res1.deinit();
    try std.testing.expectEqualStrings("hello", res1.rows[0][0].text);
    try std.testing.expectEqualStrings("hello", res1.rows[0][1].text);
    try std.testing.expectEqualStrings("hello", res1.rows[0][2].text);

    var res2 = try db.exec("SELECT trim('***hello***', '*');");
    defer res2.deinit();
    try std.testing.expectEqualStrings("hello", res2.at(0)[0].text);

    var res3 = try db.exec("SELECT substr('hello world', 1, 5), substr('hello world', 7);");
    defer res3.deinit();
    try std.testing.expectEqualStrings("hello", res3.rows[0][0].text);
    try std.testing.expectEqualStrings("world", res3.rows[0][1].text);

    var res4 = try db.exec("SELECT replace('hello world', 'world', 'zig');");
    defer res4.deinit();
    try std.testing.expectEqualStrings("hello zig", res4.rows[0][0].text);

    var res5 = try db.exec("SELECT instr('hello world', 'world');");
    defer res5.deinit();
    try std.testing.expectEqual(@as(i64, 7), res5.rows[0][0].integer);

    var res6 = try db.exec("SELECT quote('hello'), quote(42), quote(null);");
    defer res6.deinit();
    try std.testing.expectEqualStrings("'hello'", res6.rows[0][0].text);
    try std.testing.expectEqualStrings("42", res6.rows[0][1].text);
    try std.testing.expectEqualStrings("NULL", res6.rows[0][2].text);

    var res7 = try db.exec("SELECT char(65, 66, 67), unicode('A');");
    defer res7.deinit();
    try std.testing.expectEqualStrings("ABC", res7.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 65), res7.rows[0][1].integer);

    var res8 = try db.exec("SELECT hex('ABC'), unhex('414243');");
    defer res8.deinit();
    try std.testing.expectEqualStrings("414243", res8.rows[0][0].text);
    try std.testing.expectEqualStrings("ABC", res8.rows[0][1].blob);

    var res9 = try db.exec("SELECT printf('Hello %s, score: %d', 'Alice', 100);");
    defer res9.deinit();
    try std.testing.expectEqualStrings("Hello Alice, score: 100", res9.rows[0][0].text);
}

test "Phase 7: math functions" {
    const path = "sqlite_zig_phase7_math_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var res1 = try db.exec("SELECT ceil(4.2), floor(4.8), trunc(4.8);");
    defer res1.deinit();
    try std.testing.expectEqual(@as(f64, 5.0), res1.rows[0][0].real);
    try std.testing.expectEqual(@as(f64, 4.0), res1.rows[0][1].real);
    try std.testing.expectEqual(@as(f64, 4.0), res1.rows[0][2].real);

    var res2 = try db.exec("SELECT round(sqrt(16.0), 1), round(pow(2.0, 3.0), 1);");
    defer res2.deinit();
    try std.testing.expectEqual(@as(f64, 4.0), res2.at(0)[0].real);
    try std.testing.expectEqual(@as(f64, 8.0), res2.at(0)[1].real);

    var res3 = try db.exec("SELECT round(pi(), 4);");
    defer res3.deinit();
    try std.testing.expectEqual(@as(f64, 3.1416), res3.rows[0][0].real);

    var res4 = try db.exec("SELECT round(ln(2.718281828459045), 1), round(log10(100.0), 1), round(log2(8.0), 1);");
    defer res4.deinit();
    try std.testing.expectEqual(@as(f64, 1.0), res4.rows[0][0].real);
    try std.testing.expectEqual(@as(f64, 2.0), res4.rows[0][1].real);
    try std.testing.expectEqual(@as(f64, 3.0), res4.rows[0][2].real);

    var res5 = try db.exec("SELECT round(sin(0.0), 1), round(cos(0.0), 1);");
    defer res5.deinit();
    try std.testing.expectEqual(@as(f64, 0.0), res5.rows[0][0].real);
    try std.testing.expectEqual(@as(f64, 1.0), res5.rows[0][1].real);
}

test "Phase 7: date and time functions" {
    const path = "sqlite_zig_phase7_datetime_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var res1 = try db.exec("SELECT date('2024-05-15', '+1 day'), date('2024-05-15', '-1 month');");
    defer res1.deinit();
    try std.testing.expectEqualStrings("2024-05-16", res1.rows[0][0].text);
    try std.testing.expectEqualStrings("2024-04-15", res1.rows[0][1].text);

    var res2 = try db.exec("SELECT date('2024-05-15', 'start of month'), date('2024-05-15', 'start of year');");
    defer res2.deinit();
    try std.testing.expectEqualStrings("2024-05-01", res2.at(0)[0].text);
    try std.testing.expectEqualStrings("2024-01-01", res2.at(0)[1].text);

    var res3 = try db.exec("SELECT time('12:34:56', '+10 minutes');");
    defer res3.deinit();
    try std.testing.expectEqualStrings("12:44:56", res3.rows[0][0].text);

    var res4 = try db.exec("SELECT datetime('2024-05-15 12:00:00', '+2 hours');");
    defer res4.deinit();
    try std.testing.expectEqualStrings("2024-05-15 14:00:00", res4.rows[0][0].text);

    var res5 = try db.exec("SELECT strftime('%Y/%m/%d', '2024-05-15');");
    defer res5.deinit();
    try std.testing.expectEqualStrings("2024/05/15", res5.rows[0][0].text);

    var res6 = try db.exec("SELECT unixepoch('1970-01-01 00:00:00');");
    defer res6.deinit();
    try std.testing.expectEqual(@as(i64, 0), res6.rows[0][0].integer);
}

test "Phase 7: json functions" {
    const path = "sqlite_zig_phase7_json_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var res1 = try db.exec("SELECT json_valid('{\"a\":1}'), json_valid('invalid');");
    defer res1.deinit();
    try std.testing.expectEqual(@as(i64, 1), res1.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), res1.rows[0][1].integer);

    var res2 = try db.exec("SELECT json_type('{\"a\":1}'), json_type('[1,2]'), json_type('123'), json_type('\"abc\"');");
    defer res2.deinit();
    try std.testing.expectEqualStrings("object", res2.at(0)[0].text);
    try std.testing.expectEqualStrings("array", res2.at(0)[1].text);
    try std.testing.expectEqualStrings("integer", res2.at(0)[2].text);
    try std.testing.expectEqualStrings("text", res2.at(0)[3].text);

    var res3 = try db.exec("SELECT json_extract('{\"name\":\"Alice\",\"age\":30}', '$.name'), json_extract('{\"name\":\"Alice\",\"age\":30}', '$.age');");
    defer res3.deinit();
    try std.testing.expectEqualStrings("Alice", res3.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 30), res3.rows[0][1].integer);

    var res4 = try db.exec("SELECT json_array(1, 'two', 3);");
    defer res4.deinit();
    try std.testing.expectEqualStrings("[1,\"two\",3]", res4.rows[0][0].text);

    var res5 = try db.exec("SELECT json_object('a', 1, 'b', 'two');");
    defer res5.deinit();
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":\"two\"}", res5.rows[0][0].text);

    var res6 = try db.exec("SELECT json_set('{\"a\":1}', '$.b', 2);");
    defer res6.deinit();
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}", res6.rows[0][0].text);

    var res7 = try db.exec("SELECT json_replace('{\"a\":1}', '$.a', 99);");
    defer res7.deinit();
    try std.testing.expectEqualStrings("{\"a\":99}", res7.rows[0][0].text);

    var res8 = try db.exec("SELECT json_remove('{\"a\":1,\"b\":2}', '$.a');");
    defer res8.deinit();
    try std.testing.expectEqualStrings("{\"b\":2}", res8.rows[0][0].text);
}

test "Phase 7: aggregate functions and distinct" {
    const path = "sqlite_zig_phase7_agg_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var c = try db.exec("CREATE TABLE agg_tbl (grp TEXT, val INT);");
    c.deinit();
    var ins = try db.exec("INSERT INTO agg_tbl VALUES ('a', 10), ('a', 20), ('a', 20), ('b', 5), ('b', 15);");
    ins.deinit();

    var res1 = try db.exec("SELECT count(*), count(distinct val), sum(val), sum(distinct val), total(val), avg(val), min(val), max(val) FROM agg_tbl;");
    defer res1.deinit();
    try std.testing.expectEqual(@as(i64, 5), res1.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 4), res1.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 70), res1.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 50), res1.rows[0][3].integer);
    try std.testing.expectEqual(@as(f64, 70.0), res1.rows[0][4].real);
    try std.testing.expectEqual(@as(f64, 14.0), res1.rows[0][5].real);
    try std.testing.expectEqual(@as(i64, 5), res1.rows[0][6].integer);
    try std.testing.expectEqual(@as(i64, 20), res1.rows[0][7].integer);

    var res2 = try db.exec("SELECT grp, count(*), sum(val) FROM agg_tbl GROUP BY grp;");
    defer res2.deinit();
    try std.testing.expectEqual(@as(usize, 2), res2.count());
    try std.testing.expectEqualStrings("a", res2.at(0)[0].text);
    try std.testing.expectEqual(@as(i64, 3), res2.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 50), res2.at(0)[2].integer);
    try std.testing.expectEqualStrings("b", res2.at(1)[0].text);
    try std.testing.expectEqual(@as(i64, 2), res2.at(1)[1].integer);
    try std.testing.expectEqual(@as(i64, 20), res2.at(1)[2].integer);
}

test "Phase 7: window functions" {
    const path = "sqlite_zig_phase7_win_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);

    var c = try db.exec("CREATE TABLE win_tbl (dept TEXT, emp TEXT, salary INT);");
    c.deinit();
    var ins = try db.exec("INSERT INTO win_tbl VALUES ('HR', 'Alice', 1000), ('HR', 'Bob', 1500), ('IT', 'Charlie', 2000), ('IT', 'Dave', 2000), ('IT', 'Eve', 2500);");
    ins.deinit();

    var res1 = try db.exec("SELECT emp, dept, salary, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary) AS rn, RANK() OVER (PARTITION BY dept ORDER BY salary) AS rk, DENSE_RANK() OVER (PARTITION BY dept ORDER BY salary) AS drk FROM win_tbl;");
    defer res1.deinit();
    try std.testing.expectEqual(@as(usize, 5), res1.count());
    try std.testing.expectEqual(@as(i64, 1), res1.rows[0][3].integer);
    try std.testing.expectEqual(@as(i64, 2), res1.rows[1][3].integer);

    var res2 = try db.exec("SELECT emp, salary, LAG(salary, 1, 0) OVER (ORDER BY salary) AS prev_sal, LEAD(salary, 1, 0) OVER (ORDER BY salary) AS next_sal FROM win_tbl;");
    defer res2.deinit();
    try std.testing.expectEqual(@as(usize, 5), res2.count());
    try std.testing.expectEqual(@as(i64, 0), res2.at(0)[2].integer);
    try std.testing.expectEqual(@as(i64, 1500), res2.at(0)[3].integer);

    var res3 = try db.exec("SELECT emp, salary, SUM(salary) OVER (ORDER BY salary ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS moving_sum FROM win_tbl;");
    defer res3.deinit();
    try std.testing.expectEqual(@as(usize, 5), res3.count());
    try std.testing.expectEqual(@as(i64, 1000), res3.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 2500), res3.rows[1][2].integer);
}

test "dynamic DSL executes through direct AST without SQL round-trip" {
    const path = "sqlite_zig_direct_ast_test.db";
    var db = try freshDb(path);
    const t_db_live = db.table("live");
    const t_db_direct_items = db.table("direct_items");
    defer dropDb(db, path);
    const Item = @import("../dsl/table.zig").table("direct_items", struct { id: i64, label: ?[]const u8, stock: i64 });
    const Tag = @import("../dsl/table.zig").table("direct_tags", struct { id: i64, item_id: i64 });
    try db.createTable(Item, .{});
    try db.createTable(Tag, .{});
    var setup = try db.exec("INSERT INTO direct_items VALUES (1, 'alpha', 5), (2, 'beta', 0), (3, NULL, 9), (4, 'alpine', 5); INSERT INTO direct_tags VALUES (10, 1), (11, 1), (12, 99);");
    setup.deinit();

    var mark = db.parseCount;
    var like = try t_db_direct_items.selectAll().where(t_db_direct_items.column("label").like("al%")).orderBy(t_db_direct_items.column("id").asc()).fetch();
    defer like.deinit();
    try std.testing.expectEqual(@as(usize, 2), like.count());
    try std.testing.expectEqual(@as(i64, 1), like.rows[0][0].integer);
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var escaped = try t_db_direct_items.selectAll().where(t_db_direct_items.column("label").likeEscape("al%", "\\")).fetch();
    defer escaped.deinit();
    try std.testing.expectEqual(@as(usize, 2), escaped.count());
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var between = try t_db_direct_items.selectAll().where(t_db_direct_items.column("stock").between(1, 6)).fetch();
    defer between.deinit();
    try std.testing.expectEqual(@as(usize, 2), between.count());
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var inList = try t_db_direct_items.selectAll().whereInValues(Item.id, .{ 1, 3, 4 }).fetch();
    defer inList.deinit();
    try std.testing.expectEqual(@as(usize, 3), inList.count());
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var combo = try db.from(Item).where(Item.stock.gte(5)).andWhere(Item.label.isNotNull()).orWhere(Item.id.eq(2)).orderBy(Item.id.asc()).limit(10).offset(0).fetch();
    defer combo.deinit();
    try std.testing.expectEqual(@as(usize, 3), combo.count());
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var funcs = try t_db_direct_items.select(.{t_db_direct_items.column("label").lower().projection()}).where(t_db_direct_items.column("id").eq(1)).fetch();
    defer funcs.deinit();
    try std.testing.expectEqual(@as(usize, 1), funcs.count());
    try std.testing.expectEqualStrings("alpha", funcs.rows[0][0].text);
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var grouped = try t_db_direct_items.select(.{t_db_direct_items.column("stock")}).groupBy(t_db_direct_items.column("stock")).having(t_db_direct_items.column("stock").count().gt(1)).fetch();
    defer grouped.deinit();
    try std.testing.expectEqual(@as(usize, 1), grouped.count());
    try std.testing.expectEqual(@as(i64, 5), grouped.rows[0][0].integer);
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var joined = try db.from(Item).innerJoin(Tag, Item.id.eq(Tag.item_id)).fetch();
    defer joined.deinit();
    try std.testing.expectEqual(@as(usize, 2), joined.count());
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var inSub = try db.from(Item).whereInQuery(Item.id, Tag, Tag.item_id).fetch();
    defer inSub.deinit();
    try std.testing.expectEqual(@as(usize, 1), inSub.count());
    try std.testing.expectEqual(@as(i64, 1), inSub.rows[0].id);
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var exists = try db.from(Item).whereExists(Tag, Tag.item_id.eq(Item.id)).fetch();
    defer exists.deinit();
    try std.testing.expectEqual(@as(usize, 1), exists.count());
    try std.testing.expectEqual(@as(i64, 1), exists.rows[0].id);
    try std.testing.expectEqual(mark, db.parseCount);

    mark = db.parseCount;
    var inserted = try db.from(Item).insert(.{ .id = 5, .label = "gamma", .stock = 3 });
    inserted.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var rawSeen = try db.exec("SELECT stock FROM direct_items WHERE id = 5;");
    defer rawSeen.deinit();
    try std.testing.expectEqual(@as(i64, 3), rawSeen.rows[0][0].integer);

    mark = db.parseCount;
    var pending = try db.from(Item).update(.{ .stock = 8 });
    var updated = try pending.where(Item.id.eq(5)).execute();
    updated.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var rawUpdated = try db.exec("SELECT stock FROM direct_items WHERE id = 5;");
    defer rawUpdated.deinit();
    try std.testing.expectEqual(@as(i64, 8), rawUpdated.rows[0][0].integer);

    mark = db.parseCount;
    var gone = try db.from(Item).delete().where(Item.id.eq(5)).execute();
    gone.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var rawGone = try db.exec("SELECT count(*) FROM direct_items;");
    defer rawGone.deinit();
    try std.testing.expectEqual(@as(i64, 4), rawGone.rows[0][0].integer);

    var cte = try t_db_live.with("live", "SELECT id, label FROM direct_items WHERE stock >= 5").orderBy(t_db_live.column("id").asc()).fetch();
    defer cte.deinit();
    try std.testing.expectEqual(@as(usize, 3), cte.count());
    try std.testing.expectEqual(@as(i64, 1), cte.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 4), cte.rows[2][0].integer);
}

test "derived tables materialize, filter, and aggregate" {
    const path = "sqlite_zig_derived_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE d_base (id INTEGER, grp TEXT, amount INTEGER); INSERT INTO d_base VALUES (1, 'a', 10), (2, 'b', 20), (3, 'a', 30), (4, 'b', 40);");
    setup.deinit();

    var aliased = try db.exec("SELECT id FROM (SELECT id, amount FROM d_base WHERE amount >= 20) AS big ORDER BY id;");
    defer aliased.deinit();
    try std.testing.expectEqual(@as(usize, 3), aliased.count());
    try std.testing.expectEqual(@as(i64, 2), aliased.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 4), aliased.rows[2][0].integer);

    var bare = try db.exec("SELECT count(*) FROM (SELECT id FROM d_base);");
    defer bare.deinit();
    try std.testing.expectEqual(@as(i64, 4), bare.rows[0][0].integer);

    var paged = try db.exec("SELECT id FROM (SELECT id FROM d_base ORDER BY id) LIMIT 2 OFFSET 1;");
    defer paged.deinit();
    try std.testing.expectEqual(@as(usize, 2), paged.count());
    try std.testing.expectEqual(@as(i64, 2), paged.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 3), paged.rows[1][0].integer);

    var grouped = try db.exec("SELECT grp, SUM(amount) FROM (SELECT grp, amount FROM d_base) GROUP BY grp HAVING COUNT(*) > 1 ORDER BY grp;");
    defer grouped.deinit();
    try std.testing.expectEqual(@as(usize, 2), grouped.count());
    try std.testing.expectEqualStrings("a", grouped.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 40), grouped.rows[0][1].integer);
    try std.testing.expectEqualStrings("b", grouped.rows[1][0].text);
    try std.testing.expectEqual(@as(i64, 60), grouped.rows[1][1].integer);

    var distinct = try db.exec("SELECT DISTINCT grp FROM (SELECT grp FROM d_base) ORDER BY grp;");
    defer distinct.deinit();
    try std.testing.expectEqual(@as(usize, 2), distinct.count());

    var nested = try db.exec("SELECT id FROM (SELECT id FROM (SELECT id FROM d_base WHERE amount > 10) AS inner_d WHERE id < 4) AS outer_d ORDER BY id;");
    defer nested.deinit();
    try std.testing.expectEqual(@as(usize, 2), nested.count());
    try std.testing.expectEqual(@as(i64, 2), nested.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 3), nested.rows[1][0].integer);

    var overJoin = try db.exec("SELECT a.id FROM (SELECT id FROM d_base WHERE grp = 'a') AS a JOIN d_base ON a.id = d_base.id ORDER BY a.id;");
    defer overJoin.deinit();
    try std.testing.expectEqual(@as(usize, 2), overJoin.count());

    var overCte = try db.exec("WITH vals AS (SELECT id FROM d_base WHERE amount >= 30) SELECT id FROM (SELECT id FROM vals) AS v ORDER BY id;");
    defer overCte.deinit();
    try std.testing.expectEqual(@as(usize, 2), overCte.count());
    try std.testing.expectEqual(@as(i64, 3), overCte.rows[0][0].integer);

    var copied = try db.exec("CREATE TABLE d_copy (id INTEGER, amount INTEGER); INSERT INTO d_copy SELECT id, amount FROM (SELECT id, amount FROM d_base WHERE grp = 'b');");
    copied.deinit();
    var checkCopy = try db.exec("SELECT SUM(amount) FROM d_copy;");
    defer checkCopy.deinit();
    try std.testing.expectEqual(@as(i64, 60), checkCopy.rows[0][0].integer);

    var empty = try db.exec("SELECT count(*) FROM (SELECT id FROM d_base WHERE amount > 1000) AS nothing;");
    defer empty.deinit();
    try std.testing.expectEqual(@as(i64, 0), empty.rows[0][0].integer);
}

test "derived table aliases never destroy real tables" {
    const path = "sqlite_zig_derived_shadow_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE users (id INTEGER, name TEXT); INSERT INTO users VALUES (1, 'Ada'), (2, 'Bob');");
    setup.deinit();

    var shadowed = try db.exec("SELECT id FROM (SELECT 7 AS id) AS users ORDER BY id;");
    defer shadowed.deinit();
    try std.testing.expectEqual(@as(usize, 1), shadowed.count());
    try std.testing.expectEqual(@as(i64, 7), shadowed.rows[0][0].integer);

    var intact = try db.exec("SELECT id, name FROM users ORDER BY id;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(usize, 2), intact.count());
    try std.testing.expectEqual(@as(i64, 1), intact.rows[0][0].integer);
    try std.testing.expectEqualStrings("Ada", intact.rows[0][1].text);
    try std.testing.expectEqual(@as(i64, 2), intact.rows[1][0].integer);
    try std.testing.expectEqualStrings("Bob", intact.rows[1][1].text);

    var shadowAgain = try db.exec("SELECT count(*) FROM (SELECT id FROM users) AS users;");
    defer shadowAgain.deinit();
    try std.testing.expectEqual(@as(i64, 2), shadowAgain.rows[0][0].integer);

    var stillIntact = try db.exec("SELECT count(*) FROM users;");
    defer stillIntact.deinit();
    try std.testing.expectEqual(@as(i64, 2), stillIntact.rows[0][0].integer);

    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var persisted = try db.exec("SELECT count(*) FROM users;");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(i64, 2), persisted.at(0)[0].integer);
}

test "joins support order by with grouping and pagination" {
    const path = "sqlite_zig_join_order_test.db";
    var db = try freshDb(path);
    const t_db_jo_a = db.table("jo_a");
    const t_db_jo_b = db.table("jo_b");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE jo_a (id INTEGER, name TEXT); CREATE TABLE jo_b (id INTEGER, aid INTEGER); INSERT INTO jo_a VALUES (2, 'Beta'), (1, 'Alpha'); INSERT INTO jo_b VALUES (10, 1), (11, 2);");
    setup.deinit();

    var asc = try db.exec("SELECT jo_a.name FROM jo_a JOIN jo_b ON jo_a.id = jo_b.aid ORDER BY jo_a.name;");
    defer asc.deinit();
    try std.testing.expectEqual(@as(usize, 2), asc.count());
    try std.testing.expectEqualStrings("Alpha", asc.rows[0][0].text);
    try std.testing.expectEqualStrings("Beta", asc.rows[1][0].text);

    var desc = try db.exec("SELECT jo_a.id FROM jo_a JOIN jo_b ON jo_a.id = jo_b.aid ORDER BY jo_a.id DESC;");
    defer desc.deinit();
    try std.testing.expectEqual(@as(i64, 2), desc.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 1), desc.rows[1][0].integer);

    var dynOrdered = try t_db_jo_a.innerJoin(t_db_jo_b, t_db_jo_a.column("id").eq(t_db_jo_b.column("aid"))).orderBy(t_db_jo_a.column("name").asc()).fetch();
    defer dynOrdered.deinit();
    try std.testing.expectEqual(@as(usize, 2), dynOrdered.count());

    var grouped = try db.exec("SELECT jo_a.id, count(*) FROM jo_a JOIN jo_b ON jo_a.id = jo_b.aid GROUP BY jo_a.id ORDER BY jo_a.id;");
    defer grouped.deinit();
    try std.testing.expectEqual(@as(usize, 2), grouped.count());
    try std.testing.expectEqual(@as(i64, 1), grouped.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 1), grouped.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 2), grouped.rows[1][0].integer);

    var paged = try db.exec("SELECT jo_a.id FROM jo_a JOIN jo_b ON jo_a.id = jo_b.aid ORDER BY jo_a.id LIMIT 1;");
    defer paged.deinit();
    try std.testing.expectEqual(@as(usize, 1), paged.count());
    try std.testing.expectEqual(@as(i64, 1), paged.rows[0][0].integer);

    try std.testing.expectError(error.UnknownColumn, db.exec("SELECT jo_a.id FROM jo_a JOIN jo_b ON jo_a.id = jo_b.aid ORDER BY missing_col;"));

    var intact = try db.exec("SELECT count(*) FROM jo_a;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(i64, 2), intact.rows[0][0].integer);
}

test "joins support where, group by, having, and pagination" {
    const path = "sqlite_zig_join_clauses_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE jw_users (id INTEGER, name TEXT, dept TEXT); CREATE TABLE jw_orders (id INTEGER, uid INTEGER, amount REAL); INSERT INTO jw_users VALUES (1, 'ann', 'eng'), (2, 'bob', 'ops'), (3, 'cat', 'eng'), (4, 'dan', 'ops'); INSERT INTO jw_orders VALUES (10, 1, 5.0), (11, 1, 7.0), (12, 2, 3.0), (13, 9, 9.0);");
    setup.deinit();

    var filtered = try db.exec("SELECT name, amount FROM jw_users JOIN jw_orders ON jw_users.id = jw_orders.uid WHERE amount > 4.0 ORDER BY amount;");
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 2), filtered.count());
    try std.testing.expectEqualStrings("ann", filtered.rows[0][0].text);
    try std.testing.expectEqual(@as(f64, 5.0), filtered.rows[0][1].real);
    try std.testing.expectEqual(@as(f64, 7.0), filtered.rows[1][1].real);

    var deptFiltered = try db.exec("SELECT name FROM jw_users JOIN jw_orders ON id = uid WHERE dept = 'eng' ORDER BY amount;");
    defer deptFiltered.deinit();
    try std.testing.expectEqual(@as(usize, 2), deptFiltered.count());
    try std.testing.expectEqualStrings("ann", deptFiltered.rows[0][0].text);

    var unmatched = try db.exec("SELECT name FROM jw_users LEFT JOIN jw_orders ON id = uid WHERE amount IS NULL ORDER BY name;");
    defer unmatched.deinit();
    try std.testing.expectEqual(@as(usize, 2), unmatched.count());
    try std.testing.expectEqualStrings("cat", unmatched.rows[0][0].text);
    try std.testing.expectEqualStrings("dan", unmatched.rows[1][0].text);

    var computed = try db.exec("SELECT name, amount * 2 AS dbl FROM jw_users JOIN jw_orders ON id = uid WHERE uid = 1 ORDER BY amount;");
    defer computed.deinit();
    try std.testing.expectEqual(@as(usize, 2), computed.count());
    try std.testing.expectEqualStrings("dbl", computed.columns[1]);
    try std.testing.expectEqual(@as(f64, 10.0), computed.rows[0][1].real);
    try std.testing.expectEqual(@as(f64, 14.0), computed.rows[1][1].real);

    var counted = try db.exec("SELECT count(*) FROM jw_users JOIN jw_orders ON id = uid WHERE dept = 'ops';");
    defer counted.deinit();
    try std.testing.expectEqual(@as(i64, 1), counted.rows[0][0].integer);

    var totals = try db.exec("SELECT sum(amount), avg(amount), min(amount), max(amount) FROM jw_users JOIN jw_orders ON id = uid;");
    defer totals.deinit();
    try std.testing.expectEqual(@as(f64, 15.0), totals.rows[0][0].real);
    try std.testing.expectEqual(@as(f64, 5.0), totals.rows[0][1].real);
    try std.testing.expectEqual(@as(f64, 3.0), totals.rows[0][2].real);
    try std.testing.expectEqual(@as(f64, 7.0), totals.rows[0][3].real);

    var grouped = try db.exec("SELECT dept, count(*), sum(amount) FROM jw_users JOIN jw_orders ON id = uid GROUP BY dept ORDER BY dept;");
    defer grouped.deinit();
    try std.testing.expectEqual(@as(usize, 2), grouped.count());
    try std.testing.expectEqualStrings("eng", grouped.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 2), grouped.rows[0][1].integer);
    try std.testing.expectEqual(@as(f64, 12.0), grouped.rows[0][2].real);
    try std.testing.expectEqualStrings("ops", grouped.rows[1][0].text);
    try std.testing.expectEqual(@as(i64, 1), grouped.rows[1][1].integer);

    var qualifiedGrouped = try db.exec("SELECT jw_users.dept, count(*) FROM jw_users JOIN jw_orders ON id = uid GROUP BY jw_users.dept ORDER BY dept;");
    defer qualifiedGrouped.deinit();
    try std.testing.expectEqual(@as(usize, 2), qualifiedGrouped.count());
    try std.testing.expectEqualStrings("eng", qualifiedGrouped.rows[0][0].text);

    var having = try db.exec("SELECT dept, count(*) AS n FROM jw_users JOIN jw_orders ON id = uid GROUP BY dept HAVING count(*) > 1;");
    defer having.deinit();
    try std.testing.expectEqual(@as(usize, 1), having.count());
    try std.testing.expectEqualStrings("eng", having.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 2), having.rows[0][1].integer);

    var havingSum = try db.exec("SELECT dept FROM jw_users JOIN jw_orders ON id = uid GROUP BY dept HAVING sum(amount) > 10;");
    defer havingSum.deinit();
    try std.testing.expectEqual(@as(usize, 1), havingSum.count());
    try std.testing.expectEqualStrings("eng", havingSum.rows[0][0].text);

    var paged = try db.exec("SELECT name FROM jw_users JOIN jw_orders ON id = uid ORDER BY name LIMIT 2 OFFSET 1;");
    defer paged.deinit();
    try std.testing.expectEqual(@as(usize, 2), paged.count());
    try std.testing.expectEqualStrings("ann", paged.rows[0][0].text);
    try std.testing.expectEqualStrings("bob", paged.rows[1][0].text);

    var outerGrouped = try db.exec("SELECT dept, count(*) FROM jw_users LEFT JOIN jw_orders ON id = uid GROUP BY dept ORDER BY dept;");
    defer outerGrouped.deinit();
    try std.testing.expectEqual(@as(usize, 2), outerGrouped.count());
    try std.testing.expectEqual(@as(i64, 3), outerGrouped.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 2), outerGrouped.rows[1][1].integer);

    var rightWhere = try db.exec("SELECT name, amount FROM jw_users RIGHT JOIN jw_orders ON id = uid WHERE amount > 8.0;");
    defer rightWhere.deinit();
    try std.testing.expectEqual(@as(usize, 1), rightWhere.count());
    try std.testing.expect(rightWhere.rows[0][0] == .null);
    try std.testing.expectEqual(@as(f64, 9.0), rightWhere.rows[0][1].real);

    var usingSetup = try db.exec("CREATE TABLE mu_a (id INTEGER, v TEXT); CREATE TABLE mu_b (id INTEGER, w TEXT); INSERT INTO mu_a VALUES (1, 'a1'), (2, 'a2'); INSERT INTO mu_b VALUES (1, 'b1'), (1, 'b1x');");
    usingSetup.deinit();
    var usingGrouped = try db.exec("SELECT id, count(*) FROM mu_a JOIN mu_b USING (id) GROUP BY id ORDER BY id;");
    defer usingGrouped.deinit();
    try std.testing.expectEqual(@as(usize, 1), usingGrouped.count());
    try std.testing.expectEqual(@as(i64, 1), usingGrouped.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), usingGrouped.rows[0][1].integer);

    try std.testing.expectError(error.UnknownColumn, db.exec("SELECT name FROM jw_users JOIN jw_orders ON id = uid WHERE nope = 1;"));
    try std.testing.expectError(error.Unsupported, db.exec("SELECT jw_orders.dept, count(*) FROM jw_users JOIN jw_orders ON id = uid GROUP BY dept;"));
    var stateIntact = try db.exec("SELECT count(*) FROM jw_orders;");
    defer stateIntact.deinit();
    try std.testing.expectEqual(@as(i64, 4), stateIntact.rows[0][0].integer);

    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var reopened = try db.exec("SELECT dept, sum(amount) FROM jw_users JOIN jw_orders ON id = uid GROUP BY dept ORDER BY dept;");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.count());
    try std.testing.expectEqual(@as(f64, 12.0), reopened.rows[0][1].real);
    try std.testing.expectEqual(@as(f64, 3.0), reopened.rows[1][1].real);
}

test "multi-table joins chain across three tables" {
    const path = "sqlite_zig_join_chain_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE c_users (id INTEGER, name TEXT); CREATE TABLE c_orders (id INTEGER, uid INTEGER, item TEXT); CREATE TABLE c_items (name TEXT, price REAL); INSERT INTO c_users VALUES (1, 'ann'), (2, 'bob'), (3, 'cat'); INSERT INTO c_orders VALUES (10, 1, 'book'), (11, 1, 'pen'), (12, 2, 'desk'), (13, 3, 'qux'), (14, 9, 'book'); INSERT INTO c_items VALUES ('book', 9.5), ('pen', 1.5), ('desk', 50.0);");
    setup.deinit();

    var chained = try db.exec("SELECT u.name, o.id, i.price FROM c_users u JOIN c_orders o ON u.id = o.uid JOIN c_items i ON o.item = i.name ORDER BY o.id;");
    defer chained.deinit();
    try std.testing.expectEqual(@as(usize, 3), chained.count());
    try std.testing.expectEqualStrings("ann", chained.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 10), chained.rows[0][1].integer);
    try std.testing.expectEqual(@as(f64, 9.5), chained.rows[0][2].real);
    try std.testing.expectEqual(@as(i64, 11), chained.rows[1][1].integer);
    try std.testing.expectEqualStrings("bob", chained.rows[2][0].text);
    try std.testing.expectEqual(@as(f64, 50.0), chained.rows[2][2].real);

    var leftChain = try db.exec("SELECT u.name, o.id FROM c_users u LEFT JOIN c_orders o ON u.id = o.uid LEFT JOIN c_items i ON o.item = i.name ORDER BY o.id;");
    defer leftChain.deinit();
    try std.testing.expectEqual(@as(usize, 4), leftChain.count());
    try std.testing.expectEqualStrings("ann", leftChain.at(0)[0].text);
    try std.testing.expectEqual(@as(i64, 10), leftChain.at(0)[1].integer);
    try std.testing.expectEqualStrings("cat", leftChain.at(3)[0].text);
    try std.testing.expectEqual(@as(i64, 13), leftChain.at(3)[1].integer);

    var filteredChain = try db.exec("SELECT u.name, o.id, i.price FROM c_users u JOIN c_orders o ON u.id = o.uid LEFT JOIN c_items i ON o.item = i.name WHERE i.price IS NULL ORDER BY o.id;");
    defer filteredChain.deinit();
    try std.testing.expectEqual(@as(usize, 1), filteredChain.count());
    try std.testing.expectEqualStrings("cat", filteredChain.at(0)[0].text);
    try std.testing.expectEqual(@as(i64, 13), filteredChain.at(0)[1].integer);
    try std.testing.expect(filteredChain.at(0)[2] == .null);

    var groupedChain = try db.exec("SELECT u.name, count(*), sum(i.price) FROM c_users u JOIN c_orders o ON u.id = o.uid JOIN c_items i ON o.item = i.name GROUP BY u.name ORDER BY u.name;");
    defer groupedChain.deinit();
    try std.testing.expectEqual(@as(usize, 2), groupedChain.count());
    try std.testing.expectEqualStrings("ann", groupedChain.at(0)[0].text);
    try std.testing.expectEqual(@as(i64, 2), groupedChain.at(0)[1].integer);
    try std.testing.expectEqual(@as(f64, 11.0), groupedChain.at(0)[2].real);
    try std.testing.expectEqualStrings("bob", groupedChain.at(1)[0].text);
    try std.testing.expectEqual(@as(f64, 50.0), groupedChain.at(1)[2].real);

    var outerGroupedChain = try db.exec("SELECT u.name, count(*) FROM c_users u LEFT JOIN c_orders o ON u.id = o.uid LEFT JOIN c_items i ON o.item = i.name GROUP BY u.name ORDER BY u.name;");
    defer outerGroupedChain.deinit();
    try std.testing.expectEqual(@as(usize, 3), outerGroupedChain.count());
    try std.testing.expectEqual(@as(i64, 2), outerGroupedChain.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 1), outerGroupedChain.at(1)[1].integer);
    try std.testing.expectEqual(@as(i64, 1), outerGroupedChain.at(2)[1].integer);

    var whereChain = try db.exec("SELECT u.name FROM c_users u JOIN c_orders o ON u.id = o.uid JOIN c_items i ON o.item = i.name WHERE i.price > 5.0 ORDER BY u.name;");
    defer whereChain.deinit();
    try std.testing.expectEqual(@as(usize, 2), whereChain.count());
    try std.testing.expectEqualStrings("ann", whereChain.at(0)[0].text);
    try std.testing.expectEqualStrings("bob", whereChain.at(1)[0].text);

    var crossChain = try db.exec("SELECT count(*) FROM c_users CROSS JOIN c_orders CROSS JOIN c_items;");
    defer crossChain.deinit();
    try std.testing.expectEqual(@as(i64, 45), crossChain.rows[0][0].integer);

    var rightMiddle = try db.exec("SELECT u.name, o.id, i.price FROM c_orders o JOIN c_items i ON o.item = i.name RIGHT JOIN c_users u ON o.uid = u.id ORDER BY u.id;");
    defer rightMiddle.deinit();
    try std.testing.expectEqual(@as(usize, 4), rightMiddle.count());
    try std.testing.expectEqualStrings("ann", rightMiddle.rows[0][0].text);
    try std.testing.expectEqualStrings("bob", rightMiddle.rows[2][0].text);
    try std.testing.expectEqualStrings("cat", rightMiddle.rows[3][0].text);
    try std.testing.expect(rightMiddle.rows[3][1] == .null);
    try std.testing.expect(rightMiddle.rows[3][2] == .null);

    var usingChain = try db.exec("CREATE TABLE ch_a (id INTEGER, v TEXT); CREATE TABLE ch_b (id INTEGER, w TEXT); CREATE TABLE ch_c (id INTEGER, x TEXT); INSERT INTO ch_a VALUES (1, 'a'), (2, 'b'); INSERT INTO ch_b VALUES (1, 'c'), (2, 'd'); INSERT INTO ch_c VALUES (1, 'e'), (3, 'f');");
    usingChain.deinit();
    var mergedChain = try db.exec("SELECT * FROM ch_a JOIN ch_b USING (id) JOIN ch_c USING (id) ORDER BY id;");
    defer mergedChain.deinit();
    try std.testing.expectEqual(@as(usize, 4), mergedChain.columns.len);
    try std.testing.expectEqualStrings("id", mergedChain.columns[0]);
    try std.testing.expectEqualStrings("v", mergedChain.columns[1]);
    try std.testing.expectEqualStrings("w", mergedChain.columns[2]);
    try std.testing.expectEqualStrings("x", mergedChain.columns[3]);
    try std.testing.expectEqual(@as(usize, 1), mergedChain.count());
    try std.testing.expectEqual(@as(i64, 1), mergedChain.at(0)[0].integer);
    try std.testing.expectEqualStrings("e", mergedChain.at(0)[3].text);

    var outerUsingChain = try db.exec("SELECT id, v, w, x FROM ch_a LEFT JOIN ch_b USING (id) LEFT JOIN ch_c USING (id) ORDER BY id;");
    defer outerUsingChain.deinit();
    try std.testing.expectEqual(@as(usize, 2), outerUsingChain.count());
    try std.testing.expectEqualStrings("e", outerUsingChain.at(0)[3].text);
    try std.testing.expect(outerUsingChain.at(1)[3] == .null);

    var qualifiedUsingChain = try db.exec("SELECT ch_c.id FROM ch_a LEFT JOIN ch_b USING (id) LEFT JOIN ch_c USING (id) ORDER BY ch_a.id;");
    defer qualifiedUsingChain.deinit();
    try std.testing.expectEqual(@as(usize, 2), qualifiedUsingChain.count());
    try std.testing.expectEqual(@as(i64, 1), qualifiedUsingChain.at(0)[0].integer);
    try std.testing.expect(qualifiedUsingChain.at(1)[0] == .null);

    var groupedUsingChain = try db.exec("SELECT id, count(*) FROM ch_a JOIN ch_b USING (id) JOIN ch_c USING (id) GROUP BY id;");
    defer groupedUsingChain.deinit();
    try std.testing.expectEqual(@as(usize, 1), groupedUsingChain.count());
    try std.testing.expectEqual(@as(i64, 1), groupedUsingChain.at(0)[0].integer);
    try std.testing.expectEqual(@as(i64, 1), groupedUsingChain.at(0)[1].integer);

    try std.testing.expectError(error.UnknownTable, db.exec("SELECT * FROM c_users JOIN c_orders ON c_users.id = c_orders.uid JOIN missing ON c_orders.id = missing.id;"));
    try std.testing.expectError(error.UnknownColumn, db.exec("SELECT * FROM c_users JOIN c_orders ON c_users.id = c_orders.uid JOIN c_items ON nope = c_items.name;"));
    var stateIntact = try db.exec("SELECT count(*) FROM c_orders;");
    defer stateIntact.deinit();
    try std.testing.expectEqual(@as(i64, 5), stateIntact.rows[0][0].integer);

    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var reopenedChain = try db.exec("SELECT u.name, i.price FROM c_users u JOIN c_orders o ON u.id = o.uid JOIN c_items i ON o.item = i.name ORDER BY o.id;");
    defer reopenedChain.deinit();
    try std.testing.expectEqual(@as(usize, 3), reopenedChain.count());
    try std.testing.expectEqual(@as(f64, 9.5), reopenedChain.at(0)[1].real);
}

test "derived table errors leave state unchanged" {
    const path = "sqlite_zig_derived_error_test.db";
    var db = try freshDb(path);
    const t_db_e_base = db.table("e_base");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE e_base (id INTEGER, v INTEGER); INSERT INTO e_base VALUES (1, 10), (2, 20);");
    setup.deinit();

    try std.testing.expectError(error.UnknownColumn, db.exec("SELECT nope FROM (SELECT id FROM e_base) AS sub;"));
    try std.testing.expectError(error.UnknownColumn, db.exec("SELECT * FROM (SELECT id FROM e_base WHERE e_base.v = missing.v) AS sub;"));

    var intact = try db.exec("SELECT count(*) FROM e_base;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(i64, 2), intact.rows[0][0].integer);

    var dslInserted = try t_db_e_base.insert(.{ .id = 3, .v = 30 });
    dslInserted.deinit();
    var derivedSeesDsl = try db.exec("SELECT SUM(v) FROM (SELECT v FROM e_base);");
    defer derivedSeesDsl.deinit();
    try std.testing.expectEqual(@as(i64, 60), derivedSeesDsl.rows[0][0].integer);
}

test "dynamic and typed DSL support returning on insert, update, and delete" {
    const path = "sqlite_zig_dsl_returning_test.db";
    var db = try freshDb(path);
    const t_db_ret_items = db.table("ret_items");
    defer dropDb(db, path);
    const Item = @import("../dsl/table.zig").table("ret_items", struct { id: i64, label: []const u8, stock: i64 });
    try db.createTable(Item, .{ .primaryKey = Item.id });

    var mark = db.parseCount;
    var inserted = try db.from(Item).returning(.{ Item.id, Item.label }).insert(.{ .id = 1, .label = "alpha", .stock = 5 });
    defer inserted.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), inserted.count());
    try std.testing.expectEqual(@as(i64, 1), inserted.rows[0][0].integer);
    try std.testing.expectEqualStrings("alpha", inserted.rows[0][1].text);

    mark = db.parseCount;
    var dynInserted = try t_db_ret_items.returning(.{t_db_ret_items.column("id")}).insert(.{ .id = 2, .label = "beta", .stock = 7 });
    defer dynInserted.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), dynInserted.count());
    try std.testing.expectEqual(@as(i64, 2), dynInserted.rows[0][0].integer);

    mark = db.parseCount;
    var uppered = try db.from(Item).returning(.{Item.label.upper().projection()}).insert(.{ .id = 3, .label = "gamma", .stock = 1 });
    defer uppered.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqualStrings("GAMMA", uppered.rows[0][0].text);

    mark = db.parseCount;
    var skipped = try db.from(Item).returning(.{Item.id}).insertOrIgnore(.{ .id = 1, .label = "dup", .stock = 9 });
    defer skipped.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 0), skipped.count());

    mark = db.parseCount;
    var pending = try db.from(Item).update(.{ .stock = 11 });
    var updated = try pending.where(Item.id.eq(2)).returning(.{ Item.id, Item.stock }).execute();
    defer updated.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), updated.count());
    try std.testing.expectEqual(@as(i64, 2), updated.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 11), updated.rows[0][1].integer);

    mark = db.parseCount;
    var early = try db.from(Item).returning(.{Item.id}).update(.{ .stock = 12 });
    var earlyUpdated = try early.where(Item.id.eq(3)).execute();
    defer earlyUpdated.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), earlyUpdated.count());
    try std.testing.expectEqual(@as(i64, 3), earlyUpdated.rows[0][0].integer);

    mark = db.parseCount;
    var deleted = try db.from(Item).delete().where(Item.id.eq(1)).returning(.{Item.label}).execute();
    defer deleted.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), deleted.count());
    try std.testing.expectEqualStrings("alpha", deleted.rows[0][0].text);

    var remaining = try db.exec("SELECT id FROM ret_items ORDER BY id;");
    defer remaining.deinit();
    try std.testing.expectEqual(@as(usize, 2), remaining.count());
    try std.testing.expectEqual(@as(i64, 2), remaining.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 3), remaining.rows[1][0].integer);

    if (db.from(Item).returning(.{t_db_ret_items.column("missing")}).insert(.{ .id = 9, .label = "bad", .stock = 1 })) |r| {
        var owned = r;
        owned.deinit();
        return error.ReturningErrorNotRaised;
    } else |err| {
        try std.testing.expectEqual(error.UnknownColumn, err);
    }
    var afterBadInsert = try db.exec("SELECT count(*) FROM ret_items;");
    defer afterBadInsert.deinit();
    try std.testing.expectEqual(@as(i64, 2), afterBadInsert.rows[0][0].integer);

    if (db.exec("UPDATE ret_items SET stock = 0 WHERE id = 2 RETURNING missing;")) |r| {
        var owned = r;
        owned.deinit();
        return error.ReturningErrorNotRaised;
    } else |err| {
        try std.testing.expectEqual(error.UnknownColumn, err);
    }
    var afterBadUpdate = try db.exec("SELECT stock FROM ret_items WHERE id = 2;");
    defer afterBadUpdate.deinit();
    try std.testing.expectEqual(@as(i64, 11), afterBadUpdate.rows[0][0].integer);

    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var persisted = try db.exec("SELECT id, stock FROM ret_items ORDER BY id;");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(usize, 2), persisted.count());
    try std.testing.expectEqual(@as(i64, 11), persisted.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 12), persisted.at(1)[1].integer);
}

test "dynamic and typed DSL support upsert with conflict targets" {
    const path = "sqlite_zig_dsl_upsert_test.db";
    var db = try freshDb(path);
    const t_db_up_items = db.table("up_items");
    defer dropDb(db, path);
    const Item = @import("../dsl/table.zig").table("up_items", struct { id: i64, email: []const u8, name: []const u8, stock: i64 });
    try db.createTable(Item, .{ .primaryKey = Item.id, .unique = &.{Item.email} });

    var mark = db.parseCount;
    var firstUp = try db.from(Item).onConflict(Item.email).doUpdate(.{ .name = db.excluded("name"), .stock = db.excluded("stock") });
    var first = try firstUp.insert(.{ .id = 1, .email = "a@x.test", .name = "Ann", .stock = 5 });
    first.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var checkFirst = try db.exec("SELECT name, stock FROM up_items WHERE id = 1;");
    defer checkFirst.deinit();
    try std.testing.expectEqualStrings("Ann", checkFirst.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 5), checkFirst.rows[0][1].integer);

    mark = db.parseCount;
    var conflictUp = try db.from(Item).onConflict(Item.email).doUpdate(.{ .name = db.excluded("name"), .stock = db.excluded("stock") });
    var conflicted = try conflictUp.insert(.{ .id = 2, .email = "a@x.test", .name = "Annie", .stock = 8 });
    conflicted.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var checkConflict = try db.exec("SELECT id, name, stock FROM up_items ORDER BY id;");
    defer checkConflict.deinit();
    try std.testing.expectEqual(@as(usize, 1), checkConflict.count());
    try std.testing.expectEqual(@as(i64, 1), checkConflict.rows[0][0].integer);
    try std.testing.expectEqualStrings("Annie", checkConflict.rows[0][1].text);
    try std.testing.expectEqual(@as(i64, 8), checkConflict.rows[0][2].integer);

    mark = db.parseCount;
    var skipped = try db.from(Item).onConflict(Item.email).doNothing().insert(.{ .id = 3, .email = "a@x.test", .name = "Nope", .stock = 0 });
    skipped.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var checkSkipped = try db.exec("SELECT count(*) FROM up_items;");
    defer checkSkipped.deinit();
    try std.testing.expectEqual(@as(i64, 1), checkSkipped.rows[0][0].integer);

    mark = db.parseCount;
    var dynUpBase = try t_db_up_items.onConflict(t_db_up_items.column("email")).doUpdate(.{ .stock = 42 });
    var dynUp = try dynUpBase.insert(.{ .id = 4, .email = "a@x.test", .name = "Kept", .stock = 0 });
    dynUp.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var checkDyn = try db.exec("SELECT name, stock FROM up_items WHERE email = 'a@x.test';");
    defer checkDyn.deinit();
    try std.testing.expectEqualStrings("Annie", checkDyn.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 42), checkDyn.rows[0][1].integer);

    mark = db.parseCount;
    var filteredBase = try db.from(Item).onConflict(Item.email).doUpdate(.{ .stock = 99 });
    var filteredUp = filteredBase.where(db.excluded("stock").gt(100));
    var filtered = try filteredUp.insert(.{ .id = 5, .email = "a@x.test", .name = "Annie", .stock = 8 });
    filtered.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var checkFiltered = try db.exec("SELECT stock FROM up_items WHERE email = 'a@x.test';");
    defer checkFiltered.deinit();
    try std.testing.expectEqual(@as(i64, 42), checkFiltered.rows[0][0].integer);

    mark = db.parseCount;
    var partialUp = try db.from(Item).onConflict(Item.email).onConflictWhere(Item.stock.gt(100)).doUpdate(.{ .stock = 77 });
    if (partialUp.insert(.{ .id = 6, .email = "a@x.test", .name = "Annie", .stock = 8 })) |r| {
        var owned = r;
        owned.deinit();
        return error.UpsertErrorNotRaised;
    } else |err| {
        try std.testing.expectEqual(error.ConstraintViolation, err);
    }
    try std.testing.expectEqual(mark, db.parseCount);
    var checkPartial = try db.exec("SELECT stock FROM up_items WHERE email = 'a@x.test';");
    defer checkPartial.deinit();
    try std.testing.expectEqual(@as(i64, 42), checkPartial.rows[0][0].integer);

    const Member = @import("../dsl/table.zig").table("up_members", struct { tenant_id: i64, user_id: i64, label: []const u8 });
    try db.createTable(Member, .{ .primaryKey = &.{ Member.tenant_id, Member.user_id } });
    mark = db.parseCount;
    var memFirstUp = try db.from(Member).onConflict(.{ Member.tenant_id, Member.user_id }).doUpdate(.{ .label = db.excluded("label") });
    var memFirst = try memFirstUp.insert(.{ .tenant_id = 1, .user_id = 1, .label = "a" });
    memFirst.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    mark = db.parseCount;
    var memConflictUp = try db.from(Member).onConflict(.{ Member.tenant_id, Member.user_id }).doUpdate(.{ .label = db.excluded("label") });
    var memConflict = try memConflictUp.insert(.{ .tenant_id = 1, .user_id = 1, .label = "b" });
    memConflict.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var checkMem = try db.exec("SELECT label FROM up_members;");
    defer checkMem.deinit();
    try std.testing.expectEqual(@as(usize, 1), checkMem.count());
    try std.testing.expectEqualStrings("b", checkMem.rows[0][0].text);

    mark = db.parseCount;
    var bareNothing = try db.from(Member).doNothing().insert(.{ .tenant_id = 1, .user_id = 1, .label = "c" });
    bareNothing.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var checkBareNothing = try db.exec("SELECT label FROM up_members;");
    defer checkBareNothing.deinit();
    try std.testing.expectEqualStrings("b", checkBareNothing.rows[0][0].text);

    mark = db.parseCount;
    var bareUpdateBase = try db.from(Member).doUpdate(.{ .label = "d" });
    var bareUpdate = try bareUpdateBase.insert(.{ .tenant_id = 1, .user_id = 2, .label = "e" });
    bareUpdate.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var checkBareUpdate = try db.exec("SELECT count(*) FROM up_members;");
    defer checkBareUpdate.deinit();
    try std.testing.expectEqual(@as(i64, 2), checkBareUpdate.rows[0][0].integer);

    mark = db.parseCount;
    var retUpDo = try db.from(Item).onConflict(Item.email).doUpdate(.{ .stock = db.excluded("stock") });
    var retUpBase = retUpDo.returning(.{Item.stock});
    var retUp = try retUpBase.insert(.{ .id = 7, .email = "a@x.test", .name = "Annie", .stock = 55 });
    defer retUp.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), retUp.count());
    try std.testing.expectEqual(@as(i64, 55), retUp.rows[0][0].integer);

    if (db.from(Item).onConflict(Item.email).insert(.{ .id = 8, .email = "a@x.test", .name = "No", .stock = 0 })) |r| {
        var owned = r;
        owned.deinit();
        return error.UpsertErrorNotRaised;
    } else |err| {
        try std.testing.expectEqual(error.InvalidSql, err);
    }
    var checkNoAction = try db.exec("SELECT count(*) FROM up_items;");
    defer checkNoAction.deinit();
    try std.testing.expectEqual(@as(i64, 1), checkNoAction.rows[0][0].integer);

    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var persisted = try db.exec("SELECT email, stock FROM up_items ORDER BY email;");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(usize, 1), persisted.count());
    try std.testing.expectEqual(@as(i64, 55), persisted.at(0)[1].integer);
    var persistedMem = try db.exec("SELECT label FROM up_members ORDER BY user_id;");
    defer persistedMem.deinit();
    try std.testing.expectEqual(@as(usize, 2), persistedMem.count());
    try std.testing.expectEqualStrings("b", persistedMem.rows[0][0].text);
    try std.testing.expectEqualStrings("e", persistedMem.rows[1][0].text);
}

test "before triggers fire before after triggers with old and new rows" {
    const path = "sqlite_zig_before_trigger_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE bt_items (id INTEGER, label TEXT, stock INTEGER); CREATE TABLE bt_audit (pos TEXT, id INTEGER, label TEXT); INSERT INTO bt_items VALUES (1, 'alpha', 5);");
    setup.deinit();

    var make = try db.exec("CREATE TRIGGER bt_before_insert BEFORE INSERT ON bt_items BEGIN INSERT INTO bt_audit VALUES ('before', NEW.id, NEW.label); END;");
    make.deinit();
    make = try db.exec("CREATE TRIGGER bt_after_insert AFTER INSERT ON bt_items BEGIN INSERT INTO bt_audit VALUES ('after', NEW.id, NEW.label); END;");
    make.deinit();
    var ins = try db.exec("INSERT INTO bt_items VALUES (2, 'beta', 7);");
    ins.deinit();
    var order = try db.exec("SELECT pos, id, label FROM bt_audit;");
    defer order.deinit();
    try std.testing.expectEqual(@as(usize, 2), order.count());
    try std.testing.expectEqualStrings("before", order.rows[0][0].text);
    try std.testing.expectEqualStrings("after", order.rows[1][0].text);
    try std.testing.expectEqual(@as(i64, 2), order.rows[0][1].integer);

    make = try db.exec("CREATE TRIGGER bt_before_update BEFORE UPDATE ON bt_items BEGIN INSERT INTO bt_audit VALUES ('update', OLD.id, NEW.label); END;");
    make.deinit();
    var upd = try db.exec("UPDATE bt_items SET label = 'ALPHA' WHERE id = 1;");
    upd.deinit();
    var updated = try db.exec("SELECT label FROM bt_items WHERE id = 1;");
    defer updated.deinit();
    try std.testing.expectEqualStrings("ALPHA", updated.rows[0][0].text);
    var updAudit = try db.exec("SELECT pos, id, label FROM bt_audit WHERE pos = 'update';");
    defer updAudit.deinit();
    try std.testing.expectEqual(@as(usize, 1), updAudit.count());
    try std.testing.expectEqual(@as(i64, 1), updAudit.rows[0][1].integer);
    try std.testing.expectEqualStrings("ALPHA", updAudit.rows[0][2].text);

    make = try db.exec("CREATE TRIGGER bt_before_delete BEFORE DELETE ON bt_items BEGIN INSERT INTO bt_audit VALUES ('bye', OLD.id, OLD.label); END;");
    make.deinit();
    var del = try db.exec("DELETE FROM bt_items WHERE id = 2;");
    del.deinit();
    var byeAudit = try db.exec("SELECT id, label FROM bt_audit WHERE pos = 'bye';");
    defer byeAudit.deinit();
    try std.testing.expectEqual(@as(usize, 1), byeAudit.count());
    try std.testing.expectEqual(@as(i64, 2), byeAudit.rows[0][0].integer);
    try std.testing.expectEqualStrings("beta", byeAudit.rows[0][1].text);
}

test "trigger when clauses filter before and after triggers" {
    const path = "sqlite_zig_when_trigger_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE wt_items (id INTEGER, label TEXT, stock INTEGER); CREATE TABLE wt_audit (pos TEXT, id INTEGER); INSERT INTO wt_items VALUES (1, 'alpha', 5);");
    setup.deinit();

    var make = try db.exec("CREATE TRIGGER wt_before_big BEFORE INSERT ON wt_items WHEN NEW.stock > 100 BEGIN INSERT INTO wt_audit VALUES ('before-big', NEW.id); END;");
    make.deinit();
    make = try db.exec("CREATE TRIGGER wt_after_big AFTER INSERT ON wt_items WHEN NEW.stock > 100 BEGIN INSERT INTO wt_audit VALUES ('after-big', NEW.id); END;");
    make.deinit();
    make = try db.exec("CREATE TRIGGER wt_after_small AFTER INSERT ON wt_items WHEN NEW.stock <= 100 BEGIN INSERT INTO wt_audit VALUES ('after-small', NEW.id); END;");
    make.deinit();
    var small = try db.exec("INSERT INTO wt_items VALUES (2, 'beta', 7);");
    small.deinit();
    var big = try db.exec("INSERT INTO wt_items VALUES (3, 'gamma', 500);");
    big.deinit();
    var audit = try db.exec("SELECT pos, id FROM wt_audit;");
    defer audit.deinit();
    try std.testing.expectEqual(@as(usize, 3), audit.count());
    try std.testing.expectEqualStrings("after-small", audit.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 2), audit.rows[0][1].integer);
    try std.testing.expectEqualStrings("before-big", audit.rows[1][0].text);
    try std.testing.expectEqualStrings("after-big", audit.rows[2][0].text);

    make = try db.exec("CREATE TRIGGER wt_update_big BEFORE UPDATE ON wt_items WHEN NEW.stock > OLD.stock BEGIN INSERT INTO wt_audit VALUES ('grew', NEW.id); END;");
    make.deinit();
    var grew = try db.exec("UPDATE wt_items SET stock = 9 WHERE id = 2;");
    grew.deinit();
    var shrank = try db.exec("UPDATE wt_items SET stock = 1 WHERE id = 2;");
    shrank.deinit();
    var grewAudit = try db.exec("SELECT id FROM wt_audit WHERE pos = 'grew';");
    defer grewAudit.deinit();
    try std.testing.expectEqual(@as(usize, 1), grewAudit.count());
    try std.testing.expectEqual(@as(i64, 2), grewAudit.rows[0][0].integer);

    make = try db.exec("CREATE TRIGGER wt_del_big AFTER DELETE ON wt_items WHEN OLD.stock > 100 BEGIN INSERT INTO wt_audit VALUES ('del-big', OLD.id); END;");
    make.deinit();
    var delSmall = try db.exec("DELETE FROM wt_items WHERE id = 2;");
    delSmall.deinit();
    var delBig = try db.exec("DELETE FROM wt_items WHERE id = 3;");
    delBig.deinit();
    var delAudit = try db.exec("SELECT id FROM wt_audit WHERE pos = 'del-big';");
    defer delAudit.deinit();
    try std.testing.expectEqual(@as(usize, 1), delAudit.count());
    try std.testing.expectEqual(@as(i64, 3), delAudit.rows[0][0].integer);
}

test "before trigger errors abort the statement" {
    const path = "sqlite_zig_before_abort_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE ba_items (id INTEGER, label TEXT); CREATE TABLE ba_audit (id INTEGER); INSERT INTO ba_items VALUES (1, 'alpha');");
    setup.deinit();

    var make = try db.exec("CREATE TRIGGER ba_guard BEFORE INSERT ON ba_items BEGIN INSERT INTO missing_audit_table VALUES (NEW.id); END;");
    make.deinit();
    try std.testing.expectError(error.UnknownTable, db.exec("INSERT INTO ba_items VALUES (2, 'beta');"));
    var intact = try db.exec("SELECT count(*) FROM ba_items;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(i64, 1), intact.rows[0][0].integer);

    try std.testing.expectError(error.UnknownColumn, db.exec("CREATE TRIGGER ba_bad BEFORE UPDATE ON ba_items WHEN NEW.nope > OLD.nope BEGIN SELECT 1; END; UPDATE ba_items SET label = 'x' WHERE id = 1;"));
    var intactLabel = try db.exec("SELECT label FROM ba_items WHERE id = 1;");
    defer intactLabel.deinit();
    try std.testing.expectEqualStrings("alpha", intactLabel.rows[0][0].text);

    var drop = try db.exec("DROP TRIGGER ba_guard;");
    drop.deinit();
    var makeAfter = try db.exec("CREATE TRIGGER ba_after AFTER INSERT ON ba_items BEGIN INSERT INTO ba_audit VALUES (NEW.id); END;");
    makeAfter.deinit();
    var nested = try db.exec("CREATE TRIGGER ba_nested AFTER INSERT ON ba_audit WHEN NEW.id < 100 BEGIN INSERT INTO ba_items VALUES (100 + NEW.id, 'nested'); END;");
    nested.deinit();
    var chain = try db.exec("INSERT INTO ba_items VALUES (3, 'gamma');");
    chain.deinit();
    var chained = try db.exec("SELECT id FROM ba_items ORDER BY id;");
    defer chained.deinit();
    try std.testing.expectEqual(@as(usize, 3), chained.count());
    try std.testing.expectEqual(@as(i64, 103), chained.rows[2][0].integer);
}

test "before and when triggers persist and work through the dsl" {
    const path = "sqlite_zig_before_persist_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const Item = @import("../dsl/table.zig").table("bp_items", struct { id: i64, label: []const u8, stock: i64 });
    try db.createTable(Item, .{});
    var setup = try db.exec("CREATE TABLE bp_audit (id INTEGER); CREATE TRIGGER bp_before BEFORE INSERT ON bp_items WHEN NEW.stock > 0 BEGIN INSERT INTO bp_audit VALUES (NEW.id); END; CREATE TRIGGER bp_after AFTER INSERT ON bp_items BEGIN INSERT INTO bp_audit VALUES (0 - NEW.id); END;");
    setup.deinit();

    var one = try db.from(Item).insert(.{ .id = 1, .label = "a", .stock = 5 });
    one.deinit();
    var two = try db.from(Item).insert(.{ .id = 2, .label = "b", .stock = 0 });
    two.deinit();
    var audit = try db.exec("SELECT id FROM bp_audit;");
    defer audit.deinit();
    try std.testing.expectEqual(@as(usize, 3), audit.count());
    try std.testing.expectEqual(@as(i64, 1), audit.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, -1), audit.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, -2), audit.rows[2][0].integer);

    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var reinsert = try db.exec("INSERT INTO bp_items VALUES (3, 'c', 9);");
    reinsert.deinit();
    var persisted = try db.exec("SELECT id FROM bp_audit;");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(usize, 5), persisted.count());
    try std.testing.expectEqual(@as(i64, 3), persisted.at(3)[0].integer);
    try std.testing.expectEqual(@as(i64, -3), persisted.at(4)[0].integer);
}

test "trigger timing and when clauses parse and validate" {
    const path = "sqlite_zig_trigger_parse_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE tp_items (id INTEGER);");
    setup.deinit();
    var good = try db.exec("CREATE TRIGGER tp_before BEFORE INSERT ON tp_items WHEN NEW.id > 0 BEGIN SELECT 1; END;");
    good.deinit();
    var drop = try db.exec("DROP TRIGGER tp_before;");
    drop.deinit();
    try std.testing.expectError(error.UnexpectedToken, db.exec("CREATE TRIGGER tp_missing INSERT ON tp_items BEGIN SELECT 1; END;"));
    try std.testing.expectError(error.UnexpectedToken, db.exec("CREATE TRIGGER tp_bad_when BEFORE INSERT ON tp_items WHEN BEGIN SELECT 1; END;"));
    try std.testing.expectError(error.UnexpectedToken, db.exec("CREATE TRIGGER tp_bad_body BEFORE INSERT ON tp_items BEGIN END;"));
    var intact = try db.exec("SELECT count(*) FROM tp_items;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(i64, 0), intact.rows[0][0].integer);
}

test "dynamic and typed DSL support case expressions in select" {
    const path = "sqlite_zig_dsl_case_test.db";
    var db = try freshDb(path);
    const t_db_case_items = db.table("case_items");
    defer dropDb(db, path);
    const Item = @import("../dsl/table.zig").table("case_items", struct { id: i64, name: ?[]const u8, age: ?i64, score: ?i64 });
    const caseWhen = @import("../dsl/column.zig").caseWhen;
    const caseValue = @import("../dsl/column.zig").caseValue;
    try db.createTable(Item, .{});
    var setup = try db.exec("INSERT INTO case_items VALUES (1, 'Alice', 30, 9), (2, 'Bob', 17, 4), (3, 'Carol', 12, NULL), (4, NULL, NULL, 7);");
    setup.deinit();

    var mark = db.parseCount;
    var searched = try t_db_case_items.select(.{ t_db_case_items.column("id"), caseWhen(t_db_case_items.column("age").gte(18), "adult").when(t_db_case_items.column("age").gte(13), "teen").else_("child") }).orderBy(t_db_case_items.column("id").asc()).fetch();
    defer searched.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 4), searched.count());
    try std.testing.expectEqualStrings("adult", searched.rows[0][1].text);
    try std.testing.expectEqualStrings("teen", searched.rows[1][1].text);
    try std.testing.expectEqualStrings("child", searched.rows[2][1].text);
    try std.testing.expectEqualStrings("child", searched.rows[3][1].text);

    var rawSearched = try db.exec("SELECT id, CASE WHEN age >= 18 THEN 'adult' WHEN age >= 13 THEN 'teen' ELSE 'child' END FROM case_items ORDER BY id;");
    defer rawSearched.deinit();
    try std.testing.expectEqual(searched.count(), rawSearched.count());
    for (searched.rows, 0..) |row, i| try std.testing.expectEqualStrings(rawSearched.rows[i][1].text, row[1].text);

    mark = db.parseCount;
    var noElse = try t_db_case_items.select(.{caseWhen(t_db_case_items.column("age").gt(100), "old")}).orderBy(t_db_case_items.column("id").asc()).fetch();
    defer noElse.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    for (noElse.rows) |row| try std.testing.expect(row[0] == .null);

    mark = db.parseCount;
    var simple = try db.from(Item).select(.{caseValue(Item.age).whenValue(30, "thirty").whenValue(17, "seventeen").else_("other")}).orderBy(Item.id.asc()).fetch();
    defer simple.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqualStrings("thirty", simple.rows[0][0].text);
    try std.testing.expectEqualStrings("seventeen", simple.rows[1][0].text);
    try std.testing.expectEqualStrings("other", simple.rows[2][0].text);
    try std.testing.expectEqualStrings("other", simple.rows[3][0].text);

    var rawSimple = try db.exec("SELECT CASE age WHEN 30 THEN 'thirty' WHEN 17 THEN 'seventeen' ELSE 'other' END FROM case_items ORDER BY id;");
    defer rawSimple.deinit();
    for (simple.rows, 0..) |row, i| try std.testing.expectEqualStrings(rawSimple.rows[i][0].text, row[0].text);

    mark = db.parseCount;
    var funcBase = try t_db_case_items.select(.{caseValue(t_db_case_items.column("name").lower()).whenValue("alice", "found").else_("missing")}).orderBy(t_db_case_items.column("id").asc()).fetch();
    defer funcBase.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqualStrings("found", funcBase.rows[0][0].text);
    try std.testing.expectEqualStrings("missing", funcBase.rows[1][0].text);
    try std.testing.expectEqualStrings("missing", funcBase.rows[3][0].text);

    mark = db.parseCount;
    var ranged = try db.from(Item).select(.{caseWhen(Item.score.between(5, 10), "mid").else_("other")}).orderBy(Item.id.asc()).fetch();
    defer ranged.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqualStrings("mid", ranged.rows[0][0].text);
    try std.testing.expectEqualStrings("other", ranged.rows[1][0].text);
    try std.testing.expectEqualStrings("other", ranged.rows[2][0].text);
    try std.testing.expectEqualStrings("mid", ranged.rows[3][0].text);

    mark = db.parseCount;
    var liked = try db.from(Item).select(.{caseWhen(Item.name.like("A%"), "a-name").else_("other")}).orderBy(Item.id.asc()).fetch();
    defer liked.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqualStrings("a-name", liked.rows[0][0].text);
    try std.testing.expectEqualStrings("other", liked.rows[1][0].text);
    try std.testing.expectEqualStrings("other", liked.rows[3][0].text);

    mark = db.parseCount;
    var retCase = try db.from(Item).returning(.{caseWhen(Item.score.gte(0), "new").else_("update")}).insert(.{ .id = 5, .name = "Eve", .age = 40, .score = 1 });
    defer retCase.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqualStrings("new", retCase.rows[0][0].text);

    if (t_db_case_items.select(.{caseWhen(t_db_case_items.column("age").isNull(), "x").else_("y")}).fetch()) |r| {
        var owned = r;
        owned.deinit();
        return error.CaseErrorNotRaised;
    } else |err| {
        try std.testing.expectEqual(error.InvalidSql, err);
    }
    var intactRows = try db.exec("SELECT count(*) FROM case_items;");
    defer intactRows.deinit();
    try std.testing.expectEqual(@as(i64, 5), intactRows.rows[0][0].integer);

    mark = db.parseCount;
    var filtered = try t_db_case_items.selectAll().whereCase(caseWhen(t_db_case_items.column("age").gte(18), "adult").else_("child"), "adult").orderBy(t_db_case_items.column("id").asc()).fetch();
    defer filtered.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 2), filtered.count());
    try std.testing.expectEqual(@as(i64, 1), filtered.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 5), filtered.rows[1][0].integer);

    var rawFiltered = try db.exec("SELECT id FROM case_items WHERE (CASE WHEN age >= 18 THEN 'adult' ELSE 'child' END) = 'adult' ORDER BY id;");
    defer rawFiltered.deinit();
    try std.testing.expectEqual(filtered.count(), rawFiltered.count());
    for (filtered.rows, 0..) |row, i| try std.testing.expectEqual(rawFiltered.rows[i][0].integer, row[0].integer);

    mark = db.parseCount;
    var orFiltered = try db.from(Item).where(Item.id.eq(3)).orWhereCase(caseValue(Item.age).whenValue(17, "x").else_("y"), "x").orderBy(Item.id.asc()).fetch();
    defer orFiltered.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 2), orFiltered.count());
    try std.testing.expectEqual(@as(i64, 2), orFiltered.rows[0].id);
    try std.testing.expectEqual(@as(i64, 3), orFiltered.rows[1].id);

    mark = db.parseCount;
    var delPending = db.from(Item).delete().whereCase(caseWhen(Item.age.lt(13), "young").else_("old"), "young");
    var deleted = try delPending.execute();
    defer deleted.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), deleted.changes);
    var afterDelete = try db.exec("SELECT count(*) FROM case_items;");
    defer afterDelete.deinit();
    try std.testing.expectEqual(@as(i64, 4), afterDelete.rows[0][0].integer);
}

test "parenthesized left-hand values do not corrupt row memory" {
    const path = "sqlite_zig_paren_lhs_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE paren_items (id INTEGER, name TEXT); INSERT INTO paren_items VALUES (1, 'alpha'), (2, 'beta');");
    setup.deinit();
    var rows = try db.exec("SELECT id FROM paren_items WHERE (name) = 'alpha' ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[0].integer);
    var intact = try db.exec("SELECT name FROM paren_items ORDER BY id;");
    defer intact.deinit();
    try std.testing.expectEqualStrings("alpha", intact.rows[0][0].text);
    try std.testing.expectEqualStrings("beta", intact.rows[1][0].text);
}

test "using and natural joins merge shared columns" {
    const path = "sqlite_zig_using_natural_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE n_left (id INTEGER, grp TEXT, val TEXT); CREATE TABLE n_right (id INTEGER, grp TEXT, info TEXT); INSERT INTO n_left VALUES (1, 'g1', 'L1'), (2, 'g2', 'L2'), (3, 'g1', 'L3'); INSERT INTO n_right VALUES (2, 'g2', 'R2'), (3, 'g9', 'R3'), (4, 'g4', 'R4');");
    setup.deinit();

    var usingInner = try db.exec("SELECT id, n_left.grp, val, info FROM n_left JOIN n_right USING (id) ORDER BY id;");
    defer usingInner.deinit();
    try std.testing.expectEqual(@as(usize, 2), usingInner.count());
    try std.testing.expectEqual(@as(i64, 2), usingInner.rows[0][0].integer);
    try std.testing.expectEqualStrings("L2", usingInner.rows[0][2].text);
    try std.testing.expectEqualStrings("R2", usingInner.rows[0][3].text);
    try std.testing.expectEqual(@as(i64, 3), usingInner.rows[1][0].integer);

    var usingStar = try db.exec("SELECT * FROM n_left JOIN n_right USING (id) ORDER BY id;");
    defer usingStar.deinit();
    try std.testing.expectEqual(@as(usize, 5), usingStar.columns.len);
    try std.testing.expectEqualStrings("id", usingStar.columns[0]);
    try std.testing.expectEqualStrings("grp", usingStar.columns[1]);
    try std.testing.expectEqualStrings("val", usingStar.columns[2]);
    try std.testing.expectEqualStrings("grp", usingStar.columns[3]);
    try std.testing.expectEqualStrings("info", usingStar.columns[4]);

    var natural = try db.exec("SELECT id, grp, val, info FROM n_left NATURAL JOIN n_right;");
    defer natural.deinit();
    try std.testing.expectEqual(@as(usize, 1), natural.count());
    try std.testing.expectEqual(@as(i64, 2), natural.rows[0][0].integer);
    try std.testing.expectEqualStrings("g2", natural.rows[0][1].text);
    try std.testing.expectEqualStrings("L2", natural.rows[0][2].text);
    try std.testing.expectEqualStrings("R2", natural.rows[0][3].text);

    var naturalStar = try db.exec("SELECT * FROM n_left NATURAL JOIN n_right;");
    defer naturalStar.deinit();
    try std.testing.expectEqual(@as(usize, 4), naturalStar.columns.len);

    var naturalLeft = try db.exec("SELECT id, grp, val, info FROM n_left NATURAL LEFT JOIN n_right ORDER BY id;");
    defer naturalLeft.deinit();
    try std.testing.expectEqual(@as(usize, 3), naturalLeft.count());
    try std.testing.expect(naturalLeft.rows[0][3] == .null);
    try std.testing.expectEqualStrings("R2", naturalLeft.rows[1][3].text);
    try std.testing.expect(naturalLeft.rows[2][3] == .null);

    var naturalRight = try db.exec("SELECT id, grp, val, info FROM n_left NATURAL RIGHT JOIN n_right ORDER BY id;");
    defer naturalRight.deinit();
    try std.testing.expectEqual(@as(usize, 3), naturalRight.count());
    try std.testing.expectEqualStrings("L2", naturalRight.rows[0][2].text);
    try std.testing.expect(naturalRight.rows[1][2] == .null);
    try std.testing.expectEqual(@as(i64, 4), naturalRight.rows[2][0].integer);
    try std.testing.expectEqualStrings("R4", naturalRight.rows[2][3].text);

    var noCommonSetup = try db.exec("CREATE TABLE nc_a (x INTEGER); CREATE TABLE nc_b (y INTEGER); INSERT INTO nc_a VALUES (1), (2); INSERT INTO nc_b VALUES (7), (8), (9);");
    noCommonSetup.deinit();
    var noCommon = try db.exec("SELECT count(*) FROM nc_a NATURAL JOIN nc_b;");
    defer noCommon.deinit();
    try std.testing.expectEqual(@as(i64, 6), noCommon.rows[0][0].integer);
}

test "dynamic and typed dsl using and natural joins" {
    const Left = @import("../dsl/table.zig").table("dsl_n_left", struct { id: i64, grp: []const u8, val: []const u8 });
    const Right = @import("../dsl/table.zig").table("dsl_n_right", struct { id: i64, grp: []const u8, info: []const u8 });
    const path = "sqlite_zig_dsl_using_natural_test.db";
    var db = try freshDb(path);
    const t_db_dsl_n_left = db.table("dsl_n_left");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE dsl_n_left (id INTEGER, grp TEXT, val TEXT); CREATE TABLE dsl_n_right (id INTEGER, grp TEXT, info TEXT); INSERT INTO dsl_n_left VALUES (1, 'g1', 'L1'), (2, 'g2', 'L2'), (3, 'g1', 'L3'); INSERT INTO dsl_n_right VALUES (2, 'g2', 'R2'), (3, 'g9', 'R3'), (4, 'g4', 'R4');");
    setup.deinit();
    var mark = db.parseCount;
    var dynUsing = try t_db_dsl_n_left.joinUsing("dsl_n_right", t_db_dsl_n_left.column("id")).orderBy(t_db_dsl_n_left.column("id").asc()).fetch();
    defer dynUsing.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 2), dynUsing.count());
    try std.testing.expectEqual(@as(usize, 5), dynUsing.columns.len);
    try std.testing.expectEqual(@as(i64, 2), dynUsing.at(0)[0].integer);
    try std.testing.expectEqualStrings("L2", dynUsing.at(0)[2].text);
    try std.testing.expectEqualStrings("R2", dynUsing.at(0)[4].text);
    var rawUsing = try db.exec("SELECT * FROM dsl_n_left JOIN dsl_n_right USING (id) ORDER BY id;");
    defer rawUsing.deinit();
    try std.testing.expectEqual(rawUsing.count(), dynUsing.count());
    try std.testing.expectEqual(rawUsing.columns.len, dynUsing.columns.len);
    for (rawUsing.rows, 0..) |row, i| for (row, 0..) |cell, j| {
        if (cell == .integer) try std.testing.expectEqual(cell.integer, dynUsing.at(i)[j].integer);
        if (cell == .text) try std.testing.expectEqualStrings(cell.text, dynUsing.at(i)[j].text);
    };
    mark = db.parseCount;
    var dynNatural = try t_db_dsl_n_left.naturalJoin("dsl_n_right").fetch();
    defer dynNatural.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), dynNatural.count());
    try std.testing.expectEqual(@as(usize, 4), dynNatural.columns.len);
    try std.testing.expectEqual(@as(i64, 2), dynNatural.at(0)[0].integer);
    try std.testing.expectEqualStrings("R2", dynNatural.at(0)[3].text);
    mark = db.parseCount;
    var typedUsing = try db.from(Left).joinUsing(Right, Left.id).orderBy(Left.id.asc()).fetch();
    defer typedUsing.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 2), typedUsing.count());
    mark = db.parseCount;
    var typedNatural = try db.from(Left).naturalJoin(Right).fetch();
    defer typedNatural.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), typedNatural.count());
    try std.testing.expectEqual(@as(i64, 2), typedNatural.rows[0].id);
    mark = db.parseCount;
    var leftUsing = try t_db_dsl_n_left.leftJoinUsing("dsl_n_right", t_db_dsl_n_left.column("id")).orderBy(t_db_dsl_n_left.column("id").asc()).fetch();
    defer leftUsing.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 3), leftUsing.count());
    mark = db.parseCount;
    var naturalLeft = try db.from(Left).naturalLeftJoin(Right).orderBy(Left.id.asc()).fetch();
    defer naturalLeft.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 3), naturalLeft.count());
}

test "multi-column using joins match on all columns" {
    const Left = @import("../dsl/table.zig").table("m_left", struct { id: i64, grp: []const u8, val: []const u8 });
    const Right = @import("../dsl/table.zig").table("m_right", struct { id: i64, grp: []const u8, info: []const u8 });
    const path = "sqlite_zig_multi_using_test.db";
    var db = try freshDb(path);
    const t_db_m_left = db.table("m_left");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE m_left (id INTEGER, grp TEXT, val TEXT); CREATE TABLE m_right (id INTEGER, grp TEXT, info TEXT); INSERT INTO m_left VALUES (1, 'g1', 'L1'), (2, 'g2', 'L2'), (3, 'g1', 'L3'); INSERT INTO m_right VALUES (2, 'g2', 'R2'), (3, 'g9', 'R3'), (4, 'g4', 'R4');");
    setup.deinit();
    var rawStar = try db.exec("SELECT * FROM m_left JOIN m_right USING (id, grp) ORDER BY id;");
    defer rawStar.deinit();
    try std.testing.expectEqual(@as(usize, 1), rawStar.count());
    try std.testing.expectEqual(@as(usize, 4), rawStar.columns.len);
    try std.testing.expectEqualStrings("id", rawStar.columns[0]);
    try std.testing.expectEqualStrings("grp", rawStar.columns[1]);
    try std.testing.expectEqualStrings("val", rawStar.columns[2]);
    try std.testing.expectEqualStrings("info", rawStar.columns[3]);
    try std.testing.expectEqual(@as(i64, 2), rawStar.at(0)[0].integer);
    try std.testing.expectEqualStrings("g2", rawStar.at(0)[1].text);
    try std.testing.expectEqualStrings("L2", rawStar.at(0)[2].text);
    try std.testing.expectEqualStrings("R2", rawStar.at(0)[3].text);
    var rawNamed = try db.exec("SELECT id, grp, val, info FROM m_left JOIN m_right USING (id, grp);");
    defer rawNamed.deinit();
    try std.testing.expectEqual(@as(usize, 1), rawNamed.count());
    try std.testing.expectEqual(@as(i64, 2), rawNamed.rows[0][0].integer);
    var rawLeft = try db.exec("SELECT * FROM m_left LEFT JOIN m_right USING (id, grp) ORDER BY id;");
    defer rawLeft.deinit();
    try std.testing.expectEqual(@as(usize, 3), rawLeft.count());
    try std.testing.expect(rawLeft.rows[0][3] == .null);
    try std.testing.expectEqualStrings("R2", rawLeft.rows[1][3].text);
    try std.testing.expect(rawLeft.rows[2][3] == .null);
    try std.testing.expectEqualStrings("g1", rawLeft.rows[2][1].text);
    var rawCount = try db.exec("SELECT count(*) FROM m_left JOIN m_right USING (id, grp);");
    defer rawCount.deinit();
    try std.testing.expectEqual(@as(i64, 1), rawCount.rows[0][0].integer);
    var mark = db.parseCount;
    var dynMulti = try t_db_m_left.joinUsing("m_right", .{ t_db_m_left.column("id"), t_db_m_left.column("grp") }).orderBy(t_db_m_left.column("id").asc()).fetch();
    defer dynMulti.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), dynMulti.count());
    try std.testing.expectEqual(@as(usize, 4), dynMulti.columns.len);
    try std.testing.expectEqual(@as(i64, 2), dynMulti.at(0)[0].integer);
    try std.testing.expectEqualStrings("g2", dynMulti.at(0)[1].text);
    try std.testing.expectEqualStrings("L2", dynMulti.at(0)[2].text);
    try std.testing.expectEqualStrings("R2", dynMulti.at(0)[3].text);
    for (rawStar.rows, 0..) |row, i| for (row, 0..) |cell, j| {
        if (cell == .integer) try std.testing.expectEqual(cell.integer, dynMulti.at(i)[j].integer);
        if (cell == .text) try std.testing.expectEqualStrings(cell.text, dynMulti.at(i)[j].text);
    };
    mark = db.parseCount;
    var dynLeft = try t_db_m_left.leftJoinUsing("m_right", .{ t_db_m_left.column("id"), t_db_m_left.column("grp") }).orderBy(t_db_m_left.column("id").asc()).fetch();
    defer dynLeft.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 3), dynLeft.count());
    try std.testing.expect(dynLeft.rows[0][3] == .null);
    try std.testing.expectEqualStrings("R2", dynLeft.rows[1][3].text);
    mark = db.parseCount;
    var typedMulti = try db.from(Left).joinUsing(Right, .{ Left.id, Left.grp }).orderBy(Left.id.asc()).fetch();
    defer typedMulti.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), typedMulti.count());
    try std.testing.expectEqual(@as(i64, 2), typedMulti.rows[0].id);
    try std.testing.expectEqualStrings("g2", typedMulti.rows[0].grp);
    try std.testing.expectEqualStrings("L2", typedMulti.rows[0].val);
    mark = db.parseCount;
    var typedLeft = try db.from(Left).leftJoinUsing(Right, .{ Left.id, Left.grp }).orderBy(Left.id.asc()).fetch();
    defer typedLeft.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 3), typedLeft.count());
    var beforeErr = try db.exec("SELECT count(*) FROM m_left;");
    defer beforeErr.deinit();
    try std.testing.expectEqual(@as(i64, 3), beforeErr.rows[0][0].integer);
    if (db.exec("SELECT * FROM m_left JOIN m_right USING (nope);")) |r| {
        var owned = r;
        owned.deinit();
        return error.ExpectedUnknownColumn;
    } else |err| {
        try std.testing.expectEqual(error.UnknownColumn, err);
    }
    if (t_db_m_left.joinUsing("m_right", .{ t_db_m_left.column("id"), t_db_m_left.column("nope") }).fetch()) |r| {
        var owned = r;
        owned.deinit();
        return error.ExpectedUnknownColumn;
    } else |err| {
        try std.testing.expectEqual(error.UnknownColumn, err);
    }
    var afterLeft = try db.exec("SELECT count(*) FROM m_left;");
    defer afterLeft.deinit();
    try std.testing.expectEqual(@as(i64, 3), afterLeft.rows[0][0].integer);
    var afterRight = try db.exec("SELECT count(*) FROM m_right;");
    defer afterRight.deinit();
    try std.testing.expectEqual(@as(i64, 3), afterRight.rows[0][0].integer);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var persisted = try db.exec("SELECT * FROM m_left JOIN m_right USING (id, grp);");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(usize, 1), persisted.count());
    try std.testing.expectEqual(@as(usize, 4), persisted.columns.len);
    try std.testing.expectEqual(@as(i64, 2), persisted.at(0)[0].integer);
    try std.testing.expectEqualStrings("R2", persisted.at(0)[3].text);
}

test "compound dsl covers set operations with raw parity" {
    const path = "sqlite_zig_compound_dsl_test.db";
    var db = try freshDb(path);
    const t_db_c_right = db.table("c_right");
    const t_db_c_left = db.table("c_left");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE c_left (id INTEGER, label TEXT); CREATE TABLE c_right (id INTEGER, label TEXT); INSERT INTO c_left VALUES (1, 'alpha'), (2, 'beta'), (2, 'beta'), (NULL, 'null'), (4, 'delta'); INSERT INTO c_right VALUES (2, 'beta'), (3, 'gamma'), (NULL, 'null'), (5, 'eps');");
    setup.deinit();
    var rawUnion = try db.exec("SELECT id FROM c_left UNION SELECT id FROM c_right ORDER BY id;");
    defer rawUnion.deinit();
    try std.testing.expectEqual(@as(usize, 6), rawUnion.count());
    try std.testing.expect(rawUnion.rows[0][0] == .null);
    try std.testing.expectEqual(@as(i64, 1), rawUnion.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, 2), rawUnion.rows[2][0].integer);
    try std.testing.expectEqual(@as(i64, 5), rawUnion.rows[5][0].integer);
    var mark = db.parseCount;
    var dynUnion = try t_db_c_left.select(.{t_db_c_left.column("id")}).unionDistinct(t_db_c_right.select(.{t_db_c_right.column("id")})).orderBy(t_db_c_left.column("id").asc()).fetch();
    defer dynUnion.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawUnion.count(), dynUnion.count());
    for (rawUnion.rows, 0..) |row, i| {
        if (row[0] == .null) {
            try std.testing.expect(dynUnion.rows[i][0] == .null);
        } else {
            try std.testing.expectEqual(row[0].integer, dynUnion.rows[i][0].integer);
        }
    }
    var rawAll = try db.exec("SELECT id FROM c_left UNION ALL SELECT id FROM c_right;");
    defer rawAll.deinit();
    try std.testing.expectEqual(@as(usize, 9), rawAll.count());
    mark = db.parseCount;
    var dynAll = try t_db_c_left.select(.{t_db_c_left.column("id")}).unionAll(t_db_c_right.select(.{t_db_c_right.column("id")})).fetch();
    defer dynAll.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawAll.count(), dynAll.count());
    try std.testing.expectEqual(@as(i64, 1), dynAll.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), dynAll.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, 2), dynAll.rows[2][0].integer);
    var rawIntersect = try db.exec("SELECT id FROM c_left INTERSECT SELECT id FROM c_right;");
    defer rawIntersect.deinit();
    try std.testing.expectEqual(@as(usize, 2), rawIntersect.count());
    try std.testing.expectEqual(@as(i64, 2), rawIntersect.rows[0][0].integer);
    try std.testing.expect(rawIntersect.rows[1][0] == .null);
    mark = db.parseCount;
    var dynIntersect = try t_db_c_left.select(.{t_db_c_left.column("id")}).intersect(t_db_c_right.select(.{t_db_c_right.column("id")})).fetch();
    defer dynIntersect.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawIntersect.count(), dynIntersect.count());
    try std.testing.expectEqual(@as(i64, 2), dynIntersect.rows[0][0].integer);
    try std.testing.expect(dynIntersect.rows[1][0] == .null);
    var rawExcept = try db.exec("SELECT id FROM c_left EXCEPT SELECT id FROM c_right;");
    defer rawExcept.deinit();
    try std.testing.expectEqual(@as(usize, 2), rawExcept.count());
    try std.testing.expectEqual(@as(i64, 1), rawExcept.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 4), rawExcept.rows[1][0].integer);
    mark = db.parseCount;
    var dynExcept = try t_db_c_left.select(.{t_db_c_left.column("id")}).except(t_db_c_right.select(.{t_db_c_right.column("id")})).fetch();
    defer dynExcept.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawExcept.count(), dynExcept.count());
    try std.testing.expectEqual(@as(i64, 1), dynExcept.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 4), dynExcept.rows[1][0].integer);
    var crossType = try db.exec("SELECT 1 UNION SELECT 1.0;");
    defer crossType.deinit();
    try std.testing.expectEqual(@as(usize, 1), crossType.count());
    try std.testing.expectEqual(@as(i64, 1), crossType.rows[0][0].integer);
    var crossExcept = try db.exec("SELECT 1 EXCEPT SELECT 1.0;");
    defer crossExcept.deinit();
    try std.testing.expectEqual(@as(usize, 0), crossExcept.count());
    var rawPaged = try db.exec("SELECT id FROM c_left UNION SELECT id FROM c_right ORDER BY id LIMIT 2 OFFSET 1;");
    defer rawPaged.deinit();
    try std.testing.expectEqual(@as(usize, 2), rawPaged.count());
    try std.testing.expectEqual(@as(i64, 1), rawPaged.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), rawPaged.rows[1][0].integer);
    mark = db.parseCount;
    var dynPaged = try t_db_c_left.select(.{t_db_c_left.column("id")}).unionDistinct(t_db_c_right.select(.{t_db_c_right.column("id")})).orderBy(t_db_c_left.column("id").asc()).limit(2).offset(1).fetch();
    defer dynPaged.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawPaged.count(), dynPaged.count());
    try std.testing.expectEqual(@as(i64, 1), dynPaged.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), dynPaged.rows[1][0].integer);
    var rawChain = try db.exec("SELECT id FROM c_left EXCEPT SELECT id FROM c_right UNION SELECT id FROM c_right ORDER BY id;");
    defer rawChain.deinit();
    try std.testing.expectEqual(@as(usize, 6), rawChain.count());
    mark = db.parseCount;
    var dynChain = try t_db_c_left.select(.{t_db_c_left.column("id")}).except(t_db_c_right.select(.{t_db_c_right.column("id")})).unionDistinct(t_db_c_right.select(.{t_db_c_right.column("id")})).orderBy(t_db_c_left.column("id").asc()).fetch();
    defer dynChain.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawChain.count(), dynChain.count());
    for (rawChain.rows, 0..) |row, i| {
        if (row[0] == .null) {
            try std.testing.expect(dynChain.at(i)[0] == .null);
        } else {
            try std.testing.expectEqual(row[0].integer, dynChain.at(i)[0].integer);
        }
    }
    if (db.exec("SELECT id FROM c_left UNION SELECT id, label FROM c_right;")) |r| {
        var owned = r;
        owned.deinit();
        return error.ExpectedSchemaMismatch;
    } else |err| {
        try std.testing.expectEqual(error.SchemaMismatch, err);
    }
    if (t_db_c_left.select(.{t_db_c_left.column("id")}).unionDistinct(t_db_c_right.select(.{ t_db_c_right.column("id"), t_db_c_right.column("label") })).fetch()) |r| {
        var owned = r;
        owned.deinit();
        return error.ExpectedSchemaMismatch;
    } else |err| {
        try std.testing.expectEqual(error.SchemaMismatch, err);
    }
    if (db.exec("SELECT id FROM c_left UNION SELECT id FROM c_right ORDER BY nope;")) |r| {
        var owned = r;
        owned.deinit();
        return error.ExpectedUnknownColumn;
    } else |err| {
        try std.testing.expectEqual(error.UnknownColumn, err);
    }
    mark = db.parseCount;
    if (t_db_c_left.select(.{t_db_c_left.column("id")}).unionDistinct(t_db_c_right.select(.{t_db_c_right.column("id")})).orderBy(t_db_c_left.column("nope").asc()).fetch()) |r| {
        var owned = r;
        owned.deinit();
        return error.ExpectedUnknownColumn;
    } else |err| {
        try std.testing.expectEqual(error.UnknownColumn, err);
    }
    try std.testing.expectEqual(mark, db.parseCount);
    if (t_db_c_left.select(.{t_db_c_left.column("id")}).orderBy(t_db_c_left.column("id").asc()).unionDistinct(t_db_c_right.select(.{t_db_c_right.column("id")})).fetch()) |r| {
        var owned = r;
        owned.deinit();
        return error.ExpectedArmOrderRejected;
    } else |err| {
        try std.testing.expectEqual(error.InvalidSql, err);
    }
    var intactLeft = try db.exec("SELECT count(*) FROM c_left;");
    defer intactLeft.deinit();
    try std.testing.expectEqual(@as(i64, 5), intactLeft.rows[0][0].integer);
    var intactRight = try db.exec("SELECT count(*) FROM c_right;");
    defer intactRight.deinit();
    try std.testing.expectEqual(@as(i64, 4), intactRight.rows[0][0].integer);
}

test "compound dsl maps typed rows and cte arms" {
    const Left = @import("../dsl/table.zig").table("t_left", struct { id: ?i64, label: ?[]const u8 });
    const Right = @import("../dsl/table.zig").table("t_right", struct { id: ?i64, label: ?[]const u8 });
    const path = "sqlite_zig_compound_typed_test.db";
    var db = try freshDb(path);
    const t_db_live_ids = db.table("live_ids");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE t_left (id INTEGER, label TEXT); CREATE TABLE t_right (id INTEGER, label TEXT); INSERT INTO t_left VALUES (1, 'alpha'), (2, 'beta'), (NULL, 'null'); INSERT INTO t_right VALUES (2, 'beta'), (3, 'gamma'), (NULL, 'null');");
    setup.deinit();
    var mark = db.parseCount;
    var typedUnion = try db.from(Left).unionDistinct(db.from(Right)).fetch();
    defer typedUnion.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 4), typedUnion.count());
    try std.testing.expectEqual(@as(i64, 1), typedUnion.rows[0].id.?);
    try std.testing.expectEqualStrings("alpha", typedUnion.rows[0].label.?);
    mark = db.parseCount;
    var typedIds = try db.from(Left).select(.{Left.id}).unionDistinct(db.from(Right).select(.{Right.id})).orderBy(Left.id.asc()).fetch();
    defer typedIds.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 4), typedIds.count());
    try std.testing.expect(typedIds.rows[0][0] == .null);
    try std.testing.expectEqual(@as(i64, 3), typedIds.rows[3][0].integer);
    var rawTyped = try db.exec("SELECT id FROM t_left UNION SELECT id FROM t_right ORDER BY id;");
    defer rawTyped.deinit();
    try std.testing.expectEqual(rawTyped.count(), typedIds.count());
    for (rawTyped.rows, 0..) |row, i| {
        if (row[0] == .null) {
            try std.testing.expect(typedIds.rows[i][0] == .null);
        } else {
            try std.testing.expectEqual(row[0].integer, typedIds.rows[i][0].integer);
        }
    }
    var cteArm = try t_db_live_ids.with("live_ids", "SELECT id FROM t_left WHERE id IS NOT NULL").select(.{t_db_live_ids.column("id")}).unionDistinct(db.from(Right).select(.{Right.id})).fetch();
    defer cteArm.deinit();
    try std.testing.expectEqual(@as(usize, 4), cteArm.count());
    var single = try db.from(Left).where(Left.id.eq(1)).unionDistinct(db.from(Right).where(Right.id.gt(100))).fetchOne();
    defer db.from(Left).freeRow(&single);
    try std.testing.expectEqual(@as(i64, 1), single.id.?);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    const t_db_t_left_reopened = db.table("t_left");
    const t_db_t_right_reopened = db.table("t_right");
    var persisted = try t_db_t_left_reopened.select(.{t_db_t_left_reopened.column("id")}).unionDistinct(t_db_t_right_reopened.select(.{t_db_t_right_reopened.column("id")})).orderBy(t_db_t_left_reopened.column("id").asc()).fetch();
    defer persisted.deinit();
    try std.testing.expectEqual(@as(usize, 4), persisted.count());
    try std.testing.expect(persisted.at(0)[0] == .null);
}

test "derived tables construct from dsl builders" {
    const Order = @import("../dsl/table.zig").table("d_orders", struct { id: i64, user_id: i64, amount: i64 });
    const path = "sqlite_zig_derived_dsl_test.db";
    var db = try freshDb(path);
    const t_db_d_orders = db.table("d_orders");
    const t_db_d_users = db.table("d_users");
    const t_db_live_big = db.table("live_big");
    const t_db_nope = db.table("nope");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE d_orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount INTEGER); CREATE TABLE d_users (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO d_orders VALUES (1, 7, 50), (2, 7, 150), (3, 8, 200), (4, 8, 30), (5, 7, 120); INSERT INTO d_users VALUES (7, 'seven'), (8, 'eight');");
    setup.deinit();
    var mark = db.parseCount;
    var big = try t_db_d_orders.select(.{t_db_d_orders.column("user_id")}).where(t_db_d_orders.column("amount").gt(100)).asSubquery("big");
    var dynBig = try big.select(.{big.column("user_id")}).orderBy(big.column("user_id").asc()).fetch();
    defer dynBig.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqualStrings("user_id", dynBig.columns[0]);
    try std.testing.expectEqual(@as(usize, 3), dynBig.count());
    try std.testing.expectEqual(@as(i64, 7), dynBig.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 7), dynBig.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, 8), dynBig.rows[2][0].integer);
    var rawBig = try db.exec("SELECT user_id FROM (SELECT user_id FROM d_orders WHERE amount > 100) AS big ORDER BY user_id;");
    defer rawBig.deinit();
    try std.testing.expectEqual(rawBig.count(), dynBig.count());
    for (rawBig.rows, 0..) |row, i| try std.testing.expectEqual(row[0].integer, dynBig.rows[i][0].integer);
    mark = db.parseCount;
    var filtered = try big.select(.{big.column("user_id")}).where(big.column("user_id").eq(8)).fetch();
    defer filtered.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), filtered.count());
    try std.testing.expectEqual(@as(i64, 8), filtered.rows[0][0].integer);
    mark = db.parseCount;
    var paged = try big.select(.{big.column("user_id")}).orderBy(big.column("user_id").asc()).limit(2).offset(1).fetch();
    defer paged.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 2), paged.count());
    try std.testing.expectEqual(@as(i64, 7), paged.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 8), paged.rows[1][0].integer);
    mark = db.parseCount;
    var distinct = try big.select(.{big.column("user_id")}).distinct().fetch();
    defer distinct.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 2), distinct.count());
    var allIds = try t_db_d_orders.select(.{t_db_d_orders.column("user_id")}).asSubquery("allids");
    mark = db.parseCount;
    var grouped = try allIds.select(.{allIds.column("user_id")}).groupBy(allIds.column("user_id")).having(allIds.column("user_id").count().gt(2)).fetch();
    defer grouped.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 1), grouped.count());
    try std.testing.expectEqual(@as(i64, 7), grouped.rows[0][0].integer);
    mark = db.parseCount;
    var counted = try big.countStar().fetch();
    defer counted.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(i64, 3), counted.rows[0][0].integer);
    mark = db.parseCount;
    var typedSub = try db.from(Order).select(.{Order.user_id}).where(Order.amount.gt(100)).asSubquery("o");
    var typedOut = try typedSub.select(.{typedSub.column("user_id")}).fetch();
    defer typedOut.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqualStrings("user_id", typedOut.columns[0]);
    try std.testing.expectEqual(@as(usize, 3), typedOut.count());
    try std.testing.expectEqual(@as(i64, 7), typedOut.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 8), typedOut.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, 7), typedOut.rows[2][0].integer);
    mark = db.parseCount;
    const bigUserId = DynamicColumn{ .name = "user_id", .table = "big" };
    var joined = try big.select(.{big.column("name")}).innerJoin(t_db_d_users, bigUserId.eq(t_db_d_users.column("id"))).orderBy(t_db_d_users.column("name").asc()).fetch();
    defer joined.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 3), joined.count());
    try std.testing.expectEqualStrings("eight", joined.rows[0][0].text);
    try std.testing.expectEqualStrings("seven", joined.rows[1][0].text);
    try std.testing.expectEqualStrings("seven", joined.rows[2][0].text);
    var rawJoin = try db.exec("SELECT name FROM (SELECT user_id FROM d_orders WHERE amount > 100) AS big INNER JOIN d_users ON big.user_id = d_users.id ORDER BY name;");
    defer rawJoin.deinit();
    try std.testing.expectEqual(rawJoin.count(), joined.count());
    for (rawJoin.rows, 0..) |row, i| try std.testing.expectEqualStrings(row[0].text, joined.rows[i][0].text);
    var cteSub = try t_db_live_big.with("live_big", "SELECT user_id FROM d_orders WHERE amount > 100").select(.{t_db_live_big.column("user_id")}).asSubquery("cbig");
    var cteOut = try cteSub.select(.{cteSub.column("user_id")}).orderBy(cteSub.column("user_id").asc()).fetch();
    defer cteOut.deinit();
    try std.testing.expectEqual(@as(usize, 3), cteOut.count());
    try std.testing.expectEqual(@as(i64, 7), cteOut.rows[0][0].integer);
    try std.testing.expectError(error.InvalidSql, (try t_db_d_orders.select(.{t_db_d_orders.column("id")}).asSubquery("a")).asSubquery("b"));
    try std.testing.expectError(error.InvalidSql, t_db_d_orders.asSubquery(""));
    try std.testing.expectError(error.UnknownColumn, (try t_db_d_orders.select(.{t_db_d_orders.column("nope")}).asSubquery("s")).select(.{t_db_d_orders.column("nope")}).fetch());
    try std.testing.expectError(error.UnknownTable, (try t_db_nope.select(.{t_db_nope.column("id")}).asSubquery("s")).fetch());
    var intactOrders = try db.exec("SELECT count(*) FROM d_orders;");
    defer intactOrders.deinit();
    try std.testing.expectEqual(@as(i64, 5), intactOrders.rows[0][0].integer);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    const markReopened = db.parseCount;
    const t_db_d_orders_reopened = db.table("d_orders");
    var repersisted = try t_db_d_orders_reopened.select(.{t_db_d_orders_reopened.column("user_id")}).where(t_db_d_orders_reopened.column("amount").gt(100)).asSubquery("big");
    var repersistedOut = try repersisted.select(.{repersisted.column("user_id")}).orderBy(repersisted.column("user_id").asc()).fetch();
    defer repersistedOut.deinit();
    try std.testing.expectEqual(markReopened, db.parseCount);
    try std.testing.expectEqual(@as(usize, 3), repersistedOut.count());
}

test "dynamic dsl covers window functions with raw parity" {
    const win = @import("../dsl/column.zig");
    const path = "sqlite_zig_window_dsl_test.db";
    var db = try freshDb(path);
    const t_db_win_tbl = db.table("win_tbl");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE win_tbl (dept TEXT, emp TEXT, salary INT); INSERT INTO win_tbl VALUES ('HR', 'Alice', 1000), ('HR', 'Bob', 1500), ('IT', 'Charlie', 2000), ('IT', 'Dave', 2000), ('IT', 'Eve', 2500);");
    setup.deinit();
    var rawRanks = try db.exec("SELECT emp, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary) AS rn, RANK() OVER (PARTITION BY dept ORDER BY salary) AS rk, DENSE_RANK() OVER (PARTITION BY dept ORDER BY salary) AS drk FROM win_tbl ORDER BY dept;");
    defer rawRanks.deinit();
    try std.testing.expectEqual(@as(usize, 5), rawRanks.count());
    var mark = db.parseCount;
    var dynRanks = try t_db_win_tbl.select(.{ t_db_win_tbl.column("emp"), win.rowNumber().partitionBy(t_db_win_tbl.column("dept")).orderBy(t_db_win_tbl.column("salary").asc()), win.rank().partitionBy(t_db_win_tbl.column("dept")).orderBy(t_db_win_tbl.column("salary").asc()), win.denseRank().partitionBy(t_db_win_tbl.column("dept")).orderBy(t_db_win_tbl.column("salary").asc()) }).orderBy(t_db_win_tbl.column("dept").asc()).fetch();
    defer dynRanks.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawRanks.count(), dynRanks.count());
    try std.testing.expectEqualStrings("emp", dynRanks.columns[0]);
    try std.testing.expectEqualStrings("row_number", dynRanks.columns[1]);
    try std.testing.expectEqualStrings("rank", dynRanks.columns[2]);
    try std.testing.expectEqualStrings("dense_rank", dynRanks.columns[3]);
    for (rawRanks.rows, 0..) |row, i| {
        try std.testing.expectEqualStrings(row[0].text, dynRanks.rows[i][0].text);
        try std.testing.expectEqual(row[1].integer, dynRanks.rows[i][1].integer);
        try std.testing.expectEqual(row[2].integer, dynRanks.rows[i][2].integer);
        try std.testing.expectEqual(row[3].integer, dynRanks.rows[i][3].integer);
    }
    try std.testing.expectEqual(@as(i64, 1), dynRanks.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 2), dynRanks.rows[1][1].integer);
    var rawLag = try db.exec("SELECT emp, LAG(emp, 2, 'none') OVER (ORDER BY salary), LEAD(salary, 1, 0) OVER (ORDER BY salary) FROM win_tbl ORDER BY salary;");
    defer rawLag.deinit();
    mark = db.parseCount;
    var dynLag = try t_db_win_tbl.select(.{ t_db_win_tbl.column("emp"), win.lag(t_db_win_tbl.column("emp")).offset(2).defaultValue("none").orderBy(t_db_win_tbl.column("salary").asc()), win.lead(t_db_win_tbl.column("salary")).offset(1).defaultValue(0).orderBy(t_db_win_tbl.column("salary").asc()) }).orderBy(t_db_win_tbl.column("salary").asc()).fetch();
    defer dynLag.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawLag.count(), dynLag.count());
    try std.testing.expectEqualStrings("none", dynLag.rows[0][1].text);
    try std.testing.expectEqualStrings("Alice", dynLag.rows[2][1].text);
    try std.testing.expectEqual(@as(i64, 1500), dynLag.rows[0][2].integer);
    for (rawLag.rows, 0..) |row, i| {
        if (row[1] == .null) {
            try std.testing.expect(dynLag.rows[i][1] == .null);
        } else {
            try std.testing.expectEqualStrings(row[1].text, dynLag.rows[i][1].text);
        }
        try std.testing.expectEqual(row[2].integer, dynLag.rows[i][2].integer);
    }
    var rawDist = try db.exec("SELECT emp, PERCENT_RANK() OVER (ORDER BY salary), CUME_DIST() OVER (ORDER BY salary), NTILE(2) OVER (ORDER BY salary) FROM win_tbl ORDER BY salary;");
    defer rawDist.deinit();
    mark = db.parseCount;
    var dynDist = try t_db_win_tbl.select(.{ t_db_win_tbl.column("emp"), win.percentRank().orderBy(t_db_win_tbl.column("salary").asc()), win.cumeDist().orderBy(t_db_win_tbl.column("salary").asc()), win.ntile(2).orderBy(t_db_win_tbl.column("salary").asc()) }).orderBy(t_db_win_tbl.column("salary").asc()).fetch();
    defer dynDist.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawDist.count(), dynDist.count());
    try std.testing.expectEqual(rawDist.rows[0][1].real, dynDist.rows[0][1].real);
    try std.testing.expectEqual(rawDist.rows[1][1].real, dynDist.rows[1][1].real);
    try std.testing.expectEqual(rawDist.rows[4][1].real, dynDist.rows[4][1].real);
    try std.testing.expectEqual(rawDist.rows[0][2].real, dynDist.rows[0][2].real);
    try std.testing.expectEqual(rawDist.rows[2][3].integer, dynDist.rows[2][3].integer);
    try std.testing.expectEqual(rawDist.rows[3][3].integer, dynDist.rows[3][3].integer);
    var rawFramed = try db.exec("SELECT emp, FIRST_VALUE(emp) OVER (ORDER BY salary ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), LAST_VALUE(emp) OVER (ORDER BY salary ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING), NTH_VALUE(emp, 2) OVER (PARTITION BY dept ORDER BY salary) FROM win_tbl ORDER BY salary;");
    defer rawFramed.deinit();
    mark = db.parseCount;
    var dynFramed = try t_db_win_tbl.select(.{ t_db_win_tbl.column("emp"), win.firstValue(t_db_win_tbl.column("emp")).orderBy(t_db_win_tbl.column("salary").asc()).rowsBetween(win.preceding(1), win.currentRow()), win.lastValue(t_db_win_tbl.column("emp")).orderBy(t_db_win_tbl.column("salary").asc()).rowsBetween(win.currentRow(), win.following(1)), win.nthValue(t_db_win_tbl.column("emp"), 2).partitionBy(t_db_win_tbl.column("dept")).orderBy(t_db_win_tbl.column("salary").asc()) }).orderBy(t_db_win_tbl.column("salary").asc()).fetch();
    defer dynFramed.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawFramed.count(), dynFramed.count());
    for (rawFramed.rows, 0..) |row, i| {
        try std.testing.expectEqualStrings(row[0].text, dynFramed.rows[i][0].text);
        try std.testing.expectEqualStrings(row[1].text, dynFramed.rows[i][1].text);
        try std.testing.expectEqualStrings(row[2].text, dynFramed.rows[i][2].text);
        if (row[3] == .null) {
            try std.testing.expect(dynFramed.rows[i][3] == .null);
        } else {
            try std.testing.expectEqualStrings(row[3].text, dynFramed.rows[i][3].text);
        }
    }
    try std.testing.expectEqualStrings("Alice", dynFramed.rows[0][1].text);
    try std.testing.expectEqualStrings("Alice", dynFramed.rows[1][1].text);
    try std.testing.expectEqualStrings("Charlie", dynFramed.rows[1][2].text);
    var rawRangeGroups = try db.exec("SELECT emp, FIRST_VALUE(emp) OVER (ORDER BY salary RANGE BETWEEN 100 PRECEDING AND CURRENT ROW), FIRST_VALUE(emp) OVER (ORDER BY salary GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM win_tbl ORDER BY salary;");
    defer rawRangeGroups.deinit();
    mark = db.parseCount;
    var dynRangeGroups = try t_db_win_tbl.select(.{ t_db_win_tbl.column("emp"), win.firstValue(t_db_win_tbl.column("emp")).orderBy(t_db_win_tbl.column("salary").asc()).rangeBetween(win.preceding(100), win.currentRow()), win.firstValue(t_db_win_tbl.column("emp")).orderBy(t_db_win_tbl.column("salary").asc()).groupsBetween(win.preceding(1), win.currentRow()) }).orderBy(t_db_win_tbl.column("salary").asc()).fetch();
    defer dynRangeGroups.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawRangeGroups.count(), dynRangeGroups.count());
    for (rawRangeGroups.rows, 0..) |row, i| {
        try std.testing.expectEqualStrings(row[1].text, dynRangeGroups.rows[i][1].text);
        try std.testing.expectEqualStrings(row[2].text, dynRangeGroups.rows[i][2].text);
    }
    var rawUnbounded = try db.exec("SELECT emp, FIRST_VALUE(emp) OVER (ORDER BY salary RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), FIRST_VALUE(emp) OVER (ORDER BY salary GROUPS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM win_tbl ORDER BY salary;");
    defer rawUnbounded.deinit();
    mark = db.parseCount;
    var dynUnbounded = try t_db_win_tbl.select(.{ t_db_win_tbl.column("emp"), win.firstValue(t_db_win_tbl.column("emp")).orderBy(t_db_win_tbl.column("salary").asc()).rangeBetween(win.unboundedPreceding(), win.currentRow()), win.firstValue(t_db_win_tbl.column("emp")).orderBy(t_db_win_tbl.column("salary").asc()).groupsBetween(win.unboundedPreceding(), win.currentRow()) }).orderBy(t_db_win_tbl.column("salary").asc()).fetch();
    defer dynUnbounded.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawUnbounded.count(), dynUnbounded.count());
    for (rawUnbounded.rows, 0..) |row, i| {
        try std.testing.expectEqualStrings("Alice", row[1].text);
        try std.testing.expectEqualStrings("Alice", row[2].text);
        try std.testing.expectEqualStrings(row[1].text, dynUnbounded.rows[i][1].text);
        try std.testing.expectEqualStrings(row[2].text, dynUnbounded.rows[i][2].text);
    }
    var rawBare = try db.exec("SELECT RANK() OVER (), NTILE(2) OVER () FROM win_tbl;");
    defer rawBare.deinit();
    mark = db.parseCount;
    var dynBare = try t_db_win_tbl.select(.{ win.rank(), win.ntile(2) }).fetch();
    defer dynBare.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(rawBare.count(), dynBare.count());
    try std.testing.expectEqual(@as(i64, 1), dynBare.rows[0][0].integer);
    try std.testing.expectEqual(rawBare.rows[2][1].integer, dynBare.rows[2][1].integer);
    if (db.exec("SELECT RANK() OVER (ORDER BY nope) FROM win_tbl;")) |r| {
        var owned = r;
        owned.deinit();
        return error.ExpectedUnknownColumn;
    } else |err| {
        try std.testing.expectEqual(error.UnknownColumn, err);
    }
    mark = db.parseCount;
    if (t_db_win_tbl.select(.{win.rank().orderBy(t_db_win_tbl.column("nope").asc())}).fetch()) |r| {
        var owned = r;
        owned.deinit();
        return error.ExpectedUnknownColumn;
    } else |err| {
        try std.testing.expectEqual(error.UnknownColumn, err);
    }
    try std.testing.expectEqual(mark, db.parseCount);
    var intact = try db.exec("SELECT count(*) FROM win_tbl;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(i64, 5), intact.rows[0][0].integer);
}

test "typed dsl covers window functions" {
    const win = @import("../dsl/column.zig");
    const Win = @import("../dsl/table.zig").table("t_win", struct { dept: []const u8, emp: []const u8, salary: i64 });
    const path = "sqlite_zig_window_typed_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE t_win (dept TEXT, emp TEXT, salary INT); INSERT INTO t_win VALUES ('HR', 'Alice', 1000), ('HR', 'Bob', 1500), ('IT', 'Charlie', 2000), ('IT', 'Dave', 2000), ('IT', 'Eve', 2500);");
    setup.deinit();
    var mark = db.parseCount;
    var typedRanks = try db.from(Win).select(.{ Win.emp, win.rowNumber().partitionBy(Win.dept).orderBy(Win.salary.asc()), win.rank().partitionBy(Win.dept).orderBy(Win.salary.asc()) }).orderBy(Win.dept.asc()).fetch();
    defer typedRanks.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 5), typedRanks.count());
    try std.testing.expectEqualStrings("row_number", typedRanks.columns[1]);
    try std.testing.expectEqualStrings("rank", typedRanks.columns[2]);
    try std.testing.expectEqual(@as(i64, 1), typedRanks.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 2), typedRanks.rows[1][1].integer);
    var rawRanks = try db.exec("SELECT emp, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary) AS rn, RANK() OVER (PARTITION BY dept ORDER BY salary) AS rk FROM t_win ORDER BY dept;");
    defer rawRanks.deinit();
    for (rawRanks.rows, 0..) |row, i| {
        try std.testing.expectEqual(row[1].integer, typedRanks.rows[i][1].integer);
        try std.testing.expectEqual(row[2].integer, typedRanks.rows[i][2].integer);
    }
    mark = db.parseCount;
    var typedLag = try db.from(Win).select(.{ Win.emp, win.lag(Win.salary).offset(1).defaultValue(0).orderBy(Win.salary.asc()), win.ntile(2).orderBy(Win.salary.asc()) }).orderBy(Win.salary.asc()).fetch();
    defer typedLag.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(i64, 0), typedLag.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 1000), typedLag.rows[1][1].integer);
    try std.testing.expectEqual(@as(i64, 1), typedLag.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 2), typedLag.rows[4][2].integer);
    mark = db.parseCount;
    var typedInsert = try db.from(Win).insert(.{ .dept = "HR", .emp = "Zed", .salary = 900 });
    defer typedInsert.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    var afterInsert = try db.exec("SELECT count(*) FROM t_win;");
    defer afterInsert.deinit();
    try std.testing.expectEqual(@as(i64, 6), afterInsert.rows[0][0].integer);
    mark = db.parseCount;
    var typedFirst = try db.from(Win).select(.{win.firstValue(Win.emp).partitionBy(Win.dept).orderBy(Win.salary.asc()).rowsFrom(win.unboundedPreceding())}).fetch();
    defer typedFirst.deinit();
    try std.testing.expectEqual(mark, db.parseCount);
    try std.testing.expectEqual(@as(usize, 6), typedFirst.count());
    try std.testing.expectEqualStrings("Zed", typedFirst.rows[0][0].text);
    try std.testing.expectEqualStrings("Charlie", typedFirst.rows[2][0].text);
    try std.testing.expectEqualStrings("Zed", typedFirst.rows[5][0].text);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    const t_db_t_win_reopened = db.table("t_win");
    var repersisted = try t_db_t_win_reopened.select(.{win.rowNumber().partitionBy(t_db_t_win_reopened.column("dept")).orderBy(t_db_t_win_reopened.column("salary").asc())}).fetch();
    defer repersisted.deinit();
    try std.testing.expectEqual(@as(usize, 6), repersisted.count());
    const repersistedWant = [_]i64{ 2, 3, 1, 2, 3, 1 };
    for (repersisted.rows, 0..) |row, i| try std.testing.expectEqual(repersistedWant[i], row[0].integer);
}

test "typed dsl enforces strict and without rowid tables" {
    const Strict = @import("../dsl/table.zig").table("ty_strict", struct { id: i64, label: []const u8 });
    const NoRowId = @import("../dsl/table.zig").table("ty_norowid", struct { k1: i64, k2: []const u8, val: i64 });
    const path = "sqlite_zig_typed_strict_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(Strict, .{ .strict = true });
    var okInsert = try db.from(Strict).insert(.{ .id = 1, .label = "one" });
    okInsert.deinit();
    var rawRead = try db.exec("SELECT label FROM ty_strict WHERE id = 1;");
    defer rawRead.deinit();
    try std.testing.expectEqualStrings("one", rawRead.rows[0][0].text);
    try db.createTable(NoRowId, .{ .primaryKey = "k1", .withoutRowid = true });
    var okRowid = try db.from(NoRowId).insert(.{ .k1 = 1, .k2 = "a", .val = 10 });
    okRowid.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(NoRowId).insert(.{ .k1 = 1, .k2 = "b", .val = 11 }));
    var rawRowid = try db.exec("SELECT val FROM ty_norowid WHERE k1 = 1;");
    defer rawRowid.deinit();
    try std.testing.expectEqual(@as(i64, 10), rawRowid.rows[0][0].integer);
}

test "vacuum rebuilds storage and preserves schema objects" {
    const path = "sqlite_zig_vacuum_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE vac_items (id INTEGER PRIMARY KEY, label TEXT NOT NULL); CREATE INDEX vac_items_label_idx ON vac_items (label); CREATE VIEW vac_view AS SELECT id, label FROM vac_items; CREATE TRIGGER vac_log AFTER INSERT ON vac_items BEGIN UPDATE vac_items SET label = NEW.label WHERE id = NEW.id; END; INSERT INTO vac_items VALUES (1, 'one'), (2, 'two');");
    setup.deinit();
    var doomed = try db.exec("INSERT INTO vac_items VALUES (3, 'three'); DELETE FROM vac_items WHERE id = 3;");
    doomed.deinit();
    var vacuumed = try db.exec("VACUUM;");
    vacuumed.deinit();
    var rows = try db.exec("SELECT label FROM vac_items ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.count());
    try std.testing.expectEqualStrings("one", rows.at(0)[0].text);
    try std.testing.expectEqualStrings("two", rows.at(1)[0].text);
    try std.testing.expect(db.store.findIndexConst("vac_items_label_idx") != null);
    try std.testing.expect(db.store.findViewConst("vac_view") != null);
    try std.testing.expect(db.store.findTriggerConst("vac_log") != null);
    var viewRows = try db.exec("SELECT label FROM vac_view ORDER BY id;");
    defer viewRows.deinit();
    try std.testing.expectEqual(@as(usize, 2), viewRows.count());
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    var reopened = try db.exec("SELECT count(*) FROM vac_items;");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(i64, 2), reopened.rows[0][0].integer);
    try std.testing.expect(db.store.findIndexConst("vac_items_label_idx") != null);
    var named = try db.exec("VACUUM main;");
    named.deinit();
}

test "vacuum into writes an independent reopenable copy" {
    const path = "sqlite_zig_vacuum_into_test.db";
    const copyPath = "sqlite_zig_vacuum_into_copy.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, copyPath) catch {};
    var db = try freshDb(path);
    defer dropDb(db, path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, copyPath) catch {};
    var setup = try db.exec("CREATE TABLE copy_items (id INTEGER PRIMARY KEY, label TEXT); INSERT INTO copy_items VALUES (1, 'kept');");
    setup.deinit();
    var copied = try db.exec("VACUUM INTO 'sqlite_zig_vacuum_into_copy.db';");
    copied.deinit();
    var extra = try db.exec("INSERT INTO copy_items VALUES (2, 'original-only');");
    extra.deinit();
    var copyDb = try Connection.open(std.testing.allocator, copyPath);
    defer copyDb.close();
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, copyPath) catch {};
    var copyRows = try copyDb.exec("SELECT label FROM copy_items ORDER BY id;");
    defer copyRows.deinit();
    try std.testing.expectEqual(@as(usize, 1), copyRows.count());
    try std.testing.expectEqualStrings("kept", copyRows.rows[0][0].text);
    var liveRows = try db.exec("SELECT count(*) FROM copy_items;");
    defer liveRows.deinit();
    try std.testing.expectEqual(@as(i64, 2), liveRows.rows[0][0].integer);
}

test "vacuum rejects active transactions and unknown schemas" {
    const path = "sqlite_zig_vacuum_guard_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE guard_items (id INTEGER); INSERT INTO guard_items VALUES (1);");
    setup.deinit();
    var begin = try db.exec("BEGIN;");
    begin.deinit();
    try std.testing.expectError(error.TransactionActive, db.exec("VACUUM;"));
    var rollback = try db.exec("ROLLBACK;");
    rollback.deinit();
    var intact = try db.exec("SELECT count(*) FROM guard_items;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(i64, 1), intact.rows[0][0].integer);
    try std.testing.expectError(error.UnknownDatabase, db.exec("VACUUM attached;"));
    try std.testing.expectError(error.InvalidSql, db.exec("VACUUM INTO 42;"));
}

test "pragma page_size validates and preserves data across rebuilds" {
    const path = "sqlite_zig_page_size_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE sized (id INTEGER PRIMARY KEY, label TEXT); INSERT INTO sized VALUES (1, 'a'), (2, 'b');");
    setup.deinit();
    var current = try db.exec("PRAGMA page_size;");
    defer current.deinit();
    try std.testing.expectEqual(@as(i64, 4096), current.rows[0][0].integer);
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA page_size = 1000;"));
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA page_size = 300;"));
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA page_size(4096);"));
    var resized = try db.exec("PRAGMA page_size = 8192;");
    resized.deinit();
    try std.testing.expectEqual(@as(usize, 8192), db.file.pageSize);
    var rows = try db.exec("SELECT label FROM sized ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.count());
    try std.testing.expectEqualStrings("b", rows.at(1)[0].text);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    try std.testing.expectEqual(@as(usize, 8192), db.file.pageSize);
    var reopened = try db.exec("SELECT count(*) FROM sized;");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(i64, 2), reopened.rows[0][0].integer);
    var back = try db.exec("PRAGMA page_size = 4096;");
    back.deinit();
    try std.testing.expectEqual(@as(usize, 4096), db.file.pageSize);
}

test "pragma connection settings round-trip and reject invalid input" {
    const path = "sqlite_zig_pragma_settings_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var encoding = try db.exec("PRAGMA encoding;");
    defer encoding.deinit();
    try std.testing.expectEqualStrings("UTF-8", encoding.rows[0][0].text);
    var utfSet = try db.exec("PRAGMA encoding = 'UTF-8';");
    utfSet.deinit();
    try std.testing.expectError(error.Unsupported, db.exec("PRAGMA encoding = 'UTF-16';"));
    var busy = try db.exec("PRAGMA busy_timeout = 5000;");
    busy.deinit();
    var busyRead = try db.exec("PRAGMA busy_timeout;");
    defer busyRead.deinit();
    try std.testing.expectEqual(@as(i64, 5000), busyRead.rows[0][0].integer);
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA busy_timeout = 'soon';"));
    var locking = try db.exec("PRAGMA locking_mode = EXCLUSIVE;");
    locking.deinit();
    var lockingRead = try db.exec("PRAGMA locking_mode;");
    defer lockingRead.deinit();
    try std.testing.expectEqualStrings("exclusive", lockingRead.rows[0][0].text);
    var backToNormal = try db.exec("PRAGMA locking_mode = normal;");
    backToNormal.deinit();
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA locking_mode = fast;"));
    var vacuumMode = try db.exec("PRAGMA auto_vacuum = FULL;");
    vacuumMode.deinit();
    var vacuumRead = try db.exec("PRAGMA auto_vacuum;");
    defer vacuumRead.deinit();
    try std.testing.expectEqual(@as(i64, 1), vacuumRead.rows[0][0].integer);
    var incremental = try db.exec("PRAGMA auto_vacuum = 2;");
    incremental.deinit();
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA auto_vacuum = 7;"));
    try std.testing.expectError(error.Unsupported, db.exec("PRAGMA no_such_pragma;"));
    try std.testing.expectError(error.Unsupported, db.exec("PRAGMA no_such_pragma = 1;"));
}

test "partial index creation validates predicates" {
    const path = "sqlite_zig_partial_create_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE parts (id INTEGER, active INTEGER, amount INTEGER);");
    setup.deinit();
    var created = try db.exec("CREATE INDEX parts_active_id ON parts (id) WHERE active = 1;");
    created.deinit();
    try std.testing.expect(db.store.findIndexConst("parts_active_id") != null);
    try std.testing.expectError(error.UnknownColumn, db.exec("CREATE INDEX parts_bad_col ON parts (id) WHERE missing = 1;"));
    try std.testing.expect(db.store.findIndexConst("parts_bad_col") == null);
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE INDEX parts_sub ON parts (id) WHERE EXISTS (SELECT 1 FROM parts);"));
    try std.testing.expect(db.store.findIndexConst("parts_sub") == null);
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE INDEX parts_agg ON parts (id) WHERE amount > sum(amount);"));
    try std.testing.expect(db.store.findIndexConst("parts_agg") == null);
    var dropped = try db.exec("DROP INDEX parts_active_id;");
    dropped.deinit();
    try std.testing.expect(db.store.findIndexConst("parts_active_id") == null);
}

test "partial unique index constrains only matching rows" {
    const path = "sqlite_zig_partial_unique_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE members (id INTEGER, code TEXT, active INTEGER); CREATE UNIQUE INDEX members_active_code ON members (code) WHERE active = 1;");
    setup.deinit();
    var first = try db.exec("INSERT INTO members VALUES (1, 'dup', 1);");
    first.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO members VALUES (2, 'dup', 1);"));
    var inactive = try db.exec("INSERT INTO members VALUES (3, 'dup', 0);");
    inactive.deinit();
    var nullActive = try db.exec("INSERT INTO members VALUES (4, 'dup', NULL);");
    nullActive.deinit();
    var rows = try db.exec("SELECT id FROM members ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 3), rows.count());
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[0].integer);
    try std.testing.expectEqual(@as(i64, 3), rows.at(1)[0].integer);
    try std.testing.expectEqual(@as(i64, 4), rows.at(2)[0].integer);
}

test "partial unique index follows updates across the predicate boundary" {
    const path = "sqlite_zig_partial_update_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE flags (id INTEGER, code TEXT, active INTEGER); CREATE UNIQUE INDEX flags_active_code ON flags (code) WHERE active = 1; INSERT INTO flags VALUES (1, 'dup', 1), (2, 'dup', 0);");
    setup.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE flags SET active = 1 WHERE id = 2;"));
    var moved = try db.exec("UPDATE flags SET active = 0 WHERE id = 1;");
    moved.deinit();
    var nowAllowed = try db.exec("UPDATE flags SET active = 1 WHERE id = 2;");
    nowAllowed.deinit();
    var rows = try db.exec("SELECT id, active FROM flags ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 0), rows.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 1), rows.at(1)[1].integer);
}

test "partial unique index interacts with conflict handling" {
    const path = "sqlite_zig_partial_conflict_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE subs (id INTEGER, email TEXT, active INTEGER); CREATE UNIQUE INDEX subs_active_email ON subs (email) WHERE active = 1; INSERT INTO subs VALUES (1, 'a@test', 1);");
    setup.deinit();
    var ignored = try db.exec("INSERT OR IGNORE INTO subs VALUES (2, 'a@test', 1);");
    ignored.deinit();
    var inserted = try db.exec("INSERT OR IGNORE INTO subs VALUES (3, 'a@test', 0);");
    inserted.deinit();
    var upserted = try db.exec("INSERT INTO subs VALUES (4, 'a@test', 1) ON CONFLICT(email) DO UPDATE SET id = excluded.id;");
    upserted.deinit();
    var rows = try db.exec("SELECT id, active FROM subs ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.count());
    try std.testing.expectEqual(@as(i64, 3), rows.at(0)[0].integer);
    try std.testing.expectEqual(@as(i64, 0), rows.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 4), rows.at(1)[0].integer);
    try std.testing.expectEqual(@as(i64, 1), rows.at(1)[1].integer);
}

test "planner uses partial indexes only when implied" {
    const path = "sqlite_zig_partial_plan_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE orders (id INTEGER, amount INTEGER, active INTEGER); CREATE INDEX orders_active_id ON orders (id) WHERE active = 1; INSERT INTO orders VALUES (1, 10, 1), (2, 20, 0);");
    setup.deinit();
    var implied = try db.exec("EXPLAIN QUERY PLAN SELECT id FROM orders WHERE id = 1 AND active = 1;");
    defer implied.deinit();
    try std.testing.expect(implied.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, implied.rows[0][0].text, "orders_active_id") != null);
    var missing = try db.exec("EXPLAIN QUERY PLAN SELECT id FROM orders WHERE id = 1;");
    defer missing.deinit();
    try std.testing.expect(missing.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, missing.rows[0][0].text, "orders_active_id") == null);
    var orQuery = try db.exec("EXPLAIN QUERY PLAN SELECT id FROM orders WHERE id = 1 OR active = 1;");
    defer orQuery.deinit();
    try std.testing.expect(orQuery.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, orQuery.rows[0][0].text, "orders_active_id") == null);
    var filtered = try db.exec("SELECT amount FROM orders WHERE id = 2 AND active = 0;");
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.count());
    try std.testing.expectEqual(@as(i64, 20), filtered.rows[0][0].integer);
}

test "partial indexes persist across reopen" {
    const path = "sqlite_zig_partial_persist_test.db";
    var db = try freshDb(path);
    var setup = try db.exec("CREATE TABLE keep (id INTEGER, code TEXT, active INTEGER); CREATE UNIQUE INDEX keep_active_code ON keep (code) WHERE active = 1; INSERT INTO keep VALUES (1, 'k', 1), (2, 'k', 0);");
    setup.deinit();
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    defer dropDb(db, path);
    try std.testing.expect(db.store.findIndexConst("keep_active_code") != null);
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO keep VALUES (3, 'k', 1);"));
    var allowed = try db.exec("INSERT INTO keep VALUES (4, 'k', 0);");
    allowed.deinit();
    var check = try db.exec("EXPLAIN QUERY PLAN SELECT code FROM keep WHERE code = 'k' AND active = 1;");
    defer check.deinit();
    try std.testing.expect(check.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, check.rows[0][0].text, "keep_active_code") != null);
    var rows = try db.exec("SELECT count(*) FROM keep;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 3), rows.at(0)[0].integer);
}

test "expression index creation validates keys" {
    const path = "sqlite_zig_expr_create_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE people (id INTEGER, email TEXT, age INTEGER);");
    setup.deinit();
    var created = try db.exec("CREATE INDEX people_lower_email ON people (lower(email));");
    created.deinit();
    try std.testing.expect(db.store.findIndexConst("people_lower_email") != null);
    var multi = try db.exec("CREATE INDEX people_multi ON people (age, lower(email));");
    multi.deinit();
    try std.testing.expectError(error.UnknownColumn, db.exec("CREATE INDEX people_bad ON people (lower(missing));"));
    try std.testing.expect(db.store.findIndexConst("people_bad") == null);
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE INDEX people_const ON people (1 + 1);"));
    try std.testing.expect(db.store.findIndexConst("people_const") == null);
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE INDEX people_agg ON people (sum(age));"));
    try std.testing.expect(db.store.findIndexConst("people_agg") == null);
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE INDEX people_sub ON people ((SELECT 1));"));
    try std.testing.expect(db.store.findIndexConst("people_sub") == null);
    var dropped = try db.exec("DROP INDEX people_lower_email;");
    dropped.deinit();
    var droppedMulti = try db.exec("DROP INDEX people_multi;");
    droppedMulti.deinit();
}

test "expression unique index constrains computed values" {
    const path = "sqlite_zig_expr_unique_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE accounts (id INTEGER, email TEXT); CREATE UNIQUE INDEX accounts_lower_email ON accounts (lower(email));");
    setup.deinit();
    var first = try db.exec("INSERT INTO accounts VALUES (1, 'A@Test');");
    first.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO accounts VALUES (2, 'a@test');"));
    var other = try db.exec("INSERT INTO accounts VALUES (3, 'b@test');");
    other.deinit();
    var ignored = try db.exec("INSERT OR IGNORE INTO accounts VALUES (4, 'A@TEST');");
    ignored.deinit();
    var rows = try db.exec("SELECT id, email FROM accounts ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.count());
    try std.testing.expectEqualStrings("A@Test", rows.at(0)[1].text);
    try std.testing.expectEqualStrings("b@test", rows.at(1)[1].text);
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE accounts SET email = 'B@TEST' WHERE id = 1;"));
    var moved = try db.exec("UPDATE accounts SET email = 'c@test' WHERE id = 1;");
    moved.deinit();
    var after = try db.exec("SELECT email FROM accounts WHERE id = 1;");
    defer after.deinit();
    try std.testing.expectEqualStrings("c@test", after.rows[0][0].text);
}

test "planner uses expression indexes on matching predicates" {
    const path = "sqlite_zig_expr_plan_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE contacts (id INTEGER, email TEXT); CREATE INDEX contacts_lower_email ON contacts (lower(email)); INSERT INTO contacts VALUES (1, 'A@Test'), (2, 'b@test');");
    setup.deinit();
    var matched = try db.exec("EXPLAIN QUERY PLAN SELECT email FROM contacts WHERE lower(email) = 'a@test';");
    defer matched.deinit();
    try std.testing.expect(matched.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, matched.rows[0][0].text, "contacts_lower_email") != null);
    var plain = try db.exec("EXPLAIN QUERY PLAN SELECT email FROM contacts WHERE email = 'a@test';");
    defer plain.deinit();
    try std.testing.expect(plain.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, plain.rows[0][0].text, "contacts_lower_email") == null);
    var orQuery = try db.exec("EXPLAIN QUERY PLAN SELECT email FROM contacts WHERE lower(email) = 'a@test' OR id = 1;");
    defer orQuery.deinit();
    try std.testing.expect(orQuery.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, orQuery.rows[0][0].text, "contacts_lower_email") == null);
    var found = try db.exec("SELECT id FROM contacts WHERE lower(email) = 'b@test';");
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 1), found.count());
    try std.testing.expectEqual(@as(i64, 2), found.rows[0][0].integer);
}

test "expression and partial index combine correctly" {
    const path = "sqlite_zig_expr_partial_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE staff (id INTEGER, email TEXT, active INTEGER); CREATE UNIQUE INDEX staff_active_lower ON staff (lower(email)) WHERE active = 1;");
    setup.deinit();
    var first = try db.exec("INSERT INTO staff VALUES (1, 'A@Test', 1);");
    first.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO staff VALUES (2, 'a@test', 1);"));
    var inactive = try db.exec("INSERT INTO staff VALUES (3, 'A@TEST', 0);");
    inactive.deinit();
    var rows = try db.exec("SELECT count(*) FROM staff;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 2), rows.at(0)[0].integer);
    var planned = try db.exec("EXPLAIN QUERY PLAN SELECT email FROM staff WHERE lower(email) = 'a@test' AND active = 1;");
    defer planned.deinit();
    try std.testing.expect(planned.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, planned.rows[0][0].text, "staff_active_lower") != null);
}

test "expression indexes persist across reopen" {
    const path = "sqlite_zig_expr_persist_test.db";
    var db = try freshDb(path);
    var setup = try db.exec("CREATE TABLE persist (id INTEGER, email TEXT); CREATE UNIQUE INDEX persist_lower_email ON persist (lower(email)); INSERT INTO persist VALUES (1, 'A@Test');");
    setup.deinit();
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    defer dropDb(db, path);
    try std.testing.expect(db.store.findIndexConst("persist_lower_email") != null);
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO persist VALUES (2, 'a@test');"));
    var allowed = try db.exec("INSERT INTO persist VALUES (3, 'other@test');");
    allowed.deinit();
    var check = try db.exec("EXPLAIN QUERY PLAN SELECT email FROM persist WHERE lower(email) = 'other@test';");
    defer check.deinit();
    try std.testing.expect(check.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, check.rows[0][0].text, "persist_lower_email") != null);
    var rows = try db.exec("SELECT count(*) FROM persist;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 2), rows.at(0)[0].integer);
}

test "dynamic and typed DSL support insert-select" {
    const Src = @import("../dsl/table.zig").table("dsl_src_items", struct { id: i64, label: []const u8 });
    const Dst = @import("../dsl/table.zig").table("dsl_dst_items", struct { id: i64, label: []const u8 });
    const path = "sqlite_zig_dsl_insert_select_test.db";
    var db = try freshDb(path);
    const t_db_dsl_dst_items = db.table("dsl_dst_items");
    const t_db_dsl_src_items = db.table("dsl_src_items");
    defer dropDb(db, path);
    try db.createTable(Src, .{});
    try db.createTable(Dst, .{});
    var seed = try db.from(Src).insert(.{ .id = 1, .label = "one" });
    seed.deinit();
    var seed2 = try db.exec("INSERT INTO dsl_src_items VALUES (2, 'two'), (3, 'three');");
    seed2.deinit();
    var copied = try db.from(Dst).insertSelect(db.from(Src).select(.{ Src.id, Src.label }));
    defer copied.deinit();
    try std.testing.expectEqual(@as(usize, 3), copied.changes);
    var rows = try db.from(Dst).select(.{Dst.id}).fetch();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 3), rows.count());
    var filtered = try t_db_dsl_dst_items.insertSelect(
        t_db_dsl_src_items.select(.{ t_db_dsl_src_items.column("id"), t_db_dsl_src_items.column("label") }).where(t_db_dsl_src_items.column("id").gt(10)),
    );
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 0), filtered.changes);
    var resized = try db.exec("SELECT count(*) FROM dsl_dst_items;");
    defer resized.deinit();
    try std.testing.expectEqual(@as(i64, 3), resized.rows[0][0].integer);
    var returning = try db.from(Dst).returning(.{Dst.id}).insertSelect(
        db.from(Src).select(.{ Src.id, Src.label }).where(Src.id.eq(1)),
    );
    defer returning.deinit();
    try std.testing.expectEqual(@as(usize, 1), returning.count());
    try std.testing.expectEqual(@as(i64, 1), returning.rows[0][0].integer);
}

test "dynamic and typed DSL support update-from" {
    const Bal = @import("../dsl/table.zig").table("dsl_balances", struct { id: i64, amount: i64, flag: i64 });
    const Adj = @import("../dsl/table.zig").table("dsl_adjustments", struct { id: i64, bal_id: i64 });
    const path = "sqlite_zig_dsl_update_from_test.db";
    var db = try freshDb(path);
    const t_db_dsl_balances = db.table("dsl_balances");
    const t_db_dsl_adjustments = db.table("dsl_adjustments");
    defer dropDb(db, path);
    try db.createTable(Bal, .{});
    try db.createTable(Adj, .{});
    var seed = try db.exec("INSERT INTO dsl_balances VALUES (1, 100, 0), (2, 200, 0); INSERT INTO dsl_adjustments VALUES (10, 1);");
    seed.deinit();
    var mutation = try db.from(Bal).update(.{ .flag = 1 });
    var updated = try mutation.updateFrom(Adj, Bal.id.eq(Adj.bal_id)).execute();
    defer updated.deinit();
    try std.testing.expectEqual(@as(usize, 1), updated.changes);
    var rows = try db.exec("SELECT id, flag FROM dsl_balances ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[1].integer);
    try std.testing.expectEqual(@as(i64, 0), rows.at(1)[1].integer);
    var dynMutation = try t_db_dsl_balances.update(.{ .flag = 7 });
    var dynUpdated = try dynMutation.updateFrom("dsl_adjustments", t_db_dsl_balances.column("id").eq(t_db_dsl_adjustments.column("bal_id"))).where(t_db_dsl_balances.column("id").eq(2)).execute();
    defer dynUpdated.deinit();
    try std.testing.expectEqual(@as(usize, 0), dynUpdated.changes);
    var again = try db.exec("SELECT flag FROM dsl_balances WHERE id = 2;");
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 1), again.count());
    try std.testing.expectEqual(@as(i64, 0), again.rows[0][0].integer);
    var doomed = db.from(Bal).delete();
    try std.testing.expectError(error.InvalidSql, doomed.updateFrom(Adj, Bal.id.eq(Adj.bal_id)).execute());
}

test "DSL creates partial and expression indexes" {
    const Item = @import("../dsl/table.zig").table("dsl_idx_items", struct { id: i64, email: []const u8, active: i64 });
    const path = "sqlite_zig_dsl_index_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(Item, .{});
    try db.createIndexWhere(Item, "dsl_idx_active", .{Item.id}, false, "active = 1");
    try std.testing.expect(db.store.findIndexConst("dsl_idx_active") != null);
    try db.createIndexExpr("dsl_idx_items", "dsl_idx_lower", &.{"lower(email)"}, false, null);
    try std.testing.expect(db.store.findIndexConst("dsl_idx_lower") != null);
    try db.createIndexExpr(Item, "dsl_idx_combined", &.{"lower(email)"}, true, "active = 1");
    try std.testing.expect(db.store.findIndexConst("dsl_idx_combined") != null);
    try std.testing.expectError(error.UnknownColumn, db.createIndexWhere(Item, "dsl_idx_bad", .{Item.id}, false, "missing = 1"));
    try std.testing.expect(db.store.findIndexConst("dsl_idx_bad") == null);
    var first = try db.from(Item).insert(.{ .id = 1, .email = "A@Test", .active = 1 });
    first.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Item).insert(.{ .id = 2, .email = "a@test", .active = 1 }));
    var inactive = try db.from(Item).insert(.{ .id = 3, .email = "a@test", .active = 0 });
    inactive.deinit();
    var planned = try db.exec("EXPLAIN QUERY PLAN SELECT email FROM dsl_idx_items WHERE lower(email) = 'a@test' AND active = 1;");
    defer planned.deinit();
    try std.testing.expect(planned.count() > 0);
    try std.testing.expect(std.mem.indexOf(u8, planned.rows[0][0].text, "dsl_idx_combined") != null);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    try std.testing.expect(db.store.findIndexConst("dsl_idx_active") != null);
    try std.testing.expect(db.store.findIndexConst("dsl_idx_lower") != null);
    try std.testing.expect(db.store.findIndexConst("dsl_idx_combined") != null);
    try std.testing.expectError(error.ConstraintViolation, db.from(Item).insert(.{ .id = 4, .email = "A@TEST", .active = 1 }));
}

test "insert conflict policies control statement atomicity" {
    const path = "sqlite_zig_conflict_atomicity_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE conflicts (id INTEGER, code TEXT UNIQUE);");
    setup.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO conflicts VALUES (1, 'a'), (2, 'a');"));
    var none = try db.exec("SELECT count(*) FROM conflicts;");
    defer none.deinit();
    try std.testing.expectEqual(@as(i64, 0), none.rows[0][0].integer);
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT OR ABORT INTO conflicts VALUES (3, 'b'), (4, 'b');"));
    var aborted = try db.exec("SELECT count(*) FROM conflicts;");
    defer aborted.deinit();
    try std.testing.expectEqual(@as(i64, 0), aborted.rows[0][0].integer);
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT OR FAIL INTO conflicts VALUES (5, 'c'), (6, 'c');"));
    var failed = try db.exec("SELECT id FROM conflicts ORDER BY id;");
    defer failed.deinit();
    try std.testing.expectEqual(@as(usize, 1), failed.count());
    try std.testing.expectEqual(@as(i64, 5), failed.rows[0][0].integer);
    var cleanup = try db.exec("DELETE FROM conflicts;");
    cleanup.deinit();
    var begun = try db.exec("BEGIN;");
    begun.deinit();
    var first = try db.exec("INSERT INTO conflicts VALUES (7, 'd');");
    first.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT OR ROLLBACK INTO conflicts VALUES (8, 'd');"));
    try std.testing.expectError(error.NotInTransaction, db.exec("COMMIT;"));
    var rolled = try db.exec("SELECT count(*) FROM conflicts;");
    defer rolled.deinit();
    try std.testing.expectEqual(@as(i64, 0), rolled.rows[0][0].integer);
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT OR ROLLBACK INTO conflicts VALUES (9, 'e'), (10, 'e');"));
    var outside = try db.exec("SELECT count(*) FROM conflicts;");
    defer outside.deinit();
    try std.testing.expectEqual(@as(i64, 0), outside.rows[0][0].integer);
}

test "insert DSL conflict policies match raw SQL" {
    const Item = @import("../dsl/table.zig").table("dsl_conflict_items", struct { id: i64, code: []const u8 });
    const path = "sqlite_zig_dsl_conflict_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(Item, .{ .unique = &.{Item.code} });
    var first = try db.from(Item).insertOrFail(.{ .id = 1, .code = "a" });
    first.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Item).insertOrFail(.{ .id = 2, .code = "a" }));
    var kept = try db.exec("SELECT id FROM dsl_conflict_items ORDER BY id;");
    defer kept.deinit();
    try std.testing.expectEqual(@as(usize, 1), kept.count());
    try std.testing.expectError(error.ConstraintViolation, db.from(Item).insertOrAbort(.{ .id = 3, .code = "a" }));
    var begun = try db.exec("BEGIN;");
    begun.deinit();
    var inside = try db.from(Item).insert(.{ .id = 4, .code = "b" });
    inside.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Item).insertOrRollback(.{ .id = 5, .code = "b" }));
    try std.testing.expectError(error.NotInTransaction, db.exec("COMMIT;"));
    var gone = try db.exec("SELECT count(*) FROM dsl_conflict_items;");
    defer gone.deinit();
    try std.testing.expectEqual(@as(i64, 1), gone.rows[0][0].integer);
}

test "update conflict policies skip or replace conflicting rows" {
    const path = "sqlite_zig_update_conflict_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE upds (id INTEGER, code TEXT UNIQUE); INSERT INTO upds VALUES (1, 'a'), (2, 'b');");
    setup.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE upds SET code = 'x';"));
    var intact = try db.exec("SELECT code FROM upds ORDER BY id;");
    defer intact.deinit();
    try std.testing.expectEqualStrings("a", intact.rows[0][0].text);
    try std.testing.expectEqualStrings("b", intact.rows[1][0].text);
    var ignored = try db.exec("UPDATE OR IGNORE upds SET code = 'x';");
    defer ignored.deinit();
    try std.testing.expectEqual(@as(usize, 1), ignored.changes);
    var skipped = try db.exec("SELECT code FROM upds ORDER BY id;");
    defer skipped.deinit();
    try std.testing.expectEqualStrings("x", skipped.rows[0][0].text);
    try std.testing.expectEqualStrings("b", skipped.rows[1][0].text);
    var replaced = try db.exec("UPDATE OR REPLACE upds SET code = 'b' WHERE id = 1;");
    defer replaced.deinit();
    try std.testing.expectEqual(@as(usize, 1), replaced.changes);
    var final = try db.exec("SELECT id, code FROM upds ORDER BY id;");
    defer final.deinit();
    try std.testing.expectEqual(@as(usize, 1), final.count());
    try std.testing.expectEqual(@as(i64, 1), final.rows[0][0].integer);
    try std.testing.expectEqualStrings("b", final.rows[0][1].text);
}

test "update or rollback discards the enclosing transaction" {
    const path = "sqlite_zig_update_rollback_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE rb (id INTEGER, code TEXT UNIQUE); INSERT INTO rb VALUES (1, 'a'), (2, 'b');");
    setup.deinit();
    var begun = try db.exec("BEGIN;");
    begun.deinit();
    var good = try db.exec("UPDATE rb SET code = 'c' WHERE id = 1;");
    good.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE OR ROLLBACK rb SET code = 'c' WHERE id = 2;"));
    try std.testing.expectError(error.NotInTransaction, db.exec("COMMIT;"));
    var rows = try db.exec("SELECT code FROM rb ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqualStrings("a", rows.at(0)[0].text);
    try std.testing.expectEqualStrings("b", rows.at(1)[0].text);
}

test "delete failures roll back the statement" {
    const path = "sqlite_zig_delete_atomicity_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE del_parent (id INTEGER PRIMARY KEY); CREATE TABLE del_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES del_parent(id) ON DELETE RESTRICT); INSERT INTO del_parent VALUES (1), (2); INSERT INTO del_child VALUES (10, 2);");
    setup.deinit();
    var off = try db.exec("PRAGMA foreign_keys = ON;");
    off.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("DELETE FROM del_parent;"));
    var parents = try db.exec("SELECT count(*) FROM del_parent;");
    defer parents.deinit();
    try std.testing.expectEqual(@as(i64, 2), parents.rows[0][0].integer);
    var children = try db.exec("SELECT count(*) FROM del_child;");
    defer children.deinit();
    try std.testing.expectEqual(@as(i64, 1), children.rows[0][0].integer);
}

test "statement errors preserve enclosing savepoints" {
    const path = "sqlite_zig_statement_savepoint_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE sps (id INTEGER, code TEXT UNIQUE);");
    setup.deinit();
    var begun = try db.exec("BEGIN;");
    begun.deinit();
    var first = try db.exec("INSERT INTO sps VALUES (1, 'a');");
    first.deinit();
    var point = try db.exec("SAVEPOINT sp1;");
    point.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO sps VALUES (2, 'a'), (3, 'b');"));
    var back = try db.exec("ROLLBACK TO sp1;");
    back.deinit();
    var released = try db.exec("RELEASE sp1;");
    released.deinit();
    var committed = try db.exec("COMMIT;");
    committed.deinit();
    var rows = try db.exec("SELECT id FROM sps ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[0].integer);
}

test "with clause backs insert, update, and delete" {
    const path = "sqlite_zig_cte_mutation_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE cte_items (id INTEGER, label TEXT); CREATE TABLE cte_archive (id INTEGER, label TEXT); INSERT INTO cte_items VALUES (1, 'one'), (2, 'two'), (3, 'three');");
    setup.deinit();
    var copied = try db.exec("WITH big AS (SELECT id, label FROM cte_items WHERE id > 1) INSERT INTO cte_archive SELECT id, label FROM big;");
    defer copied.deinit();
    try std.testing.expectEqual(@as(usize, 2), copied.changes);
    var archived = try db.exec("SELECT id FROM cte_archive ORDER BY id;");
    defer archived.deinit();
    try std.testing.expectEqual(@as(usize, 2), archived.count());
    try std.testing.expectEqual(@as(i64, 2), archived.rows[0][0].integer);
    var updated = try db.exec("WITH target AS (SELECT id FROM cte_items WHERE id = 1) UPDATE cte_items SET label = 'ONE' WHERE id IN (SELECT id FROM target);");
    defer updated.deinit();
    try std.testing.expectEqual(@as(usize, 1), updated.changes);
    var renamed = try db.exec("SELECT label FROM cte_items WHERE id = 1;");
    defer renamed.deinit();
    try std.testing.expectEqualStrings("ONE", renamed.rows[0][0].text);
    var deleted = try db.exec("WITH gone AS (SELECT id FROM cte_items WHERE id = 3) DELETE FROM cte_items WHERE id IN (SELECT id FROM gone);");
    defer deleted.deinit();
    try std.testing.expectEqual(@as(usize, 1), deleted.changes);
    var remaining = try db.exec("SELECT count(*) FROM cte_items;");
    defer remaining.deinit();
    try std.testing.expectEqual(@as(i64, 2), remaining.rows[0][0].integer);
}

test "with recursive backs insert with returning" {
    const path = "sqlite_zig_cte_recursive_mutation_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE fib (n INTEGER);");
    setup.deinit();
    var inserted = try db.exec("WITH RECURSIVE nums AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM nums WHERE n < 4) INSERT INTO fib SELECT n FROM nums RETURNING n;");
    defer inserted.deinit();
    try std.testing.expectEqual(@as(usize, 4), inserted.count());
    try std.testing.expectEqual(@as(i64, 1), inserted.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 4), inserted.rows[3][0].integer);
    var rows = try db.exec("SELECT sum(n) FROM fib;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 10), rows.at(0)[0].integer);
}

test "writing to a cte name fails without changing state" {
    const path = "sqlite_zig_cte_write_guard_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE real_items (id INTEGER); INSERT INTO real_items VALUES (1);");
    setup.deinit();
    try std.testing.expectError(error.InvalidSql, db.exec("WITH tmp AS (SELECT id FROM real_items) INSERT INTO tmp VALUES (2);"));
    try std.testing.expectError(error.InvalidSql, db.exec("WITH tmp AS (SELECT id FROM real_items) UPDATE tmp SET id = 9;"));
    try std.testing.expectError(error.InvalidSql, db.exec("WITH tmp AS (SELECT id FROM real_items) DELETE FROM tmp;"));
    var rows = try db.exec("SELECT count(*) FROM real_items;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[0].integer);
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT count(*) FROM tmp;"));
}

test "with clause combines with upsert and constraints" {
    const path = "sqlite_zig_cte_upsert_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE upsert_items (id INTEGER PRIMARY KEY, label TEXT); INSERT INTO upsert_items VALUES (1, 'old');");
    setup.deinit();
    var merged = try db.exec("WITH fresh AS (SELECT 1 AS id, 'new' AS label UNION ALL SELECT 2, 'two') INSERT INTO upsert_items SELECT id, label FROM fresh ON CONFLICT(id) DO UPDATE SET label = excluded.label;");
    defer merged.deinit();
    var rows = try db.exec("SELECT id, label FROM upsert_items ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 2), rows.count());
    try std.testing.expectEqualStrings("new", rows.at(0)[1].text);
    try std.testing.expectEqualStrings("two", rows.at(1)[1].text);
    try std.testing.expectError(error.ConstraintViolation, db.exec("WITH bad AS (SELECT 1 AS id) INSERT INTO upsert_items (id) VALUES (1);"));
    var intact = try db.exec("SELECT count(*) FROM upsert_items;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(i64, 2), intact.rows[0][0].integer);
}

test "update of triggers fire only for listed columns" {
    const path = "sqlite_zig_update_of_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE accounts (id INTEGER, balance INTEGER, note TEXT); CREATE TABLE audit (id INTEGER, balance INTEGER); INSERT INTO accounts VALUES (1, 100, 'a');");
    setup.deinit();
    var created = try db.exec("CREATE TRIGGER audit_balance AFTER UPDATE OF balance ON accounts BEGIN INSERT INTO audit VALUES (NEW.id, NEW.balance); END;");
    created.deinit();
    var untouched = try db.exec("UPDATE accounts SET note = 'b' WHERE id = 1;");
    untouched.deinit();
    var quiet = try db.exec("SELECT count(*) FROM audit;");
    defer quiet.deinit();
    try std.testing.expectEqual(@as(i64, 0), quiet.rows[0][0].integer);
    var changed = try db.exec("UPDATE accounts SET balance = 200 WHERE id = 1;");
    changed.deinit();
    var logged = try db.exec("SELECT id, balance FROM audit;");
    defer logged.deinit();
    try std.testing.expectEqual(@as(usize, 1), logged.count());
    try std.testing.expectEqual(@as(i64, 1), logged.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 200), logged.rows[0][1].integer);
    var dropFirst = try db.exec("DROP TRIGGER audit_balance;");
    dropFirst.deinit();
    var combo = try db.exec("CREATE TRIGGER big_balance AFTER UPDATE OF balance ON accounts WHEN NEW.balance > 1000 BEGIN INSERT INTO audit VALUES (NEW.id, NEW.balance); END;");
    combo.deinit();
    var small = try db.exec("UPDATE accounts SET balance = 300 WHERE id = 1;");
    small.deinit();
    var stillOne = try db.exec("SELECT count(*) FROM audit;");
    defer stillOne.deinit();
    try std.testing.expectEqual(@as(i64, 1), stillOne.rows[0][0].integer);
    var big = try db.exec("UPDATE accounts SET balance = 2000 WHERE id = 1;");
    big.deinit();
    var two = try db.exec("SELECT balance FROM audit ORDER BY balance;");
    defer two.deinit();
    try std.testing.expectEqual(@as(usize, 2), two.count());
    try std.testing.expectEqual(@as(i64, 2000), two.rows[1][0].integer);
    var noteOnly = try db.exec("UPDATE accounts SET note = 'c' WHERE id = 1;");
    noteOnly.deinit();
    var auditRows = try db.exec("SELECT count(*) FROM audit;");
    defer auditRows.deinit();
    try std.testing.expectEqual(@as(i64, 2), auditRows.rows[0][0].integer);
}

test "update of rejects unknown columns and non-update events" {
    const path = "sqlite_zig_update_of_errors_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE t (id INTEGER, v INTEGER);");
    setup.deinit();
    try std.testing.expectError(error.UnknownColumn, db.exec("CREATE TRIGGER bad_of AFTER UPDATE OF missing ON t BEGIN SELECT 1; END;"));
    try std.testing.expect(db.store.findTriggerConst("bad_of") == null);
    try std.testing.expectError(error.UnexpectedToken, db.exec("CREATE TRIGGER bad_event BEFORE INSERT OF v ON t BEGIN SELECT 1; END;"));
    try std.testing.expect(db.store.findTriggerConst("bad_event") == null);
    var rows = try db.exec("SELECT count(*) FROM t;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 0), rows.at(0)[0].integer);
}

test "update of triggers persist and interact with upsert" {
    const path = "sqlite_zig_update_of_persist_test.db";
    var db = try freshDb(path);
    var setup = try db.exec("CREATE TABLE stock (id INTEGER PRIMARY KEY, qty INTEGER); CREATE TABLE stock_log (id INTEGER); INSERT INTO stock VALUES (1, 10); CREATE TRIGGER log_qty AFTER UPDATE OF qty ON stock BEGIN INSERT INTO stock_log VALUES (NEW.id); END;");
    setup.deinit();
    var sameValue = try db.exec("UPDATE stock SET qty = 10 WHERE id = 1;");
    sameValue.deinit();
    var upserted = try db.exec("INSERT INTO stock VALUES (1, 20) ON CONFLICT(id) DO UPDATE SET qty = excluded.qty;");
    upserted.deinit();
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    defer dropDb(db, path);
    try std.testing.expect(db.store.findTriggerConst("log_qty") != null);
    var logged = try db.exec("SELECT count(*) FROM stock_log;");
    defer logged.deinit();
    try std.testing.expectEqual(@as(i64, 2), logged.rows[0][0].integer);
    var untouched = try db.exec("UPDATE stock SET id = 1 WHERE id = 1;");
    untouched.deinit();
    var still = try db.exec("SELECT count(*) FROM stock_log;");
    defer still.deinit();
    try std.testing.expectEqual(@as(i64, 2), still.rows[0][0].integer);
}

test "analyze collects table and index statistics" {
    const path = "sqlite_zig_analyze_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE stat_items (id INTEGER, code TEXT, active INTEGER); CREATE UNIQUE INDEX stat_id_idx ON stat_items (id); CREATE INDEX stat_code_idx ON stat_items (code); CREATE INDEX stat_active_code_idx ON stat_items (active, code); CREATE UNIQUE INDEX stat_partial_idx ON stat_items (code) WHERE active = 1; CREATE INDEX stat_expr_idx ON stat_items (lower(code)); INSERT INTO stat_items VALUES (1, 'a', 1), (2, 'a', 0), (3, 'b', 1), (4, 'b', 0);");
    setup.deinit();
    var analyzed = try db.exec("ANALYZE;");
    analyzed.deinit();
    var tableStat = try db.exec("SELECT stat FROM sqlite_stat1 WHERE tbl = 'stat_items' AND idx IS NULL;");
    defer tableStat.deinit();
    try std.testing.expectEqual(@as(usize, 1), tableStat.count());
    try std.testing.expectEqualStrings("4", tableStat.rows[0][0].text);
    var uniqueStat = try db.exec("SELECT stat FROM sqlite_stat1 WHERE idx = 'stat_id_idx';");
    defer uniqueStat.deinit();
    try std.testing.expectEqualStrings("4 1", uniqueStat.rows[0][0].text);
    var plainStat = try db.exec("SELECT stat FROM sqlite_stat1 WHERE idx = 'stat_code_idx';");
    defer plainStat.deinit();
    try std.testing.expectEqualStrings("4 2", plainStat.rows[0][0].text);
    var compositeStat = try db.exec("SELECT stat FROM sqlite_stat1 WHERE idx = 'stat_active_code_idx';");
    defer compositeStat.deinit();
    try std.testing.expectEqualStrings("4 2 1", compositeStat.rows[0][0].text);
    var partialStat = try db.exec("SELECT stat FROM sqlite_stat1 WHERE idx = 'stat_partial_idx';");
    defer partialStat.deinit();
    try std.testing.expectEqualStrings("2 1", partialStat.rows[0][0].text);
    var exprStat = try db.exec("SELECT stat FROM sqlite_stat1 WHERE idx = 'stat_expr_idx';");
    defer exprStat.deinit();
    try std.testing.expectEqualStrings("4 2", exprStat.rows[0][0].text);
}

test "analyze supports table, index, and schema targets" {
    const path = "sqlite_zig_analyze_target_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE scope_a (id INTEGER); CREATE TABLE scope_b (id INTEGER); CREATE INDEX scope_a_idx ON scope_a (id); INSERT INTO scope_a VALUES (1), (2); INSERT INTO scope_b VALUES (1), (2), (3);");
    setup.deinit();
    var scoped = try db.exec("ANALYZE scope_a;");
    scoped.deinit();
    var aStat = try db.exec("SELECT stat FROM sqlite_stat1 WHERE tbl = 'scope_a' AND idx IS NULL;");
    defer aStat.deinit();
    try std.testing.expectEqualStrings("2", aStat.rows[0][0].text);
    var bMissing = try db.exec("SELECT count(*) FROM sqlite_stat1 WHERE tbl = 'scope_b';");
    defer bMissing.deinit();
    try std.testing.expectEqual(@as(i64, 0), bMissing.rows[0][0].integer);
    var indexed = try db.exec("ANALYZE scope_a_idx;");
    indexed.deinit();
    var idxStat = try db.exec("SELECT stat FROM sqlite_stat1 WHERE idx = 'scope_a_idx';");
    defer idxStat.deinit();
    try std.testing.expectEqualStrings("2 1", idxStat.rows[0][0].text);
    var mainScoped = try db.exec("ANALYZE main;");
    mainScoped.deinit();
    var bNow = try db.exec("SELECT stat FROM sqlite_stat1 WHERE tbl = 'scope_b' AND idx IS NULL;");
    defer bNow.deinit();
    try std.testing.expectEqualStrings("3", bNow.rows[0][0].text);
    try std.testing.expectError(error.UnknownTable, db.exec("ANALYZE nope;"));
    var intact = try db.exec("SELECT count(*) FROM sqlite_stat1;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(i64, 3), intact.rows[0][0].integer);
}

test "analyze refreshes stale statistics" {
    const path = "sqlite_zig_analyze_stale_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE stale (id INTEGER); CREATE INDEX stale_idx ON stale (id); INSERT INTO stale VALUES (1), (2);");
    setup.deinit();
    var first = try db.exec("ANALYZE;");
    first.deinit();
    var grown = try db.exec("INSERT INTO stale VALUES (3), (4), (5);");
    grown.deinit();
    var before = try db.exec("SELECT stat FROM sqlite_stat1 WHERE tbl = 'stale' AND idx IS NULL;");
    defer before.deinit();
    try std.testing.expectEqualStrings("2", before.rows[0][0].text);
    var second = try db.exec("ANALYZE stale;");
    second.deinit();
    var after = try db.exec("SELECT stat FROM sqlite_stat1 WHERE tbl = 'stale' AND idx IS NULL;");
    defer after.deinit();
    try std.testing.expectEqualStrings("5", after.rows[0][0].text);
    var dropped = try db.exec("DROP INDEX stale_idx;");
    dropped.deinit();
    var gone = try db.exec("SELECT count(*) FROM sqlite_stat1 WHERE idx = 'stale_idx';");
    defer gone.deinit();
    try std.testing.expectEqual(@as(i64, 0), gone.rows[0][0].integer);
}

test "analyze persists and rolls back with transactions" {
    const path = "sqlite_zig_analyze_txn_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE txn_items (id INTEGER); INSERT INTO txn_items VALUES (1);");
    setup.deinit();
    var begun = try db.exec("BEGIN;");
    begun.deinit();
    var analyzed = try db.exec("ANALYZE;");
    analyzed.deinit();
    var rolled = try db.exec("ROLLBACK;");
    rolled.deinit();
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT count(*) FROM sqlite_stat1;"));
    var committed = try db.exec("ANALYZE;");
    committed.deinit();
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    var rows = try db.exec("SELECT stat FROM sqlite_stat1 WHERE tbl = 'txn_items' AND idx IS NULL;");
    defer rows.deinit();
    try std.testing.expectEqualStrings("1", rows.at(0)[0].text);
}

test "cte column lists rename projected columns" {
    const path = "sqlite_zig_cte_columns_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE base_items (id INTEGER); INSERT INTO base_items VALUES (1), (2);");
    setup.deinit();
    var renamed = try db.exec("WITH vals(x) AS (SELECT id FROM base_items) SELECT x FROM vals ORDER BY x;");
    defer renamed.deinit();
    try std.testing.expectEqual(@as(usize, 2), renamed.count());
    try std.testing.expectEqualStrings("x", renamed.columns[0]);
    try std.testing.expectEqual(@as(i64, 2), renamed.rows[1][0].integer);
    var recursive = try db.exec("WITH RECURSIVE nums(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM nums WHERE n < 4) SELECT sum(n) FROM nums;");
    defer recursive.deinit();
    try std.testing.expectEqual(@as(i64, 10), recursive.rows[0][0].integer);
    var copied = try db.exec("CREATE TABLE copied (v INTEGER); WITH vals(y) AS (SELECT id FROM base_items WHERE id = 2) INSERT INTO copied SELECT y FROM vals;");
    defer copied.deinit();
    var stored = try db.exec("SELECT v FROM copied;");
    defer stored.deinit();
    try std.testing.expectEqual(@as(i64, 2), stored.rows[0][0].integer);
    try std.testing.expectError(error.ColumnCountMismatch, db.exec("WITH bad(a, b) AS (SELECT id FROM base_items) SELECT a FROM bad;"));
    var intact = try db.exec("SELECT count(*) FROM base_items;");
    defer intact.deinit();
    try std.testing.expectEqual(@as(i64, 2), intact.rows[0][0].integer);
}

test "recursive union all keeps duplicates while union dedups" {
    const path = "sqlite_zig_recursive_dup_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE seed (x INTEGER); INSERT INTO seed VALUES (0), (1);");
    setup.deinit();
    var kept = try db.exec("WITH RECURSIVE c(x) AS (SELECT x FROM seed UNION ALL SELECT 0 FROM c WHERE x > 0) SELECT x FROM c ORDER BY x;");
    defer kept.deinit();
    try std.testing.expectEqual(@as(usize, 3), kept.count());
    try std.testing.expectEqual(@as(i64, 0), kept.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), kept.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, 1), kept.rows[2][0].integer);
    var distinct = try db.exec("WITH RECURSIVE d(x) AS (SELECT x FROM seed UNION SELECT 0 FROM d WHERE x > 0) SELECT x FROM d ORDER BY x;");
    defer distinct.deinit();
    try std.testing.expectEqual(@as(usize, 2), distinct.count());
    try std.testing.expectEqual(@as(i64, 0), distinct.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 1), distinct.rows[1][0].integer);
}

test "end commits like commit" {
    const path = "sqlite_zig_end_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE ends (id INTEGER);");
    setup.deinit();
    var begun = try db.exec("BEGIN;");
    begun.deinit();
    var inserted = try db.exec("INSERT INTO ends VALUES (1);");
    inserted.deinit();
    var ended = try db.exec("END;");
    ended.deinit();
    var rows = try db.exec("SELECT id FROM ends;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[0].integer);
    try std.testing.expectError(error.NotInTransaction, db.exec("END;"));
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    var reopened = try db.exec("SELECT count(*) FROM ends;");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(i64, 1), reopened.rows[0][0].integer);
}

test "recursive triggers skip by default and run when enabled" {
    const path = "sqlite_zig_recursive_trigger_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE rec (id INTEGER);");
    setup.deinit();
    var flag = try db.exec("PRAGMA recursive_triggers;");
    defer flag.deinit();
    try std.testing.expectEqual(@as(i64, 0), flag.rows[0][0].integer);
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA recursive_triggers = sometimes;"));
    var trigger = try db.exec("CREATE TRIGGER rec_self AFTER INSERT ON rec BEGIN INSERT INTO rec VALUES (NEW.id + 1); END;");
    trigger.deinit();
    var first = try db.exec("INSERT INTO rec VALUES (1);");
    first.deinit();
    var twice = try db.exec("SELECT id FROM rec ORDER BY id;");
    defer twice.deinit();
    try std.testing.expectEqual(@as(usize, 2), twice.count());
    try std.testing.expectEqual(@as(i64, 2), twice.rows[1][0].integer);
    var on = try db.exec("PRAGMA recursive_triggers = ON;");
    on.deinit();
    var check = try db.exec("PRAGMA recursive_triggers;");
    defer check.deinit();
    try std.testing.expectEqual(@as(i64, 1), check.rows[0][0].integer);
    var wipe = try db.exec("DELETE FROM rec;");
    wipe.deinit();
    try std.testing.expectError(error.TriggerDepthExceeded, db.exec("INSERT INTO rec VALUES (1);"));
    var empty = try db.exec("SELECT count(*) FROM rec;");
    defer empty.deinit();
    try std.testing.expectEqual(@as(i64, 0), empty.rows[0][0].integer);
    var off = try db.exec("PRAGMA recursive_triggers = OFF;");
    off.deinit();
}

test "schema version persists and bumps on schema changes" {
    const path = "sqlite_zig_schema_version_test.db";
    var db = try freshDb(path);
    var initial = try db.exec("PRAGMA schema_version;");
    defer initial.deinit();
    try std.testing.expectEqual(@as(i64, 1), initial.rows[0][0].integer);
    var setup = try db.exec("CREATE TABLE sv (id INTEGER);");
    setup.deinit();
    var bumped = try db.exec("PRAGMA schema_version;");
    defer bumped.deinit();
    try std.testing.expectEqual(@as(i64, 2), bumped.rows[0][0].integer);
    var set = try db.exec("PRAGMA schema_version = 42;");
    set.deinit();
    var readBack = try db.exec("PRAGMA schema_version;");
    defer readBack.deinit();
    try std.testing.expectEqual(@as(i64, 42), readBack.rows[0][0].integer);
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA schema_version = 'many';"));
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    defer dropDb(db, path);
    var persisted = try db.exec("PRAGMA schema_version;");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(i64, 42), persisted.at(0)[0].integer);
}

test "wal checkpoint merges frames and reports counts" {
    const path = "sqlite_zig_wal_checkpoint_test.db";
    const walPath = "sqlite_zig_wal_checkpoint_test.db-wal";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, walPath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, walPath) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var setup = try db.exec("CREATE TABLE chk (id INTEGER);");
    setup.deinit();
    var plain = try db.exec("PRAGMA wal_checkpoint;");
    defer plain.deinit();
    try std.testing.expectEqual(@as(i64, 0), plain.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), plain.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 0), plain.rows[0][2].integer);
    var walMode = try db.exec("PRAGMA journal_mode=WAL;");
    walMode.deinit();
    var inserted = try db.exec("INSERT INTO chk VALUES (1), (2);");
    inserted.deinit();
    try std.testing.expectError(error.InvalidSql, db.exec("PRAGMA wal_checkpoint(BOGUS);"));
    var checkpoint = try db.exec("PRAGMA wal_checkpoint(TRUNCATE);");
    defer checkpoint.deinit();
    try std.testing.expectEqual(@as(i64, 0), checkpoint.rows[0][0].integer);
    try std.testing.expect(checkpoint.rows[0][1].integer > 0);
    try std.testing.expectEqual(checkpoint.rows[0][1].integer, checkpoint.rows[0][2].integer);
    var walFile = try std.Io.Dir.cwd().openFile(std.testing.io, walPath, .{ .mode = .read_only });
    defer walFile.close(std.testing.io);
    const stat = try walFile.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), stat.size);
    var rows = try db.exec("SELECT count(*) FROM chk;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 2), rows.at(0)[0].integer);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    var reopened = try db.exec("SELECT count(*) FROM chk;");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(i64, 2), reopened.rows[0][0].integer);
}

test "distinct aggregates work bare grouped and joined" {
    const path = "sqlite_zig_distinct_agg_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE d (x INTEGER, g TEXT); INSERT INTO d VALUES (1, 'a'), (2, 'a'), (2, 'a'), (NULL, 'a'), (3, 'b'), (3, 'b');");
    setup.deinit();
    var bare = try db.exec("SELECT count(DISTINCT x), sum(DISTINCT x), avg(DISTINCT x), min(DISTINCT x), max(DISTINCT x), total(DISTINCT x), group_concat(DISTINCT x), group_concat(DISTINCT x, ';') FROM d;");
    defer bare.deinit();
    try std.testing.expectEqual(@as(i64, 3), bare.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 6), bare.rows[0][1].integer);
    try std.testing.expectEqual(@as(f64, 2.0), bare.rows[0][2].real);
    try std.testing.expectEqual(@as(i64, 1), bare.rows[0][3].integer);
    try std.testing.expectEqual(@as(i64, 3), bare.rows[0][4].integer);
    try std.testing.expectEqual(@as(f64, 6.0), bare.rows[0][5].real);
    try std.testing.expectEqualStrings("1,2,3", bare.rows[0][6].text);
    try std.testing.expectEqualStrings("1;2;3", bare.rows[0][7].text);
    var grouped = try db.exec("SELECT g, count(DISTINCT x), sum(DISTINCT x) FROM d GROUP BY g ORDER BY g;");
    defer grouped.deinit();
    try std.testing.expectEqual(@as(usize, 2), grouped.count());
    try std.testing.expectEqualStrings("a", grouped.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 2), grouped.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 3), grouped.rows[0][2].integer);
    try std.testing.expectEqualStrings("b", grouped.rows[1][0].text);
    try std.testing.expectEqual(@as(i64, 1), grouped.rows[1][1].integer);
    var having = try db.exec("SELECT g FROM d GROUP BY g HAVING count(DISTINCT x) > 1;");
    defer having.deinit();
    try std.testing.expectEqual(@as(usize, 1), having.count());
    try std.testing.expectEqualStrings("a", having.rows[0][0].text);
    var sub = try db.exec("SELECT c FROM (SELECT count(DISTINCT x) AS c FROM d);");
    defer sub.deinit();
    try std.testing.expectEqual(@as(i64, 3), sub.rows[0][0].integer);
    var tables = try db.exec("CREATE TABLE e (y INTEGER); INSERT INTO e VALUES (2), (3), (3);");
    tables.deinit();
    var joined = try db.exec("SELECT count(DISTINCT d.x), sum(DISTINCT e.y) FROM d JOIN e ON d.x = e.y;");
    defer joined.deinit();
    try std.testing.expectEqual(@as(i64, 2), joined.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 5), joined.rows[0][1].integer);
    try std.testing.expectError(error.UnexpectedToken, db.exec("SELECT count(DISTINCT *) FROM d;"));
}

test "schema introspection pragmas report catalog state" {
    const path = "sqlite_zig_pragma_info_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'anon', age INTEGER DEFAULT 18, score REAL DEFAULT 1.5, data BLOB, parent_id INTEGER REFERENCES users(id) ON DELETE CASCADE, extra TEXT GENERATED ALWAYS AS (name) VIRTUAL, backup TEXT GENERATED ALWAYS AS (name) STORED, UNIQUE(name, age));");
    setup.deinit();
    var composite = try db.exec("CREATE TABLE composite (a INTEGER, b INTEGER, c TEXT, PRIMARY KEY (a, b), FOREIGN KEY (a, b) REFERENCES users(id, age) ON UPDATE SET NULL ON DELETE RESTRICT);");
    composite.deinit();
    var wr = try db.exec("CREATE TABLE wr (k TEXT PRIMARY KEY, v INTEGER) WITHOUT ROWID, STRICT;");
    wr.deinit();
    var indexes = try db.exec("CREATE INDEX idx_users_age ON users(age); CREATE UNIQUE INDEX idx_users_name ON users(name); CREATE INDEX idx_partial ON users(age) WHERE age > 18; CREATE INDEX idx_expr ON users(lower(name));");
    indexes.deinit();
    var view = try db.exec("CREATE VIEW names AS SELECT id, name FROM users;");
    view.deinit();

    var info = try db.exec("PRAGMA table_info(users);");
    defer info.deinit();
    try std.testing.expectEqual(@as(usize, 6), info.count());
    try std.testing.expectEqualStrings("cid", info.columns[0]);
    try std.testing.expectEqualStrings("dflt_value", info.columns[4]);
    try std.testing.expectEqualStrings("pk", info.columns[5]);
    try std.testing.expectEqual(@as(i64, 0), info.rows[0][0].integer);
    try std.testing.expectEqualStrings("id", info.rows[0][1].text);
    try std.testing.expectEqualStrings("INTEGER", info.rows[0][2].text);
    try std.testing.expectEqual(@as(i64, 0), info.rows[0][3].integer);
    try std.testing.expect(info.rows[0][4] == .null);
    try std.testing.expectEqual(@as(i64, 1), info.rows[0][5].integer);
    try std.testing.expectEqualStrings("name", info.rows[1][1].text);
    try std.testing.expectEqual(@as(i64, 1), info.rows[1][3].integer);
    try std.testing.expectEqualStrings("'anon'", info.rows[1][4].text);
    try std.testing.expectEqualStrings("18", info.rows[2][4].text);
    try std.testing.expectEqualStrings("1.5", info.rows[3][4].text);
    try std.testing.expect(info.rows[4][4] == .null);
    try std.testing.expect(info.rows[5][4] == .null);

    var xinfo = try db.exec("PRAGMA table_xinfo(users);");
    defer xinfo.deinit();
    try std.testing.expectEqual(@as(usize, 8), xinfo.count());
    try std.testing.expectEqualStrings("hidden", xinfo.columns[6]);
    try std.testing.expectEqual(@as(i64, 0), xinfo.rows[0][6].integer);
    try std.testing.expectEqualStrings("extra", xinfo.rows[6][1].text);
    try std.testing.expectEqual(@as(i64, 2), xinfo.rows[6][6].integer);
    try std.testing.expect(xinfo.rows[6][4] == .null);
    try std.testing.expectEqualStrings("backup", xinfo.rows[7][1].text);
    try std.testing.expectEqual(@as(i64, 3), xinfo.rows[7][6].integer);

    var compInfo = try db.exec("PRAGMA table_info(composite);");
    defer compInfo.deinit();
    try std.testing.expectEqual(@as(i64, 1), compInfo.rows[0][5].integer);
    try std.testing.expectEqual(@as(i64, 2), compInfo.rows[1][5].integer);
    try std.testing.expectEqual(@as(i64, 0), compInfo.rows[2][5].integer);

    var viewInfo = try db.exec("PRAGMA table_info(names);");
    defer viewInfo.deinit();
    try std.testing.expectEqual(@as(usize, 2), viewInfo.count());
    try std.testing.expectEqualStrings("id", viewInfo.rows[0][1].text);
    try std.testing.expectEqualStrings("name", viewInfo.rows[1][1].text);

    var missing = try db.exec("PRAGMA table_info(nosuch);");
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.count());
    try std.testing.expectEqual(@as(usize, 6), missing.columns.len);
    var bare = try db.exec("PRAGMA table_info;");
    defer bare.deinit();
    try std.testing.expectEqual(@as(usize, 0), bare.count());
    var valueForm = try db.exec("PRAGMA table_info=users;");
    defer valueForm.deinit();
    try std.testing.expectEqual(@as(usize, 6), valueForm.count());
    var schemaForm = try db.exec("PRAGMA main.table_info(users);");
    defer schemaForm.deinit();
    try std.testing.expectEqual(@as(usize, 6), schemaForm.count());
    var tempForm = try db.exec("PRAGMA temp.table_info(users);");
    defer tempForm.deinit();
    try std.testing.expectEqual(@as(usize, 0), tempForm.count());
    try std.testing.expectError(error.Unsupported, db.exec("PRAGMA bogus.table_info(users);"));

    var indexList = try db.exec("PRAGMA index_list(users);");
    defer indexList.deinit();
    try std.testing.expectEqual(@as(usize, 5), indexList.count());
    try std.testing.expectEqualStrings("seq", indexList.columns[0]);
    try std.testing.expectEqualStrings("origin", indexList.columns[3]);
    try std.testing.expectEqualStrings("partial", indexList.columns[4]);
    try std.testing.expectEqual(@as(i64, 0), indexList.rows[0][0].integer);
    try std.testing.expectEqualStrings("sqlite_autoindex_users_1", indexList.rows[0][1].text);
    try std.testing.expectEqual(@as(i64, 1), indexList.rows[0][2].integer);
    try std.testing.expectEqualStrings("u", indexList.rows[0][3].text);
    try std.testing.expectEqualStrings("c", indexList.rows[1][3].text);
    try std.testing.expectEqual(@as(i64, 0), indexList.rows[1][4].integer);
    try std.testing.expectEqualStrings("idx_partial", indexList.rows[3][1].text);
    try std.testing.expectEqual(@as(i64, 1), indexList.rows[3][4].integer);
    var compIndexes = try db.exec("PRAGMA index_list(composite);");
    defer compIndexes.deinit();
    try std.testing.expectEqual(@as(usize, 1), compIndexes.count());
    try std.testing.expectEqualStrings("pk", compIndexes.rows[0][3].text);
    var viewIndexes = try db.exec("PRAGMA index_list(names);");
    defer viewIndexes.deinit();
    try std.testing.expectEqual(@as(usize, 0), viewIndexes.count());

    var indexInfo = try db.exec("PRAGMA index_info(idx_users_age);");
    defer indexInfo.deinit();
    try std.testing.expectEqual(@as(usize, 1), indexInfo.count());
    try std.testing.expectEqual(@as(i64, 0), indexInfo.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), indexInfo.rows[0][1].integer);
    try std.testing.expectEqualStrings("age", indexInfo.rows[0][2].text);
    var exprInfo = try db.exec("PRAGMA index_info(idx_expr);");
    defer exprInfo.deinit();
    try std.testing.expectEqual(@as(usize, 1), exprInfo.count());
    try std.testing.expectEqual(@as(i64, -1), exprInfo.rows[0][1].integer);
    try std.testing.expect(exprInfo.rows[0][2] == .null);
    var xindex = try db.exec("PRAGMA index_xinfo(idx_users_age);");
    defer xindex.deinit();
    try std.testing.expectEqual(@as(usize, 6), xindex.columns.len);
    try std.testing.expectEqual(@as(i64, 0), xindex.rows[0][3].integer);
    try std.testing.expectEqualStrings("BINARY", xindex.rows[0][4].text);
    try std.testing.expectEqual(@as(i64, 1), xindex.rows[0][5].integer);
    var missingIndex = try db.exec("PRAGMA index_info(nosuch);");
    defer missingIndex.deinit();
    try std.testing.expectEqual(@as(usize, 0), missingIndex.count());

    var fkList = try db.exec("PRAGMA foreign_key_list(users);");
    defer fkList.deinit();
    try std.testing.expectEqual(@as(usize, 1), fkList.count());
    try std.testing.expectEqual(@as(i64, 0), fkList.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), fkList.rows[0][1].integer);
    try std.testing.expectEqualStrings("users", fkList.rows[0][2].text);
    try std.testing.expectEqualStrings("parent_id", fkList.rows[0][3].text);
    try std.testing.expectEqualStrings("id", fkList.rows[0][4].text);
    try std.testing.expectEqualStrings("NO ACTION", fkList.rows[0][5].text);
    try std.testing.expectEqualStrings("CASCADE", fkList.rows[0][6].text);
    try std.testing.expectEqualStrings("NONE", fkList.rows[0][7].text);
    var compFk = try db.exec("PRAGMA foreign_key_list(composite);");
    defer compFk.deinit();
    try std.testing.expectEqual(@as(usize, 2), compFk.count());
    try std.testing.expectEqual(@as(i64, 0), compFk.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), compFk.rows[0][1].integer);
    try std.testing.expectEqualStrings("a", compFk.rows[0][3].text);
    try std.testing.expectEqualStrings("id", compFk.rows[0][4].text);
    try std.testing.expectEqualStrings("SET NULL", compFk.rows[0][5].text);
    try std.testing.expectEqualStrings("RESTRICT", compFk.rows[0][6].text);
    try std.testing.expectEqual(@as(i64, 1), compFk.rows[1][1].integer);
    try std.testing.expectEqualStrings("b", compFk.rows[1][3].text);
    try std.testing.expectEqualStrings("age", compFk.rows[1][4].text);
    var noFk = try db.exec("PRAGMA foreign_key_list(wr);");
    defer noFk.deinit();
    try std.testing.expectEqual(@as(usize, 0), noFk.count());

    var dbList = try db.exec("PRAGMA database_list;");
    defer dbList.deinit();
    try std.testing.expectEqual(@as(usize, 2), dbList.count());
    try std.testing.expectEqual(@as(i64, 0), dbList.rows[0][0].integer);
    try std.testing.expectEqualStrings("main", dbList.rows[0][1].text);
    try std.testing.expectEqualStrings(path, dbList.rows[0][2].text);
    try std.testing.expectEqualStrings("temp", dbList.rows[1][1].text);
    try std.testing.expectEqualStrings("", dbList.rows[1][2].text);

    var tableList = try db.exec("PRAGMA table_list;");
    defer tableList.deinit();
    try std.testing.expectEqual(@as(usize, 4), tableList.count());
    try std.testing.expectEqualStrings("users", tableList.rows[0][1].text);
    try std.testing.expectEqualStrings("table", tableList.rows[0][2].text);
    try std.testing.expectEqual(@as(i64, 8), tableList.rows[0][3].integer);
    try std.testing.expectEqual(@as(i64, 0), tableList.rows[0][4].integer);
    try std.testing.expectEqualStrings("wr", tableList.rows[2][1].text);
    try std.testing.expectEqual(@as(i64, 1), tableList.rows[2][4].integer);
    try std.testing.expectEqual(@as(i64, 1), tableList.rows[2][5].integer);
    try std.testing.expectEqualStrings("names", tableList.rows[3][1].text);
    try std.testing.expectEqualStrings("view", tableList.rows[3][2].text);
    try std.testing.expectEqual(@as(i64, 2), tableList.rows[3][3].integer);
    var filtered = try db.exec("PRAGMA table_list(users);");
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.count());
}

test "dsl schema version bumps and strict flags persist" {
    const path = "sqlite_zig_remaining_probe_test.db";
    var db = try freshDb(path);
    var setup = try db.exec("CREATE TABLE st (id INTEGER PRIMARY KEY, v TEXT) STRICT; CREATE TABLE wro (k TEXT PRIMARY KEY, v INTEGER) WITHOUT ROWID;");
    setup.deinit();
    var v1 = try db.exec("PRAGMA schema_version;");
    defer v1.deinit();
    const DslT = @import("../dsl/table.zig").table("probe_dsl", struct { id: i64 });
    try db.createTable(DslT, .{ .primaryKey = DslT.id });
    var v2 = try db.exec("PRAGMA schema_version;");
    defer v2.deinit();
    try std.testing.expectEqual(v1.rows[0][0].integer + 1, v2.rows[0][0].integer);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    defer dropDb(db, path);
    var strictCheck = try db.exec("PRAGMA table_list(st);");
    defer strictCheck.deinit();
    try std.testing.expectEqual(@as(i64, 1), strictCheck.rows[0][5].integer);
    var wrCheck = try db.exec("PRAGMA table_list(wro);");
    defer wrCheck.deinit();
    try std.testing.expectEqual(@as(i64, 1), wrCheck.rows[0][4].integer);
}

test "autoincrement never reuses keys across raw and dsl" {
    const path = "sqlite_zig_autoincrement_test.db";
    var db = try freshDb(path);
    const t_db_dyn_ai = db.table("dyn_ai");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE ai (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT); INSERT INTO ai VALUES (NULL, 'a'), (NULL, 'b'), (10, 'j');");
    setup.deinit();
    var seq = try db.exec("SELECT seq FROM sqlite_sequence WHERE name = 'ai';");
    defer seq.deinit();
    try std.testing.expectEqual(@as(i64, 10), seq.rows[0][0].integer);
    var next = try db.exec("INSERT INTO ai(v) VALUES ('k'); SELECT id FROM ai WHERE v = 'k';");
    defer next.deinit();
    try std.testing.expectEqual(@as(i64, 11), next.rows[0][0].integer);
    var small = try db.exec("INSERT INTO ai VALUES (5, 'e'); INSERT INTO ai(v) VALUES ('f'); SELECT id FROM ai WHERE v = 'f';");
    defer small.deinit();
    try std.testing.expectEqual(@as(i64, 12), small.rows[0][0].integer);
    var wipe = try db.exec("DELETE FROM ai WHERE id >= 11; INSERT INTO ai(v) VALUES ('g'); SELECT id FROM ai WHERE v = 'g';");
    defer wipe.deinit();
    try std.testing.expectEqual(@as(i64, 13), wipe.rows[0][0].integer);
    var bump = try db.exec("UPDATE ai SET id = 50 WHERE v = 'a'; INSERT INTO ai(v) VALUES ('h'); SELECT id FROM ai WHERE v = 'h';");
    defer bump.deinit();
    try std.testing.expectEqual(@as(i64, 51), bump.rows[0][0].integer);
    var nullUpdate = try db.exec("UPDATE ai SET id = NULL WHERE v = 'b'; SELECT id FROM ai WHERE v = 'b';");
    defer nullUpdate.deinit();
    try std.testing.expectEqual(@as(i64, 52), nullUpdate.rows[0][0].integer);
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO ai VALUES ('text', 'x');"));
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE TABLE bad1 (id TEXT PRIMARY KEY AUTOINCREMENT);"));
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE TABLE bad2 (id INT PRIMARY KEY AUTOINCREMENT);"));
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE TABLE bad3 (a INTEGER, b INTEGER, PRIMARY KEY (a, b), c INTEGER AUTOINCREMENT);"));
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE TABLE bad4 (id INTEGER PRIMARY KEY AUTOINCREMENT) WITHOUT ROWID;"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("ALTER TABLE ai ADD COLUMN extra INTEGER AUTOINCREMENT;"));
    var renamed = try db.exec("ALTER TABLE ai RENAME TO ai2; SELECT seq FROM sqlite_sequence WHERE name = 'ai2';");
    defer renamed.deinit();
    try std.testing.expectEqual(@as(i64, 52), renamed.rows[0][0].integer);
    var continued = try db.exec("INSERT INTO ai2(v) VALUES ('i'); SELECT id FROM ai2 WHERE v = 'i';");
    defer continued.deinit();
    try std.testing.expectEqual(@as(i64, 53), continued.rows[0][0].integer);
    var dropped = try db.exec("DROP TABLE ai2; SELECT count(*) FROM sqlite_sequence WHERE name = 'ai2';");
    defer dropped.deinit();
    try std.testing.expectEqual(@as(i64, 0), dropped.rows[0][0].integer);
    const DslAi = @import("../dsl/table.zig").table("dsl_ai", struct { id: ?i64, v: []const u8 });
    try db.createTable(DslAi, .{ .primaryKey = DslAi.id, .autoincrement = DslAi.id });
    var d1 = try db.from(DslAi).insert(.{ .id = null, .v = "a" });
    d1.deinit();
    var d2 = try db.from(DslAi).insert(.{ .id = null, .v = "b" });
    d2.deinit();
    var dwipe = try db.from(DslAi).delete().where(DslAi.id.eq(2)).execute();
    dwipe.deinit();
    var d3 = try db.from(DslAi).insert(.{ .id = null, .v = "c" });
    d3.deinit();
    var drows = try db.from(DslAi).selectAll().fetch();
    defer drows.deinit();
    try std.testing.expectEqual(@as(i64, 1), drows.rows[0].id.?);
    try std.testing.expectEqual(@as(i64, 3), drows.rows[1].id.?);
    try db.createTable("dyn_ai", .{
        .columns = &.{ .{ .name = "id", .type = "INTEGER", .primaryKey = true, .autoincrement = true }, .{ .name = "v", .type = "TEXT" } },
    });
    var y1 = try t_db_dyn_ai.insert(.{ .v = "a" });
    y1.deinit();
    var yrows = try db.exec("SELECT id FROM dyn_ai;");
    defer yrows.deinit();
    try std.testing.expectEqual(@as(i64, 1), yrows.rows[0][0].integer);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    var after = try db.exec("INSERT INTO dyn_ai(v) VALUES ('b'); SELECT id FROM dyn_ai WHERE v = 'b';");
    defer after.deinit();
    try std.testing.expectEqual(@as(i64, 2), after.rows[0][0].integer);
}

test "renames follow check generated index and trigger expressions" {
    const path = "sqlite_zig_rename_expr_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE rx (a INTEGER CHECK (a > 0), email TEXT, g INTEGER GENERATED ALWAYS AS (a * 10) STORED); CREATE INDEX rx_email_idx ON rx(lower(email)); CREATE UNIQUE INDEX rx_a_idx ON rx(a + 1); CREATE TRIGGER rx_audit AFTER UPDATE OF a ON rx BEGIN INSERT INTO rx_log(v) VALUES (NEW.a); END; CREATE TABLE rx_log (v INTEGER);");
    setup.deinit();
    var renamed = try db.exec("ALTER TABLE rx RENAME COLUMN a TO alpha; ALTER TABLE rx RENAME COLUMN email TO mail;");
    renamed.deinit();
    var valid = try db.exec("INSERT INTO rx(alpha, mail) VALUES (5, 'A@x.test');");
    valid.deinit();
    var computed = try db.exec("SELECT g FROM rx;");
    defer computed.deinit();
    try std.testing.expectEqual(@as(i64, 50), computed.rows[0][0].integer);
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO rx(alpha, mail) VALUES (-1, 'b@x.test');"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO rx(alpha, mail) VALUES (5, 'c@x.test');"));
    var fired = try db.exec("UPDATE rx SET alpha = 7 WHERE alpha = 5; SELECT v FROM rx_log;");
    defer fired.deinit();
    try std.testing.expectEqual(@as(i64, 7), fired.rows[0][0].integer);
    var quiet = try db.exec("DELETE FROM rx_log; UPDATE rx SET mail = 'd@x.test' WHERE alpha = 7; SELECT count(*) FROM rx_log;");
    defer quiet.deinit();
    try std.testing.expectEqual(@as(i64, 0), quiet.rows[0][0].integer);
    var info = try db.exec("PRAGMA table_xinfo(rx);");
    defer info.deinit();
    try std.testing.expectEqualStrings("alpha", info.rows[0][1].text);
    try std.testing.expectEqualStrings("mail", info.rows[1][1].text);
    var makeView = try db.exec("CREATE VIEW rx_view AS SELECT alpha, mail FROM rx WHERE alpha > 0;");
    makeView.deinit();
    var renameTableView = try db.exec("ALTER TABLE rx RENAME TO people;");
    renameTableView.deinit();
    var viaView = try db.exec("SELECT alpha FROM rx_view ORDER BY alpha;");
    defer viaView.deinit();
    try std.testing.expectEqual(@as(i64, 7), viaView.rows[0][0].integer);
    var renameMail = try db.exec("ALTER TABLE people RENAME COLUMN mail TO email;");
    renameMail.deinit();
    var viaViewAgain = try db.exec("SELECT email FROM rx_view;");
    defer viaViewAgain.deinit();
    try std.testing.expectEqualStrings("d@x.test", viaViewAgain.rows[0][0].text);
    var multi = try db.exec("CREATE TABLE mm_other (id INTEGER PRIMARY KEY, pid INTEGER, beta TEXT); INSERT INTO mm_other VALUES (1, 7, 'keep'); CREATE VIEW mm_view AS SELECT people.alpha, mm_other.beta AS obeta FROM people JOIN mm_other ON mm_other.pid = people.alpha;");
    multi.deinit();
    var renameBeta = try db.exec("ALTER TABLE people RENAME COLUMN alpha TO gamma;");
    renameBeta.deinit();
    var viaMulti = try db.exec("SELECT gamma, obeta FROM mm_view;");
    defer viaMulti.deinit();
    try std.testing.expectEqual(@as(i64, 7), viaMulti.rows[0][0].integer);
    try std.testing.expectEqualStrings("keep", viaMulti.rows[0][1].text);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    var persisted = try db.exec("SELECT gamma, obeta FROM mm_view;");
    defer persisted.deinit();
    try std.testing.expectEqual(@as(i64, 7), persisted.at(0)[0].integer);
    try std.testing.expectEqualStrings("keep", persisted.at(0)[1].text);
    var genPersisted = try db.exec("SELECT g FROM people;");
    defer genPersisted.deinit();
    try std.testing.expectEqual(@as(i64, 70), genPersisted.rows[0][0].integer);
}

test "temporary keyword aliases temp objects" {
    const path = "sqlite_zig_temporary_kw_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TEMPORARY TABLE tt (x INTEGER); INSERT INTO tt VALUES (1); CREATE TEMPORARY VIEW tv AS SELECT x FROM tt; CREATE TEMPORARY TRIGGER trg AFTER INSERT ON tt BEGIN UPDATE tt SET x = NEW.x + 100 WHERE x = NEW.x; END;");
    setup.deinit();
    var rows = try db.exec("SELECT x FROM tv;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[0].integer);
    var fired = try db.exec("INSERT INTO tt VALUES (2); SELECT x FROM tt ORDER BY x;");
    defer fired.deinit();
    try std.testing.expectEqual(@as(i64, 102), fired.rows[1][0].integer);
    var scoped = try db.exec("CREATE TEMP TABLE temp.scoped (y TEXT); INSERT INTO temp.scoped VALUES ('ok'); SELECT y FROM temp.scoped;");
    defer scoped.deinit();
    try std.testing.expectEqualStrings("ok", scoped.rows[0][0].text);
    try std.testing.expectError(error.InvalidSql, db.exec("CREATE TEMP TABLE main.bad (y TEXT);"));
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT x FROM tt;"));
}

test "scalar min max follow null semantics" {
    const path = "sqlite_zig_scalar_minmax_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var a = try db.exec("SELECT min(1, NULL, 3);");
    defer a.deinit();
    try std.testing.expect(a.rows[0][0] == .null);
    var b = try db.exec("SELECT max(1, NULL, 3);");
    defer b.deinit();
    try std.testing.expect(b.rows[0][0] == .null);
    var c = try db.exec("SELECT min(NULL, NULL);");
    defer c.deinit();
    try std.testing.expect(c.rows[0][0] == .null);
    var d = try db.exec("SELECT min('a', 'b'), max(1, 'a');");
    defer d.deinit();
    try std.testing.expectEqualStrings("a", d.rows[0][0].text);
    try std.testing.expectEqualStrings("a", d.rows[0][1].text);
    var e = try db.exec("SELECT min(3, 1, 2), max(3, 1, 2);");
    defer e.deinit();
    try std.testing.expectEqual(@as(i64, 1), e.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 3), e.rows[0][1].integer);
}

test "scalar concat family matches sqlite" {
    const path = "sqlite_zig_scalar_concat_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var a = try db.exec("SELECT concat('a', NULL, 'b');");
    defer a.deinit();
    try std.testing.expectEqualStrings("ab", a.rows[0][0].text);
    var b = try db.exec("SELECT concat(NULL, NULL);");
    defer b.deinit();
    try std.testing.expectEqualStrings("", b.rows[0][0].text);
    var c = try db.exec("SELECT concat_ws(',', 'a', NULL, 'b');");
    defer c.deinit();
    try std.testing.expectEqualStrings("a,b", c.rows[0][0].text);
    var d = try db.exec("SELECT concat_ws(NULL, 'a', 'b');");
    defer d.deinit();
    try std.testing.expect(d.rows[0][0] == .null);
    var e = try db.exec("SELECT concat(1, '-', 2.5);");
    defer e.deinit();
    try std.testing.expectEqualStrings("1-2.5", e.rows[0][0].text);
    var f = try db.exec("SELECT octet_length('abc'), octet_length(x'0102'), octet_length(123), octet_length(1.5), octet_length(2.0);");
    defer f.deinit();
    try std.testing.expectEqual(@as(i64, 3), f.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), f.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 3), f.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 3), f.rows[0][3].integer);
    try std.testing.expectEqual(@as(i64, 3), f.rows[0][4].integer);
    var g = try db.exec("SELECT octet_length(NULL);");
    defer g.deinit();
    try std.testing.expect(g.rows[0][0] == .null);
    var h = try db.exec("SELECT zeroblob(3), zeroblob(0), zeroblob(-5);");
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 3), h.rows[0][0].blob.len);
    try std.testing.expectEqual(@as(usize, 0), h.rows[0][1].blob.len);
    try std.testing.expectEqual(@as(usize, 0), h.rows[0][2].blob.len);
    var i = try db.exec("SELECT sign(-5), sign(0), sign(2.5), sign('5'), sign(' 3 ');");
    defer i.deinit();
    try std.testing.expectEqual(@as(i64, -1), i.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), i.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 1), i.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 1), i.rows[0][3].integer);
    try std.testing.expectEqual(@as(i64, 1), i.rows[0][4].integer);
    var j = try db.exec("SELECT sign('abc'), sign('3x'), sign(NULL);");
    defer j.deinit();
    try std.testing.expect(j.rows[0][0] == .null);
    try std.testing.expect(j.rows[0][1] == .null);
    try std.testing.expect(j.rows[0][2] == .null);
}

test "scalar iif unlikely random version match sqlite" {
    const path = "sqlite_zig_scalar_misc_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var a = try db.exec("SELECT iif(1, 'y', 'n'), iif(0, 'y', 'n'), iif(NULL, 'y', 'n'), iif('x', 'y', 'n'), iif('1', 'y', 'n'), iif(0.5, 'y', 'n');");
    defer a.deinit();
    try std.testing.expectEqualStrings("y", a.rows[0][0].text);
    try std.testing.expectEqualStrings("n", a.rows[0][1].text);
    try std.testing.expectEqualStrings("n", a.rows[0][2].text);
    try std.testing.expectEqualStrings("n", a.rows[0][3].text);
    try std.testing.expectEqualStrings("y", a.rows[0][4].text);
    try std.testing.expectEqualStrings("y", a.rows[0][5].text);
    var b = try db.exec("SELECT if(2, 'y', 'n'), unlikely(5), likely(6), likelihood(7, 0.5);");
    defer b.deinit();
    try std.testing.expectEqualStrings("y", b.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 5), b.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 6), b.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 7), b.rows[0][3].integer);
    var c = try db.exec("SELECT random() IS NOT NULL, randomblob(16);");
    defer c.deinit();
    try std.testing.expectEqual(@as(i64, 1), c.rows[0][0].integer);
    try std.testing.expectEqual(@as(usize, 16), c.rows[0][1].blob.len);
    var d = try db.exec("SELECT length(randomblob(0));");
    defer d.deinit();
    try std.testing.expectEqual(@as(i64, 1), d.rows[0][0].integer);
    var e = try db.exec("SELECT sqlite_version(), sqlite_source_id();");
    defer e.deinit();
    try std.testing.expect(e.rows[0][0] == .text);
    try std.testing.expect(e.rows[0][1] == .text);
    var f = try db.exec("SELECT json_quote(NULL), json_quote(1), json_quote(1.5), json_quote('a');");
    defer f.deinit();
    try std.testing.expectEqualStrings("null", f.rows[0][0].text);
    try std.testing.expectEqualStrings("1", f.rows[0][1].text);
    try std.testing.expectEqualStrings("1.5", f.rows[0][2].text);
    try std.testing.expectEqualStrings("\"a\"", f.rows[0][3].text);
    try std.testing.expectError(error.Unsupported, db.exec("SELECT json_quote(x'41');"));
    var g = try db.exec("SELECT unistr('A\\u0041B');");
    defer g.deinit();
    try std.testing.expectEqualStrings("AAB", g.rows[0][0].text);
    try std.testing.expectError(error.Unsupported, db.exec("SELECT unistr('a\\q');"));
}

test "scalar math extensions match sqlite" {
    const path = "sqlite_zig_scalar_math_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var a = try db.exec("SELECT exp(1) > 2.71 AND exp(1) < 2.72;");
    defer a.deinit();
    try std.testing.expectEqual(@as(i64, 1), a.rows[0][0].integer);
    var b = try db.exec("SELECT mod(7, 3), mod(7.5, 2);");
    defer b.deinit();
    try std.testing.expectEqual(@as(f64, 1.0), b.rows[0][0].real);
    try std.testing.expectEqual(@as(f64, 1.5), b.rows[0][1].real);
    var c = try db.exec("SELECT cosh(0), sinh(0), tanh(0), acosh(1), asinh(0), atanh(0);");
    defer c.deinit();
    try std.testing.expectEqual(@as(f64, 1.0), c.rows[0][0].real);
    try std.testing.expectEqual(@as(f64, 0.0), c.rows[0][1].real);
    try std.testing.expectEqual(@as(f64, 0.0), c.rows[0][2].real);
    try std.testing.expectEqual(@as(f64, 0.0), c.rows[0][3].real);
    try std.testing.expectEqual(@as(f64, 0.0), c.rows[0][4].real);
    try std.testing.expectEqual(@as(f64, 0.0), c.rows[0][5].real);
}

test "right full natural using joins match sqlite" {
    const path = "sqlite_zig_join_matrix_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE a (id INTEGER, v TEXT); CREATE TABLE b (id INTEGER, w TEXT); INSERT INTO a VALUES (1, 'a1'), (2, 'a2'), (3, 'a3'); INSERT INTO b VALUES (2, 'b2'), (3, 'b3'), (4, 'b4');");
    setup.deinit();
    var right = try db.exec("SELECT a.id, a.v, b.id, b.w FROM a RIGHT JOIN b ON a.id = b.id ORDER BY b.id;");
    defer right.deinit();
    try std.testing.expectEqual(@as(usize, 3), right.count());
    try std.testing.expectEqual(@as(i64, 2), right.rows[0][0].integer);
    try std.testing.expect(right.rows[2][0] == .null);
    try std.testing.expect(right.rows[2][1] == .null);
    try std.testing.expectEqual(@as(i64, 4), right.rows[2][2].integer);
    try std.testing.expectEqualStrings("b4", right.rows[2][3].text);
    var full = try db.exec("SELECT a.id, b.id FROM a FULL JOIN b ON a.id = b.id ORDER BY b.id;");
    defer full.deinit();
    try std.testing.expectEqual(@as(usize, 4), full.count());
    try std.testing.expectEqual(@as(i64, 1), full.rows[0][0].integer);
    try std.testing.expect(full.rows[0][1] == .null);
    try std.testing.expectEqual(@as(i64, 2), full.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, 2), full.rows[1][1].integer);
    try std.testing.expect(full.rows[3][0] == .null);
    try std.testing.expectEqual(@as(i64, 4), full.rows[3][1].integer);
    var natural = try db.exec("SELECT id, v, w FROM a NATURAL JOIN b ORDER BY id;");
    defer natural.deinit();
    try std.testing.expectEqual(@as(usize, 2), natural.count());
    try std.testing.expectEqual(@as(i64, 2), natural.rows[0][0].integer);
    try std.testing.expectEqualStrings("a2", natural.rows[0][1].text);
    try std.testing.expectEqualStrings("b2", natural.rows[0][2].text);
    var naturalLeft = try db.exec("SELECT id, v, w FROM a NATURAL LEFT JOIN b ORDER BY id;");
    defer naturalLeft.deinit();
    try std.testing.expectEqual(@as(usize, 3), naturalLeft.count());
    try std.testing.expect(naturalLeft.rows[0][2] == .null);
    var using = try db.exec("SELECT id, v, w FROM a JOIN b USING (id) ORDER BY id;");
    defer using.deinit();
    try std.testing.expectEqual(@as(usize, 2), using.count());
    try std.testing.expectEqual(@as(i64, 3), using.rows[1][0].integer);
    var usingLeft = try db.exec("SELECT id, v, w FROM a LEFT JOIN b USING (id) ORDER BY id;");
    defer usingLeft.deinit();
    try std.testing.expectEqual(@as(usize, 3), usingLeft.count());
    try std.testing.expect(usingLeft.rows[0][2] == .null);
}

test "connection state functions track writes" {
    const path = "sqlite_zig_connection_state_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var base = try db.exec("SELECT last_insert_rowid(), changes(), total_changes();");
    defer base.deinit();
    try std.testing.expectEqual(@as(i64, 0), base.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), base.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 0), base.rows[0][2].integer);
    var setup = try db.exec("CREATE TABLE s (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT); INSERT INTO s VALUES (NULL, 'a'), (NULL, 'b');");
    setup.deinit();
    var after = try db.exec("SELECT last_insert_rowid(), changes(), total_changes();");
    defer after.deinit();
    try std.testing.expectEqual(@as(i64, 2), after.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), after.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 2), after.rows[0][2].integer);
    var update = try db.exec("UPDATE s SET v = 'z' WHERE id = 1;");
    update.deinit();
    var changed = try db.exec("SELECT changes(), total_changes(), last_insert_rowid();");
    defer changed.deinit();
    try std.testing.expectEqual(@as(i64, 1), changed.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 3), changed.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 2), changed.rows[0][2].integer);
    var del = try db.exec("DELETE FROM s;");
    del.deinit();
    var cleared = try db.exec("SELECT changes(), total_changes();");
    defer cleared.deinit();
    try std.testing.expectEqual(@as(i64, 2), cleared.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 5), cleared.rows[0][1].integer);
}

test "scalar coercions follow sqlite conversions" {
    const path = "sqlite_zig_scalar_coerce_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var a = try db.exec("SELECT instr(123, '2'), instr('abc', 2), trim(123), replace(123, '2', 'x');");
    defer a.deinit();
    try std.testing.expectEqual(@as(i64, 2), a.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), a.rows[0][1].integer);
    try std.testing.expectEqualStrings("123", a.rows[0][2].text);
    try std.testing.expectEqualStrings("1x3", a.rows[0][3].text);
    var b = try db.exec("SELECT substr(12345, 2), substr('abcdef', 2, -2), substr('abcdef', -2, -2);");
    defer b.deinit();
    try std.testing.expectEqualStrings("2345", b.rows[0][0].text);
    try std.testing.expectEqualStrings("a", b.rows[0][1].text);
    try std.testing.expectEqualStrings("cd", b.rows[0][2].text);
    var c = try db.exec("SELECT length('abc'), length(123), length(1.5), length(x'010203');");
    defer c.deinit();
    try std.testing.expectEqual(@as(i64, 3), c.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 3), c.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 3), c.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 3), c.rows[0][3].integer);
    var d = try db.exec("SELECT unicode(65), unicode(65.0);");
    defer d.deinit();
    try std.testing.expectEqual(@as(i64, 54), d.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 54), d.rows[0][1].integer);
    var e = try db.exec("SELECT CAST('3x' AS INTEGER), CAST('3.9' AS INTEGER), CAST('' AS INTEGER), CAST(x'31' AS INTEGER), CAST('3.5' AS REAL);");
    defer e.deinit();
    try std.testing.expectEqual(@as(i64, 3), e.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 3), e.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 0), e.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 1), e.rows[0][3].integer);
    try std.testing.expectEqual(@as(f64, 3.5), e.rows[0][4].real);
    var f = try db.exec("SELECT CAST(2.0 AS TEXT), CAST(2.5 AS TEXT);");
    defer f.deinit();
    try std.testing.expectEqualStrings("2.0", f.rows[0][0].text);
    try std.testing.expectEqualStrings("2.5", f.rows[0][1].text);
    try std.testing.expectError(error.Unsupported, db.exec("SELECT abs(-9223372036854775808);"));
    var minLit = try db.exec("SELECT -9223372036854775808, typeof(-9223372036854775808);");
    defer minLit.deinit();
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), minLit.rows[0][0].integer);
    try std.testing.expectEqualStrings("integer", minLit.rows[0][1].text);
    var bigLit = try db.exec("SELECT 9223372036854775808, typeof(9223372036854775808);");
    defer bigLit.deinit();
    try std.testing.expectEqualStrings("real", bigLit.rows[0][1].text);
    var hexLit = try db.exec("SELECT 0x1F, 0XABCDEF;");
    defer hexLit.deinit();
    try std.testing.expectEqual(@as(i64, 31), hexLit.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 11259375), hexLit.rows[0][1].integer);
    try std.testing.expectError(error.InvalidSql, db.exec("SELECT 0xFFFFFFFFFFFFFFFFFF;"));
    var sciLit = try db.exec("SELECT 1e3, 1E-3, .5;");
    defer sciLit.deinit();
    try std.testing.expectEqual(@as(f64, 1000.0), sciLit.rows[0][0].real);
    try std.testing.expectEqual(@as(f64, 0.001), sciLit.rows[0][1].real);
    try std.testing.expectEqual(@as(f64, 0.5), sciLit.rows[0][2].real);
}

test "where truthiness follows numeric conversion" {
    const path = "sqlite_zig_truthiness_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE w (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO w VALUES (1, '1'), (2, 'abc'), (3, '0'), (4, ''), (5, ' 2 '), (6, '2x'), (7, 'x2');");
    setup.deinit();
    var rows = try db.exec("SELECT id FROM w WHERE v ORDER BY id;");
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 3), rows.count());
    try std.testing.expectEqual(@as(i64, 1), rows.at(0)[0].integer);
    try std.testing.expectEqual(@as(i64, 5), rows.at(1)[0].integer);
    try std.testing.expectEqual(@as(i64, 6), rows.at(2)[0].integer);
    var notRows = try db.exec("SELECT ALL id FROM w WHERE NOT v ORDER BY id;");
    defer notRows.deinit();
    try std.testing.expectEqual(@as(usize, 4), notRows.count());
    try std.testing.expectEqual(@as(i64, 2), notRows.rows[0][0].integer);
    var having = try db.exec("SELECT v, count(*) FROM w GROUP BY v HAVING count(*) ORDER BY v;");
    defer having.deinit();
    try std.testing.expect(having.count() > 0);
    var havingBare = try db.exec("SELECT count(*) FROM w HAVING count(*) > 100;");
    defer havingBare.deinit();
    try std.testing.expectEqual(@as(usize, 0), havingBare.count());
}

test "open failure reports an error instead of crashing" {
    const path = "sqlite_zig_open_failure_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var garbage = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true });
    try garbage.writePositionalAll(std.testing.io, "not a database file at all", 0);
    garbage.close(std.testing.io);
    try std.testing.expectError(error.InvalidHeader, Connection.open(std.testing.allocator, path));
    var partial = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true });
    const tiny = [_]u8{ 'S', 'Q', 'L', 'i', 't', 'e' };
    try partial.writePositionalAll(std.testing.io, &tiny, 0);
    partial.close(std.testing.io);
    try std.testing.expectError(error.InvalidHeader, Connection.open(std.testing.allocator, path));
}

test "corrupted bytes report controlled errors instead of crashing" {
    const path = "sqlite_zig_corruption_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    {
        var db = try Connection.open(std.testing.allocator, path);
        defer db.close();
        var setup = try db.exec("CREATE TABLE c (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO c VALUES (1, 'one'), (2, 'two');");
        setup.deinit();
        var ok = try db.exec("PRAGMA integrity_check;");
        defer ok.deinit();
        try std.testing.expectEqualStrings("ok", ok.rows[0][0].text);
    }
    var valid = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_write });
    const fstat = try valid.stat(std.testing.io);
    var rawImage = try std.testing.allocator.alloc(u8, @intCast(fstat.size));
    const got = try valid.readPositional(std.testing.io, &.{rawImage}, 0);
    valid.close(std.testing.io);
    defer std.testing.allocator.free(rawImage);
    try std.testing.expectEqual(rawImage.len, got);
    try std.testing.expect(rawImage.len > 100);
    // Corrupted magic: not a database, never a panic or an empty result.
    {
        var f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true });
        var bad = try std.testing.allocator.dupe(u8, rawImage);
        defer std.testing.allocator.free(bad);
        bad[0] = 'X';
        try f.writePositionalAll(std.testing.io, bad, 0);
        f.close(std.testing.io);
        try std.testing.expectError(error.InvalidHeader, Connection.open(std.testing.allocator, path));
    }
    // Truncated file: short read, never a partial page presented as data.
    {
        var f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true });
        try f.writePositionalAll(std.testing.io, rawImage[0..50], 0);
        f.close(std.testing.io);
        try std.testing.expectError(error.InvalidHeader, Connection.open(std.testing.allocator, path));
    }
    // Restored image reopens with schema and data intact.
    {
        var f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true });
        try f.writePositionalAll(std.testing.io, rawImage, 0);
        f.close(std.testing.io);
        var db = try Connection.open(std.testing.allocator, path);
        defer db.close();
        var rows = try db.exec("SELECT v FROM c ORDER BY id;");
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 2), rows.count());
        try std.testing.expectEqualStrings("one", rows.rows[0][0].text);
        var check = try db.exec("PRAGMA integrity_check;");
        defer check.deinit();
        try std.testing.expectEqualStrings("ok", check.rows[0][0].text);
    }
}

test "integer primary key null auto assigns rowid alias" {
    const path = "sqlite_zig_rowid_alias_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE r (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO r VALUES (NULL, 'a'), (NULL, 'b');");
    setup.deinit();
    var ids = try db.exec("SELECT id, v FROM r ORDER BY id;");
    defer ids.deinit();
    try std.testing.expectEqual(@as(i64, 1), ids.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), ids.rows[1][0].integer);
    var gap = try db.exec("INSERT INTO r VALUES (10, 'j'); INSERT INTO r(v) VALUES ('k');");
    gap.deinit();
    var next = try db.exec("SELECT id FROM r WHERE v = 'k';");
    defer next.deinit();
    try std.testing.expectEqual(@as(i64, 11), next.rows[0][0].integer);
    var wipe = try db.exec("DELETE FROM r WHERE id = 11; INSERT INTO r(v) VALUES ('reuse');");
    wipe.deinit();
    var reused = try db.exec("SELECT id FROM r WHERE v = 'reuse';");
    defer reused.deinit();
    try std.testing.expectEqual(@as(i64, 11), reused.rows[0][0].integer);
    var updated = try db.exec("UPDATE r SET id = NULL WHERE v = 'a';");
    updated.deinit();
    var moved = try db.exec("SELECT id FROM r WHERE v = 'a';");
    defer moved.deinit();
    try std.testing.expectEqual(@as(i64, 12), moved.rows[0][0].integer);
    var defaults = try db.exec("INSERT INTO r DEFAULT VALUES;");
    defaults.deinit();
    var defaulted = try db.exec("SELECT max(id) FROM r;");
    defer defaulted.deinit();
    try std.testing.expectEqual(@as(i64, 13), defaulted.rows[0][0].integer);
    var intAlias = try db.exec("CREATE TABLE ia (id INT PRIMARY KEY, v TEXT);");
    intAlias.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO ia VALUES (NULL, 'x');"));
    var textPk = try db.exec("CREATE TABLE tp (id TEXT PRIMARY KEY, v TEXT); INSERT INTO tp VALUES ('k', 'x');");
    textPk.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO tp VALUES (NULL, 'y');"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE tp SET id = NULL WHERE v = 'x';"));
    var composite = try db.exec("CREATE TABLE cp (a INTEGER, b INTEGER, PRIMARY KEY (a, b));");
    composite.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO cp VALUES (NULL, 1);"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO cp VALUES (1, NULL);"));
    var wr = try db.exec("CREATE TABLE w (id INTEGER PRIMARY KEY, v TEXT) WITHOUT ROWID;");
    wr.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO w VALUES (NULL, 'x');"));
    var dup = try db.exec("INSERT INTO r VALUES (1, 'dupe');");
    dup.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO r VALUES (1, 'dupe2');"));
}

test "unique nulls and actions hold across raw and dsl" {
    const path = "sqlite_zig_key_matrix_test.db";
    var db = try freshDb(path);
    const t_db_matrix_dyn = db.table("matrix_dyn");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE p (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO p VALUES (1, 'a'), (2, 'b'); CREATE TABLE uq (id INTEGER PRIMARY KEY, email TEXT UNIQUE, a INTEGER, b INTEGER, UNIQUE(a, b)); INSERT INTO uq VALUES (1, NULL, 1, 1), (2, NULL, 1, 2), (3, 'x@y.test', NULL, 1), (4, NULL, NULL, NULL);");
    setup.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO uq VALUES (5, 'x@y.test', 9, 9);"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO uq VALUES (5, 'fresh@y.test', 1, 1);"));
    var keepUnique = try db.exec("UPDATE uq SET a = 1, b = 2 WHERE id = 2;");
    keepUnique.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE uq SET a = 1, b = 1 WHERE id = 2;"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("UPDATE uq SET email = 'x@y.test' WHERE id = 1;"));
    var actions = try db.exec("CREATE TABLE c_cas (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p(id) ON DELETE CASCADE ON UPDATE CASCADE); CREATE TABLE c_null (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p(id) ON DELETE SET NULL ON UPDATE SET NULL); CREATE TABLE c_def (id INTEGER PRIMARY KEY, pid INTEGER DEFAULT 0 REFERENCES p(id) ON DELETE SET DEFAULT ON UPDATE SET DEFAULT); CREATE TABLE c_res (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p(id) ON DELETE RESTRICT); INSERT INTO c_cas VALUES (1, 1); INSERT INTO c_null VALUES (1, 1); INSERT INTO c_def VALUES (1, 1); INSERT INTO c_res VALUES (1, 1);");
    actions.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO c_cas VALUES (2, 99);"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("DELETE FROM p WHERE id = 1;"));
    var wipeRes = try db.exec("DELETE FROM c_res;");
    wipeRes.deinit();
    var updateParent = try db.exec("UPDATE p SET id = 10 WHERE id = 1;");
    updateParent.deinit();
    var followed = try db.exec("SELECT pid FROM c_cas;");
    defer followed.deinit();
    try std.testing.expectEqual(@as(i64, 10), followed.rows[0][0].integer);
    var nulled = try db.exec("SELECT pid FROM c_null;");
    defer nulled.deinit();
    try std.testing.expect(nulled.rows[0][0] == .null);
    var defaulted = try db.exec("SELECT pid FROM c_def;");
    defer defaulted.deinit();
    try std.testing.expectEqual(@as(i64, 0), defaulted.rows[0][0].integer);
    var wipeParent = try db.exec("DELETE FROM p WHERE id = 10;");
    wipeParent.deinit();
    var casGone = try db.exec("SELECT count(*) FROM c_cas;");
    defer casGone.deinit();
    try std.testing.expectEqual(@as(i64, 0), casGone.rows[0][0].integer);
    const Emp = @import("../dsl/table.zig").table("matrix_emp", struct { id: i64, mgr: ?i64, email: ?[]const u8 });
    try db.createTable(Emp, .{
        .primaryKey = Emp.id,
        .unique = &.{Emp.email},
        .foreignKeys = &.{.{ .column = Emp.mgr, .references = Emp.id, .onDelete = .cascade }},
    });
    var ceo = try db.from(Emp).insert(.{ .id = 1, .mgr = null, .email = null });
    ceo.deinit();
    var staff = try db.from(Emp).insert(.{ .id = 2, .mgr = 1, .email = null });
    staff.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Emp).insert(.{ .id = 3, .mgr = 99, .email = null }));
    var dupeMail = try db.from(Emp).insert(.{ .id = 4, .mgr = 1, .email = "boss@x.test" });
    dupeMail.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Emp).insert(.{ .id = 5, .mgr = 1, .email = "boss@x.test" }));
    var dropCeo = try db.from(Emp).delete().where(Emp.id.eq(1)).execute();
    dropCeo.deinit();
    var reports = try db.from(Emp).selectAll().fetch();
    defer reports.deinit();
    try std.testing.expectEqual(@as(usize, 0), reports.count());
    try db.createTable("matrix_dyn", .{
        .columns = &.{ .{ .name = "id", .type = "INTEGER" }, .{ .name = "email", .type = "TEXT" }, .{ .name = "mgr", .type = "INTEGER" } },
        .primaryKey = "id",
        .unique = &.{"email"},
        .foreignKeys = &.{.{
            .column = "mgr",
            .references = .{ .table = "matrix_dyn", .column = "id" },
            .onDelete = .cascade,
        }},
    });
    var d1 = try t_db_matrix_dyn.insert(.{ .id = 1, .email = null, .mgr = null });
    d1.deinit();
    var d2 = try t_db_matrix_dyn.insert(.{ .id = 2, .email = null, .mgr = 1 });
    d2.deinit();
    try std.testing.expectError(error.ConstraintViolation, t_db_matrix_dyn.insert(.{ .id = 3, .email = null, .mgr = 42 }));
    var dwipe = try t_db_matrix_dyn.delete().where(t_db_matrix_dyn.column("id").eq(1)).execute();
    dwipe.deinit();
    var dleft = try t_db_matrix_dyn.selectAll().fetch();
    defer dleft.deinit();
    try std.testing.expectEqual(@as(usize, 0), dleft.count());
    var off = try db.exec("PRAGMA foreign_keys = OFF;");
    off.deinit();
    var orphan = try db.exec("INSERT INTO c_cas VALUES (9, 4242); DELETE FROM p;");
    orphan.deinit();
    var orphans = try db.exec("SELECT count(*) FROM c_cas;");
    defer orphans.deinit();
    try std.testing.expectEqual(@as(i64, 1), orphans.rows[0][0].integer);
    var on = try db.exec("PRAGMA foreign_keys = ON;");
    on.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO c_cas VALUES (10, 4243);"));
}

test "table operations hold across raw and dsl" {
    const path = "sqlite_zig_table_ops_test.db";
    var db = try freshDb(path);
    const t_db_ops_widget = db.table("ops_widget");
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE ops (id INTEGER PRIMARY KEY, name TEXT UNIQUE, age INTEGER); INSERT INTO ops VALUES (1, 'a', 10), (2, 'b', 20); CREATE INDEX ops_age_idx ON ops(age); CREATE TABLE ops_child (id INTEGER PRIMARY KEY, oid INTEGER REFERENCES ops(id)); INSERT INTO ops_child VALUES (1, 1);");
    setup.deinit();
    var add = try db.exec("ALTER TABLE ops ADD COLUMN score INTEGER DEFAULT 7;");
    add.deinit();
    var scored = try db.exec("SELECT score FROM ops ORDER BY id;");
    defer scored.deinit();
    try std.testing.expectEqual(@as(i64, 7), scored.rows[0][0].integer);
    try std.testing.expectError(error.ConstraintViolation, db.exec("ALTER TABLE ops ADD COLUMN nick TEXT NOT NULL;"));
    var addNn = try db.exec("ALTER TABLE ops ADD COLUMN nick TEXT NOT NULL DEFAULT 'x';");
    addNn.deinit();
    try std.testing.expectError(error.ColumnExists, db.exec("ALTER TABLE ops ADD COLUMN id INTEGER;"));
    var renameCol = try db.exec("ALTER TABLE ops RENAME COLUMN age TO years;");
    renameCol.deinit();
    var renamed = try db.exec("SELECT years FROM ops ORDER BY id;");
    defer renamed.deinit();
    try std.testing.expectEqual(@as(i64, 10), renamed.rows[0][0].integer);
    var idxFollow = try db.exec("PRAGMA index_list(ops);");
    defer idxFollow.deinit();
    try std.testing.expectEqual(@as(usize, 2), idxFollow.count());
    var renameTable = try db.exec("ALTER TABLE ops RENAME TO people;");
    renameTable.deinit();
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT count(*) FROM ops;"));
    var people = try db.exec("SELECT count(*) FROM people;");
    defer people.deinit();
    try std.testing.expectEqual(@as(i64, 2), people.rows[0][0].integer);
    var fkFollow = try db.exec("INSERT INTO ops_child VALUES (2, 2);");
    fkFollow.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO ops_child VALUES (3, 99);"));
    var fkListFollow = try db.exec("PRAGMA foreign_key_list(ops_child);");
    defer fkListFollow.deinit();
    try std.testing.expectEqualStrings("people", fkListFollow.rows[0][2].text);
    var renameRef = try db.exec("ALTER TABLE people RENAME COLUMN id TO pid;");
    renameRef.deinit();
    var refFollow = try db.exec("INSERT INTO ops_child VALUES (4, 1);");
    refFollow.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO ops_child VALUES (5, 98);"));
    var refList = try db.exec("PRAGMA foreign_key_list(ops_child);");
    defer refList.deinit();
    try std.testing.expectEqualStrings("pid", refList.rows[0][4].text);
    try std.testing.expectError(error.ConstraintViolation, db.exec("ALTER TABLE people DROP COLUMN pid;"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("ALTER TABLE people DROP COLUMN name;"));
    try std.testing.expectError(error.ConstraintViolation, db.exec("ALTER TABLE people DROP COLUMN years;"));
    try std.testing.expectError(error.UnknownColumn, db.exec("ALTER TABLE people DROP COLUMN oid;"));
    var dropScore = try db.exec("ALTER TABLE people DROP COLUMN score;");
    dropScore.deinit();
    var kept = try db.exec("SELECT nick FROM people ORDER BY pid;");
    defer kept.deinit();
    try std.testing.expectEqualStrings("x", kept.rows[0][0].text);
    try std.testing.expectError(error.UnknownColumn, db.exec("SELECT score FROM people;"));
    var dropParent = try db.exec("DROP TABLE people;");
    dropParent.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO ops_child VALUES (6, 1);"));
    var ifExists = try db.exec("DROP TABLE IF EXISTS nosuch; DROP INDEX IF EXISTS nosuch; DROP VIEW IF EXISTS nosuch; DROP TRIGGER IF EXISTS nosuch;");
    ifExists.deinit();
    try std.testing.expectError(error.InvalidSql, db.exec("TRUNCATE TABLE ops_child;"));
    const Widget = @import("../dsl/table.zig").table("ops_widget", struct { id: i64, label: []const u8 });
    try db.createTable(Widget, .{ .primaryKey = Widget.id });
    var w1 = try db.from(Widget).insert(.{ .id = 1, .label = "a" });
    w1.deinit();
    try db.addColumn(Widget, "stock", i64);
    try db.renameTable(Widget, "ops_gadget");
    try db.renameTable("ops_gadget", "ops_widget");
    try db.addColumn("ops_widget", "price", f64);
    var w2 = try t_db_ops_widget.insert(.{ .id = 2, .label = "b" });
    w2.deinit();
    try db.truncate("ops_widget");
    var empty = try t_db_ops_widget.selectAll().fetch();
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.count());
    var w3 = try t_db_ops_widget.insert(.{ .id = 3, .label = "c" });
    w3.deinit();
    try db.createView("ops_view", "SELECT id FROM ops_widget");
    try db.dropView("ops_view");
    try std.testing.expectError(error.UnknownView, db.dropView("ops_view"));
    try db.createIndex("ops_widget", "ops_widget_label_idx", .{t_db_ops_widget.column("label")}, false);
    try db.dropIndex("ops_widget_label_idx");
    try std.testing.expectError(error.UnknownIndex, db.dropIndex("ops_widget_label_idx"));
    try db.truncate(Widget);
    try db.dropTable("ops_widget");
    try std.testing.expectError(error.UnknownTable, db.dropTable("ops_widget"));
}

test "attached databases isolate join and persist" {
    const path = "sqlite_zig_attach_main_test.db";
    const auxPath = "sqlite_zig_attach_aux_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, auxPath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, auxPath) catch {};
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO users VALUES (1, 'ann'), (2, 'bob');");
    setup.deinit();
    var attach = try db.exec("ATTACH 'sqlite_zig_attach_aux_test.db' AS aux;");
    attach.deinit();
    var dblist = try db.exec("PRAGMA database_list;");
    defer dblist.deinit();
    try std.testing.expectEqual(@as(usize, 3), dblist.count());
    try std.testing.expectEqualStrings("aux", dblist.rows[2][1].text);
    try std.testing.expectEqualStrings(auxPath, dblist.rows[2][2].text);
    var auxSetup = try db.exec("CREATE TABLE aux.orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount INTEGER); INSERT INTO aux.orders VALUES (1, 1, 100), (2, 2, 200); CREATE TABLE aux.parents (id INTEGER PRIMARY KEY); INSERT INTO aux.parents VALUES (1); CREATE TABLE aux.children (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES parents(id) ON DELETE CASCADE); INSERT INTO aux.children VALUES (1, 1);");
    auxSetup.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO aux.children VALUES (2, 99);"));
    var auxCascade = try db.exec("DELETE FROM aux.parents WHERE id = 1; SELECT count(*) FROM aux.children;");
    defer auxCascade.deinit();
    try std.testing.expectEqual(@as(i64, 0), auxCascade.rows[0][0].integer);
    var joined = try db.exec("SELECT users.name, aux.orders.amount FROM users JOIN aux.orders ON users.id = aux.orders.user_id ORDER BY users.id;");
    defer joined.deinit();
    try std.testing.expectEqual(@as(usize, 2), joined.count());
    try std.testing.expectEqualStrings("ann", joined.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 100), joined.rows[0][1].integer);
    try std.testing.expectEqualStrings("amount", joined.columns[1]);
    var auxWrite = try db.exec("UPDATE aux.orders SET amount = 150 WHERE id = 1; DELETE FROM aux.orders WHERE id = 2;");
    auxWrite.deinit();
    var auxRead = try db.exec("SELECT count(*), sum(amount) FROM aux.orders;");
    defer auxRead.deinit();
    try std.testing.expectEqual(@as(i64, 1), auxRead.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 150), auxRead.rows[0][1].integer);
    var auxInfo = try db.exec("PRAGMA aux.table_info(orders);");
    defer auxInfo.deinit();
    try std.testing.expectEqual(@as(usize, 3), auxInfo.count());
    try std.testing.expectEqualStrings("user_id", auxInfo.rows[1][1].text);
    var auxVersion = try db.exec("PRAGMA aux.user_version = 7; PRAGMA aux.user_version;");
    defer auxVersion.deinit();
    try std.testing.expectEqual(@as(i64, 7), auxVersion.rows[0][0].integer);
    var mainVersion = try db.exec("PRAGMA user_version;");
    defer mainVersion.deinit();
    try std.testing.expectEqual(@as(i64, 0), mainVersion.rows[0][0].integer);
    try std.testing.expectError(error.InvalidSql, db.exec("DETACH main;"));
    try std.testing.expectError(error.InvalidSql, db.exec("DETACH temp;"));
    try std.testing.expectError(error.UnknownDatabase, db.exec("DETACH missing;"));
    var begun = try db.exec("BEGIN;");
    begun.deinit();
    try std.testing.expectError(error.TransactionActive, db.exec("DETACH aux;"));
    var rolled = try db.exec("ROLLBACK;");
    rolled.deinit();
    var vacuumAux = try db.exec("VACUUM aux;");
    vacuumAux.deinit();
    var detached = try db.exec("DETACH aux;");
    detached.deinit();
    var dblistAfter = try db.exec("PRAGMA database_list;");
    defer dblistAfter.deinit();
    try std.testing.expectEqual(@as(usize, 2), dblistAfter.count());
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT count(*) FROM aux.orders;"));
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    var direct = try Connection.open(std.testing.allocator, auxPath);
    defer direct.close();
    var auxRows = try direct.exec("SELECT count(*), sum(amount) FROM orders;");
    defer auxRows.deinit();
    try std.testing.expectEqual(@as(i64, 1), auxRows.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 150), auxRows.rows[0][1].integer);
    var auxVersionKept = try direct.exec("PRAGMA user_version;");
    defer auxVersionKept.deinit();
    try std.testing.expectEqual(@as(i64, 7), auxVersionKept.rows[0][0].integer);
}

test "temp tables shadow main and vanish on reopen" {
    const path = "sqlite_zig_temp_table_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO items VALUES (1, 'main');");
    setup.deinit();
    var temp = try db.exec("CREATE TEMP TABLE items (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO items VALUES (1, 'temp'), (2, 'temp2');");
    temp.deinit();
    var shadowed = try db.exec("SELECT v FROM items ORDER BY id;");
    defer shadowed.deinit();
    try std.testing.expectEqualStrings("temp", shadowed.rows[0][0].text);
    var scoped = try db.exec("SELECT v FROM main.items; SELECT v FROM temp.items ORDER BY id;");
    defer scoped.deinit();
    try std.testing.expectEqualStrings("temp2", scoped.rows[1][0].text);
    var tempOnly = try db.exec("CREATE TEMP TABLE scratch (x INTEGER); INSERT INTO scratch VALUES (5);");
    tempOnly.deinit();
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT x FROM main.scratch;"));
    var tempRead = try db.exec("SELECT x FROM scratch;");
    defer tempRead.deinit();
    try std.testing.expectEqual(@as(i64, 5), tempRead.rows[0][0].integer);
    var tempWrite = try db.exec("UPDATE scratch SET x = 6; DELETE FROM items WHERE id = 2;");
    tempWrite.deinit();
    var tempCheck = try db.exec("SELECT x FROM temp.scratch; SELECT count(*) FROM main.items;");
    defer tempCheck.deinit();
    try std.testing.expectEqual(@as(i64, 1), tempCheck.rows[0][0].integer);
    try std.testing.expectError(error.UnexpectedToken, db.exec("CREATE TEMP INDEX scratch_idx ON scratch (x);"));
    try std.testing.expectError(error.UnknownDatabase, db.exec("CREATE TEMP TABLE aux.t (x INTEGER);"));
    var tempView = try db.exec("CREATE TEMP VIEW scratch_view AS SELECT x FROM scratch;");
    tempView.deinit();
    var viaTempView = try db.exec("SELECT x FROM scratch_view;");
    defer viaTempView.deinit();
    try std.testing.expectEqual(@as(i64, 6), viaTempView.rows[0][0].integer);
    var dropTemp = try db.exec("DROP TABLE items;");
    dropTemp.deinit();
    var unshadowed = try db.exec("SELECT v FROM main.items;");
    defer unshadowed.deinit();
    try std.testing.expectEqualStrings("main", unshadowed.rows[0][0].text);
    var list = try db.exec("PRAGMA table_list;");
    defer list.deinit();
    var sawTemp = false;
    for (list.rows) |row| {
        if (std.mem.eql(u8, row[0].text, "temp") and std.mem.eql(u8, row[1].text, "scratch")) sawTemp = true;
    }
    try std.testing.expect(sawTemp);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    var gone = try db.exec("SELECT count(*) FROM items;");
    defer gone.deinit();
    try std.testing.expectEqual(@as(i64, 1), gone.rows[0][0].integer);
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT x FROM scratch;"));
}

test "transactions span main attached and temp schemas" {
    const path = "sqlite_zig_xdb_txn_test.db";
    const auxPath = "sqlite_zig_xdb_txn_aux_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, auxPath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, auxPath) catch {};
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE m (id INTEGER PRIMARY KEY, v INTEGER); INSERT INTO m VALUES (1, 10); ATTACH 'sqlite_zig_xdb_txn_aux_test.db' AS aux; CREATE TABLE aux.a (id INTEGER PRIMARY KEY, v INTEGER); INSERT INTO aux.a VALUES (1, 100); CREATE TEMP TABLE t (id INTEGER PRIMARY KEY, v INTEGER); INSERT INTO t VALUES (1, 1000);");
    setup.deinit();
    var txn = try db.exec("BEGIN; INSERT INTO m VALUES (2, 20); INSERT INTO aux.a VALUES (2, 200); INSERT INTO t VALUES (2, 2000); ROLLBACK;");
    txn.deinit();
    var rolledM = try db.exec("SELECT count(*) FROM m;");
    defer rolledM.deinit();
    try std.testing.expectEqual(@as(i64, 1), rolledM.rows[0][0].integer);
    var rolledA = try db.exec("SELECT count(*) FROM aux.a;");
    defer rolledA.deinit();
    try std.testing.expectEqual(@as(i64, 1), rolledA.rows[0][0].integer);
    var rolledT = try db.exec("SELECT count(*) FROM t;");
    defer rolledT.deinit();
    try std.testing.expectEqual(@as(i64, 1), rolledT.rows[0][0].integer);
    var txn2 = try db.exec("BEGIN; INSERT INTO m VALUES (2, 20); INSERT INTO aux.a VALUES (2, 200); INSERT INTO t VALUES (2, 2000); COMMIT;");
    txn2.deinit();
    var keptM = try db.exec("SELECT sum(v) FROM m;");
    defer keptM.deinit();
    try std.testing.expectEqual(@as(i64, 30), keptM.rows[0][0].integer);
    var keptA = try db.exec("SELECT sum(v) FROM aux.a;");
    defer keptA.deinit();
    try std.testing.expectEqual(@as(i64, 300), keptA.rows[0][0].integer);
    var keptT = try db.exec("SELECT sum(v) FROM t;");
    defer keptT.deinit();
    try std.testing.expectEqual(@as(i64, 3000), keptT.rows[0][0].integer);
    var save = try db.exec("SAVEPOINT sp1; DELETE FROM m WHERE id = 2; DELETE FROM aux.a WHERE id = 2; ROLLBACK TO sp1;");
    save.deinit();
    try std.testing.expectError(error.TransactionActive, db.exec("ATTACH 'x.db' AS x2;"));
    try std.testing.expectError(error.TransactionActive, db.exec("DETACH aux;"));
    var restoredM = try db.exec("SELECT count(*) FROM m;");
    defer restoredM.deinit();
    try std.testing.expectEqual(@as(i64, 2), restoredM.rows[0][0].integer);
    var restoredA = try db.exec("SELECT count(*) FROM aux.a;");
    defer restoredA.deinit();
    try std.testing.expectEqual(@as(i64, 2), restoredA.rows[0][0].integer);
    var release = try db.exec("RELEASE sp1; COMMIT;");
    release.deinit();
    var cleanup = try db.exec("DETACH aux;");
    cleanup.deinit();
}

test "version accessors roundtrip through the public api" {
    const path = "sqlite_zig_version_api_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try std.testing.expectEqual(@as(u32, 0), db.userVersion());
    try db.setUserVersion(41);
    try std.testing.expectEqual(@as(u32, 41), db.userVersion());
    try db.setApplicationId(99);
    try std.testing.expectEqual(@as(u32, 99), db.applicationId());
    try db.setSchemaVersion(7);
    try std.testing.expectEqual(@as(u32, 7), db.schemaVersion());
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    try std.testing.expectEqual(@as(u32, 41), db.userVersion());
    try std.testing.expectEqual(@as(u32, 99), db.applicationId());
    try std.testing.expectEqual(@as(u32, 7), db.schemaVersion());
}

test "typed parent child nullable foreign keys roundtrip" {
    const Parent = @import("../dsl/table.zig").table("pg_parent", struct {
        id: i64,
        label: []const u8,
    });
    const Child = @import("../dsl/table.zig").table("pg_child", struct {
        id: i64,
        parent_id: ?i64,
        label: []const u8,
    });
    const path = "sqlite_zig_pg_parent_child_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(Parent, .{ .primaryKey = Parent.id });
    try db.createTable(Child, .{
        .primaryKey = Child.id,
        .foreignKeys = &.{.{ .column = Child.parent_id, .references = Parent.id }},
    });
    try db.schema(Parent).validate();
    try db.schema(Child).validate();
    var p1 = try db.from(Parent).insert(.{ .id = 10, .label = "root" });
    p1.deinit();
    var c1 = try db.from(Child).insert(.{ .id = 1, .parent_id = 10, .label = "child" });
    c1.deinit();
    var orphan = try db.from(Child).insert(.{ .id = 2, .parent_id = null, .label = "orphan" });
    orphan.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Child).insert(.{ .id = 3, .parent_id = 99, .label = "bad" }));
    var kids = try db.from(Child).select(Child.all()).orderBy(Child.id.asc()).fetch();
    defer kids.deinit();
    try std.testing.expectEqual(@as(usize, 2), kids.count());
    try std.testing.expectEqual(@as(i64, 10), kids.at(0).parent_id.?);
    try std.testing.expectEqualStrings("child", kids.at(0).label);
    try std.testing.expect(kids.at(1).parent_id == null);
    var orphans = try db.from(Child).select(Child.all()).where(Child.parent_id.isNull()).fetch();
    defer orphans.deinit();
    try std.testing.expectEqual(@as(usize, 1), orphans.count());
    var linked = try db.from(Child).innerJoin(Parent, Child.parent_id.eq(Parent.id)).select(Child.all()).fetch();
    defer linked.deinit();
    try std.testing.expectEqual(@as(usize, 1), linked.count());
    try std.testing.expectEqualStrings("child", linked.at(0).label);
    var joined = try db.from(Child).innerJoin(Parent, Child.parent_id.eq(Parent.id)).select(.{ Child.id, Parent.label }).fetch();
    defer joined.deinit();
    try std.testing.expectEqual(@as(usize, 1), joined.count());
    var leftovers = try db.from(Child).leftJoin(Parent, Child.parent_id.eq(Parent.id)).select(Child.all()).orderBy(Child.id.asc()).fetch();
    defer leftovers.deinit();
    try std.testing.expectEqual(@as(usize, 2), leftovers.count());
    try std.testing.expectError(error.ConstraintViolation, db.from(Parent).delete().where(Parent.id.eq(10)).execute());
    var renamed = try (try db.from(Parent).update(.{ .label = "root2" })).where(Parent.id.eq(10)).execute();
    renamed.deinit();
    const rootName = try db.from(Parent).select(Parent.label).where(Parent.id.eq(10)).fetchOne();
    defer std.testing.allocator.free(rootName.text);
    try std.testing.expectEqualStrings("root2", rootName.text);
    try db.begin();
    var doomed = try db.from(Child).delete().where(Child.id.eq(1)).execute();
    doomed.deinit();
    try db.rollback();
    var kept = try db.from(Child).select(Child.all()).where(Child.id.eq(1)).fetchOne();
    defer db.from(Child).freeRow(&kept);
    try std.testing.expectEqual(@as(i64, 1), kept.id);
    db.close();
    db = try Connection.open(std.testing.allocator, path);
    errdefer db.close();
    var reopened = try db.from(Child).select(Child.all()).orderBy(Child.id.asc()).fetch();
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.count());
    try std.testing.expect(reopened.at(1).parent_id == null);
}

test "dynamic schema tables keep attached identity" {
    const path = "sqlite_zig_dyn_schema_main_test.db";
    const auxPath = "sqlite_zig_dyn_schema_aux_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, auxPath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, auxPath) catch {};
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO users VALUES (1, 'ann');");
    setup.deinit();
    var attach = try db.exec("ATTACH 'sqlite_zig_dyn_schema_aux_test.db' AS aux;");
    attach.deinit();
    var auxSetup = try db.exec("CREATE TABLE aux.orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount INTEGER); INSERT INTO aux.orders VALUES (1, 1, 100);");
    auxSetup.deinit();
    const users = db.table("users");
    const orders = db.schema("aux").table("orders");
    try std.testing.expectEqualStrings("", users.schema);
    try std.testing.expectEqualStrings("users", users.name);
    try std.testing.expectEqualStrings("aux", orders.schema);
    try std.testing.expectEqualStrings("orders", orders.name);
    const uid = users.column("id");
    const uname = users.column("name");
    const oid = orders.column("id");
    const oamount = orders.column("amount");
    try std.testing.expectEqualStrings("users", @import("../dsl/column.zig").dynRef(uid).table);
    try std.testing.expectEqualStrings("", @import("../dsl/column.zig").dynRef(uid).schema);
    try std.testing.expectEqualStrings("orders", @import("../dsl/column.zig").dynRef(oid).table);
    try std.testing.expectEqualStrings("aux", @import("../dsl/column.zig").dynRef(oid).schema);
    var one = try orders.selectAll().where(oid.eq(1)).fetch();
    defer one.deinit();
    try std.testing.expectEqual(@as(usize, 1), one.count());
    try std.testing.expectEqual(@as(i64, 100), (try one.get(0, "amount")).integer);
    var both = try users
        .innerJoin(orders, uid.eq(orders.column("user_id")))
        .select(.{ uid.as("userId"), uname, oid.as("orderId"), oamount })
        .fetch();
    defer both.deinit();
    try std.testing.expectEqual(@as(usize, 1), both.count());
    try std.testing.expectEqualStrings("userId", both.columns[0]);
    try std.testing.expectEqualStrings("orderId", both.columns[2]);
    var it = both.iter();
    const first = it.next().?;
    try std.testing.expectEqual(@as(i64, 1), (try first.get("userId")).integer);
    try std.testing.expectEqualStrings("ann", (try first.get("name")).text);
    try std.testing.expectEqual(@as(i64, 1), (try first.get("orderId")).integer);
    try std.testing.expect(it.next() == null);
    var detached = try db.exec("DETACH aux;");
    detached.deinit();
    try std.testing.expectError(error.UnknownTable, orders.selectAll().fetch());
}

test "column aliases disambiguate duplicate join projections" {
    const User = @import("../dsl/table.zig").table("alias_users", struct { id: i64, name: []const u8 });
    const Order = @import("../dsl/table.zig").table("alias_orders", struct { id: i64, user_id: i64, amount: i64 });
    const path = "sqlite_zig_alias_join_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(User, .{ .primaryKey = User.id });
    try db.createTable(Order, .{ .primaryKey = Order.id });
    var u = try db.from(User).insert(.{ .id = 1, .name = "ann" });
    u.deinit();
    var o = try db.from(Order).insert(.{ .id = 7, .user_id = 1, .amount = 100 });
    o.deinit();
    var rows = try db
        .from(User)
        .innerJoin(Order, User.id.eq(Order.user_id))
        .select(.{ User.id.as("userId"), User.name, Order.id.as("orderId"), Order.amount })
        .fetch();
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.count());
    try std.testing.expectEqualStrings("userId", rows.columns[0]);
    try std.testing.expectEqualStrings("name", rows.columns[1]);
    try std.testing.expectEqualStrings("orderId", rows.columns[2]);
    try std.testing.expectEqualStrings("amount", rows.columns[3]);
    try std.testing.expectEqual(@as(i64, 1), (try rows.get(0, "userId")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try rows.get(0, "orderId")).integer);
    try std.testing.expectEqualStrings("ann", (try rows.get(0, "name")).text);
    const users = db.table("alias_users");
    const orders = db.table("alias_orders");
    var dyn = try users
        .innerJoin(orders, users.column("id").eq(orders.column("user_id")))
        .select(.{
            users.column("id").as("userId"),
            users.column("name"),
            orders.column("id").as("orderId"),
        })
        .fetch();
    defer dyn.deinit();
    try std.testing.expectEqual(@as(i64, 1), (try dyn.get(0, "userId")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try dyn.get(0, "orderId")).integer);
}

test "having filters groups through the common expression system" {
    const path = "sqlite_zig_having_expr_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE hsales (grp TEXT, amount INTEGER); INSERT INTO hsales VALUES ('a', 10), ('a', 20), ('b', 7);");
    setup.deinit();
    var raw = try db.exec("SELECT grp, SUM(amount) FROM hsales GROUP BY grp HAVING COUNT(*) > 1;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 1), raw.count());
    try std.testing.expectEqualStrings("a", raw.rows[0][0].text);
    const Sale = @import("../dsl/table.zig").table("hsales", struct { grp: []const u8, amount: i64 });
    const sales = db.table("hsales");
    var dynAgg = try sales
        .select(.{sales.column("grp")})
        .groupBy(sales.column("grp"))
        .having(sales.column("grp").count().gt(1))
        .fetch();
    defer dynAgg.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynAgg.count());
    try std.testing.expectEqualStrings("a", dynAgg.rows[0][0].text);
    var typedAgg = try db
        .from(Sale)
        .select(.{Sale.grp})
        .groupBy(Sale.grp)
        .having(Sale.grp.count().gt(1))
        .fetch();
    defer typedAgg.deinit();
    try std.testing.expectEqual(@as(usize, 1), typedAgg.count());
    var dynAvg = try sales
        .select(.{sales.column("grp")})
        .groupBy(sales.column("grp"))
        .having(sales.column("amount").avg().gte(15))
        .fetch();
    defer dynAvg.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynAvg.count());
    var plain = try sales
        .select(.{sales.column("grp")})
        .groupBy(sales.column("grp"))
        .having(sales.column("grp").eq("b"))
        .fetch();
    defer plain.deinit();
    try std.testing.expectEqual(@as(usize, 1), plain.count());
    try std.testing.expectEqualStrings("b", plain.rows[0][0].text);
    var typedPlain = try db
        .from(Sale)
        .select(.{Sale.grp})
        .groupBy(Sale.grp)
        .having(Sale.grp.eq("b"))
        .fetch();
    defer typedPlain.deinit();
    try std.testing.expectEqual(@as(usize, 1), typedPlain.count());
}

test "scalar fetchOne and fetchOptional return single projection values" {
    const Item = @import("../dsl/table.zig").table("scalar_one_items", struct { id: i64, label: []const u8 });
    const path = "sqlite_zig_scalar_one_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(Item, .{ .primaryKey = Item.id });
    var first = try db.from(Item).insert(.{ .id = 1, .label = "one" });
    first.deinit();
    var second = try db.from(Item).insert(.{ .id = 2, .label = "two" });
    second.deinit();
    const items = db.table("scalar_one_items");
    const id = items.column("id");
    const label = items.column("label");
    try std.testing.expectEqual(@as(i64, 2), (try items.select(id).where(id.eq(2)).fetchOne()).integer);
    try std.testing.expectEqual(@as(i64, 1), (try db.from(Item).select(Item.id).where(Item.id.eq(1)).fetchOne()).integer);
    const missing = try items.select(label).where(id.eq(99)).fetchOptional();
    try std.testing.expect(missing == null);
    const present = try items.select(label).where(id.eq(1)).fetchOptional();
    try std.testing.expect(present != null);
    defer std.testing.allocator.free(present.?.text);
    try std.testing.expectEqualStrings("one", present.?.text);
    try std.testing.expectError(error.NoRows, items.select(id).where(id.eq(99)).fetchOne());
    try std.testing.expectError(error.TooManyRows, items.select(id).fetchOne());
    try std.testing.expectError(error.TooManyRows, items.select(id).fetchOptional());
}

test "raw dynamic and typed queries agree on values and errors" {
    const User = @import("../dsl/table.zig").table("equiv_users", struct { id: i64, name: []const u8, age: i64 });
    const path = "sqlite_zig_equiv_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(User, .{ .primaryKey = User.id });
    var seed = try db.exec("INSERT INTO equiv_users VALUES (1, 'ann', 30), (2, 'bob', 17), (3, 'cid', 44);");
    seed.deinit();
    var raw = try db.exec("SELECT id, name FROM equiv_users WHERE age >= 18 ORDER BY name;");
    defer raw.deinit();
    const users = db.table("equiv_users");
    var dyn = try users
        .select(.{ users.column("id"), users.column("name") })
        .where(users.column("age").gte(18))
        .orderBy(users.column("name").asc())
        .fetch();
    defer dyn.deinit();
    var typed = try db
        .from(User)
        .select(.{ User.id, User.name })
        .where(User.age.gte(18))
        .orderBy(User.name.asc())
        .fetch();
    defer typed.deinit();
    try std.testing.expectEqual(raw.count(), dyn.count());
    try std.testing.expectEqual(raw.count(), typed.count());
    try std.testing.expectEqual(@as(usize, 2), raw.count());
    for (0..raw.count()) |i| {
        try std.testing.expectEqual(raw.rows[i][0].integer, dyn.rows[i][0].integer);
        try std.testing.expectEqualStrings(raw.rows[i][1].text, dyn.rows[i][1].text);
        try std.testing.expectEqual(raw.rows[i][0].integer, typed.rows[i][0].integer);
        try std.testing.expectEqualStrings(raw.rows[i][1].text, typed.rows[i][1].text);
    }
    try std.testing.expectEqualStrings("id", dyn.columns[0]);
    try std.testing.expectEqualStrings("name", dyn.columns[1]);
    try std.testing.expectError(error.UnknownColumn, users.select(users.column("nope")).fetch());
    try std.testing.expectError(error.UnknownColumn, db.exec("SELECT nope FROM equiv_users;"));
    try std.testing.expectError(error.UnknownTable, db.table("missing").selectAll().fetch());
    try std.testing.expectError(error.UnknownTable, db.exec("SELECT * FROM missing;"));
}

test "multi-key order by sorts raw dynamic typed identically" {
    const Mk = @import("../dsl/table.zig").table("mk_sort", struct { grp: ?[]const u8, val: i64, tag: ?[]const u8 });
    const path = "sqlite_zig_multi_key_order_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    const t_db_mk = db.table("mk_sort");
    var setup = try db.exec("CREATE TABLE mk_sort (grp TEXT, val INTEGER, tag TEXT); INSERT INTO mk_sort VALUES ('b', 2, 'x'), ('a', 1, 'y'), ('b', 1, 'z'), ('a', 2, NULL), ('a', 1, 'w'), (NULL, 0, 'n');");
    setup.deinit();
    // NULLs sort first under ASC (SQLite total order) on every key.
    var raw = try db.exec("SELECT grp, val, tag FROM mk_sort ORDER BY grp, val, tag;");
    defer raw.deinit();
    try std.testing.expectEqual(@as(usize, 6), raw.count());
    try std.testing.expect(raw.rows[0][0] == .null);
    try std.testing.expectEqualStrings("n", raw.rows[0][2].text);
    try std.testing.expectEqualStrings("a", raw.rows[1][0].text);
    try std.testing.expectEqual(@as(i64, 1), raw.rows[1][1].integer);
    try std.testing.expectEqualStrings("w", raw.rows[1][2].text);
    try std.testing.expectEqualStrings("y", raw.rows[2][2].text);
    try std.testing.expect(raw.rows[3][2] == .null);
    try std.testing.expectEqualStrings("b", raw.rows[4][0].text);
    try std.testing.expectEqual(@as(i64, 1), raw.rows[4][1].integer);
    try std.testing.expectEqualStrings("x", raw.rows[5][2].text);
    // Per-key DESC inverts placement (NULLs last under DESC), like OP_Compare.
    var rawDesc = try db.exec("SELECT grp, val, tag FROM mk_sort ORDER BY grp DESC, val ASC;");
    defer rawDesc.deinit();
    try std.testing.expectEqual(@as(usize, 6), rawDesc.count());
    try std.testing.expectEqualStrings("b", rawDesc.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 1), rawDesc.rows[0][1].integer);
    try std.testing.expectEqualStrings("b", rawDesc.rows[1][0].text);
    try std.testing.expectEqual(@as(i64, 2), rawDesc.rows[1][1].integer);
    try std.testing.expectEqualStrings("a", rawDesc.rows[2][0].text);
    try std.testing.expect(rawDesc.rows[5][0] == .null);
    // Ordinal positions and aliases resolve per key.
    var rawOrd = try db.exec("SELECT grp, val, tag FROM mk_sort ORDER BY 1, 3;");
    defer rawOrd.deinit();
    try std.testing.expectEqual(@as(usize, 6), rawOrd.count());
    try std.testing.expect(rawOrd.rows[0][0] == .null);
    try std.testing.expect(rawOrd.rows[1][2] == .null);
    try std.testing.expectEqualStrings("w", rawOrd.rows[2][2].text);
    var rawAlias = try db.exec("SELECT grp AS g, val AS v, tag AS t FROM mk_sort ORDER BY g DESC, v ASC;");
    defer rawAlias.deinit();
    try std.testing.expectEqual(@as(usize, 6), rawAlias.count());
    try std.testing.expectEqualStrings("b", rawAlias.rows[0][0].text);
    try std.testing.expect(rawAlias.rows[5][0] == .null);
    // LIMIT/OFFSET apply after the full multi-key sort.
    var rawPage = try db.exec("SELECT grp, val, tag FROM mk_sort ORDER BY grp, val, tag LIMIT 2 OFFSET 1;");
    defer rawPage.deinit();
    try std.testing.expectEqual(@as(usize, 2), rawPage.count());
    try std.testing.expectEqualStrings("w", rawPage.rows[0][2].text);
    try std.testing.expectEqualStrings("y", rawPage.rows[1][2].text);
    // Dynamic and Typed tuples build the same key list: grp ASC, val DESC.
    var rawMixed = try db.exec("SELECT grp, val, tag FROM mk_sort ORDER BY grp ASC, val DESC;");
    defer rawMixed.deinit();
    var dyn = try t_db_mk.select(.{ t_db_mk.column("grp"), t_db_mk.column("val"), t_db_mk.column("tag") }).orderBy(.{ t_db_mk.column("grp").asc(), t_db_mk.column("val").desc() }).fetch();
    defer dyn.deinit();
    var typed = try db.from(Mk).select(.{ Mk.grp, Mk.val, Mk.tag }).orderBy(.{ Mk.grp.asc(), Mk.val.desc() }).fetch();
    defer typed.deinit();
    try std.testing.expectEqual(rawMixed.count(), dyn.count());
    try std.testing.expectEqual(rawMixed.count(), typed.count());
    try std.testing.expectEqual(@as(usize, 6), rawMixed.count());
    try std.testing.expect(rawMixed.rows[0][0] == .null);
    try std.testing.expectEqual(@as(i64, 2), rawMixed.rows[1][1].integer);
    for (0..rawMixed.count()) |i| {
        try expectSameSortCell(rawMixed.rows[i][0], dyn.rows[i][0]);
        try expectSameSortCell(rawMixed.rows[i][1], dyn.rows[i][1]);
        try expectSameSortCell(rawMixed.rows[i][2], dyn.rows[i][2]);
        try expectSameSortCell(rawMixed.rows[i][0], typed.rows[i][0]);
        try expectSameSortCell(rawMixed.rows[i][1], typed.rows[i][1]);
        try expectSameSortCell(rawMixed.rows[i][2], typed.rows[i][2]);
    }
    // Unknown keys stay errors, never silent picks.
    try std.testing.expectError(error.UnknownColumn, db.exec("SELECT grp FROM mk_sort ORDER BY nope;"));
    // Compound trailing ORDER BY takes multiple keys over ordinals.
    var compound = try db.exec("SELECT grp, val FROM mk_sort WHERE grp = 'a' UNION ALL SELECT grp, val FROM mk_sort WHERE grp = 'b' ORDER BY 1 DESC, 2 ASC;");
    defer compound.deinit();
    try std.testing.expectEqual(@as(usize, 5), compound.count());
    try std.testing.expectEqualStrings("b", compound.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 1), compound.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 2), compound.rows[1][1].integer);
    try std.testing.expectEqualStrings("a", compound.rows[2][0].text);
    // Qualified keys resolve against their own table, not a same-named column.
    var qualSetup = try db.exec("CREATE TABLE q_a (id INTEGER, v TEXT); CREATE TABLE q_b (id INTEGER, w TEXT); INSERT INTO q_a VALUES (1, 'a1'), (2, 'a2'), (3, 'a3'); INSERT INTO q_b VALUES (2, 'b2'), (3, 'b3'), (4, 'b4');");
    qualSetup.deinit();
    var qualRight = try db.exec("SELECT q_a.id, q_a.v, q_b.id, q_b.w FROM q_a RIGHT JOIN q_b ON q_a.id = q_b.id ORDER BY q_b.id DESC, q_a.id ASC;");
    defer qualRight.deinit();
    try std.testing.expectEqual(@as(usize, 3), qualRight.count());
    try std.testing.expectEqual(@as(i64, 4), qualRight.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 3), qualRight.rows[1][2].integer);
    try std.testing.expectEqual(@as(i64, 2), qualRight.rows[2][2].integer);
    var qualFull = try db.exec("SELECT q_a.id, q_b.id FROM q_a FULL JOIN q_b ON q_a.id = q_b.id ORDER BY q_a.id DESC, q_b.id ASC;");
    defer qualFull.deinit();
    try std.testing.expectEqual(@as(usize, 4), qualFull.count());
    try std.testing.expectEqual(@as(i64, 3), qualFull.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), qualFull.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, 1), qualFull.rows[2][0].integer);
    try std.testing.expect(qualFull.rows[3][0] == .null);
    try std.testing.expectEqual(@as(i64, 4), qualFull.rows[3][1].integer);
    // Qualified keys outside the projection sort pre-projection pairs.
    var qualOuter = try db.exec("SELECT q_a.v, q_b.w FROM q_a RIGHT JOIN q_b ON q_a.id = q_b.id ORDER BY q_b.id DESC, q_a.id ASC;");
    defer qualOuter.deinit();
    try std.testing.expectEqual(@as(usize, 3), qualOuter.count());
    try std.testing.expectEqualStrings("b4", qualOuter.rows[0][1].text);
    try std.testing.expectEqualStrings("b3", qualOuter.rows[1][1].text);
    try std.testing.expectEqualStrings("b2", qualOuter.rows[2][1].text);
}

fn expectSameSortCell(a: Value, b: Value) !void {
    if (a == .null or b == .null) {
        try std.testing.expect(a == .null and b == .null);
        return;
    }
    try std.testing.expectEqual(a.order(b, .binary), .eq);
}

test "database files carry the sqlite magic and reopen intact" {
    const path = "sqlite_zig_file_format_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    {
        var db = try Connection.open(std.testing.allocator, path);
        defer db.close();
        var setup = try db.exec("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, data BLOB); INSERT INTO users VALUES (1,'alice',30,x'00ff'),(2,'cara',NULL,NULL),(3,'bob',-9223372036854775808,NULL); CREATE INDEX users_name_idx ON users(name); CREATE TABLE orders(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), amount REAL); INSERT INTO orders VALUES (1,1,9.5),(2,1,NULL); CREATE VIEW adult_users AS SELECT id, name FROM users WHERE age >= 18;");
        setup.deinit();
    }
    var raw = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{ .mode = .read_only });
    const stat = try raw.stat(std.testing.io);
    var fileImage = try std.testing.allocator.alloc(u8, @intCast(stat.size));
    defer std.testing.allocator.free(fileImage);
    const got = try raw.readPositional(std.testing.io, &.{fileImage}, 0);
    raw.close(std.testing.io);
    try std.testing.expectEqual(fileImage.len, got);
    try std.testing.expectEqualStrings("SQLite format 3\x00", fileImage[0..16]);
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var users = try db.exec("SELECT id, name, age FROM users ORDER BY id;");
    defer users.deinit();
    try std.testing.expectEqual(@as(usize, 3), users.count());
    try std.testing.expectEqual(@as(i64, 1), users.rows[0][0].integer);
    try std.testing.expectEqualStrings("alice", users.rows[0][1].text);
    try std.testing.expectEqual(@as(i64, 30), users.rows[0][2].integer);
    try std.testing.expectEqualStrings("cara", users.rows[1][1].text);
    try std.testing.expect(users.rows[1][2] == .null);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), users.rows[2][2].integer);
    var blob = try db.exec("SELECT hex(data) FROM users ORDER BY id;");
    defer blob.deinit();
    try std.testing.expectEqualStrings("00FF", blob.rows[0][0].text);
    try std.testing.expect(blob.rows[1][0] == .null);
    var orders = try db.exec("SELECT amount FROM orders ORDER BY id;");
    defer orders.deinit();
    try std.testing.expectEqual(@as(f64, 9.5), orders.rows[0][0].real);
    try std.testing.expect(orders.rows[1][0] == .null);
    var adults = try db.exec("SELECT id, name FROM adult_users;");
    defer adults.deinit();
    try std.testing.expectEqual(@as(usize, 1), adults.count());
    try std.testing.expectEqualStrings("alice", adults.rows[0][1].text);
    var check = try db.exec("PRAGMA integrity_check;");
    defer check.deinit();
    try std.testing.expectEqualStrings("ok", check.rows[0][0].text);
}

test "null three-valued logic matches sqlite" {
    const path = "sqlite_zig_null_matrix_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    // NULL never equals, orders, or ranges: only IS (NOT) NULL sees it.
    var cmp = try db.exec("SELECT NULL = NULL, NULL <> NULL, NULL < NULL, NULL > NULL, NULL IS NULL, NULL IS NOT NULL;");
    defer cmp.deinit();
    try std.testing.expect(cmp.rows[0][0] == .null);
    try std.testing.expect(cmp.rows[0][1] == .null);
    try std.testing.expect(cmp.rows[0][2] == .null);
    try std.testing.expect(cmp.rows[0][3] == .null);
    try std.testing.expectEqual(@as(i64, 1), cmp.rows[0][4].integer);
    try std.testing.expectEqual(@as(i64, 0), cmp.rows[0][5].integer);
    // AND/OR/NOT truth tables with NULL.
    var logic = try db.exec("SELECT (NULL AND 1), (NULL AND 0), (NULL OR 1), (NULL OR 0), (NOT NULL);");
    defer logic.deinit();
    try std.testing.expect(logic.rows[0][0] == .null);
    try std.testing.expectEqual(@as(i64, 0), logic.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 1), logic.rows[0][2].integer);
    try std.testing.expect(logic.rows[0][3] == .null);
    try std.testing.expect(logic.rows[0][4] == .null);
    // IN/NOT IN with NULL operand, NULL list members, and empty subqueries.
    var membership = try db.exec("SELECT 1 IN (NULL), 1 NOT IN (NULL), NULL IN (1, 2), NULL NOT IN (1, 2);");
    defer membership.deinit();
    for (membership.rows[0]) |cell| try std.testing.expect(cell == .null);
    var emptySub = try db.exec("CREATE TABLE empty_in (x INTEGER); SELECT 1 IN (SELECT x FROM empty_in), 1 NOT IN (SELECT x FROM empty_in);");
    defer emptySub.deinit();
    try std.testing.expectEqual(@as(i64, 0), emptySub.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 1), emptySub.rows[0][1].integer);
    // A NULL row with no match makes IN/NOT IN unknown, never false/true.
    var nullSub = try db.exec("SELECT 1 IN (SELECT NULL), 1 NOT IN (SELECT NULL), 2 IN (SELECT NULL UNION ALL SELECT 1), 1 IN (SELECT NULL UNION ALL SELECT 1);");
    defer nullSub.deinit();
    try std.testing.expect(nullSub.rows[0][0] == .null);
    try std.testing.expect(nullSub.rows[0][1] == .null);
    try std.testing.expect(nullSub.rows[0][2] == .null);
    try std.testing.expectEqual(@as(i64, 1), nullSub.rows[0][3].integer);
    // Aggregates over empty and all-NULL inputs.
    var agg = try db.exec("SELECT SUM(x), TOTAL(x), AVG(x), COUNT(x), COUNT(*), GROUP_CONCAT(x) FROM empty_in;");
    defer agg.deinit();
    try std.testing.expect(agg.rows[0][0] == .null);
    try std.testing.expectEqual(@as(f64, 0.0), agg.rows[0][1].real);
    try std.testing.expect(agg.rows[0][2] == .null);
    try std.testing.expectEqual(@as(i64, 0), agg.rows[0][3].integer);
    try std.testing.expectEqual(@as(i64, 0), agg.rows[0][4].integer);
    try std.testing.expect(agg.rows[0][5] == .null);
    var allNull = try db.exec("SELECT SUM(x), TOTAL(x), COUNT(x), COUNT(*), GROUP_CONCAT(x, '|') FROM (SELECT NULL AS x UNION ALL SELECT NULL);");
    defer allNull.deinit();
    try std.testing.expect(allNull.rows[0][0] == .null);
    try std.testing.expectEqual(@as(f64, 0.0), allNull.rows[0][1].real);
    try std.testing.expectEqual(@as(i64, 0), allNull.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 2), allNull.rows[0][3].integer);
    try std.testing.expect(allNull.rows[0][4] == .null);
}

test "integer and real edge cases match sqlite" {
    const path = "sqlite_zig_numeric_edge_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    // Boundary storage round-trips through a table.
    var setup = try db.exec("CREATE TABLE nums (v INTEGER); INSERT INTO nums VALUES (9223372036854775807), (-9223372036854775808), (0), (-1), (1);");
    setup.deinit();
    var bounds = try db.exec("SELECT v FROM nums ORDER BY v;");
    defer bounds.deinit();
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), bounds.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, -1), bounds.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, 0), bounds.rows[2][0].integer);
    try std.testing.expectEqual(@as(i64, 1), bounds.rows[3][0].integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), bounds.rows[4][0].integer);
    // Overflow promotes to REAL, exactly like the reference implementation.
    var overflow = try db.exec("SELECT 9223372036854775807 + 1, -9223372036854775808 - 1, 3037000500 * 3037000500;");
    defer overflow.deinit();
    try std.testing.expectEqual(@as(f64, 9223372036854775808.0), overflow.rows[0][0].real);
    try std.testing.expect(overflow.rows[0][1].real < -9.2233720368547e18);
    try std.testing.expect(overflow.rows[0][2].real > 9.223372036e18);
    // Division and remainder by zero yield NULL, never an error or panic.
    var divZero = try db.exec("SELECT 1/0, 1%0, -9223372036854775808 / -1, -9223372036854775808 % -1;");
    defer divZero.deinit();
    try std.testing.expect(divZero.rows[0][0] == .null);
    try std.testing.expect(divZero.rows[0][1] == .null);
    try std.testing.expectEqual(@as(f64, 9223372036854775808.0), divZero.rows[0][2].real);
    try std.testing.expectEqual(@as(i64, 0), divZero.rows[0][3].integer);
    // Integer division truncates; bit operations and shifts match.
    var intOps = try db.exec("SELECT 7/2, 7%3, -7%3, 7%-3, 12 & 10, 12 | 10, 1 << 70, 1 >> 70, 1 << 3, 256 >> 2;");
    defer intOps.deinit();
    const expectedInts = [_]i64{ 3, 1, -1, 1, 8, 14, 0, 0, 8, 64 };
    for (expectedInts, 0..) |expected, i| try std.testing.expectEqual(expected, intOps.rows[0][i].integer);
    // Real edges: signed zero equality, infinities, real division by zero.
    var realEdges = try db.exec("SELECT 0.0 = -0.0, 1e999, -1e999, 1.0/0.0;");
    defer realEdges.deinit();
    try std.testing.expectEqual(@as(i64, 1), realEdges.rows[0][0].integer);
    try std.testing.expect(std.math.isInf(realEdges.rows[0][1].real) and realEdges.rows[0][1].real > 0);
    try std.testing.expect(std.math.isInf(realEdges.rows[0][2].real) and realEdges.rows[0][2].real < 0);
    try std.testing.expect(realEdges.rows[0][3] == .null);
    // Concatenation with NULL is NULL.
    var concatNull = try db.exec("SELECT 'a' || NULL, NULL || 'b', 'foo' || 'bar';");
    defer concatNull.deinit();
    try std.testing.expect(concatNull.rows[0][0] == .null);
    try std.testing.expect(concatNull.rows[0][1] == .null);
    try std.testing.expectEqualStrings("foobar", concatNull.rows[0][2].text);
}

test "text blob and scalar edges match sqlite" {
    const path = "sqlite_zig_text_blob_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    // Empty values round-trip and compare correctly.
    var setup = try db.exec("CREATE TABLE blobs (t TEXT, b BLOB); INSERT INTO blobs VALUES ('', x''), ('hello', x'00ff'), (NULL, NULL);");
    setup.deinit();
    var empties = try db.exec("SELECT length(t), length(b) FROM blobs ORDER BY rowid;");
    defer empties.deinit();
    try std.testing.expectEqual(@as(usize, 3), empties.count());
    try std.testing.expectEqual(@as(i64, 0), empties.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), empties.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 5), empties.rows[1][0].integer);
    try std.testing.expectEqual(@as(i64, 2), empties.rows[1][1].integer);
    try std.testing.expect(empties.rows[2][0] == .null);
    // Blob bytes (including zero) survive storage and order by memcmp,
    // with the empty blob smallest.
    var blobOrder = try db.exec("SELECT hex(b) FROM blobs WHERE b IS NOT NULL ORDER BY b;");
    defer blobOrder.deinit();
    try std.testing.expectEqualStrings("", blobOrder.rows[0][0].text);
    try std.testing.expectEqualStrings("00FF", blobOrder.rows[1][0].text);
    // LIKE is case-insensitive, GLOB is case-sensitive, length counts UTF-8 characters.
    var pattern = try db.exec("SELECT 'AbC' LIKE 'abc', 'AbC' GLOB 'abc', 'AbC' LIKE 'a_c', length(char(104,233,108,108,111)), substr('hello', -2), substr('hello', 2, 2);");
    defer pattern.deinit();
    try std.testing.expectEqual(@as(i64, 1), pattern.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 0), pattern.rows[0][1].integer);
    try std.testing.expectEqual(@as(i64, 1), pattern.rows[0][2].integer);
    try std.testing.expectEqual(@as(i64, 5), pattern.rows[0][3].integer);
    try std.testing.expectEqualStrings("lo", pattern.rows[0][4].text);
    try std.testing.expectEqualStrings("el", pattern.rows[0][5].text);
    // Scalar aggregates over values.
    var scalars = try db.exec("SELECT TOTAL(x), AVG(x), GROUP_CONCAT(x), GROUP_CONCAT(x, '|') FROM (SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3);");
    defer scalars.deinit();
    try std.testing.expectEqual(@as(f64, 6.0), scalars.rows[0][0].real);
    try std.testing.expectEqual(@as(f64, 2.0), scalars.rows[0][1].real);
    try std.testing.expectEqualStrings("1,2,3", scalars.rows[0][2].text);
    try std.testing.expectEqualStrings("1|2|3", scalars.rows[0][3].text);
}

test "rowid order by follows storage order" {
    const path = "sqlite_zig_rowid_order_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE r (v TEXT); INSERT INTO r VALUES ('a'), ('b'), ('c'); CREATE TABLE w (k TEXT PRIMARY KEY, v INTEGER) WITHOUT ROWID; INSERT INTO w VALUES ('x', 1);");
    setup.deinit();
    var asc = try db.exec("SELECT v FROM r ORDER BY rowid;");
    defer asc.deinit();
    try std.testing.expectEqualStrings("a", asc.rows[0][0].text);
    try std.testing.expectEqualStrings("c", asc.rows[2][0].text);
    var desc = try db.exec("SELECT v FROM r ORDER BY rowid DESC;");
    defer desc.deinit();
    try std.testing.expectEqualStrings("c", desc.rows[0][0].text);
    try std.testing.expectEqualStrings("a", desc.rows[2][0].text);
    var oid = try db.exec("SELECT v FROM r ORDER BY oid;");
    defer oid.deinit();
    try std.testing.expectEqualStrings("a", oid.rows[0][0].text);
    // WITHOUT ROWID tables have no rowid to order by.
    try std.testing.expectError(error.UnknownColumn, db.exec("SELECT v FROM w ORDER BY rowid;"));
}

test "subquery nesting correlation and emptiness match sqlite" {
    const path = "sqlite_zig_subquery_edge_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    var setup = try db.exec("CREATE TABLE sq_a (id INTEGER, grp TEXT); CREATE TABLE sq_b (aid INTEGER, val INTEGER); INSERT INTO sq_a VALUES (1, 'x'), (2, 'y'), (3, 'x'); INSERT INTO sq_b VALUES (1, 10), (1, 20), (2, 30);");
    setup.deinit();
    // Scalar subquery, three nesting levels, correlated EXISTS.
    var scalar = try db.exec("SELECT (SELECT max(v) FROM (SELECT val AS v FROM sq_b WHERE aid = sq_a.id)) FROM sq_a ORDER BY id;");
    defer scalar.deinit();
    try std.testing.expectEqual(@as(i64, 20), scalar.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 30), scalar.rows[1][0].integer);
    try std.testing.expect(scalar.rows[2][0] == .null);
    var correlated = try db.exec("SELECT id FROM sq_a WHERE EXISTS (SELECT 1 FROM sq_b WHERE aid = sq_a.id AND val > 15) ORDER BY id;");
    defer correlated.deinit();
    try std.testing.expectEqual(@as(usize, 2), correlated.count());
    try std.testing.expectEqual(@as(i64, 1), correlated.rows[0][0].integer);
    try std.testing.expectEqual(@as(i64, 2), correlated.rows[1][0].integer);
    // NULL never matches IN, even against itself; empty results decide cleanly.
    var nullIn = try db.exec("SELECT NULL IN (SELECT id FROM sq_a), NULL IN (1, 2);");
    defer nullIn.deinit();
    try std.testing.expect(nullIn.rows[0][0] == .null);
    try std.testing.expect(nullIn.rows[0][1] == .null);
    // Correlated NOT EXISTS finds the childless row.
    var childless = try db.exec("SELECT grp FROM sq_a WHERE NOT EXISTS (SELECT 1 FROM sq_b WHERE aid = sq_a.id) ORDER BY id;");
    defer childless.deinit();
    try std.testing.expectEqual(@as(usize, 1), childless.count());
    try std.testing.expectEqualStrings("x", childless.rows[0][0].text);
    // Subquery in a DML statement.
    var promoted = try db.exec("UPDATE sq_b SET val = val + (SELECT count(*) FROM sq_a WHERE grp = 'x') WHERE aid = 2;");
    defer promoted.deinit();
    var check = try db.exec("SELECT val FROM sq_b WHERE aid = 2;");
    defer check.deinit();
    try std.testing.expectEqual(@as(i64, 32), check.rows[0][0].integer);
}

test "dsl-looking column names stay usable end to end" {
    const WeirdRow = struct {
        id: i64,
        all: []const u8,
        count: i64,
        select: []const u8,
        where: []const u8,
        join: []const u8,
        limit: i64,
    };
    const Weird = @import("../dsl/table.zig").table("cf_weird", WeirdRow);
    const path = "sqlite_zig_collision_test.db";
    var db = try freshDb(path);
    defer dropDb(db, path);
    try db.createTable(Weird, .{ .primaryKey = Weird.id });
    try db.schema(Weird).validate();
    var inserted = try db.from(Weird).insert(.{ .id = 1, .all = "a", .count = 7, .select = "s", .where = "w", .join = "j", .limit = 50 });
    inserted.deinit();
    var second = try db.from(Weird).insert(.{ .id = 2, .all = "b", .count = 3, .select = "t", .where = "x", .join = "k", .limit = 10 });
    second.deinit();
    // Each colliding name filters, orders, and updates as a plain column.
    var filtered = try db.from(Weird).select(Weird.all).where(Weird.where.eq("w")).fetch();
    defer filtered.deinit();
    try std.testing.expectEqual(@as(usize, 1), filtered.count());
    try std.testing.expectEqualStrings("a", filtered.rows[0][0].text);
    // Raw SQL spells reserved-word columns quoted, exactly as SQLite requires.
    var rawQuoted = try db.exec("SELECT \"all\", \"count\" FROM cf_weird WHERE \"where\" = 'w' ORDER BY \"limit\";");
    defer rawQuoted.deinit();
    try std.testing.expectEqual(@as(usize, 1), rawQuoted.count());
    try std.testing.expectEqualStrings("a", rawQuoted.rows[0][0].text);
    try std.testing.expectEqual(@as(i64, 7), rawQuoted.rows[0][1].integer);
    var ordered = try db.from(Weird).select(Weird.all).orderBy(Weird.limit.asc()).fetch();
    defer ordered.deinit();
    try std.testing.expectEqual(@as(usize, 2), ordered.count());
    try std.testing.expectEqualStrings("b", ordered.rows[0][0].text);
    try std.testing.expectEqualStrings("a", ordered.rows[1][0].text);
    var renamed = try (try db.from(Weird).update(.{ .limit = 99 })).where(Weird.id.eq(2)).execute();
    renamed.deinit();
    const checkLimit = try db.from(Weird).select(Weird.limit).where(Weird.id.eq(2)).fetchOne();
    try std.testing.expectEqual(@as(i64, 99), checkLimit.integer);
    var summed = try db.from(Weird).select(.{Weird.count.sum()}).fetch();
    defer summed.deinit();
    try std.testing.expectEqual(@as(i64, 10), summed.rows[0][0].integer);
    // `selectAll()` is the all-columns operation; raw SELECT * agrees.
    var everything = try db.from(Weird).selectAll().orderBy(Weird.id.asc()).fetch();
    defer everything.deinit();
    var rawStar = try db.exec("SELECT * FROM cf_weird ORDER BY id;");
    defer rawStar.deinit();
    try std.testing.expectEqual(rawStar.count(), everything.count());
    try std.testing.expectEqual(@as(usize, 7), rawStar.columns.len);
    for (0..everything.count()) |i| {
        try std.testing.expectEqual(rawStar.rows[i][0].integer, everything.at(i).id);
        try std.testing.expectEqualStrings(rawStar.rows[i][1].text, everything.at(i).all);
        try std.testing.expectEqual(rawStar.rows[i][2].integer, everything.at(i).count);
    }
    // Dynamic DSL sees the same columns under the same names.
    const dynWeird = db.table("cf_weird");
    var dynFiltered = try dynWeird.select(.{dynWeird.column("all")}).where(dynWeird.column("where").eq("x")).fetch();
    defer dynFiltered.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynFiltered.count());
    try std.testing.expectEqualStrings("b", dynFiltered.rows[0][0].text);
    // Aliases keep colliding columns working.
    const w = @import("../dsl/table.zig").aliased(Weird, "w");
    var aliasedRows = try db.from(w).select(w.all).where(w.id.eq(1)).fetch();
    defer aliasedRows.deinit();
    try std.testing.expectEqual(@as(usize, 1), aliasedRows.count());
    try std.testing.expectEqualStrings("a", aliasedRows.rows[0][0].text);
    var gone = try db.from(Weird).delete().where(Weird.join.eq("k")).execute();
    gone.deinit();
    var remaining = try db.exec("SELECT count(*) FROM cf_weird;");
    defer remaining.deinit();
    try std.testing.expectEqual(@as(i64, 1), remaining.rows[0][0].integer);
}
