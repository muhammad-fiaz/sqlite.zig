//! Full dual-form matrix: every scoped/explicit combination, verified live.
//!
//! Each case prints `ok <name>` after asserting. Scoped means root-table
//! scope (`.id` lists, `q.c().id` predicates); explicit means qualified
//! paths (`User.id`, `u.id`, `t.column("id")`, `.set(...)` assigns).
//! Sections run as small functions so no single frame grows large.
//! Run with `zig build run-73_dual_form_matrix`.
const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("matrix_users", struct { id: i64, name: []const u8 });
const Group = sqlite.table("matrix_groups", struct { id: i64, title: []const u8 });
const MembershipRow = struct { user_id: i64, group_id: i64, label: []const u8 };
const Membership = sqlite.table("matrix_memberships", MembershipRow);

fn ok(name: []const u8) void {
    std.debug.print("ok {s}\n", .{name});
}

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_73.db");
    defer db.close();
    try schemaPart(db);
    try insertPart(db);
    try readPart(db);
    try joinPart(db);
    try writePart(db);
    try tailPart(db);
    std.debug.print("73 dual-form matrix: all combinations verified\n", .{});
}

/// Target table is Membership, so `.user_id`/`.group_id` resolve against
/// Membership exactly like `Membership.user_id` does; other tables stay
/// fully qualified (`User.id`, `Group.id`), and a bare field in
/// `references` is a compile error (no parent scope exists to bind it).
fn schemaPart(db: *sqlite.Connection) !void {
    try db.createTable(User, .{ .overWrite = true, .primaryKey = User.id });
    try db.createTable(Group, .{ .overWrite = true, .primaryKey = .id });
    try db.createTable(Membership, .{
        .overWrite = true,
        .primaryKey = &.{ Membership.user_id, Membership.group_id },
        .unique = &.{&.{ Membership.group_id, Membership.label }},
        .foreignKeys = &.{
            .{ .column = Membership.user_id, .references = User.id },
            .{ .column = .group_id, .references = Group.id },
        },
    });
    ok("ddl-combos");
    try db.createIndex(Membership, "matrix_mem_label", .{.label}, false);
    try db.createIndex(Membership, "matrix_mem_group", .{Membership.group_id}, false);
    ok("index-scoped-and-explicit");
}

fn insertPart(db: *sqlite.Connection) !void {
    const users = db.table("matrix_users");
    var a = try db.from(User).insert(.{ .id = 1, .name = "ann" });
    a.deinit();
    var b = try db.from(User).insert(.{ User.id.set(2), User.name.set("bob") });
    b.deinit();
    var c = try db.from(User).insert(.{ users.column("id").set(3), users.column("name").set("cy") });
    c.deinit();
    var d = try db.from(User).insert(.{ User.id.set(4), users.column("name").set("dee") });
    d.deinit();
    var g = try db.from(Group).insert(.{ .id = 7, .title = "ops" });
    g.deinit();
    var m1 = try db.from(Membership).insert(.{ .user_id = 1, .group_id = 7, .label = "a" });
    m1.deinit();
    var m2 = try db.from(Membership).insert(.{
        Membership.user_id.set(2),
        Membership.group_id.set(7),
        Membership.label.set("b"),
    });
    m2.deinit();
    ok("insert-scoped-explicit-dynamic-mixed");
}

fn readPart(db: *sqlite.Connection) !void {
    var sScoped = try db.from(User).select(.{ .id, .name }).orderBy(.id).fetch();
    defer sScoped.deinit();
    var sExplicit = try db.from(User).select(.{ User.id, User.name }).orderBy(User.id.asc()).fetch();
    defer sExplicit.deinit();
    std.debug.assert(sScoped.count() == 4 and sExplicit.count() == 4);
    for (0..4) |i| {
        std.debug.assert(sScoped.rows[i][0].integer == sExplicit.rows[i][0].integer);
        std.debug.assert(std.mem.eql(u8, sScoped.rows[i][1].text, sExplicit.rows[i][1].text));
    }
    ok("select-scoped-equals-explicit");
    var sMixed = try db.from(User).select(.{ .id, User.name }).fetch();
    defer sMixed.deinit();
    std.debug.assert(sMixed.count() == 4);
    ok("select-mixed");
    var sOne = try db.from(User).select(.id).fetch();
    defer sOne.deinit();
    std.debug.assert(sOne.count() == 4);
    ok("select-single-scoped");

    const q = db.from(User);
    var wScoped = try q.where(q.c().name.eq("bob")).select(.{.id}).fetch();
    defer wScoped.deinit();
    var wExplicit = try db.from(User).where(User.name.eq("bob")).select(.{User.id}).fetch();
    defer wExplicit.deinit();
    std.debug.assert(wScoped.count() == 1 and wExplicit.count() == 1);
    std.debug.assert(wScoped.rows[0][0].integer == wExplicit.rows[0][0].integer);
    ok("where-scoped-equals-explicit");

    var oMix = try db.from(User).orderBy(.{ .name, User.id.desc() }).select(.{.id}).fetch();
    defer oMix.deinit();
    std.debug.assert(oMix.count() == 4 and oMix.rows[0][0].integer == 1);
    ok("order-mixed");
    const gq = db.from(Membership);
    var grouped = try gq.groupBy(.group_id).having(gq.c().group_id.count().gt(0)).select(.{.group_id}).fetch();
    defer grouped.deinit();
    std.debug.assert(grouped.count() == 1 and grouped.rows[0][0].integer == 7);
    ok("group-having-scoped");

    var inS = try db.from(User).whereInValues(.id, &[_]i64{ 1, 3 }).select(.{.id}).fetch();
    defer inS.deinit();
    std.debug.assert(inS.count() == 2);
    ok("in-values-scoped");
    var inQ = try db.from(User).whereInQuery(.id, Membership, Membership.user_id).select(.{.id}).fetch();
    defer inQ.deinit();
    std.debug.assert(inQ.count() == 2);
    ok("in-query-outer-scoped");
    var ex = try db.from(User).whereExists(Membership, Membership.user_id.eq(User.id)).select(.{.id}).fetch();
    defer ex.deinit();
    std.debug.assert(ex.count() == 2);
    ok("exists-correlated");
}

fn joinPart(db: *sqlite.Connection) !void {
    const u = sqlite.aliased(User, "u");
    const m = sqlite.aliased(Membership, "m");
    var j = try db.from(u).join(m, .inner, u.id.eq(m.user_id)).select(.{ u.id, u.name, m.group_id }).fetch();
    defer j.deinit();
    std.debug.assert(j.count() == 2 and j.rows[0][2].integer == 7);
    ok("join-aliased-explicit");
    const qa = db.from(u);
    var ja = try qa.where(qa.c().id.eq(1)).join(m, .inner, u.id.eq(m.user_id)).select(.{.id}).fetch();
    defer ja.deinit();
    std.debug.assert(ja.count() == 1);
    ok("join-aliased-scoped-where");
    var jm = try db.from(User).join(Membership, .inner, User.id.eq(Membership.user_id)).where(User.id.eq(2)).select(.{ .id, Membership.label }).fetch();
    defer jm.deinit();
    std.debug.assert(jm.count() == 1 and std.mem.eql(u8, jm.rows[0][1].text, "b"));
    ok("join-mixed-scope");

    const Pair = sqlite.table("matrix_pairs", struct { id: i64, tag: []const u8 });
    const PairMeta = sqlite.table("matrix_pair_meta", struct { id: i64, note: []const u8 });
    try db.createTable(Pair, .{ .overWrite = true, .primaryKey = Pair.id });
    try db.createTable(PairMeta, .{ .overWrite = true, .primaryKey = PairMeta.id });
    var p1 = try db.from(Pair).insert(.{ .id = 1, .tag = "x" });
    p1.deinit();
    var p2 = try db.from(PairMeta).insert(.{ .id = 1, .note = "y" });
    p2.deinit();
    var ju = try db.from(Pair).joinUsing(PairMeta, .id).select(.{ Pair.id, Pair.tag }).fetch();
    defer ju.deinit();
    std.debug.assert(ju.count() == 1);
    ok("join-using-scoped");

    const Lite = sqlite.table("lite73", struct { id: i64 });
    var cte = try db.from(Lite).with("lite73", "SELECT id FROM matrix_users WHERE id >= 3").select(.{.id}).fetch();
    defer cte.deinit();
    std.debug.assert(cte.count() == 2);
    ok("cte-own-scope");
}

fn writePart(db: *sqlite.Connection) !void {
    const users = db.table("matrix_users");
    var ua = try (try db.from(User).update(.{ .name = "ann2" })).where(User.id.eq(1)).execute();
    ua.deinit();
    var ub = try (try db.from(User).update(.{User.name.set("bob2")})).where(User.id.eq(2)).execute();
    ub.deinit();
    var uc = try (try db.from(User).update(.{User.id.set(User.id.add(100))})).where(User.name.eq("cy")).execute();
    uc.deinit();
    var ud = try (try db.from(User).update(.{users.column("name").set("dee2")})).where(users.column("id").eq(4)).execute();
    ud.deinit();
    var checkU = try db.from(User).select(User.all()).orderBy(User.id.asc()).fetch();
    defer checkU.deinit();
    std.debug.assert(std.mem.eql(u8, checkU.at(0).name, "ann2"));
    std.debug.assert(std.mem.eql(u8, checkU.at(1).name, "bob2"));
    std.debug.assert(checkU.at(2).id == 4);
    std.debug.assert(std.mem.eql(u8, checkU.at(2).name, "dee2"));
    std.debug.assert(checkU.at(3).id == 103);
    ok("update-all-forms");

    var r1 = try (try db.from(User).returning(.{.name}).update(.{ .name = "ann3" })).where(User.id.eq(1)).execute();
    defer r1.deinit();
    std.debug.assert(r1.count() == 1);
    var r2 = try (try db.from(User).returning(.{User.name}).update(.{User.name.set("bob3")})).where(User.id.eq(2)).execute();
    defer r2.deinit();
    std.debug.assert(r2.count() == 1);
    ok("returning-scoped-and-explicit");

    var up1 = try (try db.from(User).onConflict(.id).doUpdate(.{User.name.set("ann4")})).insert(.{ .id = 1, .name = "x" });
    up1.deinit();
    var up2 = try (try db.from(User).onConflict(User.id).doUpdate(.{User.name.set(db.excluded("name"))})).insert(.{ .id = 2, .name = "bob4" });
    up2.deinit();
    var checkUp = try db.from(User).where(User.id.eq(2)).select(.{.name}).fetch();
    defer checkUp.deinit();
    std.debug.assert(std.mem.eql(u8, checkUp.rows[0][0].text, "bob4"));
    ok("upsert-targets-assigns-excluded");
}

fn tailPart(db: *sqlite.Connection) !void {
    const Copy = sqlite.table("matrix_copy", struct { id: i64, name: []const u8 });
    try db.createTable(Copy, .{ .overWrite = true, .primaryKey = Copy.id });
    var cp1 = try db.from(Copy).insertFrom(User, .{ .id = .id, .name = .name });
    cp1.deinit();
    var cpCount = try db.exec("SELECT count(*) FROM matrix_copy;");
    defer cpCount.deinit();
    std.debug.assert(cpCount.rows[0][0].integer == 4);
    ok("insert-from-scoped");

    const qd = db.from(User);
    var d1 = try qd.where(qd.c().id.eq(103)).delete().execute();
    d1.deinit();
    var d2 = try db.from(User).where(User.id.eq(4)).delete().execute();
    d2.deinit();
    var left = try db.exec("SELECT count(*) FROM matrix_users;");
    defer left.deinit();
    std.debug.assert(left.rows[0][0].integer == 2);
    ok("delete-where-first");

    const mems = db.table("matrix_memberships");
    var dyn = try mems.select(.{ mems.column("label"), mems.column("group_id") }).fetch();
    defer dyn.deinit();
    std.debug.assert(dyn.count() == 2);
    var dynW = try mems.select(mems.column("label")).where(mems.column("group_id").eq(7)).fetch();
    defer dynW.deinit();
    std.debug.assert(dynW.count() == 2);
    ok("dynamic-builder");
}
