const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_54.db");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS orders; DROP TABLE IF EXISTS customers; DROP TABLE IF EXISTS big_orders; CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, region TEXT); CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total INTEGER); INSERT INTO customers VALUES (1, 'Ada', 'north'), (2, 'Bob', 'south'), (3, 'Cy', 'north'); INSERT INTO orders VALUES (10, 1, 120), (11, 1, 80), (12, 2, 200), (13, 9, 50);");
    setup.deinit();

    var aliased = try db.exec("SELECT id, name FROM (SELECT id, name FROM customers WHERE region = 'north') AS northern ORDER BY id;");
    defer aliased.deinit();
    if (aliased.count() != 2) return error.VerificationFailed;
    if (aliased.rows[0][0].integer != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, aliased.rows[1][1].text, "Cy")) return error.VerificationFailed;

    var bare = try db.exec("SELECT count(*) FROM (SELECT id FROM orders);");
    defer bare.deinit();
    if (bare.rows[0][0].integer != 4) return error.VerificationFailed;

    var totals = try db.exec("SELECT name, spent FROM (SELECT customer_id AS id, SUM(total) AS spent FROM orders GROUP BY customer_id) AS sums JOIN customers ON sums.id = customers.id ORDER BY spent DESC;");
    defer totals.deinit();
    if (totals.count() != 2) return error.VerificationFailed;
    if (!std.mem.eql(u8, totals.rows[0][0].text, "Ada")) return error.VerificationFailed;
    if (totals.rows[0][1].integer != 200) return error.VerificationFailed;
    if (!std.mem.eql(u8, totals.rows[1][0].text, "Bob")) return error.VerificationFailed;

    var nested = try db.exec("SELECT id FROM (SELECT id FROM (SELECT id FROM orders WHERE total >= 100) AS big WHERE id < 12) AS small ORDER BY id;");
    defer nested.deinit();
    if (nested.count() != 1) return error.VerificationFailed;
    if (nested.rows[0][0].integer != 10) return error.VerificationFailed;

    var copied = try db.exec("CREATE TABLE big_orders (id INTEGER, total INTEGER); INSERT INTO big_orders SELECT id, total FROM (SELECT id, total FROM orders WHERE total >= 100) ORDER BY id;");
    copied.deinit();
    var checkCopy = try db.exec("SELECT count(*), SUM(total) FROM big_orders;");
    defer checkCopy.deinit();
    if (checkCopy.rows[0][0].integer != 2) return error.VerificationFailed;
    if (checkCopy.rows[0][1].integer != 320) return error.VerificationFailed;

    var shadowed = try db.exec("SELECT id FROM (SELECT 99 AS id) AS customers;");
    defer shadowed.deinit();
    if (shadowed.count() != 1) return error.VerificationFailed;
    if (shadowed.rows[0][0].integer != 99) return error.VerificationFailed;
    var intact = try db.exec("SELECT count(*) FROM customers;");
    defer intact.deinit();
    if (intact.rows[0][0].integer != 3) return error.VerificationFailed;

    if (db.exec("SELECT nope FROM (SELECT id FROM customers) AS sub;")) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |err| {
        if (err != error.UnknownColumn) return error.VerificationFailed;
    }
    var afterError = try db.exec("SELECT count(*) FROM customers;");
    defer afterError.deinit();
    if (afterError.rows[0][0].integer != 3) return error.VerificationFailed;

    var dslInserted = try db.from("customers").insert(.{ .id = 4, .name = "Dee", .region = "south" });
    dslInserted.deinit();
    var derivedSeesDsl = try db.exec("SELECT count(*) FROM (SELECT id FROM customers WHERE region = 'south');");
    defer derivedSeesDsl.deinit();
    if (derivedSeesDsl.rows[0][0].integer != 2) return error.VerificationFailed;

    var typedSeen = try db.exec("SELECT name FROM customers WHERE id = 4;");
    defer typedSeen.deinit();
    if (typedSeen.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, typedSeen.rows[0][0].text, "Dee")) return error.VerificationFailed;

    {
        var check = try db.exec("SELECT count(*) FROM customers;");
        defer check.deinit();
        if (check.rows[0][0].integer != 4) return error.VerificationFailed;
    }
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_54.db");
    defer reopened.close();
    var persisted = try reopened.exec("SELECT SUM(total) FROM (SELECT total FROM orders WHERE total >= 100);");
    defer persisted.deinit();
    if (persisted.rows[0][0].integer != 320) return error.VerificationFailed;
    var persistedBase = try reopened.exec("SELECT count(*) FROM customers;");
    defer persistedBase.deinit();
    if (persistedBase.rows[0][0].integer != 4) return error.VerificationFailed;
    std.debug.print("54 derived tables: subqueries in FROM verified with persistence\n", .{});
}
