//! RAII-style transaction guard over a `Connection`.
//!
//! Purpose: begin a transaction on construction and commit/rollback it
//! exactly once through the guard. Responsibilities: forward to
//! `Connection.begin/commit/rollback` and track completion. Dependencies:
//! `connection/connection.zig`, `std` (tests). Ownership/lifetime: borrows
//! the connection (must outlive the guard); no allocation. Error behavior:
//! double `commit`/`rollback` returns `NotInTransaction` without touching the
//! connection; `Connection` errors (`TransactionActive`, I/O) propagate.
//! Invariants: at most one terminal call succeeds; `active` is false after.
//! Compatibility: maps onto the connection's snapshot-based transactions —
//! there is no automatic rollback on drop (see TODO): leaking a guard
//! without `commit`/`rollback` leaves the connection's transaction open.

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
};
// TODO: add rollback-on-drop (or explicit close) for Transaction. Current limitation: dropping an active guard without commit/rollback leaves the connection transaction open with no compiler warning. Expected behavior: deinit that rolls back an active transaction, or a must-consume annotation. Tests needed: scope-exit test asserting the connection is no longer in a transaction after drop.

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
    defer outer.rollback() catch {};
    try std.testing.expectError(error.TransactionActive, Transaction.begin(db));
}
