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
//!     resolves against the current/root table scope (or its alias).
//!     A bare column such as `.id` refers to the current/root table scope.
//!     Use `Table.id` or an alias such as `t.id` when referring to another
//!     table or when explicit qualification is required.
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
//!     unqualified fields resolve against the target table being defined.
//!     Foreign-key `references` follows the same rule: a bare field means
//!     the table being defined (the reference target for self-references),
//!     while cross-table parents stay explicit (`Parent.id`) — never a
//!     name-inferred guess, and relationships stay explicit FK metadata.
//!
//! All-columns markers (User.all() / u.all()):
//!     carry their source scope (table name or alias); a foreign scope
//!     expands to that side's qualified references, the root scope keeps
//!     the mapped star, and bare `.all` is the root star.
//! ```
//!
//! Resolution is comptime over borrowed names; nothing allocates and no SQL
//! text is ever produced or reparsed. Unknown fields are compile errors
//! naming the problem, never silent guesses. Bare fields never search all
//! tables: with no deterministic scope they fail loudly instead.
//!
//! One Zig-expressible boundary: operators and method calls cannot hang off
//! a bare literal (`.id.eq(1)` is rejected by the Zig compiler itself, with
//! `no field or member function named 'eq' in '@EnumLiteral()'`), so scoped
//! predicates spell through the builder's scoped columns (`q.c().id.eq(1)`)
//! or explicit paths (`User.id.eq(1)`). The scope rule itself is unchanged:
//! `q.c().id` still means the current/root table's `id`.

const std = @import("std");
const dslExpr = @import("expr.zig");
const ColumnRef = dslExpr.ColumnRef;

/// The compile-time type of a bare `.field` enum literal. Tuple elements in
/// `select(.{ .id, .name })` and bare `.id` arguments arrive as this type.
pub const EnumLiteral = @TypeOf(.id);

/// Native query-scope identity: which table unqualified typed fields belong
/// to, plus the schema and alias that qualify references. The alias
/// replaces the table name when set (`ast_builder` strips qualifiers
/// matching the alias first, then the table name). This is the single
/// scope representation shared by the DSL builders and the AST lowering
/// (`StripBase` is an alias of this struct).
pub const Scope = struct {
    table: []const u8,
    schema: []const u8 = "",
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
/// value, comptime or runtime (`@tagName` reads both, so no enum coercion
/// can fail). Unknown fields panic naming the field and table (a compile
/// error for comptime inputs): with no valid root scope to bind them,
/// guessing would be silent magic. The panic (rather than `@compileError`)
/// keeps valid runtime field-enum values working, since an
/// `orelse @compileError` would fire even for those.
pub fn resolveRef(comptime Row: type, comptime Columns: type, scope: Scope, item: anytype) ColumnRef {
    _ = Row;
    const zigName = @tagName(item);
    const sqlName = sqlNameOf(Columns, zigName) orelse std.debug.panic("scoped field '{s}' is not a column of table '{s}'", .{ zigName, scope.table });
    return .{ .table = scope.qualifier(), .name = sqlName };
}

/// Scope of a query builder: its alias when set, else its table name.
pub fn builderScope(table: []const u8, tableAlias: ?[]const u8) Scope {
    return .{ .table = table, .alias = tableAlias };
}

/// Scope of a catalog operation over one table in a schema.
pub fn tableScope(table: []const u8, schema: []const u8, tableAlias: ?[]const u8) Scope {
    return .{ .table = table, .schema = schema, .alias = tableAlias };
}

/// True when `item` is the scoped all-columns marker: the bare `.all`
/// literal on a row type with no `all` column. A real `all` column always
/// wins (collision rule), resolving as an ordinary scoped field instead.
/// `@tagName` reads bare literals directly, so no enum coercion can fail.
pub fn isScopedAll(comptime T: type, comptime Row: type, item: anytype) bool {
    if (T != EnumLiteral or Row == void) return false;
    if (@hasField(Row, "all")) return false;
    return std.mem.eql(u8, @tagName(item), "all");
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

/// Read a scoped item's zig field name. Callers must have established
/// `isScopedItem` first (`@tagName` reads literals and enum values alike).
pub fn fieldNameOf(comptime S: type, item: anytype) []const u8 {
    _ = S;
    return @tagName(item);
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
}
