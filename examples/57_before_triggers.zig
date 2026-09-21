const std = @import("std");
const sqlite = @import("sqlite");

const Item = sqlite.table("before_items", struct { id: i64, label: []const u8, stock: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_57.db");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS before_items; DROP TABLE IF EXISTS before_audit; CREATE TABLE before_items (id INTEGER PRIMARY KEY, label TEXT NOT NULL, stock INTEGER NOT NULL); CREATE TABLE before_audit (pos TEXT NOT NULL, id INTEGER NOT NULL, label TEXT); INSERT INTO before_items VALUES (1, 'alpha', 5);");
    setup.deinit();
    try db.schema(Item).validate();
    db.dropTrigger("trg_before_insert") catch {};
    db.dropTrigger("trg_after_insert") catch {};
    db.dropTrigger("trg_big_only") catch {};
    db.dropTrigger("trg_before_update") catch {};
    db.dropTrigger("trg_guard") catch {};

    var make = try db.exec("CREATE TRIGGER trg_before_insert BEFORE INSERT ON before_items BEGIN INSERT INTO before_audit VALUES ('before', NEW.id, NEW.label); END;");
    make.deinit();
    make = try db.exec("CREATE TRIGGER trg_after_insert AFTER INSERT ON before_items BEGIN INSERT INTO before_audit VALUES ('after', NEW.id, NEW.label); END;");
    make.deinit();
    make = try db.exec("CREATE TRIGGER trg_big_only BEFORE INSERT ON before_items WHEN NEW.stock > 100 BEGIN INSERT INTO before_audit VALUES ('big', NEW.id, NEW.label); END;");
    make.deinit();

    var small = try db.from(Item).insert(.{ .id = 2, .label = "beta", .stock = 7 });
    small.deinit();
    var big = try db.exec("INSERT INTO before_items VALUES (3, 'gamma', 500);");
    big.deinit();
    var audit = try db.exec("SELECT pos, id, label FROM before_audit;");
    defer audit.deinit();
    if (audit.count() != 5) return error.VerificationFailed;
    if (!std.mem.eql(u8, audit.at(0)[0].text, "before")) return error.VerificationFailed;
    if (!std.mem.eql(u8, audit.at(1)[0].text, "after")) return error.VerificationFailed;
    if (!std.mem.eql(u8, audit.at(2)[0].text, "before")) return error.VerificationFailed;
    if (!std.mem.eql(u8, audit.at(3)[0].text, "big")) return error.VerificationFailed;
    if (!std.mem.eql(u8, audit.at(4)[0].text, "after")) return error.VerificationFailed;
    if (audit.at(3)[1].integer != 3) return error.VerificationFailed;

    make = try db.exec("CREATE TRIGGER trg_before_update BEFORE UPDATE ON before_items WHEN NEW.stock > OLD.stock BEGIN INSERT INTO before_audit VALUES ('grew', NEW.id, NEW.label); END;");
    make.deinit();
    var grew = try db.exec("UPDATE before_items SET stock = 9 WHERE id = 2;");
    grew.deinit();
    var shrank = try db.exec("UPDATE before_items SET stock = 1 WHERE id = 2;");
    shrank.deinit();
    var grewAudit = try db.exec("SELECT id FROM before_audit WHERE pos = 'grew';");
    defer grewAudit.deinit();
    if (grewAudit.count() != 1) return error.VerificationFailed;
    if (grewAudit.at(0)[0].integer != 2) return error.VerificationFailed;

    make = try db.exec("CREATE TRIGGER trg_guard BEFORE INSERT ON before_items BEGIN INSERT INTO missing_audit_table VALUES (NEW.id); END;");
    make.deinit();
    if (db.exec("INSERT INTO before_items VALUES (4, 'delta', 1);")) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |err| {
        if (err != error.UnknownTable) return error.VerificationFailed;
    }
    var afterAbort = try db.exec("SELECT count(*) FROM before_items;");
    defer afterAbort.deinit();
    if (afterAbort.at(0)[0].integer != 3) return error.VerificationFailed;
    var dropGuard = try db.exec("DROP TRIGGER trg_guard;");
    dropGuard.deinit();

    {
        var check = try db.exec("SELECT count(*) FROM before_items;");
        defer check.deinit();
        if (check.at(0)[0].integer != 3) return error.VerificationFailed;
    }
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_57.db");
    defer reopened.close();
    var again = try reopened.exec("INSERT INTO before_items VALUES (5, 'epsilon', 300);");
    again.deinit();
    var persisted = try reopened.exec("SELECT pos FROM before_audit WHERE id = 5;");
    defer persisted.deinit();
    if (persisted.count() != 3) return error.VerificationFailed;
    if (!std.mem.eql(u8, persisted.at(0)[0].text, "before")) return error.VerificationFailed;
    if (!std.mem.eql(u8, persisted.at(1)[0].text, "big")) return error.VerificationFailed;
    if (!std.mem.eql(u8, persisted.at(2)[0].text, "after")) return error.VerificationFailed;
    std.debug.print("57 before triggers: timing, when filters, and persistence verified\n", .{});
}
