//! Comptime typed table descriptors with collision-free columns.
//!
//! Everything is comptime-known borrowed names; no heap, no deinit.
//! Misuse is a compile error.

const std = @import("std");
const Column = @import("column.zig").Column;

/// Native all-columns marker, parameterized by source scope: the table name
/// (or alias) qualifier plus the source columns descriptor. `User.all()`
/// carries `"users"`; `u.all()` on an aliased table carries the alias.
/// Query builders expand a foreign scope's marker into that side's explicit
/// qualified column references (native `ColumnRef`s, never SQL text), while
/// a marker naming the builder's own scope keeps the mapped star. Bare
/// `.all` in scoped lists stays the root star (see `query_builder`).
/// Only produced by the synthesized `all()` call; a schema field named
/// `all` is a `Column`, never this struct.
pub fn AllProjection(comptime qualifier: []const u8, comptime Cols: type) type {
    return struct {
        /// Table name (or alias) this marker projects.
        pub const qualifierName = qualifier;
        /// Source columns descriptor, for scope-aware expansion.
        pub const Columns = Cols;
        pub const isAllProjection = true;
    };
}

/// True for any `AllProjection(qualifier, Columns)` marker instantiation.
pub fn isAllProjectionType(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "isAllProjection") and T.isAllProjection;
}

/// True for a synthesized `all` operation function pointer: `*const fn ()`
/// returning an `AllProjection` marker. Each table (or alias) value carries
/// its own instantiation, so the marker always knows its source scope.
pub fn isAllOpFn(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one) return false;
    const fnInfo = @typeInfo(info.pointer.child);
    if (fnInfo != .@"fn") return false;
    if (fnInfo.@"fn".params.len != 0) return false;
    const Ret = fnInfo.@"fn".return_type orelse return false;
    return isAllProjectionType(Ret);
}

/// Build the per-value `all` operation returning a scope-carrying marker.
/// `qualifier` is the table name (or alias); `Cols` is that value's columns
/// descriptor type. The marker value itself is empty — all identity lives
/// in its type, so `query_builder` can expand it at comptime.
fn allOpFor(comptime qualifier: []const u8, comptime Cols: type) *const fn () AllProjection(qualifier, Cols) {
    return &struct {
        fn f() AllProjection(qualifier, Cols) {
            return .{};
        }
    }.f;
}

/// Number of synthesized metadata fields prepended to every table struct.
pub const metaCount = 5;

/// True when `T` is a `Column(...)` descriptor struct (has `isDslColumn`).
pub fn isColumnField(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "isDslColumn") and T.isDslColumn;
}

fn RowHolder(comptime R: type) type {
    return struct {
        pub const value: type = R;
    };
}

fn OptHolder(comptime o: anytype) type {
    return struct {
        pub const value = o;
    };
}

/// Define a typed table from a row struct (`struct { id: i64, ... }`).
/// Zig field names default to identical SQL names. Returns a table *value*.
pub fn table(comptime name: []const u8, comptime spec: anytype) TablePublic(name, spec, .{}) {
    return tableWith(name, spec, .{});
}

/// Table type for `table()`/`tableWith()`: metadata fields plus one `Column`
/// per schema field, plus a synthesized `all` operation (returning a
/// scope-carrying `AllProjection` marker) unless the schema
/// declares its own `all` column (collision rule).
pub fn TablePublic(comptime name: []const u8, comptime spec: anytype, comptime opts: anytype) type {
    if (@TypeOf(spec) == type) {
        const info = @typeInfo(spec);
        if (info != .@"struct") @compileError("sqlite.table row must be a struct");
        return TableTypeFor(name, spec, opts, info.@"struct".fields, null);
    }
    return DescribedTypeFor(name, spec, opts);
}

/// Define a typed table with options (e.g. strict/without-rowid flags).
/// `spec` is either a row struct or a descriptor struct of `column()` values.
pub fn tableWith(comptime name: []const u8, comptime spec: anytype, comptime opts: anytype) TablePublic(name, spec, opts) {
    if (@TypeOf(spec) == type) {
        const info = @typeInfo(spec);
        if (info != .@"struct") @compileError("sqlite.table row must be a struct");
        return buildTable(name, spec, opts, info.@"struct".fields, null);
    }
    return buildDescribed(name, spec, opts);
}

fn sqlNameFor(comptime zigName: []const u8, comptime mappings: anytype) []const u8 {
    if (mappings) |fields| {
        inline for (fields) |f| {
            if (f[0].len == zigName.len and comptimeStringEq(f[0], zigName)) return f[1];
        }
    }
    return zigName;
}

fn comptimeStringEq(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn makeAttrs(comptime n: usize) *const [n]std.builtin.Type.StructField.Attributes {
    const A = [_]std.builtin.Type.StructField.Attributes{.{}} ** n;
    return &A;
}

fn TableTypeFor(
    comptime name: []const u8,
    comptime Row: type,
    comptime opts: anytype,
    comptime rowFields: anytype,
    comptime mappings: anytype,
) type {
    const N = rowFields.len;
    const hasUserAll = @hasField(Row, "all");
    const Total = N + metaCount + (if (hasUserAll) 0 else 1);
    comptime var names: [Total][:0]const u8 = undefined;
    comptime var types: [Total]type = undefined;
    names[0] = "tableName";
    names[1] = "columnNames";
    names[2] = "rowType";
    names[3] = "tableOptions";
    names[4] = "tableAlias";
    types[0] = []const u8;
    types[1] = [N][]const u8;
    types[2] = RowHolder(Row);
    types[3] = OptHolder(opts);
    types[4] = []const u8;
    comptime var colNames: [N][:0]const u8 = undefined;
    comptime var colTypes: [N]type = undefined;
    inline for (rowFields, 0..) |field, i| {
        const buf = field.name ++ [_]u8{0};
        names[metaCount + i] = buf[0..field.name.len :0];
        types[metaCount + i] = Column(name, sqlNameFor(field.name, mappings), field.type);
        colNames[i] = names[metaCount + i];
        colTypes[i] = types[metaCount + i];
    }
    if (!hasUserAll) {
        names[metaCount + N] = "all";
        const ColsOnly = @Struct(.auto, null, &colNames, &colTypes, makeAttrs(N));
        types[metaCount + N] = *const fn () AllProjection(name, ColsOnly);
    }
    return @Struct(.auto, null, &names, &types, makeAttrs(Total));
}

fn DescribedTypeFor(comptime tname: []const u8, comptime spec: anytype, comptime opts: anytype) type {
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;
    const N = fields.len;
    const hasUserAll = @hasField(@TypeOf(spec), "all");
    const Total = N + metaCount + (if (hasUserAll) 0 else 1);
    comptime var names: [Total][:0]const u8 = undefined;
    comptime var types: [Total]type = undefined;
    comptime var ftypes: [N]type = undefined;
    names[0] = "tableName";
    names[1] = "columnNames";
    names[2] = "rowType";
    names[3] = "tableOptions";
    names[4] = "tableAlias";
    types[0] = []const u8;
    types[1] = [N][]const u8;
    types[3] = OptHolder(opts);
    types[4] = []const u8;
    comptime var colNames: [N][:0]const u8 = undefined;
    comptime var colTypes: [N]type = undefined;
    inline for (fields, 0..) |field, i| {
        const VT = @TypeOf(@field(spec, field.name));
        const zbuf = field.name ++ [_]u8{0};
        names[metaCount + i] = zbuf[0..field.name.len :0];
        types[metaCount + i] = Column(tname, VT.dslName, VT.fieldType);
        ftypes[i] = VT.fieldType;
        colNames[i] = names[metaCount + i];
        colTypes[i] = types[metaCount + i];
    }
    if (!hasUserAll) {
        names[metaCount + N] = "all";
        const ColsOnly = @Struct(.auto, null, &colNames, &colTypes, makeAttrs(N));
        types[metaCount + N] = *const fn () AllProjection(tname, ColsOnly);
    }
    comptime var fnames: [N][:0]const u8 = undefined;
    inline for (0..N) |i| {
        fnames[i] = names[metaCount + i];
    }
    const Row = @Struct(.auto, null, &fnames, &ftypes, makeAttrs(N));
    types[2] = RowHolder(Row);
    return @Struct(.auto, null, &names, &types, makeAttrs(Total));
}

fn buildTable(
    comptime name: []const u8,
    comptime Row: type,
    comptime opts: anytype,
    comptime rowFields: anytype,
    comptime mappings: anytype,
) TableTypeFor(name, Row, opts, rowFields, mappings) {
    const N = rowFields.len;
    const T = TableTypeFor(name, Row, opts, rowFields, mappings);
    var sqls: [N][]const u8 = undefined;
    inline for (rowFields, 0..) |field, i| {
        sqls[i] = sqlNameFor(field.name, mappings);
    }
    var v: T = undefined;
    v.tableName = name;
    v.columnNames = sqls;
    v.rowType = .{};
    v.tableOptions = .{};
    v.tableAlias = "";
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isColumnField(field.type)) {
            @field(v, field.name) = .{};
        } else if (comptime isAllOpFn(field.type)) {
            @field(v, field.name) = allOpForType(field.type);
        }
    }
    return v;
}

fn buildDescribed(comptime tname: []const u8, comptime spec: anytype, comptime opts: anytype) DescribedTypeFor(tname, spec, opts) {
    const T = DescribedTypeFor(tname, spec, opts);
    const fields = @typeInfo(@TypeOf(spec)).@"struct".fields;
    const N = fields.len;
    var sqls: [N][]const u8 = undefined;
    inline for (fields, 0..) |field, i| {
        sqls[i] = @TypeOf(@field(spec, field.name)).dslName;
    }
    var v: T = undefined;
    v.tableName = tname;
    v.columnNames = sqls;
    v.rowType = .{};
    v.tableOptions = .{};
    v.tableAlias = "";
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isColumnField(field.type)) {
            @field(v, field.name) = .{};
        } else if (comptime isAllOpFn(field.type)) {
            @field(v, field.name) = allOpForType(field.type);
        }
    }
    return v;
}

/// True when `T` is a table *value* type (has all metadata + `all` fields).
pub fn isTableValue(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasField(T, "tableName") and @hasField(T, "columnNames") and
        @hasField(T, "rowType") and @hasField(T, "tableOptions") and @hasField(T, "all") and
        @hasField(T, "tableAlias");
}

fn isMetaFieldName(comptime name: []const u8) bool {
    return comptimeStringEq(name, "tableName") or comptimeStringEq(name, "columnNames") or
        comptimeStringEq(name, "rowType") or comptimeStringEq(name, "tableOptions") or
        comptimeStringEq(name, "tableAlias");
}

/// Rebind a table value's columns to `aliasName` (for self-joins), keeping
/// field types and SQL names. `tableName` is preserved; `tableAlias` becomes
/// the alias. Comptime alias slice must outlive the result.
/// This free function (not a `User.as("u")` method) is the alias API by
/// necessity: table values are comptime-generated `@Struct` types, which
/// cannot carry methods, and an `as` field could not type its return on the
/// alias value. Never mutates the schema: the original value keeps its
/// identity, and only the rebound copy qualifies with the alias.
pub fn AliasedType(comptime T: type, comptime aliasName: []const u8) type {
    if (!isTableValue(T)) @compileError("aliased() takes a sqlite.table(...) value");
    if (aliasName.len == 0) @compileError("alias must not be empty");
    const fields = @typeInfo(T).@"struct".fields;
    comptime var names: [fields.len][:0]const u8 = undefined;
    comptime var types: [fields.len]type = undefined;
    comptime var allIndex: ?usize = null;
    inline for (fields, 0..) |field, i| {
        const buf = field.name ++ [_]u8{0};
        names[i] = buf[0..field.name.len :0];
        if (isMetaFieldName(field.name)) {
            types[i] = field.type;
        } else if (comptime isAllOpFn(field.type)) {
            allIndex = i;
        } else {
            types[i] = Column(aliasName, field.type.dslName, field.type.fieldType);
        }
    }
    if (allIndex) |ai| {
        // The alias carries its own all-columns operation. Column fields
        // sit between the metadata prefix and the trailing `all` operation
        // (the same layout `columnsTypeOfValue` assumes); bundle the
        // rebound columns so `u.all()` expands to the alias's references.
        const first = metaCount;
        const n = if (ai > first) ai - first else 0;
        comptime var colNames: [n][:0]const u8 = undefined;
        comptime var colTypes: [n]type = undefined;
        inline for (0..n) |k| {
            colNames[k] = names[first + k];
            colTypes[k] = types[first + k];
        }
        const ColsOnly = @Struct(.auto, null, &colNames, &colTypes, makeAttrs(n));
        types[ai] = *const fn () AllProjection(aliasName, ColsOnly);
    }
    return @Struct(.auto, null, &names, &types, makeAttrs(fields.len));
}

/// Build the `all` operation value matching a specialized `all` field type
/// exactly. The marker value is empty; all identity lives in its type, so
/// `query_builder` can expand it into that scope's qualified references.
fn allOpForType(comptime Fn: type) Fn {
    const Child = @typeInfo(Fn).pointer.child;
    const fnInfo = @typeInfo(Child);
    if (fnInfo != .@"fn") @compileError("all operation field must be a function pointer");
    const Ret = fnInfo.@"fn".return_type orelse @compileError("all operation must return an AllProjection marker");
    return &struct {
        fn f() Ret {
            return .{};
        }
    }.f;
}

/// Build the aliased table value described by `AliasedType`.
pub fn aliased(tbl: anytype, comptime aliasName: []const u8) AliasedType(@TypeOf(tbl), aliasName) {
    const T = @TypeOf(tbl);
    const A = AliasedType(T, aliasName);
    const AF = @typeInfo(A).@"struct".fields;
    const TF = @typeInfo(T).@"struct".fields;
    var v: A = undefined;
    inline for (AF, 0..) |afield, i| {
        if (comptime isMetaFieldName(afield.name)) {
            if (comptime comptimeStringEq(afield.name, "tableAlias")) {
                @field(v, afield.name) = aliasName;
            } else {
                @field(v, afield.name) = @field(tbl, TF[i].name);
            }
        } else if (comptime isAllOpFn(afield.type)) {
            @field(v, afield.name) = allOpForType(afield.type);
        } else {
            // Column fields rebound to the alias; default-constructed values.
            @field(v, afield.name) = .{};
        }
    }
    return v;
}

/// Borrowed SQL table name of a table value.
pub fn tableNameOfValue(source: anytype) []const u8 {
    return source.tableName;
}

/// Row struct type carried by a table value type.
pub fn rowTypeOfValue(comptime T: type) type {
    return @typeInfo(T).@"struct".fields[2].type.value;
}

/// Options-holder type carried by a table value type.
pub fn tableOptionsField(comptime T: type) type {
    return @typeInfo(T).@"struct".fields[3].type;
}

fn hasTrailingAllOp(comptime T: type) bool {
    const f = @typeInfo(T).@"struct".fields;
    if (f.len <= metaCount) return false;
    const last = f[f.len - 1];
    return comptimeStringEq(last.name, "all") and isAllOpFn(last.type);
}

/// Columns-only struct type of a table value (metadata + trailing `all` op
/// stripped). Used by `query_builder` to map result columns positionally.
pub fn columnsTypeOfValue(comptime T: type) type {
    const f = @typeInfo(T).@"struct".fields;
    const skip: usize = if (hasTrailingAllOp(T)) 1 else 0;
    const n = f.len - metaCount - skip;
    comptime var names: [n][:0]const u8 = undefined;
    comptime var types: [n]type = undefined;
    inline for (0..n) |i| {
        names[i] = f[metaCount + i].name;
        types[i] = f[metaCount + i].type;
    }
    return @Struct(.auto, null, &names, &types, makeAttrs(n));
}

/// Number of column fields in a table value type (excludes metadata/`all`).
pub fn columnCount(comptime T: type) usize {
    const f = @typeInfo(T).@"struct".fields;
    const skip: usize = if (hasTrailingAllOp(T)) 1 else 0;
    return f.len - metaCount - skip;
}

test "typed table exposes columns directly" {
    const User = table("users", struct { id: i64, name: []const u8 });
    try std.testing.expectEqualStrings("users", User.tableName);
    try std.testing.expectEqualStrings("id", @TypeOf(User.id).name);
    try std.testing.expectEqualStrings("name", @TypeOf(User.name).name);
    try std.testing.expectEqualStrings("users", @TypeOf(User.id).table);
    try std.testing.expect(@TypeOf(User.id).fieldType == i64);
    try std.testing.expect(isTableValue(@TypeOf(User)));
    try std.testing.expectEqualStrings("users", tableNameOfValue(User));
    try std.testing.expectEqualStrings("id", User.columnNames[0]);
}

test "columns keep table identity across tables" {
    const User = table("t_users", struct { id: i64, name: []const u8 });
    const Order = table("t_orders", struct { id: i64, user_id: i64 });
    try std.testing.expectEqualStrings("t_users", @TypeOf(User.id).table);
    try std.testing.expectEqualStrings("t_orders", @TypeOf(Order.id).table);
    try std.testing.expect(@TypeOf(User.id).fieldType == i64);
}

test "descriptors map zig names onto sql names" {
    const col = @import("column.zig").column;
    const User = table("users", .{
        .firstName = col("first_name", []const u8),
        .ageYears = col("age_years", i64),
    });
    try std.testing.expectEqualStrings("first_name", @TypeOf(User.firstName).name);
    try std.testing.expect(@TypeOf(User.ageYears).fieldType == i64);
}

test "aliased tables rebind columns without losing types" {
    const User = table("users", struct { id: i64, name: []const u8 });
    const u = aliased(User, "u");
    try std.testing.expect(isTableValue(@TypeOf(u)));
    try std.testing.expectEqualStrings("users", u.tableName);
    try std.testing.expectEqualStrings("u", u.tableAlias);
    try std.testing.expectEqualStrings("u", @TypeOf(u.id).table);
    try std.testing.expectEqualStrings("id", @TypeOf(u.id).name);
    try std.testing.expect(@TypeOf(u.id).fieldType == i64);
    try std.testing.expectEqualStrings("name", @TypeOf(u.name).name);
}

test "all() builds the all-columns operation on collision-free tables" {
    const User = table("users", struct { id: i64, name: []const u8 });
    const proj = User.all();
    try std.testing.expect(isAllProjectionType(@TypeOf(proj)));
    try std.testing.expectEqualStrings("users", @TypeOf(proj).qualifierName);
    try std.testing.expect(isTableValue(@TypeOf(User)));
    try std.testing.expectEqual(@as(usize, 2), columnCount(@TypeOf(User)));
    // The alias keeps a working all-columns operation bound to the alias.
    const u = aliased(User, "u");
    try std.testing.expect(isAllProjectionType(@TypeOf(u.all())));
    try std.testing.expectEqualStrings("u", @TypeOf(u.all()).qualifierName);
    // The marker's columns describe the source scope for expansion.
    inline for (@typeInfo(@TypeOf(u.all()).Columns).@"struct".fields) |f| {
        try std.testing.expectEqualStrings("u", f.type.table);
    }
    inline for (@typeInfo(@TypeOf(proj).Columns).@"struct".fields) |f| {
        try std.testing.expectEqualStrings("users", f.type.table);
    }
}

test "columns named like dsl operations stay plain fields" {
    const WeirdRow = struct {
        id: i64,
        all: []const u8,
        count: i64,
        len: i64,
        select: []const u8,
        where: []const u8,
        join: []const u8,
        limit: i64,
        offset: i64,
        orderBy: []const u8,
        groupBy: []const u8,
        having: i64,
        insert: []const u8,
        update: []const u8,
        delete: []const u8,
        returning: []const u8,
    };
    const Weird = table("weird", WeirdRow);
    try std.testing.expect(isTableValue(@TypeOf(Weird)));
    // Every DSL-looking name is a real typed column descriptor here,
    // including `all`: no operation field shadows user schema.
    try std.testing.expectEqualStrings("all", @TypeOf(Weird.all).name);
    try std.testing.expect(@TypeOf(Weird.all).fieldType == []const u8);
    try std.testing.expectEqualStrings("count", @TypeOf(Weird.count).name);
    try std.testing.expect(@TypeOf(Weird.count).fieldType == i64);
    try std.testing.expectEqualStrings("len", @TypeOf(Weird.len).name);
    try std.testing.expectEqualStrings("select", @TypeOf(Weird.select).name);
    try std.testing.expectEqualStrings("where", @TypeOf(Weird.where).name);
    try std.testing.expectEqualStrings("join", @TypeOf(Weird.join).name);
    try std.testing.expectEqualStrings("limit", @TypeOf(Weird.limit).name);
    try std.testing.expectEqualStrings("offset", @TypeOf(Weird.offset).name);
    try std.testing.expectEqualStrings("orderBy", @TypeOf(Weird.orderBy).name);
    try std.testing.expectEqualStrings("groupBy", @TypeOf(Weird.groupBy).name);
    try std.testing.expectEqualStrings("having", @TypeOf(Weird.having).name);
    try std.testing.expectEqualStrings("insert", @TypeOf(Weird.insert).name);
    try std.testing.expectEqualStrings("update", @TypeOf(Weird.update).name);
    try std.testing.expectEqualStrings("delete", @TypeOf(Weird.delete).name);
    try std.testing.expectEqualStrings("returning", @TypeOf(Weird.returning).name);
    try std.testing.expectEqual(@as(usize, 16), columnCount(@TypeOf(Weird)));
    try std.testing.expectEqualStrings("weird", @TypeOf(Weird.limit).table);
    // Column expression methods still work on them: operations are methods
    // on the column value, so there is nothing to collide with.
    const pred = Weird.where.eq("x");
    try std.testing.expectEqualStrings("where", pred.column.name);
    try std.testing.expect(pred.operator == .equal);
    const ord = Weird.limit.desc();
    try std.testing.expect(ord.descending);
    try std.testing.expectEqualStrings("limit", ord.column.name);
    const total = Weird.count.sum();
    try std.testing.expectEqualStrings("SUM", total.function);
    // Aliases rebind even colliding columns without losing their identity.
    const w = aliased(Weird, "w");
    try std.testing.expect(isTableValue(@TypeOf(w)));
    try std.testing.expectEqualStrings("w", @TypeOf(w.all).table);
    try std.testing.expectEqualStrings("all", @TypeOf(w.all).name);
    try std.testing.expectEqualStrings("where", @TypeOf(w.where).name);
}

test "column order is declaration order and all() stays last" {
    const User = table("users", struct { c: i64, a: []const u8, b: f64 });
    // columnNames (and hence native projection order for selectAll) follows
    // declaration order, not alphabetical order.
    try std.testing.expectEqualStrings("c", User.columnNames[0]);
    try std.testing.expectEqualStrings("a", User.columnNames[1]);
    try std.testing.expectEqualStrings("b", User.columnNames[2]);
    try std.testing.expectEqual(@as(usize, 3), columnCount(@TypeOf(User)));
    // AllColumns marker is distinct from any column value, including a column
    // literally named `all` on another table.
    try std.testing.expect(isAllProjectionType(@TypeOf(User.all())));
    const Weird = table("weird", struct { all: []const u8, id: i64 });
    try std.testing.expect(@TypeOf(Weird.all).fieldType == []const u8);
    try std.testing.expectEqualStrings("all", Weird.columnNames[0]);
    try std.testing.expectEqualStrings("id", Weird.columnNames[1]);
}
