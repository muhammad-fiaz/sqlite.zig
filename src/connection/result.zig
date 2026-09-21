//! Owned query results.
//!
//! `Result` owns column names and payloads; rows borrow it.
//! Caller calls `deinit` once; lookups fail on bad names.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;

/// Borrowed view of one result row. `columns` and `values` point into the
/// parent `Result`; the view dangles after the parent is `deinit`ed. Values
/// are borrowed — duplicate text/blob payloads to retain them past `deinit`.
pub const DynamicRow = struct {
    columns: []const []const u8,
    values: []Value,

    /// Borrowed lookup by column name (case-insensitive). Fails
    /// `error.UnknownColumn` when absent. Panics when the row is empty only
    /// if the index itself is out of range — name misses are errors, not panics.
    pub fn get(self: @This(), name: []const u8) !Value {
        const index = findColumn(self.columns, name) orelse return error.UnknownColumn;
        return self.values[index];
    }

    /// Borrowed positional access. Panics when `index >= len`.
    pub fn at(self: @This(), index: usize) Value {
        return self.values[index];
    }

    /// Number of values in this row (always equals the parent's column count).
    pub fn len(self: @This()) usize {
        return self.values.len;
    }
};

/// Forward-only cursor over a borrowed `Result`. Holds no allocation; the
/// parent `Result` must outlive the iterator. Exhaustion yields `null`.
pub const RowIter = struct {
    result: *const Result,
    index: usize = 0,

    /// Borrow the next row view, or `null` when exhausted.
    pub fn next(self: *RowIter) ?DynamicRow {
        if (self.index >= self.result.rows.len) return null;
        const row = self.result.row(self.index);
        self.index += 1;
        return row;
    }
};

fn findColumn(columns: []const []const u8, name: []const u8) ?usize {
    for (columns, 0..) |column, index| {
        if (std.ascii.eqlIgnoreCase(column, name)) return index;
    }
    return null;
}

/// Owned, eagerly materialized result. See module docs: caller `deinit`s
/// exactly once; `DynamicRow`/`RowIter` borrow it; text/blob payloads are owned.
pub const Result = struct {
    /// Allocator that owns every string/payload/row slice below. Borrowed
    /// handle — must stay valid through `deinit`, but owns no connection state.
    allocator: std.mem.Allocator,
    /// Owned column-name strings, one per result column (may be empty).
    columns: []const []const u8,
    /// Owned rows; each inner slice is owned and holds owned text/blob payloads.
    rows: []const []Value,
    /// Modified-row count for writes; 0 for reads.
    changes: usize = 0,

    /// Free every column name, payload, row, and the top-level slices, then
    /// reset them to empty so a second `deinit` is a safe no-op. After the
    /// first call every view into this result dangles.
    pub fn deinit(self: *Result) void {
        for (self.rows) |values| {
            for (values) |value| switch (value) {
                .text => |bytes| self.allocator.free(bytes),
                .blob => |bytes| self.allocator.free(bytes),
                else => {},
            };
            self.allocator.free(values);
        }
        for (self.columns) |column| self.allocator.free(column);
        self.allocator.free(self.rows);
        self.allocator.free(self.columns);
        self.rows = &.{};
        self.columns = &.{};
        self.changes = 0;
    }

    /// Number of rows.
    pub fn count(self: Result) usize {
        return self.rows.len;
    }

    /// True when there are no rows.
    pub fn isEmpty(self: Result) bool {
        return self.rows.len == 0;
    }

    /// Borrowed row slice at `index`. Panics when out of range. The slice and
    /// its payloads dangle after `deinit`.
    pub fn at(self: Result, index: usize) []Value {
        return self.rows[index];
    }

    /// Borrowed view of all rows. Dangles after `deinit`.
    pub fn slice(self: Result) []const []Value {
        return self.rows;
    }

    /// Case-insensitive column position, or `null` when absent. Never fails.
    pub fn columnIndex(self: Result, name: []const u8) ?usize {
        return findColumn(self.columns, name);
    }

    /// Borrowed value at (`rowIndex`, `name`). Fails `UnknownColumn` on a bad
    /// name; panics on a bad row index.
    pub fn get(self: Result, rowIndex: usize, name: []const u8) !Value {
        return self.row(rowIndex).get(name);
    }

    /// Borrowed row view at `index`. Panics when out of range. Dangles after
    /// `deinit`.
    pub fn row(self: *const Result, index: usize) DynamicRow {
        return .{ .columns = self.columns, .values = self.rows[index] };
    }

    /// Forward iterator borrowing this result. Do not `deinit` mid-iteration.
    pub fn iter(self: *const Result) RowIter {
        return .{ .result = self };
    }
};

test "empty result reports zero rows and deinitializes safely" {
    const alloc = std.testing.allocator;
    var r = Result{ .allocator = alloc, .columns = try alloc.alloc([]const u8, 0), .rows = try alloc.alloc([]Value, 0) };
    // No rows, no columns: every accessor is well-defined.
    try std.testing.expectEqual(@as(usize, 0), r.count());
    try std.testing.expect(r.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), r.slice().len);
    try std.testing.expect(r.columnIndex("anything") == null);
    // No row exists, so value lookup is not exercised here (get/row/at
    // panic on an out-of-range row index by design; UnknownColumn is
    // covered by the non-empty test below).
    var it = r.iter();
    try std.testing.expect(it.next() == null);
    r.deinit();
    // Idempotent deinit: second call is a safe no-op after the reset.
    r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "rows columns count and case-insensitive lookup" {
    const alloc = std.testing.allocator;
    const cols = try alloc.alloc([]const u8, 2);
    cols[0] = try alloc.dupe(u8, "ID");
    cols[1] = try alloc.dupe(u8, "Name");
    const rows = try alloc.alloc([]Value, 2);
    const r0 = try alloc.alloc(Value, 2);
    r0[0] = .{ .integer = 1 };
    r0[1] = .{ .text = try alloc.dupe(u8, "ada") };
    const r1 = try alloc.alloc(Value, 2);
    r1[0] = .{ .integer = 2 };
    r1[1] = .{ .blob = try alloc.dupe(u8, "blob") };
    rows[0] = r0;
    rows[1] = r1;
    var r = Result{ .allocator = alloc, .columns = cols, .rows = rows, .changes = 2 };
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.count());
    try std.testing.expect(!r.isEmpty());
    // Case-insensitive name resolution, first-match wins.
    try std.testing.expectEqual(@as(usize, 0), r.columnIndex("id").?);
    try std.testing.expectEqual(@as(usize, 1), r.columnIndex("NAME").?);
    try std.testing.expectEqual(@as(i64, 2), (try r.get(1, "id")).integer);
    try std.testing.expectEqualStrings("ada", (try r.get(0, "name")).text);
    try std.testing.expectError(error.UnknownColumn, r.get(0, "missing"));
    // Positional and row-view access borrow the same storage.
    try std.testing.expectEqual(@as(usize, 2), r.at(0).len);
    try std.testing.expectEqual(@as(usize, 2), r.row(1).len());
    try std.testing.expectEqual(@as(i64, 1), r.row(0).at(0).integer);
    // Iteration visits every row in order.
    var it = r.iter();
    try std.testing.expectEqual(@as(i64, 1), it.next().?.at(0).integer);
    try std.testing.expectEqual(@as(i64, 2), it.next().?.at(0).integer);
    try std.testing.expect(it.next() == null);
}
