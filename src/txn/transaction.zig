const std = @import("std");
const Connection = @import("../connection/connection.zig").Connection;

pub const Transaction = struct {
    connection: *Connection,
    active: bool = true,

    pub fn begin(connection: *Connection) !Transaction {
        try connection.begin();
        return .{ .connection = connection };
    }
    pub fn commit(self: *Transaction) !void {
        try self.connection.commit();
        self.active = false;
    }
    pub fn rollback(self: *Transaction) !void {
        try self.connection.rollback();
        self.active = false;
    }
};

test "transaction wrapper commits a connection transaction" {
    const path = "sqlite_zig_txn_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    var transaction = try Transaction.begin(db);
    try transaction.commit();
}
