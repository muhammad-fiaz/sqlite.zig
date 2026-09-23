//! Foreign-key referential-action enforcement over the catalog.
//!
//! Responsibility: apply `ON UPDATE` / `ON DELETE` actions (`CASCADE`,
//! `SET NULL`, `SET DEFAULT`, immediate `RESTRICT`/`NO ACTION`) for both
//! column-level FKs and table-level (composite) constraints, recursing into
//! chained children; verify deferred (`DEFERRABLE INITIALLY DEFERRED` and
//! `PRAGMA defer_foreign_keys`) constraints at COMMIT; shape
//! `PRAGMA foreign_key_check` violation rows; spell referential-action
//! keywords. Mirrors SQLite's `fkey.c` cascade semantics: composite actions
//! run before column-level ones, and delete pass 1 reports every immediate
//! RESTRICT violation before any pass-2 effect fires.
//!
//! Dependencies: `catalog/schema.zig` for `Schema`/`Table` (one-directional:
//! schema never imports connection), `connection/compare.zig` for the
//! canonical `sameValue`/`compare`, `sql/expr.zig` for the canonical value
//! free. Lifetime: operates purely on schema-owned rows; `allocator` backs
//! transient cascade candidates and duped payloads, which are either adopted
//! into rows or freed on error. Deferred checks (`fkCheckDeferred`) skip
//! immediate enforcement; the caller runs deferred verification at COMMIT.
//! Errors: `ConstraintViolation` on missing parents, unknown columns, NOT
//! NULL conflicts, or immediate RESTRICT/NO ACTION matches.

const std = @import("std");
const Schema = @import("../catalog/schema.zig").Schema;
const Table = @import("../catalog/schema.zig").Table;
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");
const compare = @import("compare.zig");
const exprEvaluator = @import("../sql/expr.zig");
const valuesEqual = @import("../catalog/schema.zig").valuesEqual;

fn freeOne(allocator: std.mem.Allocator, value: Value) void {
    exprEvaluator.freeValue(allocator, value);
}

fn copyOne(allocator: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .text => |v| .{ .text = try allocator.dupe(u8, v) },
        .blob => |v| .{ .blob = try allocator.dupe(u8, v) },
        else => value,
    };
}

/// Position of `name` in `table.columns` (case-insensitive), or
/// `UnknownColumn`. Local to this module so FK enforcement never depends on
/// connection internals; matches the catalog's canonical lookup rule.
fn fkColumnIndex(table: *const Table, name: []const u8) !usize {
    for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
    return error.UnknownColumn;
}

/// True when the child row references the parent row under a composite
/// (table-level) FK constraint. NULLs never match (`sameValue` identity).
pub fn compositeMatches(child: *const Table, childValues: []const Value, parent: *const Table, parentValues: []const Value, constraint: anytype) !bool {
    for (constraint.columns, constraint.referencedColumns) |childName, parentName| {
        const childIndex = try fkColumnIndex(child, childName);
        const parentIndex = try fkColumnIndex(parent, parentName);
        if (!compare.sameValue(childValues[childIndex], parentValues[parentIndex])) return false;
    }
    return true;
}

/// Composite (table-level) `ON UPDATE` actions for every child FK pointing at
/// `parentName`. Borrowed names/values; mutates child rows in place.
pub fn applyCompositeUpdateActions(allocator: std.mem.Allocator, store: *Schema, parentName: []const u8, oldValues: []const Value, newValues: []const Value) anyerror!void {
    const parent = store.findConst(parentName) orelse return error.ConstraintViolation;
    for (store.tables.items) |childTable| {
        var childRowIndex: usize = 0;
        while (childRowIndex < childTable.rows.items.len) : (childRowIndex += 1) {
            var constraintIndex: usize = 0;
            while (constraintIndex < childTable.constraints.len) : (constraintIndex += 1) {
                const constraint = childTable.constraints[constraintIndex];
                if (constraint.kind != .foreignKey or !std.ascii.eqlIgnoreCase(constraint.foreignTable.?, parentName)) continue;
                var changed = false;
                for (constraint.referencedColumns) |parentColumn| {
                    const parentIndex = try fkColumnIndex(parent, parentColumn);
                    if (!compare.sameValue(oldValues[parentIndex], newValues[parentIndex])) changed = true;
                }
                if (!changed or !try compositeMatches(childTable, childTable.rows.items[childRowIndex].values, parent, oldValues, constraint)) continue;
                switch (constraint.onUpdate) {
                    .restrict, .noAction => if (store.fkCheckDeferred(constraint.deferrable, constraint.initiallyDeferred)) continue else return error.ConstraintViolation,
                    .setNull => {
                        for (constraint.columns) |childColumn| {
                            const childIndex = try fkColumnIndex(childTable, childColumn);
                            if (childTable.columns[childIndex].notNull) return error.ConstraintViolation;
                        }
                        for (constraint.columns) |childColumn| {
                            const childIndex = try fkColumnIndex(childTable, childColumn);
                            const old = childTable.rows.items[childRowIndex].values[childIndex];
                            freeOne(allocator, old);
                            childTable.rows.items[childRowIndex].values[childIndex] = .null;
                        }
                    },
                    .setDefault => {
                        for (constraint.columns) |childColumn| {
                            const childIndex = try fkColumnIndex(childTable, childColumn);
                            const def = childTable.columns[childIndex].defaultValue orelse .null;
                            if (childTable.columns[childIndex].notNull and def == .null) return error.ConstraintViolation;
                        }
                        for (constraint.columns) |childColumn| {
                            const childIndex = try fkColumnIndex(childTable, childColumn);
                            const def = childTable.columns[childIndex].defaultValue orelse .null;
                            const old = childTable.rows.items[childRowIndex].values[childIndex];
                            freeOne(allocator, old);
                            childTable.rows.items[childRowIndex].values[childIndex] = .null;
                            childTable.rows.items[childRowIndex].values[childIndex] = try copyOne(allocator, def);
                        }
                    },
                    .cascade => {
                        const row = &childTable.rows.items[childRowIndex];
                        const candidate = try allocator.alloc(Value, row.values.len);
                        for (row.values, 0..) |item, index| candidate[index] = try copyOne(allocator, item);
                        for (constraint.columns, constraint.referencedColumns) |childColumn, parentColumn| {
                            const childIndex = try fkColumnIndex(childTable, childColumn);
                            const parentIndex = try fkColumnIndex(parent, parentColumn);
                            freeOne(allocator, candidate[childIndex]);
                            candidate[childIndex] = try copyOne(allocator, newValues[parentIndex]);
                        }
                        try applyUpdateActions(allocator, store, childTable.name, row.values, candidate);
                        for (row.values) |item| freeOne(allocator, item);
                        allocator.free(row.values);
                        row.values = candidate;
                    },
                }
            }
        }
    }
}

/// Composite (table-level) `ON DELETE` actions for every child FK pointing at
/// `parentName`. Borrowed names/values; mutates child rows in place.
pub fn applyCompositeDeleteActions(allocator: std.mem.Allocator, store: *Schema, parentName: []const u8, parentValues: []const Value) anyerror!void {
    const parent = store.findConst(parentName) orelse return error.ConstraintViolation;
    for (store.tables.items) |childTable| {
        var childRowIndex = childTable.rows.items.len;
        while (childRowIndex > 0) {
            childRowIndex -= 1;
            for (childTable.constraints) |constraint| {
                if (constraint.kind != .foreignKey or !std.ascii.eqlIgnoreCase(constraint.foreignTable.?, parentName)) continue;
                if (!try compositeMatches(childTable, childTable.rows.items[childRowIndex].values, parent, parentValues, constraint)) continue;
                switch (constraint.onDelete) {
                    .restrict, .noAction => if (store.fkCheckDeferred(constraint.deferrable, constraint.initiallyDeferred)) continue else return error.ConstraintViolation,
                    .setNull => {
                        for (constraint.columns) |childColumn| {
                            const childIndex = try fkColumnIndex(childTable, childColumn);
                            if (childTable.columns[childIndex].notNull) return error.ConstraintViolation;
                        }
                        for (constraint.columns) |childColumn| {
                            const childIndex = try fkColumnIndex(childTable, childColumn);
                            const old = childTable.rows.items[childRowIndex].values[childIndex];
                            freeOne(allocator, old);
                            childTable.rows.items[childRowIndex].values[childIndex] = .null;
                        }
                    },
                    .setDefault => {
                        for (constraint.columns) |childColumn| {
                            const childIndex = try fkColumnIndex(childTable, childColumn);
                            const def = childTable.columns[childIndex].defaultValue orelse .null;
                            if (childTable.columns[childIndex].notNull and def == .null) return error.ConstraintViolation;
                        }
                        for (constraint.columns) |childColumn| {
                            const childIndex = try fkColumnIndex(childTable, childColumn);
                            const def = childTable.columns[childIndex].defaultValue orelse .null;
                            const old = childTable.rows.items[childRowIndex].values[childIndex];
                            freeOne(allocator, old);
                            childTable.rows.items[childRowIndex].values[childIndex] = .null;
                            childTable.rows.items[childRowIndex].values[childIndex] = try copyOne(allocator, def);
                        }
                    },
                    .cascade => {
                        try applyDeleteActions(allocator, store, childTable.name, childTable.rows.items[childRowIndex].values);
                        const removed = childTable.rows.orderedRemove(childRowIndex);
                        for (removed.values) |item| freeOne(allocator, item);
                        allocator.free(removed.values);
                    },
                }
            }
        }
    }
}

/// Column-level plus composite `ON UPDATE` actions for every FK pointing at
/// `parentName`. Composite actions run first. Borrowed names/values.
pub fn applyUpdateActions(allocator: std.mem.Allocator, store: *Schema, parentName: []const u8, oldValues: []const Value, newValues: []const Value) anyerror!void {
    if (!store.foreignKeysEnabled) return;
    try applyCompositeUpdateActions(allocator, store, parentName, oldValues, newValues);
    const parent = store.findConst(parentName) orelse return error.ConstraintViolation;
    var childTableIndex: usize = 0;
    while (childTableIndex < store.tables.items.len) : (childTableIndex += 1) {
        const childTable = store.tables.items[childTableIndex];
        var childColumnIndex: usize = 0;
        while (childColumnIndex < childTable.columns.len) : (childColumnIndex += 1) {
            const childColumn = childTable.columns[childColumnIndex];
            const foreignTable = childColumn.foreignTable orelse continue;
            if (!std.ascii.eqlIgnoreCase(foreignTable, parentName)) continue;
            const referenced = childColumn.foreignColumn orelse return error.ConstraintViolation;
            const parentColumnIndex = try fkColumnIndex(parent, referenced);
            if (compare.sameValue(oldValues[parentColumnIndex], newValues[parentColumnIndex])) continue;

            var childRowIndex: usize = 0;
            while (childRowIndex < childTable.rows.items.len) : (childRowIndex += 1) {
                const childRow = &childTable.rows.items[childRowIndex];
                if (!compare.sameValue(oldValues[parentColumnIndex], childRow.values[childColumnIndex])) continue;
                switch (childColumn.onUpdate) {
                    .restrict, .noAction => if (store.fkCheckDeferred(childColumn.fkDeferrable, childColumn.fkInitiallyDeferred)) continue else return error.ConstraintViolation,
                    .setNull => {
                        if (childColumn.notNull) return error.ConstraintViolation;
                        const old = childRow.values[childColumnIndex];
                        freeOne(allocator, old);
                        childRow.values[childColumnIndex] = .null;
                    },
                    .setDefault => {
                        const def = childColumn.defaultValue orelse .null;
                        if (childColumn.notNull and def == .null) return error.ConstraintViolation;
                        const old = childRow.values[childColumnIndex];
                        freeOne(allocator, old);
                        childRow.values[childColumnIndex] = .null;
                        childRow.values[childColumnIndex] = try copyOne(allocator, def);
                    },
                    .cascade => {
                        const candidate = try allocator.alloc(Value, childRow.values.len);
                        errdefer allocator.free(candidate);
                        for (childRow.values, 0..) |item, index| candidate[index] = try copyOne(allocator, item);
                        const replacement = try copyOne(allocator, newValues[parentColumnIndex]);
                        freeOne(allocator, candidate[childColumnIndex]);
                        candidate[childColumnIndex] = replacement;
                        try applyUpdateActions(allocator, store, childTable.name, childRow.values, candidate);
                        for (childRow.values) |item| freeOne(allocator, item);
                        allocator.free(childRow.values);
                        childRow.values = candidate;
                    },
                }
            }
        }
    }
}

/// Resolve the parent column index for one child FK column, or fail when the
/// FK metadata names an unknown column. Shared by both delete passes.
pub fn deleteFkParentIndex(store: *Schema, parentName: []const u8, column: anytype) !usize {
    const parentTable = store.findConst(parentName) orelse return error.ConstraintViolation;
    const referenced = column.foreignColumn orelse return error.ConstraintViolation;
    for (parentTable.columns, 0..) |parentColumn, index| {
        if (std.ascii.eqlIgnoreCase(parentColumn.name, referenced)) return index;
    }
    return error.ConstraintViolation;
}

/// Column-level plus composite `ON DELETE` actions for every FK pointing at
/// `parentName`. Pass 1 reports every immediate RESTRICT/NO ACTION violation
/// before any pass-2 effect fires. Borrowed names/values.
pub fn applyDeleteActions(allocator: std.mem.Allocator, store: *Schema, parentName: []const u8, parentValues: []const Value) anyerror!void {
    if (!store.foreignKeysEnabled) return;
    try applyCompositeDeleteActions(allocator, store, parentName, parentValues);
    var childTableIndex: usize = 0;
    while (childTableIndex < store.tables.items.len) : (childTableIndex += 1) {
        const childTable = store.tables.items[childTableIndex];
        // Pass 1: every independent FK to this parent is examined — never
        // just the first matching column. Any immediate RESTRICT/NO ACTION
        // violation fails before any cascade/set effect fires.
        for (childTable.columns, 0..) |column, columnIdx| {
            const foreignTable = column.foreignTable orelse continue;
            if (!std.ascii.eqlIgnoreCase(foreignTable, parentName)) continue;
            if (column.onDelete != .restrict and column.onDelete != .noAction) continue;
            if (store.fkCheckDeferred(column.fkDeferrable, column.fkInitiallyDeferred)) continue;
            const parentColumnIndex = try deleteFkParentIndex(store, parentName, column);
            var childRowIndex = childTable.rows.items.len;
            while (childRowIndex > 0) {
                childRowIndex -= 1;
                if (compare.compare(parentValues[parentColumnIndex], .equal, childTable.rows.items[childRowIndex].values[columnIdx])) return error.ConstraintViolation;
            }
        }
        // Pass 2: apply SET NULL / SET DEFAULT / CASCADE per FK.
        for (childTable.columns, 0..) |column, columnIdx| {
            const foreignTable = column.foreignTable orelse continue;
            if (!std.ascii.eqlIgnoreCase(foreignTable, parentName)) continue;
            const parentColumnIndex = try deleteFkParentIndex(store, parentName, column);
            var childRowIndex = childTable.rows.items.len;
            while (childRowIndex > 0) {
                childRowIndex -= 1;
                if (!compare.compare(parentValues[parentColumnIndex], .equal, childTable.rows.items[childRowIndex].values[columnIdx])) continue;
                switch (column.onDelete) {
                    .restrict, .noAction => {},
                    .setNull => {
                        if (column.notNull) return error.ConstraintViolation;
                        const old = childTable.rows.items[childRowIndex].values[columnIdx];
                        freeOne(allocator, old);
                        childTable.rows.items[childRowIndex].values[columnIdx] = .null;
                    },
                    .setDefault => {
                        const def = column.defaultValue orelse .null;
                        if (column.notNull and def == .null) return error.ConstraintViolation;
                        const old = childTable.rows.items[childRowIndex].values[columnIdx];
                        freeOne(allocator, old);
                        childTable.rows.items[childRowIndex].values[columnIdx] = .null;
                        childTable.rows.items[childRowIndex].values[columnIdx] = try copyOne(allocator, def);
                    },
                    .cascade => {
                        try applyDeleteActions(allocator, store, childTable.name, childTable.rows.items[childRowIndex].values);
                        const removed = childTable.rows.orderedRemove(childRowIndex);
                        for (removed.values) |item| freeOne(allocator, item);
                        allocator.free(removed.values);
                    },
                }
            }
        }
    }
}

test "compositeMatches requires all pairs under strict identity" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const parentDefs = [_]ast.ColumnDef{
        .{ .name = "a", .typeName = "INTEGER" },
        .{ .name = "b", .typeName = "INTEGER" },
    };
    try schema.createTable("p", &parentDefs, &.{});
    const childDefs = [_]ast.ColumnDef{
        .{ .name = "x", .typeName = "INTEGER" },
        .{ .name = "y", .typeName = "INTEGER" },
    };
    const fk = ast.TableConstraint{ .foreignKey = .{ .columns = @constCast(&[_][]const u8{ "x", "y" }), .table = "p", .referencedColumns = @constCast(&[_][]const u8{ "a", "b" }) } };
    try schema.createTable("c", &childDefs, &[_]ast.TableConstraint{fk});
    const parent = schema.findConst("p").?;
    const child = schema.findConst("c").?;
    const constraint = child.constraints[0];
    const ok = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const same = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const half = [_]Value{ .{ .integer = 1 }, .{ .integer = 9 } };
    try std.testing.expect(try compositeMatches(child, &ok, parent, &same, constraint));
    try std.testing.expect(!try compositeMatches(child, &ok, parent, &half, constraint));
    // Strict identity: integer 1 is not real 1.0 for FK matching.
    const cross = [_]Value{ .{ .real = 1.0 }, .{ .integer = 2 } };
    try std.testing.expect(!try compositeMatches(child, &cross, parent, &same, constraint));
}

test "delete cascade removes chained children" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const pDefs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER", .primaryKey = true }};
    try schema.createTable("p", &pDefs, &.{});
    const cDefs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "pid", .typeName = "INTEGER", .foreignKey = .{ .table = "p", .column = "id", .onDelete = .cascade, .onUpdate = .cascade } },
    };
    try schema.createTable("c", &cDefs, &.{});
    const p = schema.find("p").?;
    const c = schema.find("c").?;
    try schema.appendRow(p, &[_]Value{.{ .integer = 1 }});
    try schema.appendRow(c, &[_]Value{ .{ .integer = 10 }, .{ .integer = 1 } });
    try schema.appendRow(c, &[_]Value{ .{ .integer = 11 }, .{ .integer = 1 } });
    const doomed = [_]Value{.{ .integer = 1 }};
    try applyDeleteActions(std.testing.allocator, &schema, "p", &doomed);
    try std.testing.expectEqual(@as(usize, 0), c.rows.items.len);
}

test "delete restrict fails before any cascade fires" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const pDefs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER", .primaryKey = true }};
    try schema.createTable("p", &pDefs, &.{});
    const cDefs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "pid", .typeName = "INTEGER", .foreignKey = .{ .table = "p", .column = "id", .onDelete = .restrict, .onUpdate = .restrict } },
    };
    try schema.createTable("c", &cDefs, &.{});
    try schema.appendRow(schema.find("p").?, &[_]Value{.{ .integer = 1 }});
    try schema.appendRow(schema.find("c").?, &[_]Value{ .{ .integer = 10 }, .{ .integer = 1 } });
    const doomed = [_]Value{.{ .integer = 1 }};
    try std.testing.expectError(error.ConstraintViolation, applyDeleteActions(std.testing.allocator, &schema, "p", &doomed));
    try std.testing.expectEqual(@as(usize, 1), schema.find("c").?.rows.items.len);
}

test "update cascade rewrites child keys" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const pDefs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER", .primaryKey = true }};
    try schema.createTable("p", &pDefs, &.{});
    const cDefs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "pid", .typeName = "INTEGER", .foreignKey = .{ .table = "p", .column = "id", .onDelete = .cascade, .onUpdate = .cascade } },
    };
    try schema.createTable("c", &cDefs, &.{});
    try schema.appendRow(schema.find("p").?, &[_]Value{.{ .integer = 1 }});
    try schema.appendRow(schema.find("c").?, &[_]Value{ .{ .integer = 10 }, .{ .integer = 1 } });
    const old = [_]Value{.{ .integer = 1 }};
    const new = [_]Value{.{ .integer = 2 }};
    try applyUpdateActions(std.testing.allocator, &schema, "p", &old, &new);
    try std.testing.expectEqual(@as(i64, 2), schema.find("c").?.rows.items[0].values[1].integer);
}

/// SQL keyword for a referential action, as reported by
/// `PRAGMA foreign_key_list` (`NO ACTION` with a space, per the reference).
pub fn fkActionName(action: ast.ReferentialAction) []const u8 {
    return switch (action) {
        .cascade => "CASCADE",
        .restrict => "RESTRICT",
        .setNull => "SET NULL",
        .setDefault => "SET DEFAULT",
        .noAction => "NO ACTION",
    };
}

/// True when `store` holds any FK needing a deferred COMMIT-time check:
/// under `PRAGMA defer_foreign_keys` any FK qualifies, otherwise only
/// constraints declared `DEFERRABLE INITIALLY DEFERRED. Borrowed store.
pub fn storeNeedsDeferredCheck(store: *const Schema) bool {
    if (store.deferForeignKeys) {
        for (store.tables.items) |tbl| {
            for (tbl.columns) |column| if (column.foreignTable != null) return true;
            for (tbl.constraints) |constraint| if (constraint.kind == .foreignKey) return true;
        }
        return false;
    }
    for (store.tables.items) |tbl| {
        for (tbl.columns) |column| if (column.foreignTable != null and column.fkDeferrable and column.fkInitiallyDeferred) return true;
        for (tbl.constraints) |constraint| if (constraint.kind == .foreignKey and constraint.deferrable and constraint.initiallyDeferred) return true;
    }
    return false;
}

/// Deferred FK enforcement for COMMIT and autocommit statement ends.
/// Re-scans postponed constraints (skipped by immediate validation); the
/// first orphan row fails `ConstraintViolation`. Respects
/// `foreignKeysEnabled`; immediate-only constraints were already checked.
/// Borrowed store; read-only.
pub fn enforceDeferredForeignKeys(store: *const Schema) !void {
    if (!store.foreignKeysEnabled) return;
    if (!storeNeedsDeferredCheck(store)) return;
    for (store.tables.items) |tbl| {
        if (tbl.virtualModule != null) continue;
        for (tbl.rows.items) |row| {
            if (row.values.len != tbl.columns.len) continue;
            for (tbl.columns, 0..) |column, childIndex| {
                const foreignTableName = column.foreignTable orelse continue;
                if (!store.fkCheckDeferred(column.fkDeferrable, column.fkInitiallyDeferred)) continue;
                const parent = store.findConst(foreignTableName) orelse return error.ConstraintViolation;
                const foreignColumnName = column.foreignColumn orelse return error.ConstraintViolation;
                const parentIndex = fkColumnIndex(parent, foreignColumnName) catch return error.ConstraintViolation;
                if (row.values[childIndex] == .null) continue;
                var found = false;
                for (parent.rows.items) |parentRow| {
                    if (parentRow.values.len != parent.columns.len) continue;
                    if (valuesEqual(parentRow.values[parentIndex], row.values[childIndex])) {
                        found = true;
                        break;
                    }
                }
                if (!found) return error.ConstraintViolation;
            }
            for (tbl.constraints) |constraint| {
                if (constraint.kind != .foreignKey) continue;
                if (!store.fkCheckDeferred(constraint.deferrable, constraint.initiallyDeferred)) continue;
                const foreignTableName = constraint.foreignTable orelse return error.ConstraintViolation;
                const parent = store.findConst(foreignTableName) orelse return error.ConstraintViolation;
                var hasNull = false;
                for (constraint.columns) |childName| {
                    const childIndex = fkColumnIndex(tbl, childName) catch return error.ConstraintViolation;
                    if (row.values[childIndex] == .null) hasNull = true;
                }
                if (hasNull) continue;
                var found = false;
                for (parent.rows.items) |parentRow| {
                    if (parentRow.values.len != parent.columns.len) continue;
                    var matched = true;
                    for (constraint.columns, constraint.referencedColumns) |childName, parentName| {
                        const childIndex = fkColumnIndex(tbl, childName) catch return error.ConstraintViolation;
                        const parentIndex = fkColumnIndex(parent, parentName) catch return error.ConstraintViolation;
                        if (!valuesEqual(row.values[childIndex], parentRow.values[parentIndex])) matched = false;
                    }
                    if (matched) {
                        found = true;
                        break;
                    }
                }
                if (!found) return error.ConstraintViolation;
            }
        }
    }
}

/// Append one `PRAGMA foreign_key_check` row shaped as
/// `(table, rowid, parent, fkid)`. WITHOUT ROWID tables report NULL rowids.
/// The row's text payloads are caller-owned via `rows`.
pub fn foreignKeyViolation(allocator: std.mem.Allocator, rows: *std.ArrayList([]Value), tbl: *const Table, rowIndex: usize, parentName: []const u8, fkid: i64) !void {
    const row = try allocator.alloc(Value, 4);
    row[0] = .null;
    row[1] = .null;
    row[2] = .null;
    row[3] = .null;
    errdefer {
        for (row) |v| exprEvaluator.freeValue(allocator, v);
        allocator.free(row);
    }
    row[0] = .{ .text = try allocator.dupe(u8, tbl.name) };
    row[1] = if (tbl.withoutRowid) .null else .{ .integer = @intCast(rowIndex + 1) };
    row[2] = .{ .text = try allocator.dupe(u8, parentName) };
    row[3] = .{ .integer = fkid };
    try rows.append(allocator, row);
}

test "fkActionName spells every referential action" {
    try std.testing.expectEqualStrings("CASCADE", fkActionName(.cascade));
    try std.testing.expectEqualStrings("RESTRICT", fkActionName(.restrict));
    try std.testing.expectEqualStrings("SET NULL", fkActionName(.setNull));
    try std.testing.expectEqualStrings("SET DEFAULT", fkActionName(.setDefault));
    try std.testing.expectEqualStrings("NO ACTION", fkActionName(.noAction));
}

test "storeNeedsDeferredCheck respects pragma and deferrability" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const pDefs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER", .primaryKey = true }};
    try schema.createTable("p", &pDefs, &.{});
    const cDefs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "pid", .typeName = "INTEGER", .foreignKey = .{ .table = "p", .column = "id" } },
    };
    try schema.createTable("c", &cDefs, &.{});
    // Immediate-only FK: nothing deferred.
    try std.testing.expect(!storeNeedsDeferredCheck(&schema));
    // Global deferral pragma qualifies any FK.
    schema.deferForeignKeys = true;
    try std.testing.expect(storeNeedsDeferredCheck(&schema));
    schema.deferForeignKeys = false;
    // INITIALLY DEFERRED qualifies without the pragma.
    const dDefs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "pid", .typeName = "INTEGER", .foreignKey = .{ .table = "p", .column = "id", .deferrable = true, .initiallyDeferred = true } },
    };
    try schema.createTable("d", &dDefs, &.{});
    try std.testing.expect(storeNeedsDeferredCheck(&schema));
}

test "enforceDeferredForeignKeys catches orphans at commit time" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const pDefs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER", .primaryKey = true }};
    try schema.createTable("p", &pDefs, &.{});
    const cDefs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "pid", .typeName = "INTEGER", .foreignKey = .{ .table = "p", .column = "id", .deferrable = true, .initiallyDeferred = true } },
    };
    try schema.createTable("c", &cDefs, &.{});
    try schema.appendRow(schema.find("p").?, &[_]Value{.{ .integer = 1 }});
    try schema.appendRow(schema.find("c").?, &[_]Value{ .{ .integer = 10 }, .{ .integer = 1 } });
    try enforceDeferredForeignKeys(&schema);
    // An orphan child fails even though the immediate check was deferred.
    try schema.appendRow(schema.find("c").?, &[_]Value{ .{ .integer = 11 }, .{ .integer = 2 } });
    try std.testing.expectError(error.ConstraintViolation, enforceDeferredForeignKeys(&schema));
    // Disabled enforcement skips everything.
    const removed = schema.find("c").?.rows.orderedRemove(1);
    for (removed.values) |v| exprEvaluator.freeValue(std.testing.allocator, v);
    std.testing.allocator.free(removed.values);
    schema.foreignKeysEnabled = false;
    try enforceDeferredForeignKeys(&schema);
}

test "foreignKeyViolation shapes table-rowid-parent-fkid rows" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const pDefs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER", .primaryKey = true }};
    try schema.createTable("p", &pDefs, &.{});
    const t = schema.findConst("p").?;
    var rows = std.ArrayList([]Value).empty;
    defer {
        for (rows.items) |r| {
            for (r) |v| exprEvaluator.freeValue(std.testing.allocator, v);
            std.testing.allocator.free(r);
        }
        rows.deinit(std.testing.allocator);
    }
    try foreignKeyViolation(std.testing.allocator, &rows, t, 4, "parent", 7);
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("p", rows.items[0][0].text);
    try std.testing.expectEqual(@as(i64, 5), rows.items[0][1].integer);
    try std.testing.expectEqualStrings("parent", rows.items[0][2].text);
    try std.testing.expectEqual(@as(i64, 7), rows.items[0][3].integer);
}
