const Value = @import("../vm/value.zig").Value;

pub const Operator = enum { equal, not_equal, less, less_equal, greater, greater_equal, like, is_null, is_not_null, between };
pub const Expr = struct {
    column: []const u8,
    operator: Operator,
    value: Value,
    value2: ?Value = null,

    pub fn andExpr(self: Expr, other: Expr) Expr {
        _ = other;
        return self;
    }
};
