//! Process-local connection lock (SHARED/RESERVED/EXCLUSIVE state machine).
//!
//! Purpose: serialize readers and writers inside one process with SQLite's
//! lock vocabulary. This is a state tracker, not an OS lock: it grants or
//! refuses transitions and reports contention as `error.Busy`. Dependencies:
//! `std` (tests only). Ownership: `Lock` is a value — no allocation, no
//! lifetime, safe to embed in a connection struct. Error behavior:
//! conflicting acquisition returns `error.Busy` without changing state.
//! Invariants: exactly one of the four states holds; `release` always lands
//! on `unlocked`. Compatibility: state names mirror SQLite's locking model.
//! Safety note: no atomics/mutex — concurrent threads must externally
//! serialize access to a shared `Lock` (see TODO below).

const std = @import("std");

/// SQLite-style lock levels in upgrade order.
pub const LockState = enum {
    /// No lock held; any acquisition may proceed.
    unlocked,
    /// Read lock; blocks `exclusive`, allows `shared`/`reserved`.
    shared,
    /// Write intent; one holder, still allows new `shared` readers.
    reserved,
    /// Write lock; blocks everything until released.
    exclusive,
};

/// Single-holder lock state machine.
///
/// Why `reserved` exists separately: SQLite lets one writer stage changes
/// (reserved) while readers finish, then upgrade to exclusive for commit —
/// collapsing the two would force writers to block readers earlier.
pub const Lock = struct {
    /// Current level (starts `unlocked`).
    state: LockState = .unlocked,
    /// Acquires a read lock. Fails with `Busy` when `exclusive` is held;
    /// allowed from `unlocked`/`shared`/`reserved` (re-acquire is idempotent).
    pub fn acquireShared(self: *Lock) !void {
        if (self.state == .exclusive) return error.Busy;
        self.state = .shared;
    }
    /// Declares write intent. Fails with `Busy` when `reserved`/`exclusive`
    /// is already held; upgrades from `unlocked`/`shared`.
    pub fn acquireReserved(self: *Lock) !void {
        if (self.state == .reserved or self.state == .exclusive) return error.Busy;
        self.state = .reserved;
    }
    /// Acquires the write lock. Only valid from `unlocked` — upgrading from
    /// `shared`/`reserved` must release first (prevents silent lock upgrades
    /// that would deadlock against other readers); otherwise `Busy`.
    pub fn acquireExclusive(self: *Lock) !void {
        if (self.state != .unlocked) return error.Busy;
        self.state = .exclusive;
    }
    /// Drops any held level back to `unlocked` (never fails).
    pub fn release(self: *Lock) void {
        self.state = .unlocked;
    }
};
// TODO: make Lock thread-safe for shared connections. Current limitation: plain enum state with no mutex/atomic, so concurrent acquire/release from multiple threads races. Expected behavior: internal mutex or documented external-locking contract enforced by debug assertions. Tests needed: multi-thread acquisition stress test asserting no state corruption.

test "connection lock transitions are serialized" {
    var lock = Lock{};
    try lock.acquireShared();
    lock.release();
    try lock.acquireExclusive();
    lock.release();
}

test "connection lock contention fails closed without state change" {
    var lock = Lock{};
    // Error: exclusive is blocked by any held level; state is unchanged.
    try lock.acquireShared();
    try std.testing.expectError(error.Busy, lock.acquireExclusive());
    try std.testing.expectEqual(LockState.shared, lock.state);
    lock.release();
    // Error: double exclusive and shared-under-exclusive both refuse.
    try lock.acquireExclusive();
    try std.testing.expectError(error.Busy, lock.acquireExclusive());
    try std.testing.expectError(error.Busy, lock.acquireShared());
    try std.testing.expectEqual(LockState.exclusive, lock.state);
    lock.release();
    try std.testing.expectEqual(LockState.unlocked, lock.state);
    // Normal: reserved upgrades from shared, then releases cleanly.
    try lock.acquireShared();
    try lock.acquireReserved();
    try std.testing.expectEqual(LockState.reserved, lock.state);
    // Error: second reserved claim and exclusive-under-reserved refuse.
    try std.testing.expectError(error.Busy, lock.acquireReserved());
    try std.testing.expectError(error.Busy, lock.acquireExclusive());
    lock.release();
    // Normal: shared re-acquire is idempotent, release is total.
    try lock.acquireShared();
    try lock.acquireShared();
    lock.release();
    lock.release();
    try std.testing.expectEqual(LockState.unlocked, lock.state);
}
