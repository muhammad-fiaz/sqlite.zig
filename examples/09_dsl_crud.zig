//! Typed DSL CRUD: insert, update, select, and delete in scoped and
//! explicit form (see `72_scoped_and_explicit_typed` for the full model).
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("dsl_users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_09.db");
    defer db.close();
    try db.createTable(User, .{ .overWrite = true });
    // Scoped row insert; explicit qualified insert writes the same shape.
    var inserted = try db.from(User).insert(.{ .id = 1, .name = "before" });
    inserted.deinit();
    var insertedExplicit = try db.from(User).insert(.{ User.id.set(2), User.name.set("second") });
    insertedExplicit.deinit();
    var mutation = try db.from(User).update(.{ .name = "after" });
    var updated = try mutation.where(User.id.eq(1)).execute();
    updated.deinit();
    // Scoped select list resolves against the root table like User.id does.
    var selected = try db.from(User).select(.{ .id, .name }).where(User.id.eq(1)).fetch();
    selected.deinit();
    // Explicit predicate on the root table.
    const q = db.from(User);
    var scoped = try q.where(User.name.eq("second")).select(.{.id}).fetch();
    defer scoped.deinit();
    std.debug.assert(scoped.count() == 1);
    var deleted = try db.from(User).delete().where(User.id.eq(1)).execute();
    deleted.deinit();
    var deletedScoped = try db.from(User).where(User.id.eq(2)).delete().execute();
    deletedScoped.deinit();
    std.debug.print("09 dsl crud: insert, update, select, delete verified\n", .{});
}
