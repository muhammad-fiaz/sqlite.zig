const std = @import("std");

pub const Collation = enum {
    binary,
    nocase,
    rtrim,

    pub fn fromName(name: ?[]const u8) Collation {
        const n = name orelse return .binary;
        if (std.ascii.eqlIgnoreCase(n, "nocase")) return .nocase;
        if (std.ascii.eqlIgnoreCase(n, "rtrim")) return .rtrim;
        return .binary;
    }
};

pub const Comparison = enum {
    equal,
    notEqual,
    less,
    lessEqual,
    greater,
    greaterEqual,
};

pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null => "null",
            .integer => "integer",
            .real => "real",
            .text => "text",
            .blob => "blob",
        };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .integer => |n| n != 0,
            .real => |n| n != 0.0 and !std.math.isNan(n),
            .text => |bytes| blk: {
                const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
                if (trimmed.len == 0) break :blk false;
                if (std.fmt.parseInt(i64, trimmed, 10)) |intVal| {
                    break :blk intVal != 0;
                } else |_| {}
                if (std.fmt.parseFloat(f64, trimmed)) |floatVal| {
                    break :blk floatVal != 0.0 and !std.math.isNan(floatVal);
                } else |_| {}
                break :blk false;
            },
            .blob => false,
        };
    }

    pub fn isFalsy(self: Value) bool {
        return !self.isTruthy();
    }

    pub fn sameValue(self: Value, other: Value) bool {
        return switch (self) {
            .null => other == .null,
            .integer => |a| switch (other) {
                .integer => |b| a == b,
                else => false,
            },
            .real => |a| switch (other) {
                .real => |b| a == b,
                else => false,
            },
            .text => |a| switch (other) {
                .text => |b| std.mem.eql(u8, a, b),
                else => false,
            },
            .blob => |a| switch (other) {
                .blob => |b| std.mem.eql(u8, a, b),
                else => false,
            },
        };
    }

    fn typeClass(self: Value) u8 {
        return switch (self) {
            .null => 0,
            .integer, .real => 1,
            .text => 2,
            .blob => 3,
        };
    }

    fn compareIntReal(i: i64, r: f64) std.math.Order {
        if (std.math.isNan(r)) return .gt;
        const fi: f64 = @floatFromInt(i);
        if (fi < r) return .lt;
        if (fi > r) return .gt;
        return .eq;
    }

    fn compareRealReal(a: f64, b: f64) std.math.Order {
        if (std.math.isNan(a)) {
            if (std.math.isNan(b)) return .eq;
            return .lt;
        }
        if (std.math.isNan(b)) return .gt;
        if (a < b) return .lt;
        if (a > b) return .gt;
        return .eq;
    }

    fn trimTrailingSpaces(bytes: []const u8) []const u8 {
        var end = bytes.len;
        while (end > 0 and bytes[end - 1] == ' ') : (end -= 1) {}
        return bytes[0..end];
    }

    fn compareText(a: []const u8, b: []const u8, collation: Collation) std.math.Order {
        return switch (collation) {
            .binary => std.mem.order(u8, a, b),
            .nocase => blk: {
                var i: usize = 0;
                const minLen = @min(a.len, b.len);
                while (i < minLen) : (i += 1) {
                    const ca = std.ascii.toLower(a[i]);
                    const cb = std.ascii.toLower(b[i]);
                    if (ca < cb) break :blk .lt;
                    if (ca > cb) break :blk .gt;
                }
                break :blk std.math.order(a.len, b.len);
            },
            .rtrim => blk: {
                const ta = trimTrailingSpaces(a);
                const tb = trimTrailingSpaces(b);
                break :blk std.mem.order(u8, ta, tb);
            },
        };
    }

    pub fn order(self: Value, other: Value, collation: Collation) std.math.Order {
        const ca = self.typeClass();
        const cb = other.typeClass();
        if (ca != cb) return std.math.order(ca, cb);
        return switch (self) {
            .null => .eq,
            .integer => |a| switch (other) {
                .integer => |b| std.math.order(a, b),
                .real => |b| compareIntReal(a, b),
                else => unreachable,
            },
            .real => |a| switch (other) {
                .integer => |b| compareIntReal(b, a).invert(),
                .real => |b| compareRealReal(a, b),
                else => unreachable,
            },
            .text => |a| switch (other) {
                .text => |b| compareText(a, b, collation),
                else => unreachable,
            },
            .blob => |a| switch (other) {
                .blob => |b| std.mem.order(u8, a, b),
                else => unreachable,
            },
        };
    }

    pub fn compare(self: Value, cmp: Comparison, other: Value, collation: Collation) bool {
        if (self == .null or other == .null) return false;
        const ord = self.order(other, collation);
        return switch (cmp) {
            .equal => ord == .eq,
            .notEqual => ord != .eq,
            .less => ord == .lt,
            .lessEqual => ord != .gt,
            .greater => ord == .gt,
            .greaterEqual => ord != .lt,
        };
    }

    pub fn isDistinct(self: Value, other: Value, collation: Collation) bool {
        if (self == .null and other == .null) return false;
        if (self == .null or other == .null) return true;
        return self.order(other, collation) != .eq;
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .text => |bytes| .{ .text = try allocator.dupe(u8, bytes) },
            .blob => |bytes| .{ .blob = try allocator.dupe(u8, bytes) },
            else => self,
        };
    }

    pub fn free(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |bytes| allocator.free(bytes),
            .blob => |bytes| allocator.free(bytes),
            else => {},
        }
    }
};

test "sql values expose stable types" {
    const nullValue: Value = .null;
    const integerValue: Value = .{ .integer = 4 };
    try std.testing.expect(nullValue.isNull());
    try std.testing.expectEqualStrings("integer", integerValue.typeName());
}

test "sqlite values support full signed 64-bit integer range" {
    const minVal: Value = .{ .integer = std.math.minInt(i64) };
    const maxVal: Value = .{ .integer = std.math.maxInt(i64) };
    try std.testing.expectEqual(std.math.minInt(i64), minVal.integer);
    try std.testing.expectEqual(std.math.maxInt(i64), maxVal.integer);
    try std.testing.expect(minVal.compare(.less, maxVal, .binary));
    try std.testing.expect(!maxVal.compare(.less, minVal, .binary));
}

test "sqlite total ordering puts nulls first then numeric then text then blob" {
    const nullVal: Value = .null;
    const intVal: Value = .{ .integer = 42 };
    const textVal: Value = .{ .text = "hello" };
    const blobVal: Value = .{ .blob = "hello" };

    try std.testing.expectEqual(std.math.Order.lt, nullVal.order(intVal, .binary));
    try std.testing.expectEqual(std.math.Order.lt, intVal.order(textVal, .binary));
    try std.testing.expectEqual(std.math.Order.lt, textVal.order(blobVal, .binary));
}

test "sqlite numeric comparison handles int and real equivalence" {
    const intTwo: Value = .{ .integer = 2 };
    const realTwo: Value = .{ .real = 2.0 };
    const realTwoPointFive: Value = .{ .real = 2.5 };

    try std.testing.expect(intTwo.compare(.equal, realTwo, .binary));
    try std.testing.expect(intTwo.compare(.less, realTwoPointFive, .binary));
    try std.testing.expect(realTwoPointFive.compare(.greater, intTwo, .binary));
    try std.testing.expect(!intTwo.sameValue(realTwo));
}

test "sqlite collation evaluates nocase and rtrim" {
    const lower: Value = .{ .text = "apple" };
    const upper: Value = .{ .text = "APPLE" };
    const spaced: Value = .{ .text = "apple   " };

    try std.testing.expect(!lower.compare(.equal, upper, .binary));
    try std.testing.expect(lower.compare(.equal, upper, .nocase));
    try std.testing.expect(!lower.compare(.equal, spaced, .binary));
    try std.testing.expect(lower.compare(.equal, spaced, .rtrim));
}

test "sqlite is distinct from handles null semantics correctly" {
    const nullA: Value = .null;
    const nullB: Value = .null;
    const num: Value = .{ .integer = 1 };

    try std.testing.expect(!nullA.isDistinct(nullB, .binary));
    try std.testing.expect(nullA.isDistinct(num, .binary));
    try std.testing.expect(!num.isDistinct(num, .binary));
}

test "sqlite truthiness follows three-valued boolean rules" {
    const nullVal: Value = .null;
    try std.testing.expect(!nullVal.isTruthy());
    try std.testing.expect((Value{ .integer = 1 }).isTruthy());
    try std.testing.expect(!(Value{ .integer = 0 }).isTruthy());
    try std.testing.expect((Value{ .real = -0.5 }).isTruthy());
    try std.testing.expect(!(Value{ .real = 0.0 }).isTruthy());
    try std.testing.expect((Value{ .text = "123" }).isTruthy());
    try std.testing.expect(!(Value{ .text = "0" }).isTruthy());
    try std.testing.expect(!(Value{ .text = "abc" }).isTruthy());
}
