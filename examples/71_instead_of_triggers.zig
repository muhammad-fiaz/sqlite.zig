//! INSTEAD OF triggers: writable views route inserts, updates, deletes.
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_71.db");
    errdefer db.close();
    var setup = try db.exec("DROP TRIGGER IF EXISTS it_customer_orders_ins; DROP TRIGGER IF EXISTS it_customer_orders_upd; DROP TRIGGER IF EXISTS it_customer_orders_del; DROP VIEW IF EXISTS it_customer_orders; DROP TABLE IF EXISTS it_users; DROP TABLE IF EXISTS it_orders; CREATE TABLE it_users (id INTEGER PRIMARY KEY, name TEXT); CREATE TABLE it_orders (id INTEGER PRIMARY KEY, user_id INTEGER, amount INTEGER); CREATE VIEW it_customer_orders AS SELECT u.name AS name, o.amount AS amount FROM it_users u JOIN it_orders o ON o.user_id = u.id;");
    setup.deinit();
    var makeIns = try db.exec("CREATE TRIGGER it_customer_orders_ins INSTEAD OF INSERT ON it_customer_orders BEGIN INSERT INTO it_users (name) VALUES (NEW.name); INSERT INTO it_orders (user_id, amount) VALUES (last_insert_rowid(), NEW.amount); END;");
    makeIns.deinit();
    var makeUpd = try db.exec("CREATE TRIGGER it_customer_orders_upd INSTEAD OF UPDATE OF amount ON it_customer_orders BEGIN UPDATE it_orders SET amount = NEW.amount WHERE user_id = (SELECT id FROM it_users WHERE name = OLD.name); END;");
    makeUpd.deinit();
    var makeDel = try db.exec("CREATE TRIGGER it_customer_orders_del INSTEAD OF DELETE ON it_customer_orders BEGIN DELETE FROM it_orders WHERE user_id = (SELECT id FROM it_users WHERE name = OLD.name); DELETE FROM it_users WHERE name = OLD.name; END;");
    makeDel.deinit();

    var inserted = try db.exec("INSERT INTO it_customer_orders VALUES ('Ada', 120), ('Bo', 30);");
    inserted.deinit();
    var updated = try db.exec("UPDATE it_customer_orders SET amount = 150 WHERE name = 'Ada';");
    updated.deinit();
    var deleted = try db.exec("DELETE FROM it_customer_orders WHERE name = 'Bo';");
    deleted.deinit();
    var check = try db.exec("SELECT name, amount FROM it_customer_orders ORDER BY name;");
    defer check.deinit();
    if (check.count() != 1) return error.VerificationFailed;
    if (!std.mem.eql(u8, check.at(0)[0].text, "Ada")) return error.VerificationFailed;
    if (check.at(0)[1].integer != 150) return error.VerificationFailed;
    db.close();
    std.debug.print("71 instead of triggers: view insert update delete verified\n", .{});
}
