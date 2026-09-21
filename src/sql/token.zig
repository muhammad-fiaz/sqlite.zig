//! SQL token vocabulary for the sqlite.zig frontend.
//!
//! Purpose: defines the smallest lexical units produced by `lexer.zig` and
//! consumed by `parser.zig`. This is stage 1 of the
//! lexer -> parser -> AST -> resolver -> planner -> compiler -> VM pipeline.
//! DSL builders construct native `ast.zig` nodes directly and never go
//! through this token layer.
//!
//! Responsibilities:
//! - Enumerate every terminal the grammar needs (`Tag`).
//! - Carry the source slice (`text`), byte offset (`position`), and whether a
//!   `word` came from a quoted identifier (`quoted`) so the parser can treat
//!   quoted keywords as identifiers (SQLite semantics).
//!
//! Dependencies: `std.ascii` only. No allocation, no I/O.
//!
//! Ownership/lifetime: `Token.text` borrows the original SQL string; tokens
//! never own memory. The token slice itself is owned by the caller of
//! `lexer.tokenize`.
//!
//! Error behavior: infallible; keyword comparison is ASCII case-insensitive.
//!
//! Invariants:
//! - `text` is always a subslice of the input SQL (except the trailing `eof`
//!   token whose text is the empty slice at `sql.len`).
//! - `quoted == true` implies `tag == .word` (double-quote/backtick path).
//!
//! SQLite compatibility: single `=` and double `==` both map to `.equal`;
//! `<>` and `!=` both map to `.notEqual`, matching SQLite's accepted forms.

const std = @import("std");

/// Terminal symbols of the SQL grammar.
///
/// A minimal vocabulary: identifiers/keywords share `.word` (the parser
/// distinguishes them case-insensitively), literals are `.number`/`.string`,
/// and every single- or multi-character operator the parser needs has its own
/// tag. `eof` is always the final token.
pub const Tag = enum {
    /// Identifier or keyword (quoted identifiers included; see `Token.quoted`).
    word,
    /// Integer, float, hex-integer, or exponent literal; raw text kept verbatim.
    number,
    /// Single-quoted string literal with `''` escapes already noted in text.
    string,
    /// `?`, `?NNN`, `:name`, `@name`, or `$name` placeholder.
    parameter,
    /// `,`
    comma,
    /// `.` (member access / qualifier separator).
    dot,
    /// `(`
    lparen,
    /// `)`
    rparen,
    /// `*` (also overloaded as multiply; parser disambiguates by context).
    star,
    /// `+`
    plus,
    /// `-`
    minus,
    /// `/`
    slash,
    /// `%`
    percent,
    /// `&`
    amp,
    /// `|` (single pipe; `||` is `.concat`).
    pipe,
    /// `~`
    tilde,
    /// `||` string concatenation operator.
    concat,
    /// `<<`
    lshift,
    /// `>>`
    rshift,
    /// `=` or `==`
    equal,
    /// `!=` or `<>`
    notEqual,
    /// `<`
    less,
    /// `<=`
    lessEqual,
    /// `>`
    greater,
    /// `>=`
    greaterEqual,
    /// `;` statement terminator.
    semicolon,
    /// End of input sentinel; always present as the last token.
    eof,
};

/// A single lexical unit: tag plus a borrow into the source SQL.
///
/// `quoted` is true only for double-quoted/backtick words (`"name"`, `` `name` ``),
/// which the parser must treat as identifiers even when they spell keywords.
pub const Token = struct {
    /// Grammar terminal carried by this token.
    tag: Tag,
    /// Source slice for this token (unescaped content for quoted forms).
    text: []const u8,
    /// Byte offset of the token start in the original SQL string.
    position: usize,
    /// True when a `.word` token came from `"..."` or `` `...` `` quoting.
    quoted: bool = false,
};

/// Case-insensitive keyword comparison for `.word` tokens.
///
/// Used by the parser's `acceptWord`/`requireWord` helpers. Non-word tokens
/// can also be compared (their `text` is the operator spelling) but callers
/// conventionally check `tag` first.
pub fn eql(token: Token, word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token.text, word);
}

test "token keyword matching ignores case" {
    try std.testing.expect(eql(.{ .tag = .word, .text = "SeLeCt", .position = 0 }, "select"));
}

test "token quoted flag distinguishes identifiers from keywords" {
    const quoted: Token = .{ .tag = .word, .text = "select", .position = 0, .quoted = true };
    const bare: Token = .{ .tag = .word, .text = "select", .position = 0, .quoted = false };
    // Both spell the keyword, but only the bare form may act as one.
    try std.testing.expect(eql(quoted, "SELECT"));
    try std.testing.expect(eql(bare, "SELECT"));
    try std.testing.expect(quoted.quoted);
    try std.testing.expect(!bare.quoted);
}

test "token operator spellings round-trip through eql" {
    const eq: Token = .{ .tag = .equal, .text = "==", .position = 0 };
    const ne: Token = .{ .tag = .notEqual, .text = "<>", .position = 0 };
    try std.testing.expect(eql(eq, "=="));
    try std.testing.expect(eql(ne, "<>"));
    try std.testing.expect(!eql(eq, "=") or eql(eq, "==")); // documents raw-text compare
}
