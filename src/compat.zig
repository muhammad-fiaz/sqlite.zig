const std = @import("std");

pub const Field = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,
    is_comptime: bool,
};

// Preserve the old field view while using the Zig 0.17 reflection arrays.
pub fn fields(comptime info: std.builtin.Type.Struct) [info.field_names.len]Field {
    @setEvalBranchQuota(100000);
    var result: [info.field_names.len]Field = undefined;
    for (info.field_names, info.field_types, info.field_attrs, 0..) |name, T, attrs, i| {
        result[i] = .{ .name = name, .type = T, .default_value_ptr = attrs.default_value_ptr, .is_comptime = attrs.@"comptime" };
    }
    return result;
}
