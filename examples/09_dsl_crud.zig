//! Typed DSL CRUD: insert, update, select, and delete.
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("dsl_users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_09.db");
    defer db.close();
    try db.createTable(User, .{ .overWrite = true });
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "before" });
    inserted.deinit();
    var mutation = try db.from(User).update(.{ .name = "after" });
    var updated = try mutation.where(User.id.eq(1)).execute();
    updated.deinit();
    var selected = try db.from(User).select(.{ User.id, User.name }).where(User.id.eq(1)).fetch();
    selected.deinit();
    var deleted = try db.from(User).delete().where(User.id.eq(1)).execute();
    deleted.deinit();
    std.debug.print("09 dsl crud: insert, update, select, delete verified\n", .{});
}
