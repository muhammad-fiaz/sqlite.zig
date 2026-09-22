//! Recursive CTE with UNION ALL fixpoint iteration.
const std = @import("std");
const sqlite = @import("sqlite");

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_32.db");
    defer db.close();
    var rows = try db.exec("WITH RECURSIVE nums AS (SELECT 1 AS n UNION ALL SELECT n + 1 AS n FROM nums WHERE n < 5) SELECT n FROM nums ORDER BY n;");
    defer rows.deinit();
    if (rows.count() != 5 or rows.at(0)[0].integer != 1 or rows.at(4)[0].integer != 5) return error.RecursiveCteVerificationFailed;
    std.debug.print("32 recursive CTEs: UNION ALL fixpoint and arithmetic verified\n", .{});
}
