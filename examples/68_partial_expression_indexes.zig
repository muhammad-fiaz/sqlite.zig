const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("pix_users", struct { id: i64, email: []const u8, active: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_68.db");
    const t_db_pix_users = db.table("pix_users");
    errdefer db.close();
    try db.createTable(User, .{ .overWrite = true, .primaryKey = User.id });
    try db.createIndexWhere(User, "pix_active_id", .{User.id}, false, "active = 1");
    try db.createIndexExpr(User, "pix_lower_email", &.{"lower(email)"}, false, null);
    try db.createIndexExpr(User, "pix_active_email", &.{"lower(email)"}, true, "active = 1");
    var seed = try db.exec("INSERT INTO pix_users VALUES (1, 'Ada@x.test', 1), (2, 'ada@y.test', 0), (3, 'Bo@x.test', 1);");
    seed.deinit();
    try db.schema(User).validate();
    // Partial UNIQUE index: duplicate active emails rejected, inactive duplicates allowed.
    if (db.exec("INSERT INTO pix_users VALUES (4, 'ADA@X.TEST', 1);")) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    var inactiveDup = try db.exec("INSERT INTO pix_users VALUES (4, 'ADA@Y.TEST', 0);");
    inactiveDup.deinit();
    var raw = try db.exec("SELECT id FROM pix_users WHERE active = 1 ORDER BY id;");
    defer raw.deinit();
    if (raw.count() != 2) return error.VerificationFailed;
    var dyn = try t_db_pix_users.select(.{t_db_pix_users.column("id")}).where(t_db_pix_users.column("active").eq(1)).orderBy(t_db_pix_users.column("id").asc()).fetch();
    defer dyn.deinit();
    if (dyn.count() != raw.count()) return error.VerificationFailed;
    var typed = try db.from(User).select(.{User.id}).where(User.active.eq(1)).orderBy(User.id.asc()).fetch();
    defer typed.deinit();
    if (typed.count() != raw.count()) return error.VerificationFailed;
    // Expression index serves case-insensitive lookup identically in each layer.
    var rawLower = try db.exec("SELECT id FROM pix_users WHERE lower(email) = lower('ADA@X.TEST') ORDER BY id;");
    defer rawLower.deinit();
    if (rawLower.count() != 1) return error.VerificationFailed;
    var dynLower = try t_db_pix_users.select(.{t_db_pix_users.column("id")}).where(t_db_pix_users.column("email").lower().eq("ada@x.test")).orderBy(t_db_pix_users.column("id").asc()).fetch();
    defer dynLower.deinit();
    if (dynLower.count() != 1) return error.VerificationFailed;
    if (dynLower.at(0)[0].integer != 1) return error.VerificationFailed;
    var typedLower = try db.from(User).select(.{User.id}).where(User.email.lower().eq("ada@x.test")).fetch();
    defer typedLower.deinit();
    if (typedLower.count() != 1) return error.VerificationFailed;
    var plan = try db.exec("EXPLAIN QUERY PLAN SELECT id FROM pix_users WHERE active = 1;");
    defer plan.deinit();
    if (plan.count() == 0) return error.VerificationFailed;
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_68.db");
    const t_reopened_pix_users = reopened.table("pix_users");
    defer reopened.close();
    var persisted = try reopened.exec("SELECT count(*) FROM pix_users;");
    defer persisted.deinit();
    if (persisted.at(0)[0].integer != 4) return error.VerificationFailed;
    var persistedDyn = try t_reopened_pix_users.select(.{t_reopened_pix_users.column("id")}).where(t_reopened_pix_users.column("active").eq(1)).fetch();
    defer persistedDyn.deinit();
    if (persistedDyn.count() != 2) return error.VerificationFailed;
    std.debug.print("68 partial and expression indexes: raw dynamic typed verified with persistence\n", .{});
}
