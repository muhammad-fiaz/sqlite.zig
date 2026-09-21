//! Type affinity for column declarations.
//!
//! Purpose: map a `CREATE TABLE` column declaration to one of SQLite's five
//! affinities (BLOB, TEXT, NUMERIC, INTEGER, REAL) and coerce runtime `Value`s
//! accordingly. This is the catalog-policy half of storage; the schema
//! descriptor (`catalog/schema.zig`) owns the declaration strings while this
//! module owns the mapping rules.
//!
//! Responsibilities:
//! - `fromDeclaration` implements the SQLite affinity decision tree
//!   (INT -> INTEGER, CHAR/CLOB/TEXT -> TEXT, BLOB/empty -> BLOB,
//!   REAL/FLOA/DOUB -> REAL, otherwise NUMERIC).
//! - `apply` / `applyAlloc` coerce a `Value` toward an affinity without
//!   touching the catalog.
//!
//! Dependencies: `vm/value.zig` (`Value`) only. No heap is retained; the
//! caller owns all inputs and outputs. `applyAlloc` duplicates text/blob
//! payloads with the caller's allocator; the caller must free the returned
//! `Value` with `Value.free` (or equivalent) when it holds text/blob.
//!
//! Ownership/lifetime: pure functions. Input slices are borrowed and never
//! retained. `apply` returns its input `Value` unchanged when no conversion
//! applies (shallow copy; text/blob payloads stay borrowed).
//! `applyAlloc` returns an owned `Value`; freeing is the caller's duty.
//!
//! Error behavior: `apply` never fails — unconvertible values pass through
//! unchanged (SQLite "convert if possible" rule). `applyAlloc` fails only on
//! allocation failure.
//!
//! SQLite compatibility: mirrors https://www.sqlite.org/datatype3.html
//! section 3. `fromDeclaration("FLOATING POINT")` contains "INT" and therefore
//! maps to INTEGER, matching SQLite's rule ordering. `parseTextToNumeric`
//! accepts only decimal integer/float spellings; SQLite also accepts hex,
//! exponents with different trims — documented gap, not a divergence for the
//! common cases. REAL affinity converts integers to floats; TEXT affinity
//! stringifies integers/reals in `applyAlloc` only.
//!
//! Unified pipeline note: affinity is a catalog concern consumed by native
//! AST/IR execution. Raw SQL, the dynamic DSL, and the typed DSL all converge
//! on the same native AST — this module never renders or parses SQL strings.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;

/// SQLite storage affinity for one column declaration.
pub const Affinity = enum {
    /// No conversion preference; values stored as-is.
    blob,
    /// Prefers text storage.
    text,
    /// Prefers numeric storage; losslessly convertible text becomes a number.
    numeric,
    /// Prefers integer storage; fractional reals pass through unchanged.
    integer,
    /// Prefers real storage; integers widen to floats.
    real,

    /// Human-readable SQLite affinity name (`"BLOB"`, `"TEXT"`, ...).
    /// Returned slice is a static literal; never free it.
    pub fn name(self: Affinity) []const u8 {
        return switch (self) {
            .blob => "BLOB",
            .text => "TEXT",
            .numeric => "NUMERIC",
            .integer => "INTEGER",
            .real => "REAL",
        };
    }
};

/// Map a raw column declaration (e.g. `"VARCHAR(80)"`) to an `Affinity`.
/// Follows SQLite's ordered substring rules; empty declaration yields `.blob`.
/// Input is borrowed; return value is by value with no allocation.
pub fn fromDeclaration(declaration: []const u8) Affinity {
    const trimmed = std.mem.trim(u8, declaration, " \t\r\n");
    if (trimmed.len == 0) return .blob;
    if (std.ascii.indexOfIgnoreCase(trimmed, "INT")) |_| return .integer;
    if (std.ascii.indexOfIgnoreCase(trimmed, "CHAR")) |_| return .text;
    if (std.ascii.indexOfIgnoreCase(trimmed, "CLOB")) |_| return .text;
    if (std.ascii.indexOfIgnoreCase(trimmed, "TEXT")) |_| return .text;
    if (std.ascii.indexOfIgnoreCase(trimmed, "BLOB")) |_| return .blob;
    if (std.ascii.indexOfIgnoreCase(trimmed, "REAL")) |_| return .real;
    if (std.ascii.indexOfIgnoreCase(trimmed, "FLOA")) |_| return .real;
    if (std.ascii.indexOfIgnoreCase(trimmed, "DOUB")) |_| return .real;
    return .numeric;
}

/// Try to read borrowed text as a number: integer first, then finite float.
/// Returns `null` for empty/whitespace-only or non-numeric text. NaN/Inf are
/// rejected (SQLite stores them as NULL-ish reals; this engine keeps text).
/// No allocation; result is by value.
fn parseTextToNumeric(bytes: []const u8) ?Value {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.fmt.parseInt(i64, trimmed, 10)) |intVal| {
        return .{ .integer = intVal };
    } else |_| {}
    if (std.fmt.parseFloat(f64, trimmed)) |floatVal| {
        if (!std.math.isNan(floatVal) and !std.math.isInf(floatVal)) {
            return .{ .real = floatVal };
        }
    } else |_| {}
    return null;
}

/// Non-allocating affinity coercion. Unconvertible values are returned
/// unchanged (borrowed payloads stay borrowed). Never fails.
pub fn apply(affinity: Affinity, value: Value) Value {
    return switch (affinity) {
        .integer => switch (value) {
            .real => |r| blk: {
                if (r >= -9223372036854775808.0 and r <= 9223372036854774784.0 and r == @floor(r)) {
                    break :blk .{ .integer = @intFromFloat(r) };
                }
                break :blk value;
            },
            .text => |bytes| blk: {
                if (parseTextToNumeric(bytes)) |num| {
                    if (num == .integer) break :blk num;
                    if (num == .real and num.real == @floor(num.real) and num.real >= -9223372036854775808.0 and num.real <= 9223372036854774784.0) {
                        break :blk .{ .integer = @intFromFloat(num.real) };
                    }
                    break :blk num;
                }
                break :blk value;
            },
            else => value,
        },
        .numeric => switch (value) {
            .text => |bytes| parseTextToNumeric(bytes) orelse value,
            else => value,
        },
        .real => switch (value) {
            .integer => |n| .{ .real = @floatFromInt(n) },
            .text => |bytes| blk: {
                if (parseTextToNumeric(bytes)) |num| {
                    if (num == .integer) break :blk .{ .real = @floatFromInt(num.integer) };
                    break :blk num;
                }
                break :blk value;
            },
            else => value,
        },
        .text, .blob => value,
    };
}

/// Owning variant of `apply`. TEXT affinity stringifies integers/reals and
/// duplicates text/blob payloads with `allocator`; other affinities duplicate
/// only when the converted value carries a text/blob payload. Caller owns the
/// result and must free text/blob payloads. Fails only on allocation failure.
pub fn applyAlloc(allocator: std.mem.Allocator, affinity: Affinity, value: Value) !Value {
    if (affinity == .text) {
        return switch (value) {
            .integer => |n| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{n}) },
            .real => |r| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{r}) },
            .text => |bytes| .{ .text = try allocator.dupe(u8, bytes) },
            .blob => |bytes| .{ .blob = try allocator.dupe(u8, bytes) },
            .null => .null,
        };
    }
    const applied = apply(affinity, value);
    return switch (applied) {
        .text => |bytes| .{ .text = try allocator.dupe(u8, bytes) },
        .blob => |bytes| .{ .blob = try allocator.dupe(u8, bytes) },
        else => applied,
    };
}

test "type declarations map to SQLite affinities" {
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("INTEGER PRIMARY KEY"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("BIGINT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("TINYINT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("SMALLINT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("MEDIUMINT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("INT2"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("INT8"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("UNSIGNED BIG INT"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("CHARACTER(20)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("VARYING CHARACTER(255)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("NCHAR(55)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("NATIVE CHARACTER(70)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("NVARCHAR(100)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("VARCHAR(80)"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("TEXT"));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("CLOB"));
    try std.testing.expectEqual(Affinity.blob, fromDeclaration("BLOB"));
    try std.testing.expectEqual(Affinity.blob, fromDeclaration(""));
    try std.testing.expectEqual(Affinity.real, fromDeclaration("REAL"));
    try std.testing.expectEqual(Affinity.real, fromDeclaration("DOUBLE PRECISION"));
    try std.testing.expectEqual(Affinity.real, fromDeclaration("DOUBLE"));
    try std.testing.expectEqual(Affinity.real, fromDeclaration("FLOAT"));
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("FLOATING POINT"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("NUMERIC"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("BOOLEAN"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("DATE"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("DATETIME"));
    try std.testing.expectEqual(Affinity.numeric, fromDeclaration("DECIMAL(10,2)"));
}

test "sqlite affinity coercion follows reference implementation rules" {
    const textInt = Value{ .text = "42" };
    const textReal = Value{ .text = "3.14" };
    const intVal = Value{ .integer = 7 };
    const realInt = Value{ .real = 10.0 };
    const realFrac = Value{ .real = 10.5 };

    try std.testing.expectEqual(@as(i64, 42), apply(.integer, textInt).integer);
    try std.testing.expectEqual(@as(i64, 10), apply(.integer, realInt).integer);
    try std.testing.expectEqual(@as(f64, 10.5), apply(.integer, realFrac).real);
    try std.testing.expectEqual(@as(f64, 7.0), apply(.real, intVal).real);
    try std.testing.expectEqual(@as(i64, 42), apply(.numeric, textInt).integer);
    try std.testing.expectEqual(@as(f64, 3.14), apply(.numeric, textReal).real);

    var textFromInt = try applyAlloc(std.testing.allocator, .text, intVal);
    defer textFromInt.free(std.testing.allocator);
    try std.testing.expectEqualStrings("7", textFromInt.text);
}

test "affinity edge cases: whitespace, blobs, nulls, and casing" {
    // Rule ordering matters: INT wins over later matches, and lookup is
    // case-insensitive with surrounding whitespace trimmed.
    try std.testing.expectEqual(Affinity.integer, fromDeclaration("  integer  "));
    try std.testing.expectEqual(Affinity.text, fromDeclaration("varchar(10)"));
    try std.testing.expectEqual(Affinity.blob, fromDeclaration("   "));
    try std.testing.expectEqualStrings("BLOB", Affinity.blob.name());
    try std.testing.expectEqualStrings("NUMERIC", Affinity.numeric.name());
    // Pass-through: blob/null never convert; non-numeric text is untouched.
    const blob = Value{ .blob = "ab" };
    try std.testing.expect(apply(.integer, blob).blob.len == 2);
    try std.testing.expect(apply(.numeric, .null) == .null);
    try std.testing.expectEqualStrings("nope", apply(.numeric, .{ .text = "nope" }).text);
    try std.testing.expectEqualStrings("  ", apply(.integer, .{ .text = "  " }).text);
    // Out-of-range integral reals stay real under INTEGER affinity.
    try std.testing.expect(apply(.integer, .{ .real = 1.5e300 }).real == 1.5e300);
    // applyAlloc duplicates payloads so the caller can free unconditionally.
    var dup = try applyAlloc(std.testing.allocator, .numeric, Value{ .text = "9" });
    defer dup.free(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 9), dup.integer);
    var kept = try applyAlloc(std.testing.allocator, .blob, Value{ .blob = "xy" });
    defer kept.free(std.testing.allocator);
    try std.testing.expectEqualStrings("xy", kept.blob);
    // TODO: parseTextToNumeric accepts only decimal int/float spellings; SQLite
    // also converts hex ("0x2A"), exponents with leading/trailing junk trimmed
    // differently, and embedded NULs. Extend the parser if compat tests demand it.
}
