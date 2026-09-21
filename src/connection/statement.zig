//! Reusable statements with bound parameters.
//!
//! Owns SQL text and params; borrows the connection and payloads.
//! `query` returns an owned `Result`; `finalize` frees the statement.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const Result = @import("result.zig").Result;

/// Owned prepared statement. See module docs: owns `sql` + `parameters`,
/// borrows `connection` + hooks, borrows bound text/blob payloads.
pub const Statement = struct {
    /// Borrowed live connection. Must outlive the statement.
    connection: *anyopaque,
    /// Owned SQL text. Freed by `finalize`; unusable afterwards.
    sql: []u8,
    /// Borrowed allocator that owns `sql`/`parameters`. Must outlive `finalize`.
    allocator: std.mem.Allocator,
    /// Owned bound parameters (1-based externally). Text/blob payloads inside
    /// are BORROWED from the `bind` caller — never freed here.
    parameters: std.ArrayList(Value),
    /// Borrowed write executor: runs `sql` with the current parameters.
    executeFn: *const fn (*anyopaque, []const u8, []const Value) anyerror!void,
    /// Borrowed read executor: returns an owned `Result` (caller deinits).
    queryFn: *const fn (*anyopaque, []const u8, []const Value) anyerror!Result,
    /// Finalize guard. Set by `finalize`; makes a second call a safe no-op.
    /// Defaults to false so existing struct literals keep compiling.
    finalized: bool = false,

    /// Bind `value` at 1-based `index`, growing with NULL fill as needed.
    /// Text/blob payloads stay caller-owned. Fails `InvalidParameter` on 0.
    pub fn bind(self: *Statement, index: usize, value: anytype) !void {
        if (index == 0) return error.InvalidParameter;
        if (self.finalized) return error.InvalidParameter;
        const converted: Value = bindValue(value);
        while (self.parameters.items.len < index) try self.parameters.append(self.allocator, .null);
        self.parameters.items[index - 1] = converted;
    }

    /// Execute as a write with the current bindings. Borrowed payloads must
    /// still be alive. Propagates engine errors.
    pub fn step(self: *Statement) !void {
        return self.executeFn(self.connection, self.sql, self.parameters.items);
    }

    /// Execute as a read with the current bindings. Returns an owned `Result`
    /// the caller must `deinit`. Borrowed payloads must still be alive.
    pub fn query(self: *Statement) !Result {
        return self.queryFn(self.connection, self.sql, self.parameters.items);
    }

    /// Clear all bindings for reuse, keeping capacity. `sql` is untouched.
    /// Safe to call on a fresh or already-reset statement.
    pub fn reset(self: *Statement) void {
        self.parameters.clearRetainingCapacity();
    }

    /// Free `sql` and the parameter list and reset both to empty, making a
    /// second `finalize` a safe no-op. After the first call the statement
    /// must not be used. Note: bound text/blob payloads are caller-owned and
    /// are NOT freed here.
    pub fn finalize(self: *Statement) void {
        if (self.finalized) return;
        self.finalized = true;
        self.parameters.deinit(self.allocator);
        self.parameters = .empty;
        self.allocator.free(self.sql);
        self.sql = &.{};
    }

    /// Convert a Zig scalar to a borrowed `Value` for binding. `Value`
    /// passes through; optionals/null map to NULL; bools to 0/1; ints/floats
    /// convert; pointers bind as TEXT (caller keeps the bytes alive).
    /// Anything else is a comptime error.
    fn bindValue(value: anytype) Value {
        const T = @TypeOf(value);
        if (T == Value) return value;
        if (@typeInfo(T) == .optional) {
            if (value) |present| return bindValue(present);
            return .null;
        }
        if (@typeInfo(T) == .null) return .null;
        return switch (@typeInfo(T)) {
            .bool => .{ .integer = if (value) 1 else 0 },
            .int, .comptime_int => .{ .integer = @intCast(value) },
            .float, .comptime_float => .{ .real = @floatCast(value) },
            .pointer => .{ .text = value },
            else => @compileError("unsupported SQL parameter type"),
        };
    }
};

test "statement parameter binding stores values" {
    var parameters = std.ArrayList(Value).empty;
    defer parameters.deinit(std.testing.allocator);
    var statement = Statement{ .connection = undefined, .sql = try std.testing.allocator.dupe(u8, ""), .allocator = std.testing.allocator, .parameters = parameters, .executeFn = undefined, .queryFn = undefined };
    defer statement.finalize();
    try statement.bind(1, 12);
    try std.testing.expectEqual(@as(i64, 12), statement.parameters.items[0].integer);
}

test "statement binding rejects index zero fills gaps and rebinds" {
    var parameters = std.ArrayList(Value).empty;
    defer parameters.deinit(std.testing.allocator);
    var statement = Statement{ .connection = undefined, .sql = try std.testing.allocator.dupe(u8, ""), .allocator = std.testing.allocator, .parameters = parameters, .executeFn = undefined, .queryFn = undefined };
    defer statement.finalize();
    try std.testing.expectError(error.InvalidParameter, statement.bind(0, 1));
    // Skipped positions fill with NULL, like an unbound parameter.
    try statement.bind(3, "late");
    try std.testing.expectEqual(@as(usize, 3), statement.parameters.items.len);
    try std.testing.expect(statement.parameters.items[0] == .null);
    try std.testing.expect(statement.parameters.items[1] == .null);
    try std.testing.expectEqualStrings("late", statement.parameters.items[2].text);
    // Rebinding overwrites in place without growing the list.
    try statement.bind(1, 42);
    try statement.bind(3, null);
    try std.testing.expectEqual(@as(usize, 3), statement.parameters.items.len);
    try std.testing.expectEqual(@as(i64, 42), statement.parameters.items[0].integer);
    try std.testing.expect(statement.parameters.items[2] == .null);
    // reset() clears bindings for statement reuse.
    statement.reset();
    try std.testing.expectEqual(@as(usize, 0), statement.parameters.items.len);
}

test "finalize is idempotent and retires the statement" {
    var statement = Statement{ .connection = undefined, .sql = try std.testing.allocator.dupe(u8, "SELECT 1"), .allocator = std.testing.allocator, .parameters = .empty, .executeFn = undefined, .queryFn = undefined };
    try statement.bind(1, 7);
    try statement.bind(2, "text");
    try std.testing.expectEqual(@as(usize, 2), statement.parameters.items.len);
    statement.finalize();
    try std.testing.expect(statement.finalized);
    try std.testing.expectEqual(@as(usize, 0), statement.sql.len);
    // Second finalize is a safe no-op; binding after finalize is refused.
    statement.finalize();
    try std.testing.expectError(error.InvalidParameter, statement.bind(1, 1));
}
