const std = @import("std");
const sqlite = @import("sqlite");

const UserRow = struct { id: i64, name: []const u8, active: i64 };
const User = sqlite.table("view_users", UserRow);
const ActiveUser = sqlite.table("active_users", struct { id: i64, name: []const u8, active: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_22.db");
    defer db.close();
    try db.createTable(User, .{ .if_not_exists = true, .primary_key = User.key("id") });
    try db.truncate(User);
    db.dropView("active_users") catch {};
    var first = try db.from(User).insertTyped(.{ .id = 1, .name = "Alice", .active = 1 });
    first.deinit();
    var second = try db.from(User).insertTyped(.{ .id = 2, .name = "Bob", .active = 0 });
    second.deinit();
    var create = try db.exec("CREATE VIEW active_users AS SELECT id, name, active FROM view_users WHERE active = 1;");
    create.deinit();

    var typed = try db.from(ActiveUser).selectAll().fetchAll();
    defer typed.deinit();
    if (typed.rowCount() != 1 or typed.rows[0][0].integer != 1) return error.ViewVerificationFailed;
    var raw = try db.exec("SELECT * FROM active_users;");
    defer raw.deinit();
    if (raw.rowCount() != typed.rowCount()) return error.ViewInteropVerificationFailed;
    var reopened = try sqlite.open(std.heap.page_allocator, "valid_22.db");
    defer reopened.close();
    var persisted = try reopened.from(ActiveUser).selectAll().fetchAll();
    defer persisted.deinit();
    if (persisted.rowCount() != 1) return error.ViewPersistenceVerificationFailed;
    std.debug.print("22 views: raw and typed view reads verified\n", .{});
}
