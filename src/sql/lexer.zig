const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;

pub const Error = error{ InvalidCharacter, UnterminatedString, UnterminatedComment };

fn isWordStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;
}
fn isWordPart(byte: u8) bool {
    return isWordStart(byte) or std.ascii.isDigit(byte) or byte == '$';
}

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
                        try tokens.append(allocator, .{ .tag = if (quote == '\'') .string else .word, .text = sql[content..i], .position = start });
                        i += 1;
                        break;
                    }
                } else return Error.UnterminatedString;
            },
            '0'...'9' => {
                i += 1;
                while (i < sql.len and (std.ascii.isDigit(sql[i]) or sql[i] == '.')) i += 1;
                try tokens.append(allocator, .{ .tag = .number, .text = sql[start..i], .position = start });
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
            '.' => {
                try tokens.append(allocator, .{ .tag = .dot, .text = sql[i .. i + 1], .position = i });
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
                try tokens.append(allocator, .{ .tag = .equal, .text = sql[i .. i + 1], .position = i });
                i += 1;
            },
            '<' => {
                i += 1;
                const tag: Tag = if (i < sql.len and sql[i] == '=') blk: {
                    i += 1;
                    break :blk .less_equal;
                } else if (i < sql.len and sql[i] == '>') blk: {
                    i += 1;
                    break :blk .not_equal;
                } else .less;
                try tokens.append(allocator, .{ .tag = tag, .text = sql[start..i], .position = start });
            },
            '>' => {
                i += 1;
                const tag: Tag = if (i < sql.len and sql[i] == '=') blk: {
                    i += 1;
                    break :blk .greater_equal;
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
    try std.testing.expectEqual(Tag.greater_equal, tokens[6].tag);
    try std.testing.expectEqualStrings("A''B", tokens[11].text);
}
