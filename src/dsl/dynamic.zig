const std = @import("std");
const columnMod = @import("column.zig");
const queryBuilder = @import("query_builder.zig");
const astBuilder = @import("ast_builder.zig");
const dslExpr = @import("expr.zig");

pub const DynamicColumn = columnMod.DynamicColumn;
pub const DynamicQuery = queryBuilder.DynamicQuery;
pub const DynamicMutation = queryBuilder.Mutation;
pub const DynamicUpsert = queryBuilder.UpsertBuilder(void, void);
pub const DynamicResult = @import("../connection/result.zig").Result;

pub const DynamicTable = struct {
    const Self = @This();
    pub const isDynamicTable = true;

    // Borrowed handle: connection must outlive every query built from this
    // table. Re-acquire with db.table() after close/reopen; stale handles
    // are dangling pointers.
    allocator: std.mem.Allocator,
    connection: *anyopaque,
    executeFn: astBuilder.ExecFn,
    compoundExecuteFn: astBuilder.CompoundExecFn,
    derivedExecuteFn: astBuilder.DerivedExecFn,
    schema: []const u8 = "",
    name: []const u8 = "",
    alias: []const u8 = "",

    pub fn init(
        allocator: std.mem.Allocator,
        connection: *anyopaque,
        executeFn: astBuilder.ExecFn,
        compoundExecuteFn: astBuilder.CompoundExecFn,
        derivedExecuteFn: astBuilder.DerivedExecFn,
        schema: []const u8,
        name: []const u8,
    ) Self {
        return Self{
            .allocator = allocator,
            .connection = connection,
            .executeFn = executeFn,
            .compoundExecuteFn = compoundExecuteFn,
            .derivedExecuteFn = derivedExecuteFn,
            .schema = schema,
            .name = name,
        };
    }

    pub fn as(self: Self, alias: []const u8) Self {
        var copy = self;
        copy.alias = alias;
        return copy;
    }

    fn qualifier(self: *const Self) []const u8 {
        if (self.alias.len != 0) return self.alias;
        return self.name;
    }

    pub fn column(self: *const Self, colName: []const u8) DynamicColumn {
        return .{ .name = colName, .schema = self.schema, .table = self.qualifier() };
    }

    fn qb(self: Self) DynamicQuery {
        var q = DynamicQuery.initRaw(self.allocator, self.connection, self.name, self.executeFn, self.compoundExecuteFn, self.derivedExecuteFn);
        q.schema = self.schema;
        q.tableAlias = if (self.alias.len != 0) self.alias else null;
        return q;
    }

    pub fn select(self: Self, cols: anytype) queryBuilder.SelectOut(void, void, @TypeOf(cols)) {
        return self.qb().select(cols);
    }

    pub fn selectAll(self: Self) queryBuilder.Builder(void, void, true) {
        return self.qb().selectAll();
    }

    pub fn countStar(self: Self) DynamicQuery {
        return self.qb().countStar();
    }

    pub fn with(self: Self, name: []const u8, body: []const u8) DynamicQuery {
        return self.qb().with(name, body);
    }

    pub fn withRecursive(self: Self, name: []const u8, base: []const u8, recursive: []const u8) DynamicQuery {
        return self.qb().withRecursive(name, base, recursive);
    }

    pub fn innerJoin(self: Self, other: anytype, on: dslExpr.Expr) DynamicQuery {
        return self.qb().innerJoin(other, on);
    }
    pub fn leftJoin(self: Self, other: anytype, on: dslExpr.Expr) DynamicQuery {
        return self.qb().leftJoin(other, on);
    }
    pub fn rightJoin(self: Self, other: anytype, on: dslExpr.Expr) DynamicQuery {
        return self.qb().rightJoin(other, on);
    }
    pub fn fullJoin(self: Self, other: anytype, on: dslExpr.Expr) DynamicQuery {
        return self.qb().fullJoin(other, on);
    }
    pub fn crossJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().crossJoin(other);
    }
    pub fn joinUsing(self: Self, other: anytype, col: anytype) DynamicQuery {
        return self.qb().joinUsing(other, col);
    }
    pub fn leftJoinUsing(self: Self, other: anytype, col: anytype) DynamicQuery {
        return self.qb().leftJoinUsing(other, col);
    }
    pub fn rightJoinUsing(self: Self, other: anytype, col: anytype) DynamicQuery {
        return self.qb().rightJoinUsing(other, col);
    }
    pub fn fullJoinUsing(self: Self, other: anytype, col: anytype) DynamicQuery {
        return self.qb().fullJoinUsing(other, col);
    }
    pub fn naturalJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().naturalJoin(other);
    }
    pub fn naturalLeftJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().naturalLeftJoin(other);
    }
    pub fn naturalRightJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().naturalRightJoin(other);
    }
    pub fn naturalFullJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().naturalFullJoin(other);
    }

    pub fn insert(self: Self, row: anytype) !DynamicResult {
        return self.qb().insert(row);
    }
    pub fn insertOrIgnore(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrIgnore(row);
    }
    pub fn insertOrReplace(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrReplace(row);
    }
    pub fn insertOrAbort(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrAbort(row);
    }
    pub fn insertOrFail(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrFail(row);
    }
    pub fn insertOrRollback(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrRollback(row);
    }
    pub fn insertSelect(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelect(source);
    }
    pub fn insertSelectOrIgnore(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrIgnore(source);
    }
    pub fn insertSelectOrReplace(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrReplace(source);
    }
    pub fn insertSelectOrAbort(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrAbort(source);
    }
    pub fn insertSelectOrFail(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrFail(source);
    }
    pub fn insertSelectOrRollback(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrRollback(source);
    }

    pub fn insertFrom(self: Self, source: anytype, mapping: anytype) !DynamicResult {
        return self.qb().insertFrom(source, mapping);
    }

    pub fn update(self: Self, assignments: anytype) !DynamicMutation {
        return self.qb().update(assignments);
    }

    pub fn delete(self: Self) DynamicMutation {
        return self.qb().delete();
    }

    pub fn onConflict(self: Self, target: anytype) DynamicUpsert {
        return self.qb().onConflict(target);
    }
    pub fn doNothing(self: Self) DynamicUpsert {
        return self.qb().doNothing();
    }
    pub fn doUpdate(self: Self, assignments: anytype) !DynamicUpsert {
        return self.qb().doUpdate(assignments);
    }

    pub fn returning(self: Self, cols: anytype) DynamicQuery {
        return self.qb().returning(cols);
    }

    pub fn asSubquery(self: *const Self, alias: []const u8) !DynamicQuery {
        var q = self.qb();
        return q.asSubquery(alias);
    }
};

pub const SchemaHandle = struct {
    allocator: std.mem.Allocator,
    connection: *anyopaque,
    executeFn: astBuilder.ExecFn,
    compoundExecuteFn: astBuilder.CompoundExecFn,
    derivedExecuteFn: astBuilder.DerivedExecFn,
    name: []const u8 = "",

    pub fn table(self: @This(), tableName: []const u8) DynamicTable {
        return DynamicTable.init(self.allocator, self.connection, self.executeFn, self.compoundExecuteFn, self.derivedExecuteFn, self.name, tableName);
    }
};

test "dynamic table columns carry table identity" {
    const std_testing = @import("std").testing;
    var t = DynamicTable.init(std_testing.allocator, undefined, undefined, undefined, undefined, "", "users");
    const id = t.column("id");
    try std_testing.expectEqualStrings("id", id.name);
    try std_testing.expectEqualStrings("", id.schema);
    try std_testing.expectEqualStrings("users", id.table);
    try std_testing.expectEqualStrings("users", t.name);
    try std_testing.expect(t.alias.len == 0);
    const ref = columnMod.dynRef(id);
    try std_testing.expectEqualStrings("users", ref.table);
    try std_testing.expectEqualStrings("", ref.schema);
    try std_testing.expectEqualStrings("id", ref.name);
}

test "schema-qualified dynamic tables keep schema identity" {
    const std_testing = @import("std").testing;
    var t = DynamicTable.init(std_testing.allocator, undefined, undefined, undefined, undefined, "archive", "users");
    try std_testing.expectEqualStrings("archive", t.schema);
    try std_testing.expectEqualStrings("users", t.name);
    const id = t.column("id");
    const ref = columnMod.dynRef(id);
    try std_testing.expectEqualStrings("archive", ref.schema);
    try std_testing.expectEqualStrings("users", ref.table);
    try std_testing.expectEqualStrings("id", ref.name);
}

test "dynamic table aliases rebind column qualifiers" {
    const std_testing = @import("std").testing;
    var t = DynamicTable.init(std_testing.allocator, undefined, undefined, undefined, undefined, "", "users");
    const u = t.as("u");
    try std_testing.expectEqualStrings("u", u.alias);
    try std_testing.expectEqualStrings("users", u.name);
    const id = u.column("id");
    const ref = columnMod.dynRef(id);
    try std_testing.expectEqualStrings("u", ref.table);
    try std_testing.expectEqualStrings("id", ref.name);
}
