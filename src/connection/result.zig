const std = @import("std");
const Value = @import("../vm/value.zig").Value;

pub const DynamicRow = struct {
    columns: []const []const u8,
    values: []Value,

    pub fn get(self: @This(), name: []const u8) !Value {
        const index = findColumn(self.columns, name) orelse return error.UnknownColumn;
        return self.values[index];
    }

    pub fn at(self: @This(), index: usize) Value {
        return self.values[index];
    }

    pub fn len(self: @This()) usize {
        return self.values.len;
    }
};

pub const RowIter = struct {
    result: *const Result,
    index: usize = 0,

    pub fn next(self: *RowIter) ?DynamicRow {
        if (self.index >= self.result.rows.len) return null;
        const row = self.result.row(self.index);
        self.index += 1;
        return row;
    }
};

fn findColumn(columns: []const []const u8, name: []const u8) ?usize {
    for (columns, 0..) |column, index| {
        if (std.ascii.eqlIgnoreCase(column, name)) return index;
    }
    return null;
}

pub const Result = struct {
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    rows: []const []Value,
    changes: usize = 0,

    pub fn deinit(self: *Result) void {
        for (self.rows) |values| {
            for (values) |value| switch (value) {
                .text => |bytes| self.allocator.free(bytes),
                .blob => |bytes| self.allocator.free(bytes),
                else => {},
            };
            self.allocator.free(values);
        }
        for (self.columns) |column| self.allocator.free(column);
        self.allocator.free(self.rows);
        self.allocator.free(self.columns);
    }

    pub fn count(self: Result) usize {
        return self.rows.len;
    }

    pub fn isEmpty(self: Result) bool {
        return self.rows.len == 0;
    }

    pub fn at(self: Result, index: usize) []Value {
        return self.rows[index];
    }

    pub fn slice(self: Result) []const []Value {
        return self.rows;
    }

    pub fn columnIndex(self: Result, name: []const u8) ?usize {
        return findColumn(self.columns, name);
    }

    pub fn get(self: Result, rowIndex: usize, name: []const u8) !Value {
        return self.row(rowIndex).get(name);
    }

    pub fn row(self: *const Result, index: usize) DynamicRow {
        return .{ .columns = self.columns, .values = self.rows[index] };
    }

    pub fn iter(self: *const Result) RowIter {
        return .{ .result = self };
    }
};
