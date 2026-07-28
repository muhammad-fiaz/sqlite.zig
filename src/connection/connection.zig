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
        };
    }

    fn matches(self: *Connection, table: *const Table, row: []const Value, condition: ?ast.Conditions, parameters: []const Value) !bool {
        if (condition) |items| for (items) |item| if (!compare(row[try columnIndex(table, item.column)], item.op, try self.resolve(item.value, parameters))) return false;
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
