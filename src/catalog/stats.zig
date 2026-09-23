//! ANALYZE statistics (`sqlite_stat1`) management.
//!
//! Responsibility: ensure/read/clear the `sqlite_stat1(tbl, idx, stat)`
//! table and append table/index selectivity entries used by the planner.
//! All functions take a generic schema (`anytype`) to avoid a `schema.zig`
//! import cycle; the schema must expose `find`, `findConst`, `createTable`,
//! `appendRow`, `columnIndex`, `indexPredicateHolds`, and `allocator`.
//!
//! Dependencies: `sql/ast.zig` for column defs, `sql/expr.zig` for key
//! evaluation and value frees, `vm/value.zig` for `Value`. Lifetime: stat
//! rows are schema-owned dupes; transient evaluation values are freed
//! internally. Errors: `OutOfMemory`, `SchemaMismatch`, `UnknownColumn`.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");
const exprEvaluator = @import("../sql/expr.zig");

/// Canonical `valuesEqual` for stat key comparison: NULL==NULL, ints by
/// value, reals numerically, texts/blobs by bytes. Borrowed inputs.
pub fn valuesEqual(left: Value, right: Value) bool {
    return switch (left) {
        .null => right == .null,
        .integer => |value| switch (right) {
            .integer => |other| value == other,
            else => false,
        },
        .real => |value| switch (right) {
            .real => |other| value == other,
            .integer => |other| value == @as(f64, @floatFromInt(other)),
            else => false,
        },
        .text => |value| switch (right) {
            .text => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .blob => |value| switch (right) {
            .blob => |other| std.mem.eql(u8, value, other),
            else => false,
        },
    };
}

fn positionIsUnique(index: anytype, position: usize) bool {
    return index.unique and position + 1 == index.columns.len;
}

fn statKeyValue(schema: anytype, table: anytype, index: anytype, colNames: []const []const u8, position: usize, values: []const Value) !Value {
    if (index.keyExpr(position)) |key| return exprEvaluator.eval(schema.allocator, colNames, values, key);
    const columnIdx = schema.columnIndex(table, index.columns[position]) orelse return error.UnknownColumn;
    return switch (values[columnIdx]) {
        .text => |text| .{ .text = try schema.allocator.dupe(u8, text) },
        .blob => |blob| .{ .blob = try schema.allocator.dupe(u8, blob) },
        else => |value| value,
    };
}

fn statPrefixDistinct(schema: anytype, table: anytype, index: anytype, colNames: []const []const u8, rows: anytype, prefixLen: usize) !usize {
    var distinct: usize = 0;
    for (rows, 0..) |row, rowIndex| {
        var seen = false;
        for (rows[0..rowIndex]) |other| {
            var same = true;
            for (0..prefixLen) |position| {
                const left = try statKeyValue(schema, table, index, colNames, position, row.values);
                defer exprEvaluator.freeValue(schema.allocator, left);
                const right = try statKeyValue(schema, table, index, colNames, position, other.values);
                defer exprEvaluator.freeValue(schema.allocator, right);
                if (left == .null or right == .null) {
                    if (left != .null or right != .null) same = false;
                    continue;
                }
                if (!valuesEqual(left, right)) same = false;
            }
            if (same) {
                seen = true;
                break;
            }
        }
        if (!seen) distinct += 1;
    }
    return distinct;
}

/// Ensure the `sqlite_stat1` table exists with the canonical shape.
pub fn ensureStatTable(schema: anytype) !@TypeOf(schema.find("x").?) {
    if (schema.find("sqlite_stat1")) |existing| {
        if (existing.columns.len != 3) return error.SchemaMismatch;
        for (existing.columns, 0..) |column, index| {
            const expected: []const u8 = if (index == 0) "tbl" else if (index == 1) "idx" else "stat";
            if (!std.ascii.eqlIgnoreCase(column.name, expected)) return error.SchemaMismatch;
        }
        return existing;
    }
    const definitions = [_]ast.ColumnDef{
        .{ .name = "tbl", .typeName = "TEXT" },
        .{ .name = "idx", .typeName = "TEXT" },
        .{ .name = "stat", .typeName = "TEXT" },
    };
    try schema.createTable("sqlite_stat1", &definitions, &.{});
    return schema.find("sqlite_stat1").?;
}

/// Delete stat rows for a table (optionally one index). `null` table clears
/// all; `null` index with a table clears the table scope. No-op when the
/// stat table is absent. Never fails.
pub fn clearStatScope(schema: anytype, tableName: ?[]const u8, indexName: ?[]const u8) void {
    const stat = schema.find("sqlite_stat1") orelse return;
    var position = stat.rows.items.len;
    while (position > 0) {
        position -= 1;
        const row = stat.rows.items[position];
        if (row.values.len != 3) continue;
        if (tableName) |wanted| {
            if (row.values[0] != .text or !std.ascii.eqlIgnoreCase(row.values[0].text, wanted)) continue;
            if (indexName) |wantedIndex| {
                if (row.values[1] != .text or !std.ascii.eqlIgnoreCase(row.values[1].text, wantedIndex)) continue;
            }
        } else if (indexName != null) {
            continue;
        }
        const removed = stat.rows.orderedRemove(position);
        for (removed.values) |value| exprEvaluator.freeValue(schema.allocator, value);
        schema.allocator.free(removed.values);
    }
}

/// Table row count from the stat table (`tbl` row with NULL `idx`), or null
/// when absent/unparseable. Borrowed name; never fails.
pub fn statRowCount(schema: anytype, tableName: []const u8) ?usize {
    const stat = schema.findConst("sqlite_stat1") orelse return null;
    var tableIdx: ?usize = null;
    var idxIdx: ?usize = null;
    var statIdx: ?usize = null;
    for (stat.columns, 0..) |column, index| {
        if (std.ascii.eqlIgnoreCase(column.name, "tbl")) tableIdx = index;
        if (std.ascii.eqlIgnoreCase(column.name, "idx")) idxIdx = index;
        if (std.ascii.eqlIgnoreCase(column.name, "stat")) statIdx = index;
    }
    const tIdx = tableIdx orelse return null;
    const iIdx = idxIdx orelse return null;
    const sIdx = statIdx orelse return null;
    for (stat.rows.items) |row| {
        if (row.values.len != stat.columns.len) continue;
        if (row.values[tIdx] != .text) continue;
        if (!std.ascii.eqlIgnoreCase(row.values[tIdx].text, tableName)) continue;
        if (row.values[iIdx] != .null) continue;
        if (row.values[sIdx] != .text) continue;
        const count = std.fmt.parseInt(usize, std.mem.trim(u8, row.values[sIdx].text, " \t"), 10) catch continue;
        return count;
    }
    return null;
}

/// Append a table row-count entry to `sqlite_stat1`.
pub fn collectTableStats(schema: anytype, table: anytype) !void {
    const stat = try ensureStatTable(schema);
    const countText = try std.fmt.allocPrint(schema.allocator, "{d}", .{table.rows.items.len});
    defer schema.allocator.free(countText);
    const row = [_]Value{ .{ .text = table.name }, .null, .{ .text = countText } };
    try schema.appendRow(stat, &row);
}

/// Append an index selectivity entry (`count avg-per-prefix...`) for rows
/// matching the partial predicate.
pub fn collectIndexStats(schema: anytype, table: anytype, index: anytype) !void {
    const stat = try ensureStatTable(schema);
    var colNames = try schema.allocator.alloc([]const u8, table.columns.len);
    defer schema.allocator.free(colNames);
    for (table.columns, 0..) |col, idx| colNames[idx] = col.name;
    var matched = std.ArrayList(@TypeOf(table.rows.items[0])).empty;
    defer matched.deinit(schema.allocator);
    for (table.rows.items) |row| {
        if (try schema.indexPredicateHolds(table, index, row.values)) try matched.append(schema.allocator, row);
    }
    var text = std.ArrayList(u8).empty;
    defer text.deinit(schema.allocator);
    const countText = try std.fmt.allocPrint(schema.allocator, "{d}", .{matched.items.len});
    defer schema.allocator.free(countText);
    try text.appendSlice(schema.allocator, countText);
    for (0..index.columns.len) |prefixLen| {
        const distinct = try statPrefixDistinct(schema, table, index, colNames, matched.items, prefixLen + 1);
        var average: usize = 0;
        if (distinct != 0) average = (matched.items.len + distinct / 2) / distinct;
        if (positionIsUnique(index, prefixLen)) average = 1;
        const averageText = try std.fmt.allocPrint(schema.allocator, " {d}", .{average});
        defer schema.allocator.free(averageText);
        try text.appendSlice(schema.allocator, averageText);
    }
    const statText = try text.toOwnedSlice(schema.allocator);
    defer schema.allocator.free(statText);
    const row = [_]Value{ .{ .text = table.name }, .{ .text = index.name }, .{ .text = statText } };
    try schema.appendRow(stat, &row);
}

test "stat table round-trips counts" {
    const Schema = @import("schema.zig").Schema;
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER" }};
    try schema.createTable("t", &defs, &.{});
    try collectTableStats(&schema, schema.find("t").?);
    try std.testing.expectEqual(@as(?usize, 0), statRowCount(&schema, "t"));
    clearStatScope(&schema, "t", null);
    try std.testing.expectEqual(@as(?usize, null), statRowCount(&schema, "t"));
}
