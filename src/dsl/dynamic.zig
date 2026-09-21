//! Dynamic (runtime) table handles: stringly-typed entry to the typed engine.
//!
//! Purpose: let callers address tables/columns known only at runtime
//! (`db.table("users").column("age")`) while still lowering to the same native
//! AST/IR as the typed DSL. `DynamicTable` is a thin borrowed handle over a
//! live connection plus three executor hooks; every query method forwards to
//! `query_builder.DynamicQuery`.
//!
//! Responsibilities: table/column identity (`DynamicTable.column`,
//! alias-aware qualifiers), and pass-through SELECT/JOIN/INSERT/UPDATE/DELETE/
//! UPSERT/CTE entry points.
//!
//! Dependencies: `dsl/column.zig`, `dsl/query_builder.zig`,
//! `dsl/ast_builder.zig` (executor signatures), `connection/result.zig`.
//!
//! Ownership/lifetime: `DynamicTable` and `SchemaHandle` are borrowed handles
//! — they copy the allocator and the raw `*anyopaque` connection pointer but
//! own nothing. The connection must outlive every table handle and every
//! builder/`Result` derived from it. Re-acquire with `db.table()` after
//! close/reopen; stale handles dangle. `table`/`schema`/`alias` slices are
//! borrowed from the caller. Query results (`DynamicResult`) are owned and
//! must be `deinit`ed by the caller.
//!
//! Error behavior: handle construction never fails. Query execution returns
//! the engine's errors (`UnknownTable`, `InvalidSql`, I/O, ...). Alias/column
//! misuse surfaces at execution, not at handle creation.
//!
//! SQLite compatibility: inherits the engine's; dynamic qualifiers follow the
//! same case-insensitive, schema-aware resolution as typed references.
//!
//! Unified pipeline note: Raw SQL, this dynamic DSL, and the typed DSL all
//! converge on native AST/IR via `ast_builder` — dynamic builders never render
//! SQL strings for re-parsing.
//!
//! Column/operation collision rule: columns are fetched with the `column()`
//! *call* (`t.column("where")`), so even a column literally named `select` or
//! `where` is addressable; operations remain distinct method calls on the
//! table/query value.
//!
//! AllColumns note: `selectAll()` lowers to the native star projection; plain
//! `select(...)` with explicit columns never implies star.

const std = @import("std");
const columnMod = @import("column.zig");
const queryBuilder = @import("query_builder.zig");
const astBuilder = @import("ast_builder.zig");
const dslExpr = @import("expr.zig");

/// Re-exported runtime column descriptor; see `column.zig`.
pub const DynamicColumn = columnMod.DynamicColumn;
/// Untyped SELECT builder over the dynamic table; see `query_builder.zig`.
pub const DynamicQuery = queryBuilder.DynamicQuery;
/// Untyped UPDATE/DELETE builder; execution owns the returned `Result`.
pub const DynamicMutation = queryBuilder.Mutation;
/// Untyped UPSERT builder.
pub const DynamicUpsert = queryBuilder.UpsertBuilder(void, void);
/// Runtime result alias: owned `connection/result.zig` value; caller deinits.
pub const DynamicResult = @import("../connection/result.zig").Result;

/// Borrowed handle to one runtime table on a live connection. Owns nothing;
/// see module docs for lifetime rules.
pub const DynamicTable = struct {
    const Self = @This();
    pub const isDynamicTable = true;

    // Borrowed handle: connection must outlive every query built from this
    // table. Re-acquire with db.table() after close/reopen; stale handles
    // are dangling pointers.
    allocator: std.mem.Allocator,
    connection: *anyopaque,
    /// Borrowed executor hook for single statements (opaque connection + AST).
    executeFn: astBuilder.ExecFn,
    /// Borrowed executor hook for compound (UNION/INTERSECT/EXCEPT) queries.
    compoundExecuteFn: astBuilder.CompoundExecFn,
    /// Borrowed executor hook for derived-table (subquery) queries.
    derivedExecuteFn: astBuilder.DerivedExecFn,
    /// Borrowed schema qualifier (`""` means the default schema).
    schema: []const u8 = "",
    /// Borrowed table name.
    name: []const u8 = "",
    /// Borrowed alias set by `as()`; empty means "no alias".
    alias: []const u8 = "",

    /// Bind a borrowed table identity to borrowed executor hooks. The
    /// connection must outlive the returned handle. Never fails.
    pub fn init(
        allocator: std.mem.Allocator,
        connection: *anyopaque,
        executeFn: astBuilder.ExecFn,
        compoundExecuteFn: astBuilder.CompoundExecFn,
        derivedExecuteFn: astBuilder.DerivedExecFn,
        schema: []const u8,
        name: []const u8,
    ) Self {
        return Self{
            .allocator = allocator,
            .connection = connection,
            .executeFn = executeFn,
            .compoundExecuteFn = compoundExecuteFn,
            .derivedExecuteFn = derivedExecuteFn,
            .schema = schema,
            .name = name,
        };
    }

    /// Return an aliased copy; later `column()` calls qualify with the alias.
    /// Borrowed alias slice must outlive the copy's use.
    pub fn as(self: Self, alias: []const u8) Self {
        var copy = self;
        copy.alias = alias;
        return copy;
    }

    fn qualifier(self: *const Self) []const u8 {
        if (self.alias.len != 0) return self.alias;
        return self.name;
    }

    /// Address one runtime column (borrowed name). Works for operation-named
    /// columns too (`t.column("where")`) per the collision rule.
    pub fn column(self: *const Self, colName: []const u8) DynamicColumn {
        return .{ .name = colName, .schema = self.schema, .table = self.qualifier() };
    }

    fn qb(self: Self) DynamicQuery {
        var q = DynamicQuery.initRaw(self.allocator, self.connection, self.name, self.executeFn, self.compoundExecuteFn, self.derivedExecuteFn);
        q.schema = self.schema;
        q.tableAlias = if (self.alias.len != 0) self.alias else null;
        return q;
    }

    /// Project explicit columns; forwards to `DynamicQuery.select`. Borrowed cols.
    pub fn select(self: Self, cols: anytype) queryBuilder.SelectOut(void, void, @TypeOf(cols)) {
        return self.qb().select(cols);
    }

    /// Project all columns (native star); forwards to `DynamicQuery.selectAll`.
    pub fn selectAll(self: Self) queryBuilder.Builder(void, void, true) {
        return self.qb().selectAll();
    }

    /// Project native `COUNT(*)`; forwards to `DynamicQuery.countStar`.
    pub fn countStar(self: Self) DynamicQuery {
        return self.qb().countStar();
    }

    /// Add a non-recursive CTE (`WITH name AS (body)`); borrowed slices.
    pub fn with(self: Self, name: []const u8, body: []const u8) DynamicQuery {
        return self.qb().with(name, body);
    }

    /// Add a recursive CTE; borrowed slices.
    pub fn withRecursive(self: Self, name: []const u8, base: []const u8, recursive: []const u8) DynamicQuery {
        return self.qb().withRecursive(name, base, recursive);
    }

    /// INNER JOIN pass-through; `on` is a borrowed column predicate.
    pub fn innerJoin(self: Self, other: anytype, on: dslExpr.Expr) DynamicQuery {
        return self.qb().innerJoin(other, on);
    }
    /// LEFT JOIN pass-through.
    pub fn leftJoin(self: Self, other: anytype, on: dslExpr.Expr) DynamicQuery {
        return self.qb().leftJoin(other, on);
    }
    /// RIGHT JOIN pass-through.
    pub fn rightJoin(self: Self, other: anytype, on: dslExpr.Expr) DynamicQuery {
        return self.qb().rightJoin(other, on);
    }
    /// FULL JOIN pass-through.
    pub fn fullJoin(self: Self, other: anytype, on: dslExpr.Expr) DynamicQuery {
        return self.qb().fullJoin(other, on);
    }
    /// CROSS JOIN pass-through (no predicate).
    pub fn crossJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().crossJoin(other);
    }
    /// INNER JOIN ... USING pass-through.
    pub fn joinUsing(self: Self, other: anytype, col: anytype) DynamicQuery {
        return self.qb().joinUsing(other, col);
    }
    /// LEFT JOIN ... USING pass-through.
    pub fn leftJoinUsing(self: Self, other: anytype, col: anytype) DynamicQuery {
        return self.qb().leftJoinUsing(other, col);
    }
    /// RIGHT JOIN ... USING pass-through.
    pub fn rightJoinUsing(self: Self, other: anytype, col: anytype) DynamicQuery {
        return self.qb().rightJoinUsing(other, col);
    }
    /// FULL JOIN ... USING pass-through.
    pub fn fullJoinUsing(self: Self, other: anytype, col: anytype) DynamicQuery {
        return self.qb().fullJoinUsing(other, col);
    }
    /// NATURAL JOIN pass-through.
    pub fn naturalJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().naturalJoin(other);
    }
    /// NATURAL LEFT JOIN pass-through.
    pub fn naturalLeftJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().naturalLeftJoin(other);
    }
    /// NATURAL RIGHT JOIN pass-through.
    pub fn naturalRightJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().naturalRightJoin(other);
    }
    /// NATURAL FULL JOIN pass-through.
    pub fn naturalFullJoin(self: Self, other: anytype) DynamicQuery {
        return self.qb().naturalFullJoin(other);
    }

    /// INSERT one runtime row struct; returns an owned `Result` (caller deinits).
    pub fn insert(self: Self, row: anytype) !DynamicResult {
        return self.qb().insert(row);
    }
    /// INSERT OR IGNORE variant.
    pub fn insertOrIgnore(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrIgnore(row);
    }
    /// INSERT OR REPLACE variant.
    pub fn insertOrReplace(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrReplace(row);
    }
    /// INSERT OR ABORT variant.
    pub fn insertOrAbort(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrAbort(row);
    }
    /// INSERT OR FAIL variant.
    pub fn insertOrFail(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrFail(row);
    }
    /// INSERT OR ROLLBACK variant.
    pub fn insertOrRollback(self: Self, row: anytype) !DynamicResult {
        return self.qb().insertOrRollback(row);
    }
    /// INSERT ... SELECT pass-through; returns an owned `Result`.
    pub fn insertSelect(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelect(source);
    }
    /// INSERT ... SELECT OR IGNORE variant.
    pub fn insertSelectOrIgnore(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrIgnore(source);
    }
    /// INSERT ... SELECT OR REPLACE variant.
    pub fn insertSelectOrReplace(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrReplace(source);
    }
    /// INSERT ... SELECT OR ABORT variant.
    pub fn insertSelectOrAbort(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrAbort(source);
    }
    /// INSERT ... SELECT OR FAIL variant.
    pub fn insertSelectOrFail(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrFail(source);
    }
    /// INSERT ... SELECT OR ROLLBACK variant.
    pub fn insertSelectOrRollback(self: Self, source: anytype) !DynamicResult {
        return self.qb().insertSelectOrRollback(source);
    }

    /// INSERT FROM another table with a destination=source mapping struct.
    pub fn insertFrom(self: Self, source: anytype, mapping: anytype) !DynamicResult {
        return self.qb().insertFrom(source, mapping);
    }

    /// Begin an UPDATE mutation; chain `.where(...).execute()`.
    pub fn update(self: Self, assignments: anytype) !DynamicMutation {
        return self.qb().update(assignments);
    }

    /// Begin a DELETE mutation; chain `.where(...).execute()`.
    pub fn delete(self: Self) DynamicMutation {
        return self.qb().delete();
    }

    /// Begin an UPSERT with an explicit conflict target.
    pub fn onConflict(self: Self, target: anytype) DynamicUpsert {
        return self.qb().onConflict(target);
    }
    /// Begin an UPSERT that does nothing on conflict.
    pub fn doNothing(self: Self) DynamicUpsert {
        return self.qb().doNothing();
    }
    /// Begin an UPSERT that updates on conflict.
    pub fn doUpdate(self: Self, assignments: anytype) !DynamicUpsert {
        return self.qb().doUpdate(assignments);
    }

    /// Stage a RETURNING projection (borrowed cols) for a later mutation.
    pub fn returning(self: Self, cols: anytype) DynamicQuery {
        return self.qb().returning(cols);
    }

    /// Snapshot this table identity as a derived-table source named `alias`.
    /// Fails `InvalidSql` on empty/duplicate aliasing. Borrowed alias.
    pub fn asSubquery(self: *const Self, alias: []const u8) !DynamicQuery {
        var q = self.qb();
        return q.asSubquery(alias);
    }
};

/// Borrowed handle to one attached schema/database. Owns nothing; the
/// connection must outlive the handle. `name` is borrowed (`""` = default).
pub const SchemaHandle = struct {
    /// Borrowed allocator used for builders derived from this handle.
    allocator: std.mem.Allocator,
    /// Borrowed opaque live connection pointer. Must outlive the handle.
    connection: *anyopaque,
    /// Borrowed single-statement executor hook.
    executeFn: astBuilder.ExecFn,
    /// Borrowed compound executor hook.
    compoundExecuteFn: astBuilder.CompoundExecFn,
    /// Borrowed derived-table executor hook.
    derivedExecuteFn: astBuilder.DerivedExecFn,
    /// Borrowed schema name.
    name: []const u8 = "",

    /// Open a borrowed `DynamicTable` in this schema (borrowed table name).
    pub fn table(self: @This(), tableName: []const u8) DynamicTable {
        return DynamicTable.init(self.allocator, self.connection, self.executeFn, self.compoundExecuteFn, self.derivedExecuteFn, self.name, tableName);
    }
};

test "dynamic table columns carry table identity" {
    const std_testing = @import("std").testing;
    var t = DynamicTable.init(std_testing.allocator, undefined, undefined, undefined, undefined, "", "users");
    const id = t.column("id");
    try std_testing.expectEqualStrings("id", id.name);
    try std_testing.expectEqualStrings("", id.schema);
    try std_testing.expectEqualStrings("users", id.table);
    try std_testing.expectEqualStrings("users", t.name);
    try std_testing.expect(t.alias.len == 0);
    const ref = columnMod.dynRef(id);
    try std_testing.expectEqualStrings("users", ref.table);
    try std_testing.expectEqualStrings("", ref.schema);
    try std_testing.expectEqualStrings("id", ref.name);
}

test "schema-qualified dynamic tables keep schema identity" {
    const std_testing = @import("std").testing;
    var t = DynamicTable.init(std_testing.allocator, undefined, undefined, undefined, undefined, "archive", "users");
    try std_testing.expectEqualStrings("archive", t.schema);
    try std_testing.expectEqualStrings("users", t.name);
    const id = t.column("id");
    const ref = columnMod.dynRef(id);
    try std_testing.expectEqualStrings("archive", ref.schema);
    try std_testing.expectEqualStrings("users", ref.table);
    try std_testing.expectEqualStrings("id", ref.name);
}

test "dynamic table aliases rebind column qualifiers" {
    const std_testing = @import("std").testing;
    var t = DynamicTable.init(std_testing.allocator, undefined, undefined, undefined, undefined, "", "users");
    const u = t.as("u");
    try std_testing.expectEqualStrings("u", u.alias);
    try std_testing.expectEqualStrings("users", u.name);
    const id = u.column("id");
    const ref = columnMod.dynRef(id);
    try std_testing.expectEqualStrings("u", ref.table);
    try std_testing.expectEqualStrings("id", ref.name);
}

test "operation-named dynamic columns stay addressable" {
    const std_testing = @import("std").testing;
    var t = DynamicTable.init(std_testing.allocator, undefined, undefined, undefined, undefined, "", "weird");
    // Collision rule: `column("where")` is a call, so schema fields named
    // like operations remain reachable at runtime.
    for ([_][]const u8{ "all", "count", "select", "where", "join", "limit" }) |opname| {
        const col = t.column(opname);
        const ref = columnMod.dynRef(col);
        try std_testing.expectEqualStrings(opname, ref.name);
        try std_testing.expectEqualStrings("weird", ref.table);
        const pred = col.eq(1);
        try std_testing.expectEqualStrings(opname, pred.column.name);
    }
    const aliased = t.as("w").column("where");
    try std_testing.expectEqualStrings("w", columnMod.dynRef(aliased).table);
    const handle = SchemaHandle{ .allocator = std_testing.allocator, .connection = undefined, .executeFn = undefined, .compoundExecuteFn = undefined, .derivedExecuteFn = undefined, .name = "archive" };
    try std_testing.expectEqualStrings("users", handle.table("users").name);
    try std_testing.expectEqualStrings("archive", handle.table("users").schema);
}
