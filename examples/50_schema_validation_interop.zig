const std = @import("std");
const sqlite = @import("sqlite");

const User = sqlite.table("validation_users", struct { id: i64, email: []const u8, age: ?i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_50.db");
    defer db.close();

    var setup = try db.exec("DROP TABLE IF EXISTS validation_users; CREATE TABLE validation_users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, age INTEGER); INSERT INTO validation_users VALUES (1, 'ada@example.test', 36);");
    setup.deinit();

    var dyn = try db.from("validation_users").where(db.col("email").like("%@example.test")).fetch();
    defer dyn.deinit();
    if (dyn.rowCount() != 1) return error.DynamicInteropFailed;

    try db.schema(User).validate();
    var typed = try db.from(User).where(User.columns.age.gte(18)).fetch();
    defer typed.deinit();
    if (typed.rowCount() != 1 or !std.mem.eql(u8, typed.rows[0].email, "ada@example.test")) return error.TypedInteropFailed;

    const Wrong = sqlite.table("validation_users", struct { id: i64, email: []const u8 });
    if (db.schema(Wrong).validate()) {
        return error.MismatchWasAccepted;
    } else |err| {
        if (err != error.SchemaMismatch) return err;
    }

    std.debug.print("50 schema validation: raw, dynamic, and typed interop verified\n", .{});
}
