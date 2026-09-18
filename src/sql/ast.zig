const Value = @import("../vm/value.zig").Value;

pub const CompareOp = enum { equal, notEqual, less, lessEqual, greater, greaterEqual, like, notLike, glob, notGlob, regexp, notRegexp, match, notMatch, isNull, isNotNull, isValue, isNotValue, isDistinct, isNotDistinct, between, notBetween, in, notIn, exists, notExists };

pub const Expr = union(enum) {
    literal: Value,
    identifier: []const u8,
    parameter: usize,
    wildcard,
    function: struct { name: []const u8, argument: *const Expr, argument2: ?*const Expr = null, argument3: ?*const Expr = null, distinct: bool = false },
    binary: struct { op: BinaryOp, left: *const Expr, right: *const Expr },
    unary: struct { op: UnaryOp, expr: *const Expr },
    caseExpr: struct { base: ?*const Expr, whens: []CaseWhen, otherwise: ?*const Expr = null },
    patternMatch: struct { value: *const Expr, pattern: *const Expr, escape: ?*const Expr = null, negated: bool = false, glob: bool = false, isRegexp: bool = false, isMatch: bool = false },
    collate: struct { expr: *const Expr, name: []const u8 },
};
pub const BinaryOp = enum { add, subtract, multiply, divide, modulo, concat, bitAnd, bitOr, shiftLeft, shiftRight, equal, notEqual, less, lessEqual, greater, greaterEqual, logicalAnd, logicalOr };
pub const UnaryOp = enum { negate, positive, bitNot, logicalNot };
pub const CaseWhen = struct { condition: Expr, result: Expr };

pub const Condition = struct { column: []const u8, op: CompareOp, value: Expr, value2: ?Expr = null, subquery: ?[]const u8 = null, listValues: []const Expr = &.{}, joinOr: bool = false, leftExpr: ?Expr = null, escape: ?Expr = null, negated: bool = false, collate: ?[]const u8 = null };
pub const Having = struct { left: Expr, op: CompareOp, right: Expr };
pub const Conditions = []const Condition;
pub const Order = struct { column: []const u8, descending: bool };
pub const JoinKind = enum { inner, left, right, full, cross };
pub const Join = struct { kind: JoinKind, table: []const u8, leftTable: []const u8, leftColumn: []const u8, rightTable: []const u8, rightColumn: []const u8 };
pub const Projection = struct { expr: Expr, alias: ?[]const u8 = null };
pub const ForeignKeyDef = struct { table: []const u8, column: []const u8, onDelete: ReferentialAction = .restrict, onUpdate: ReferentialAction = .restrict };
pub const ReferentialAction = enum { restrict, cascade, setNull };
pub const ColumnDef = struct { name: []const u8, typeName: []const u8, primaryKey: bool = false, notNull: bool = false, unique: bool = false, foreignKey: ?ForeignKeyDef = null, defaultValue: ?Value = null };
pub const TableForeignKeyDef = struct { columns: []const []const u8, table: []const u8, referencedColumns: []const []const u8, onDelete: ReferentialAction = .restrict, onUpdate: ReferentialAction = .restrict };
pub const TableConstraint = union(enum) { primaryKey: []const []const u8, unique: []const []const u8, foreignKey: TableForeignKeyDef };
pub const IndexDef = struct { name: []const u8, table: []const u8, columns: []const []const u8, unique: bool = false, ifNotExists: bool = false };
pub const TriggerEvent = enum { insert, update, delete };
pub const TriggerDef = struct { name: []const u8, table: []const u8, event: TriggerEvent, body: []const u8, ifNotExists: bool = false };
pub const VirtualTableDef = struct { name: []const u8, module: []const u8, arguments: []const []const u8, ifNotExists: bool = false };
pub const CteDef = struct { name: []const u8, querySql: []const u8, recursiveSql: ?[]const u8 = null };
pub const WithSelect = struct { ctes: []CteDef, bodySql: []const u8, recursive: bool = false };
pub const InsertConflict = enum { none, ignore, replace, update };
pub const UpsertResult = enum { noConflict, skipped, updated };
pub const UpdateFrom = struct { table: []const u8, leftTable: []const u8, leftColumn: []const u8, rightTable: []const u8, rightColumn: []const u8 };
pub const AlterTable = union(enum) {
    addColumn: struct { table: []const u8, definition: ColumnDef },
    renameTable: struct { table: []const u8, newName: []const u8 },
    renameColumn: struct { table: []const u8, oldName: []const u8, newName: []const u8 },
    dropColumn: struct { table: []const u8, column: []const u8 },
};

pub const Statement = union(enum) {
    createTable: struct { name: []const u8, columns: []ColumnDef, constraints: []TableConstraint = &.{}, ifNotExists: bool = false },
    createIndex: IndexDef,
    createView: struct { name: []const u8, sql: []const u8, ifNotExists: bool = false },
    createTrigger: TriggerDef,
    createVirtualTable: VirtualTableDef,
    withSelect: WithSelect,
    explainQueryPlan: []const u8,
    pragma: struct { name: []const u8, value: ?[]const u8 = null },
    alterTable: AlterTable,
    dropTable: struct { name: []const u8, ifExists: bool = false },
    dropIndex: struct { name: []const u8, ifExists: bool = false },
    dropView: struct { name: []const u8, ifExists: bool = false },
    dropTrigger: struct { name: []const u8, ifExists: bool = false },
    insert: struct { table: []const u8, columns: []const []const u8, rows: []const []const Expr, selectSql: ?[]const u8 = null, conflict: InsertConflict = .none, upsertColumns: []const []const u8 = &.{}, upsertValues: []const Expr = &.{}, upsertWhere: ?Conditions = null },
    select: struct { projections: []const Projection, table: ?[]const u8, join: ?Join = null, condition: ?Conditions, groupBy: ?[]const u8 = null, having: ?Having = null, order: ?Order, limit: ?usize, offset: ?usize = null, distinct: bool = false },
    update: struct { table: []const u8, columns: []const []const u8, values: []const Expr, condition: ?Conditions, from: ?UpdateFrom = null },
    delete: struct { table: []const u8, condition: ?Conditions },
    begin,
    commit,
    rollback,
    savepoint: []const u8,
    release: []const u8,
    rollbackTo: []const u8,

    pub fn isQuery(self: Statement) bool {
        return self == .select or self == .withSelect or self == .explainQueryPlan;
    }
};

pub fn deinit(allocator: anytype, statement: *Statement) void {
    const freeExpr = struct {
        fn run(gpa: anytype, expr: Expr) void {
            switch (expr) {
                .function => |call| {
                    run(gpa, call.argument.*);
                    gpa.destroy(call.argument);
                    if (call.argument2) |argument| {
                        run(gpa, argument.*);
                        gpa.destroy(argument);
                    }
                    if (call.argument3) |argument| {
                        run(gpa, argument.*);
                        gpa.destroy(argument);
                    }
                },
                .binary => |binary| {
                    run(gpa, binary.left.*);
                    run(gpa, binary.right.*);
                    gpa.destroy(binary.left);
                    gpa.destroy(binary.right);
                },
                .unary => |unary| {
                    run(gpa, unary.expr.*);
                    gpa.destroy(unary.expr);
                },
                .caseExpr => |caseBlock| {
                    if (caseBlock.base) |base| {
                        run(gpa, base.*);
                        gpa.destroy(base);
                    }
                    for (caseBlock.whens) |when| {
                        run(gpa, when.condition);
                        run(gpa, when.result);
                    }
                    gpa.free(caseBlock.whens);
                    if (caseBlock.otherwise) |otherwise| {
                        run(gpa, otherwise.*);
                        gpa.destroy(otherwise);
                    }
                },
                .patternMatch => |match| {
                    run(gpa, match.value.*);
                    gpa.destroy(match.value);
                    run(gpa, match.pattern.*);
                    gpa.destroy(match.pattern);
                    if (match.escape) |escape| {
                        run(gpa, escape.*);
                        gpa.destroy(escape);
                    }
                },
                .collate => |node| {
                    run(gpa, node.expr.*);
                    gpa.destroy(node.expr);
                },
                else => {},
            }
        }
    }.run;
    switch (statement.*) {
        .createTable => |value| {
            allocator.free(value.columns);
            for (value.constraints) |constraint| switch (constraint) {
                .primaryKey => |columns| allocator.free(columns),
                .unique => |columns| allocator.free(columns),
                .foreignKey => |foreignKey| {
                    allocator.free(foreignKey.columns);
                    allocator.free(foreignKey.referencedColumns);
                },
            };
            allocator.free(value.constraints);
        },
        .createIndex => |value| {
            allocator.free(value.columns);
        },
        .createView => {},
        .createTrigger => {},
        .createVirtualTable => |value| allocator.free(value.arguments),
        .withSelect => |value| allocator.free(value.ctes),
        .explainQueryPlan => {},
        .pragma => {},
        .insert => |value| {
            allocator.free(value.columns);
            for (value.rows) |row| {
                for (row) |expr| freeExpr(allocator, expr);
                allocator.free(row);
            }
            allocator.free(value.rows);
            allocator.free(value.upsertColumns);
            for (value.upsertValues) |expr| freeExpr(allocator, expr);
            allocator.free(value.upsertValues);
            if (value.upsertWhere) |conditions| {
                for (conditions) |condition| {
                    if (condition.leftExpr) |left| freeExpr(allocator, left);
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    if (condition.escape) |escape| freeExpr(allocator, escape);
                    for (condition.listValues) |item| freeExpr(allocator, item);
                    if (condition.listValues.len != 0) allocator.free(condition.listValues);
                }
                allocator.free(conditions);
            }
        },
        .select => |value| {
            for (value.projections) |projection| freeExpr(allocator, projection.expr);
            allocator.free(value.projections);
            if (value.condition) |conditions| {
                for (conditions) |condition| {
                    if (condition.leftExpr) |left| freeExpr(allocator, left);
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    if (condition.escape) |escape| freeExpr(allocator, escape);
                    for (condition.listValues) |item| freeExpr(allocator, item);
                    if (condition.listValues.len != 0) allocator.free(condition.listValues);
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
                    if (condition.leftExpr) |left| freeExpr(allocator, left);
                    freeExpr(allocator, condition.value);
                    if (condition.value2) |second| freeExpr(allocator, second);
                    if (condition.escape) |escape| freeExpr(allocator, escape);
                    for (condition.listValues) |item| freeExpr(allocator, item);
                    if (condition.listValues.len != 0) allocator.free(condition.listValues);
                }
                allocator.free(conditions);
            }
        },
        .delete => |value| if (value.condition) |conditions| {
            for (conditions) |condition| {
                if (condition.leftExpr) |left| freeExpr(allocator, left);
                freeExpr(allocator, condition.value);
                if (condition.value2) |second| freeExpr(allocator, second);
                if (condition.escape) |escape| freeExpr(allocator, escape);
                for (condition.listValues) |item| freeExpr(allocator, item);
                if (condition.listValues.len != 0) allocator.free(condition.listValues);
            }
            allocator.free(conditions);
        },
        else => {},
    }
}
