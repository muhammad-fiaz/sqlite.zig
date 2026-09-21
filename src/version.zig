//! Engine version constants.
//!
//! Purpose: single source of truth for the library release (`sqliteVersion`)
//! and the SQLite compatibility version this engine targets
//! (`sqliteEngineVersion`, surfaced via `sqlite_version()`). Dependencies:
//! none. Ownership: static strings, no lifetime. Invariants: both are
//! `major.minor.patch` numeric strings; the engine version tracks a real
//! upstream SQLite release so clients can gate on file-format features.

const std = @import("std");

/// This library's own release version.
pub const sqliteVersion = "0.0.1";
/// Upstream SQLite version whose behavior/file format is targeted.
pub const sqliteEngineVersion = "3.54.0";

test "versions are dotted numeric triples" {
    for ([_][]const u8{ sqliteVersion, sqliteEngineVersion }) |version| {
        var parts: usize = 0;
        var segments = std.mem.splitScalar(u8, version, '.');
        while (segments.next()) |segment| {
            parts += 1;
            try std.testing.expect(segment.len > 0);
            for (segment) |c| try std.testing.expect(c >= '0' and c <= '9');
        }
        try std.testing.expectEqual(@as(usize, 3), parts);
    }
    // The engine compatibility version must stay ahead of the library release.
    try std.testing.expect(!std.mem.eql(u8, sqliteVersion, sqliteEngineVersion));
}
