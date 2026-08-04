const std = @import("std");
const sqlite = @import("sqlite");

const Account = sqlite.table("lifecycle_accounts", struct { id: i64, name: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_18.db");
    defer db.close();
    try db.createTable(Account, .{ .if_not_exists = true });
    if (!db.tableExists(Account)) return error.TableWasNotCreated;
    try db.addColumn(Account, "active", i64);
    try db.renameColumn(Account, "active", "enabled");
    try db.dropColumn(Account, "enabled");
    try db.truncate(Account);
    try db.renameTable(Account, "lifecycle_accounts_archive");
    try db.dropTable(sqlite.table("lifecycle_accounts_archive", struct { id: i64, name: []const u8 }));
    std.debug.print("18 schema lifecycle: create, alter, rename, truncate, and drop verified\n", .{});
}
