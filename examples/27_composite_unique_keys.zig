//! Multi-column UNIQUE index enforced via typed DSL.
const std = @import("std");
const sqlite = @import("sqlite");

const MembershipRow = struct { id: i64, user_id: i64, group_id: i64 };
const Membership = sqlite.table("composite_memberships", MembershipRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_27.db");
    defer db.close();
    try db.createTable(Membership, .{ .overWrite = true, .primaryKey = Membership.id });
    try db.truncate(Membership);
    db.dropIndex("membership_user_group") catch {};
    try db.createIndex(Membership, "membership_user_group", &.{ Membership.user_id, Membership.group_id }, true);

    var first = try db.from(Membership).insert(.{ .id = 1, .user_id = 10, .group_id = 20 });
    first.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Membership).insert(.{ .id = 2, .user_id = 10, .group_id = 20 }));
    var differentGroup = try db.from(Membership).insert(.{ .id = 3, .user_id = 10, .group_id = 21 });
    differentGroup.deinit();
    std.debug.print("27 composite keys: typed multi-column UNIQUE index verified\n", .{});
}
