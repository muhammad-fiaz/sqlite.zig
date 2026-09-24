//! Upsert/REPLACE conflict detection over the catalog.
//!
//! Responsibility: find the existing row that a candidate insert conflicts
//! with (column PRIMARY KEY/UNIQUE, table-level constraints, UNIQUE indexes
//! including expression and partial indexes) and validate explicit
//! `ON CONFLICT(target)` clauses against the table's uniqueness scope,
//! mirroring the reference inference (`sqlite3UpsertAnalyzeTarget` in
//! `upsert.c`): the target must match the rowid alias, a PRIMARY
//! KEY/UNIQUE group, or a UNIQUE index, with partial indexes additionally
//! requiring a WHERE implying the predicate.
//!
//! Dependencies: `catalog/schema.zig` for `Schema`/`Table` (one-directional:
//! schema never imports connection), `connection/compare.zig` for the
//! canonical `sameValue`/`compare`, `sql/expr.zig` for key evaluation,
//! predicate checks, and value frees. Lifetime: read-only over
//! schema-owned rows; `allocator` backs only transient expression-index key
//! buffers, freed before return. Errors: `UnknownColumn` for dangling
//! constraint/index references, `InvalidSql` for unmatched conflict
//! targets, `OutOfMemory` for transient buffers.
//!
//! `conflictRowTarget` (target-scoped lookup needing the interpreter's row
//! matcher) stays in `connection.zig` and delegates here for the unscoped
//! scan.

const std = @import("std");
const Schema = @import("../catalog/schema.zig").Schema;
const Table = @import("../catalog/schema.zig").Table;
const Value = @import("../vm/value.zig").Value;
const compare = @import("compare.zig");
const exprEvaluator = @import("../sql/expr.zig");

/// Position of `name` in `table.columns` (case-insensitive). Local to this
/// module so conflict detection never depends on connection internals;
/// matches the catalog's canonical lookup rule.
fn conflictColumnIndex(table: *const Table, name: []const u8) !usize {
    for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
    return error.UnknownColumn;
}

/// First row index conflicting with `values` under any uniqueness scope, or
/// null. NULL candidate values never conflict (SQLite rule); `ignoreIndex`
/// skips one row for REPLACE-style rescans. Borrowed inputs.
pub fn conflictRow(allocator: std.mem.Allocator, store: *Schema, tbl: *const Table, values: []const Value, ignoreIndex: ?usize) anyerror!?usize {
    for (tbl.rows.items, 0..) |existing, rowIndex| {
        if (ignoreIndex != null and ignoreIndex.? == rowIndex) continue;
        var matched = false;
        for (tbl.columns, 0..) |column, columnIdx| if ((column.primaryKey or column.unique) and values[columnIdx] != .null and compare.sameValue(existing.values[columnIdx], values[columnIdx])) {
            matched = true;
            break;
        };
        if (matched) return rowIndex;
        for (tbl.constraints) |constraint| {
            if (constraint.kind == .foreignKey) continue;
            var valid = true;
            var hasNull = false;
            for (constraint.columns) |name| {
                const columnIdx = conflictColumnIndex(tbl, name) catch {
                    valid = false;
                    break;
                };
                if (values[columnIdx] == .null) hasNull = true;
                if (!compare.sameValue(existing.values[columnIdx], values[columnIdx])) valid = false;
            }
            if (valid and (constraint.kind == .primaryKey or !hasNull)) return rowIndex;
        }
        for (store.indexes.items) |index| if (index.unique and std.ascii.eqlIgnoreCase(index.table, tbl.name)) {
            var colNames: ?[][]const u8 = null;
            defer if (colNames) |names| allocator.free(names);
            var valid = true;
            var hasNull = false;
            for (index.columns, 0..) |name, position| {
                if (index.keyExpr(position) != null) {
                    if (colNames == null) {
                        const names = try allocator.alloc([]const u8, tbl.columns.len);
                        for (tbl.columns, 0..) |tableColumn, idx| names[idx] = tableColumn.name;
                        colNames = names;
                    }
                    const leftVal = try exprEvaluator.eval(allocator, colNames.?, existing.values, index.keyExpr(position).?);
                    defer exprEvaluator.freeValue(allocator, leftVal);
                    const rightVal = try exprEvaluator.eval(allocator, colNames.?, values, index.keyExpr(position).?);
                    defer exprEvaluator.freeValue(allocator, rightVal);
                    if (leftVal == .null or rightVal == .null) {
                        valid = false;
                        break;
                    }
                    if (!leftVal.sameValue(rightVal)) valid = false;
                    continue;
                }
                const columnIdx = conflictColumnIndex(tbl, name) catch {
                    valid = false;
                    break;
                };
                if (values[columnIdx] == .null) hasNull = true;
                if (!compare.sameValue(existing.values[columnIdx], values[columnIdx])) valid = false;
            }
            if (!valid or hasNull) continue;
            if (!try store.indexPredicateHolds(tbl, &index, values)) continue;
            if (!try store.indexPredicateHolds(tbl, &index, existing.values)) continue;
            return rowIndex;
        };
    }
    return null;
}

/// True when two column lists hold the same names regardless of order
/// (ASCII case-insensitive); the reference requires equal cardinality
/// between conflict targets and index keys, so lengths must agree.
pub fn conflictColumnsMatch(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left) |a| {
        var found = false;
        for (right) |b| if (std.ascii.eqlIgnoreCase(a, b)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}

/// Validates an explicit `ON CONFLICT(target)` clause against the table's
/// unique constraints, mirroring the reference inference
/// (`sqlite3UpsertAnalyzeTarget`): the target set must match the rowid,
/// a PRIMARY KEY/UNIQUE group, or a UNIQUE index — and a partial index
/// additionally needs a WHERE implying its predicate. Anything else fails
/// `InvalidSql` instead of silently inserting. Borrowed inputs.
pub fn checkConflictTarget(store: *const Schema, tbl: *const Table, value: anytype) !void {
    if (value.conflictTargetColumns.len == 0) return;
    if (value.conflict != .update and value.conflict != .ignore) return;
    const target = value.conflictTargetColumns;
    if (target.len == 1 and !tbl.withoutRowid) {
        if (std.ascii.eqlIgnoreCase(target[0], "rowid") or std.ascii.eqlIgnoreCase(target[0], "_rowid_") or std.ascii.eqlIgnoreCase(target[0], "oid")) return;
    }
    if (target.len == 1) {
        if (Schema.rowidAliasColumn(tbl)) |alias| {
            if (std.ascii.eqlIgnoreCase(tbl.columns[alias].name, target[0])) return;
        }
        for (tbl.columns) |column| {
            if (!column.unique or !std.ascii.eqlIgnoreCase(column.name, target[0])) continue;
            if (inCompositePk(tbl, column.name)) continue;
            return;
        }
    }
    for (tbl.constraints) |constraint| {
        if (constraint.kind == .foreignKey or constraint.kind == .check) continue;
        if (conflictColumnsMatch(constraint.columns, target)) return;
    }
    for (store.indexes.items) |index| {
        if (!index.unique or !std.ascii.eqlIgnoreCase(index.table, tbl.name)) continue;
        // Expression indexes need expression targets, which the
        // word-only target list cannot name; keep looking.
        var hasExpr = false;
        for (index.columns, 0..) |_, position| if (index.keyExpr(position) != null) {
            hasExpr = true;
            break;
        };
        if (hasExpr) continue;
        if (!conflictColumnsMatch(index.columns, target)) continue;
        if (index.whereExpr) |predicate| {
            const whereConds = value.conflictTargetWhere orelse return error.InvalidSql;
            if (!exprEvaluator.partialPredicateImpliedBy(predicate, whereConds)) continue;
        }
        return;
    }
    return error.InvalidSql;
}

/// True when `column` belongs to a composite (multi-column) table-level
/// PRIMARY KEY group (single-column members match on their own).
pub fn inCompositePk(tbl: *const Table, column: []const u8) bool {
    for (tbl.constraints) |constraint| {
        if (constraint.kind != .primaryKey or constraint.columns.len < 2) continue;
        for (constraint.columns) |name| if (std.ascii.eqlIgnoreCase(name, column)) return true;
    }
    return false;
}

test "conflictColumnsMatch is order-insensitive but length-strict" {
    const ab = [_][]const u8{ "a", "b" };
    const ba = [_][]const u8{ "B", "A" };
    const a = [_][]const u8{"a"};
    try std.testing.expect(conflictColumnsMatch(&ab, &ba));
    try std.testing.expect(!conflictColumnsMatch(&ab, &a));
    try std.testing.expect(!conflictColumnsMatch(&a, &ab));
    try std.testing.expect(conflictColumnsMatch(&[_][]const u8{}, &[_][]const u8{}));
}

test "conflictRow finds unique dups and skips nulls" {
    const ast = @import("../sql/ast.zig");
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "email", .typeName = "TEXT", .unique = true },
    };
    try schema.createTable("users", &defs, &.{});
    const t = schema.find("users").?;
    try schema.appendRow(t, &[_]Value{ .{ .integer = 1 }, .{ .text = "a" } });
    try schema.appendRow(t, &[_]Value{ .{ .integer = 2 }, .null });
    // Primary-key and unique-column duplicates report the stored row.
    try std.testing.expectEqual(@as(?usize, 0), try conflictRow(std.testing.allocator, &schema, t, &[_]Value{ .{ .integer = 1 }, .{ .text = "b" } }, null));
    try std.testing.expectEqual(@as(?usize, 0), try conflictRow(std.testing.allocator, &schema, t, &[_]Value{ .{ .integer = 9 }, .{ .text = "a" } }, null));
    // NULL candidates never conflict; ignoreIndex skips the matching row.
    try std.testing.expectEqual(@as(?usize, null), try conflictRow(std.testing.allocator, &schema, t, &[_]Value{ .{ .integer = 3 }, .null }, null));
    try std.testing.expectEqual(@as(?usize, null), try conflictRow(std.testing.allocator, &schema, t, &[_]Value{ .{ .integer = 1 }, .{ .text = "b" } }, 0));
    try std.testing.expectEqual(@as(?usize, null), try conflictRow(std.testing.allocator, &schema, t, &[_]Value{ .{ .integer = 3 }, .{ .text = "zzz" } }, null));
}

test "checkConflictTarget accepts scoped targets and rejects the rest" {
    const ast = @import("../sql/ast.zig");
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "email", .typeName = "TEXT", .unique = true },
    };
    try schema.createTable("users", &defs, &.{});
    const t = schema.findConst("users").?;
    const MockValue = struct {
        conflictTargetColumns: []const []const u8,
        conflict: ast.ConflictPolicy,
        conflictTargetWhere: ?ast.Conditions,
    };
    const empty = MockValue{ .conflictTargetColumns = &.{}, .conflict = .update, .conflictTargetWhere = null };
    try checkConflictTarget(&schema, t, empty);
    const email = [_][]const u8{"email"};
    try checkConflictTarget(&schema, t, .{ .conflictTargetColumns = &email, .conflict = .ignore, .conflictTargetWhere = null });
    const rowid = [_][]const u8{"rowid"};
    try checkConflictTarget(&schema, t, .{ .conflictTargetColumns = &rowid, .conflict = .update, .conflictTargetWhere = null });
    const bogus = [_][]const u8{"missing"};
    try std.testing.expectError(error.InvalidSql, checkConflictTarget(&schema, t, .{ .conflictTargetColumns = &bogus, .conflict = .update, .conflictTargetWhere = null }));
    // A lone member of a composite PRIMARY KEY is not a uniqueness scope.
    const pdefs = [_]ast.ColumnDef{
        .{ .name = "a", .typeName = "INTEGER" },
        .{ .name = "b", .typeName = "INTEGER" },
    };
    const pk = ast.TableConstraint{ .primaryKey = .{ .columns = @constCast(&[_][]const u8{ "a", "b" }) } };
    try schema.createTable("pairs", &pdefs, &[_]ast.TableConstraint{pk});
    const pt = schema.findConst("pairs").?;
    try std.testing.expect(inCompositePk(pt, "a"));
    try std.testing.expect(!inCompositePk(pt, "zzz"));
    const lone = [_][]const u8{"a"};
    try std.testing.expectError(error.InvalidSql, checkConflictTarget(&schema, pt, .{ .conflictTargetColumns = &lone, .conflict = .update, .conflictTargetWhere = null }));
    const both = [_][]const u8{ "b", "a" };
    try checkConflictTarget(&schema, pt, .{ .conflictTargetColumns = &both, .conflict = .update, .conflictTargetWhere = null });
}
