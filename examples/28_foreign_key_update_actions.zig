//! ON UPDATE CASCADE, SET NULL, and RESTRICT actions.
const std = @import("std");
const sqlite = @import("sqlite");

const ParentRow = struct { id: i64, name: []const u8 };
const CascadeChildRow = struct { id: i64, parent_id: i64 };
const NullableChildRow = struct { id: i64, parent_id: ?i64 };
const RestrictedChildRow = struct { id: i64, parent_id: i64 };
const Parent = sqlite.table("update_parents", ParentRow);
const CascadeChild = sqlite.table("update_cascade_children", CascadeChildRow);
const NullableChild = sqlite.table("update_nullable_children", NullableChildRow);
const RestrictedChild = sqlite.table("update_restricted_children", RestrictedChildRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_28.db");
    defer db.close();
    try db.createTable(Parent, .{ .overWrite = true, .primaryKey = Parent.id });
    try db.createTable(CascadeChild, .{ .overWrite = true, .primaryKey = CascadeChild.id, .foreignKeys = &.{.{ .column = CascadeChild.parent_id, .references = Parent.id, .onUpdate = .cascade }} });
    try db.createTable(NullableChild, .{ .overWrite = true, .primaryKey = NullableChild.id, .foreignKeys = &.{.{ .column = NullableChild.parent_id, .references = Parent.id, .onUpdate = .setNull }} });
    try db.createTable(RestrictedChild, .{ .overWrite = true, .primaryKey = RestrictedChild.id, .foreignKeys = &.{.{ .column = RestrictedChild.parent_id, .references = Parent.id, .onUpdate = .restrict }} });
    try db.truncate(RestrictedChild);
    try db.truncate(NullableChild);
    try db.truncate(CascadeChild);
    try db.truncate(Parent);

    var parent = try db.from(Parent).insert(.{ .id = 1, .name = "parent" });
    parent.deinit();
    var cascade = try db.from(CascadeChild).insert(.{ .id = 1, .parent_id = 1 });
    cascade.deinit();
    var nullable = try db.from(NullableChild).insert(.{ .id = 1, .parent_id = 1 });
    nullable.deinit();
    var update = try db.from(Parent).update(.{ .id = 2 });
    var result = try update.where(Parent.id.eq(1)).execute();
    result.deinit();

    var child = try db.from(CascadeChild).selectAll().fetch();
    defer child.deinit();
    if (child.at(0).parent_id != 2) return error.CascadeUpdateVerificationFailed;
    var cleared = try db.from(NullableChild).selectAll().fetch();
    defer cleared.deinit();
    if (cleared.at(0).parent_id != null) return error.SetNullUpdateVerificationFailed;

    var restrictedParent = try db.from(Parent).insert(.{ .id = 3, .name = "restricted" });
    restrictedParent.deinit();
    var restrictedChild = try db.from(RestrictedChild).insert(.{ .id = 1, .parent_id = 3 });
    restrictedChild.deinit();
    var blocked = try db.from(Parent).update(.{ .id = 4 });
    try std.testing.expectError(error.ConstraintViolation, blocked.where(Parent.id.eq(3)).execute());
    std.debug.print("28 foreign keys: ON UPDATE CASCADE, SET NULL, and RESTRICT verified\n", .{});
}
