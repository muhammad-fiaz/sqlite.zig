//! Older length-prefixed schema image codec.
//!
//! `encode` returns a fresh buffer; `decode` returns an owned Schema.
//! Truncated input or bad tags fail with `InvalidHeader`.

const std = @import("std");
const Schema = @import("../catalog/schema.zig").Schema;
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");

/// Maximum tables per image. Far above legitimate schemas; bounds the
/// table loop over a corrupt u32 count so decoding cannot spin.
pub const maxTables: u32 = 100_000;
/// Maximum columns per table. SQLite itself caps columns at 2000; anything
/// larger is corruption, and the cap bounds the definition allocation.
pub const maxColumns: u32 = 10_000;
/// Maximum rows per table. Bounds the row loop (zero-column rows consume no
/// input bytes, so input exhaustion alone cannot stop a corrupt count).
pub const maxRows: u32 = 10_000_000;

/// Appends a big-endian u32 length prefix + helper.
fn u32Bytes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .big);
    try list.appendSlice(allocator, &buffer);
}
/// Reads one big-endian u32 at `offset.*`, advancing past it.
///
/// Safety: bounds-checked; overruns return `InvalidHeader` instead of
/// reading out of bounds.
fn readU32(data: []const u8, offset: *usize) !u32 {
    if (offset.* + 4 > data.len) return error.InvalidHeader;
    var value: u32 = 0;
    for (data[offset.* .. offset.* + 4]) |item| value = (value << 8) | item;
    offset.* += 4;
    return value;
}
/// Reads one big-endian u64 (integer/real bodies). Bounds-checked like
/// `readU32`.
fn readU64(data: []const u8, offset: *usize) !u64 {
    if (offset.* + 8 > data.len) return error.InvalidHeader;
    var value: u64 = 0;
    for (data[offset.* .. offset.* + 8]) |item| value = (value << 8) | item;
    offset.* += 8;
    return value;
}
/// Appends a u32-prefixed byte string.
fn bytes(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try u32Bytes(list, allocator, @intCast(value.len));
    try list.appendSlice(allocator, value);
}
/// Reads a u32-prefixed byte string into a caller-owned buffer.
/// The length is checked against remaining input before allocating.
fn readBytes(allocator: std.mem.Allocator, data: []const u8, offset: *usize) ![]u8 {
    const length = try readU32(data, offset);
    if (offset.* + length > data.len) return error.InvalidHeader;
    const result = try allocator.dupe(u8, data[offset.* .. offset.* + length]);
    offset.* += length;
    return result;
}

/// Encodes `schema` into a fresh caller-owned image buffer.
///
/// Value tags: 0 = NULL, 1 = i64, 2 = f64 bits, 3 = text, 4 = blob.
/// Primary-key/not-null flags ride as two trailing bytes per column.
pub fn encode(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try u32Bytes(&result, allocator, @intCast(schema.tables.items.len));
    for (schema.tables.items) |table| {
        try bytes(&result, allocator, table.name);
        try u32Bytes(&result, allocator, @intCast(table.columns.len));
        for (table.columns) |column| {
            try bytes(&result, allocator, column.name);
            try bytes(&result, allocator, column.typeName);
            result.append(allocator, @intFromBool(column.primaryKey)) catch return error.OutOfMemory;
            result.append(allocator, @intFromBool(column.notNull)) catch return error.OutOfMemory;
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

/// Rebuilds an owned `Schema` from `data`; corrupt input fails closed.
/// Counts and lengths stay bounded and every error path frees what it owns.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Schema {
    var schema = Schema.init(allocator);
    errdefer schema.deinit();
    schema.foreignKeysEnabled = false;
    var offset: usize = 0;
    const tableCount = try readU32(data, &offset);
    if (tableCount > maxTables or @as(u64, tableCount) > data.len) return error.InvalidHeader;
    var tableIndex: u32 = 0;
    while (tableIndex < tableCount) : (tableIndex += 1) {
        const name = try readBytes(allocator, data, &offset);
        defer allocator.free(name);
        const columnCount = try readU32(data, &offset);
        if (columnCount > maxColumns or @as(u64, columnCount) > data.len) return error.InvalidHeader;
        const definitions = try allocator.alloc(ast.ColumnDef, columnCount);
        defer allocator.free(definitions);
        // `defined` counts initialized entries so every error path below
        // frees exactly the name/type strings owned so far (no leaks on
        // truncated input, no double-free on success).
        var defined: usize = 0;
        errdefer for (definitions[0..defined]) |definition| {
            allocator.free(definition.name);
            allocator.free(definition.typeName);
        };
        var i: usize = 0;
        while (i < columnCount) : (i += 1) {
            // Explicit frees (not errdefer): per-iteration errdefers would
            // linger after success and double-free on a later failure.
            const columnName = try readBytes(allocator, data, &offset);
            const typeName = readBytes(allocator, data, &offset) catch |err| {
                allocator.free(columnName);
                return err;
            };
            if (offset + 2 > data.len) {
                allocator.free(columnName);
                allocator.free(typeName);
                return error.InvalidHeader;
            }
            definitions[i] = .{ .name = columnName, .typeName = typeName, .primaryKey = data[offset] != 0, .notNull = data[offset + 1] != 0 };
            offset += 2;
            defined += 1;
        }
        try schema.createTable(name, definitions, &.{});
        for (definitions) |definition| {
            allocator.free(definition.name);
            allocator.free(definition.typeName);
        }
        defined = 0;
        const table = schema.find(name).?;
        const rowCount = try readU32(data, &offset);
        if (rowCount > maxRows) return error.InvalidHeader;
        // Each stored value costs >= 1 tag byte, so a nonzero-width row
        // count is also bounded by the input size (u64 math, no overflow).
        if (columnCount > 0 and @as(u64, rowCount) * @as(u64, columnCount) > @as(u64, data.len)) return error.InvalidHeader;
        var rowIndex: u32 = 0;
        while (rowIndex < rowCount) : (rowIndex += 1) {
            const values = try allocator.alloc(Value, columnCount);
            defer allocator.free(values);
            // `armed` disarms the errdefer once we free the text/blob
            // copies below. Without it, errdefers registered by successful
            // iterations would linger and double-free when a later row
            // fails (errdefers run on any later error return).
            var filled: usize = 0;
            var armed: bool = true;
            errdefer {
                if (armed) for (values[0..filled]) |value| switch (value) {
                    .text => |v| allocator.free(v),
                    .blob => |v| allocator.free(v),
                    else => {},
                };
            }
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
                filled += 1;
            }
            try schema.appendRow(table, values);
            for (values) |value| switch (value) {
                .text => |v| allocator.free(v),
                .blob => |v| allocator.free(v),
                else => {},
            };
            armed = false;
        }
    }
    schema.foreignKeysEnabled = true;
    return schema;
}

test "schema image round trip" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER" }};
    try schema.createTable("t", &defs, &.{});
    var row = [_]Value{.{ .integer = 7 }};
    try schema.appendRow(schema.find("t").?, &row);
    const image = try encode(std.testing.allocator, &schema);
    defer std.testing.allocator.free(image);
    var restored = try decode(std.testing.allocator, image);
    defer restored.deinit();
    try std.testing.expectEqual(@as(i64, 7), restored.find("t").?.rows.items[0].values[0].integer);
}

test "schema image rejects truncation, bad tags, and absurd counts" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER" },
        .{ .name = "name", .typeName = "TEXT" },
    };
    try schema.createTable("t", &defs, &.{});
    var row = [_]Value{ .{ .integer = 1 }, .{ .text = "hi" } };
    try schema.appendRow(schema.find("t").?, &row);
    const image = try encode(std.testing.allocator, &schema);
    defer std.testing.allocator.free(image);
    // Normal: full image decodes.
    {
        var ok = try decode(std.testing.allocator, image);
        defer ok.deinit();
        try std.testing.expectEqual(@as(usize, 1), ok.find("t").?.rows.items.len);
    }
    // Error: every truncation fails closed (sampled stride keeps it fast).
    var cut: usize = 1;
    while (cut < image.len) : (cut += 7) {
        try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, image[0..cut]));
    }
    try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, &[_]u8{}));
    // Error: unknown value tag is rejected, not misinterpreted. A minimal
    // one-table image is built by hand with tag 9 (no such tag exists).
    {
        var bad = std.ArrayList(u8).empty;
        defer bad.deinit(std.testing.allocator);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, 1, .big);
        try bad.appendSlice(std.testing.allocator, &len); // table count
        std.mem.writeInt(u32, &len, 1, .big);
        try bad.appendSlice(std.testing.allocator, &len); // name len
        try bad.append(std.testing.allocator, 't'); // name
        std.mem.writeInt(u32, &len, 1, .big);
        try bad.appendSlice(std.testing.allocator, &len); // column count
        std.mem.writeInt(u32, &len, 1, .big);
        try bad.appendSlice(std.testing.allocator, &len); // column name len
        try bad.append(std.testing.allocator, 'a');
        std.mem.writeInt(u32, &len, 7, .big);
        try bad.appendSlice(std.testing.allocator, &len); // type name len
        try bad.appendSlice(std.testing.allocator, "INTEGER");
        try bad.append(std.testing.allocator, 0); // primary key flag
        try bad.append(std.testing.allocator, 0); // not-null flag
        std.mem.writeInt(u32, &len, 1, .big);
        try bad.appendSlice(std.testing.allocator, &len); // row count
        try bad.append(std.testing.allocator, 9); // invalid tag
        try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, bad.items));
    }
    // Error: absurd counts fail before any blind allocation.
    {
        var hugeTables: [4]u8 = undefined;
        std.mem.writeInt(u32, &hugeTables, 0xffffffff, .big);
        try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, &hugeTables));
    }
    {
        // One-column table image with the column count patched to max u32:
        // offset 4 (table count) + 4 (name len) + 1 (name) = 9.
        var oneCol = Schema.init(std.testing.allocator);
        defer oneCol.deinit();
        const oneDef = [_]ast.ColumnDef{.{ .name = "a", .typeName = "INTEGER" }};
        try oneCol.createTable("t", &oneDef, &.{});
        const oneImage = try encode(std.testing.allocator, &oneCol);
        defer std.testing.allocator.free(oneImage);
        var patched = try std.testing.allocator.dupe(u8, oneImage);
        defer std.testing.allocator.free(patched);
        std.mem.writeInt(u32, patched[9..13], 0xffffffff, .big);
        try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, patched));
    }
}
