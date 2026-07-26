const std = @import("std");
const Schema = @import("../catalog/schema.zig").Schema;
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");

fn u32Bytes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .big);
    try list.appendSlice(allocator, &buffer);
}
fn readU32(data: []const u8, offset: *usize) !u32 {
    if (offset.* + 4 > data.len) return error.InvalidHeader;
    var value: u32 = 0;
    for (data[offset.* .. offset.* + 4]) |item| value = (value << 8) | item;
    offset.* += 4;
    return value;
}
fn readU64(data: []const u8, offset: *usize) !u64 {
    if (offset.* + 8 > data.len) return error.InvalidHeader;
    var value: u64 = 0;
    for (data[offset.* .. offset.* + 8]) |item| value = (value << 8) | item;
    offset.* += 8;
    return value;
}
fn bytes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try u32Bytes(list, allocator, @intCast(value.len));
    try list.appendSlice(allocator, value);
}
fn readBytes(allocator: std.mem.Allocator, data: []const u8, offset: *usize) ![]u8 {
    const length = try readU32(data, offset);
    if (offset.* + length > data.len) return error.InvalidHeader;
    const result = try allocator.dupe(u8, data[offset.* .. offset.* + length]);
    offset.* += length;
    return result;
}

pub fn encode(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try u32Bytes(&result, allocator, @intCast(schema.tables.items.len));
    for (schema.tables.items) |table| {
        try bytes(&result, allocator, table.name);
        try u32Bytes(&result, allocator, @intCast(table.columns.len));
        for (table.columns) |column| {
            try bytes(&result, allocator, column.name);
            try bytes(&result, allocator, column.type_name);
            result.append(allocator, @intFromBool(column.primary_key)) catch return error.OutOfMemory;
            result.append(allocator, @intFromBool(column.not_null)) catch return error.OutOfMemory;
        }
        try u32Bytes(&result, allocator, @intCast(table.rows.items.len));
        for (table.rows.items) |row| for (row.values) |value| switch (value) {
            .null => try result.append(allocator, 0),
            .integer => |n| {
                try result.append(allocator, 1);
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, n, .big);
                try result.appendSlice(allocator, &b);
            },
            .real => |n| {
                try result.append(allocator, 2);
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, @bitCast(n), .big);
                try result.appendSlice(allocator, &b);
            },
            .text => |v| {
                try result.append(allocator, 3);
                try bytes(&result, allocator, v);
            },
            .blob => |v| {
                try result.append(allocator, 4);
                try bytes(&result, allocator, v);
            },
        };
    }
    return result.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Schema {
    var schema = Schema.init(allocator);
    errdefer schema.deinit();
    var offset: usize = 0;
    const table_count = try readU32(data, &offset);
    var table_index: u32 = 0;
    while (table_index < table_count) : (table_index += 1) {
        const name = try readBytes(allocator, data, &offset);
        defer allocator.free(name);
        const column_count = try readU32(data, &offset);
        const definitions = try allocator.alloc(ast.ColumnDef, column_count);
        defer allocator.free(definitions);
        var i: usize = 0;
        while (i < column_count) : (i += 1) {
            const column_name = try readBytes(allocator, data, &offset);
            const type_name = try readBytes(allocator, data, &offset);
            if (offset + 2 > data.len) return error.InvalidHeader;
            definitions[i] = .{ .name = column_name, .type_name = type_name, .primary_key = data[offset] != 0, .not_null = data[offset + 1] != 0 };
            offset += 2;
        }
        try schema.createTable(name, definitions);
        for (definitions) |definition| {
            allocator.free(definition.name);
            allocator.free(definition.type_name);
        }
        const table = schema.find(name).?;
        const row_count = try readU32(data, &offset);
        var row_index: u32 = 0;
        while (row_index < row_count) : (row_index += 1) {
            const values = try allocator.alloc(Value, column_count);
            defer allocator.free(values);
            for (values) |*value| {
                if (offset >= data.len) return error.InvalidHeader;
                const tag = data[offset];
                offset += 1;
                value.* = switch (tag) {
                    0 => .null,
                    1 => .{ .integer = @bitCast(try readU64(data, &offset)) },
                    2 => .{ .real = @bitCast(try readU64(data, &offset)) },
                    3 => .{ .text = try readBytes(allocator, data, &offset) },
                    4 => .{ .blob = try readBytes(allocator, data, &offset) },
                    else => return error.InvalidHeader,
                };
            }
            try schema.appendRow(table, values);
            for (values) |value| switch (value) {
                .text => |v| allocator.free(v),
                .blob => |v| allocator.free(v),
                else => {},
            };
        }
    }
    return schema;
}

test "schema image round trip" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{.{ .name = "id", .type_name = "INTEGER" }};
    try schema.createTable("t", &defs);
    var row = [_]Value{.{ .integer = 7 }};
    try schema.appendRow(schema.find("t").?, &row);
    const image = try encode(std.testing.allocator, &schema);
    defer std.testing.allocator.free(image);
    var restored = try decode(std.testing.allocator, image);
    defer restored.deinit();
    try std.testing.expectEqual(@as(i64, 7), restored.find("t").?.rows.items[0].values[0].integer);
}
