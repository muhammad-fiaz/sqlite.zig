//! Key shapes normalized to borrowed name lists and checked live.
//!
//! Outputs borrow the inputs; validation only borrows the table.
//! Wrong tables give `UnknownColumn`, bad shapes `InvalidSql`, drift `SchemaMismatch`.

const std = @import("std");
const ast = @import("../sql/ast.zig");
const Value = @import("../vm/value.zig").Value;
const schemaMod = @import("../catalog/schema.zig");
const dslColumn = @import("column.zig");
const scopeMod = @import("scope.zig");
const DynamicColumn = dslColumn.DynamicColumn;

/// Re-exported referential action so table definitions need only import keys.
pub const Action = ast.ReferentialAction;

/// Comptime check for a typed column descriptor (`Column(...)` instance).
pub fn isDslColumn(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "isDslColumn") and T.isDslColumn;
}

/// Dereference a `*[_][]const u8`-style single-pointer key list; otherwise
/// return the value unchanged. Used so callers may pass `&pair` or `pair`.
pub fn derefItems(list: anytype) Derefed(@TypeOf(list)) {
    const one = comptime isOnePointer(@TypeOf(list));
    if (one) return list.*;
    return list;
}

fn Derefed(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) return info.pointer.child;
    return T;
}

fn isOnePointer(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .one;
}

/// True for `[]const u8`, `[]u8`, `*[N]u8`-style string-likes (slices and
/// single pointers to u8 arrays). Used to recognize bare name key items.
pub fn isStringLike(comptime T: type) bool {
    if (T == []const u8 or T == []u8) return true;
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size == .slice) return ptr.child == u8;
    if (ptr.size == .one) {
        const child = @typeInfo(ptr.child);
        if (child == .array) return child.array.child == u8;
    }
    return false;
}

/// Borrow the caller's string as a column name. Accepts slices and
/// `*const [N]u8`; anything else is a comptime error. Never allocates.
pub fn coerceName(value: anytype) []const u8 {
    const T = @TypeOf(value);
    if (T == []const u8 or T == []u8) return value;
    const info = @typeInfo(T);
    if (info == .pointer) {
        const ptr = info.pointer;
        if (ptr.size == .slice and ptr.child == u8) return value;
        if (ptr.size == .one) {
            const child = @typeInfo(ptr.child);
            if (child == .array and child.array.child == u8) return value[0..child.array.len];
        }
    }
    @compileError("expected a column-name string");
}

/// Borrowed SQL column name of a key item (typed/dynamic column or string).
pub fn colNameOf(c: anytype) []const u8 {
    const T = @TypeOf(c);
    if (T == DynamicColumn) return dslColumn.dynRef(c).name;
    if (comptime isDslColumn(T)) return T.dslName;
    return coerceName(c);
}

/// Borrowed owning-table qualifier of a key item, or `""` for bare strings.
pub fn colTableOf(c: anytype) []const u8 {
    const T = @TypeOf(c);
    if (T == DynamicColumn) return dslColumn.dynRef(c).table;
    if (comptime isDslColumn(T)) return T.dslTable;
    return "";
}

fn checkKeyTable(c: anytype, expectedTable: []const u8) !void {
    const t = colTableOf(c);
    if (t.len != 0 and !std.ascii.eqlIgnoreCase(t, expectedTable)) return error.UnknownColumn;
}

/// Scoped field check: unqualified fields (`.id`) are bound by the target
/// being defined, so they always pass the table guard; anything else uses
/// the explicit table identity. `S` is a `scope.TypeScope` bundle.
fn checkKeyTableScoped(comptime S: type, c: anytype, expectedTable: []const u8) !void {
    if (comptime scopeMod.isScopedItem(@TypeOf(c), S.Row)) return;
    try checkKeyTable(c, expectedTable);
}

/// Borrowed SQL column name of a key item: scoped fields resolve through
/// the target's column mapping, everything else uses `colNameOf`.
fn colNameOfScoped(comptime S: type, expectedTable: []const u8, c: anytype) []const u8 {
    if (comptime scopeMod.isScopedItem(@TypeOf(c), S.Row)) {
        return scopeMod.resolveSqlName(S, expectedTable, scopeMod.fieldNameOf(S, c));
    }
    return colNameOf(c);
}

/// Normalize one key (single or composite) into borrowed names in `out`.
/// Returns the count written (max 16). `expectedTable` guards cross-table
/// mixing; bare strings skip the check. Errors: `UnknownColumn` on table
/// mismatch, `InvalidSql` on empty/oversized lists.
pub fn normalizeKey(key: anytype, expectedTable: []const u8, out: *[16][]const u8) !usize {
    return normalizeKeyScoped(key, expectedTable, scopeMod.Unscoped, out);
}

/// `normalizeKey` plus scoped-field support: unqualified fields (`.id`,
/// `.{ .a, .b }` mixed with explicit columns) resolve against the target
/// table described by `S` (a `scope.TypeScope` bundle). Unscoped targets
/// reject bare fields with a compile error instead of guessing.
pub fn normalizeKeyScoped(key: anytype, expectedTable: []const u8, comptime S: type, out: *[16][]const u8) !usize {
    const T = @TypeOf(key);
    const isSingle = comptime (T == DynamicColumn or isDslColumn(T) or isStringLike(T) or scopeMod.isScopedItem(T, S.Row));
    if (isSingle) {
        if (comptime scopeMod.isScopedItem(T, S.Row) and !S.isScoped) @compileError("unqualified field needs a typed table scope (define keys on a sqlite.table(...) value)");
        try checkKeyTableScoped(S, key, expectedTable);
        out[0] = colNameOfScoped(S, expectedTable, key);
        return 1;
    }
    const items = derefItems(key);
    const info = @typeInfo(@TypeOf(items));
    var count: usize = 0;
    if ((info == .@"struct" and info.@"struct".is_tuple) or info == .array) {
        inline for (items) |item| {
            if (count >= out.len) return error.InvalidSql;
            if (comptime scopeMod.isScopedItem(@TypeOf(item), S.Row) and !S.isScoped) @compileError("unqualified field needs a typed table scope (define keys on a sqlite.table(...) value)");
            try checkKeyTableScoped(S, item, expectedTable);
            out[count] = colNameOfScoped(S, expectedTable, item);
            count += 1;
        }
    } else {
        for (items) |item| {
            if (count >= out.len) return error.InvalidSql;
            try checkKeyTable(item, expectedTable);
            out[count] = colNameOf(item);
            count += 1;
        }
    }
    if (count == 0) return error.InvalidSql;
    return count;
}

/// Normalized foreign-key spec. All name/table slices are borrowed from the
/// caller's descriptors; `localCount`/`refCount` must agree.
pub const ForeignKeySpec = struct {
    local: [16][]const u8 = undefined,
    localCount: usize = 0,
    refTable: []const u8 = "",
    refCols: [16][]const u8 = undefined,
    refCount: usize = 0,
    onDelete: ast.ReferentialAction = .noAction,
    onUpdate: ast.ReferentialAction = .noAction,
    deferrable: bool = false,
    initiallyDeferred: bool = false,
};

/// Normalize `.{ .table, .column/.columns }`-style reference inputs plus
/// tuple/array/slice reference lists into `(table, cols)`. Borrowed.
/// Foreign-key `references` must stay explicit: the parent scope is unknown,
/// so a bare field there is a compile error, never a guess.
fn normalizeRefList(ref: anytype, outTable: *[]const u8, outCols: *[16][]const u8) !usize {
    const R = @TypeOf(ref);
    // No scope exists on the parent side: a bare field cannot resolve.
    if (R == scopeMod.EnumLiteral or @typeInfo(R) == .@"enum") @compileError("foreign-key references must be explicit table-qualified columns (Parent.id), not bare fields");
    if (R == DynamicColumn) {
        const split = dslColumn.dynRef(ref);
        if (split.table.len == 0) return error.InvalidSql;
        outTable.* = split.table;
        outCols[0] = split.name;
        return 1;
    }
    {
        const isCol = comptime isDslColumn(R);
        if (isCol) {
            outTable.* = R.dslTable;
            outCols[0] = R.dslName;
            return 1;
        }
    }
    if (@typeInfo(R) == .@"struct" and !@typeInfo(R).@"struct".is_tuple) {
        if (!@hasField(R, "table")) @compileError("dynamic foreign-key reference needs .table plus .column/.columns");
        outTable.* = coerceName(ref.table);
        if (@hasField(R, "columns")) return normalizeKey(ref.columns, outTable.*, outCols);
        if (@hasField(R, "column")) return normalizeKey(ref.column, outTable.*, outCols);
        @compileError("dynamic foreign-key reference needs .column or .columns");
    }
    const items = derefItems(ref);
    const info = @typeInfo(@TypeOf(items));
    var count: usize = 0;
    var table: []const u8 = "";
    if ((info == .@"struct" and info.@"struct".is_tuple) or info == .array) {
        inline for (items) |item| {
            const IT = @TypeOf(item);
            if (comptime (IT != DynamicColumn and !isDslColumn(IT))) @compileError("composite foreign-key references must be typed columns");
            const t = colTableOf(item);
            if (t.len == 0) return error.InvalidSql;
            if (count == 0) table = t else if (!std.ascii.eqlIgnoreCase(table, t)) return error.InvalidSql;
            if (count >= outCols.len) return error.InvalidSql;
            outCols[count] = colNameOf(item);
            count += 1;
        }
    } else {
        for (items) |item| {
            const t = colTableOf(item);
            if (t.len == 0) return error.InvalidSql;
            if (count == 0) table = t else if (!std.ascii.eqlIgnoreCase(table, t)) return error.InvalidSql;
            if (count >= outCols.len) return error.InvalidSql;
            outCols[count] = colNameOf(item);
            count += 1;
        }
    }
    if (count == 0) return error.InvalidSql;
    outTable.* = table;
    return count;
}

/// Parse `.{ .column/.columns, .references, .onDelete?, .onUpdate?,
/// .deferrable?, .initiallyDeferred? }` into a `ForeignKeySpec`.
/// `references` may be a typed column, a `DynamicColumn` with `table` set, a
/// `.{ .table, .column/.columns }` struct, or a tuple of same-table typed
/// columns. Borrowed; fails `InvalidSql` on count mismatch.
/// `initiallyDeferred` without `deferrable` is a compile error.
pub fn parseFkSpec(fk: anytype, expectedTable: []const u8) !ForeignKeySpec {
    return parseFkSpecScoped(fk, expectedTable, scopeMod.Unscoped);
}

/// `parseFkSpec` plus scoped-field support on the local side (`.column` /
/// `.columns` accept `.parent_id` against the child table in `S`); the
/// `references` side always stays explicit.
pub fn parseFkSpecScoped(fk: anytype, expectedTable: []const u8, comptime S: type) !ForeignKeySpec {
    const F = @TypeOf(fk);
    const info = @typeInfo(F);
    if (info != .@"struct" or info.@"struct".is_tuple) @compileError("foreign key must be a struct with .column/.columns and .references");
    var spec = ForeignKeySpec{};
    if (@hasField(F, "columns")) {
        spec.localCount = try normalizeKeyScoped(fk.columns, expectedTable, S, &spec.local);
    } else if (@hasField(F, "column")) {
        spec.localCount = try normalizeKeyScoped(fk.column, expectedTable, S, &spec.local);
    } else @compileError("foreign key needs .column or .columns");
    if (!@hasField(F, "references")) @compileError("foreign key needs .references");
    spec.refCount = try normalizeRefList(fk.references, &spec.refTable, &spec.refCols);
    if (@hasField(F, "onDelete")) spec.onDelete = fk.onDelete;
    if (@hasField(F, "onUpdate")) spec.onUpdate = fk.onUpdate;
    if (@hasField(F, "deferrable")) spec.deferrable = fk.deferrable;
    if (@hasField(F, "initiallyDeferred")) spec.initiallyDeferred = fk.initiallyDeferred;
    if (@hasField(F, "initiallyDeferred") and !@hasField(F, "deferrable")) @compileError("initiallyDeferred needs deferrable");
    if (spec.initiallyDeferred and !spec.deferrable) return error.InvalidSql;
    if (spec.localCount != spec.refCount) return error.InvalidSql;
    return spec;
}

/// Map a Zig field type to its declared SQL type name (static literal).
/// ints/bools -> INTEGER, floats -> REAL, u8 slices/arrays -> TEXT, else BLOB.
pub fn dslTypeName(comptime T: type) []const u8 {
    const info = @typeInfo(T);
    if (info == .optional) return dslTypeName(info.optional.child);
    return switch (info) {
        .int, .comptime_int, .bool => "INTEGER",
        .float, .comptime_float => "REAL",
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) "TEXT" else "BLOB",
        .array => |arr| if (arr.child == u8) "TEXT" else "BLOB",
        else => "BLOB",
    };
}

fn defaultScalar(value: anytype) ?Value {
    const T = @TypeOf(value);
    if (T == Value) return value;
    if (@typeInfo(T) == .optional) {
        if (value) |present| return defaultScalar(present);
        return null;
    }
    return switch (@typeInfo(T)) {
        .bool => .{ .integer = if (value) 1 else 0 },
        .int, .comptime_int => .{ .integer = @intCast(value) },
        .float, .comptime_float => .{ .real = @floatCast(value) },
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) .{ .text = value } else null,
        else => null,
    };
}

/// Read a struct field's comptime default as a `Value` (borrowed text).
/// Returns `null` when the field has no default or the type is unsupported.
/// `ptr` must point at an `F`; null means "no default known".
pub fn zigDefault(comptime F: type, ptr: ?*const anyopaque) ?Value {
    const p = ptr orelse return null;
    const v: *const F = @ptrCast(@alignCast(p));
    return defaultScalar(v.*);
}

/// Declared type name -> storage class. Case-insensitive substring match.
pub fn affinityOf(typeName: []const u8) []const u8 {
    if (typeName.len == 0) return "BLOB";
    if (containsIgnoreCase(typeName, "INT")) return "INTEGER";
    if (containsIgnoreCase(typeName, "CHAR") or containsIgnoreCase(typeName, "CLOB") or containsIgnoreCase(typeName, "TEXT")) return "TEXT";
    if (containsIgnoreCase(typeName, "BLOB")) return "BLOB";
    if (containsIgnoreCase(typeName, "REAL") or containsIgnoreCase(typeName, "FLOA") or containsIgnoreCase(typeName, "DOUB")) return "REAL";
    return "NUMERIC";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |b, j| {
            if (std.ascii.toUpper(haystack[i + j]) != b) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// NUMERIC is compatible with INTEGER/REAL in either direction; otherwise
/// classes must match exactly (case-insensitive). TEXT never matches numbers.
pub fn affinitiesCompatible(expected: []const u8, actual: []const u8) bool {
    const a = affinityOf(expected);
    const b = affinityOf(actual);
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    const aNum = std.ascii.eqlIgnoreCase(a, "NUMERIC");
    const bNum = std.ascii.eqlIgnoreCase(b, "NUMERIC");
    const aIntReal = std.ascii.eqlIgnoreCase(a, "INTEGER") or std.ascii.eqlIgnoreCase(a, "REAL");
    const bIntReal = std.ascii.eqlIgnoreCase(b, "INTEGER") or std.ascii.eqlIgnoreCase(b, "REAL");
    return (aNum and bIntReal) or (bNum and aIntReal);
}

/// Compare optional default `Value`s: two missing/nulls match, int/real mix
/// by numeric equality, texts by bytes. Anything else is unequal.
pub fn sameDefault(expected: ?Value, actual: ?Value) bool {
    const eNull = expected == null or expected.? == .null;
    const aNull = actual == null or actual.? == .null;
    if (eNull and aNull) return true;
    if (eNull or aNull) return false;
    const e = expected.?;
    const a = actual.?;
    if (e == .integer and a == .integer) return e.integer == a.integer;
    if (e == .real and a == .real) return e.real == a.real;
    if ((e == .integer and a == .real) or (e == .real and a == .integer)) {
        const ef: f64 = if (e == .integer) @as(f64, @floatFromInt(e.integer)) else e.real;
        const af: f64 = if (a == .integer) @as(f64, @floatFromInt(a.integer)) else a.real;
        return ef == af;
    }
    if (e == .text and a == .text) return std.mem.eql(u8, e.text, a.text);
    if (e == .null and a == .null) return true;
    return false;
}

/// One composite UNIQUE group: borrowed names plus count.
pub const UniqueGroup = struct { names: [16][]const u8 = undefined, count: usize = 0 };

/// Expected key set accumulated by `parsePkInto`/`parseUniqueInto`/
/// `parseFksInto` and checked by `validateKeys`. All slices borrowed.
pub const ExpectedKeys = struct {
    hasPk: bool = false,
    pk: [16][]const u8 = undefined,
    pkCount: usize = 0,
    hasUnique: bool = false,
    uniqueSingles: [16][]const u8 = undefined,
    uniqueSingleCount: usize = 0,
    uniqueGroups: [8]UniqueGroup = undefined,
    uniqueGroupCount: usize = 0,
    hasFks: bool = false,
    fks: [8]ForeignKeySpec = undefined,
    fkCount: usize = 0,
};

/// Record the expected primary key. Overwrites any previous expectation.
/// The scoped form takes an explicit `scope.TypeScope` bundle so
/// unqualified fields (`.id`) resolve against the table being defined.
pub fn parsePkInto(src: anytype, tableName: []const u8, expected: *ExpectedKeys) !void {
    return parsePkIntoScoped(src, tableName, scopeMod.Unscoped, expected);
}

/// `parsePkInto` with scoped-field support via `S`.
pub fn parsePkIntoScoped(src: anytype, tableName: []const u8, comptime S: type, expected: *ExpectedKeys) !void {
    expected.hasPk = true;
    expected.pkCount = try normalizeKeyScoped(src, tableName, S, &expected.pk);
}

/// Record expected UNIQUEs: singles go to `uniqueSingles`, composites to
/// `uniqueGroups`. Accumulates across calls; sets `hasUnique`.
pub fn parseUniqueInto(src: anytype, tableName: []const u8, expected: *ExpectedKeys) !void {
    return parseUniqueIntoScoped(src, tableName, scopeMod.Unscoped, expected);
}

/// `parseUniqueInto` with scoped-field support via `S`.
pub fn parseUniqueIntoScoped(src: anytype, tableName: []const u8, comptime S: type, expected: *ExpectedKeys) !void {
    const items = derefItems(src);
    const info = @typeInfo(@TypeOf(items));
    expected.hasUnique = true;
    if ((info == .@"struct" and info.@"struct".is_tuple) or info == .array) {
        inline for (items) |item| try addUniqueItemScoped(item, tableName, S, expected);
    } else {
        for (items) |item| try addUniqueItem(item, tableName, expected);
    }
}

fn addUniqueItem(item: anytype, tableName: []const u8, expected: *ExpectedKeys) !void {
    return addUniqueItemScoped(item, tableName, scopeMod.Unscoped, expected);
}

fn addUniqueItemScoped(item: anytype, tableName: []const u8, comptime S: type, expected: *ExpectedKeys) !void {
    const T = @TypeOf(item);
    const isSingle = comptime (T == DynamicColumn or isDslColumn(T) or isStringLike(T) or scopeMod.isScopedItem(T, S.Row));
    if (isSingle) {
        if (expected.uniqueSingleCount >= expected.uniqueSingles.len) return error.InvalidSql;
        var buf: [16][]const u8 = undefined;
        const count = try normalizeKeyScoped(item, tableName, S, &buf);
        std.debug.assert(count == 1);
        expected.uniqueSingles[expected.uniqueSingleCount] = buf[0];
        expected.uniqueSingleCount += 1;
        return;
    }
    if (expected.uniqueGroupCount >= expected.uniqueGroups.len) return error.InvalidSql;
    var group = UniqueGroup{};
    group.count = try normalizeKeyScoped(item, tableName, S, &group.names);
    expected.uniqueGroups[expected.uniqueGroupCount] = group;
    expected.uniqueGroupCount += 1;
}

/// Record expected foreign keys (tuple/slice/array of FK structs).
/// Accumulates into `fks`; sets `hasFks`.
pub fn parseFksInto(src: anytype, tableName: []const u8, expected: *ExpectedKeys) !void {
    return parseFksIntoScoped(src, tableName, scopeMod.Unscoped, expected);
}

/// `parseFksInto` with scoped-field support on local sides via `S`.
pub fn parseFksIntoScoped(src: anytype, tableName: []const u8, comptime S: type, expected: *ExpectedKeys) !void {
    const items = derefItems(src);
    const info = @typeInfo(@TypeOf(items));
    expected.hasFks = true;
    if ((info == .@"struct" and info.@"struct".is_tuple) or info == .array) {
        inline for (items) |item| {
            if (expected.fkCount >= expected.fks.len) return error.InvalidSql;
            expected.fks[expected.fkCount] = try parseFkSpecScoped(item, tableName, S);
            expected.fkCount += 1;
        }
    } else {
        for (items) |item| {
            if (expected.fkCount >= expected.fks.len) return error.InvalidSql;
            expected.fks[expected.fkCount] = try parseFkSpec(item, tableName);
            expected.fkCount += 1;
        }
    }
}

fn eqlName(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn findColumn(table: *const schemaMod.Table, name: []const u8) ?*const schemaMod.Column {
    for (table.columns) |*col| if (eqlName(col.name, name)) return col;
    return null;
}

fn namesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!eqlName(x, y)) return false;
    return true;
}

/// Canonical primary-key column names of a live table (borrowed), from the
/// table constraint first, else from column `primaryKey` flags.
pub fn actualPk(table: *const schemaMod.Table, out: *[16][]const u8) usize {
    for (table.constraints) |*c| {
        if (c.kind != .primaryKey) continue;
        var n: usize = 0;
        for (c.columns) |name| {
            if (n >= out.len) break;
            out[n] = name;
            n += 1;
        }
        return n;
    }
    var n: usize = 0;
    for (table.columns) |*col| {
        if (!col.primaryKey) continue;
        if (n >= out.len) break;
        out[n] = col.name;
        n += 1;
    }
    return n;
}

/// Check the expected PK/UNIQUE/FK set against a live catalog table.
/// Only declared aspects are checked (unset `has*` flags are skipped).
/// Returns `error.SchemaMismatch` on any drift; borrows both inputs.
pub fn validateKeys(table: *const schemaMod.Table, expected: *const ExpectedKeys) !void {
    if (expected.hasPk) {
        var actual: [16][]const u8 = undefined;
        const count = actualPk(table, &actual);
        if (!namesEqual(expected.pk[0..expected.pkCount], actual[0..count])) return error.SchemaMismatch;
    }
    if (expected.hasUnique) {
        for (expected.uniqueSingles[0..expected.uniqueSingleCount]) |name| {
            const col = findColumn(table, name) orelse return error.SchemaMismatch;
            if (!col.unique) return error.SchemaMismatch;
        }
        var actualSingleCount: usize = 0;
        for (table.columns) |*col| {
            if (col.unique) actualSingleCount += 1;
        }
        if (actualSingleCount != expected.uniqueSingleCount) return error.SchemaMismatch;
        var matched: [8]bool = .{false} ** 8;
        var actualGroupCount: usize = 0;
        for (table.constraints) |*c| {
            if (c.kind != .unique) continue;
            actualGroupCount += 1;
            var found = false;
            for (expected.uniqueGroups[0..expected.uniqueGroupCount], 0..) |*group, gi| {
                if (!matched[gi] and namesEqual(group.names[0..group.count], c.columns)) {
                    matched[gi] = true;
                    found = true;
                    break;
                }
            }
            if (!found) return error.SchemaMismatch;
        }
        if (actualGroupCount != expected.uniqueGroupCount) return error.SchemaMismatch;
    }
    if (expected.hasFks) {
        var matched: [8]bool = .{false} ** 8;
        var actualCount: usize = 0;
        for (table.columns) |*col| {
            if (col.foreignTable == null) continue;
            actualCount += 1;
            if (!matchFk(expected, &matched, &.{col.name}, col.foreignTable.?, &.{col.foreignColumn.?}, col.onDelete, col.onUpdate, col.fkDeferrable, col.fkInitiallyDeferred)) return error.SchemaMismatch;
        }
        for (table.constraints) |*c| {
            if (c.kind != .foreignKey) continue;
            actualCount += 1;
            if (!matchFk(expected, &matched, c.columns, c.foreignTable.?, c.referencedColumns, c.onDelete, c.onUpdate, c.deferrable, c.initiallyDeferred)) return error.SchemaMismatch;
        }
        if (actualCount != expected.fkCount) return error.SchemaMismatch;
    }
}

/// One-shot bipartite match of an actual FK against unmatched expectations.
/// Marks the slot on success so each expectation matches at most once.
fn matchFk(expected: *const ExpectedKeys, matched: *[8]bool, local: []const []const u8, refTable: []const u8, refCols: []const []const u8, onDelete: ast.ReferentialAction, onUpdate: ast.ReferentialAction, deferrable: bool, initiallyDeferred: bool) bool {
    for (expected.fks[0..expected.fkCount], 0..) |*fk, i| {
        if (matched[i]) continue;
        if (!namesEqual(fk.local[0..fk.localCount], local)) continue;
        if (!eqlName(fk.refTable, refTable)) continue;
        if (!namesEqual(fk.refCols[0..fk.refCount], refCols)) continue;
        if (fk.onDelete != onDelete or fk.onUpdate != onUpdate) continue;
        if (fk.deferrable != deferrable or fk.initiallyDeferred != initiallyDeferred) continue;
        matched[i] = true;
        return true;
    }
    return false;
}

test "normalizeKey accepts singles and composites" {
    const A = dslColumn.Column("t", "a", i64);
    const B = dslColumn.Column("t", "b", i64);
    var buf: [16][]const u8 = undefined;
    try std.testing.expect(try normalizeKey(A{}, "t", &buf) == 1);
    try std.testing.expectEqualStrings("a", buf[0]);
    try std.testing.expect(try normalizeKey("b", "t", &buf) == 1);
    try std.testing.expectEqualStrings("b", buf[0]);
    try std.testing.expect(try normalizeKey(DynamicColumn{ .name = "b" }, "t", &buf) == 1);
    const pair = .{ A{}, B{} };
    try std.testing.expect(try normalizeKey(&pair, "t", &buf) == 2);
    try std.testing.expectEqualStrings("b", buf[1]);
    const names = [_][]const u8{ "a", "b" };
    try std.testing.expect(try normalizeKey(names[0..], "t", &buf) == 2);
    try std.testing.expectError(error.UnknownColumn, normalizeKey(A{}, "other", &buf));
    try std.testing.expectError(error.InvalidSql, normalizeKey(@as([]const []const u8, &.{}), "t", &buf));
}

test "parseFkSpec funnels every key shape into one spec" {
    const Uid = dslColumn.Column("users", "id", i64);
    const Oid = dslColumn.Column("orders", "user_id", i64);
    const single = try parseFkSpec(.{ .column = Oid{}, .references = Uid{}, .onDelete = .cascade }, "orders");
    try std.testing.expectEqualStrings("user_id", single.local[0]);
    try std.testing.expectEqualStrings("users", single.refTable);
    try std.testing.expectEqualStrings("id", single.refCols[0]);
    try std.testing.expect(single.onDelete == .cascade);
    try std.testing.expect(single.onUpdate == .noAction);
    const dyn = try parseFkSpec(.{ .column = "user_id", .references = .{ .table = "users", .column = "id" } }, "orders");
    try std.testing.expectEqualStrings("users", dyn.refTable);
    const A = dslColumn.Column("c", "a", i64);
    const B = dslColumn.Column("c", "b", i64);
    const P = dslColumn.Column("p", "a", i64);
    const Q = dslColumn.Column("p", "b", i64);
    const composite = try parseFkSpec(.{ .columns = &.{ A{}, B{} }, .references = &.{ P{}, Q{} } }, "c");
    try std.testing.expect(composite.localCount == 2);
    try std.testing.expect(composite.refCount == 2);
    try std.testing.expectEqualStrings("p", composite.refTable);
    try std.testing.expectError(error.InvalidSql, parseFkSpec(.{ .column = Oid{}, .references = &.{ P{}, Q{} } }, "orders"));
}

test "affinities map declared types to storage classes" {
    try std.testing.expectEqualStrings("INTEGER", affinityOf("INTEGER"));
    try std.testing.expectEqualStrings("INTEGER", affinityOf("INT"));
    try std.testing.expectEqualStrings("TEXT", affinityOf("VARCHAR"));
    try std.testing.expectEqualStrings("TEXT", affinityOf("TEXT"));
    try std.testing.expectEqualStrings("BLOB", affinityOf(""));
    try std.testing.expectEqualStrings("BLOB", affinityOf("BLOB"));
    try std.testing.expectEqualStrings("REAL", affinityOf("DOUBLE"));
}

test "affinity compatibility allows numeric interchange" {
    try std.testing.expect(affinitiesCompatible("INTEGER", "INT"));
    try std.testing.expect(affinitiesCompatible("NUMERIC", "INTEGER"));
    try std.testing.expect(affinitiesCompatible("REAL", "NUMERIC"));
    try std.testing.expect(!affinitiesCompatible("TEXT", "INTEGER"));
    try std.testing.expect(!affinitiesCompatible("TEXT", "NUMERIC"));
}

test "sameDefault compares stored defaults" {
    try std.testing.expect(sameDefault(null, null));
    try std.testing.expect(!sameDefault(.{ .integer = 1 }, null));
    try std.testing.expect(sameDefault(.{ .integer = 1 }, .{ .integer = 1 }));
    try std.testing.expect(sameDefault(.{ .integer = 1 }, .{ .real = 1 }));
    try std.testing.expect(sameDefault(.{ .text = "a" }, .{ .text = "a" }));
    try std.testing.expect(!sameDefault(.{ .text = "a" }, .{ .text = "b" }));
    try std.testing.expect(sameDefault(null, .null));
}

test "zig type mapping documents the storage contract" {
    try std.testing.expectEqualStrings("INTEGER", dslTypeName(i64));
    try std.testing.expectEqualStrings("INTEGER", dslTypeName(bool));
    try std.testing.expectEqualStrings("INTEGER", dslTypeName(?i64));
    try std.testing.expectEqualStrings("REAL", dslTypeName(f64));
    try std.testing.expectEqualStrings("TEXT", dslTypeName([]const u8));
    try std.testing.expectEqualStrings("TEXT", dslTypeName([]u8));
    const S = struct { n: i64 = 7, t: []const u8 = "hi", f: f64 = 1.5, o: ?i64 = null, b: bool = true };
    inline for (@typeInfo(S).@"struct".fields) |field| {
        const got = zigDefault(field.type, field.default_value_ptr);
        if (std.mem.eql(u8, field.name, "n")) try std.testing.expect(got.?.integer == 7);
        if (std.mem.eql(u8, field.name, "t")) try std.testing.expectEqualStrings("hi", got.?.text);
        if (std.mem.eql(u8, field.name, "f")) try std.testing.expect(got.?.real == 1.5);
        if (std.mem.eql(u8, field.name, "o")) try std.testing.expect(got == null);
        if (std.mem.eql(u8, field.name, "b")) try std.testing.expect(got.?.integer == 1);
    }
}

test "collision-free key items accept operation-named columns" {
    const All = dslColumn.Column("t", "all", []const u8);
    const Count = dslColumn.Column("t", "count", i64);
    const Where = dslColumn.Column("t", "where", []const u8);
    var buf: [16][]const u8 = undefined;
    // Schema fields stay valid key inputs even when named like operations.
    try std.testing.expectEqual(@as(usize, 1), try normalizeKey(All{}, "t", &buf));
    try std.testing.expectEqualStrings("all", buf[0]);
    const pair = .{ Count{}, Where{} };
    try std.testing.expectEqual(@as(usize, 2), try normalizeKey(&pair, "t", &buf));
    try std.testing.expectEqualStrings("where", buf[1]);
    var expected = ExpectedKeys{};
    try parsePkInto(All{}, "t", &expected);
    try std.testing.expect(expected.hasPk and expected.pkCount == 1);
    try parseUniqueInto(.{All{}}, "t", &expected);
    try std.testing.expectEqual(@as(usize, 1), expected.uniqueSingleCount);
    // Overflow is a hard error, not silent truncation.
    var big: [17][]const u8 = undefined;
    for (&big) |*s| s.* = "x";
    try std.testing.expectError(error.InvalidSql, normalizeKey(big[0..], "t", &buf));
}
