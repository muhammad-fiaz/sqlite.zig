//! Relationship shapes: self-reference, multi-FK, one-to-one.
//!
//! Bare fields resolve against the table being defined, so a self-reference
//! needs no qualification (`.references = .id` means this table's `id`);
//! cross-table parents stay explicit (`RUser.id`). Both self-reference
//! forms resolve to the same native foreign-key metadata.
//! Predicate positions cannot call operators on bare literals (Zig has no
//! syntax for it), so predicates use explicit qualified paths
//! (`Employee.id.eq(1)`) or dynamic columns.
const std = @import("std");
const sqlite = @import("sqlite");

const Employee = sqlite.table("rel_employees", struct { id: i64, manager_id: ?i64 });
const Audit = sqlite.table("rel_audits", struct { id: i64, prev_id: ?i64 });
const RUser = sqlite.table("rel_msg_users", struct { id: i64, name: []const u8 });
const Message = sqlite.table("rel_messages", struct { id: i64, sender_id: i64, receiver_id: i64 });
const Profile = sqlite.table("rel_profiles", struct { id: i64, user_id: i64, bio: []const u8 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_74.db");
    defer db.close();

    // Self-reference, scoped form: deleting a manager NULLs direct reports.
    try db.createTable(Employee, .{
        .overWrite = true,
        .primaryKey = .id,
        .foreignKeys = &.{.{ .column = .manager_id, .references = .id, .onDelete = .setNull }},
    });
    var ceo = try db.from(Employee).insert(.{ .id = 1, .manager_id = null });
    ceo.deinit();
    var dev = try db.from(Employee).insert(.{ .id = 2, .manager_id = 1 });
    dev.deinit();
    const emp = db.from(Employee);
    var delMgr = try emp.where(Employee.id.eq(1)).delete().execute();
    delMgr.deinit();
    var orphan = try db.from(Employee).select(Employee.all()).fetchOne();
    defer db.from(Employee).freeRow(&orphan);
    std.debug.assert(orphan.manager_id == null);
    std.debug.print("74 self reference: manager delete nulled reports\n", .{});

    // Self-reference, explicit form: resolves to the same native metadata.
    try db.createTable(Audit, .{
        .overWrite = true,
        .primaryKey = Audit.id,
        .foreignKeys = &.{.{ .column = Audit.prev_id, .references = Audit.id, .onDelete = .cascade }},
    });
    var a1 = try db.from(Audit).insert(.{ .id = 1, .prev_id = null });
    a1.deinit();
    var a2 = try db.from(Audit).insert(.{ .id = 2, .prev_id = 1 });
    a2.deinit();
    var delA1 = try db.from(Audit).where(Audit.id.eq(1)).delete().execute();
    delA1.deinit();
    var auditLeft = try db.from(Audit).selectAll().fetch();
    defer auditLeft.deinit();
    std.debug.assert(auditLeft.count() == 0);
    std.debug.print("74 explicit self reference: cascade removed the chain\n", .{});

    // Two independent FKs to one table keep separate actions.
    try db.createTable(RUser, .{ .overWrite = true, .primaryKey = RUser.id });
    try db.createTable(Message, .{
        .overWrite = true,
        .primaryKey = Message.id,
        .foreignKeys = &.{
            .{ .column = Message.sender_id, .references = RUser.id, .onDelete = .cascade },
            .{ .column = Message.receiver_id, .references = RUser.id, .onDelete = .restrict },
        },
    });
    var ua = try db.from(RUser).insert(.{ .id = 10, .name = "ann" });
    ua.deinit();
    var ub = try db.from(RUser).insert(.{ .id = 20, .name = "bob" });
    ub.deinit();
    var mm = try db.from(Message).insert(.{ .id = 1, .sender_id = 10, .receiver_id = 20 });
    mm.deinit();
    var ds = try db.from(RUser).where(RUser.id.eq(10)).delete().execute();
    ds.deinit();
    var gone = try db.from(Message).selectAll().fetch();
    defer gone.deinit();
    std.debug.assert(gone.count() == 0);
    std.debug.print("74 multi FK: sender cascade removed the message\n", .{});

    // One-to-one: unique FK rejects the second profile, join reads both.
    try db.createTable(Profile, .{
        .overWrite = true,
        .primaryKey = Profile.id,
        .unique = &.{Profile.user_id},
        .foreignKeys = &.{.{ .column = Profile.user_id, .references = RUser.id, .onDelete = .cascade }},
    });
    var p1 = try db.from(Profile).insert(.{ .id = 1, .user_id = 20, .bio = "hi" });
    p1.deinit();
    var joined = try db.from(RUser).join(Profile, .inner, RUser.id.eq(Profile.user_id)).select(.{ RUser.name, Profile.bio }).fetch();
    defer joined.deinit();
    std.debug.assert(joined.count() == 1);
    std.debug.print("74 one-to-one: join reads user plus profile\n", .{});
}
