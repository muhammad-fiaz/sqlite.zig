//! Aggregate SQL functions (`count`, `sum`, `avg`, `min`, `max`, ...).
//!
//! Streaming per-group accumulator (`AggState`: `step` rows in, `final`
//! reads the result out, `deinit` releases). `sum`/`avg` text must be
//! wholly numeric or the row is skipped — deliberately stricter than the
//! prefix scans scalar `abs` uses (`sum('12x')` skips, `abs('12x')` is 12).

const std = @import("std");
const Value = @import("../../vm/value.zig").Value;
const scalar = @import("scalar.zig");
const coerce = @import("../coerce.zig");
const limits = @import("../limits.zig");

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

/// Hashable DISTINCT identity: same-type equality exactly like
/// `Value.sameValue` (integers never equal reals; `-0.0` normalizes to
/// `0.0`; NaN never reaches the map — it is always distinct).
const DistinctKey = union(enum) {
    integer: i64,
    real: u64,
    text: []const u8,
    blob: []const u8,
};

/// Hash/equality for `DistinctKey`: tag + payload bytes; text/blob compare
/// by contents. Reals hash by bits with `-0.0` already normalized to `0.0`
/// at key build time, so equal values always share a bucket.
const DistinctContext = struct {
    pub fn hash(_: @This(), key: DistinctKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&[_]u8{@intFromEnum(key)});
        switch (key) {
            .integer => |n| hasher.update(std.mem.asBytes(&n)),
            .real => |bits| hasher.update(std.mem.asBytes(&bits)),
            .text => |t| hasher.update(t),
            .blob => |b| hasher.update(b),
        }
        return hasher.final();
    }
    pub fn eql(_: @This(), a: DistinctKey, b: DistinctKey) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .integer => |n| n == b.integer,
            .real => |bits| @as(f64, @bitCast(bits)) == @as(f64, @bitCast(b.real)),
            .text => |t| std.mem.eql(u8, t, b.text),
            .blob => |x| std.mem.eql(u8, x, b.blob),
        };
    }
};

/// Build a dedup key, or null when the value must bypass the map (NULL and
/// NaN are always distinct and never stored, matching `sameValue`).
fn distinctKey(val: Value) ?DistinctKey {
    return switch (val) {
        .null => null,
        .integer => |n| .{ .integer = n },
        .real => |r| {
            if (std.math.isNan(r)) return null;
            const normalized: f64 = if (r == 0.0) 0.0 else r;
            return .{ .real = @bitCast(normalized) };
        },
        .text => |t| .{ .text = t },
        .blob => |b| .{ .blob = b },
    };
}

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
    /// Owned DISTINCT key set (hash dedup; text/blob payloads duped).
    seenValues: std.HashMap(DistinctKey, void, DistinctContext, 80),

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
            .seenValues = std.HashMap(DistinctKey, void, DistinctContext, 80).init(allocator),
        };
    }

    /// Release owned min/max, concat pieces, and DISTINCT key payloads.
    pub fn deinit(self: *AggState) void {
        for (self.concatPieces.items) |piece| {
            self.allocator.free(piece);
        }
        self.concatPieces.deinit(self.allocator);
        var keyIterator = self.seenValues.keyIterator();
        while (keyIterator.next()) |key| {
            switch (key.*) {
                .text => |t| self.allocator.free(t),
                .blob => |b| self.allocator.free(b),
                else => {},
            }
        }
        self.seenValues.deinit();
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
        // NULL and NaN bypass the map (always distinct, never stored),
        // matching `sameValue` identity exactly.
        const key = distinctKey(val) orelse return false;
        if (self.seenValues.count() >= limits.max_distinct_values) return error.SqlTooBig;
        const entry = try self.seenValues.getOrPut(key);
        if (entry.found_existing) return true;
        // Own text/blob payloads; scalars need no storage.
        switch (key) {
            .text => |t| entry.key_ptr.* = .{ .text = try self.allocator.dupe(u8, t) },
            .blob => |b| entry.key_ptr.* = .{ .blob = try self.allocator.dupe(u8, b) },
            else => {},
        }
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
                        const trimmed = std.mem.trim(u8, t, " \t\r\n");
                        if (std.fmt.parseInt(i64, trimmed, 10)) |i| {
                            const res = @addWithOverflow(self.sumInt, i);
                            self.sumInt = res[0];
                            if (res[1] != 0) self.isReal = true;
                            self.sumReal += @as(f64, @floatFromInt(i));
                        } else |_| {
                            // Whole-string decimal only: hex and trailing
                            // junk stay text (skipped), matching the strict
                            // conversion `sum` requires.
                            if (coerce.toFloatStrict(.{ .text = t })) |r| {
                                self.isReal = true;
                                self.sumReal += r;
                            }
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

test "sum skips hex and partial numbers like strict conversion" {
    const alloc = std.testing.allocator;
    var s = AggState.init(alloc, .sum, null);
    defer s.deinit();
    try s.step(.{ .text = "0x2A" }, false);
    try s.step(.{ .text = "12x" }, false);
    try s.step(.{ .integer = 5 }, false);
    const total = try s.final();
    defer total.free(alloc);
    try std.testing.expectEqual(@as(i64, 5), total.integer);
}

test "distinct dedup matches sameValue identity at scale" {
    const alloc = std.testing.allocator;
    var d = AggState.init(alloc, .count, null);
    defer d.deinit();
    // Integers dedupe; int 1 and real 1.0 stay distinct (strict types).
    try d.step(.{ .integer = 1 }, true);
    try d.step(.{ .integer = 1 }, true);
    try d.step(.{ .real = 1.0 }, true);
    // -0.0 normalizes onto 0.0; NaN never matches, not even itself.
    try d.step(.{ .real = 0.0 }, true);
    try d.step(.{ .real = -0.0 }, true);
    try d.step(.{ .real = std.math.nan(f64) }, true);
    try d.step(.{ .real = std.math.nan(f64) }, true);
    // Text and blob dedupe by contents across duplicates.
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try d.step(.{ .integer = @intCast(i) }, true);
        try d.step(.{ .text = "dup" }, true);
    }
    // 1, 1.0, 0.0, nan, nan, ints 0..9999 minus the dup 1, "dup".
    try std.testing.expectEqual(@as(i64, 10005), (try d.final()).integer);
}

test "distinct accumulation rejects past its budget" {
    const alloc = std.testing.allocator;
    var d = AggState.init(alloc, .count, null);
    defer d.deinit();
    var i: i64 = 0;
    while (i < @as(i64, limits.max_distinct_values)) : (i += 1) {
        try d.step(.{ .integer = i }, true);
    }
    try std.testing.expectError(error.SqlTooBig, d.step(.{ .integer = -1 }, true));
}
