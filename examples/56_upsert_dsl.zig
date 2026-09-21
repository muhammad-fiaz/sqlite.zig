const std = @import("std");
const sqlite = @import("sqlite");

const Account = sqlite.table("upsert_accounts", struct { id: i64, email: []const u8, name: []const u8, stock: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_56.db");
    const t_db_upsert_accounts = db.table("upsert_accounts");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS upsert_accounts; CREATE TABLE upsert_accounts (id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, name TEXT NOT NULL, stock INTEGER NOT NULL);");
    setup.deinit();
    try db.schema(Account).validate();

    var rawUpsert = try db.exec("INSERT INTO upsert_accounts VALUES (1, 'a@x.test', 'Ann', 5) ON CONFLICT(email) DO UPDATE SET name = excluded.name, stock = excluded.stock;");
    rawUpsert.deinit();
    var rawSeen = try db.exec("SELECT name, stock FROM upsert_accounts WHERE id = 1;");
    defer rawSeen.deinit();
    if (!std.mem.eql(u8, rawSeen.at(0)[0].text, "Ann")) return error.VerificationFailed;
    if (rawSeen.at(0)[1].integer != 5) return error.VerificationFailed;

    var typedUpBase = try db.from(Account).onConflict(Account.email).doUpdate(.{ .name = db.excluded("name"), .stock = db.excluded("stock") });
    var typedUp = try typedUpBase.insert(.{ .id = 2, .email = "a@x.test", .name = "Annie", .stock = 8 });
    typedUp.deinit();
    var checkTyped = try db.exec("SELECT id, name, stock FROM upsert_accounts ORDER BY id;");
    defer checkTyped.deinit();
    if (checkTyped.count() != 1) return error.VerificationFailed;
    if (checkTyped.at(0)[0].integer != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, checkTyped.at(0)[1].text, "Annie")) return error.VerificationFailed;
    if (checkTyped.at(0)[2].integer != 8) return error.VerificationFailed;

    var dynBase = try t_db_upsert_accounts.onConflict(t_db_upsert_accounts.column("email")).doUpdate(.{ .stock = 42 });
    var dynUp = try dynBase.insert(.{ .id = 3, .email = "a@x.test", .name = "Kept", .stock = 0 });
    dynUp.deinit();
    var checkDyn = try db.exec("SELECT name, stock FROM upsert_accounts WHERE email = 'a@x.test';");
    defer checkDyn.deinit();
    if (!std.mem.eql(u8, checkDyn.at(0)[0].text, "Annie")) return error.VerificationFailed;
    if (checkDyn.at(0)[1].integer != 42) return error.VerificationFailed;

    var skipped = try db.from(Account).onConflict(Account.email).doNothing().insert(.{ .id = 4, .email = "a@x.test", .name = "Nope", .stock = 0 });
    skipped.deinit();
    var checkSkipped = try db.exec("SELECT count(*) FROM upsert_accounts;");
    defer checkSkipped.deinit();
    if (checkSkipped.at(0)[0].integer != 1) return error.VerificationFailed;

    var guardedBase = try db.from(Account).onConflict(Account.email).doUpdate(.{ .stock = 99 });
    var guardedUp = guardedBase.where(db.excluded("stock").gt(100));
    var guarded = try guardedUp.insert(.{ .id = 5, .email = "a@x.test", .name = "Annie", .stock = 8 });
    guarded.deinit();
    var checkGuarded = try db.exec("SELECT stock FROM upsert_accounts WHERE email = 'a@x.test';");
    defer checkGuarded.deinit();
    if (checkGuarded.at(0)[0].integer != 42) return error.VerificationFailed;

    var retBase = try db.from(Account).onConflict(Account.email).doUpdate(.{ .stock = db.excluded("stock") });
    var retWithCols = retBase.returning(.{Account.stock});
    var retUp = try retWithCols.insert(.{ .id = 6, .email = "a@x.test", .name = "Annie", .stock = 55 });
    defer retUp.deinit();
    if (retUp.count() != 1) return error.VerificationFailed;
    if (retUp.at(0)[0].integer != 55) return error.VerificationFailed;

    if (db.from(Account).onConflict(Account.email).insert(.{ .id = 7, .email = "a@x.test", .name = "No", .stock = 0 })) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |err| {
        if (err != error.InvalidSql) return error.VerificationFailed;
    }
    var afterInvalid = try db.exec("SELECT count(*) FROM upsert_accounts;");
    defer afterInvalid.deinit();
    if (afterInvalid.at(0)[0].integer != 1) return error.VerificationFailed;

    {
        var check = try db.exec("SELECT email, stock FROM upsert_accounts;");
        defer check.deinit();
        if (check.at(0)[1].integer != 55) return error.VerificationFailed;
    }
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_56.db");
    defer reopened.close();
    var persisted = try reopened.exec("SELECT email, stock FROM upsert_accounts;");
    defer persisted.deinit();
    if (persisted.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, persisted.at(0)[0].text, "a@x.test")) return error.VerificationFailed;
    if (persisted.at(0)[1].integer != 55) return error.VerificationFailed;
    std.debug.print("56 upsert dsl: conflict targets and excluded values verified with persistence\n", .{});
}
