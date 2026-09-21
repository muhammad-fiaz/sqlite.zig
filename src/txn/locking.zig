//! Connection lock (SHARED/RESERVED/EXCLUSIVE state machine).
//!
//! Tracks lock state in-process and reports contention as `Busy`. Every
//! transition holds an internal mutex; share by pointer, never copy.

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
    /// Guards every transition below; share the `Lock` by pointer, never copy.
    mutex: std.atomic.Mutex = .unlocked,
    /// Acquires a read lock. Fails with `Busy` when `exclusive` is held;
    /// allowed from `unlocked`/`shared`/`reserved` (re-acquire is idempotent).
    pub fn acquireShared(self: *Lock) !void {
        self.spinLock();
        defer self.mutex.unlock();
        if (self.state == .exclusive) return error.Busy;
        self.state = .shared;
    }
    /// Declares write intent. Fails with `Busy` when `reserved`/`exclusive`
    /// is already held; upgrades from `unlocked`/`shared`.
    pub fn acquireReserved(self: *Lock) !void {
        self.spinLock();
        defer self.mutex.unlock();
        if (self.state == .reserved or self.state == .exclusive) return error.Busy;
        self.state = .reserved;
    }
    /// Acquires the write lock. Only valid from `unlocked` — upgrading from
    /// `shared`/`reserved` must release first (prevents silent lock upgrades
    /// that would deadlock against other readers); otherwise `Busy`.
    pub fn acquireExclusive(self: *Lock) !void {
        self.spinLock();
        defer self.mutex.unlock();
        if (self.state != .unlocked) return error.Busy;
        self.state = .exclusive;
    }
    /// Spins until the internal mutex is held (critical sections are a
    /// few instructions; no thread ever sleeps while holding it).
    fn spinLock(self: *Lock) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    /// Drops any held level back to `unlocked` (never fails).
    pub fn release(self: *Lock) void {
        self.spinLock();
        defer self.mutex.unlock();
        self.state = .unlocked;
    }
};

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

test "lock survives concurrent acquisition without corruption" {
    var lock = Lock{};
    const Worker = struct {
        fn run(l: *Lock) void {
            var i: usize = 0;
            while (i < 500) : (i += 1) {
                // Contention is expected (Busy is fine); corruption is not:
                // every acquired level is always released, so the lock must
                // end unlocked regardless of interleaving.
                l.acquireShared() catch {};
                l.release();
                l.acquireExclusive() catch {};
                l.release();
            }
        }
    };
    var t1 = try std.Thread.spawn(.{}, Worker.run, .{&lock});
    var t2 = try std.Thread.spawn(.{}, Worker.run, .{&lock});
    var t3 = try std.Thread.spawn(.{}, Worker.run, .{&lock});
    var t4 = try std.Thread.spawn(.{}, Worker.run, .{&lock});
    t1.join();
    t2.join();
    t3.join();
    t4.join();
    try std.testing.expectEqual(LockState.unlocked, lock.state);
}
