//! Shared engine error set plus stable human-readable messages.
//!
//! Purpose: single vocabulary for every recoverable failure (corrupt files,
//! bad SQL, missing objects, constraint and transaction misuse) and a
//! `message` mapping for CLI/API surfaces. Responsibilities: error
//! definitions and display strings only — raising is owned by each
//! subsystem. Dependencies: `std` (tests only). Ownership: none (pure
//! values/static strings; returned slices are literals with no lifetime).
//! Error behavior: this module never fails. Invariants: every `Error`
//! variant has a non-empty, stable message covered by the exhaustive test
//! below (do not rename messages without updating clients).

const std = @import("std");

/// Every recoverable engine failure.
///
/// Grouped by area: storage/format corruption (`InvalidHeader`,
/// `InvalidPageSize`, `InvalidRecord`), SQL authoring (`InvalidSql`,
/// `UnexpectedToken`, unknown/ambiguous names), DDL conflicts
/// (`TableExists` et al.), DML problems (`ColumnCountMismatch`,
/// `ConstraintViolation`, `SchemaMismatch`), transaction misuse
/// (`NotInTransaction`, `TransactionActive`), runtime limits
/// (`IntegerOverflow`, `Unsupported`, `TriggerDepthExceeded`), and result
/// arity (`NoRows`, `TooManyRows` for single-row queries).
pub const Error = error{
    InvalidHeader,
    InvalidPageSize,
    InvalidRecord,
    InvalidSql,
    UnexpectedToken,
    UnknownTable,
    UnknownColumn,
    AmbiguousColumn,
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
    NoRows,
    TooManyRows,
};

/// Maps an error to its stable display string (static literal, no lifetime).
///
/// Why stable matters: clients snapshot these strings in tests and user
/// output, so wording changes are breaking changes — extend, don't reword.
pub fn message(err: Error) []const u8 {
    return switch (err) {
        error.InvalidHeader => "invalid database header",
        error.InvalidPageSize => "invalid page size",
        error.InvalidRecord => "invalid record",
        error.InvalidSql => "invalid SQL",
        error.UnexpectedToken => "unexpected SQL token",
        error.UnknownTable => "unknown table",
        error.UnknownColumn => "unknown column",
        error.AmbiguousColumn => "ambiguous column name",
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
        error.NoRows => "query returned no rows",
        error.TooManyRows => "query returned more than one row",
    };
}

test "error messages are stable" {
    try std.testing.expectEqualStrings("invalid SQL", message(error.InvalidSql));
}

test "every error has a distinct non-empty message" {
    const cases = [_]Error{
        error.InvalidHeader,
        error.InvalidPageSize,
        error.InvalidRecord,
        error.InvalidSql,
        error.UnexpectedToken,
        error.UnknownTable,
        error.UnknownColumn,
        error.AmbiguousColumn,
        error.ColumnExists,
        error.TableExists,
        error.IndexExists,
        error.UnknownIndex,
        error.ViewExists,
        error.UnknownView,
        error.TriggerExists,
        error.UnknownTrigger,
        error.ColumnCountMismatch,
        error.ConstraintViolation,
        error.NotInTransaction,
        error.TransactionActive,
        error.UnknownDatabase,
        error.IntegerOverflow,
        error.Unsupported,
        error.SchemaMismatch,
        error.TriggerDepthExceeded,
        error.NoRows,
        error.TooManyRows,
    };
    // Exhaustive: the test must grow with the error set (27 variants).
    try std.testing.expectEqual(@as(usize, 27), cases.len);
    for (cases, 0..) |err, i| {
        const text = message(err);
        try std.testing.expect(text.len > 0);
        // Distinct: no two variants share a message.
        for (cases[0..i]) |other| {
            try std.testing.expect(!std.mem.eql(u8, text, message(other)));
        }
    }
    // Boundary: `message` is total over the set — spot-check the edges.
    try std.testing.expectEqualStrings("invalid database header", message(error.InvalidHeader));
    try std.testing.expectEqualStrings("query returned more than one row", message(error.TooManyRows));
}
