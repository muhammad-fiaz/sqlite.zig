//! Public entry point; re-exports client types only.
//!
//! No logic here. Owners keep their own contracts.
//! Close the connection after its results and statements.

const std = @import("std");
const connection = @import("connection/connection.zig");

/// Open a database at `path` (borrowed). Returns an owned `Connection` that
/// must be `close`d; it must outlive every result/statement/handle from it.
pub const open = Connection.open;
/// Owned live database connection; see `connection/connection.zig`.
pub const Connection = connection.Connection;
/// Owned eagerly materialized result; caller `deinit`s (idempotent).
pub const Result = @import("connection/result.zig").Result;
/// Owned prepared statement; caller `finalize`s (idempotent).
pub const Statement = @import("connection/statement.zig").Statement;
/// Runtime value; text/blob payloads follow the owner (Result borrows in).
pub const Value = @import("vm/value.zig").Value;
/// Engine error sets.
pub const errors = @import("errors/errors.zig");
/// Define a typed table value from a row struct or descriptor struct.
pub const table = @import("dsl/table.zig").table;
/// Define a typed table value with options (strict/without-rowid flags).
pub const tableWith = @import("dsl/table.zig").tableWith;
/// Rebind a table value's columns to an alias (for self-joins).
pub const aliased = @import("dsl/table.zig").aliased;
/// Borrowed runtime table handle; connection must outlive it.
pub const DynamicTable = @import("dsl/dynamic.zig").DynamicTable;
/// Runtime column descriptor; same predicate family as typed columns.
pub const DynamicColumn = @import("dsl/column.zig").DynamicColumn;
/// Borrowed handle to one attached schema; connection must outlive it.
pub const SchemaHandle = @import("dsl/dynamic.zig").SchemaHandle;
/// Build a typed column value for descriptor-form table specs.
pub const column = @import("dsl/column.zig").column;
/// Start a searched CASE builder (`caseWhen(cond, result)`).
pub const caseWhen = @import("dsl/column.zig").caseWhen;
/// Start a simple CASE builder dispatching on a column (`caseValue(col)`).
pub const caseValue = @import("dsl/column.zig").caseValue;
/// `row_number()` window handle.
pub const rowNumber = @import("dsl/column.zig").rowNumber;
/// `rank()` window handle.
pub const rank = @import("dsl/column.zig").rank;
/// `dense_rank()` window handle.
pub const denseRank = @import("dsl/column.zig").denseRank;
/// `percent_rank()` window handle.
pub const percentRank = @import("dsl/column.zig").percentRank;
/// `cume_dist()` window handle.
pub const cumeDist = @import("dsl/column.zig").cumeDist;
/// `ntile(n)` window handle.
pub const ntile = @import("dsl/column.zig").ntile;
/// `lag(col)` window handle.
pub const lag = @import("dsl/column.zig").lag;
/// `lead(col)` window handle.
pub const lead = @import("dsl/column.zig").lead;
/// `first_value(col)` window handle.
pub const firstValue = @import("dsl/column.zig").firstValue;
/// `last_value(col)` window handle.
pub const lastValue = @import("dsl/column.zig").lastValue;
/// `nth_value(col, n)` window handle.
pub const nthValue = @import("dsl/column.zig").nthValue;
/// `UNBOUNDED PRECEDING` frame bound.
pub const unboundedPreceding = @import("dsl/column.zig").unboundedPreceding;
/// `<offset> PRECEDING` frame bound.
pub const preceding = @import("dsl/column.zig").preceding;
/// `CURRENT ROW` frame bound.
pub const currentRow = @import("dsl/column.zig").currentRow;
/// `<offset> FOLLOWING` frame bound.
pub const following = @import("dsl/column.zig").following;
/// `UNBOUNDED FOLLOWING` frame bound.
pub const unboundedFollowing = @import("dsl/column.zig").unboundedFollowing;
/// Migration namespace: `Migration` (borrowed def), `Set` (borrowed list),
/// `Runner` (borrowed applier). Connection must outlive runner calls.
pub const migration = struct {
    pub const Migration = @import("migration/migration.zig").Migration;
    pub const Set = @import("migration/migration.zig").Set;
    pub const Runner = @import("migration/runner.zig").Runner;
};
/// Library version info.
pub const version = @import("version.zig");

test {
    _ = @import("format/varint.zig");
    _ = @import("format/header.zig");
    _ = @import("format/record.zig");
    _ = @import("format/page.zig");
    _ = @import("vm/value.zig");
    _ = @import("vm/vm.zig");
    _ = @import("vm/compiler.zig");
    _ = @import("vm/opcode.zig");
    _ = @import("storage/file.zig");
    _ = @import("storage/pager.zig");
    _ = @import("storage/wal.zig");
    _ = @import("storage/journal.zig");
    _ = @import("storage/image.zig");
    _ = @import("storage/sqlite_image.zig");
    _ = @import("errors/errors.zig");
    _ = @import("sql/token.zig");
    _ = @import("sql/lexer.zig");
    _ = @import("sql/ast.zig");
    _ = @import("sql/parser.zig");
    _ = @import("sql/parser/common.zig");
    _ = @import("sql/limits.zig");
    _ = @import("sql/coerce.zig");
    _ = @import("sql/expr.zig");
    _ = @import("connection/connection.zig");
    _ = @import("connection/result.zig");
    _ = @import("connection/statement.zig");
    _ = @import("dsl/expr.zig");
    _ = @import("dsl/column.zig");
    _ = @import("dsl/keys.zig");
    _ = @import("dsl/table.zig");
    _ = @import("dsl/query_builder.zig");
    _ = @import("dsl/mutation.zig");
    _ = @import("dsl/ast_builder.zig");
    _ = @import("dsl/dynamic.zig");
    _ = @import("migration/migration.zig");
    _ = @import("migration/runner.zig");
    _ = @import("catalog/schema.zig");
    _ = @import("catalog/strict.zig");
    _ = @import("catalog/sequence.zig");
    _ = @import("catalog/stats.zig");
    _ = @import("catalog/type_affinity.zig");
    _ = @import("btree/btree.zig");
    _ = @import("btree/cursor.zig");
    _ = @import("btree/index_btree.zig");
    _ = @import("btree/balance.zig");
    _ = @import("plan/planner.zig");
    _ = @import("plan/cost.zig");
    _ = @import("plan/optimizer.zig");
    _ = @import("txn/transaction.zig");
    _ = @import("txn/locking.zig");
    _ = @import("connection/pattern.zig");
    _ = @import("connection/compare.zig");
    _ = @import("connection/fk_actions.zig");
    _ = @import("connection/conflicts.zig");
    _ = @import("version.zig");
}

test "public surface exposes only client concepts" {
    try std.testing.expect(@hasDecl(@This(), "open"));
    try std.testing.expect(@hasDecl(@This(), "Connection"));
    try std.testing.expect(@hasDecl(@This(), "Statement"));
    try std.testing.expect(@hasDecl(@This(), "Result"));
    try std.testing.expect(@hasDecl(@This(), "Value"));
    try std.testing.expect(@hasDecl(@This(), "errors"));
    try std.testing.expect(@hasDecl(@This(), "table"));
    try std.testing.expect(@hasDecl(@This(), "tableWith"));
    try std.testing.expect(@hasDecl(@This(), "DynamicTable"));
    try std.testing.expect(@hasDecl(@This(), "DynamicColumn"));
    try std.testing.expect(@hasDecl(@This(), "SchemaHandle"));
    try std.testing.expect(@hasDecl(@This(), "column"));
    try std.testing.expect(@hasDecl(@This(), "caseWhen"));
    try std.testing.expect(@hasDecl(@This(), "caseValue"));
    try std.testing.expect(@hasDecl(@This(), "rowNumber"));
    try std.testing.expect(@hasDecl(@This(), "rank"));
    try std.testing.expect(@hasDecl(@This(), "denseRank"));
    try std.testing.expect(@hasDecl(@This(), "percentRank"));
    try std.testing.expect(@hasDecl(@This(), "cumeDist"));
    try std.testing.expect(@hasDecl(@This(), "ntile"));
    try std.testing.expect(@hasDecl(@This(), "lag"));
    try std.testing.expect(@hasDecl(@This(), "lead"));
    try std.testing.expect(@hasDecl(@This(), "firstValue"));
    try std.testing.expect(@hasDecl(@This(), "lastValue"));
    try std.testing.expect(@hasDecl(@This(), "nthValue"));
    try std.testing.expect(@hasDecl(@This(), "unboundedPreceding"));
    try std.testing.expect(@hasDecl(@This(), "preceding"));
    try std.testing.expect(@hasDecl(@This(), "currentRow"));
    try std.testing.expect(@hasDecl(@This(), "following"));
    try std.testing.expect(@hasDecl(@This(), "unboundedFollowing"));
    try std.testing.expect(@hasDecl(@This(), "migration"));
    try std.testing.expect(@hasDecl(migration, "Set"));
    try std.testing.expect(@hasDecl(@This(), "version"));
    try std.testing.expect(!@hasDecl(@This(), "format"));
    try std.testing.expect(!@hasDecl(@This(), "storage"));
    try std.testing.expect(!@hasDecl(@This(), "sql"));
    try std.testing.expect(!@hasDecl(@This(), "catalog"));
    try std.testing.expect(!@hasDecl(@This(), "btree"));
    try std.testing.expect(!@hasDecl(@This(), "plan"));
    try std.testing.expect(!@hasDecl(@This(), "vm"));
    try std.testing.expect(!@hasDecl(@This(), "txn"));
    try std.testing.expect(!@hasDecl(@This(), "dsl"));
}
