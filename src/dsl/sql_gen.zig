const std = @import("std");
const dslExpr = @import("expr.zig");
const Expr = dslExpr.Expr;
const Order = dslExpr.Order;
const Projection = dslExpr.Projection;
const ColumnRef = dslExpr.ColumnRef;
const FuncCall = dslExpr.FuncCall;
const Value = @import("../vm/value.zig").Value;

pub const Params = std.ArrayList(Value);

pub fn appendIdent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), identifier: []const u8) !void {
    if (identifier.len == 0) return error.InvalidSql;
    if (identifier[identifier.len - 1] == '.') return error.InvalidSql;
    var start: usize = 0;
    while (start < identifier.len) {
        const end = std.mem.indexOfScalarPos(u8, identifier, start, '.') orelse identifier.len;
        const part = identifier[start..end];
        if (part.len == 0) return error.InvalidSql;
        try out.append(allocator, '"');
        for (part) |byte| {
            if (byte == 0) return error.InvalidSql;
            if (byte == '"') try out.append(allocator, '"');
            try out.append(allocator, byte);
        }
        try out.append(allocator, '"');
        if (end == identifier.len) break;
        try out.append(allocator, '.');
        start = end + 1;
    }
}

pub fn appendRef(allocator: std.mem.Allocator, out: *std.ArrayList(u8), ref: ColumnRef) !void {
    if (ref.name.len == 0) return error.InvalidSql;
    if (ref.table.len != 0) {
        try appendIdent(allocator, out, ref.table);
        try out.append(allocator, '.');
    }
    try appendIdent(allocator, out, ref.name);
}

fn appendFuncArgValue(params: *Params, allocator: std.mem.Allocator, value: Value) !void {
    try params.append(allocator, value);
}

fn appendLeft(allocator: std.mem.Allocator, out: *std.ArrayList(u8), params: *Params, ref: ColumnRef, func: ?FuncCall) !void {
    const call = func orelse return appendRef(allocator, out, ref);
    if (std.ascii.eqlIgnoreCase(call.name, "CAST")) {
        try out.appendSlice(allocator, "CAST(");
        try appendRef(allocator, out, ref);
        try out.appendSlice(allocator, " AS ");
        const target: []const u8 = if (call.hasArgument and call.argument == .text) call.argument.text else return error.InvalidSql;
        if (target.len == 0) return error.InvalidSql;
        try out.appendSlice(allocator, target);
        try out.append(allocator, ')');
        return;
    }
    try out.appendSlice(allocator, call.name);
    try out.append(allocator, '(');
    try appendRef(allocator, out, ref);
    if (call.hasArgument) {
        try out.appendSlice(allocator, ", ?");
        try appendFuncArgValue(params, allocator, call.argument);
        if (call.hasArgument2) {
            try out.appendSlice(allocator, ", ?");
            try appendFuncArgValue(params, allocator, call.argument2);
        }
    }
    try out.append(allocator, ')');
}

fn appendRhs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), params: *Params, rhs: dslExpr.Rhs) !void {
    switch (rhs) {
        .column => |ref| try appendRef(allocator, out, ref),
        .value => |value| {
            try params.append(allocator, value);
            try out.append(allocator, '?');
        },
    }
}

pub fn appendExpr(allocator: std.mem.Allocator, out: *std.ArrayList(u8), params: *Params, expr: Expr) !void {
    if (expr.negated) try out.appendSlice(allocator, "NOT (");
    try appendLeft(allocator, out, params, expr.column, expr.function);
    if (expr.collate) |name| {
        try out.appendSlice(allocator, " COLLATE ");
        try out.appendSlice(allocator, name);
    }
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, expr.operator.sql());
    if (!expr.needsRhs()) {
        if (expr.negated) try out.append(allocator, ')');
        return;
    }
    try out.append(allocator, ' ');
    try appendRhs(allocator, out, params, expr.rhs);
    if (expr.needsRhs2()) {
        try out.appendSlice(allocator, " AND ");
        try appendRhs(allocator, out, params, expr.rhs2.?);
    }
    if (expr.escape) |escape| {
        if (expr.operator != .like and expr.operator != .notLike) return error.InvalidSql;
        try out.appendSlice(allocator, " ESCAPE ?");
        try params.append(allocator, escape);
    }
    if (expr.negated) try out.append(allocator, ')');
}

pub fn appendOrder(allocator: std.mem.Allocator, out: *std.ArrayList(u8), params: *Params, order: Order) !void {
    try appendLeft(allocator, out, params, order.column, order.function);
    if (order.descending) try out.appendSlice(allocator, " DESC");
}

pub fn appendProjection(allocator: std.mem.Allocator, out: *std.ArrayList(u8), params: *Params, proj: Projection) !void {
    switch (proj.kind) {
        .star => try out.append(allocator, '*'),
        .countStar => try out.appendSlice(allocator, "COUNT(*)"),
        .column => try appendRef(allocator, out, proj.column),
        .aggregate => {
            try out.appendSlice(allocator, proj.function);
            try out.append(allocator, '(');
            if (proj.distinct) try out.appendSlice(allocator, "DISTINCT ");
            try appendRef(allocator, out, proj.column);
            try out.append(allocator, ')');
        },
        .scalar => {
            if (std.ascii.eqlIgnoreCase(proj.function, "CAST")) {
                try out.appendSlice(allocator, "CAST(");
                try appendRef(allocator, out, proj.column);
                try out.appendSlice(allocator, " AS ");
                const target: []const u8 = if (proj.hasArgument and proj.argument == .text) proj.argument.text else return error.InvalidSql;
                try out.appendSlice(allocator, target);
                try out.append(allocator, ')');
                return;
            }
            try out.appendSlice(allocator, proj.function);
            try out.append(allocator, '(');
            try appendRef(allocator, out, proj.column);
            if (proj.hasArgument) {
                try out.appendSlice(allocator, ", ?");
                try params.append(allocator, proj.argument);
                if (proj.hasArgument2) {
                    try out.appendSlice(allocator, ", ?");
                    try params.append(allocator, proj.argument2);
                }
            }
            try out.append(allocator, ')');
        },
    }
}

test "predicates bind values and quote identifiers" {
    const allocator = std.testing.allocator;
    const col = @import("column.zig").DynamicColumn{ .name = "users.age" };
    const expr = col.gte(18);
    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(allocator);
    var params = Params.empty;
    defer params.deinit(allocator);
    try appendExpr(allocator, &sql, &params, expr);
    try std.testing.expectEqualStrings("\"users\".\"age\" >= ?", sql.items);
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
    try std.testing.expectEqual(@as(i64, 18), params.items[0].integer);
}

test "between and column comparisons bind in order" {
    const allocator = std.testing.allocator;
    const column = @import("column.zig").DynamicColumn;
    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(allocator);
    var params = Params.empty;
    defer params.deinit(allocator);
    try appendExpr(allocator, &sql, &params, (column{ .name = "age" }).between(1, 9));
    try std.testing.expectEqualStrings("\"age\" BETWEEN ? AND ?", sql.items);
    try std.testing.expectEqual(@as(i64, 1), params.items[0].integer);
    try std.testing.expectEqual(@as(i64, 9), params.items[1].integer);
    sql.clearRetainingCapacity();
    params.clearRetainingCapacity();
    try appendExpr(allocator, &sql, &params, (column{ .name = "a.id" }).eq(column{ .name = "b.aid" }));
    try std.testing.expectEqualStrings("\"a\".\"id\" = \"b\".\"aid\"", sql.items);
    try std.testing.expectEqual(@as(usize, 0), params.items.len);
    sql.clearRetainingCapacity();
    try appendExpr(allocator, &sql, &params, (column{ .name = "name" }).isNull());
    try std.testing.expectEqualStrings("\"name\" IS NULL", sql.items);
}

test "identifiers quote each dotted part" {
    const allocator = std.testing.allocator;
    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(allocator);
    try appendIdent(allocator, &sql, "weird name");
    try std.testing.expectEqualStrings("\"weird name\"", sql.items);
    sql.clearRetainingCapacity();
    try appendIdent(allocator, &sql, "t.c");
    try std.testing.expectEqualStrings("\"t\".\"c\"", sql.items);
    try std.testing.expectError(error.InvalidSql, appendIdent(allocator, &sql, ""));
    try std.testing.expectError(error.InvalidSql, appendIdent(allocator, &sql, "a."));
}

test "orders and projections render bare and aggregate forms" {
    const allocator = std.testing.allocator;
    const column = @import("column.zig").DynamicColumn;
    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(allocator);
    var params = Params.empty;
    defer params.deinit(allocator);
    try appendOrder(allocator, &sql, &params, (column{ .name = "name" }).desc());
    try std.testing.expectEqualStrings("\"name\" DESC", sql.items);
    sql.clearRetainingCapacity();
    try appendProjection(allocator, &sql, &params, (column{ .name = "age" }).sum());
    try std.testing.expectEqualStrings("SUM(\"age\")", sql.items);
    sql.clearRetainingCapacity();
    try appendProjection(allocator, &sql, &params, dslExpr.countStar());
    try std.testing.expectEqualStrings("COUNT(*)", sql.items);
    sql.clearRetainingCapacity();
    try appendProjection(allocator, &sql, &params, (column{ .name = "name" }).lower().projection());
    try std.testing.expectEqualStrings("LOWER(\"name\")", sql.items);
    sql.clearRetainingCapacity();
    try appendProjection(allocator, &sql, &params, (column{ .name = "v" }).cast("INTEGER").projection());
    try std.testing.expectEqualStrings("CAST(\"v\" AS INTEGER)", sql.items);
}
