const std = @import("std");

pub const LockState = enum { unlocked, shared, reserved, exclusive };
pub const Lock = struct {
    state: LockState = .unlocked,
    pub fn acquireShared(self: *Lock) !void {
        if (self.state == .exclusive) return error.Busy;
        self.state = .shared;
    }
    pub fn acquireExclusive(self: *Lock) !void {
        if (self.state != .unlocked) return error.Busy;
        self.state = .exclusive;
    }
    pub fn release(self: *Lock) void {
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
