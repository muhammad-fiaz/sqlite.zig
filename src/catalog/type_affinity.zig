const std = @import("std");
const Value = @import("../vm/value.zig").Value;

pub const Affinity = enum {
    blob,
    text,
    numeric,
    integer,
    real,

    pub fn name(self: Affinity) []const u8 {
        return switch (self) {
            .blob => "BLOB",
            .text => "TEXT",
            .numeric => "NUMERIC",
            .integer => "INTEGER",
            .real => "REAL",
        };
    }
};

pub fn fromDeclaration(declaration: []const u8) Affinity {
    const trimmed = std.mem.trim(u8, declaration, " \t\r\n");
    if (trimmed.len == 0) return .blob;
    if (std.ascii.indexOfIgnoreCase(trimmed, "INT")) |_| return .integer;
    if (std.ascii.indexOfIgnoreCase(trimmed, "CHAR")) |_| return .text;
    if (std.ascii.indexOfIgnoreCase(trimmed, "CLOB")) |_| return .text;
    if (std.ascii.indexOfIgnoreCase(trimmed, "TEXT")) |_| return .text;
    if (std.ascii.indexOfIgnoreCase(trimmed, "BLOB")) |_| return .blob;
    if (std.ascii.indexOfIgnoreCase(trimmed, "REAL")) |_| return .real;
    if (std.ascii.indexOfIgnoreCase(trimmed, "FLOA")) |_| return .real;
    if (std.ascii.indexOfIgnoreCase(trimmed, "DOUB")) |_| return .real;
    return .numeric;
}

fn parseTextToNumeric(bytes: []const u8) ?Value {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.fmt.parseInt(i64, trimmed, 10)) |intVal| {
        return .{ .integer = intVal };
    } else |_| {}
    if (std.fmt.parseFloat(f64, trimmed)) |floatVal| {
        if (!std.math.isNan(floatVal) and !std.math.isInf(floatVal)) {
            return .{ .real = floatVal };
        }
    } else |_| {}
    return null;
}

pub fn apply(affinity: Affinity, value: Value) Value {
    return switch (affinity) {
        .integer => switch (value) {
            .real => |r| blk: {
                if (r >= -9223372036854775808.0 and r <= 9223372036854774784.0 and r == @floor(r)) {
                    break :blk .{ .integer = @intFromFloat(r) };
                }
                break :blk value;
            },
            .text => |bytes| blk: {
                if (parseTextToNumeric(bytes)) |num| {
                    if (num == .integer) break :blk num;
                    if (num == .real and num.real == @floor(num.real) and num.real >= -9223372036854775808.0 and num.real <= 9223372036854774784.0) {
                        break :blk .{ .integer = @intFromFloat(num.real) };
                    }
                    break :blk num;
                }
                break :blk value;
            },
            else => value,
        },
        .numeric => switch (value) {
            .text => |bytes| parseTextToNumeric(bytes) orelse value,
            else => value,
        },
        .real => switch (value) {
            .integer => |n| .{ .real = @floatFromInt(n) },
            .text => |bytes| blk: {
                if (parseTextToNumeric(bytes)) |num| {
                    if (num == .integer) break :blk .{ .real = @floatFromInt(num.integer) };
                    break :blk num;
                }
                break :blk value;
            },
            else => value,
        },
        .text, .blob => value,
    };
}

pub fn applyAlloc(allocator: std.mem.Allocator, affinity: Affinity, value: Value) !Value {
    if (affinity == .text) {
        return switch (value) {
            .integer => |n| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{n}) },
            .real => |r| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{r}) },
            .text => |bytes| .{ .text = try allocator.dupe(u8, bytes) },
            .blob => |bytes| .{ .blob = try allocator.dupe(u8, bytes) },
            .null => .null,
        };
    }
    const applied = apply(affinity, value);
    return switch (applied) {
        .text => |bytes| .{ .text = try allocator.dupe(u8, bytes) },
        .blob => |bytes| .{ .blob = try allocator.dupe(u8, bytes) },
        else => applied,
    };
}

test "type declarations map to SQLite affinities" {
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("INTEGER PRIMARY KEY"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("BIGINT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("TINYINT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("SMALLINT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("MEDIUMINT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("INT2"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("INT8"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("UNSIGNED BIG INT"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("CHARACTER(20)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("VARYING CHARACTER(255)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("NCHAR(55)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("NATIVE CHARACTER(70)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("NVARCHAR(100)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("VARCHAR(80)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("TEXT"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("CLOB"));
    try std.testing.expectEqual(Affinity.blob, fromDeclaration("BLOB"));
    try std.testing.expectEqual(Affinity.blob, fromDeclaration(""));
    try std.testing.expectEqual(Affinity.real, fromDeclaration("REAL"));
    try std.testing.expectEqual(Affinity.real, fromDeclaration("DOUBLE PRECISION"));
    try std.testing.expectEqual(Affinity.real, fromDeclaration("DOUBLE"));
    try std.testing.expectEqual(Affinity.real, fromDeclaration("FLOAT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("FLOATING POINT"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("NUMERIC"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("BOOLEAN"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("DATE"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("DATETIME"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("DECIMAL(10,2)"));
}

test "sqlite affinity coercion follows reference implementation rules" {
    const textInt = Value{ .text = "42" };
    const textReal = Value{ .text = "3.14" };
    const intVal = Value{ .integer = 7 };
    const realInt = Value{ .real = 10.0 };
    const realFrac = Value{ .real = 10.5 };

    try std.testing.expectEqual(@as(i64, 42), apply(.integer, textInt).integer);
    try std.testing.expectEqual(@as(i64, 10), apply(.integer, realInt).integer);
    try std.testing.expectEqual(@as(f64, 10.5), apply(.integer, realFrac).real);
    try std.testing.expectEqual(@as(f64, 7.0), apply(.real, intVal).real);
    try std.testing.expectEqual(@as(i64, 42), apply(.numeric, textInt).integer);
    try std.testing.expectEqual(@as(f64, 3.14), apply(.numeric, textReal).real);

    var textFromInt = try applyAlloc(std.testing.allocator, .text, intVal);
    defer textFromInt.free(std.testing.allocator);
    try std.testing.expectEqualStrings("7", textFromInt.text);
}
