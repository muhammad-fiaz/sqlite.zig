const std = @import("std");
const Column = @import("column.zig").Column;

pub fn table(comptime name: []const u8, comptime spec: anytype) type {
    return tableWith(name, spec, .{});
}

pub fn tableWith(comptime name: []const u8, comptime spec: anytype, comptime opts: anytype) type {
    if (@TypeOf(spec) == type) {
        const info = @typeInfo(spec);
        if (info != .@"struct") @compileError("sqlite.table row must be a struct");
        const Cols = ColumnsType(name, spec);
        return TableDecl(name, spec, opts, Cols, info.@"struct".fields.len);
    }
    return tableFromDescriptors(name, spec, opts);
}

fn TableDecl(comptime name: []const u8, comptime Row: type, comptime opts: anytype, comptime Cols: type, comptime fieldCount: usize) type {
    return struct {
        pub const tableName = name;
        pub const rowType = Row;
        pub const tableOptions = opts;
        pub const columns: Cols = .{};

        pub fn columnNames() [fieldCount][]const u8 {
            var result: [fieldCount][]const u8 = undefined;
            inline for (@typeInfo(Row).@"struct".fields, 0..) |field, index| result[index] = field.name;
            return result;
        }
    };
}

fn isColumn(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "isDslColumn") and T.isDslColumn;
}

fn tableFromDescriptors(comptime tname: []const u8, comptime spec: anytype, comptime opts: anytype) type {
    const S = @TypeOf(spec);
    const sinfo = @typeInfo(S);
    if (sinfo != .@"struct" or sinfo.@"struct".is_tuple) @compileError("sqlite.table takes a struct type or column descriptors");
    const fields = sinfo.@"struct".fields;
    var zigNames: [fields.len][:0]const u8 = undefined;
    var fieldTypes: [fields.len]type = undefined;
    var colTypes: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index| {
        const VT = @TypeOf(@field(spec, field.name));
        if (comptime !isColumn(VT)) @compileError("table descriptor fields must be sqlite.column(...) values");
        const zbuf = field.name ++ [_]u8{0};
        zigNames[index] = zbuf[0..field.name.len :0];
        fieldTypes[index] = VT.fieldType;
        colTypes[index] = Column(tname, VT.dslName, VT.fieldType);
    }
    const zAttrs = nullAttrs(fields.len);
    const Row = @Struct(.auto, null, &zigNames, &fieldTypes, &zAttrs);
    const Cols = mappedColumns(zigNames, colTypes);
    return TableDecl(tname, Row, opts, Cols, fields.len);
}

fn nullAttrs(comptime n: usize) [n]std.builtin.Type.StructField.Attributes {
    var attrs: [n]std.builtin.Type.StructField.Attributes = undefined;
    inline for (0..n) |i| attrs[i] = .{};
    return attrs;
}

fn mappedColumns(comptime zigNames: anytype, comptime colTypes: anytype) type {
    const Defaults = @Tuple(&colTypes);
    var defaults: Defaults = undefined;
    inline for (colTypes, 0..) |_, index| defaults[index] = .{};
    const Attr = std.builtin.Type.StructField.Attributes;
    var attrs: [colTypes.len]Attr = undefined;
    inline for (colTypes, 0..) |_, index| attrs[index] = .{ .default_value_ptr = @ptrCast(&defaults[index]) };
    return @Struct(.auto, null, &zigNames, &colTypes, &attrs);
}

fn ColumnsType(comptime tname: []const u8, comptime Row: type) type {
    const fields = @typeInfo(Row).@"struct".fields;
    var names: [fields.len][:0]const u8 = undefined;
    var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index| {
        const buf = field.name ++ [_]u8{0};
        names[index] = buf[0..field.name.len :0];
        types[index] = Column(tname, field.name, field.type);
    }
    return mappedColumns(names, types);
}

test "typed table exposes columns as fields" {
    const User = table("users", struct { id: i64, name: []const u8 });
    try std.testing.expectEqualStrings("users", User.tableName);
    try std.testing.expectEqualStrings("id", @TypeOf(User.columns.id).name);
    try std.testing.expectEqualStrings("name", @TypeOf(User.columns.name).name);
    try std.testing.expectEqualStrings("users", @TypeOf(User.columns.id).table);
}

test "columns keep table identity across tables" {
    const User = table("t_users", struct { id: i64, name: []const u8 });
    const Order = table("t_orders", struct { id: i64, user_id: i64 });
    try std.testing.expectEqualStrings("t_users", @TypeOf(User.columns.id).table);
    try std.testing.expectEqualStrings("t_orders", @TypeOf(Order.columns.id).table);
    try std.testing.expect(!std.mem.eql(u8, @TypeOf(User.columns.id).table, @TypeOf(Order.columns.id).table));
    try std.testing.expect(@TypeOf(User.columns.id).fieldType == i64);
}

test "declared keys ride along for validation and creation" {
    const User = tableWith("users", struct { id: i64, email: []const u8 }, .{
        .primaryKey = "id",
        .unique = &.{"email"},
    });
    try std.testing.expect(@hasField(@TypeOf(User.tableOptions), "primaryKey"));
    try std.testing.expectEqualStrings("id", User.tableOptions.primaryKey);
    try std.testing.expect(User.columnNames().len == 2);
    try std.testing.expectEqualStrings("id", User.columnNames()[0]);
    try std.testing.expectEqualStrings("email", User.columnNames()[1]);
}

test "descriptors map zig names onto sql names" {
    const col = @import("column.zig").column;
    const User = table("users", .{
        .firstName = col("first_name", []const u8),
        .ageYears = col("age_years", i64),
    });
    try std.testing.expectEqualStrings("first_name", @TypeOf(User.columns.firstName).name);
    try std.testing.expectEqualStrings("users", @TypeOf(User.columns.firstName).table);
    try std.testing.expect(@TypeOf(User.columns.ageYears).fieldType == i64);
    try std.testing.expectEqualStrings("first_name", @TypeOf(User.columns.firstName).name);
    try std.testing.expectEqualStrings("age_years", @TypeOf(User.columns.ageYears).name);
    try std.testing.expectEqualStrings("firstName", User.columnNames()[0]);
    try std.testing.expectEqualStrings("ageYears", User.columnNames()[1]);
}
