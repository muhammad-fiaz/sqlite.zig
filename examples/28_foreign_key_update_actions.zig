const std = @import("std");
const sqlite = @import("sqlite");

const ParentRow = struct { id: i64, name: []const u8 };
const CascadeChildRow = struct { id: i64, parent_id: i64 };
const NullableChildRow = struct { id: i64, parent_id: i64 };
const RestrictedChildRow = struct { id: i64, parent_id: i64 };
const Parent = sqlite.table("update_parents", ParentRow);
const CascadeChild = sqlite.table("update_cascade_children", CascadeChildRow);
const NullableChild = sqlite.table("update_nullable_children", NullableChildRow);
const RestrictedChild = sqlite.table("update_restricted_children", RestrictedChildRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_28.db");
    defer db.close();
    try db.createTable(Parent, .{ .if_not_exists = true, .primary_key = Parent.key("id") });
    try db.createTable(CascadeChild, .{ .if_not_exists = true, .primary_key = CascadeChild.key("id"), .foreign_keys = &.{.{ .table = "update_parents", .referenced_column = "id", .column_key = CascadeChild.key("parent_id"), .on_update = .cascade }} });
    try db.createTable(NullableChild, .{ .if_not_exists = true, .primary_key = NullableChild.key("id"), .foreign_keys = &.{.{ .table = "update_parents", .referenced_column = "id", .column_key = NullableChild.key("parent_id"), .on_update = .set_null }} });
    try db.createTable(RestrictedChild, .{ .if_not_exists = true, .primary_key = RestrictedChild.key("id"), .foreign_keys = &.{.{ .table = "update_parents", .referenced_column = "id", .column_key = RestrictedChild.key("parent_id"), .on_update = .restrict }} });
    try db.truncate(RestrictedChild);
    try db.truncate(NullableChild);
    try db.truncate(CascadeChild);
    try db.truncate(Parent);

    var parent = try db.from(Parent).insertTyped(.{ .id = 1, .name = "parent" });
    parent.deinit();
    var cascade = try db.from(CascadeChild).insertTyped(.{ .id = 1, .parent_id = 1 });
    cascade.deinit();
    var nullable = try db.from(NullableChild).insertTyped(.{ .id = 1, .parent_id = 1 });
    nullable.deinit();
    var update = try db.from(Parent).update(.{ .id = 2 });
    var result = try update.where(Parent.column("id").eq(1)).execute();
    update.deinit();
    result.deinit();

    var child = try db.from(CascadeChild).selectAll().fetchAll();
    defer child.deinit();
    if (child.rows[0][1].integer != 2) return error.CascadeUpdateVerificationFailed;
    var cleared = try db.from(NullableChild).selectAll().fetchAll();
    defer cleared.deinit();
    if (cleared.rows[0][1] != .null) return error.SetNullUpdateVerificationFailed;

    var restricted_parent = try db.from(Parent).insertTyped(.{ .id = 3, .name = "restricted" });
    restricted_parent.deinit();
    var restricted_child = try db.from(RestrictedChild).insertTyped(.{ .id = 1, .parent_id = 3 });
    restricted_child.deinit();
    var blocked = try db.from(Parent).update(.{ .id = 4 });
    defer blocked.deinit();
    try std.testing.expectError(error.ConstraintViolation, blocked.where(Parent.column("id").eq(3)).execute());
    std.debug.print("28 foreign keys: ON UPDATE CASCADE, SET NULL, and RESTRICT verified\n", .{});
}
