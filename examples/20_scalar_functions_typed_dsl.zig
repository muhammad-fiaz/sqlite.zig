const std = @import("std");
const sqlite = @import("sqlite");

const MetricRow = struct { id: i64, label: []const u8, value: i64 };
const Metric = sqlite.table("scalar_metrics", MetricRow);

pub fn main() !void {
    var db = try sqlite.open(std.heap.page_allocator, "valid_20.db");
    defer db.close();
    try db.createTable(Metric, .{ .if_not_exists = true, .primary_key = Metric.key("id") });
    try db.truncate(Metric);
    var inserted = try db.from(Metric).insertTyped(.{ .id = 1, .label = "Alpha", .value = 12 });
    inserted.deinit();

    var raw = try db.exec("SELECT lower(label), upper(label), length(label), abs(value), typeof(value) FROM scalar_metrics;");
    defer raw.deinit();
    if (raw.rowCount() != 1) return error.RawScalarVerificationFailed;

    var lower = try db.from(Metric).lowerColumn(Metric.key("label")).fetchAll();
    defer lower.deinit();
    var absolute = try db.from(Metric).absColumn(Metric.key("value")).fetchAll();
    defer absolute.deinit();
    if (lower.rowCount() != 1 or absolute.rows[0][0].integer != 12) return error.TypedScalarVerificationFailed;
    std.debug.print("20 scalar functions: raw and typed projections verified\n", .{});
}
