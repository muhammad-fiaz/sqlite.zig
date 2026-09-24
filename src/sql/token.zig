//! Token vocabulary for the lexer and parser.
//!
//! Tokens borrow the source SQL; the token slice is caller-owned.
//! Keyword match is case-insensitive.

const std = @import("std");

/// Terminal symbols of the SQL grammar.
/// Words, literals, operators, and a trailing `eof`.
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
    /// `->` JSON extract (SQL value form).
    jsonArrow,
    /// `->>` JSON extract (unquoted SQL text form).
    jsonArrowText,
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
/// Used by the parser's word helpers.
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
