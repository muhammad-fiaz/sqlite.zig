const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const Result = @import("result.zig").Result;

pub const Statement = struct {
    connection: *anyopaque,
    sql: []u8,
    allocator: std.mem.Allocator,
    parameters: std.ArrayList(Value),
    executeFn: *const fn (*anyopaque, []const u8, []const Value) anyerror!void,
    queryFn: *const fn (*anyopaque, []const u8, []const Value) anyerror!Result,

    pub fn bind(self: *Statement, index: usize, value: anytype) !void {
        const converted: Value = bindValue(value);
        while (self.parameters.items.len < index) try self.parameters.append(self.allocator, .null);
        if (index == 0) return error.InvalidParameter;
        if (index - 1 == self.parameters.items.len) try self.parameters.append(self.allocator, converted) else self.parameters.items[index - 1] = converted;
    }

    pub fn step(self: *Statement) !void {
        return self.executeFn(self.connection, self.sql, self.parameters.items);
    }

    pub fn query(self: *Statement) !Result {
        return self.queryFn(self.connection, self.sql, self.parameters.items);
    }

    pub fn reset(self: *Statement) void {
        self.parameters.clearRetainingCapacity();
    }

    pub fn finalize(self: *Statement) void {
        self.parameters.deinit(self.allocator);
        self.allocator.free(self.sql);
    }

    fn bindValue(value: anytype) Value {
        const T = @TypeOf(value);
        if (T == Value) return value;
        if (@typeInfo(T) == .optional) {
            if (value) |present| return bindValue(present);
            return .null;
        }
        if (@typeInfo(T) == .null) return .null;
        return switch (@typeInfo(T)) {
            .bool => .{ .integer = if (value) 1 else 0 },
            .int, .comptime_int => .{ .integer = @intCast(value) },
            .float, .comptime_float => .{ .real = @floatCast(value) },
            .pointer => .{ .text = value },
            else => @compileError("unsupported SQL parameter type"),
        };
    }
};

test "statement parameter binding stores values" {
    var parameters = std.ArrayList(Value).empty;
    defer parameters.deinit(std.testing.allocator);
    var statement = Statement{ .connection = undefined, .sql = try std.testing.allocator.dupe(u8, ""), .allocator = std.testing.allocator, .parameters = parameters, .executeFn = undefined, .queryFn = undefined };
    defer statement.finalize();
    try statement.bind(1, 12);
    try std.testing.expectEqual(@as(i64, 12), statement.parameters.items[0].integer);
}
