//! AUTOINCREMENT sequence bookkeeping (`sqlite_sequence`).
//!
//! Responsibility: ensure/read/write the `sqlite_sequence(name, seq)`
//! table and apply AUTOINCREMENT assignment for inserts. All functions take
//! a generic schema (`anytype`) to avoid a `schema.zig` import cycle; the
//! schema must expose `find`, `findConst`, `createTable`, `appendRow`, and
//! `allocator`. Borrowed table names; new row names are duped by `appendRow`.
//!
//! Dependencies: `vm/value.zig` for `Value` only. Lifetime: no owned state;
//! `setSequenceValue`/`applyAutoincrement` mutate the schema's sequence rows.
//! Errors: `OutOfMemory`, `InvalidSql` (two AUTOINCREMENT columns),
//! `ConstraintViolation` (explicit non-integer or overflow past maxInt).

const std = @import("std");
const Value = @import("../vm/value.zig").Value;

/// Ensure the `sqlite_sequence(name, seq)` table exists. Idempotent.
pub fn ensureSequenceTable(schema: anytype) !void {
    if (schema.find("sqlite_sequence") != null) return;
    const ast = @import("../sql/ast.zig");
    const definitions = [_]ast.ColumnDef{
        .{ .name = "name", .typeName = "TEXT" },
        .{ .name = "seq", .typeName = "INTEGER" },
    };
    try schema.createTable("sqlite_sequence", &definitions, &.{});
}

/// Current AUTOINCREMENT sequence for a table, or 0 when absent.
///
/// Borrowed name; never fails.
pub fn sequenceValue(schema: anytype, tableName: []const u8) i64 {
    const sequence = schema.findConst("sqlite_sequence") orelse return 0;
    if (sequence.columns.len < 2) return 0;
    for (sequence.rows.items) |row| {
        if (row.values.len != sequence.columns.len) continue;
        if (row.values[0] != .text) continue;
        if (!std.ascii.eqlIgnoreCase(row.values[0].text, tableName)) continue;
        if (row.values[1] == .integer) return row.values[1].integer;
        return 0;
    }
    return 0;
}

/// Set the AUTOINCREMENT sequence, creating the row when absent.
///
/// Borrowed name; dupes the name for new rows.
pub fn setSequenceValue(schema: anytype, tableName: []const u8, next: i64) !void {
    try ensureSequenceTable(schema);
    const sequence = schema.find("sqlite_sequence").?;
    for (sequence.rows.items) |*row| {
        if (row.values.len != sequence.columns.len) continue;
        if (row.values[0] != .text) continue;
        if (!std.ascii.eqlIgnoreCase(row.values[0].text, tableName)) continue;
        const exprEvaluator = @import("../sql/expr.zig");
        exprEvaluator.freeValue(schema.allocator, row.values[1]);
        row.values[1] = .{ .integer = next };
        return;
    }
    const nameValue = Value{ .text = tableName };
    const seqValue = Value{ .integer = next };
    try schema.appendRow(sequence, &.{ nameValue, seqValue });
}

/// Assign AUTOINCREMENT for one insert row: NULL becomes max+1 (tracked in
/// the sequence table), an explicit integer bumps the sequence, anything
/// else fails. Mutates `values[alias]` in place.
pub fn applyAutoincrement(schema: anytype, table: anytype, values: anytype) !void {
    var columnIdx: ?usize = null;
    for (table.columns, 0..) |column, index| if (column.autoincrement) {
        if (columnIdx != null) return error.InvalidSql;
        columnIdx = index;
    };
    const alias = columnIdx orelse return;
    switch (values[alias]) {
        .null => {
            var max = sequenceValue(schema, table.name);
            for (table.rows.items) |existing| {
                switch (existing.values[alias]) {
                    .integer => |current| {
                        if (current > max) max = current;
                    },
                    else => {},
                }
            }
            if (max == std.math.maxInt(i64)) return error.ConstraintViolation;
            const next = max + 1;
            try setSequenceValue(schema, table.name, next);
            values[alias] = .{ .integer = next };
        },
        .integer => |explicit| {
            if (explicit > sequenceValue(schema, table.name)) try setSequenceValue(schema, table.name, explicit);
        },
        else => return error.ConstraintViolation,
    }
}

test "sequence tracks max plus explicit bumps" {
    const Schema = @import("schema.zig").Schema;
    const ast = @import("../sql/ast.zig");
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true, .autoincrement = true },
    };
    try schema.createTable("t", &defs, &.{});
    try std.testing.expectEqual(@as(i64, 0), sequenceValue(&schema, "t"));
    try setSequenceValue(&schema, "t", 41);
    try std.testing.expectEqual(@as(i64, 41), sequenceValue(&schema, "t"));
    try std.testing.expect(schema.find("sqlite_sequence") != null);
}
