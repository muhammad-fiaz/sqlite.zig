//! Composite PRIMARY KEY and UNIQUE table constraints.
const std = @import("std");
const sqlite = @import("sqlite");

const MembershipRow = struct { user_id: i64, group_id: i64, label: []const u8 };
const Membership = sqlite.table("typed_composite_memberships", MembershipRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_30.db");
    defer db.close();

    var rawSetup = try db.exec("CREATE TABLE IF NOT EXISTS raw_composite_items (left_id INTEGER, right_id INTEGER, label TEXT, PRIMARY KEY (left_id, right_id), UNIQUE (right_id, label));");
    rawSetup.deinit();
    var rawClear = try db.exec("DELETE FROM raw_composite_items;");
    rawClear.deinit();
    var rawInsert = try db.exec("INSERT INTO raw_composite_items VALUES (1, 10, 'alpha');");
    rawInsert.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.exec("INSERT INTO raw_composite_items VALUES (1, 10, 'duplicate');"));

    try db.createTable(Membership, .{ .overWrite = true, .primaryKey = &.{ Membership.user_id, Membership.group_id }, .unique = &.{&.{ Membership.group_id, Membership.label }} });
    try db.truncate(Membership);
    var typed = try db.from(Membership).insert(.{ .user_id = 1, .group_id = 10, .label = "alpha" });
    typed.deinit();
    try std.testing.expectError(error.ConstraintViolation, db.from(Membership).insert(.{ .user_id = 1, .group_id = 10, .label = "duplicate" }));
    std.debug.print("30 composite constraints: raw and typed PRIMARY KEY/UNIQUE verified\n", .{});
}
