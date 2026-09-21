const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_19.db");
    defer db.close();
    var setup = try db.exec("CREATE TABLE IF NOT EXISTS prepared_items (id INTEGER, label TEXT);");
    setup.deinit();
    var clear = try db.exec("DELETE FROM prepared_items;");
    clear.deinit();
    var statement = try db.prepare("INSERT INTO prepared_items (id, label) VALUES (?, ?);");
    try statement.bind(1, 7);
    try statement.bind(2, "bound value");
    try statement.step();
    statement.finalize();
    var result = try db.exec("SELECT id, label FROM prepared_items WHERE id = 7;");
    defer result.deinit();
    if (result.count() != 1 or result.at(0)[0].integer != 7 or !std.mem.eql(u8, result.at(0)[1].text, "bound value")) return error.PreparedValueVerificationFailed;
    std.debug.print("19 prepared parameters: prepared_items contains {d} verified row\n", .{result.count()});
}
