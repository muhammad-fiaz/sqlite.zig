const std = @import("std");
const sqlite = @import("sqlite");

const Order = sqlite.table("dd_orders", struct { id: i64, user_id: i64, amount: i64 });
const User = sqlite.table("dd_users", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_63.db");
    const t_db_dd_orders = db.table("dd_orders");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS dd_orders; DROP TABLE IF EXISTS dd_users; CREATE TABLE dd_orders (id INTEGER NOT NULL PRIMARY KEY, user_id INTEGER NOT NULL, amount INTEGER NOT NULL); CREATE TABLE dd_users (id INTEGER NOT NULL PRIMARY KEY, name TEXT NOT NULL); INSERT INTO dd_orders VALUES (1, 7, 50), (2, 7, 150), (3, 8, 200), (4, 8, 30), (5, 7, 120); INSERT INTO dd_users VALUES (7, 'seven'), (8, 'eight');");
    setup.deinit();
    try db.schema(Order).validate();
    try db.schema(User).validate();
    var rawBig = try db.exec("SELECT user_id FROM (SELECT user_id FROM dd_orders WHERE amount > 100) AS big ORDER BY user_id;");
    defer rawBig.deinit();
    if (rawBig.count() != 3) return error.VerificationFailed;
    var big = try t_db_dd_orders.select(.{t_db_dd_orders.column("user_id")}).where(t_db_dd_orders.column("amount").gt(100)).asSubquery("big");
    var dynBig = try big.select(.{big.column("user_id")}).orderBy(big.column("user_id").asc()).fetch();
    defer dynBig.deinit();
    if (dynBig.count() != rawBig.count()) return error.VerificationFailed;
    for (rawBig.rows, 0..) |row, i| {
        if (dynBig.at(i)[0].integer != row[0].integer) return error.VerificationFailed;
    }
    var typedSub = try db.from(Order).select(.{Order.user_id}).where(Order.amount.gt(100)).asSubquery("o");
    var typedOut = try typedSub.select(.{typedSub.column("user_id")}).orderBy(typedSub.column("user_id").asc()).fetch();
    defer typedOut.deinit();
    if (typedOut.count() != 3) return error.VerificationFailed;
    if (typedOut.at(0)[0].integer != 7) return error.VerificationFailed;
    const t_db_dd_users = db.table("dd_users");
    const bigUserId = sqlite.DynamicColumn{ .name = "user_id", .table = "big" };
    var dynJoin = try big.select(.{big.column("name")}).innerJoin(t_db_dd_users, bigUserId.eq(t_db_dd_users.column("id"))).orderBy(t_db_dd_users.column("name").asc()).fetch();
    defer dynJoin.deinit();
    if (dynJoin.count() != 3) return error.VerificationFailed;
    if (!std.mem.eql(u8, dynJoin.at(0)[0].text, "eight")) return error.VerificationFailed;
    var dynCount = try big.countStar().fetch();
    defer dynCount.deinit();
    if (dynCount.at(0)[0].integer != 3) return error.VerificationFailed;
    var nested = try t_db_dd_orders.select(.{t_db_dd_orders.column("id")}).asSubquery("a");
    if (nested.asSubquery("b")) |_| {
        return error.VerificationFailed;
    } else |err| {
        if (err != error.InvalidSql) return error.VerificationFailed;
    }
    if (t_db_dd_orders.asSubquery("")) |_| {
        return error.VerificationFailed;
    } else |err| {
        if (err != error.InvalidSql) return error.VerificationFailed;
    }
    var inserted = try db.from(Order).insert(.{ .id = 6, .user_id = 8, .amount = 500 });
    inserted.deinit();
    var afterInsert = try db.exec("SELECT count(*) FROM (SELECT user_id FROM dd_orders WHERE amount > 100) AS big;");
    defer afterInsert.deinit();
    if (afterInsert.at(0)[0].integer != 4) return error.VerificationFailed;
    var dynAfter = try big.select(.{big.column("user_id")}).fetch();
    defer dynAfter.deinit();
    if (dynAfter.count() != 4) return error.VerificationFailed;
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_63.db");
    const t_reopened_dd_orders = reopened.table("dd_orders");
    defer reopened.close();
    var persisted = try t_reopened_dd_orders.select(.{t_reopened_dd_orders.column("user_id")}).where(t_reopened_dd_orders.column("amount").gt(100)).asSubquery("big");
    var persistedOut = try persisted.select(.{persisted.column("user_id")}).orderBy(persisted.column("user_id").asc()).fetch();
    defer persistedOut.deinit();
    if (persistedOut.count() != 4) return error.VerificationFailed;
    if (persistedOut.at(0)[0].integer != 7) return error.VerificationFailed;
    std.debug.print("63 derived dsl: raw dynamic typed verified with persistence\n", .{});
}
