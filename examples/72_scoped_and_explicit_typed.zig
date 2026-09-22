//! Typed DSL scoping: scoped fields and explicit table paths are one model.
//!
//! `db.from(User)` establishes User as the root scope: `.id` in column
//! lists resolves against it, and `q.c().id` exposes scoped columns for
//! predicate positions. Explicit paths (`User.id`, `u.id`) carry their own
//! table identity and never depend on scope. Both forms converge on the
//! same native AST; this example asserts they return identical data.
//! Aliases come from `sqlite.aliased` (Zig comptime structs cannot carry
//! methods, so `User.as("u")` is not expressible; the free function is the
//! alias API and never mutates the schema).
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("scoped_users", struct { id: i64, name: []const u8 });
const MembershipRow = struct { user_id: i64, group_id: i64, label: []const u8 };
const Membership = sqlite.table("scoped_memberships", MembershipRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_72.db");
    defer db.close();
    try db.createTable(User, .{ .overWrite = true, .primaryKey = User.id });
    try db.createTable(Membership, .{
        .overWrite = true,
        .primaryKey = &.{ Membership.user_id, Membership.group_id },
        .unique = &.{&.{ Membership.group_id, Membership.label }},
    });
    // Scoped insert...
    var s1 = try db.from(User).insert(.{ .id = 1, .name = "ann" });
    s1.deinit();
    var s2 = try db.from(Membership).insert(.{ .user_id = 1, .group_id = 7, .label = "ops" });
    s2.deinit();
    // ...and the explicit qualified form writes the same native rows.
    var e1 = try db.from(User).insert(.{ User.id.set(2), User.name.set("bob") });
    e1.deinit();
    var e2 = try db.from(Membership).insert(.{
        Membership.user_id.set(2),
        Membership.group_id.set(9),
        Membership.label.set("dev"),
    });
    e2.deinit();
    // Scoped and explicit selects agree cell by cell.
    var scoped = try db.from(Membership).select(.{ .user_id, .group_id, .label }).orderBy(.user_id).fetch();
    defer scoped.deinit();
    var explicit = try db.from(Membership).select(.{ Membership.user_id, Membership.group_id, Membership.label }).orderBy(Membership.user_id.asc()).fetch();
    defer explicit.deinit();
    std.debug.assert(scoped.count() == explicit.count() and scoped.count() == 2);
    for (0..scoped.count()) |i| {
        std.debug.assert(scoped.rows[i][0].integer == explicit.rows[i][0].integer);
        std.debug.assert(scoped.rows[i][1].integer == explicit.rows[i][1].integer);
        std.debug.assert(std.mem.eql(u8, scoped.rows[i][2].text, explicit.rows[i][2].text));
    }
    // Scoped predicates through the columns value.
    const q = db.from(User);
    var one = try q.where(q.c().id.eq(1)).select(.{.name}).fetch();
    defer one.deinit();
    std.debug.assert(one.count() == 1 and std.mem.eql(u8, one.rows[0][0].text, "ann"));
    // Aliased join: every reference keeps its alias identity.
    const u = sqlite.aliased(User, "u");
    const m = sqlite.aliased(Membership, "m");
    var joined = try db.from(u).join(m, .inner, u.id.eq(m.user_id)).select(.{ u.id, u.name, m.group_id }).fetch();
    defer joined.deinit();
    std.debug.assert(joined.count() == 2);
    std.debug.assert(joined.rows[0][0].integer == 1);
    std.debug.assert(joined.rows[0][2].integer == 7);
    std.debug.assert(joined.rows[1][0].integer == 2);
    std.debug.assert(joined.rows[1][2].integer == 9);
    // Same join unaliased, mixing root scope with explicit other-table refs.
    var mixed = try db.from(User).join(Membership, .inner, User.id.eq(Membership.user_id)).where(User.id.eq(1)).select(.{ .id, Membership.group_id }).fetch();
    defer mixed.deinit();
    std.debug.assert(mixed.count() == 1 and mixed.rows[0][1].integer == 7);
    // Scoped upsert target with an explicit arithmetic assignment.
    var up = try (try db.from(User).onConflict(.id).doUpdate(.{
        User.name.set("ann-updated"),
    })).insert(.{ .id = 1, .name = "ignored" });
    up.deinit();
    // Scoped RETURNING on update plus scoped delete.
    var ret = try (try db.from(User).returning(.{.name}).update(.{ .name = "ann-final" })).where(User.id.eq(1)).execute();
    defer ret.deinit();
    std.debug.assert(ret.count() == 1);
    var del = try db.from(User).where(User.id.eq(2)).delete().execute();
    defer del.deinit();
    var left = try db.exec("SELECT count(*) FROM scoped_users;");
    defer left.deinit();
    std.debug.assert(left.rows[0][0].integer == 1);
    std.debug.print("72 scoped and explicit typed forms: identical results verified\n", .{});
}
