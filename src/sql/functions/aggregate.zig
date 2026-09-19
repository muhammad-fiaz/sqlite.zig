const std = @import("std");
const Value = @import("../../vm/value.zig").Value;
const scalar = @import("scalar.zig");

pub const AggKind = enum {
    count,
    sum,
    total,
    avg,
    min,
    max,
    groupConcat,
    stringAgg,

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

pub const AggState = struct {
    allocator: std.mem.Allocator,
    kind: AggKind,
    count: usize = 0,
    sumInt: i64 = 0,
    sumReal: f64 = 0.0,
    isReal: bool = false,
    hasValue: bool = false,
    minVal: ?Value = null,
    maxVal: ?Value = null,
    separator: []const u8 = ",",
    concatPieces: std.ArrayList([]const u8),
    seenValues: std.ArrayList(Value),

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

    pub fn stepWildcard(self: *AggState) void {
        if (self.kind == .count) {
            self.count += 1;
        }
    }

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
                        self.sumInt += i;
                        self.sumReal += @as(f64, @floatFromInt(i));
                    },
                    .real => |r| {
                        self.isReal = true;
                        self.sumReal += r;
                    },
                    .text => |t| {
                        if (std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10)) |i| {
                            self.sumInt += i;
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

    pub const result = final;

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
                    totalLen += piece.len;
                    if (i + 1 < self.concatPieces.items.len) totalLen += self.separator.len;
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
