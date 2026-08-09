const Value = @import("../vm/value.zig").Value;

pub const CompareOp = enum { equal, not_equal, less, less_equal, greater, greater_equal, like, not_like, is_null, is_not_null, is_value, is_not_value, between, in, not_in, exists, not_exists };

pub const Expr = union(enum) {
    literal: Value,
    identifier: []const u8,
    parameter: usize,
    wildcard,
    function: struct { name: []const u8, argument: *const Expr },
    binary: struct { op: BinaryOp, left: *const Expr, right: *const Expr },
};
pub const BinaryOp = enum { add, subtract };

pub const Condition = struct { column: []const u8, op: CompareOp, value: Expr, value2: ?Expr = null, subquery: ?[]const u8 = null, list_values: []const Expr = &.{}, join_or: bool = false };
pub const Having = struct { left: Expr, op: CompareOp, right: Expr };
pub const Conditions = []const Condition;
pub const Order = struct { column: []const u8, descending: bool };
pub const JoinKind = enum { inner, left, right, full, cross };
pub const Join = struct { kind: JoinKind, table: []const u8, left_table: []const u8, left_column: []const u8, right_table: []const u8, right_column: []const u8 };
pub const Projection = struct { expr: Expr, alias: ?[]const u8 = null };
pub const ForeignKeyDef = struct { table: []const u8, column: []const u8, on_delete: ReferentialAction = .restrict, on_update: ReferentialAction = .restrict };
pub const ReferentialAction = enum { restrict, cascade, set_null };
pub const ColumnDef = struct { name: []const u8, type_name: []const u8, primary_key: bool = false, not_null: bool = false, unique: bool = false, foreign_key: ?ForeignKeyDef = null, default_value: ?Value = null };
pub const TableForeignKeyDef = struct { columns: []const []const u8, table: []const u8, referenced_columns: []const []const u8, on_delete: ReferentialAction = .restrict, on_update: ReferentialAction = .restrict };
pub const TableConstraint = union(enum) { primary_key: []const []const u8, unique: []const []const u8, foreign_key: TableForeignKeyDef };
pub const IndexDef = struct { name: []const u8, table: []const u8, columns: []const []const u8, unique: bool = false, if_not_exists: bool = false };
pub const TriggerEvent = enum { insert, update, delete };
pub const TriggerDef = struct { name: []const u8, table: []const u8, event: TriggerEvent, body: []const u8, if_not_exists: bool = false };
pub const VirtualTableDef = struct { name: []const u8, module: []const u8, arguments: []const []const u8, if_not_exists: bool = false };
pub const CteDef = struct { name: []const u8, query_sql: []const u8, recursive_sql: ?[]const u8 = null };
pub const WithSelect = struct { ctes: []CteDef, body_sql: []const u8, recursive: bool = false };
pub const InsertConflict = enum { none, ignore, replace, update };
pub const UpsertResult = enum { no_conflict, skipped, updated };
pub const UpdateFrom = struct { table: []const u8, left_table: []const u8, left_column: []const u8, right_table: []const u8, right_column: []const u8 };
pub const AlterTable = union(enum) {
    add_column: struct { table: []const u8, definition: ColumnDef },
    rename_table: struct { table: []const u8, new_name: []const u8 },
    rename_column: struct { table: []const u8, old_name: []const u8, new_name: []const u8 },
    drop_column: struct { table: []const u8, column: []const u8 },
};

pub const Statement = union(enum) {
    create_table: struct { name: []const u8, columns: []ColumnDef, constraints: []TableConstraint = &.{}, if_not_exists: bool = false },
    create_index: IndexDef,
    create_view: struct { name: []const u8, sql: []const u8, if_not_exists: bool = false },
    create_trigger: TriggerDef,
    create_virtual_table: VirtualTableDef,
    with_select: WithSelect,
    explain_query_plan: []const u8,
    pragma: struct { name: []const u8, value: ?[]const u8 = null },
    alter_table: AlterTable,
    drop_table: struct { name: []const u8, if_exists: bool = false },
    drop_index: struct { name: []const u8, if_exists: bool = false },
    drop_view: struct { name: []const u8, if_exists: bool = false },
    drop_trigger: struct { name: []const u8, if_exists: bool = false },
    insert: struct { table: []const u8, columns: []const []const u8, rows: []const []const Expr, select_sql: ?[]const u8 = null, conflict: InsertConflict = .none, upsert_columns: []const []const u8 = &.{}, upsert_values: []const Expr = &.{}, upsert_where: ?Conditions = null },
    select: struct { projections: []const Projection, table: ?[]const u8, join: ?Join = null, condition: ?Conditions, group_by: ?[]const u8 = null, having: ?Having = null, order: ?Order, limit: ?usize, offset: ?usize = null, distinct: bool = false },
    update: struct { table: []const u8, columns: []const []const u8, values: []const Expr, condition: ?Conditions, from: ?UpdateFrom = null },
    delete: struct { table: []const u8, condition: ?Conditions },
    begin,
    commit,
    rollback,
    savepoint: []const u8,
    release: []const u8,
    rollback_to: []const u8,

    pub fn isQuery(self: Statement) bool {
        return self == .select or self == .with_select or self == .explain_query_plan;
    }
};

pub fn deinit(allocator: anytype, statement: *Statement) void {
    const freeExpr = struct {
        fn run(gpa: anytype, expr: Expr) void {
            switch (expr) {
                .function => |call| {
                    run(gpa, call.argument.*);
                    gpa.destroy(call.argument);
                },
                .binary => |binary| {
                    run(gpa, binary.left.*);
                    run(gpa, binary.right.*);
                    gpa.destroy(binary.left);
                    gpa.destroy(binary.right);
                },
                else => {},
            }
        }
    }.run;
    switch (statement.*) {
        .create_table => |value| {
            allocator.free(value.columns);
            for (value.constraints) |constraint| switch (constraint) {
                .primary_key => |columns| allocator.free(columns),
                .unique => |columns| allocator.free(columns),
                .foreign_key => |foreign_key| {
                    allocator.free(foreign_key.columns);
                    allocator.free(foreign_key.referenced_columns);
                },
            };
            allocator.free(value.constraints);
        },
        .create_index => |value| {
            allocator.free(value.columns);
        },
        .create_view => {},
        .create_trigger => {},
        .create_virtual_table => |value| allocator.free(value.arguments),
        .with_select => |value| allocator.free(value.ctes),
        .explain_query_plan => {},
        .pragma => {},
        .insert => |value| {
            allocator.free(value.columns);
            for (value.rows) |row| {
                for (row) |expr| freeExpr(allocator, expr);
                allocator.free(row);
            }
            allocator.free(value.rows);
            allocator.free(value.upsert_columns);
            for (value.upsert_values) |expr| freeExpr(allocator, expr);
            allocator.free(value.upsert_values);
            if (value.upsert_where) |conditions| {
                for (conditions) |condition| {
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    for (condition.list_values) |item| freeExpr(allocator, item);
                    if (condition.list_values.len != 0) allocator.free(condition.list_values);
                }
                allocator.free(conditions);
            }
        },
        .select => |value| {
            for (value.projections) |projection| freeExpr(allocator, projection.expr);
            allocator.free(value.projections);
            if (value.condition) |conditions| {
                for (conditions) |condition| {
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    for (condition.list_values) |item| freeExpr(allocator, item);
                    if (condition.list_values.len != 0) allocator.free(condition.list_values);
                }
                allocator.free(conditions);
            }
            if (value.having) |having| {
                freeExpr(allocator, having.left);
                freeExpr(allocator, having.right);
            }
        },
        .update => |value| {
            allocator.free(value.columns);
            for (value.values) |expr| freeExpr(allocator, expr);
            allocator.free(value.values);
            if (value.condition) |conditions| {
                for (conditions) |condition| {
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    for (condition.list_values) |item| freeExpr(allocator, item);
                    if (condition.list_values.len != 0) allocator.free(condition.list_values);
                }
                allocator.free(conditions);
            }
        },
        .delete => |value| if (value.condition) |conditions| {
            for (conditions) |condition| {
                freeExpr(allocator, condition.value);
                if (condition.value2) |second| freeExpr(allocator, second);
                for (condition.list_values) |item| freeExpr(allocator, item);
                if (condition.list_values.len != 0) allocator.free(condition.list_values);
            }
            allocator.free(conditions);
        },
        else => {},
    }
}
