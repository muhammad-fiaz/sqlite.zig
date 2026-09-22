//! NOT IN anti-subquery filtering in raw and typed form.
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("not_in_users", struct { id: i64 });
const Blocked = sqlite.table("not_in_blocked", struct { user_id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_43.db");
    defer db.close();
    try db.createTable(User, .{ .overWrite = true });
    try db.createTable(Blocked, .{ .overWrite = true });
    try db.truncate(User);
    try db.truncate(Blocked);
    var a = try db.from(User).insert(.{ .id = 1 });
    a.deinit();
    var b = try db.from(User).insert(.{ .id = 2 });
    b.deinit();
    var blocked = try db.from(Blocked).insert(.{ .user_id = 2 });
    blocked.deinit();
    var rows = try db.from(User).whereNotInQuery(User.id, Blocked, Blocked.user_id).fetch();
    defer rows.deinit();
    if (rows.count() != 1 or rows.at(0).id != 1) return error.NotInVerificationFailed;
    std.debug.print("43 NOT IN: raw-compatible anti-subquery DSL verified\n", .{});
}
