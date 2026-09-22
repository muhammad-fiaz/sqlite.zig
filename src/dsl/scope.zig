//! Query-scope resolution for the typed DSL: the dual mapping model.
//!
//! A query builder rooted at `db.from(Table)` establishes a root/current
//! table scope. Inside that scope, unqualified typed fields (`.id`, written
//! as Zig enum literals in column lists) resolve against the scope's table,
//! while explicit table-qualified columns (`User.id`, `u.id`) carry their own
//! table identity through the native IR. Both forms converge on the same
//! `ColumnRef` representation: scoped references simply fill in the scope's
//! qualifier, explicit ones keep theirs.
//!
//! ```text
//! Unqualified typed field (.id):
//!     resolves against the current/root query table (or its alias).
//!
//! Qualified typed column (User.id / u.id):
//!     explicitly identifies a table or alias; scope never overrides it.
//!
//! Nested query:
//!     creates a new local scope; inner fields bind to the inner table.
//!
//! Correlated reference:
//!     may explicitly reference an outer scope by table/alias identity.
//!
//! Schema definition (createTable / keys / indexes):
//!     unqualified fields resolve against the target table being defined;
//!     foreign-key `references` must stay explicit (the parent scope is
//!     unknown there, so guessing would be silent magic).
//! ```
//!
//! Resolution is comptime over borrowed names; nothing allocates and no SQL
//! text is ever produced or reparsed. Unknown fields are compile errors
//! naming the problem, never silent guesses.

const std = @import("std");
const dslExpr = @import("expr.zig");
const ColumnRef = dslExpr.ColumnRef;

/// The compile-time type of a bare `.field` enum literal. Tuple elements in
/// `select(.{ .id, .name })` and bare `.id` arguments arrive as this type.
pub const EnumLiteral = @TypeOf(.id);

/// Native query-scope identity: which table unqualified typed fields belong
/// to, plus the alias that replaces the table name when one is set (mirrors
/// `StripBase` in `ast_builder`, which strips qualifiers matching the
/// alias first, then the table name).
pub const Scope = struct {
    table: []const u8,
    alias: ?[]const u8 = null,

    /// Effective qualifier for scoped references: the alias when set,
    /// otherwise the table name. Never empty for well-formed scopes.
    pub fn qualifier(self: Scope) []const u8 {
        return self.alias orelse self.table;
    }
};

/// True when `T` is a bare `.field` enum literal.
pub fn isEnumLiteral(comptime T: type) bool {
    return T == EnumLiteral;
}

/// True when `T` is one scoped field of a typed (`Row != void`) scope: a
/// bare enum literal (`.id`) or a value of the row's field-name enum.
/// Untyped scopes (`Row == void`) have no column mapping, so even bare
/// literals are rejected there: dynamic queries use `column("name")`.
pub fn isScopedItem(comptime T: type, comptime Row: type) bool {
    if (Row == void) return false;
    if (T == EnumLiteral) return true;
    return T == std.meta.FieldEnum(Row);
}

/// True when `T` is a column list of scoped fields: a tuple, fixed array,
/// or slice whose every (element) type is a scoped item. Empty tuples are
/// not scoped lists. Untyped (`Row == void`) scopes accept no scoped lists.
pub fn isScopedList(comptime T: type, comptime Row: type) bool {
    if (Row == void) return false;
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) return isScopedList(info.pointer.child, Row);
    if (info == .array) return isScopedItem(info.array.child, Row);
    if (info == .pointer and info.pointer.size == .slice) return isScopedItem(info.pointer.child, Row);
    if (info == .@"struct" and info.@"struct".is_tuple) {
        const fields = info.@"struct".fields;
        if (fields.len == 0) return false;
        inline for (fields) |field| {
            if (!isScopedItem(field.type, Row)) return false;
        }
        return true;
    }
    return false;
}

/// True when `T` mixes explicit column descriptors and scoped fields in one
/// tuple (e.g. `.{ .id, Membership.group_id }`). Element-wise dispatch in
/// the builder handles each form; this only detects the shape.
pub fn isMixedList(comptime T: type, comptime Row: type) bool {
    if (Row == void) return false;
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) return isMixedList(info.pointer.child, Row);
    if (info != .@"struct" or !info.@"struct".is_tuple) return false;
    const fields = info.@"struct".fields;
    if (fields.len == 0) return false;
    var sawScoped = false;
    var sawOther = false;
    inline for (fields) |field| {
        if (isScopedItem(field.type, Row)) {
            sawScoped = true;
        } else {
            sawOther = true;
        }
    }
    return sawScoped and sawOther;
}

/// Borrowed SQL name for a zig field name under `Columns` (the table's
/// columns descriptor struct). Usable at runtime for slice inputs; returns
/// null when the field is unknown.
pub fn sqlNameOf(comptime Columns: type, zigName: []const u8) ?[]const u8 {
    inline for (@typeInfo(Columns).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, zigName)) return field.type.dslName;
    }
    return null;
}

/// Resolve one scoped field to a native `ColumnRef` against `Columns` and
/// `scope`. The item may be a bare enum literal (`.id`) or a field-enum
/// value, comptime or runtime. Unknown fields panic naming the field and
/// table (a compile error for comptime inputs): with no valid root scope
/// to bind them, guessing would be silent magic. The panic (rather than
/// `@compileError`) keeps valid runtime field-enum values working, since an
/// `orelse @compileError` would fire even for those.
pub fn resolveRef(comptime Row: type, comptime Columns: type, scope: Scope, item: anytype) ColumnRef {
    const E = std.meta.FieldEnum(Row);
    const coerced: E = item;
    const zigName = @tagName(coerced);
    const sqlName = sqlNameOf(Columns, zigName) orelse std.debug.panic("scoped field '{s}' is not a column of table '{s}'", .{ zigName, scope.table });
    return .{ .table = scope.qualifier(), .name = sqlName };
}

/// Resolve one scoped field where the zig field name is already known
/// (runtime slice path). Returns null for unknown fields.
pub fn resolveName(comptime Columns: type, scope: Scope, zigName: []const u8) ?ColumnRef {
    const sqlName = sqlNameOf(Columns, zigName) orelse return null;
    return .{ .table = scope.qualifier(), .name = sqlName };
}

/// Scope of a query builder: its alias when set, else its table name.
pub fn builderScope(table: []const u8, tableAlias: ?[]const u8) Scope {
    return .{ .table = table, .alias = tableAlias };
}

/// Comptime scope bundle for key/DDL resolution: the row struct (for the
/// field-name enum) plus the columns descriptor struct (for zig to sql
/// names). Thread one of these through key normalization instead of bare
/// strings so unqualified fields (`.id`) resolve against the target table
/// being defined, while explicit columns keep their own table identity.
pub fn TypeScope(comptime RowT: type, comptime ColumnsT: type) type {
    return struct {
        pub const Row = RowT;
        pub const Columns = ColumnsT;
        pub const isScoped = RowT != void and ColumnsT != void;
    };
}

/// Scope bundle for untyped targets (dynamic tables, name strings):
/// scoped fields are rejected with a clear compile error.
pub const Unscoped = TypeScope(void, void);

/// Borrowed SQL name for a scoped field name under a `TypeScope` bundle.
/// Panics naming the field and table when unknown (a compile error for
/// comptime inputs, a loud runtime panic otherwise); see `resolveRef`.
pub fn resolveSqlName(comptime S: type, scopeTable: []const u8, zigName: []const u8) []const u8 {
    if (S.isScoped) {
        return sqlNameOf(S.Columns, zigName) orelse std.debug.panic("scoped field '{s}' is not a column of table '{s}'", .{ zigName, scopeTable });
    }
    std.debug.panic("unqualified field '{s}' needs a typed table scope", .{zigName});
}

/// Coerce a scoped item (bare enum literal or field-enum value) to its zig
/// field name. Callers must have established `isScopedItem` first.
pub fn fieldNameOf(comptime S: type, item: anytype) []const u8 {
    const coerced: std.meta.FieldEnum(S.Row) = item;
    return @tagName(coerced);
}

test "scopes qualify with alias first" {
    const s = Scope{ .table = "users", .alias = "u" };
    try std.testing.expectEqualStrings("u", s.qualifier());
    const plain = Scope{ .table = "users" };
    try std.testing.expectEqualStrings("users", plain.qualifier());
    try std.testing.expectEqual(builderScope("t", null).qualifier(), "t");
    try std.testing.expectEqualStrings("m", builderScope("memberships", "m").qualifier());
}

test "scoped shapes detect literals lists and mixes" {
    const Row = struct { id: i64, name: []const u8 };
    try std.testing.expect(isEnumLiteral(EnumLiteral));
    try std.testing.expect(isScopedItem(EnumLiteral, Row));
    try std.testing.expect(isScopedItem(std.meta.FieldEnum(Row), Row));
    try std.testing.expect(!isScopedItem(i64, Row));
    try std.testing.expect(!isScopedItem(EnumLiteral, void));
    try std.testing.expect(isScopedList(@TypeOf(.{ .id, .name }), Row));
    try std.testing.expect(isScopedList(@TypeOf(.{.id}), Row));
    try std.testing.expect(!isScopedList(@TypeOf(.{}), Row));
    try std.testing.expect(!isScopedList(@TypeOf(.{ .id, 1 }), Row));
    try std.testing.expect(!isScopedList(i64, Row));
    const arr = [_]EnumLiteral{ .id, .name };
    try std.testing.expect(isScopedList(@TypeOf(arr), Row));
    try std.testing.expect(isScopedList([]const std.meta.FieldEnum(Row), Row));
}

test "resolveRef maps zig fields onto sql names under scope" {
    const Row = struct { id: i64, userName: []const u8 };
    const Col = @import("column.zig").Column;
    const Columns = struct {
        id: Col("users", "id", i64),
        userName: Col("users", "user_name", []const u8),
    };
    const plain = resolveRef(Row, Columns, .{ .table = "users" }, .id);
    try std.testing.expectEqualStrings("users", plain.table);
    try std.testing.expectEqualStrings("id", plain.name);
    const mapped = resolveRef(Row, Columns, .{ .table = "users" }, .userName);
    try std.testing.expectEqualStrings("user_name", mapped.name);
    const aliased = resolveRef(Row, Columns, .{ .table = "users", .alias = "u" }, .id);
    try std.testing.expectEqualStrings("u", aliased.table);
    try std.testing.expectEqualStrings("id", aliased.name);
    try std.testing.expectEqualStrings("user_name", sqlNameOf(Columns, "userName").?);
    try std.testing.expect(sqlNameOf(Columns, "nope") == null);
    try std.testing.expect(resolveName(Columns, .{ .table = "users" }, "id").?.name.len == 2);
}
