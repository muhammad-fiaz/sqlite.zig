const std = @import("std");
const sqlite = @import("sqlite");

const Users = sqlite.table("exists_users", struct { id: i64 });
const Marker = sqlite.table("exists_marker", struct { id: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_44.db");
    defer db.close();
    db.dropTable(Users) catch {};
    db.dropTable(Marker) catch {};
    var result = try db.exec("CREATE TABLE exists_users (id INTEGER); CREATE TABLE exists_marker (id INTEGER);");
    result.deinit();
    result = try db.exec("INSERT INTO exists_users VALUES (1), (2); INSERT INTO exists_marker VALUES (1);");
    result.deinit();
    var present = try db.exec("SELECT id FROM exists_users WHERE EXISTS (SELECT id FROM exists_marker) ORDER BY id;");
    defer present.deinit();
    if (present.rowCount() != 2) return error.ExistsVerificationFailed;
    var correlated = try db.exec("SELECT id FROM exists_users WHERE EXISTS (SELECT id FROM exists_marker WHERE exists_marker.id = exists_users.id) ORDER BY id;");
    defer correlated.deinit();
    if (correlated.rowCount() != 1 or correlated.rows[0][0].integer != 1) return error.CorrelatedExistsVerificationFailed;
    var typed = try db.from(Users).whereExistsKey(Marker, Marker.key("id"), Users.key("id")).fetchAll();
    defer typed.deinit();
    if (typed.rowCount() != 1 or typed.rows[0][0].integer != 1) return error.TypedExistsVerificationFailed;
    result = try db.exec("DELETE FROM exists_marker;");
    result.deinit();
    var absent = try db.exec("SELECT id FROM exists_users WHERE NOT EXISTS (SELECT id FROM exists_marker) ORDER BY id;");
    defer absent.deinit();
    if (absent.rowCount() != 2) return error.NotExistsVerificationFailed;
    std.debug.print("44 EXISTS: raw EXISTS and NOT EXISTS verified\n", .{});
}
