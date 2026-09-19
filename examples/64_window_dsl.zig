const std = @import("std");
const sqlite = @import("sqlite");

const Emp = sqlite.table("w_emp", struct { dept: []const u8, emp: []const u8, salary: i64 });

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "example_64.db");
    errdefer db.close();
    var setup = try db.exec("DROP TABLE IF EXISTS w_emp; CREATE TABLE w_emp (dept TEXT NOT NULL, emp TEXT NOT NULL, salary INTEGER NOT NULL); INSERT INTO w_emp VALUES ('HR', 'Alice', 1000), ('HR', 'Bob', 1500), ('IT', 'Charlie', 2000), ('IT', 'Dave', 2000), ('IT', 'Eve', 2500);");
    setup.deinit();
    try db.schema(Emp).validate();
    var rawRanks = try db.exec("SELECT emp, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary) AS rn, RANK() OVER (PARTITION BY dept ORDER BY salary) AS rk FROM w_emp ORDER BY salary;");
    defer rawRanks.deinit();
    if (rawRanks.count() != 5) return error.VerificationFailed;
    if (rawRanks.rows[0][1].integer != 1) return error.VerificationFailed;
    if (rawRanks.rows[1][1].integer != 2) return error.VerificationFailed;
    var dynRanks = try db.from("w_emp").select(.{ db.col("emp"), sqlite.rowNumber().partitionBy(db.col("dept")).orderBy(db.col("salary").asc()), sqlite.rank().partitionBy(db.col("dept")).orderBy(db.col("salary").asc()) }).orderBy(db.col("salary").asc()).fetch();
    defer dynRanks.deinit();
    if (dynRanks.count() != rawRanks.count()) return error.VerificationFailed;
    if (!std.mem.eql(u8, dynRanks.columns[1], "row_number")) return error.VerificationFailed;
    for (rawRanks.rows, 0..) |row, i| {
        if (dynRanks.rows[i][1].integer != row[1].integer) return error.VerificationFailed;
        if (dynRanks.rows[i][2].integer != row[2].integer) return error.VerificationFailed;
    }
    var typedRanks = try db.from(Emp).select(.{ Emp.columns.emp, sqlite.denseRank().partitionBy(Emp.columns.dept).orderBy(Emp.columns.salary.asc()), sqlite.lag(Emp.columns.salary).offset(1).defaultValue(0).orderBy(Emp.columns.salary.asc()) }).orderBy(Emp.columns.salary.asc()).fetch();
    defer typedRanks.deinit();
    if (typedRanks.count() != 5) return error.VerificationFailed;
    if (typedRanks.rows[0][1].integer != 1) return error.VerificationFailed;
    if (typedRanks.rows[0][2].integer != 0) return error.VerificationFailed;
    if (typedRanks.rows[1][2].integer != 1000) return error.VerificationFailed;
    var rawFramed = try db.exec("SELECT emp, FIRST_VALUE(emp) OVER (ORDER BY salary ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), NTILE(2) OVER (ORDER BY salary) FROM w_emp ORDER BY salary;");
    defer rawFramed.deinit();
    if (rawFramed.count() != 5) return error.VerificationFailed;
    var dynFramed = try db.from("w_emp").select(.{ db.col("emp"), sqlite.firstValue(db.col("emp")).orderBy(db.col("salary").asc()).rowsBetween(sqlite.preceding(1), sqlite.currentRow()), sqlite.ntile(2).orderBy(db.col("salary").asc()) }).orderBy(db.col("salary").asc()).fetch();
    defer dynFramed.deinit();
    if (dynFramed.count() != 5) return error.VerificationFailed;
    if (!std.mem.eql(u8, dynFramed.rows[0][1].text, "Alice")) return error.VerificationFailed;
    if (!std.mem.eql(u8, dynFramed.rows[1][1].text, "Alice")) return error.VerificationFailed;
    if (dynFramed.rows[4][2].integer != 2) return error.VerificationFailed;
    if (db.exec("SELECT RANK() OVER (ORDER BY nope) FROM w_emp;")) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    if (db.from("w_emp").select(.{sqlite.rank().orderBy(db.col("nope").asc())}).fetch()) |r| {
        var owned = r;
        owned.deinit();
        return error.VerificationFailed;
    } else |_| {}
    var intact = try db.exec("SELECT count(*) FROM w_emp;");
    defer intact.deinit();
    if (intact.rows[0][0].integer != 5) return error.VerificationFailed;
    var inserted = try db.from(Emp).insert(.{ .dept = "HR", .emp = "Zed", .salary = 900 });
    inserted.deinit();
    var afterInsert = try db.exec("SELECT emp, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary) FROM w_emp ORDER BY salary;");
    defer afterInsert.deinit();
    if (afterInsert.count() != 6) return error.VerificationFailed;
    var dynAfter = try db.from("w_emp").select(.{ db.col("emp"), sqlite.rowNumber().partitionBy(db.col("dept")).orderBy(db.col("salary").asc()) }).orderBy(db.col("salary").asc()).fetch();
    defer dynAfter.deinit();
    if (dynAfter.count() != 6) return error.VerificationFailed;
    if (!std.mem.eql(u8, dynAfter.rows[0][0].text, "Zed")) return error.VerificationFailed;
    if (dynAfter.rows[0][1].integer != 1) return error.VerificationFailed;
    db.close();
    var reopened = try sqlite.open(std.heap.page_allocator, "example_64.db");
    defer reopened.close();
    var persisted = try reopened.from("w_emp").select(.{ reopened.col("emp"), sqlite.rowNumber().partitionBy(reopened.col("dept")).orderBy(reopened.col("salary").asc()) }).orderBy(reopened.col("salary").asc()).fetch();
    defer persisted.deinit();
    if (persisted.count() != 6) return error.VerificationFailed;
    if (!std.mem.eql(u8, persisted.rows[0][0].text, "Zed")) return error.VerificationFailed;
    std.debug.print("64 window dsl: raw dynamic typed verified with persistence\n", .{});
}
