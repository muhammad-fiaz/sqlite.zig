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

pub const ForeignKeyOption = struct { column: []const u8 = "", table: []const u8, referenced_column: []const u8, column_key: ?ColumnKey = null };
pub const TableOptions = struct { if_not_exists: bool = false, primary_key: ?[]const u8 = null, primary_key_key: ?ColumnKey = null, unique_columns: []const []const u8 = &.{}, unique_keys: []const ColumnKey = &.{}, foreign_keys: []const ForeignKeyOption = &.{} };

const Savepoint = struct { name: []u8, schema: Schema };

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
        const bytes = try sqlite_image.encode(self.allocator, &self.schema);
        defer self.allocator.free(bytes);
        try self.file.writeImage(bytes);
    }

    pub fn exec(self: *Connection, sql: []const u8) !Result {
        return self.execute(sql, &.{});
    }

    pub fn prepare(self: *Connection, sql: []const u8) !Prepared {
        return .{ .connection = self, .sql = try self.allocator.dupe(u8, sql), .allocator = self.allocator, .parameters = .empty, .execute_fn = executePrepared };
    }

    pub fn from(self: *Connection, comptime TableType: type) @import("../dsl/query_builder.zig").Query(TableType) {
        return @import("../dsl/query_builder.zig").Query(TableType).init(self, TableType.table_name, executeForDsl);
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
            var definition = ast.ColumnDef{ .name = field.name, .type_name = dslTypeName(field.type), .primary_key = if (options.primary_key) |key| std.mem.eql(u8, key, field.name) else if (options.primary_key_key) |key| std.mem.eql(u8, key.name, field.name) else false };
            for (options.unique_columns) |unique_column| {
                if (std.mem.eql(u8, unique_column, field.name)) definition.unique = true;
            }
            for (options.unique_keys) |unique_column| {
                if (std.mem.eql(u8, unique_column.name, field.name)) definition.unique = true;
            }
            for (options.foreign_keys) |foreign_key| {
                const local_name = if (foreign_key.column_key) |key| key.name else foreign_key.column;
                if (std.mem.eql(u8, local_name, field.name)) definition.foreign_key = .{ .table = foreign_key.table, .column = foreign_key.referenced_column };
            }
            definitions[index] = definition;
        }
        try self.schema.createTable(TableType.table_name, &definitions);
        if (!self.transaction_active) try self.persist();
    }

    pub fn dropTable(self: *Connection, comptime TableType: type) !void {
        try self.schema.dropTable(TableType.table_name);
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

    fn dslTypeName(comptime T: type) []const u8 {
        return switch (@typeInfo(T)) {
            .int, .comptime_int, .bool => "INTEGER",
            .float, .comptime_float => "REAL",
            .pointer => |pointer| if (pointer.size == .slice and pointer.child == u8) "TEXT" else "BLOB",
            else => "BLOB",
        };
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
            .drop_table => |value| try self.dropTableCommand(value),
            .insert => |value| try self.insert(value, parameters),
            .select => |value| try self.select(value, parameters),
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
    fn createTableCommand(self: *Connection, value: anytype) !Result {
        if (self.schema.find(value.name) != null and value.if_not_exists) return try emptyResult(self.allocator);
        try self.schema.createTable(value.name, value.columns);
        return try emptyResult(self.allocator);
    }
    fn dropTableCommand(self: *Connection, name: []const u8) !Result {
        try self.schema.dropTable(name);
        return try emptyResult(self.allocator);
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
            .like, .is_null, .is_not_null, .between => false,
        };
    }

    fn matches(self: *Connection, table: *const Table, row: []const Value, condition: ?ast.Conditions, parameters: []const Value) !bool {
        if (condition) |items| {
            var result = true;
            for (items) |item| {
                const current = row[try columnIndex(table, item.column)];
                const item_result = if (item.op == .is_null) current == .null else if (item.op == .is_not_null) current != .null else if (item.op == .between) compare(current, .greater_equal, try self.resolve(item.value, parameters)) and compare(current, .less_equal, try self.resolve(item.value2 orelse return error.InvalidSql, parameters)) else if (item.op == .like) blk: {
                    const pattern = try self.resolve(item.value, parameters);
                    break :blk current == .text and pattern == .text and likeMatch(current.text, pattern.text);
                } else compare(current, item.op, try self.resolve(item.value, parameters));
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
        return text.len != 0 and pattern[0] == text[0] and likeMatch(text[1..], pattern[1..]);
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
        return switch (expr) {
            .literal => |value| value,
            .parameter => |index| if (index == 0 or index > parameters.len) error.InvalidParameter else parameters[index - 1],
            .identifier => |name| row[try columnIndex(table, name)],
            .wildcard => error.InvalidSql,
            .function => |call| blk: {
                const argument = if (call.argument.* == .wildcard) .null else try self.eval(table, row, call.argument.*, parameters);
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
                if (std.ascii.eqlIgnoreCase(call.name, "typeof")) break :blk .{ .text = argument.typeName() };
                if (std.ascii.eqlIgnoreCase(call.name, "coalesce") or std.ascii.eqlIgnoreCase(call.name, "ifnull")) break :blk argument;
                return error.Unsupported;
            },
        };
    }

    fn materialize(self: *Connection, table: *const Table, row: []const Value, expr: ast.Expr, parameters: []const Value) !Value {
        if (expr == .function) {
            const call = expr.function;
            if (std.ascii.eqlIgnoreCase(call.name, "lower") or std.ascii.eqlIgnoreCase(call.name, "upper")) {
                const argument = try self.eval(table, row, call.argument.*, parameters);
                if (argument == .text) {
                    const copy = try self.allocator.dupe(u8, argument.text);
                    for (copy) |*byte| {
                        if (std.ascii.eqlIgnoreCase(call.name, "lower")) {
                            byte.* = std.ascii.toLower(byte.*);
                        } else {
                            byte.* = std.ascii.toUpper(byte.*);
                        }
                    }
                    return .{ .text = copy };
                }
            }
        }
        return try self.copyValue(try self.eval(table, row, expr, parameters));
    }

    fn insert(self: *Connection, value: anytype, parameters: []const Value) !Result {
        const table = self.schema.find(value.table) orelse return error.UnknownTable;
        for (value.rows) |row_exprs| {
            var row = try self.allocator.alloc(Value, table.columns.len);
            defer self.allocator.free(row);
            @memset(row, .null);
            if (value.columns.len == 0) {
                if (row_exprs.len != row.len) return error.ColumnCountMismatch;
                for (row_exprs, 0..) |expr, index| row[index] = try self.resolve(expr, parameters);
            } else {
                if (value.columns.len != row_exprs.len) return error.ColumnCountMismatch;
                for (value.columns, row_exprs) |name, expr| row[try columnIndex(table, name)] = try self.resolve(expr, parameters);
            }
            try self.schema.appendRow(table, row);
        }
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = value.rows.len };
    }

    fn select(self: *Connection, value: anytype, parameters: []const Value) !Result {
        var columns = std.ArrayList([]const u8).empty;
        defer columns.deinit(self.allocator);
        var projections = std.ArrayList(ast.Projection).empty;
        defer projections.deinit(self.allocator);
        if (value.table) |table_name| {
            const table = self.schema.findConst(table_name) orelse return error.UnknownTable;
            if (value.join) |join| return try self.selectJoin(value, table, join);
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
                return .{ .allocator = self.allocator, .columns = try self.allocator.dupe([]const u8, columns.items), .rows = aggregate_rows };
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
                    return .{ .allocator = self.allocator, .columns = try self.allocator.dupe([]const u8, columns.items), .rows = aggregate_rows };
                }
            }
            for (value.projections) |projection| if (projection.expr == .wildcard) for (table.columns) |column| try columns.append(self.allocator, column.name) else if (projection.expr == .identifier) try columns.append(self.allocator, projection.alias orelse projection.expr.identifier) else if (projection.expr == .function) try columns.append(self.allocator, projection.alias orelse projection.expr.function.name);
            if (columns.items.len == 0) for (value.projections) |projection| try columns.append(self.allocator, projection.alias orelse "?column?");
            var rows = std.ArrayList([]Value).empty;
            errdefer {
                for (rows.items) |row| self.allocator.free(row);
                rows.deinit(self.allocator);
            }
            const ordered_indices = try self.allocator.alloc(usize, table.rows.items.len);
            defer self.allocator.free(ordered_indices);
            for (ordered_indices, 0..) |*index, row_index| index.* = row_index;
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
            return .{ .allocator = self.allocator, .columns = try self.allocator.dupe([]const u8, columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
        }
        const result_row = try self.allocator.alloc(Value, value.projections.len);
        for (value.projections, 0..) |projection, index| result_row[index] = try self.resolve(projection.expr, parameters);
        var rows = try self.allocator.alloc([]Value, 1);
        rows[0] = result_row;
        for (value.projections) |projection| _ = try columns.append(self.allocator, projection.alias orelse "?column?");
        return .{ .allocator = self.allocator, .columns = try self.allocator.dupe([]const u8, columns.items), .rows = rows };
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
                try self.appendJoinRow(&rows, value.projections, left, left_row.values, right, right_row.values);
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
        return .{ .allocator = self.allocator, .columns = try self.allocator.dupe([]const u8, columns.items), .rows = try rows.toOwnedSlice(self.allocator) };
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

    fn update(self: *Connection, value: anytype, parameters: []const Value) !Result {
        const table = self.schema.find(value.table) orelse return error.UnknownTable;
        var changes: usize = 0;
        for (table.rows.items, 0..) |*row, row_index| if (try self.matches(table, row.values, value.condition, parameters)) {
            const candidate = try self.allocator.alloc(Value, row.values.len);
            defer self.allocator.free(candidate);
            @memcpy(candidate, row.values);
            for (value.columns, value.values) |name, expr| {
                const index = try columnIndex(table, name);
                const new_value = try self.resolve(expr, parameters);
                if (new_value == .null and table.columns[index].not_null) return error.ConstraintViolation;
                candidate[index] = new_value;
            }
            try self.schema.validateUpdate(table, row_index, candidate);
            for (value.columns, value.values) |name, expr| {
                const index = try columnIndex(table, name);
                const new_value = try self.resolve(expr, parameters);
                if (row.values[index] == .text) self.allocator.free(row.values[index].text);
                if (row.values[index] == .blob) self.allocator.free(row.values[index].blob);
                row.values[index] = switch (new_value) {
                    .text => |v| .{ .text = try self.allocator.dupe(u8, v) },
                    .blob => |v| .{ .blob = try self.allocator.dupe(u8, v) },
                    else => new_value,
                };
            }
            changes += 1;
        };
        return .{ .allocator = self.allocator, .columns = try self.allocator.alloc([]const u8, 0), .rows = try self.allocator.alloc([]Value, 0), .changes = changes };
    }

    fn delete(self: *Connection, value: anytype, parameters: []const Value) !Result {
        const table = self.schema.find(value.table) orelse return error.UnknownTable;
        var changes: usize = 0;
        var index: usize = 0;
        while (index < table.rows.items.len) {
            if (try self.matches(table, table.rows.items[index].values, value.condition, parameters)) {
                const row = table.rows.orderedRemove(index);
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
    try db.createTable(Parent, .{ .primary_key_key = Parent.key("id"), .unique_keys = &.{Parent.key("email")} });
    try db.createTable(Child, .{ .primary_key_key = Child.key("id"), .foreign_keys = &.{.{ .table = "key_dsl_parent", .referenced_column = "id", .column_key = Child.key("parent_id") }} });
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
    try db.createTable(User, .{ .primary_key = "id" });
    try db.createTable(Order, .{ .primary_key = "id" });
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
    var null_result = try db.from(Item).where(Item.column("label").isNull()).fetchAll();
    defer null_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), null_result.rowCount());
    var distinct_result = try db.from(Item).selectFieldNames(&.{"label"}).distinct().fetchAll();
    defer distinct_result.deinit();
    try std.testing.expectEqual(@as(usize, 3), distinct_result.rowCount());
}
