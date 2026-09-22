//! ON DELETE CASCADE verified through typed DSL reads.
const std = @import("std");
const sqlite = @import("sqlite");

const ParentRow = struct { id: i64, name: []const u8 };
const ChildRow = struct { id: i64, parent_id: i64 };
const Parent = sqlite.table("cascade_parents", ParentRow);
const Child = sqlite.table("cascade_children", ChildRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_26.db");
    defer db.close();
    try db.createTable(Parent, .{ .overWrite = true, .primaryKey = Parent.id });
    try db.createTable(Child, .{ .overWrite = true, .primaryKey = Child.id, .foreignKeys = &.{.{ .column = Child.parent_id, .references = Parent.id, .onDelete = .cascade }} });
    try db.truncate(Child);
    try db.truncate(Parent);
    var parent = try db.from(Parent).insert(.{ .id = 1, .name = "parent" });
    parent.deinit();
    var child = try db.from(Child).insert(.{ .id = 1, .parent_id = 1 });
    child.deinit();
    var deleted = db.from(Parent).delete().where(Parent.id.eq(1));
    var result = try deleted.execute();
    result.deinit();
    var remaining = try db.from(Child).selectAll().fetch();
    defer remaining.deinit();
    if (remaining.count() != 0) return error.CascadeVerificationFailed;
    std.debug.print("26 foreign keys: typed CASCADE delete verified\n", .{});
}
