const std = @import("std");
const Header = @import("../format/header.zig").Header;
const header_size = @import("../format/header.zig").size;
const varint = @import("../format/varint.zig");
const record = @import("../format/record.zig");
const Schema = @import("../catalog/schema.zig").Schema;
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");
const Parser = @import("../sql/parser.zig").Parser;

const Cell = struct { rowid: u64, values: []Value };

pub const page_size: usize = 4096;

fn putU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}
fn getU16(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn columnIndex(table: anytype, name: []const u8) ?usize {
    for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
    return null;
}

fn appendSqlLiteral(allocator: std.mem.Allocator, sql: *std.ArrayList(u8), value: Value) !void {
    switch (value) {
        .null => try sql.appendSlice(allocator, "NULL"),
        .integer => |number| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{number});
            defer allocator.free(rendered);
            try sql.appendSlice(allocator, rendered);
        },
        .real => |number| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{number});
            defer allocator.free(rendered);
            try sql.appendSlice(allocator, rendered);
        },
        .text, .blob => |bytes| {
            try sql.append(allocator, '\'');
            for (bytes) |byte| {
                if (byte == '\'') try sql.append(allocator, '\'');
                try sql.append(allocator, byte);
            }
            try sql.append(allocator, '\'');
        },
    }
}

fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buffer: [9]u8 = undefined;
    const length = try varint.encode(value, &buffer);
    try list.appendSlice(allocator, buffer[0..length]);
}

fn cell(allocator: std.mem.Allocator, rowid: u64, values: []const Value) ![]u8 {
    const payload = try record.encode(allocator, values);
    defer allocator.free(payload);
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try appendVarint(&result, allocator, payload.len);
    try appendVarint(&result, allocator, rowid);
    try result.appendSlice(allocator, payload);
    return result.toOwnedSlice(allocator);
}

fn indexCell(allocator: std.mem.Allocator, values: []const Value) ![]u8 {
    const payload = try record.encode(allocator, values);
    defer allocator.free(payload);
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try appendVarint(&result, allocator, payload.len);
    try result.appendSlice(allocator, payload);
    return result.toOwnedSlice(allocator);
}

fn addLeafPage(page: []u8, page_start: usize, header_offset: usize, page_type: u8, cells: []const []const u8, database_page_size: usize) !void {
    const header = page_start + header_offset;
    if (cells.len > 0xffff) return error.PageOverflow;
    var content = page_start + database_page_size;
    for (cells) |item| {
        if (item.len > content - (header + 8 + cells.len * 2)) return error.PageOverflow;
        content -= item.len;
        @memcpy(page[content .. content + item.len], item);
    }
    page[header] = page_type;
    putU16(page, header + 1, 0);
    putU16(page, header + 3, @intCast(cells.len));
    putU16(page, header + 5, @intCast(content - page_start));
    page[header + 7] = 0;
    content = page_start + database_page_size;
    for (cells, 0..) |item, index| {
        content -= item.len;
        putU16(page, header + 8 + index * 2, @intCast(content - page_start));
    }
}

fn createSql(allocator: std.mem.Allocator, table: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    if (table.virtual_module) |module| {
        try sql.appendSlice(allocator, "CREATE VIRTUAL TABLE ");
        try sql.appendSlice(allocator, table.name);
        try sql.appendSlice(allocator, " USING ");
        try sql.appendSlice(allocator, module);
        try sql.append(allocator, '(');
        for (table.virtual_arguments, 0..) |argument, index| {
            if (index != 0) try sql.appendSlice(allocator, ", ");
            try sql.appendSlice(allocator, argument);
        }
        try sql.appendSlice(allocator, ");");
        return sql.toOwnedSlice(allocator);
    }
    try sql.appendSlice(allocator, "CREATE TABLE ");
    try sql.appendSlice(allocator, table.name);
    try sql.appendSlice(allocator, " (");
    for (table.columns, 0..) |column, index| {
        if (index != 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, column.name);
        if (column.type_name.len != 0) {
            try sql.append(allocator, ' ');
            try sql.appendSlice(allocator, column.type_name);
        }
        if (column.primary_key) try sql.appendSlice(allocator, " PRIMARY KEY");
        if (column.not_null) try sql.appendSlice(allocator, " NOT NULL");
        if (column.unique) try sql.appendSlice(allocator, " UNIQUE");
        if (column.default_value) |default| {
            try sql.appendSlice(allocator, " DEFAULT ");
            try appendSqlLiteral(allocator, &sql, default);
        }
        if (column.foreign_table) |foreign_table| {
            try sql.appendSlice(allocator, " REFERENCES ");
            try sql.appendSlice(allocator, foreign_table);
            try sql.append(allocator, '(');
            try sql.appendSlice(allocator, column.foreign_column.?);
            try sql.append(allocator, ')');
            switch (column.on_delete) {
                .restrict => {},
                .cascade => try sql.appendSlice(allocator, " ON DELETE CASCADE"),
                .set_null => try sql.appendSlice(allocator, " ON DELETE SET NULL"),
            }
            switch (column.on_update) {
                .restrict => {},
                .cascade => try sql.appendSlice(allocator, " ON UPDATE CASCADE"),
                .set_null => try sql.appendSlice(allocator, " ON UPDATE SET NULL"),
            }
        }
    }
    for (table.constraints) |constraint| {
        try sql.appendSlice(allocator, ", ");
        if (constraint.kind == .foreign_key) {
            try sql.appendSlice(allocator, "FOREIGN KEY (");
        } else try sql.appendSlice(allocator, switch (constraint.kind) {
            .primary_key => "PRIMARY KEY (",
            .unique => "UNIQUE (",
            .foreign_key => unreachable,
        });
        for (constraint.columns, 0..) |column, position| {
            if (position != 0) try sql.appendSlice(allocator, ", ");
            try sql.appendSlice(allocator, column);
        }
        try sql.append(allocator, ')');
        if (constraint.kind == .foreign_key) {
            try sql.appendSlice(allocator, " REFERENCES ");
            try sql.appendSlice(allocator, constraint.foreign_table.?);
            try sql.appendSlice(allocator, " (");
            for (constraint.referenced_columns, 0..) |column, position| {
                if (position != 0) try sql.appendSlice(allocator, ", ");
                try sql.appendSlice(allocator, column);
            }
            try sql.append(allocator, ')');
            switch (constraint.on_delete) {
                .restrict => {},
                .cascade => try sql.appendSlice(allocator, " ON DELETE CASCADE"),
                .set_null => try sql.appendSlice(allocator, " ON DELETE SET NULL"),
            }
            switch (constraint.on_update) {
                .restrict => {},
                .cascade => try sql.appendSlice(allocator, " ON UPDATE CASCADE"),
                .set_null => try sql.appendSlice(allocator, " ON UPDATE SET NULL"),
            }
        }
    }
    try sql.appendSlice(allocator, ");");
    return sql.toOwnedSlice(allocator);
}

fn createIndexSql(allocator: std.mem.Allocator, index: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    try sql.appendSlice(allocator, if (index.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
    try sql.appendSlice(allocator, index.name);
    try sql.appendSlice(allocator, " ON ");
    try sql.appendSlice(allocator, index.table);
    try sql.appendSlice(allocator, " (");
    for (index.columns, 0..) |column, position| {
        if (position != 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, column);
    }
    try sql.appendSlice(allocator, ");");
    return sql.toOwnedSlice(allocator);
}

fn createViewSql(allocator: std.mem.Allocator, view: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    try sql.appendSlice(allocator, "CREATE VIEW ");
    try sql.appendSlice(allocator, view.name);
    try sql.appendSlice(allocator, " AS ");
    try sql.appendSlice(allocator, view.sql);
    return sql.toOwnedSlice(allocator);
}

fn createTriggerSql(allocator: std.mem.Allocator, trigger: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    try sql.appendSlice(allocator, "CREATE TRIGGER ");
    try sql.appendSlice(allocator, trigger.name);
    try sql.appendSlice(allocator, " AFTER ");
    try sql.appendSlice(allocator, switch (trigger.event) {
        .insert => "INSERT",
        .update => "UPDATE",
        .delete => "DELETE",
    });
    try sql.appendSlice(allocator, " ON ");
    try sql.appendSlice(allocator, trigger.table);
    try sql.appendSlice(allocator, " BEGIN ");
    try sql.appendSlice(allocator, trigger.body);
    try sql.appendSlice(allocator, " END;");
    return sql.toOwnedSlice(allocator);
}

pub fn encodeWithPageSize(allocator: std.mem.Allocator, schema: *const Schema, database_page_size: usize) ![]u8 {
    if (database_page_size < 512 or database_page_size > 65536 or (database_page_size & (database_page_size - 1)) != 0) return error.InvalidPageSize;
    const page_count = 1 + schema.tables.items.len + schema.indexes.items.len;
    const bytes = try allocator.alloc(u8, page_count * database_page_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    var header = Header{ .page_size = @intCast(database_page_size), .database_size_pages = @intCast(page_count), .change_counter = 1, .schema_cookie = 1 };
    header.encode(@ptrCast(bytes[0..header_size].ptr));

    var schema_cells = try allocator.alloc([]const u8, schema.tables.items.len + schema.indexes.items.len + schema.views.items.len + schema.triggers.items.len);
    defer allocator.free(schema_cells);
    var schema_owned = std.ArrayList([]u8).empty;
    defer {
        for (schema_owned.items) |item| allocator.free(item);
        schema_owned.deinit(allocator);
    }

    for (schema.tables.items, 0..) |table, index| {
        const sql = try createSql(allocator, table);
        defer allocator.free(sql);
        const values = [_]Value{
            .{ .text = "table" },
            .{ .text = table.name },
            .{ .text = table.name },
            .{ .integer = if (table.virtual_module != null) 0 else @intCast(index + 2) },
            .{ .text = sql },
        };
        const item = try cell(allocator, index + 1, &values);
        try schema_owned.append(allocator, item);
        schema_cells[index] = item;
    }
    for (schema.indexes.items, 0..) |index, position| {
        const sql = if (std.mem.startsWith(u8, index.name, "sqlite_autoindex_")) null else try createIndexSql(allocator, index);
        defer if (sql) |owned_sql| allocator.free(owned_sql);
        const values = [_]Value{
            .{ .text = "index" },
            .{ .text = index.name },
            .{ .text = index.table },
            .{ .integer = @intCast(schema.tables.items.len + position + 2) },
            if (sql) |owned_sql| .{ .text = owned_sql } else .null,
        };
        const item = try cell(allocator, schema.tables.items.len + position + 1, &values);
        try schema_owned.append(allocator, item);
        schema_cells[schema.tables.items.len + position] = item;
    }
    for (schema.views.items, 0..) |view, position| {
        const sql = try createViewSql(allocator, view);
        defer allocator.free(sql);
        const values = [_]Value{
            .{ .text = "view" },
            .{ .text = view.name },
            .{ .text = view.name },
            .{ .integer = 0 },
            .{ .text = sql },
        };
        const item = try cell(allocator, schema.tables.items.len + schema.indexes.items.len + position + 1, &values);
        try schema_owned.append(allocator, item);
        schema_cells[schema.tables.items.len + schema.indexes.items.len + position] = item;
    }
    for (schema.triggers.items, 0..) |trigger, position| {
        const sql = try createTriggerSql(allocator, trigger);
        defer allocator.free(sql);
        const values = [_]Value{
            .{ .text = "trigger" },
            .{ .text = trigger.name },
            .{ .text = trigger.table },
            .{ .integer = 0 },
            .{ .text = sql },
        };
        const item = try cell(allocator, schema.tables.items.len + schema.indexes.items.len + schema.views.items.len + position + 1, &values);
        try schema_owned.append(allocator, item);
        schema_cells[schema.tables.items.len + schema.indexes.items.len + schema.views.items.len + position] = item;
    }
    addLeafPage(bytes, 0, header_size, 0x0d, schema_cells, database_page_size) catch |err| {
        if (err == error.PageOverflow) return error.DatabaseTooLarge;
        return err;
    };

    for (schema.tables.items, 0..) |table, index| {
        if (table.virtual_module != null) continue;
        var table_cells = try allocator.alloc([]const u8, table.rows.items.len);
        defer allocator.free(table_cells);
        var owned = std.ArrayList([]u8).empty;
        defer {
            for (owned.items) |item| allocator.free(item);
            owned.deinit(allocator);
        }
        for (table.rows.items, 0..) |row, row_index| {
            const item = try cell(allocator, row_index + 1, row.values);
            try owned.append(allocator, item);
            table_cells[row_index] = item;
        }
        addLeafPage(bytes, (index + 1) * database_page_size, 0, 0x0d, table_cells, database_page_size) catch |err| {
            if (err == error.PageOverflow) return error.DatabaseTooLarge;
            return err;
        };
    }
    for (schema.indexes.items, 0..) |index, index_position| {
        const table = schema.findConst(index.table) orelse return error.UnknownTable;
        var index_cells = try allocator.alloc([]const u8, table.rows.items.len);
        defer allocator.free(index_cells);
        var owned = std.ArrayList([]u8).empty;
        defer {
            for (owned.items) |item| allocator.free(item);
            owned.deinit(allocator);
        }
        for (table.rows.items, 0..) |row, row_position| {
            var values = try allocator.alloc(Value, index.columns.len + 1);
            defer allocator.free(values);
            for (index.columns, 0..) |column, position| values[position] = row.values[columnIndex(table, column) orelse return error.UnknownColumn];
            values[index.columns.len] = .{ .integer = @intCast(row_position + 1) };
            const item = try indexCell(allocator, values);
            try owned.append(allocator, item);
            index_cells[row_position] = item;
        }
        addLeafPage(bytes, (schema.tables.items.len + index_position + 1) * database_page_size, 0, 0x0a, index_cells, database_page_size) catch |err| {
            if (err == error.PageOverflow) return error.DatabaseTooLarge;
            return err;
        };
    }
    return bytes;
}

pub fn encode(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    return encodeWithPageSize(allocator, schema, page_size);
}

const SchemaEntry = struct { root_page: u32, sql: []const u8 };

fn readCell(allocator: std.mem.Allocator, bytes: []const u8, offset: *usize) !Cell {
    const payload_length = try varint.decode(bytes[offset.*..]);
    offset.* += payload_length.length;
    const rowid = try varint.decode(bytes[offset.*..]);
    offset.* += rowid.length;
    const payload_end = offset.* + @as(usize, @intCast(payload_length.value));
    if (payload_end > bytes.len) return error.InvalidHeader;
    const values = try record.decode(allocator, bytes[offset.*..payload_end]);
    offset.* = payload_end;
    return .{ .rowid = rowid.value, .values = values };
}

fn leafCells(allocator: std.mem.Allocator, bytes: []const u8, page_number: u32) ![]Cell {
    const offset: usize = if (page_number == 1) header_size else 0;
    if (bytes[offset] != 0x0d) return error.InvalidHeader;
    const count = getU16(bytes, offset + 3);
    const result = try allocator.alloc(Cell, count);
    errdefer allocator.free(result);
    for (result, 0..) |*item, index| {
        const cell_offset = getU16(bytes, offset + 8 + index * 2);
        var cursor: usize = cell_offset;
        item.* = try readCell(allocator, bytes, &cursor);
    }
    return result;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Schema {
    if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..16], "SQLite format 3\x00")) return error.InvalidHeader;
    const encoded_page_size = std.mem.readInt(u16, bytes[16..18], .big);
    const database_page_size: usize = if (encoded_page_size == 1) 65536 else encoded_page_size;
    if (database_page_size < 512 or database_page_size > 65536 or (database_page_size & (database_page_size - 1)) != 0 or bytes.len < database_page_size) return error.InvalidPageSize;
    const database_pages = std.mem.readInt(u32, bytes[28..32], .big);
    if (database_pages == 0 or @as(u64, database_pages) * database_page_size > bytes.len) return error.InvalidHeader;
    var schema = Schema.init(allocator);
    errdefer schema.deinit();
    const schema_rows = try leafCells(allocator, bytes[0..database_page_size], 1);
    defer allocator.free(schema_rows);
    var entries = std.ArrayList(SchemaEntry).empty;
    defer entries.deinit(allocator);
    for (schema_rows) |row| {
        defer allocator.free(row.values);
        if (row.values.len < 5 or row.values[0] != .text) continue;
        if (row.values[3] != .integer or row.values[4] != .text) continue;
        try entries.append(allocator, .{ .root_page = @intCast(row.values[3].integer), .sql = row.values[4].text });
    }
    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .create_virtual_table) {
            try schema.createVirtualTable(statement.create_virtual_table.name, statement.create_virtual_table.module, statement.create_virtual_table.arguments);
            continue;
        }
        if (statement != .create_table) continue;
        try schema.createTable(statement.create_table.name, statement.create_table.columns, statement.create_table.constraints);
        const table = schema.find(statement.create_table.name).?;
        const start = (@as(usize, entry.root_page) - 1) * database_page_size;
        if (start + database_page_size > bytes.len) return error.InvalidHeader;
        const rows = try leafCells(allocator, bytes[start .. start + database_page_size], entry.root_page);
        defer allocator.free(rows);
        for (rows) |row| {
            defer allocator.free(row.values);
            try schema.appendRow(table, row.values);
        }
    }
    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .create_index and schema.findIndexConst(statement.create_index.name) == null) try schema.createIndex(statement.create_index);
    }
    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .create_view) try schema.createView(statement.create_view.name, statement.create_view.sql);
    }
    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .create_trigger) try schema.createTrigger(statement.create_trigger);
    }
    return schema;
}

test "SQLite image writes a Python-compatible page-one b-tree" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const definitions = [_]ast.ColumnDef{ .{ .name = "id", .type_name = "INTEGER" }, .{ .name = "name", .type_name = "TEXT" } };
    try schema.createTable("users", &definitions, &.{});
    var values = [_]Value{ .{ .integer = 1 }, .{ .text = "Fiaz" } };
    try schema.appendRow(schema.find("users").?, &values);
    const bytes = try encode(std.testing.allocator, &schema);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(u8, 0x0d), bytes[100]);
    try std.testing.expectEqualStrings("SQLite format 3\x00", bytes[0..16]);
}

test "SQLite image round trips with an 8192-byte page size" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const definitions = [_]ast.ColumnDef{.{ .name = "id", .type_name = "INTEGER" }};
    try schema.createTable("wide_pages", &definitions, &.{});
    var values = [_]Value{.{ .integer = 7 }};
    try schema.appendRow(schema.find("wide_pages").?, &values);
    const bytes = try encodeWithPageSize(std.testing.allocator, &schema, 8192);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 8192 * 2), bytes.len);
    try std.testing.expectEqual(@as(u16, 8192), std.mem.readInt(u16, bytes[16..18], .big));
    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.findConst("wide_pages").?.rows.items.len);
    try std.testing.expectEqual(@as(i64, 7), decoded.findConst("wide_pages").?.rows.items[0].values[0].integer);
}
