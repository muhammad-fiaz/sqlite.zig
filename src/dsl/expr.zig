const Value = @import("../vm/value.zig").Value;

pub const Operator = enum { equal, not_equal, less, less_equal, greater, greater_equal };
pub const Expr = struct {
    column: []const u8,
    operator: Operator,
    value: Value,

    pub fn andExpr(self: Expr, other: Expr) Expr {
        _ = other;
        return self;
    }
};
