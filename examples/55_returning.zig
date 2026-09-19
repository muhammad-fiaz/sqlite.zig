const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("returning_items", struct { id: i64, label: []const u8, stock: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_55.db");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS returning_items; CREATE TABLE returning_items (id INTEGER PRIMARY KEY, label TEXT NOT NULL, stock INTEGER NOT NULL);");
    setup.deinit();
    try db.schema(Item).validate();

    var rawInsert = try db.exec("INSERT INTO returning_items VALUES (1, 'alpha', 5) RETURNING id, label;");
    defer rawInsert.deinit();
    if (rawInsert.count() != 1) return error.VerificationFailed;
    if (rawInsert.rows[0][0].integer != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, rawInsert.rows[0][1].text, "alpha")) return error.VerificationFailed;

    var typedInsert = try db.from(Item).returning(.{ Item.columns.id, Item.columns.stock }).insert(.{ .id = 2, .label = "beta", .stock = 7 });
    defer typedInsert.deinit();
    if (typedInsert.count() != 1) return error.VerificationFailed;
    if (typedInsert.rows[0][0].integer != 2) return error.VerificationFailed;
    if (typedInsert.rows[0][1].integer != 7) return error.VerificationFailed;

    var dynInsert = try db.from("returning_items").returning(.{db.col("label").upper().projection()}).insert(.{ .id = 3, .label = "gamma", .stock = 1 });
    defer dynInsert.deinit();
    if (dynInsert.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, dynInsert.rows[0][0].text, "GAMMA")) return error.VerificationFailed;

    var rawSeen = try db.exec("SELECT count(*) FROM returning_items;");
    defer rawSeen.deinit();
    if (rawSeen.rows[0][0].integer != 3) return error.VerificationFailed;

    var ignored = try db.from(Item).returning(.{Item.columns.id}).insertOrIgnore(.{ .id = 2, .label = "dup", .stock = 9 });
    defer ignored.deinit();
    if (ignored.count() != 0) return error.VerificationFailed;

    var typedUpdate = try db.from(Item).update(.{ .stock = 11 });
    var updated = try typedUpdate.where(Item.columns.id.eq(2)).returning(.{ Item.columns.id, Item.columns.stock }).execute();
    defer updated.deinit();
    if (updated.count() != 1) return error.VerificationFailed;
    if (updated.rows[0][0].integer != 2) return error.VerificationFailed;
    if (updated.rows[0][1].integer != 11) return error.VerificationFailed;

    var rawUpdated = try db.exec("SELECT stock FROM returning_items WHERE id = 2;");
    defer rawUpdated.deinit();
    if (rawUpdated.rows[0][0].integer != 11) return error.VerificationFailed;

    var dynDelete = try db.from("returning_items").delete().where(db.col("id").eq(1)).returning(.{db.col("label")}).execute();
    defer dynDelete.deinit();
    if (dynDelete.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, dynDelete.rows[0][0].text, "alpha")) return error.VerificationFailed;

    var rawRemaining = try db.exec("SELECT id FROM returning_items ORDER BY id;");
    defer rawRemaining.deinit();
    if (rawRemaining.count() != 2) return error.VerificationFailed;
    if (rawRemaining.rows[0][0].integer != 2) return error.VerificationFailed;

    if (db.from(Item).returning(.{db.col("missing")}).insert(.{ .id = 9, .label = "bad", .stock = 1 })) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |err| {
        if (err != error.UnknownColumn) return error.VerificationFailed;
    }
    var afterBad = try db.exec("SELECT count(*) FROM returning_items;");
    defer afterBad.deinit();
    if (afterBad.rows[0][0].integer != 2) return error.VerificationFailed;

    {
        var check = try db.exec("SELECT id, stock FROM returning_items ORDER BY id;");
        defer check.deinit();
        if (check.rows[0][1].integer != 11) return error.VerificationFailed;
        if (check.rows[1][1].integer != 1) return error.VerificationFailed;
    }
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_55.db");
    defer reopened.close();
    var persisted = try reopened.exec("SELECT id, stock FROM returning_items ORDER BY id;");
    defer persisted.deinit();
    if (persisted.count() != 2) return error.VerificationFailed;
    if (persisted.rows[0][1].integer != 11) return error.VerificationFailed;
    if (persisted.rows[1][1].integer != 1) return error.VerificationFailed;
    std.debug.print("55 returning: insert, update, and delete returning verified with persistence\n", .{});
}
