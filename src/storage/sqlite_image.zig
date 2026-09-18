const std = @import("std");
const Header = @import("../format/header.zig").Header;
const headerSize = @import("../format/header.zig").size;
const varint = @import("../format/varint.zig");
const record = @import("../format/record.zig");
const Schema = @import("../catalog/schema.zig").Schema;
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");
const Parser = @import("../sql/parser.zig").Parser;

const Cell = struct { rowid: u64, values: []Value };

pub const pageSize: usize = 4096;

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

fn addLeafPage(page: []u8, pageStart: usize, headerOffset: usize, pageType: u8, cells: []const []const u8, databasePageSize: usize) !void {
    const header = pageStart + headerOffset;
    if (cells.len > 0xffff) return error.PageOverflow;
    var content = pageStart + databasePageSize;
    for (cells) |item| {
        if (item.len > content - (header + 8 + cells.len * 2)) return error.PageOverflow;
        content -= item.len;
        @memcpy(page[content .. content + item.len], item);
    }
    page[header] = pageType;
    putU16(page, header + 1, 0);
    putU16(page, header + 3, @intCast(cells.len));
    putU16(page, header + 5, @intCast(content - pageStart));
    page[header + 7] = 0;
    content = pageStart + databasePageSize;
    for (cells, 0..) |item, index| {
        content -= item.len;
        putU16(page, header + 8 + index * 2, @intCast(content - pageStart));
    }
}

fn createSql(allocator: std.mem.Allocator, table: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    if (table.virtualModule) |module| {
        try sql.appendSlice(allocator, "CREATE VIRTUAL TABLE ");
        try sql.appendSlice(allocator, table.name);
        try sql.appendSlice(allocator, " USING ");
        try sql.appendSlice(allocator, module);
        try sql.append(allocator, '(');
        for (table.virtualArguments, 0..) |argument, index| {
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
        if (column.typeName.len != 0) {
            try sql.append(allocator, ' ');
            try sql.appendSlice(allocator, column.typeName);
        }
        if (column.primaryKey) try sql.appendSlice(allocator, " PRIMARY KEY");
        if (column.notNull) try sql.appendSlice(allocator, " NOT NULL");
        if (column.unique) try sql.appendSlice(allocator, " UNIQUE");
        if (column.defaultValue) |default| {
            try sql.appendSlice(allocator, " DEFAULT ");
            try appendSqlLiteral(allocator, &sql, default);
        }
        if (column.foreignTable) |foreignTable| {
            try sql.appendSlice(allocator, " REFERENCES ");
            try sql.appendSlice(allocator, foreignTable);
            try sql.append(allocator, '(');
            try sql.appendSlice(allocator, column.foreignColumn.?);
            try sql.append(allocator, ')');
            switch (column.onDelete) {
                .restrict => {},
                .cascade => try sql.appendSlice(allocator, " ON DELETE CASCADE"),
                .setNull => try sql.appendSlice(allocator, " ON DELETE SET NULL"),
            }
            switch (column.onUpdate) {
                .restrict => {},
                .cascade => try sql.appendSlice(allocator, " ON UPDATE CASCADE"),
                .setNull => try sql.appendSlice(allocator, " ON UPDATE SET NULL"),
            }
        }
    }
    for (table.constraints) |constraint| {
        try sql.appendSlice(allocator, ", ");
        if (constraint.kind == .foreignKey) {
            try sql.appendSlice(allocator, "FOREIGN KEY (");
        } else try sql.appendSlice(allocator, switch (constraint.kind) {
            .primaryKey => "PRIMARY KEY (",
            .unique => "UNIQUE (",
            .foreignKey => unreachable,
        });
        for (constraint.columns, 0..) |column, position| {
            if (position != 0) try sql.appendSlice(allocator, ", ");
            try sql.appendSlice(allocator, column);
        }
        try sql.append(allocator, ')');
        if (constraint.kind == .foreignKey) {
            try sql.appendSlice(allocator, " REFERENCES ");
            try sql.appendSlice(allocator, constraint.foreignTable.?);
            try sql.appendSlice(allocator, " (");
            for (constraint.referencedColumns, 0..) |column, position| {
                if (position != 0) try sql.appendSlice(allocator, ", ");
                try sql.appendSlice(allocator, column);
            }
            try sql.append(allocator, ')');
            switch (constraint.onDelete) {
                .restrict => {},
                .cascade => try sql.appendSlice(allocator, " ON DELETE CASCADE"),
                .setNull => try sql.appendSlice(allocator, " ON DELETE SET NULL"),
            }
            switch (constraint.onUpdate) {
                .restrict => {},
                .cascade => try sql.appendSlice(allocator, " ON UPDATE CASCADE"),
                .setNull => try sql.appendSlice(allocator, " ON UPDATE SET NULL"),
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

pub fn encodeWithPageSize(allocator: std.mem.Allocator, schema: *const Schema, databasePageSize: usize) ![]u8 {
    if (databasePageSize < 512 or databasePageSize > 65536 or (databasePageSize & (databasePageSize - 1)) != 0) return error.InvalidPageSize;
    const pageCount = 1 + schema.tables.items.len + schema.indexes.items.len;
    const bytes = try allocator.alloc(u8, pageCount * databasePageSize);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    var header = Header{ .pageSize = @intCast(databasePageSize), .databaseSizePages = @intCast(pageCount), .changeCounter = 1, .schemaCookie = 1 };
    header.encode(@ptrCast(bytes[0..headerSize].ptr));

    var schemaCells = try allocator.alloc([]const u8, schema.tables.items.len + schema.indexes.items.len + schema.views.items.len + schema.triggers.items.len);
    defer allocator.free(schemaCells);
    var schemaOwned = std.ArrayList([]u8).empty;
    defer {
        for (schemaOwned.items) |item| allocator.free(item);
        schemaOwned.deinit(allocator);
    }

    for (schema.tables.items, 0..) |table, index| {
        const sql = try createSql(allocator, table);
        defer allocator.free(sql);
        const values = [_]Value{
            .{ .text = "table" },
            .{ .text = table.name },
            .{ .text = table.name },
            .{ .integer = if (table.virtualModule != null) 0 else @intCast(index + 2) },
            .{ .text = sql },
        };
        const item = try cell(allocator, index + 1, &values);
        try schemaOwned.append(allocator, item);
        schemaCells[index] = item;
    }
    for (schema.indexes.items, 0..) |index, position| {
        const sql = if (std.mem.startsWith(u8, index.name, "sqlite_autoindex_")) null else try createIndexSql(allocator, index);
        defer if (sql) |ownedSql| allocator.free(ownedSql);
        const values = [_]Value{
            .{ .text = "index" },
            .{ .text = index.name },
            .{ .text = index.table },
            .{ .integer = @intCast(schema.tables.items.len + position + 2) },
            if (sql) |ownedSql| .{ .text = ownedSql } else .null,
        };
        const item = try cell(allocator, schema.tables.items.len + position + 1, &values);
        try schemaOwned.append(allocator, item);
        schemaCells[schema.tables.items.len + position] = item;
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
        try schemaOwned.append(allocator, item);
        schemaCells[schema.tables.items.len + schema.indexes.items.len + position] = item;
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
        try schemaOwned.append(allocator, item);
        schemaCells[schema.tables.items.len + schema.indexes.items.len + schema.views.items.len + position] = item;
    }
    addLeafPage(bytes, 0, headerSize, 0x0d, schemaCells, databasePageSize) catch |err| {
        if (err == error.PageOverflow) return error.DatabaseTooLarge;
        return err;
    };

    for (schema.tables.items, 0..) |table, index| {
        if (table.virtualModule != null) continue;
        var tableCells = try allocator.alloc([]const u8, table.rows.items.len);
        defer allocator.free(tableCells);
        var owned = std.ArrayList([]u8).empty;
        defer {
            for (owned.items) |item| allocator.free(item);
            owned.deinit(allocator);
        }
        for (table.rows.items, 0..) |row, rowIndex| {
            const item = try cell(allocator, rowIndex + 1, row.values);
            try owned.append(allocator, item);
            tableCells[rowIndex] = item;
        }
        addLeafPage(bytes, (index + 1) * databasePageSize, 0, 0x0d, tableCells, databasePageSize) catch |err| {
            if (err == error.PageOverflow) return error.DatabaseTooLarge;
            return err;
        };
    }
    for (schema.indexes.items, 0..) |index, indexPosition| {
        const table = schema.findConst(index.table) orelse return error.UnknownTable;
        var indexCells = try allocator.alloc([]const u8, table.rows.items.len);
        defer allocator.free(indexCells);
        var owned = std.ArrayList([]u8).empty;
        defer {
            for (owned.items) |item| allocator.free(item);
            owned.deinit(allocator);
        }
        for (table.rows.items, 0..) |row, rowPosition| {
            var values = try allocator.alloc(Value, index.columns.len + 1);
            defer allocator.free(values);
            for (index.columns, 0..) |column, position| values[position] = row.values[columnIndex(table, column) orelse return error.UnknownColumn];
            values[index.columns.len] = .{ .integer = @intCast(rowPosition + 1) };
            const item = try indexCell(allocator, values);
            try owned.append(allocator, item);
            indexCells[rowPosition] = item;
        }
        addLeafPage(bytes, (schema.tables.items.len + indexPosition + 1) * databasePageSize, 0, 0x0a, indexCells, databasePageSize) catch |err| {
            if (err == error.PageOverflow) return error.DatabaseTooLarge;
            return err;
        };
    }
    return bytes;
}

pub fn encode(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    return encodeWithPageSize(allocator, schema, pageSize);
}

const SchemaEntry = struct { rootPage: u32, sql: []const u8 };

fn readCell(allocator: std.mem.Allocator, bytes: []const u8, offset: *usize) !Cell {
    const payloadLength = try varint.decode(bytes[offset.*..]);
    offset.* += payloadLength.length;
    const rowid = try varint.decode(bytes[offset.*..]);
    offset.* += rowid.length;
    const payloadEnd = offset.* + @as(usize, @intCast(payloadLength.value));
    if (payloadEnd > bytes.len) return error.InvalidHeader;
    const values = try record.decode(allocator, bytes[offset.*..payloadEnd]);
    offset.* = payloadEnd;
    return .{ .rowid = rowid.value, .values = values };
}

fn leafCells(allocator: std.mem.Allocator, bytes: []const u8, pageNumber: u32) ![]Cell {
    const offset: usize = if (pageNumber == 1) headerSize else 0;
    if (bytes[offset] != 0x0d) return error.InvalidHeader;
    const count = getU16(bytes, offset + 3);
    const result = try allocator.alloc(Cell, count);
    errdefer allocator.free(result);
    for (result, 0..) |*item, index| {
        const cellOffset = getU16(bytes, offset + 8 + index * 2);
        var cursor: usize = cellOffset;
        item.* = try readCell(allocator, bytes, &cursor);
    }
    return result;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Schema {
    if (bytes.len < headerSize or !std.mem.eql(u8, bytes[0..16], "SQLite format 3\x00")) return error.InvalidHeader;
    const encodedPageSize = std.mem.readInt(u16, bytes[16..18], .big);
    const databasePageSize: usize = if (encodedPageSize == 1) 65536 else encodedPageSize;
    if (databasePageSize < 512 or databasePageSize > 65536 or (databasePageSize & (databasePageSize - 1)) != 0 or bytes.len < databasePageSize) return error.InvalidPageSize;
    const databasePages = std.mem.readInt(u32, bytes[28..32], .big);
    if (databasePages == 0 or @as(u64, databasePages) * databasePageSize > bytes.len) return error.InvalidHeader;
    var schema = Schema.init(allocator);
    errdefer schema.deinit();
    const schemaRows = try leafCells(allocator, bytes[0..databasePageSize], 1);
    defer allocator.free(schemaRows);
    var entries = std.ArrayList(SchemaEntry).empty;
    defer entries.deinit(allocator);
    for (schemaRows) |row| {
        defer allocator.free(row.values);
        if (row.values.len < 5 or row.values[0] != .text) continue;
        if (row.values[3] != .integer or row.values[4] != .text) continue;
        try entries.append(allocator, .{ .rootPage = @intCast(row.values[3].integer), .sql = row.values[4].text });
    }
    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .createVirtualTable) {
            try schema.createVirtualTable(statement.createVirtualTable.name, statement.createVirtualTable.module, statement.createVirtualTable.arguments);
            continue;
        }
        if (statement != .createTable) continue;
        try schema.createTable(statement.createTable.name, statement.createTable.columns, statement.createTable.constraints);
        const table = schema.find(statement.createTable.name).?;
        const start = (@as(usize, entry.rootPage) - 1) * databasePageSize;
        if (start + databasePageSize > bytes.len) return error.InvalidHeader;
        const rows = try leafCells(allocator, bytes[start .. start + databasePageSize], entry.rootPage);
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
        if (statement == .createIndex and schema.findIndexConst(statement.createIndex.name) == null) try schema.createIndex(statement.createIndex);
    }
    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .createView) try schema.createView(statement.createView.name, statement.createView.sql);
    }
    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .createTrigger) try schema.createTrigger(statement.createTrigger);
    }
    return schema;
}

test "SQLite image writes a Python-compatible page-one b-tree" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const definitions = [_]ast.ColumnDef{ .{ .name = "id", .typeName = "INTEGER" }, .{ .name = "name", .typeName = "TEXT" } };
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
    const definitions = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER" }};
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
