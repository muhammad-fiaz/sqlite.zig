const std = @import("std");
const Expr = @import("expr.zig").Expr;
const sql_gen = @import("sql_gen.zig");
const Result = @import("../connection/result.zig").Result;

pub const Order = struct { column: []const u8, descending: bool };

pub const Query = struct {
    allocator: std.mem.Allocator,
    connection: *anyopaque,
    execute_fn: *const fn (*anyopaque, []const u8) anyerror!Result,
    table: []const u8,
    projection: []const u8 = "*",
    condition: ?Expr = null,
    order: ?Order = null,
    limit_value: ?usize = null,

    pub fn init(connection: anytype, table: []const u8, execute_fn: *const fn (*anyopaque, []const u8) anyerror!Result) Query {
        return .{ .allocator = connection.allocator, .connection = connection, .execute_fn = execute_fn, .table = table };
    }
    pub fn select(self: Query, projection: []const u8) Query {
        var copy = self;
        copy.projection = projection;
        return copy;
    }
    pub fn where(self: Query, condition: Expr) Query {
        var copy = self;
        copy.condition = condition;
        return copy;
    }
    pub fn orderBy(self: Query, order: Order) Query {
        var copy = self;
        copy.order = order;
        return copy;
    }
    pub fn limit(self: Query, count: usize) Query {
        var copy = self;
        copy.limit_value = count;
        return copy;
    }

    pub fn fetchAll(self: Query) !Result {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(self.allocator);
        try list.appendSlice(self.allocator, "SELECT ");
        try list.appendSlice(self.allocator, self.projection);
        try list.appendSlice(self.allocator, " FROM ");
        try list.appendSlice(self.allocator, self.table);
        if (self.condition) |condition| {
            const rendered = try sql_gen.renderExpr(self.allocator, condition);
            defer self.allocator.free(rendered);
            try list.appendSlice(self.allocator, " WHERE ");
            try list.appendSlice(self.allocator, rendered);
        }
        if (self.order) |order| {
            try list.appendSlice(self.allocator, " ORDER BY ");
            try list.appendSlice(self.allocator, order.column);
            if (order.descending) try list.appendSlice(self.allocator, " DESC");
        }
        if (self.limit_value) |count| {
            const rendered = try std.fmt.allocPrint(self.allocator, " LIMIT {d}", .{count});
            defer self.allocator.free(rendered);
            try list.appendSlice(self.allocator, rendered);
        }
        return self.execute_fn(self.connection, list.items);
    }
};
