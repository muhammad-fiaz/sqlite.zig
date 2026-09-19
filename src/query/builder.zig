const std = @import("std");
const types = @import("../core/types.zig");
const expr_mod = @import("expr.zig");
const Expr = expr_mod.Expr;
const q = @import("q.zig");
const model = @import("model.zig");

pub fn tableNameFromType(comptime T: type) []const u8 {
    return model.tableName(T);
}

pub fn storageClassFromType(comptime T: type) types.StorageClass {
    const info = @typeInfo(T);
    if (info == .int) return .integer;
    if (info == .float) return .real;
    if (info == .bool) return .integer;
    if (info == .pointer) {
        if (info.pointer.size == .slice and info.pointer.child == u8) return .text;
    }
    return .blob;
}

pub fn colExpr(comptime T: type, comptime field: []const u8) Expr {
    return q.col(tableNameFromType(T), field);
}

pub fn colExprTyped(comptime T: type, comptime field: []const u8) Expr {
    const info = @typeInfo(T).@"struct";
    comptime {
        for (0..info.field_names.len) |i| {
            if (std.mem.eql(u8, info.field_names[i], field)) {
                return q.colTyped(tableNameFromType(T), field, storageClassFromType(info.field_types[i]));
            }
        }
        @compileError("Field '" ++ field ++ "' not found in type " ++ @typeName(T));
    }
}

pub fn SelectQuery(comptime Table: type) type {
    return struct {
        const Self = @This();
        pub const TableType = Table;
        pub const table_name = tableNameFromType(Table);

        allocator: std.mem.Allocator,
        where_clauses: std.ArrayList(Expr),
        joins: std.ArrayList(expr_mod.JoinClause),
        order_by: std.ArrayList(expr_mod.OrderByClause),
        group_by_columns: std.ArrayList(Expr),
        having_clause: ?Expr,
        limit_val: ?usize,
        offset_val: ?usize,
        distinct_val: bool,
        select_columns: std.ArrayList(Expr),
        has_custom_select: bool,
        ctes: std.ArrayList(expr_mod.CteExpr),
        returning_columns: std.ArrayList(Expr),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .where_clauses = .empty,
                .joins = .empty,
                .order_by = .empty,
                .group_by_columns = .empty,
                .having_clause = null,
                .limit_val = null,
                .offset_val = null,
                .distinct_val = false,
                .select_columns = .empty,
                .has_custom_select = false,
                .ctes = .empty,
                .returning_columns = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.where_clauses.items) |clause| clause.deinit(self.allocator);
            self.where_clauses.deinit(self.allocator);
            for (self.joins.items) |*j| {
                if (j.on_condition) |oc| oc.deinit(self.allocator);
            }
            self.joins.deinit(self.allocator);
            for (self.order_by.items) |ob| ob.expr.deinit(self.allocator);
            self.order_by.deinit(self.allocator);
            for (self.group_by_columns.items) |col| col.deinit(self.allocator);
            self.group_by_columns.deinit(self.allocator);
            for (self.select_columns.items) |col| col.deinit(self.allocator);
            self.select_columns.deinit(self.allocator);
            for (self.returning_columns.items) |col| col.deinit(self.allocator);
            self.returning_columns.deinit(self.allocator);
            self.ctes.deinit(self.allocator);
        }

        pub fn where(self: *Self, condition: Expr) !void {
            try self.where_clauses.append(self.allocator, condition);
        }

        pub fn whereField(self: *Self, comptime field: []const u8, op: expr_mod.BinOp, rhs: Expr) !void {
            try self.where_clauses.append(self.allocator, q.binaryOp(self.allocator, op, colExpr(Table, field), rhs));
        }

        pub fn join(self: *Self, comptime Other: type) JoinBuilder(Self, Other) {
            return .{
                .parent = self,
                .other_table = tableNameFromType(Other),
                .join_type = .inner,
            };
        }

        pub fn leftJoin(self: *Self, comptime Other: type) JoinBuilder(Self, Other) {
            return .{
                .parent = self,
                .other_table = tableNameFromType(Other),
                .join_type = .left,
            };
        }

        pub fn rightJoin(self: *Self, comptime Other: type) JoinBuilder(Self, Other) {
            return .{
                .parent = self,
                .other_table = tableNameFromType(Other),
                .join_type = .right,
            };
        }

        pub fn fullJoin(self: *Self, comptime Other: type) JoinBuilder(Self, Other) {
            return .{
                .parent = self,
                .other_table = tableNameFromType(Other),
                .join_type = .full,
            };
        }

        pub fn crossJoin(self: *Self, comptime Other: type) JoinBuilder(Self, Other) {
            return .{
                .parent = self,
                .other_table = tableNameFromType(Other),
                .join_type = .cross,
            };
        }

        pub fn select(self: *Self, columns: []const Expr) !void {
            self.has_custom_select = true;
            for (columns) |col| {
                try self.select_columns.append(self.allocator, col);
            }
        }

        pub fn orderBy(self: *Self, column: Expr, direction: expr_mod.SortDirection) !void {
            try self.order_by.append(self.allocator, .{
                .expr = column,
                .direction = direction,
            });
        }

        pub fn orderByAsc(self: *Self, column: Expr) !void {
            try self.orderBy(column, .asc);
        }

        pub fn orderByDesc(self: *Self, column: Expr) !void {
            try self.orderBy(column, .desc);
        }

        pub fn groupBy(self: *Self, columns: []const Expr) !void {
            for (columns) |col| {
                try self.group_by_columns.append(self.allocator, col);
            }
        }

        pub fn having(self: *Self, condition: Expr) void {
            self.having_clause = condition;
        }

        pub fn limit(self: *Self, count: usize) void {
            self.limit_val = count;
        }

        pub fn offset(self: *Self, count: usize) void {
            self.offset_val = count;
        }

        pub fn distinct(self: *Self) void {
            self.distinct_val = true;
        }

        pub fn with(self: *Self, name: []const u8, query: expr_mod.SelectExpr, recursive: bool) !void {
            try self.ctes.append(self.allocator, .{
                .name = name,
                .query = query,
                .recursive = recursive,
            });
        }

        pub fn returning(self: *Self, columns: []const Expr) !void {
            for (columns) |col| {
                try self.returning_columns.append(self.allocator, col);
            }
        }
    };
}

pub fn JoinBuilder(comptime Parent: type, comptime Other: type) type {
    return struct {
        const Self = @This();
        pub const TableType = Parent.TableType;

        parent: *Parent,
        other_table: []const u8,
        join_type: expr_mod.JoinType,

        pub fn on(self: *Self, lhs: Expr, rhs: Expr) void {
            const condition = q.eq(self.parent.allocator, lhs, rhs);
            self.parent.joins.append(self.parent.allocator, .{
                .join_type = self.join_type,
                .table_name = self.other_table,
                .on_condition = condition,
            }) catch {};
        }

        pub fn onFields(self: *Self, comptime lhs_field: []const u8, comptime rhs_field: []const u8) void {
            self.on(
                colExpr(Parent.TableType, lhs_field),
                colExpr(Other, rhs_field),
            );
        }
    };
}

pub fn InsertQuery(comptime Table: type) type {
    return struct {
        const Self = @This();
        pub const TableType = Table;
        pub const table_name = tableNameFromType(Table);

        allocator: std.mem.Allocator,
        columns: std.ArrayList([]const u8),
        values_rows: std.ArrayList(std.ArrayList(Expr)),
        or_ignore_val: bool,
        on_conflict_update: ?OnConflictUpdate,

        pub const OnConflictUpdate = struct {
            target_columns: std.ArrayList([]const u8),
            update_columns: std.ArrayList(expr_mod.UpdateSetClause),
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .columns = .empty,
                .values_rows = .empty,
                .or_ignore_val = false,
                .on_conflict_update = null,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.values_rows.items) |*row| {
                row.deinit(self.allocator);
            }
            self.values_rows.deinit(self.allocator);
            self.columns.deinit(self.allocator);
            if (self.on_conflict_update) |*oc| {
                oc.target_columns.deinit(self.allocator);
                oc.update_columns.deinit(self.allocator);
            }
        }

        pub fn orIgnore(self: *Self) void {
            self.or_ignore_val = true;
        }

        pub fn orReplace(self: *Self) void {
            self.or_ignore_val = true;
        }

        pub fn onConflictDoUpdate(self: *Self, target_columns: []const []const u8) !void {
            self.on_conflict_update = .{
                .target_columns = .empty,
                .update_columns = .empty,
            };
            for (target_columns) |col| {
                try self.on_conflict_update.?.target_columns.append(self.allocator, col);
            }
        }

        pub fn conflictUpdateSet(self: *Self, column: []const u8, val: Expr) !void {
            if (self.on_conflict_update) |*oc| {
                try oc.update_columns.append(self.allocator, .{
                    .column = column,
                    .value = val,
                });
            }
        }

        pub fn value(self: *Self, row: anytype) !void {
            const row_info = @typeInfo(@TypeOf(row)).@"struct";

            if (self.columns.items.len == 0) {
                inline for (row_info.field_names) |name| {
                    try self.columns.append(self.allocator, name);
                }
            }

            var vals: std.ArrayList(Expr) = .empty;
            errdefer vals.deinit(self.allocator);

            inline for (row_info.field_names) |name| {
                const field_val = @field(row, name);
                try vals.append(self.allocator, q.val(field_val));
            }

            try self.values_rows.append(self.allocator, vals);
        }
    };
}

pub fn UpdateQuery(comptime Table: type) type {
    return struct {
        const Self = @This();
        pub const TableType = Table;
        pub const table_name = tableNameFromType(Table);

        allocator: std.mem.Allocator,
        where_clauses: std.ArrayList(Expr),
        set_clauses: std.ArrayList(expr_mod.UpdateSetClause),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .where_clauses = .empty,
                .set_clauses = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.where_clauses.items) |clause| clause.deinit(self.allocator);
            self.where_clauses.deinit(self.allocator);
            self.set_clauses.deinit(self.allocator);
        }

        pub fn where(self: *Self, condition: Expr) !void {
            try self.where_clauses.append(self.allocator, condition);
        }

        pub fn set(self: *Self, values: anytype) !void {
            const info = @typeInfo(@TypeOf(values)).@"struct";
            inline for (info.field_names) |name| {
                try self.set_clauses.append(self.allocator, .{
                    .column = name,
                    .value = q.val(@field(values, name)),
                });
            }
        }
    };
}

pub fn DeleteQuery(comptime Table: type) type {
    return struct {
        const Self = @This();
        pub const TableType = Table;
        pub const table_name = tableNameFromType(Table);

        allocator: std.mem.Allocator,
        where_clauses: std.ArrayList(Expr),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .where_clauses = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.where_clauses.items) |clause| clause.deinit(self.allocator);
            self.where_clauses.deinit(self.allocator);
        }

        pub fn where(self: *Self, condition: Expr) !void {
            try self.where_clauses.append(self.allocator, condition);
        }
    };
}

test "SelectQuery init and where" {
    const User = struct {
        name: []const u8,
        age: i64,
    };

    var sq = SelectQuery(User).init(std.testing.allocator);
    defer sq.deinit();

    const gt_expr = q.gt(std.testing.allocator, colExpr(User, "age"), q.val(@as(i64, 18)));
    try sq.where(gt_expr);
    try std.testing.expectEqual(@as(usize, 1), sq.where_clauses.items.len);
}

test "InsertQuery value" {
    const User = struct {
        name: []const u8,
        age: i64,
    };

    var iq = InsertQuery(User).init(std.testing.allocator);
    defer iq.deinit();

    try iq.value(.{ .name = "Alice", .age = 30 });
    try std.testing.expectEqual(@as(usize, 1), iq.values_rows.items.len);
    try std.testing.expectEqual(@as(usize, 2), iq.columns.items.len);
}

test "UpdateQuery set" {
    const User = struct {
        name: []const u8,
        age: i64,
    };

    var uq = UpdateQuery(User).init(std.testing.allocator);
    defer uq.deinit();

    try uq.set(.{ .name = "Bob" });
    try std.testing.expectEqual(@as(usize, 1), uq.set_clauses.items.len);
}

test "DeleteQuery where" {
    const User = struct {
        name: []const u8,
        age: i64,
    };

    var dq = DeleteQuery(User).init(std.testing.allocator);
    defer dq.deinit();

    const eq_expr = q.eq(std.testing.allocator, colExpr(User, "name"), q.val("Alice"));
    try dq.where(eq_expr);
    try std.testing.expectEqual(@as(usize, 1), dq.where_clauses.items.len);
}

test "JoinBuilder" {
    const User = struct {
        pub const table_name = "users";
        id: i64,
        name: []const u8,
    };
    const Post = struct {
        pub const table_name = "posts";
        id: i64,
        user_id: i64,
        title: []const u8,
    };

    var sq = SelectQuery(User).init(std.testing.allocator);
    defer sq.deinit();

    var jb = sq.join(Post);
    jb.onFields("id", "user_id");
    try std.testing.expectEqual(@as(usize, 1), sq.joins.items.len);
    try std.testing.expectEqual(expr_mod.JoinType.inner, sq.joins.items[0].join_type);
    try std.testing.expectEqualStrings("posts", sq.joins.items[0].table_name);
    try std.testing.expect(sq.joins.items[0].on_condition != null);
}

test "SelectQuery with multiple joins" {
    const User = struct {
        pub const table_name = "users";
        id: i64,
        name: []const u8,
    };
    const Post = struct {
        pub const table_name = "posts";
        id: i64,
        user_id: i64,
        title: []const u8,
    };
    const Comment = struct {
        pub const table_name = "comments";
        id: i64,
        post_id: i64,
        body: []const u8,
    };

    var sq = SelectQuery(User).init(std.testing.allocator);
    defer sq.deinit();

    var jb1 = sq.join(Post);
    jb1.onFields("id", "user_id");

    var jb2 = sq.join(Comment);
    jb2.onFields("id", "post_id");

    try std.testing.expectEqual(@as(usize, 2), sq.joins.items.len);
    try std.testing.expectEqualStrings("posts", sq.joins.items[0].table_name);
    try std.testing.expectEqualStrings("comments", sq.joins.items[1].table_name);
}

test "SelectQuery with left join" {
    const User = struct {
        pub const table_name = "users";
        id: i64,
        name: []const u8,
    };
    const Post = struct {
        pub const table_name = "posts";
        id: i64,
        user_id: i64,
        title: []const u8,
    };

    var sq = SelectQuery(User).init(std.testing.allocator);
    defer sq.deinit();

    var jb = sq.leftJoin(Post);
    jb.onFields("id", "user_id");

    try std.testing.expectEqual(@as(usize, 1), sq.joins.items.len);
    try std.testing.expectEqual(expr_mod.JoinType.left, sq.joins.items[0].join_type);
}

test "InsertQuery with orIgnore" {
    const User = struct {
        name: []const u8,
        age: i64,
    };

    var iq = InsertQuery(User).init(std.testing.allocator);
    defer iq.deinit();

    iq.orIgnore();
    try std.testing.expect(iq.or_ignore_val);
}

test "InsertQuery with multiple values" {
    const User = struct {
        name: []const u8,
        age: i64,
    };

    var iq = InsertQuery(User).init(std.testing.allocator);
    defer iq.deinit();

    try iq.value(.{ .name = "Alice", .age = 30 });
    try iq.value(.{ .name = "Bob", .age = 25 });
    try iq.value(.{ .name = "Charlie", .age = 35 });
    try std.testing.expectEqual(@as(usize, 3), iq.values_rows.items.len);
    try std.testing.expectEqual(@as(usize, 2), iq.columns.items.len);
}

test "UpdateQuery with multiple set clauses" {
    const User = struct {
        name: []const u8,
        age: i64,
        email: []const u8,
    };

    var uq = UpdateQuery(User).init(std.testing.allocator);
    defer uq.deinit();

    try uq.set(.{ .name = "Bob", .age = 31, .email = "bob@example.com" });
    try std.testing.expectEqual(@as(usize, 3), uq.set_clauses.items.len);
}

test "DeleteQuery with multiple where clauses" {
    const User = struct {
        name: []const u8,
        age: i64,
    };

    var dq = DeleteQuery(User).init(std.testing.allocator);
    defer dq.deinit();

    const cond1 = q.eq(std.testing.allocator, colExpr(User, "name"), q.val("Alice"));
    const cond2 = q.gt(std.testing.allocator, colExpr(User, "age"), q.val(@as(i64, 18)));
    try dq.where(cond1);
    try dq.where(cond2);
    try std.testing.expectEqual(@as(usize, 2), dq.where_clauses.items.len);
}
