const Value = @import("../vm/value.zig").Value;

pub const CompareOp = enum { equal, not_equal, less, less_equal, greater, greater_equal };

pub const Expr = union(enum) {
    literal: Value,
    identifier: []const u8,
    parameter: usize,
    wildcard,
};

pub const Condition = struct { column: []const u8, op: CompareOp, value: Expr };
pub const Order = struct { column: []const u8, descending: bool };
pub const Projection = struct { expr: Expr, alias: ?[]const u8 = null };
pub const ColumnDef = struct { name: []const u8, type_name: []const u8, primary_key: bool = false, not_null: bool = false };

pub const Statement = union(enum) {
    create_table: struct { name: []const u8, columns: []ColumnDef, if_not_exists: bool = false },
    drop_table: []const u8,
    insert: struct { table: []const u8, columns: []const []const u8, rows: []const []const Expr },
    select: struct { projections: []const Projection, table: ?[]const u8, condition: ?Condition, order: ?Order, limit: ?usize },
    update: struct { table: []const u8, columns: []const []const u8, values: []const Expr, condition: ?Condition },
    delete: struct { table: []const u8, condition: ?Condition },
    begin,
    commit,
    rollback,

    pub fn isQuery(self: Statement) bool {
        return self == .select;
    }
};

pub fn deinit(allocator: anytype, statement: *Statement) void {
    switch (statement.*) {
        .create_table => |value| allocator.free(value.columns),
        .insert => |value| {
            allocator.free(value.columns);
            for (value.rows) |row| allocator.free(row);
            allocator.free(value.rows);
        },
        .select => |value| allocator.free(value.projections),
        .update => |value| {
            allocator.free(value.columns);
            allocator.free(value.values);
        },
        else => {},
    }
}
