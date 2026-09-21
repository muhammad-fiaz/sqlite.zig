//! Transaction guard over a connection.
//!
//! Begins on construction, ends with exactly one of `commit`, `rollback`,
//! or `deinit` (which rolls back). Borrows the connection; double
//! completion fails `NotInTransaction`.

const std = @import("std");
const Connection = @import("../connection/connection.zig").Connection;

/// Borrowed guard for one connection transaction.
///
/// Why `active` is tracked here as well as in the connection: the guard can
/// cheaply reject double-commit/rollback locally instead of issuing a second
/// `persist()`/restore against the connection.
pub const Transaction = struct {
    /// Borrowed connection (must outlive the guard).
    connection: *Connection,
    /// True until the first successful `commit`/`rollback`.
    active: bool = true,

    /// Begins a connection transaction and wraps it (fails with
    /// `TransactionActive` when one is already open).
    pub fn begin(connection: *Connection) !Transaction {
        try connection.begin();
        return .{ .connection = connection };
    }
    /// Commits and disarms the guard. Fails with `NotInTransaction` when the
    /// guard already completed; a failed commit keeps `active` true so the
    /// caller can still roll back.
    pub fn commit(self: *Transaction) !void {
        if (!self.active) return error.NotInTransaction;
        try self.connection.commit();
        self.active = false;
    }
    /// Rolls back and disarms the guard. Same double-use rule as `commit`.
    pub fn rollback(self: *Transaction) !void {
        if (!self.active) return error.NotInTransaction;
        try self.connection.rollback();
        self.active = false;
    }

    /// Scope-exit safety: rolls back an still-active transaction and disarms
    /// the guard (rollback errors are swallowed — the connection stays
    /// consistent because rollback restores the pre-transaction snapshot).
    /// A committed/rolled-back guard is a no-op. Always pair `begin` with
    /// exactly one of `commit`, `rollback`, or `deinit`.
    pub fn deinit(self: *Transaction) void {
        if (!self.active) return;
        self.connection.rollback() catch {};
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

test "transaction guard rolls back and rejects double completion" {
    const path = "sqlite_zig_txn_guard_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    // Normal: rollback disarms the guard; reuse fails closed locally.
    var first = try Transaction.begin(db);
    try std.testing.expect(first.active);
    try first.rollback();
    try std.testing.expect(!first.active);
    try std.testing.expectError(error.NotInTransaction, first.rollback());
    try std.testing.expectError(error.NotInTransaction, first.commit());
    // Normal: commit path behaves the same.
    var second = try Transaction.begin(db);
    try second.commit();
    try std.testing.expectError(error.NotInTransaction, second.commit());
    // Error: nesting a second transaction while one is open is refused by
    // the connection layer (guard construction propagates it).
    var outer = try Transaction.begin(db);
    defer outer.deinit();
    try std.testing.expectError(error.TransactionActive, Transaction.begin(db));
}

test "transaction guard rolls back on scope exit" {
    const path = "sqlite_zig_txn_scope_test.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    var db = try Connection.open(std.testing.allocator, path);
    defer db.close();
    // Dropping an active guard (deinit without commit/rollback) rolls the
    // connection back: no transaction stays open, and the guard disarms.
    var leaked = try Transaction.begin(db);
    try std.testing.expect(db.transactionActive);
    leaked.deinit();
    try std.testing.expect(!leaked.active);
    try std.testing.expect(!db.transactionActive);
    // deinit after explicit completion is a safe no-op.
    var done = try Transaction.begin(db);
    try done.commit();
    done.deinit();
    try std.testing.expect(!db.transactionActive);
}
