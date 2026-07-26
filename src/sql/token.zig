const std = @import("std");

pub const Tag = enum {
    word,
    number,
    string,
    parameter,
    comma,
    dot,
    lparen,
    rparen,
    star,
    plus,
    minus,
    slash,
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    semicolon,
    eof,
};

pub const Token = struct {
    tag: Tag,
    text: []const u8,
    position: usize,
};

pub fn eql(token: Token, word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token.text, word);
}

test "token keyword matching ignores case" {
    try std.testing.expect(eql(.{ .tag = .word, .text = "SeLeCt", .position = 0 }, "select"));
}
