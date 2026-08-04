const std = @import("std");
const sqlite = @import("sqlite");

const ParentRow = struct { id: i64, name: []const u8 };
const ChildRow = struct { id: i64, parent_id: i64 };
const Parent = sqlite.table("cascade_parents", ParentRow);
const Child = sqlite.table("cascade_children", ChildRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_26.db");
    defer db.close();
    try db.createTable(Parent, .{ .if_not_exists = true, .primary_key = Parent.key("id") });
    try db.createTable(Child, .{ .if_not_exists = true, .primary_key = Child.key("id"), .foreign_keys = &.{.{ .table = "cascade_parents", .referenced_column = "id", .column_key = Child.key("parent_id"), .on_delete = .cascade }} });
    try db.truncate(Child);
    try db.truncate(Parent);
    var parent = try db.from(Parent).insertTyped(.{ .id = 1, .name = "parent" });
    parent.deinit();
    var child = try db.from(Child).insertTyped(.{ .id = 1, .parent_id = 1 });
    child.deinit();
    var deleted = db.from(Parent).delete().where(Parent.column("id").eq(1));
    var result = try deleted.execute();
    deleted.deinit();
    result.deinit();
    var remaining = try db.from(Child).selectAll().fetchAll();
    defer remaining.deinit();
    if (remaining.rowCount() != 0) return error.CascadeVerificationFailed;
    std.debug.print("26 foreign keys: typed CASCADE delete verified\n", .{});
}
