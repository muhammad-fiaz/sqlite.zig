pub const format = struct {
    pub const varint = @import("format/varint.zig");
    pub const header = @import("format/header.zig");
    pub const record = @import("format/record.zig");
    pub const page = @import("format/page.zig");
};

pub const value = @import("vm/value.zig");
pub const storage = struct {
    pub const file = @import("storage/file.zig");
    pub const pager = @import("storage/pager.zig");
    pub const wal = @import("storage/wal.zig");
    pub const journal = @import("storage/journal.zig");
    pub const sqlite_image = @import("storage/sqlite_image.zig");
};
pub const errors = @import("errors/errors.zig");
pub const sql = struct {
    pub const token = @import("sql/token.zig");
    pub const lexer = @import("sql/lexer.zig");
    pub const ast = @import("sql/ast.zig");
    pub const parser = @import("sql/parser.zig");
};
pub const connection = @import("connection/connection.zig");
pub const Connection = connection.Connection;
pub const Result = connection.Result;
pub const Statement = @import("connection/statement.zig").Statement;
pub const open = Connection.open;
pub const version = @import("version.zig");
pub const dsl = struct {
    pub const table = @import("dsl/table.zig").table;
    pub const Expr = @import("dsl/expr.zig").Expr;
    pub const Query = @import("dsl/query_builder.zig").Query;
    pub const ColumnKey = @import("dsl/table.zig").ColumnKey;
    pub const RawColumn = @import("dsl/raw_dsl.zig").RawColumn;
    pub const RawCondition = @import("dsl/raw_dsl.zig").RawCondition;
    pub const RawQuery = @import("dsl/raw_dsl.zig").RawQuery;
};
pub const table = @import("dsl/table.zig").table;
pub const migration = struct {
    pub const Migration = @import("migration/migration.zig").Migration;
    pub const Runner = @import("migration/runner.zig").Runner;
};
pub const catalog = struct {
    pub const schema = @import("catalog/schema.zig");
    pub const type_affinity = @import("catalog/type_affinity.zig");
    pub const table_def = @import("catalog/table_def.zig");
    pub const index_def = @import("catalog/index_def.zig");
};
pub const btree = struct {
    pub const BTree = @import("btree/btree.zig").BTree;
    pub const Cursor = @import("btree/cursor.zig").Cursor;
    pub const Index = @import("btree/index_btree.zig").Index;
    pub const balance = @import("btree/balance.zig");
};
pub const plan = struct {
    pub const planner = @import("plan/planner.zig");
    pub const cost = @import("plan/cost.zig");
};
pub const vm = struct {
    pub const opcode = @import("vm/opcode.zig");
    pub const compiler = @import("vm/compiler.zig");
    pub const run = @import("vm/vm.zig").run;
};
pub const txn = struct {
    pub const Transaction = @import("txn/transaction.zig").Transaction;
    pub const locking = @import("txn/locking.zig");
};

test {
    _ = format.varint;
    _ = format.header;
    _ = value;
    _ = storage.file;
    _ = errors;
    _ = sql.parser;
    _ = connection;
    _ = dsl;
    _ = migration;
    _ = catalog;
    _ = btree;
    _ = plan;
    _ = vm;
}
