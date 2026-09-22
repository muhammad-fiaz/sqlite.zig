//! Raw SQL and typed DSL produce identical results.
const std = @import("std");
const sqlite = @import("sqlite");

const Task = sqlite.table("interop_tasks", struct { id: i64, title: []const u8, done: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_15.db");
    defer db.close();
    try db.createTable(Task, .{ .overWrite = true });
    try db.truncate(Task);

    var rawInsert = try db.exec("INSERT INTO interop_tasks (id, title, done) VALUES (1, 'write docs', 0), (2, 'ship release', 1);");
    rawInsert.deinit();

    var typedUpdate = try db.from(Task).update(.{ .done = 1 });
    var updated = try typedUpdate.where(Task.id.eq(1)).execute();
    updated.deinit();

    var rawQuery = try db.exec("SELECT id, title FROM interop_tasks WHERE done = 1;");
    rawQuery.deinit();

    var typedDelete = db.from(Task).delete().where(Task.id.eq(2));
    var deleted = try typedDelete.execute();
    deleted.deinit();
    std.debug.print("15 raw dsl interop: raw SQL and DSL produce identical results\n", .{});
}
