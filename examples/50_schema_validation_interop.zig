const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("validation_users", struct { id: i64, email: []const u8, age: ?i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_50.db");
    const t_db_validation_users = db.table("validation_users");
    defer db.close();

    var setup = try db.exec("DROP TABLE IF EXISTS validation_users; CREATE TABLE validation_users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, age INTEGER); INSERT INTO validation_users VALUES (1, 'ada@example.test', 36);");
    setup.deinit();

    var dyn = try t_db_validation_users.selectAll().where(t_db_validation_users.column("email").like("%@example.test")).fetch();
    defer dyn.deinit();
    if (dyn.count() != 1) return error.DynamicInteropFailed;

    try db.schema(User).validate();
    var typed = try db.from(User).where(User.age.gte(18)).fetch();
    defer typed.deinit();
    if (typed.count() != 1 or !std.mem.eql(u8, typed.at(0).email, "ada@example.test")) return error.TypedInteropFailed;

    const Wrong = sqlite.table("validation_users", struct { id: i64, email: []const u8 });
    if (db.schema(Wrong).validate()) {
        return error.MismatchWasAccepted;
    } else |err| {
        if (err != error.SchemaMismatch) return err;
    }

    std.debug.print("50 schema validation: raw, dynamic, and typed interop verified\n", .{});
}
