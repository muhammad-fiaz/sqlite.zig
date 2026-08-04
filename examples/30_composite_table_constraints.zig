const std = @import("std");
const sqlite = @import("sqlite");

const MembershipRow = struct { user_id: i64, group_id: i64, label: []const u8 };
const Membership = sqlite.table("typed_composite_memberships", MembershipRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_30.db");
    defer db.close();

    var raw_setup = try db.exec("CREATE TABLE IF NOT EXISTS raw_composite_items (left_id INTEGER, right_id INTEGER, label TEXT, PRIMARY KEY (left_id, right_id), UNIQUE (right_id, label));");
    raw_setup.deinit();
    var raw_clear = try db.exec("DELETE FROM raw_composite_items;");
    raw_clear.deinit();
    var raw_insert = try db.exec("INSERT INTO raw_composite_items VALUES (1, 10, 'alpha');");
    raw_insert.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO raw_composite_items VALUES (1, 10, 'duplicate');"));

    try db.createTable(Membership, .{ .if_not_exists = true, .primary_keys = &.{ Membership.key("user_id"), Membership.key("group_id") }, .unique_constraints = &.{&.{ Membership.key("group_id"), Membership.key("label") }} });
    try db.truncate(Membership);
    var typed = try db.from(Membership).insertTyped(.{ .user_id = 1, .group_id = 10, .label = "alpha" });
    typed.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Membership).insertTyped(.{ .user_id = 1, .group_id = 10, .label = "duplicate" }));
    std.debug.print("30 composite constraints: raw and typed PRIMARY KEY/UNIQUE verified\n", .{});
}
