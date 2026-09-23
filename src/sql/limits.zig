//! Shared SQL resource limits: one budget table for the whole frontend.
//!
//! Values track `sqlite/src/sqliteLimit.h` defaults where the engine can
//! honor them. Two deliberate deviations: the parser depth cap (200 vs
//! SQLite's 2500) and the trigger depth cap (64 vs 1000) bound
//! recursive-descent call-stack and trigger-execution recursion, where
//! SQLite's LALR heap stack has no such pressure; hostile input still
//! fails closed either way. Expression nesting shares the parser depth
//! cap (SQLite splits `MAX_EXPR_DEPTH`=1000 from the parser stack).
//! Caps hostile or runaway SQL before it can force unbounded allocation.
//! Over-budget input fails with `error.SqlTooBig`.

const std = @import("std");

/// Maximum SQL statement text in bytes.
/// Enforced by `lexer.tokenize` before any token is allocated.
pub const max_sql_length: usize = 1_000_000_000;

/// Maximum string/blob/row size in bytes.
/// Reserved for value-size budgets; oversized payloads currently fail
/// closed via allocator OOM instead of a pre-check.
pub const max_length: usize = 1_000_000_000;

/// Maximum columns in a table definition or result set.
/// Enforced on parsed CREATE TABLE columns and SELECT/RETURNING projections.
pub const max_columns: usize = 2000;

/// Maximum terms in a compound SELECT.
/// Enforced while chaining UNION/INTERSECT/EXCEPT branches.
pub const max_compound_terms: usize = 500;

/// Maximum arguments to one function call.
/// Enforced while parsing call argument lists.
pub const max_function_args: usize = 1000;

/// Maximum attached databases.
/// Enforced by `connection.attachCommand`.
pub const max_attached: usize = 10;

/// Maximum LIKE/GLOB pattern length in bytes.
/// Enforced before matching starts.
pub const max_like_pattern_length: usize = 50000;

/// Maximum bound-parameter index.
/// Enforced on `?NNN` and anonymous `?` numbering while parsing.
pub const max_variables: usize = 32766;

/// Maximum statements in one trigger body (`SQLITE_MAX_TRIGGER_STEPS`).
/// Enforced when a trigger body executes, not for general multi-statement
/// scripts (migrations stay unbounded). SQLite rejects the oversized
/// `CREATE TRIGGER`; this engine fails the firing statement instead —
/// observable behavior matches for every trigger that can legally exist.
pub const max_trigger_steps: usize = 65000;

/// Maximum database page size in bytes (`SQLITE_MAX_PAGE_SIZE`).
/// Page sizes are powers of two in 512..65536; 65536 encodes as 1 on disk.
pub const max_page_size: usize = 65536;

/// Default database page size in bytes (`SQLITE_DEFAULT_PAGE_SIZE`).
/// Fresh databases are created with this size.
pub const default_page_size: usize = 4096;

/// Maximum distinct values tracked by one DISTINCT aggregate.
/// Past this, accumulation fails `SqlTooBig` instead of growing without
/// bound (per-group state, so ordinary queries never approach it).
pub const max_distinct_values: usize = 1_000_000;

test "limits pin the documented budgets" {
    // Values double as compatibility surface: same budgets SQLite documents
    // as its defaults, so the same hostile inputs fail on both sides.
    try std.testing.expectEqual(@as(usize, 1_000_000_000), max_sql_length);
    try std.testing.expectEqual(@as(usize, 1_000_000_000), max_length);
    try std.testing.expectEqual(@as(usize, 2000), max_columns);
    try std.testing.expectEqual(@as(usize, 500), max_compound_terms);
    try std.testing.expectEqual(@as(usize, 1000), max_function_args);
    try std.testing.expectEqual(@as(usize, 10), max_attached);
    try std.testing.expectEqual(@as(usize, 50000), max_like_pattern_length);
    try std.testing.expectEqual(@as(usize, 32766), max_variables);
    try std.testing.expectEqual(@as(usize, 1_000_000), max_distinct_values);
    try std.testing.expectEqual(@as(usize, 65000), max_trigger_steps);
    try std.testing.expectEqual(@as(usize, 65536), max_page_size);
    try std.testing.expectEqual(@as(usize, 4096), default_page_size);
}
