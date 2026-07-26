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
pub const Result = @import("result.zig").Result;

pub const Connection = struct {
    allocator: std.mem.Allocator,
    file: DatabaseFile,
    schema: Schema,
    backup: ?Schema = null,
    transaction_active: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Connection {
        const connection = try allocator.create(Connection);
        errdefer allocator.destroy(connection);
        connection.* = .{ .allocator = allocator, .file = try DatabaseFile.open(allocator, path), .schema = Schema.init(allocator) };
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

    pub fn from(self: *Connection, comptime TableType: type) @import("../dsl/query_builder.zig").Query {
        return @import("../dsl/query_builder.zig").Query.init(self, TableType.table_name, executeForDsl);
    }

    fn executeForDsl(pointer: *anyopaque, sql: []const u8) anyerror!Result {
        const self: *Connection = @ptrCast(@alignCast(pointer));
        return self.execute(sql, &.{});
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
        self.transaction_active = false;
    }
    pub fn rollback(self: *Connection) !void {
        if (!self.transaction_active) return error.NotInTransaction;
        self.schema.deinit();
        self.schema = self.backup.?;
        self.backup = null;
        self.transaction_active = false;
    }

    fn execute(self: *Connection, sql: []const u8, parameters: []const Value) !Result {
        var parser = try Parser.init(self.allocator, sql);
        defer parser.deinit();
        var statement = try parser.parse();
        defer ast.deinit(self.allocator, &statement);
        const result = switch (statement) {
            .create_table => |value| try self.createTable(value),
            .drop_table => |value| try self.dropTable(value),
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
        };
        if (!self.transaction_active and !statement.isQuery()) try self.persist();
        return result;
    }

    fn emptyResult(allocator: std.mem.Allocator) !Result {
        return .{ .allocator = allocator, .columns = try allocator.alloc([]const u8, 0), .rows = try allocator.alloc([]Value, 0) };
    }
    fn createTable(self: *Connection, value: anytype) !Result {
        if (self.schema.find(value.name) != null and value.if_not_exists) return try emptyResult(self.allocator);
        try self.schema.createTable(value.name, value.columns);
        return try emptyResult(self.allocator);
    }
    fn dropTable(self: *Connection, name: []const u8) !Result {
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
        };
    }

    fn matches(self: *Connection, table: *const Table, row: []const Value, condition: ?ast.Condition, parameters: []const Value) !bool {
        if (condition) |item| return compare(row[try columnIndex(table, item.column)], item.op, try self.resolve(item.value, parameters));
        return true;
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
            for (value.projections) |projection| if (projection.expr == .wildcard) for (table.columns) |column| try columns.append(self.allocator, column.name) else if (projection.expr == .identifier) try columns.append(self.allocator, projection.alias orelse projection.expr.identifier);
            if (columns.items.len == 0) for (value.projections) |projection| try columns.append(self.allocator, projection.alias orelse "?column?");
            var rows = std.ArrayList([]Value).empty;
            errdefer {
                for (rows.items) |row| self.allocator.free(row);
                rows.deinit(self.allocator);
            }
            var count: usize = 0;
            for (table.rows.items) |row| {
                if (!try self.matches(table, row.values, value.condition, parameters)) continue;
                const result_row = try self.allocator.alloc(Value, value.projections.len + if (value.projections.len == 1 and value.projections[0].expr == .wildcard) table.columns.len - 1 else 0);
                var out_index: usize = 0;
                for (value.projections) |projection| if (projection.expr == .wildcard) {
                    for (row.values) |item| {
                        result_row[out_index] = item;
                        out_index += 1;
                    }
                } else {
                    result_row[out_index] = switch (projection.expr) {
                        .identifier => |name| row.values[try columnIndex(table, name)],
                        else => try self.resolve(projection.expr, parameters),
                    };
                    out_index += 1;
                };
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

    fn update(self: *Connection, value: anytype, parameters: []const Value) !Result {
        const table = self.schema.find(value.table) orelse return error.UnknownTable;
        var changes: usize = 0;
        for (table.rows.items) |*row| if (try self.matches(table, row.values, value.condition, parameters)) {
            for (value.columns, value.values) |name, expr| {
                const index = try columnIndex(table, name);
                const new_value = try self.resolve(expr, parameters);
                if (new_value == .null and table.columns[index].not_null) return error.ConstraintViolation;
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
