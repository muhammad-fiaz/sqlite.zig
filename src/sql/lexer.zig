//! SQL lexer: bytes -> `token.zig` tokens (pipeline stage 1).
//!
//! Purpose: single-pass scanner producing the token stream `Parser` consumes.
//! Handles whitespace, `--`/`/* */` comments, quoted identifiers and string
//! literals (`'it''s'`, `"ident"`, `` `ident` ``), numbers (decimal, float,
//! exponent, `0x` hex, leading-dot floats), bind parameters (`?`, `?NNN`,
//! `:name`, `@name`, `$name`), and all single/double-char operators
//! (`||`, `<<`, `>>`, `<=`, `>=`, `==`, `!=`, `<>`).
//!
//! Responsibilities: tokenize only; no keyword classification (that stays in
//! the parser so quoted keywords remain identifiers) and no semantic checks.
//! DSL builders bypass this stage by constructing `ast.zig` nodes directly.
//!
//! Dependencies: `token.zig` (`Token`, `Tag`) and `std` only.
//!
//! Ownership/lifetime: returned `[]Token` is heap-owned by the caller; each
//! `Token.text` borrows the input `sql` slice. Caller frees the slice with
//! `allocator.free(tokens)`; no per-token frees.
//!
//! Error behavior: fails closed on hostile input — `InvalidCharacter` for
//! stray bytes/`!` without `=`, `UnterminatedString` for a missing close
//! quote, `UnterminatedComment` for a missing `*/`. No partial token stream
//! is returned on error (`errdefer` cleans up).
//!
//! Invariants: output always ends with exactly one `.eof` token whose
//! `position == sql.len`; every other token satisfies
//! `text.len > 0` and `position + text.len <= sql.len` (modulo quote stripping).
//!
//! SQLite compatibility: `==` accepted as `=`; `<>` and `!=` both map to
//! `.notEqual`; `--` runs to newline; `/* */` is non-nesting, as in SQLite.
//!
//! Hostile-input notes: token count is O(sql.len) (each token consumes >= 1
//! byte), so allocation is linear in input the caller already holds.
//! No recursion is used; the scanner loop itself cannot stack-overflow.
// TODO(sql/lexer): enforce a SQLITE_LIMIT_SQL_LENGTH-style cap (SQLite
// defaults to 1_000_000 bytes) and surface `error.SqlTooBig` so a
// multi-megabyte hostile string fails fast instead of allocating O(n) tokens.
// Expected: lexer + parser + connection agree on one constant and one error;
// tests: over-limit SQL rejected, boundary length accepted, limit documented.

const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;

/// Lexer failure modes; all fail closed with no partial output.
pub const Error = error{ InvalidCharacter, UnterminatedString, UnterminatedComment };

fn isWordStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;
}
fn isWordPart(byte: u8) bool {
    return isWordStart(byte) or std.ascii.isDigit(byte) or byte == '$';
}

/// Scan `sql` into a heap-owned token slice ending in `.eof`.
/// Caller owns the returned slice (`allocator.free`) while token texts borrow `sql`.
/// Fails closed with `Error` on bad bytes, unterminated strings, or comments.
pub fn tokenize(allocator: std.mem.Allocator, sql: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);
    var i: usize = 0;
    while (i < sql.len) {
        const start = i;
        switch (sql[i]) {
            ' ', '\t', '\r', '\n' => i += 1,
            '-' => if (i + 1 < sql.len and sql[i + 1] == '-') {
                i += 2;
                while (i < sql.len and sql[i] != '\n') i += 1;
            } else {
                try tokens.append(allocator, .{ .tag = .minus, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            '/' => if (i + 1 < sql.len and sql[i + 1] == '*') {
                i += 2;
                while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) i += 1;
                if (i + 1 >= sql.len) return Error.UnterminatedComment;
                i += 2;
            } else {
                try tokens.append(allocator, .{ .tag = .slash, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            '\'', '"', '`' => {
                const quote = sql[i];
                i += 1;
                const content = i;
                while (i < sql.len) : (i += 1) {
                    if (sql[i] == quote) {
                        if (i + 1 < sql.len and sql[i + 1] == quote) {
                            i += 1;
                            continue;
                        }
                        try tokens.append(allocator, .{ .tag = if (quote == '\'') .string else .word, .text = sql[content..i], .position = start, .quoted = quote != '\'' });
                        i += 1;
                        break;
                    }
                } else return Error.UnterminatedString;
            },
            '0'...'9' => {
                if (sql[i] == '0' and i + 1 < sql.len and (sql[i + 1] == 'x' or sql[i + 1] == 'X')) {
                    i += 2;
                    const hexStart = i;
                    while (i < sql.len and std.ascii.isHex(sql[i])) i += 1;
                    if (i == hexStart) i = start + 1;
                    try tokens.append(allocator, .{ .tag = .number, .text = sql[start..i], .position = start });
                } else {
                    i += 1;
                    while (i < sql.len and std.ascii.isDigit(sql[i])) i += 1;
                    if (i < sql.len and sql[i] == '.') i += 1;
                    while (i < sql.len and std.ascii.isDigit(sql[i])) i += 1;
                    if (i < sql.len and (sql[i] == 'e' or sql[i] == 'E')) {
                        var cursor = i + 1;
                        if (cursor < sql.len and (sql[cursor] == '+' or sql[cursor] == '-')) cursor += 1;
                        var expDigits: usize = 0;
                        while (cursor < sql.len and std.ascii.isDigit(sql[cursor])) : (cursor += 1) expDigits += 1;
                        if (expDigits != 0) i = cursor;
                    }
                    try tokens.append(allocator, .{ .tag = .number, .text = sql[start..i], .position = start });
                }
            },
            '.' => {
                if (i + 1 < sql.len and std.ascii.isDigit(sql[i + 1])) {
                    i += 1;
                    while (i < sql.len and std.ascii.isDigit(sql[i])) i += 1;
                    if (i < sql.len and (sql[i] == 'e' or sql[i] == 'E')) {
                        var cursor = i + 1;
                        if (cursor < sql.len and (sql[cursor] == '+' or sql[cursor] == '-')) cursor += 1;
                        var expDigits: usize = 0;
                        while (cursor < sql.len and std.ascii.isDigit(sql[cursor])) : (cursor += 1) expDigits += 1;
                        if (expDigits != 0) i = cursor;
                    }
                    try tokens.append(allocator, .{ .tag = .number, .text = sql[start..i], .position = start });
                } else {
                    try tokens.append(allocator, .{ .tag = .dot, .text = sql[i .. i + 1], .position = i });
                    i += 1;
                }
            },
            '?' => {
                i += 1;
                while (i < sql.len and std.ascii.isDigit(sql[i])) i += 1;
                try tokens.append(allocator, .{ .tag = .parameter, .text = sql[start..i], .position = start });
            },
            ':', '@', '$' => {
                i += 1;
                while (i < sql.len and isWordPart(sql[i])) i += 1;
                try tokens.append(allocator, .{ .tag = .parameter, .text = sql[start..i], .position = start });
            },
            '(' => {
                try tokens.append(allocator, .{ .tag = .lparen, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            ')' => {
                try tokens.append(allocator, .{ .tag = .rparen, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            ',' => {
                try tokens.append(allocator, .{ .tag = .comma, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            '*' => {
                try tokens.append(allocator, .{ .tag = .star, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            '+' => {
                try tokens.append(allocator, .{ .tag = .plus, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            '=' => {
                if (i + 1 < sql.len and sql[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .equal, .text = sql[i .. i + 2], .position = i });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .equal, .text = sql[i .. i + 1], .position = i });
                    i += 1;
                }
            },
            '!' => {
                if (i + 1 < sql.len and sql[i + 1] == '=') {
                    try tokens.append(allocator, .{ .tag = .notEqual, .text = sql[i .. i + 2], .position = i });
                    i += 2;
                } else return Error.InvalidCharacter;
            },
            '%' => {
                try tokens.append(allocator, .{ .tag = .percent, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            '&' => {
                try tokens.append(allocator, .{ .tag = .amp, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            '|' => {
                if (i + 1 < sql.len and sql[i + 1] == '|') {
                    try tokens.append(allocator, .{ .tag = .concat, .text = sql[i .. i + 2], .position = i });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .tag = .pipe, .text = sql[i .. i + 1], .position = i });
                    i += 1;
                }
            },
            '~' => {
                try tokens.append(allocator, .{ .tag = .tilde, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            '<' => {
                i += 1;
                const tag: Tag = if (i < sql.len and sql[i] == '=') blk: {
                    i += 1;
                    break :blk .lessEqual;
                } else if (i < sql.len and sql[i] == '>') blk: {
                    i += 1;
                    break :blk .notEqual;
                } else if (i < sql.len and sql[i] == '<') blk: {
                    i += 1;
                    break :blk .lshift;
                } else .less;
                try tokens.append(allocator, .{ .tag = tag, .text = sql[start..i], .position = start });
            },
            '>' => {
                i += 1;
                const tag: Tag = if (i < sql.len and sql[i] == '=') blk: {
                    i += 1;
                    break :blk .greaterEqual;
                } else if (i < sql.len and sql[i] == '>') blk: {
                    i += 1;
                    break :blk .rshift;
                } else .greater;
                try tokens.append(allocator, .{ .tag = tag, .text = sql[start..i], .position = start });
            },
            ';' => {
                try tokens.append(allocator, .{ .tag = .semicolon, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            else => if (isWordStart(sql[i])) {
                i += 1;
                while (i < sql.len and isWordPart(sql[i])) i += 1;
                try tokens.append(allocator, .{ .tag = .word, .text = sql[start..i], .position = start });
            } else return Error.InvalidCharacter,
        }
    }
    try tokens.append(allocator, .{ .tag = .eof, .text = sql[sql.len..], .position = sql.len });
    return tokens.toOwnedSlice(allocator);
}

test "lexer handles SQL primitives" {
    const tokens = try tokenize(std.testing.allocator, "SELECT name FROM users WHERE age >= 18 AND name = 'A''B';");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(Tag.word, tokens[0].tag);
    try std.testing.expectEqual(Tag.greaterEqual, tokens[6].tag);
    try std.testing.expectEqualStrings("A''B", tokens[11].text);
}

test "lexer rejects hostile inputs fail-closed" {
    // Stray `!` without `=`.
    try std.testing.expectError(Error.InvalidCharacter, tokenize(std.testing.allocator, "SELECT 1 ! 2"));
    // Unterminated string and block comment.
    try std.testing.expectError(Error.UnterminatedString, tokenize(std.testing.allocator, "SELECT 'abc"));
    try std.testing.expectError(Error.UnterminatedComment, tokenize(std.testing.allocator, "SELECT 1 /* nope"));
}

test "lexer tokenizes operators, numbers, and parameters matrix" {
    const tokens = try tokenize(std.testing.allocator, "SELECT 0xFF, 1.5e-3, .25, a || b << 1 >> 2, ?1, :name;");
    defer std.testing.allocator.free(tokens);
    var saw_hex = false;
    var saw_concat = false;
    var saw_param = false;
    for (tokens) |t| {
        if (t.tag == .number and std.mem.eql(u8, t.text, "0xFF")) saw_hex = true;
        if (t.tag == .concat) saw_concat = true;
        if (t.tag == .parameter) saw_param = true;
    }
    try std.testing.expect(saw_hex and saw_concat and saw_param);
    try std.testing.expectEqual(Tag.eof, tokens[tokens.len - 1].tag);
}

test "lexer handles empty input and comments only" {
    const empty = try tokenize(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    try std.testing.expectEqual(Tag.eof, empty[0].tag);
    const comments = try tokenize(std.testing.allocator, "-- hi\n/* x */");
    defer std.testing.allocator.free(comments);
    try std.testing.expectEqual(@as(usize, 1), comments.len);
}
