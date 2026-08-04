const std = @import("std");
const Value = @import("../vm/value.zig").Value;

pub const Result = struct {
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    rows: []const []Value,
    changes: usize = 0,

    pub fn deinit(self: *Result) void {
        for (self.rows) |row| {
            for (row) |value| switch (value) {
                .text => |bytes| self.allocator.free(bytes),
                .blob => |bytes| self.allocator.free(bytes),
                else => {},
            };
            self.allocator.free(row);
        }
        for (self.columns) |column| self.allocator.free(column);
        self.allocator.free(self.rows);
        self.allocator.free(self.columns);
    }

    pub fn rowCount(self: Result) usize {
        return self.rows.len;
    }
};
