const std = @import("std");
const sqlite = @import("sqlite");

const TypedParent = sqlite.table("typed_fk_parents", struct { part_a: i64, part_b: i64, label: []const u8 });
const TypedChild = sqlite.table("typed_fk_children", struct { id: i64, parent_a: i64, parent_b: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_31.db");
    defer db.close();

    var setup = try db.exec("CREATE TABLE IF NOT EXISTS raw_fk_parents (part_a INTEGER, part_b INTEGER, label TEXT, PRIMARY KEY (part_a, part_b));");
    setup.deinit();
    setup = try db.exec("CREATE TABLE IF NOT EXISTS raw_fk_children (id INTEGER PRIMARY KEY, parent_a INTEGER, parent_b INTEGER, FOREIGN KEY (parent_a, parent_b) REFERENCES raw_fk_parents (part_a, part_b) ON UPDATE CASCADE ON DELETE CASCADE);");
    setup.deinit();
    var clear = try db.exec("DELETE FROM raw_fk_children;");
    clear.deinit();
    clear = try db.exec("DELETE FROM raw_fk_parents;");
    clear.deinit();
    var inserted = try db.exec("INSERT INTO raw_fk_parents VALUES (1, 10, 'raw');");
    inserted.deinit();
    inserted = try db.exec("INSERT INTO raw_fk_children VALUES (1, 1, 10);");
    inserted.deinit();
    var updated = try db.exec("UPDATE raw_fk_parents SET part_a = 2, part_b = 20 WHERE part_a = 1 AND part_b = 10;");
    updated.deinit();
    var raw_child = try db.exec("SELECT parent_a, parent_b FROM raw_fk_children;");
    defer raw_child.deinit();
    if (raw_child.rows[0][0].integer != 2 or raw_child.rows[0][1].integer != 20) return error.CompositeForeignKeyUpdateFailed;

    try db.createTable(TypedParent, .{ .if_not_exists = true, .primary_keys = &.{ TypedParent.key("part_a"), TypedParent.key("part_b") } });
    try db.createTable(TypedChild, .{ .if_not_exists = true, .foreign_key_constraints = &.{.{ .columns = &.{ TypedChild.key("parent_a"), TypedChild.key("parent_b") }, .referenced_columns = &.{ TypedParent.key("part_a"), TypedParent.key("part_b") }, .on_delete = .cascade, .on_update = .cascade }} });
    try db.truncate(TypedChild);
    try db.truncate(TypedParent);
    var parent = try db.from(TypedParent).insertTyped(.{ .part_a = 1, .part_b = 10, .label = "typed" });
    parent.deinit();
    var child = try db.from(TypedChild).insertTyped(.{ .id = 1, .parent_a = 1, .parent_b = 10 });
    child.deinit();
    var parent_update = try db.from(TypedParent).update(.{ .part_a = 2, .part_b = 20 });
    var result = try parent_update.where(TypedParent.column("part_a").eq(1)).execute();
    parent_update.deinit();
    result.deinit();
    var typed_child = try db.from(TypedChild).selectAll().fetchAll();
    defer typed_child.deinit();
    if (typed_child.rows[0][1].integer != 2 or typed_child.rows[0][2].integer != 20) return error.TypedCompositeForeignKeyUpdateFailed;
    std.debug.print("31 composite foreign keys: raw and typed cascading relationships verified\n", .{});
}
