//! Aggregate SQL functions (`count`, `sum`, `avg`, `min`, `max`, ...).
//!
//! Purpose: single authoritative streaming aggregate state machine behind
//! GROUP BY / window-aggregate paths. `AggKind.fromName` is also the
//! `functions.isAggregate` predicate, so naming stays in one place.
//!
//! Responsibilities: per-group `step` accumulation with DISTINCT dedup,
//! overflow-safe integer sums (widening to REAL), type-aware `min`/`max`,
//! and `group_concat`/`string_agg` string building.
//!
//! Dependencies: `std`, `../../vm/value.zig`, `scalar.zig` (`formatReal`).
//! Driven by `connection.zig` and `window.zig` (frame aggregates).
//!
//! Ownership/lifetime: `AggState` owns cloned `minVal`/`maxVal`, `concatPieces`
//! strings, and DISTINCT `seenValues`; release with `deinit`. `step` borrows
//! its input; `final` returns a fresh caller-owned `Value`.
//!
//! Error behavior: `step`/`final` fail only on OOM. NULL inputs are skipped
//! (except `count(*)` via `stepWildcard`); empty groups yield NULL except
//! `count` (0) and `total` (0.0).
//!
//! Invariants: `hasValue` tracks any non-NULL row; `isReal` forces REAL sums;
//! `separator` is borrowed (caller must keep it alive through `final`).
//!
//! SQLite compatibility: `avg`/`average` alias; `total` never returns NULL;
//! `sum` of all-NULL/empty is NULL; `group_concat` default separator `,`;
//! DISTINCT uses `sameValue` identity (int 1 != real 1.0).
// TODO(sql/aggregate): DISTINCT dedup is O(n^2) linear scan plus a full clone
// per distinct value; hostile 100k-row GROUP BY can blow time/memory.
// Expected: hash-based dedup with a size budget; tests: 10k-distinct perf
// bound + budget rejection. Subsystem: sql/functions.
// TODO(sql/aggregate): text `sum`/`avg` coercion uses strict trim+parse while
// scalar prefix parsing is lenient. Expected: shared coercion (see scalar
// TODO); tests: `'12x'` sum matrix identical across paths. Subsystem: sql/functions.

const std = @import("std");
const Value = @import("../../vm/value.zig").Value;
const scalar = @import("scalar.zig");

/// Aggregate function identity; `fromName` is the single name resolver.
pub const AggKind = enum {
    count,
    sum,
    total,
    avg,
    min,
    max,
    groupConcat,
    stringAgg,

    /// Case-insensitive name lookup; `average` maps to `avg`, else null.
    pub fn fromName(name: []const u8) ?AggKind {
        if (std.ascii.eqlIgnoreCase(name, "count")) return .count;
        if (std.ascii.eqlIgnoreCase(name, "sum")) return .sum;
        if (std.ascii.eqlIgnoreCase(name, "total")) return .total;
        if (std.ascii.eqlIgnoreCase(name, "avg") or std.ascii.eqlIgnoreCase(name, "average")) return .avg;
        if (std.ascii.eqlIgnoreCase(name, "min")) return .min;
        if (std.ascii.eqlIgnoreCase(name, "max")) return .max;
        if (std.ascii.eqlIgnoreCase(name, "group_concat")) return .groupConcat;
        if (std.ascii.eqlIgnoreCase(name, "string_agg")) return .stringAgg;
        return null;
    }
};

/// Streaming per-group accumulator; create with `init`, release with `deinit`.
pub const AggState = struct {
    /// Allocator for clones/pieces/seen-values.
    allocator: std.mem.Allocator,
    /// Which aggregate is being computed.
    kind: AggKind,
    /// Row/accumulation count (non-NULL rows, or all rows for count(*)).
    count: usize = 0,
    /// Integer sum accumulator (wraps; `isReal` set on overflow so `final` widens).
    sumInt: i64 = 0,
    /// Float sum accumulator (always maintained for sum/total/avg).
    sumReal: f64 = 0.0,
    /// True once a REAL input arrived or integer overflow occurred.
    isReal: bool = false,
    /// True once any non-NULL input arrived (drives NULL-vs-0 results).
    hasValue: bool = false,
    /// Current minimum (owned clone) or null when empty.
    minVal: ?Value = null,
    /// Current maximum (owned clone) or null when empty.
    maxVal: ?Value = null,
    /// `group_concat` separator (borrowed).
    separator: []const u8 = ",",
    /// Owned string pieces for concat (freed by `deinit`; joined by `final`).
    concatPieces: std.ArrayList([]const u8),
    /// Owned DISTINCT history (linear scan; see module TODO).
    seenValues: std.ArrayList(Value),

    /// Create an empty accumulator; `sep` borrows (defaults to `","`).
    pub fn init(allocator: std.mem.Allocator, kind: AggKind, sep: ?[]const u8) AggState {
        return .{
            .allocator = allocator,
            .kind = kind,
            .count = 0,
            .sumInt = 0,
            .sumReal = 0.0,
            .isReal = false,
            .hasValue = false,
            .minVal = null,
            .maxVal = null,
            .separator = sep orelse ",",
            .concatPieces = std.ArrayList([]const u8).empty,
            .seenValues = std.ArrayList(Value).empty,
        };
    }

    /// Release owned min/max, concat pieces, and DISTINCT history.
    pub fn deinit(self: *AggState) void {
        for (self.concatPieces.items) |piece| {
            self.allocator.free(piece);
        }
        self.concatPieces.deinit(self.allocator);
        for (self.seenValues.items) |v| {
            switch (v) {
                .text => |t| self.allocator.free(t),
                .blob => |b| self.allocator.free(b),
                else => {},
            }
        }
        self.seenValues.deinit(self.allocator);
        if (self.minVal) |v| {
            switch (v) {
                .text => |t| self.allocator.free(t),
                .blob => |b| self.allocator.free(b),
                else => {},
            }
        }
        if (self.maxVal) |v| {
            switch (v) {
                .text => |t| self.allocator.free(t),
                .blob => |b| self.allocator.free(b),
                else => {},
            }
        }
    }

    fn isDistinctDuplicate(self: *AggState, val: Value) !bool {
        for (self.seenValues.items) |seen| {
            if (seen.sameValue(val)) return true;
        }
        const cloned = try val.clone(self.allocator);
        try self.seenValues.append(self.allocator, cloned);
        return false;
    }

    /// Count one `count(*)` row (NULLs included; no-ops for other kinds).
    pub fn stepWildcard(self: *AggState) void {
        if (self.kind == .count) {
            self.count += 1;
        }
    }

    /// Accumulate one value; NULLs skipped (except count(*) path). OOM only error.
    /// `distinct` enables `sameValue` dedup. Integer overflow widens sums to REAL.
    pub fn step(self: *AggState, val: Value, distinct: bool) !void {
        if (self.kind == .count) {
            if (val == .null) return;
            if (distinct and try self.isDistinctDuplicate(val)) return;
            self.count += 1;
            return;
        }
        if (val == .null) return;
        if (distinct and try self.isDistinctDuplicate(val)) return;

        self.hasValue = true;
        self.count += 1;

        switch (self.kind) {
            .count => unreachable,
            .sum, .total, .avg => {
                switch (val) {
                    .integer => |i| {
                        const res = @addWithOverflow(self.sumInt, i);
                        self.sumInt = res[0];
                        if (res[1] != 0) self.isReal = true;
                        self.sumReal += @as(f64, @floatFromInt(i));
                    },
                    .real => |r| {
                        self.isReal = true;
                        self.sumReal += r;
                    },
                    .text => |t| {
                        if (std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10)) |i| {
                            const res = @addWithOverflow(self.sumInt, i);
                            self.sumInt = res[0];
                            if (res[1] != 0) self.isReal = true;
                            self.sumReal += @as(f64, @floatFromInt(i));
                        } else |_| {
                            if (std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n"))) |r| {
                                self.isReal = true;
                                self.sumReal += r;
                            } else |_| {}
                        }
                    },
                    .null, .blob => {},
                }
            },
            .min => {
                if (self.minVal == null or val.order(self.minVal.?, .binary) == .lt) {
                    if (self.minVal) |old| {
                        switch (old) {
                            .text => |t| self.allocator.free(t),
                            .blob => |b| self.allocator.free(b),
                            else => {},
                        }
                    }
                    self.minVal = try val.clone(self.allocator);
                }
            },
            .max => {
                if (self.maxVal == null or val.order(self.maxVal.?, .binary) == .gt) {
                    if (self.maxVal) |old| {
                        switch (old) {
                            .text => |t| self.allocator.free(t),
                            .blob => |b| self.allocator.free(b),
                            else => {},
                        }
                    }
                    self.maxVal = try val.clone(self.allocator);
                }
            },
            .groupConcat, .stringAgg => {
                var strPiece: []const u8 = undefined;
                switch (val) {
                    .text => |t| strPiece = try self.allocator.dupe(u8, t),
                    .blob => |b| strPiece = try self.allocator.dupe(u8, b),
                    .integer => |i| strPiece = try std.fmt.allocPrint(self.allocator, "{d}", .{i}),
                    .real => |r| strPiece = try scalar.formatReal(self.allocator, r),
                    .null => return,
                }
                try self.concatPieces.append(self.allocator, strPiece);
            },
        }
    }

    /// Alias for `final` kept for call-site compatibility.
    pub const result = final;

    /// Produce the aggregate result as a caller-owned `Value` (OOM only error).
    /// Empty groups: count=0, total=0.0, others NULL.
    pub fn final(self: *AggState) !Value {
        switch (self.kind) {
            .count => return .{ .integer = @intCast(self.count) },
            .sum => {
                if (!self.hasValue) return .null;
                if (self.isReal) return .{ .real = self.sumReal };
                return .{ .integer = self.sumInt };
            },
            .total => {
                return .{ .real = self.sumReal };
            },
            .avg => {
                if (self.count == 0) return .null;
                return .{ .real = self.sumReal / @as(f64, @floatFromInt(self.count)) };
            },
            .min => {
                if (self.minVal) |m| return try m.clone(self.allocator);
                return .null;
            },
            .max => {
                if (self.maxVal) |m| return try m.clone(self.allocator);
                return .null;
            },
            .groupConcat, .stringAgg => {
                if (self.concatPieces.items.len == 0) return .null;
                var totalLen: usize = 0;
                for (self.concatPieces.items, 0..) |piece, i| {
                    totalLen = totalLen +| piece.len;
                    if (i + 1 < self.concatPieces.items.len) totalLen = totalLen +| self.separator.len;
                }
                const out = try self.allocator.alloc(u8, totalLen);
                var curIdx: usize = 0;
                for (self.concatPieces.items, 0..) |piece, i| {
                    @memcpy(out[curIdx .. curIdx + piece.len], piece);
                    curIdx += piece.len;
                    if (i + 1 < self.concatPieces.items.len) {
                        @memcpy(out[curIdx .. curIdx + self.separator.len], self.separator);
                        curIdx += self.separator.len;
                    }
                }
                return .{ .text = out };
            },
        }
    }
};

test "aggregate normal behavior" {
    const alloc = std.testing.allocator;
    var c = AggState.init(alloc, .count, null);
    defer c.deinit();
    try c.step(.{ .integer = 1 }, false);
    try c.step(.null, false);
    c.stepWildcard();
    try std.testing.expectEqual(@as(i64, 2), (try c.final()).integer);

    var s = AggState.init(alloc, .sum, null);
    defer s.deinit();
    try s.step(.{ .integer = 2 }, false);
    try s.step(.{ .integer = 3 }, false);
    try std.testing.expectEqual(@as(i64, 5), (try s.final()).integer);

    var a = AggState.init(alloc, .avg, null);
    defer a.deinit();
    try a.step(.{ .integer = 2 }, false);
    try a.step(.{ .integer = 4 }, false);
    try std.testing.expectEqual(@as(f64, 3.0), (try a.final()).real);

    var g = AggState.init(alloc, .groupConcat, "|");
    defer g.deinit();
    try g.step(.{ .text = "a" }, false);
    try g.step(.{ .text = "b" }, false);
    const gs = try g.final();
    defer gs.free(alloc);
    try std.testing.expectEqualStrings("a|b", gs.text);
    try std.testing.expect(AggKind.fromName("average") == .avg);
}

test "aggregate null empty and boundary" {
    const alloc = std.testing.allocator;
    var empty_sum = AggState.init(alloc, .sum, null);
    defer empty_sum.deinit();
    try std.testing.expect((try empty_sum.final()) == .null);
    var empty_count = AggState.init(alloc, .count, null);
    defer empty_count.deinit();
    try std.testing.expectEqual(@as(i64, 0), (try empty_count.final()).integer);
    var empty_total = AggState.init(alloc, .total, null);
    defer empty_total.deinit();
    try std.testing.expectEqual(@as(f64, 0.0), (try empty_total.final()).real);
    var empty_gc = AggState.init(alloc, .groupConcat, null);
    defer empty_gc.deinit();
    try std.testing.expect((try empty_gc.final()) == .null);
    // NULLs skipped; min/max across mixed storage classes.
    var m = AggState.init(alloc, .min, null);
    defer m.deinit();
    try m.step(.null, false);
    try m.step(.{ .text = "b" }, false);
    try m.step(.{ .integer = 1 }, false);
    const mv = try m.final();
    defer mv.free(alloc);
    try std.testing.expectEqual(@as(i64, 1), mv.integer);
    // DISTINCT dedups.
    var d = AggState.init(alloc, .count, null);
    defer d.deinit();
    try d.step(.{ .integer = 1 }, true);
    try d.step(.{ .integer = 1 }, true);
    try d.step(.{ .integer = 2 }, true);
    try std.testing.expectEqual(@as(i64, 2), (try d.final()).integer);
}

test "aggregate overflow and error-equivalents" {
    const alloc = std.testing.allocator;
    var s = AggState.init(alloc, .sum, null);
    defer s.deinit();
    try s.step(.{ .integer = std.math.maxInt(i64) }, false);
    try s.step(.{ .integer = 1 }, false);
    const ov = try s.final();
    defer ov.free(alloc);
    // Overflow widens to REAL instead of trapping.
    try std.testing.expect(ov == .real);
}
