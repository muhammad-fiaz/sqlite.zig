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

fn putU16(bytes: []u8, offset: usize, value: u16) void { bytes[offset] = @truncate(value >> 8); bytes[offset + 1] = @truncate(value); }
fn getU16(bytes: []const u8, offset: usize) u16 { return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1]; }

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

fn addLeafPage(page: []u8, page_start: usize, header_offset: usize, cells: []const []const u8) !void {
    const header = page_start + header_offset;
    if (cells.len > 0xffff) return error.PageOverflow;
    var content = page_start + page_size;
    for (cells) |item| {
        if (item.len > content - (header + 8 + cells.len * 2)) return error.PageOverflow;
        content -= item.len;
        @memcpy(page[content .. content + item.len], item);
    }
    page[header] = 0x0d;
    putU16(page, header + 1, 0);
    putU16(page, header + 3, @intCast(cells.len));
    putU16(page, header + 5, @intCast(content - page_start));
    page[header + 7] = 0;
    content = page_start + page_size;
    for (cells, 0..) |item, index| {
        content -= item.len;
        putU16(page, header + 8 + index * 2, @intCast(content - page_start));
    }
}

fn createSql(allocator: std.mem.Allocator, table: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
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
    }
    try sql.appendSlice(allocator, ");");
    return sql.toOwnedSlice(allocator);
}

pub fn encode(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    const page_count = 1 + schema.tables.items.len;
    const bytes = try allocator.alloc(u8, page_count * page_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    var header = Header{ .page_size = page_size, .database_size_pages = @intCast(page_count), .change_counter = 1, .schema_cookie = 1 };
    header.encode(@ptrCast(bytes[0..header_size].ptr));

    var schema_cells = try allocator.alloc([]const u8, schema.tables.items.len);
    defer allocator.free(schema_cells);
    var schema_owned = std.ArrayList([]u8).empty;
    defer { for (schema_owned.items) |item| allocator.free(item); schema_owned.deinit(allocator); }

    for (schema.tables.items, 0..) |table, index| {
        const sql = try createSql(allocator, table);
        defer allocator.free(sql);
        const values = [_]Value{
            .{ .text = "table" },
            .{ .text = table.name },
            .{ .text = table.name },
            .{ .integer = @intCast(index + 2) },
            .{ .text = sql },
        };
        const item = try cell(allocator, index + 1, &values);
        try schema_owned.append(allocator, item);
        schema_cells[index] = item;
    }
    addLeafPage(bytes, 0, header_size, schema_cells) catch |err| {
        if (err == error.PageOverflow) return error.DatabaseTooLarge;
        return err;
    };

    for (schema.tables.items, 0..) |table, index| {
        var table_cells = try allocator.alloc([]const u8, table.rows.items.len);
        defer allocator.free(table_cells);
        var owned = std.ArrayList([]u8).empty;
        defer { for (owned.items) |item| allocator.free(item); owned.deinit(allocator); }
        for (table.rows.items, 0..) |row, row_index| {
            const item = try cell(allocator, row_index + 1, row.values);
            try owned.append(allocator, item);
            table_cells[row_index] = item;
        }
        addLeafPage(bytes, (index + 1) * page_size, 0, table_cells) catch |err| {
            if (err == error.PageOverflow) return error.DatabaseTooLarge;
            return err;
        };
    }
    return bytes;
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
    if (bytes.len < page_size or !std.mem.eql(u8, bytes[0..16], "SQLite format 3\x00")) return error.InvalidHeader;
    const database_pages = std.mem.readInt(u32, bytes[28..32], .big);
    if (database_pages == 0 or database_pages * page_size > bytes.len) return error.InvalidHeader;
    var schema = Schema.init(allocator);
    errdefer schema.deinit();
    const schema_rows = try leafCells(allocator, bytes[0..page_size], 1);
    defer allocator.free(schema_rows);
    var entries = std.ArrayList(SchemaEntry).empty;
    defer entries.deinit(allocator);
    for (schema_rows) |row| {
        defer allocator.free(row.values);
        if (row.values.len < 5 or row.values[0] != .text or !std.ascii.eqlIgnoreCase(row.values[0].text, "table")) continue;
        if (row.values[3] != .integer or row.values[4] != .text) continue;
        try entries.append(allocator, .{ .root_page = @intCast(row.values[3].integer), .sql = row.values[4].text });
    }
    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement != .create_table) continue;
        try schema.createTable(statement.create_table.name, statement.create_table.columns);
        const table = schema.find(statement.create_table.name).?;
        const start = (@as(usize, entry.root_page) - 1) * page_size;
        const rows = try leafCells(allocator, bytes[start .. start + page_size], entry.root_page);
        defer allocator.free(rows);
        for (rows) |row| {
            defer allocator.free(row.values);
            try schema.appendRow(table, row.values);
        }
    }
    return schema;
}

test "SQLite image writes a Python-compatible page-one b-tree" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const definitions = [_]ast.ColumnDef{ .{ .name = "id", .type_name = "INTEGER" }, .{ .name = "name", .type_name = "TEXT" } };
    try schema.createTable("users", &definitions);
    var values = [_]Value{ .{ .integer = 1 }, .{ .text = "Fiaz" } };
    try schema.appendRow(schema.find("users").?, &values);
    const bytes = try encode(std.testing.allocator, &schema);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(u8, 0x0d), bytes[100]);
    try std.testing.expectEqualStrings("SQLite format 3\x00", bytes[0..16]);
}
