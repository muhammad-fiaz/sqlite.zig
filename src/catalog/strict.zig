//! STRICT-table type enforcement.
//!
//! Responsibility: validate STRICT column types and coerce stored values
//! to those types, mirroring SQLite's `OP_TypeCheck` affinity-then-check
//! rule. Pure and stateless; owns only newly allocated TEXT payloads.
//!
//! Dependencies: `vm/value.zig` for `Value`, `sql/coerce.zig` for affinity
//! helpers. Lifetime: `coerceStrict` borrows `value` and returns either the
//! input (no allocation) or a newly allocated TEXT value the caller owns.
//! Errors: `ConstraintViolation` when the value cannot inhabit `typeName`.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const coerce = @import("../sql/coerce.zig");

/// True for the five STRICT storage types plus ANY (case-insensitive).
///
/// Borrowed `typeName`; never fails.
pub fn isValidStrictType(typeName: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(typeName, "INT")) return true;
    if (std.ascii.eqlIgnoreCase(typeName, "INTEGER")) return true;
    if (std.ascii.eqlIgnoreCase(typeName, "REAL")) return true;
    if (std.ascii.eqlIgnoreCase(typeName, "TEXT")) return true;
    if (std.ascii.eqlIgnoreCase(typeName, "BLOB")) return true;
    if (std.ascii.eqlIgnoreCase(typeName, "ANY")) return true;
    return false;
}

/// Coerce a borrowed `Value` to a STRICT type, passing NULL through.
///
/// INT/INTEGER accept ints and integral reals; REAL widens ints; TEXT/BLOB
/// accept only their kind; ANY passes through. Fails `ConstraintViolation`.
/// STRICT single-value check with affinity conversion first, mirroring
/// the reference `OP_TypeCheck`: each type applies its affinity, then
/// the converted storage class must match. INTEGER affinity converts
/// well-formed text numerals and lossless reals; REAL keeps small
/// integers as integers (`IntReal`) and widens the rest past 2**47;
/// TEXT renders numbers but never blobs; BLOB converts nothing. Blobs
/// (not strings) skip numeric affinity entirely. NULL passes through
/// (`NOT NULL` rejects separately).
pub fn coerceStrict(allocator: std.mem.Allocator, typeName: []const u8, value: Value) !Value {
    if (value == .null) return .null;
    if (std.ascii.eqlIgnoreCase(typeName, "INT") or std.ascii.eqlIgnoreCase(typeName, "INTEGER")) {
        return switch (value) {
            .integer => value,
            .real => |r| if (coerce.realAffinityInt(r)) |i| .{ .integer = i } else error.ConstraintViolation,
            .text => |t| switch (coerce.affinityNumeric(t) orelse return error.ConstraintViolation) {
                .int => |i| Value{ .integer = i },
                .real => |r| if (coerce.realAffinityInt(r)) |i| .{ .integer = i } else error.ConstraintViolation,
                .none => error.ConstraintViolation,
            },
            else => error.ConstraintViolation,
        };
    }
    if (std.ascii.eqlIgnoreCase(typeName, "REAL")) {
        return switch (value) {
            .real => |r| if (coerce.realAffinityInt(r)) |i| .{ .integer = i } else value,
            .integer => |i| if (i <= 140737488355327 and i >= -140737488355328) value else .{ .real = @floatFromInt(i) },
            .text => |t| switch (coerce.affinityNumeric(t) orelse return error.ConstraintViolation) {
                .int => |i| if (i <= 140737488355327 and i >= -140737488355328) Value{ .integer = i } else .{ .real = @floatFromInt(i) },
                .real => |r| .{ .real = r },
                .none => error.ConstraintViolation,
            },
            else => error.ConstraintViolation,
        };
    }
    if (std.ascii.eqlIgnoreCase(typeName, "TEXT")) {
        return switch (value) {
            .text => value,
            .integer => |i| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
            .real => |r| .{ .text = try coerce.formatReal(allocator, r) },
            else => error.ConstraintViolation,
        };
    }
    if (std.ascii.eqlIgnoreCase(typeName, "BLOB")) {
        return switch (value) {
            .blob => value,
            else => error.ConstraintViolation,
        };
    }
    if (std.ascii.eqlIgnoreCase(typeName, "ANY")) {
        return value;
    }
    return error.ConstraintViolation;
}

test "strict types accept canonical names only" {
    try std.testing.expect(isValidStrictType("INT"));
    try std.testing.expect(isValidStrictType("integer"));
    try std.testing.expect(isValidStrictType("REAL"));
    try std.testing.expect(isValidStrictType("text"));
    try std.testing.expect(isValidStrictType("BLOB"));
    try std.testing.expect(isValidStrictType("any"));
    try std.testing.expect(!isValidStrictType("VARCHAR"));
    try std.testing.expect(!isValidStrictType("NUMERIC"));
    try std.testing.expect(!isValidStrictType(""));
}

test "strict coercion applies affinity before the type check" {
    const alloc = std.testing.allocator;
    // Well-formed text numerals convert; junk stays TEXT and fails.
    const fromText = try coerceStrict(alloc, "INT", .{ .text = "123" });
    try std.testing.expectEqual(@as(i64, 123), fromText.integer);
    try std.testing.expectError(error.ConstraintViolation, coerceStrict(alloc, "INT", .{ .text = "12x" }));
    try std.testing.expectError(error.ConstraintViolation, coerceStrict(alloc, "INT", .{ .text = "1.5" }));
    const floatText = try coerceStrict(alloc, "INT", .{ .text = "48.00" });
    try std.testing.expectEqual(@as(i64, 48), floatText.integer);
    const toReal = try coerceStrict(alloc, "REAL", .{ .text = "2.5" });
    try std.testing.expectEqual(@as(f64, 2.5), toReal.real);
    // Small integers stay integers in REAL columns (IntReal); large ones widen.
    const intReal = try coerceStrict(alloc, "REAL", .{ .integer = 42 });
    try std.testing.expectEqual(@as(i64, 42), intReal.integer);
    const wide = try coerceStrict(alloc, "REAL", .{ .integer = std.math.maxInt(i64) });
    try std.testing.expect(wide == .real);
    // Lossless reals become integers; the rest (and huge magnitudes) fail
    // for INT without trapping.
    const lossless = try coerceStrict(alloc, "INT", .{ .real = 50.0 });
    try std.testing.expectEqual(@as(i64, 50), lossless.integer);
    try std.testing.expectError(error.ConstraintViolation, coerceStrict(alloc, "INT", .{ .real = 1e30 }));
    try std.testing.expectError(error.ConstraintViolation, coerceStrict(alloc, "INT", .{ .real = 1.5 }));
    // Numbers render to TEXT; blobs never convert.
    const rendered = try coerceStrict(alloc, "TEXT", .{ .integer = 999 });
    defer alloc.free(rendered.text);
    try std.testing.expectEqualStrings("999", rendered.text);
    try std.testing.expectError(error.ConstraintViolation, coerceStrict(alloc, "TEXT", .{ .blob = "x" }));
    try std.testing.expectError(error.ConstraintViolation, coerceStrict(alloc, "BLOB", .{ .integer = 1 }));
    try std.testing.expectError(error.ConstraintViolation, coerceStrict(alloc, "BLOB", .{ .text = "x" }));
    const anyBlob = try coerceStrict(alloc, "ANY", .{ .blob = "x" });
    try std.testing.expect(anyBlob == .blob);
}
