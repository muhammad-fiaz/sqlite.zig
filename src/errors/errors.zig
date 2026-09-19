const std = @import("std");

pub const Error = error{
    InvalidHeader,
    InvalidPageSize,
    InvalidRecord,
    InvalidSql,
    UnexpectedToken,
    UnknownTable,
    UnknownColumn,
    ColumnExists,
    TableExists,
    IndexExists,
    UnknownIndex,
    ViewExists,
    UnknownView,
    TriggerExists,
    UnknownTrigger,
    ColumnCountMismatch,
    ConstraintViolation,
    NotInTransaction,
    TransactionActive,
    UnknownDatabase,
    IntegerOverflow,
    Unsupported,
    SchemaMismatch,
    TriggerDepthExceeded,
};

pub fn message(err: Error) []const u8 {
    return switch (err) {
        error.InvalidHeader => "invalid database header",
        error.InvalidPageSize => "invalid page size",
        error.InvalidRecord => "invalid record",
        error.InvalidSql => "invalid SQL",
        error.UnexpectedToken => "unexpected SQL token",
        error.UnknownTable => "unknown table",
        error.UnknownColumn => "unknown column",
        error.ColumnExists => "column already exists",
        error.TableExists => "table already exists",
        error.IndexExists => "index already exists",
        error.UnknownIndex => "unknown index",
        error.ViewExists => "view already exists",
        error.UnknownView => "unknown view",
        error.TriggerExists => "trigger already exists",
        error.UnknownTrigger => "unknown trigger",
        error.ColumnCountMismatch => "column count mismatch",
        error.ConstraintViolation => "constraint violation",
        error.NotInTransaction => "not in transaction",
        error.TransactionActive => "transaction already active",
        error.UnknownDatabase => "no such database",
        error.IntegerOverflow => "integer overflow",
        error.Unsupported => "unsupported feature",
        error.SchemaMismatch => "database schema does not match the declared table",
        error.TriggerDepthExceeded => "triggers nested too deep",
    };
}

test "error messages are stable" {
    try std.testing.expectEqualStrings("invalid SQL", message(error.InvalidSql));
}
