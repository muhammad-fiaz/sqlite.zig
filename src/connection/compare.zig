//! Pure value comparison and ordering helpers for SQL predicates.
//!
//! This module extracts the stateless comparison semantics previously embedded
//! in `src/connection/connection.zig` so future refactors can evaluate
//! `sql.ast.CompareOp` predicates without depending on `Connection`.
//!
//! Relationship to `vm.Value`: `vm/value.zig` already owns the canonical total
//! ordering (`Value.order`), tri-state `Value.compare`, and strict-identity
//! `Value.sameValue`. The helpers here are a thin `sql.ast.CompareOp` adapter
//! over that model: ordering operators (`=`, `<>`, `<`, `<=`, `>`, `>=`)
//! delegate to collation-aware ordering, while every other `CompareOp`
//! (`LIKE`, `GLOB`, `IN`, `BETWEEN`, `IS`, ...) returns `false` because those
//! operators are evaluated elsewhere (see `connection/pattern.zig` and the
//! expression evaluator). Prefer `Value.compare`/`Value.order` directly for
//! new code that already speaks `vm.value.Comparison`.
//!
//! Collation note: only `NOCASE` (ASCII fold, text-vs-text only) affects the
//! legacy `compareCollated` path, matching `connection.zig`. Full `RTRIM` and
//! cross-type total ordering live on `Value.order`; this adapter keeps the
//! historical subset so extracted behaviour stays byte-identical.
//!
//! Ownership and errors: all functions are pure and infallible. `Value`
//! payloads (`text`/`blob` slices) are borrowed; callers retain ownership and
//! must handle SQL `NULL` propagation before/after calling (any `NULL`
//! operand yields `false` here, i.e. SQL `UNKNOWN` in a `WHERE` filter).

const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");

/// Reports whether a `COLLATE` name selects case-insensitive comparison.
///
/// Only `NOCASE` (any ASCII case) returns `true`; `null` and every other name
/// (including `BINARY` and `RTRIM`) return `false` on this legacy path.
pub fn isNocase(collate: ?[]const u8) bool {
    if (collate) |name| return std.ascii.eqlIgnoreCase(name, "nocase");
    return false;
}

/// Ordering-only comparison with binary collation.
///
/// Returns `false` when either operand is `NULL` and for every non-ordering
/// `CompareOp` (`LIKE`/`GLOB`/`REGEXP`/`MATCH`/`IS`/`IN`/`BETWEEN`/quantified
/// predicates); those operators are not comparison operators here.
pub fn compare(left: Value, op: ast.CompareOp, right: Value) bool {
    return compareCollated(left, op, right, null);
}

/// Ordering-only comparison with an optional `COLLATE` name.
///
/// `NOCASE` folds ASCII text-vs-text ordering; all other type pairs use the
/// engine's cross-type rank (numeric < text < blob, numerics compared across
/// `integer`/`real`). `NULL` on either side yields `false`. Non-ordering
/// `CompareOp` variants yield `false`.
pub fn compareCollated(left: Value, op: ast.CompareOp, right: Value, collate: ?[]const u8) bool {
    if (left == .null or right == .null) return false;
    if (isNocase(collate)) {
        if (left == .text and right == .text) {
            var li: usize = 0;
            var ri: usize = 0;
            const l = left.text;
            const r = right.text;
            while (li < l.len and ri < r.len) : ({
                li += 1;
                ri += 1;
            }) {
                const a = std.ascii.toLower(l[li]);
                const b = std.ascii.toLower(r[ri]);
                if (a != b) {
                    const less = a < b;
                    return switch (op) {
                        .equal => false,
                        .notEqual => true,
                        .less => less,
                        .lessEqual => less,
                        .greater => !less,
                        .greaterEqual => !less,
                        else => false,
                    };
                }
            }
            const result: i8 = if (l.len < r.len) -1 else if (l.len > r.len) 1 else 0;
            return switch (op) {
                .equal => result == 0,
                .notEqual => result != 0,
                .less => result < 0,
                .lessEqual => result <= 0,
                .greater => result > 0,
                .greaterEqual => result >= 0,
                else => false,
            };
        }
    }
    if (left == .null or right == .null) return false;
    const result: i8 = switch (left) {
        .integer => |l| switch (right) {
            .integer => |r| if (l < r) -1 else if (l > r) 1 else 0,
            .real => |r| if (@as(f64, @floatFromInt(l)) < r) -1 else if (@as(f64, @floatFromInt(l)) > r) 1 else 0,
            else => -1,
        },
        .real => |l| switch (right) {
            .integer => |r| if (l < @as(f64, @floatFromInt(r))) -1 else if (l > @as(f64, @floatFromInt(r))) 1 else 0,
            .real => |r| if (l < r) -1 else if (l > r) 1 else 0,
            else => -1,
        },
        .text => |l| switch (right) {
            .text => |r| if (std.mem.order(u8, l, r) == .lt) -1 else if (std.mem.order(u8, l, r) == .gt) 1 else 0,
            else => -1,
        },
        .blob => |l| switch (right) {
            .blob => |r| if (std.mem.order(u8, l, r) == .lt) -1 else if (std.mem.order(u8, l, r) == .gt) 1 else 0,
            else => -1,
        },
        .null => 0,
    };
    return switch (op) {
        .equal => result == 0,
        .notEqual => result != 0,
        .less => result < 0,
        .lessEqual => result <= 0,
        .greater => result > 0,
        .greaterEqual => result >= 0,
        .like, .notLike, .glob, .notGlob, .regexp, .notRegexp, .match, .notMatch, .isNull, .isNotNull, .isValue, .isNotValue, .isDistinct, .isNotDistinct, .between, .notBetween, .in, .notIn, .exists, .notExists, .isTrue => false,
    };
}

/// Strict value identity: same storage type and equal payload.
///
/// Unlike `compare` (which folds numerics across `integer`/`real`),
/// `sameValue` returns `false` across types (`1` integer vs `1.0` real) and
/// for `NULL` vs non-`NULL`. Used for FK/UNIQUE identity and row dedup.
pub fn sameValue(left: Value, right: Value) bool {
    return switch (left) {
        .null => right == .null,
        .integer => |value| switch (right) {
            .integer => |other| value == other,
            else => false,
        },
        .real => |value| switch (right) {
            .real => |other| value == other,
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

/// Row identity: equal length and element-wise `sameValue`.
pub fn rowsEqual(left: []const Value, right: []const Value) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| switch (a) {
        .null => if (b != .null) return false,
        .integer => |value| if (b != .integer or b.integer != value) return false,
        .real => |value| if (b != .real or b.real != value) return false,
        .text => |value| if (b != .text or !std.mem.eql(u8, value, b.text)) return false,
        .blob => |value| if (b != .blob or !std.mem.eql(u8, value, b.blob)) return false,
    };
    return true;
}

/// One resolved sort key: which output column to compare and its direction.
pub const SortKey = struct {
    colIdx: usize,
    descending: bool = false,
};

/// Multi-key row ordering over already-materialized rows (binary collation).
///
/// Compares `a`/`b` key by key with `Value.order(..., .binary)`; the first
/// non-equal key decides (inverted when `descending`). Returns `.eq` when all
/// keys tie. Callers must guarantee every `colIdx` is in bounds.
pub fn compareRowsByKeys(a: []const Value, b: []const Value, sortKeys: []const SortKey) std.math.Order {
    for (sortKeys) |key| {
        const ord = a[key.colIdx].order(b[key.colIdx], .binary);
        if (ord == .eq) continue;
        return if (key.descending) ord.invert() else ord;
    }
    return .eq;
}

test "isNocase only honors nocase" {
    try std.testing.expect(isNocase("NOCASE"));
    try std.testing.expect(isNocase("nocase"));
    try std.testing.expect(!isNocase(null));
    try std.testing.expect(!isNocase("BINARY"));
    try std.testing.expect(!isNocase("rtrim"));
}

test "compare orders numerics text and blobs with null as unknown" {
    const one: Value = .{ .integer = 1 };
    const two: Value = .{ .integer = 2 };
    const real_two: Value = .{ .real = 2.0 };
    const text_a: Value = .{ .text = "a" };
    const text_b: Value = .{ .text = "b" };

    try std.testing.expect(compare(one, .less, two));
    try std.testing.expect(compare(two, .greaterEqual, real_two));
    try std.testing.expect(compare(text_a, .less, text_b));
    try std.testing.expect(!compare(.null, .equal, .null));
    try std.testing.expect(!compare(one, .equal, .null));
    try std.testing.expect(!compare(one, .like, one));
    try std.testing.expect(!compare(one, .in, one));
}

test "compareCollated folds ascii case for text under nocase" {
    const lower: Value = .{ .text = "apple" };
    const upper: Value = .{ .text = "APPLE" };
    const later: Value = .{ .text = "Banana" };

    try std.testing.expect(!compare(lower, .equal, upper));
    try std.testing.expect(compareCollated(lower, .equal, upper, "NOCASE"));
    try std.testing.expect(compareCollated(lower, .less, later, "nocase"));
    try std.testing.expect(compareCollated(later, .greater, lower, "NOCASE"));
    try std.testing.expect(!compareCollated(lower, .like, upper, "NOCASE"));
}

test "sameValue is strict across storage types" {
    try std.testing.expect(sameValue(.null, .null));
    try std.testing.expect(!sameValue(.null, .{ .integer = 0 }));
    try std.testing.expect(sameValue(.{ .integer = 1 }, .{ .integer = 1 }));
    try std.testing.expect(!sameValue(.{ .integer = 1 }, .{ .real = 1.0 }));
    try std.testing.expect(sameValue(.{ .text = "x" }, .{ .text = "x" }));
    try std.testing.expect(!sameValue(.{ .text = "x" }, .{ .blob = "x" }));
}

test "rowsEqual checks length then element identity" {
    const left = [_]Value{ .{ .integer = 1 }, .{ .text = "a" }, .null };
    const same = [_]Value{ .{ .integer = 1 }, .{ .text = "a" }, .null };
    const diff = [_]Value{ .{ .integer = 1 }, .{ .text = "b" }, .null };
    const short_row = [_]Value{.{ .integer = 1 }};
    try std.testing.expect(rowsEqual(&left, &same));
    try std.testing.expect(!rowsEqual(&left, &diff));
    try std.testing.expect(!rowsEqual(&left, &short_row));
}

test "compareRowsByKeys honors key order and direction" {
    const a = [_]Value{ .{ .integer = 1 }, .{ .text = "b" } };
    const b = [_]Value{ .{ .integer = 1 }, .{ .text = "a" } };
    const c = [_]Value{ .{ .integer = 2 }, .{ .text = "a" } };

    const by_second = [_]SortKey{.{ .colIdx = 1 }};
    try std.testing.expect(compareRowsByKeys(&a, &b, &by_second) == .gt);

    const by_first_desc = [_]SortKey{.{ .colIdx = 0, .descending = true }};
    try std.testing.expect(compareRowsByKeys(&a, &c, &by_first_desc) == .gt);
    try std.testing.expect(compareRowsByKeys(&a, &a, &by_first_desc) == .eq);
}
