const std = @import("std");
const connection = @import("connection/connection.zig");

pub const Connection = connection.Connection;
pub const open = Connection.open;
pub const Result = @import("connection/result.zig").Result;
pub const Statement = @import("connection/statement.zig").Statement;
pub const Value = @import("vm/value.zig").Value;
pub const errors = @import("errors/errors.zig");
pub const table = @import("dsl/table.zig").table;
pub const tableWith = @import("dsl/table.zig").tableWith;
pub const column = @import("dsl/column.zig").column;
pub const migration = struct {
    pub const Migration = @import("migration/migration.zig").Migration;
    pub const Runner = @import("migration/runner.zig").Runner;
};
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
    _ = @import("connection/connection.zig");
    _ = @import("connection/result.zig");
    _ = @import("connection/statement.zig");
    _ = @import("dsl/expr.zig");
    _ = @import("dsl/column.zig");
    _ = @import("dsl/keys.zig");
    _ = @import("dsl/table.zig");
    _ = @import("dsl/query_builder.zig");
    _ = @import("dsl/sql_gen.zig");
    _ = @import("migration/migration.zig");
    _ = @import("migration/runner.zig");
    _ = @import("catalog/schema.zig");
    _ = @import("catalog/type_affinity.zig");
    _ = @import("catalog/table_def.zig");
    _ = @import("catalog/index_def.zig");
    _ = @import("btree/btree.zig");
    _ = @import("btree/cursor.zig");
    _ = @import("btree/index_btree.zig");
    _ = @import("btree/balance.zig");
    _ = @import("plan/planner.zig");
    _ = @import("plan/cost.zig");
    _ = @import("plan/optimizer.zig");
    _ = @import("txn/transaction.zig");
    _ = @import("txn/locking.zig");
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
    try std.testing.expect(@hasDecl(@This(), "column"));
    try std.testing.expect(@hasDecl(@This(), "migration"));
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
