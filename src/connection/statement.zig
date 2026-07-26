const std = @import("std");
const Value = @import("../vm/value.zig").Value;

pub const Statement = struct {
    connection: *anyopaque,
    sql: []u8,
    allocator: std.mem.Allocator,
    parameters: std.ArrayList(Value),
    execute_fn: *const fn (*anyopaque, []const u8, []const Value) anyerror!void,

    pub fn bind(self: *Statement, index: usize, value: anytype) !void {
        const T = @TypeOf(value);
        const converted: Value = if (T == Value) value else if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) .{ .integer = @intCast(value) } else if (@typeInfo(T) == .float or @typeInfo(T) == .comptime_float) .{ .real = @floatCast(value) } else if (@typeInfo(T) == .pointer) .{ .text = value } else @compileError("unsupported SQL parameter type");
        while (self.parameters.items.len < index) try self.parameters.append(self.allocator, .null);
        if (index == 0) return error.InvalidParameter;
        if (index - 1 == self.parameters.items.len) try self.parameters.append(self.allocator, converted) else self.parameters.items[index - 1] = converted;
    }

    pub fn step(self: *Statement) !void {
        return self.execute_fn(self.connection, self.sql, self.parameters.items);
    }

    pub fn reset(self: *Statement) void {
        self.parameters.clearRetainingCapacity();
    }

    pub fn finalize(self: *Statement) void {
        self.parameters.deinit(self.allocator);
        self.allocator.free(self.sql);
    }
};

test "statement parameter binding stores values" {
    var parameters = std.ArrayList(Value).empty;
    defer parameters.deinit(std.testing.allocator);
    var statement = Statement{ .connection = undefined, .sql = try std.testing.allocator.dupe(u8, ""), .allocator = std.testing.allocator, .parameters = parameters, .execute_fn = undefined };
    defer statement.finalize();
    try statement.bind(1, 12);
    try std.testing.expectEqual(@as(i64, 12), statement.parameters.items[0].integer);
}
