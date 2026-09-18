const std = @import("std");
const dslExpr = @import("expr.zig");
const Expr = dslExpr.Expr;
const Order = dslExpr.Order;
const Projection = dslExpr.Projection;
const ColumnRef = dslExpr.ColumnRef;
const FuncCall = dslExpr.FuncCall;
const Operator = dslExpr.Operator;
const Value = @import("../vm/value.zig").Value;

pub fn column(comptime name: []const u8, comptime FieldType: type) Column("", name, FieldType) {
    return .{};
}

pub fn toValue(value: anytype) Value {
    const T = @TypeOf(value);
    if (T == Value) return value;
    if (@typeInfo(T) == .optional) {
        if (value) |present| return toValue(present);
        return .null;
    }
    return switch (@typeInfo(T)) {
        .bool => .{ .integer = if (value) 1 else 0 },
        .int, .comptime_int => .{ .integer = @intCast(value) },
        .float, .comptime_float => .{ .real = @floatCast(value) },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return .{ .text = value };
            if (ptr.size == .one) {
                const child = @typeInfo(ptr.child);
                if (child == .array and child.array.child == u8) return .{ .text = value };
            }
            @compileError("unsupported DSL value type");
        },
        .null => .null,
        else => @compileError("unsupported DSL value type"),
    };
}

pub fn splitRef(name: []const u8) ColumnRef {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        return .{ .table = name[0..dot], .name = name[dot + 1 ..] };
    }
    return .{ .name = name };
}

fn isTypedColumn(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    return @hasDecl(T, "isDslColumn") and T.isDslColumn;
}

fn rhsFrom(value: anytype) dslExpr.Rhs {
    const T = @TypeOf(value);
    if (T == DynamicColumn) return .{ .column = splitRef(value.name) };
    if (comptime isTypedColumn(T)) return .{ .column = .{ .table = T.dslTable, .name = T.dslName } };
    return .{ .value = toValue(value) };
}

fn orderFromRef(ref: ColumnRef, func: ?FuncCall, descending: bool) Order {
    return .{ .column = ref, .descending = descending, .function = func };
}

pub fn Column(comptime tableName: []const u8, comptime columnName: []const u8, comptime FieldType: type) type {
    return struct {
        const Self = @This();
        pub const isDslColumn = true;
        pub const dslTable = tableName;
        pub const dslName = columnName;
        pub const table = tableName;
        pub const name = columnName;
        pub const fieldType = FieldType;

        func: ?FuncCall = null,

        fn ref(self: Self) ColumnRef {
            _ = self;
            return .{ .table = tableName, .name = columnName };
        }

        fn pred(self: Self, op: Operator, value: anytype) Expr {
            return .{ .column = self.ref(), .operator = op, .rhs = rhsFrom(value), .function = self.func };
        }

        pub fn eq(self: Self, value: anytype) Expr {
            return self.pred(.equal, value);
        }
        pub fn ne(self: Self, value: anytype) Expr {
            return self.pred(.notEqual, value);
        }
        pub fn lt(self: Self, value: anytype) Expr {
            return self.pred(.less, value);
        }
        pub fn lte(self: Self, value: anytype) Expr {
            return self.pred(.lessEqual, value);
        }
        pub fn gt(self: Self, value: anytype) Expr {
            return self.pred(.greater, value);
        }
        pub fn gte(self: Self, value: anytype) Expr {
            return self.pred(.greaterEqual, value);
        }
        pub fn like(self: Self, value: anytype) Expr {
            return self.pred(.like, value);
        }
        pub fn notLike(self: Self, value: anytype) Expr {
            return self.pred(.notLike, value);
        }
        pub fn likeEscape(self: Self, value: anytype, escape: anytype) Expr {
            var expr = self.pred(.like, value);
            expr.escape = toValue(escape);
            return expr;
        }
        pub fn notLikeEscape(self: Self, value: anytype, escape: anytype) Expr {
            var expr = self.pred(.notLike, value);
            expr.escape = toValue(escape);
            return expr;
        }
        pub fn glob(self: Self, value: anytype) Expr {
            return self.pred(.glob, value);
        }
        pub fn notGlob(self: Self, value: anytype) Expr {
            return self.pred(.notGlob, value);
        }
        pub fn regexp(self: Self, value: anytype) Expr {
            return self.pred(.regexp, value);
        }
        pub fn notRegexp(self: Self, value: anytype) Expr {
            return self.pred(.notRegexp, value);
        }
        pub fn matchPattern(self: Self, value: anytype) Expr {
            return self.pred(.match, value);
        }
        pub fn match(self: Self, value: anytype) Expr {
            return self.pred(.match, value);
        }
        pub fn notMatch(self: Self, value: anytype) Expr {
            return self.pred(.notMatch, value);
        }
        pub fn collate(self: Self, comptime collation: []const u8, value: anytype) Expr {
            var expr = self.pred(.equal, value);
            expr.collate = collation;
            return expr;
        }
        pub fn is(self: Self, value: anytype) Expr {
            return self.pred(.isValue, value);
        }
        pub fn isNot(self: Self, value: anytype) Expr {
            return self.pred(.isNotValue, value);
        }
        pub fn isDistinctFrom(self: Self, value: anytype) Expr {
            return self.pred(.isDistinct, value);
        }
        pub fn isNotDistinctFrom(self: Self, value: anytype) Expr {
            return self.pred(.isNotDistinct, value);
        }
        pub fn isNull(self: Self) Expr {
            return .{ .column = self.ref(), .operator = .isNull, .function = self.func };
        }
        pub fn isNotNull(self: Self) Expr {
            return .{ .column = self.ref(), .operator = .isNotNull, .function = self.func };
        }
        pub fn between(self: Self, lo: anytype, hi: anytype) Expr {
            return .{ .column = self.ref(), .operator = .between, .rhs = rhsFrom(lo), .rhs2 = rhsFrom(hi), .function = self.func };
        }
        pub fn notBetween(self: Self, lo: anytype, hi: anytype) Expr {
            return .{ .column = self.ref(), .operator = .notBetween, .rhs = rhsFrom(lo), .rhs2 = rhsFrom(hi), .function = self.func };
        }

        pub fn asc(self: Self) Order {
            return orderFromRef(self.ref(), self.func, false);
        }
        pub fn desc(self: Self) Order {
            return orderFromRef(self.ref(), self.func, true);
        }

        pub fn sum(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "SUM" };
        }
        pub fn avg(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "AVG" };
        }
        pub fn min(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "MIN" };
        }
        pub fn max(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "MAX" };
        }
        pub fn count(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "COUNT" };
        }
        pub fn countDistinct(self: Self) Projection {
            return .{ .kind = .aggregate, .column = self.ref(), .function = "COUNT", .distinct = true };
        }

        fn wrap(self: Self, call: FuncCall) Self {
            var copy = self;
            copy.func = call;
            return copy;
        }
        pub fn lower(self: Self) Self {
            return self.wrap(.{ .name = "LOWER" });
        }
        pub fn upper(self: Self) Self {
            return self.wrap(.{ .name = "UPPER" });
        }
        pub fn trim(self: Self) Self {
            return self.wrap(.{ .name = "TRIM" });
        }
        pub fn ltrim(self: Self) Self {
            return self.wrap(.{ .name = "LTRIM" });
        }
        pub fn rtrim(self: Self) Self {
            return self.wrap(.{ .name = "RTRIM" });
        }
        pub fn length(self: Self) Self {
            return self.wrap(.{ .name = "LENGTH" });
        }
        pub fn abs(self: Self) Self {
            return self.wrap(.{ .name = "ABS" });
        }
        pub fn typeOf(self: Self) Self {
            return self.wrap(.{ .name = "TYPEOF" });
        }
        pub fn round(self: Self, precision: anytype) Self {
            return self.wrap(.{ .name = "ROUND", .argument = toValue(precision), .hasArgument = true });
        }
        pub fn coalesce(self: Self, fallback: anytype) Self {
            return self.wrap(.{ .name = "COALESCE", .argument = toValue(fallback), .hasArgument = true });
        }
        pub fn ifNull(self: Self, fallback: anytype) Self {
            return self.wrap(.{ .name = "IFNULL", .argument = toValue(fallback), .hasArgument = true });
        }
        pub fn instr(self: Self, needle: anytype) Self {
            return self.wrap(.{ .name = "INSTR", .argument = toValue(needle), .hasArgument = true });
        }
        pub fn substr(self: Self, start: anytype, len: anytype) Self {
            return self.wrap(.{ .name = "SUBSTR", .argument = toValue(start), .argument2 = toValue(len), .hasArgument = true, .hasArgument2 = true });
        }
        pub fn replace(self: Self, search: anytype, replacement: anytype) Self {
            return self.wrap(.{ .name = "REPLACE", .argument = toValue(search), .argument2 = toValue(replacement), .hasArgument = true, .hasArgument2 = true });
        }
        pub fn cast(self: Self, comptime target: []const u8) Self {
            return self.wrap(.{ .name = "CAST", .argument = .{ .text = target }, .hasArgument = true });
        }
        pub fn hex(self: Self) Self {
            return self.wrap(.{ .name = "HEX" });
        }
        pub fn quote(self: Self) Self {
            return self.wrap(.{ .name = "QUOTE" });
        }
        pub fn unicode(self: Self) Self {
            return self.wrap(.{ .name = "UNICODE" });
        }
        pub fn char(self: Self, extra: anytype) Self {
            return self.wrap(.{ .name = "CHAR", .argument = toValue(extra), .hasArgument = true });
        }
        pub fn printf(self: Self, arg: anytype) Self {
            return self.wrap(.{ .name = "PRINTF", .argument = toValue(arg), .hasArgument = true });
        }
        pub fn jsonExtract(self: Self, path: anytype) Self {
            return self.wrap(.{ .name = "json_extract", .argument = toValue(path), .hasArgument = true });
        }
        pub fn jsonSet(self: Self, path: anytype, value: anytype) Self {
            return self.wrap(.{ .name = "json_set", .argument = toValue(path), .argument2 = toValue(value), .hasArgument = true, .hasArgument2 = true });
        }

        pub fn projection(self: Self) Projection {
            if (self.func) |call| {
                return .{
                    .kind = .scalar,
                    .column = self.ref(),
                    .function = call.name,
                    .argument = call.argument,
                    .argument2 = call.argument2,
                    .hasArgument = call.hasArgument,
                    .hasArgument2 = call.hasArgument2,
                };
            }
            return .{ .kind = .column, .column = self.ref() };
        }
    };
}

pub const DynamicColumn = struct {
    name: []const u8,
    func: ?FuncCall = null,

    fn ref(self: @This()) ColumnRef {
        return splitRef(self.name);
    }

    fn pred(self: @This(), op: Operator, value: anytype) Expr {
        const T = @TypeOf(value);
        const rhs: dslExpr.Rhs = if (T == DynamicColumn)
            .{ .column = splitRef(value.name) }
        else if (comptime isTypedColumn(T))
            .{ .column = .{ .table = T.dslTable, .name = T.dslName } }
        else
            .{ .value = toValue(value) };
        return .{ .column = self.ref(), .operator = op, .rhs = rhs, .function = self.func };
    }

    pub fn eq(self: @This(), value: anytype) Expr {
        return self.pred(.equal, value);
    }
    pub fn ne(self: @This(), value: anytype) Expr {
        return self.pred(.notEqual, value);
    }
    pub fn lt(self: @This(), value: anytype) Expr {
        return self.pred(.less, value);
    }
    pub fn lte(self: @This(), value: anytype) Expr {
        return self.pred(.lessEqual, value);
    }
    pub fn gt(self: @This(), value: anytype) Expr {
        return self.pred(.greater, value);
    }
    pub fn gte(self: @This(), value: anytype) Expr {
        return self.pred(.greaterEqual, value);
    }
    pub fn like(self: @This(), value: anytype) Expr {
        return self.pred(.like, value);
    }
    pub fn notLike(self: @This(), value: anytype) Expr {
        return self.pred(.notLike, value);
    }
    pub fn likeEscape(self: @This(), value: anytype, escape: anytype) Expr {
        var expr = self.pred(.like, value);
        expr.escape = toValue(escape);
        return expr;
    }
    pub fn notLikeEscape(self: @This(), value: anytype, escape: anytype) Expr {
        var expr = self.pred(.notLike, value);
        expr.escape = toValue(escape);
        return expr;
    }
    pub fn glob(self: @This(), value: anytype) Expr {
        return self.pred(.glob, value);
    }
    pub fn notGlob(self: @This(), value: anytype) Expr {
        return self.pred(.notGlob, value);
    }
    pub fn regexp(self: @This(), value: anytype) Expr {
        return self.pred(.regexp, value);
    }
    pub fn notRegexp(self: @This(), value: anytype) Expr {
        return self.pred(.notRegexp, value);
    }
    pub fn matchPattern(self: @This(), value: anytype) Expr {
        return self.pred(.match, value);
    }
    pub fn match(self: @This(), value: anytype) Expr {
        return self.pred(.match, value);
    }
    pub fn notMatch(self: @This(), value: anytype) Expr {
        return self.pred(.notMatch, value);
    }
    pub fn collate(self: @This(), comptime collationName: []const u8, value: anytype) Expr {
        var expr = self.pred(.equal, value);
        expr.collate = collationName;
        return expr;
    }
    pub fn is(self: @This(), value: anytype) Expr {
        return self.pred(.isValue, value);
    }
    pub fn isNot(self: @This(), value: anytype) Expr {
        return self.pred(.isNotValue, value);
    }
    pub fn isDistinctFrom(self: @This(), value: anytype) Expr {
        return self.pred(.isDistinct, value);
    }
    pub fn isNotDistinctFrom(self: @This(), value: anytype) Expr {
        return self.pred(.isNotDistinct, value);
    }
    pub fn isNull(self: @This()) Expr {
        return .{ .column = self.ref(), .operator = .isNull, .function = self.func };
    }
    pub fn isNotNull(self: @This()) Expr {
        return .{ .column = self.ref(), .operator = .isNotNull, .function = self.func };
    }
    pub fn between(self: @This(), lo: anytype, hi: anytype) Expr {
        return .{
            .column = self.ref(),
            .operator = .between,
            .rhs = rhsFrom(lo),
            .rhs2 = rhsFrom(hi),
            .function = self.func,
        };
    }
    pub fn notBetween(self: @This(), lo: anytype, hi: anytype) Expr {
        return .{
            .column = self.ref(),
            .operator = .notBetween,
            .rhs = rhsFrom(lo),
            .rhs2 = rhsFrom(hi),
            .function = self.func,
        };
    }

    pub fn asc(self: @This()) Order {
        return orderFromRef(self.ref(), self.func, false);
    }
    pub fn desc(self: @This()) Order {
        return orderFromRef(self.ref(), self.func, true);
    }

    pub fn sum(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "SUM" };
    }
    pub fn avg(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "AVG" };
    }
    pub fn min(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "MIN" };
    }
    pub fn max(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "MAX" };
    }
    pub fn count(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "COUNT" };
    }
    pub fn countDistinct(self: @This()) Projection {
        return .{ .kind = .aggregate, .column = self.ref(), .function = "COUNT", .distinct = true };
    }

    fn wrap(self: @This(), call: FuncCall) @This() {
        var copy = self;
        copy.func = call;
        return copy;
    }
    pub fn lower(self: @This()) @This() {
        return self.wrap(.{ .name = "LOWER" });
    }
    pub fn upper(self: @This()) @This() {
        return self.wrap(.{ .name = "UPPER" });
    }
    pub fn trim(self: @This()) @This() {
        return self.wrap(.{ .name = "TRIM" });
    }
    pub fn ltrim(self: @This()) @This() {
        return self.wrap(.{ .name = "LTRIM" });
    }
    pub fn rtrim(self: @This()) @This() {
        return self.wrap(.{ .name = "RTRIM" });
    }
    pub fn length(self: @This()) @This() {
        return self.wrap(.{ .name = "LENGTH" });
    }
    pub fn abs(self: @This()) @This() {
        return self.wrap(.{ .name = "ABS" });
    }
    pub fn typeOf(self: @This()) @This() {
        return self.wrap(.{ .name = "TYPEOF" });
    }
    pub fn round(self: @This(), precision: anytype) @This() {
        return self.wrap(.{ .name = "ROUND", .argument = toValue(precision), .hasArgument = true });
    }
    pub fn coalesce(self: @This(), fallback: anytype) @This() {
        return self.wrap(.{ .name = "COALESCE", .argument = toValue(fallback), .hasArgument = true });
    }
    pub fn ifNull(self: @This(), fallback: anytype) @This() {
        return self.wrap(.{ .name = "IFNULL", .argument = toValue(fallback), .hasArgument = true });
    }
    pub fn instr(self: @This(), needle: anytype) @This() {
        return self.wrap(.{ .name = "INSTR", .argument = toValue(needle), .hasArgument = true });
    }
    pub fn substr(self: @This(), start: anytype, len: anytype) @This() {
        return self.wrap(.{ .name = "SUBSTR", .argument = toValue(start), .argument2 = toValue(len), .hasArgument = true, .hasArgument2 = true });
    }
    pub fn replace(self: @This(), search: anytype, replacement: anytype) @This() {
        return self.wrap(.{ .name = "REPLACE", .argument = toValue(search), .argument2 = toValue(replacement), .hasArgument = true, .hasArgument2 = true });
    }
    pub fn cast(self: @This(), target: []const u8) @This() {
        return self.wrap(.{ .name = "CAST", .argument = .{ .text = target }, .hasArgument = true });
    }
    pub fn hex(self: @This()) @This() {
        return self.wrap(.{ .name = "HEX" });
    }
    pub fn quote(self: @This()) @This() {
        return self.wrap(.{ .name = "QUOTE" });
    }
    pub fn unicode(self: @This()) @This() {
        return self.wrap(.{ .name = "UNICODE" });
    }
    pub fn char(self: @This(), extra: anytype) @This() {
        return self.wrap(.{ .name = "CHAR", .argument = toValue(extra), .hasArgument = true });
    }
    pub fn printf(self: @This(), arg: anytype) @This() {
        return self.wrap(.{ .name = "PRINTF", .argument = toValue(arg), .hasArgument = true });
    }
    pub fn jsonExtract(self: @This(), path: anytype) @This() {
        return self.wrap(.{ .name = "json_extract", .argument = toValue(path), .hasArgument = true });
    }
    pub fn jsonSet(self: @This(), path: anytype, value: anytype) @This() {
        return self.wrap(.{ .name = "json_set", .argument = toValue(path), .argument2 = toValue(value), .hasArgument = true, .hasArgument2 = true });
    }

    pub fn projection(self: @This()) Projection {
        if (self.func) |call| {
            return .{
                .kind = .scalar,
                .column = self.ref(),
                .function = call.name,
                .argument = call.argument,
                .argument2 = call.argument2,
                .hasArgument = call.hasArgument,
                .hasArgument2 = call.hasArgument2,
            };
        }
        return .{ .kind = .column, .column = self.ref() };
    }
};

test "typed predicates carry table identity and bound values" {
    const Age = Column("users", "age", i64);
    const age = Age{};
    const pred = age.gte(18);
    try std.testing.expectEqualStrings("users", pred.column.table);
    try std.testing.expectEqualStrings("age", pred.column.name);
    try std.testing.expect(pred.operator == .greaterEqual);
    try std.testing.expect(pred.rhs.value.integer == 18);
    const Name = Column("users", "name", []const u8);
    const like = (Name{}).like("A%");
    try std.testing.expect(like.operator == .like);
    try std.testing.expectEqualStrings("A%", like.rhs.value.text);
    const nullPred = (Name{}).isNull();
    try std.testing.expect(nullPred.operator == .isNull);
    const range = age.between(1, 9);
    try std.testing.expect(range.operator == .between);
    try std.testing.expect(range.rhs.value.integer == 1);
    try std.testing.expect(range.rhs2.?.value.integer == 9);
}

test "typed predicates compare columns without string lookup" {
    const Uid = Column("users", "id", i64);
    const Oid = Column("orders", "user_id", i64);
    const join = (Uid{}).eq(Oid{});
    try std.testing.expectEqualStrings("users", join.column.table);
    try std.testing.expectEqualStrings("orders", join.rhs.column.table);
    try std.testing.expectEqualStrings("user_id", join.rhs.column.name);
}

test "typed columns build orders aggregates and wrappers" {
    const Age = Column("users", "age", i64);
    const age = Age{};
    const asc = age.asc();
    try std.testing.expect(!asc.descending);
    try std.testing.expectEqualStrings("age", asc.column.name);
    try std.testing.expect(age.desc().descending);
    const total = age.sum();
    try std.testing.expect(total.kind == .aggregate);
    try std.testing.expectEqualStrings("SUM", total.function);
    try std.testing.expectEqualStrings("users", total.column.table);
    const lowered = (Column("users", "name", []const u8){}).lower();
    const lp = lowered.projection();
    try std.testing.expect(lp.kind == .scalar);
    try std.testing.expectEqualStrings("LOWER", lp.function);
    const plain = age.projection();
    try std.testing.expect(plain.kind == .column);
}

test "dynamic predicates mirror typed predicates at runtime" {
    const age = DynamicColumn{ .name = "users.age" };
    const pred = age.gte(18);
    try std.testing.expectEqualStrings("users", pred.column.table);
    try std.testing.expectEqualStrings("age", pred.column.name);
    try std.testing.expect(pred.rhs.value.integer == 18);
    const cross = (DynamicColumn{ .name = "a" }).eq(DynamicColumn{ .name = "b.c" });
    try std.testing.expectEqualStrings("b", cross.rhs.column.table);
    try std.testing.expectEqualStrings("c", cross.rhs.column.name);
    try std.testing.expectEqualStrings("age", splitRef("age").name);
    try std.testing.expect(splitRef("age").table.len == 0);
    const missing = (DynamicColumn{ .name = "x" }).isNotNull();
    try std.testing.expect(missing.operator == .isNotNull);
}
