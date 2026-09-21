//! Pure `LIKE`/`GLOB`/`REGEXP`/`MATCH` predicates over byte slices.
//!
//! `LIKE` folds ASCII case (`%` any run, `_` one byte, optional `ESCAPE`);
//! `GLOB` is case-sensitive (`*`, `?`, `[...]` classes); `REGEXP` is a small
//! built-in subset, not PCRE; `MATCH` is a case-insensitive substring test.
//! Pure and infallible; NULL handling stays with the caller.

const std = @import("std");

/// ASCII case-insensitive `LIKE` without an `ESCAPE` clause.
///
/// `pattern` supports `%` (any sequence, possibly empty) and `_` (exactly one
/// byte). Comparison folds both sides with `std.ascii.toLower`.
pub fn like(text: []const u8, pattern: []const u8) bool {
    return likeWithEscape(text, pattern, null);
}

/// ASCII case-insensitive `LIKE` with an optional single-byte `ESCAPE`.
///
/// When `escape` is non-null and the pattern head equals the escape byte, the
/// next pattern byte matches literally (case-insensitively). A trailing lone
/// escape byte matches nothing. A `null` escape behaves like `like`.
pub fn likeWithEscape(text: []const u8, pattern: []const u8, escape: ?u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (escape) |esc| if (pattern[0] == esc) {
        if (pattern.len == 1) return false;
        return text.len != 0 and std.ascii.toLower(pattern[1]) == std.ascii.toLower(text[0]) and likeWithEscape(text[1..], pattern[2..], escape);
    };
    if (pattern[0] == '%') {
        var index: usize = 0;
        while (index <= text.len) : (index += 1) if (likeWithEscape(text[index..], pattern[1..], escape)) return true;
        return false;
    }
    if (pattern[0] == '_') return text.len != 0 and likeWithEscape(text[1..], pattern[1..], escape);
    return text.len != 0 and std.ascii.toLower(pattern[0]) == std.ascii.toLower(text[0]) and likeWithEscape(text[1..], pattern[1..], escape);
}

/// Case-sensitive `GLOB` match.
///
/// Supports `*` (any sequence), `?` (exactly one byte), and `[...]` classes
/// with `^`/`!` negation and `a-b` ranges. An unterminated `[` falls back to a
/// literal `[` comparison.
pub fn glob(text: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;
    if (pattern[0] == '*') return glob(text, pattern[1..]) or (text.len != 0 and glob(text[1..], pattern));
    if (text.len == 0) return false;
    if (pattern[0] == '?') return glob(text[1..], pattern[1..]);
    if (pattern[0] == '[') {
        var i: usize = 1;
        var matched = false;
        var negated = false;
        if (i < pattern.len and (pattern[i] == '^' or pattern[i] == '!')) {
            negated = true;
            i += 1;
        }
        while (i < pattern.len and pattern[i] != ']') : (i += 1) {
            if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                if (text[0] >= pattern[i] and text[0] <= pattern[i + 2]) matched = true;
                i += 2;
            } else if (text[0] == pattern[i]) matched = true;
        }
        if (i >= pattern.len) return text[0] == '[' and glob(text[1..], pattern[1..]);
        if (negated) matched = !matched;
        return matched and glob(text[1..], pattern[i + 1 ..]);
    }
    return text[0] == pattern[0] and glob(text[1..], pattern[1..]);
}

const RegexEngine = struct {
    text: []const u8,
    pattern: []const u8,

    fn matchFull(text: []const u8, pattern: []const u8) bool {
        var engine = RegexEngine{ .text = text, .pattern = pattern };
        if (pattern.len != 0 and pattern[0] == '^') {
            engine.pattern = pattern[1..];
            return engine.matchAt(0, 0);
        }
        var start: usize = 0;
        while (true) {
            var attempt = engine;
            attempt.text = text[start..];
            if (attempt.matchAt(0, 0)) return true;
            if (start >= text.len) return false;
            start += 1;
        }
    }

    fn matchAt(self: *RegexEngine, ti: usize, pi: usize) bool {
        var t = ti;
        var p = pi;
        while (p < self.pattern.len) {
            if (p + 1 < self.pattern.len and self.pattern[p + 1] == '?') {
                if (self.atomMatches(t, p)) {
                    var copy = self.*;
                    if (copy.matchAt(if (t < self.text.len) t + 1 else t, p + 2)) return true;
                }
                p += 2;
                continue;
            }
            if (p + 1 < self.pattern.len and (self.pattern[p + 1] == '*' or self.pattern[p + 1] == '+')) {
                const star = self.pattern[p + 1] == '*';
                var count: usize = 0;
                while (self.atomMatches(t, p)) {
                    t += 1;
                    count += 1;
                    if (t > self.text.len) break;
                }
                var back = count;
                while (true) {
                    var copy = self.*;
                    if (copy.matchAt(t, p + 2)) return true;
                    if (back == 0 or (back == count and !star and count == 0)) break;
                    if (back == 0) break;
                    if (t == 0) break;
                    t -= 1;
                    back -= 1;
                    if (!star and back == 0) {
                        var once = self.*;
                        if (once.matchAt(t + 1, p + 2)) return true;
                        break;
                    }
                }
                return false;
            }
            if (p < self.pattern.len and self.pattern[p] == '$' and p + 1 == self.pattern.len) return t == self.text.len;
            if (self.pattern[p] == '|') return false;
            if (!self.atomMatches(t, p)) return false;
            t += 1;
            if (t > self.text.len) return false;
            p = self.atomNext(p);
        }
        return true;
    }

    fn atomNext(self: *RegexEngine, p: usize) usize {
        if (self.pattern[p] == '[') {
            var i = p + 1;
            if (i < self.pattern.len and self.pattern[i] == '^') i += 1;
            if (i < self.pattern.len and self.pattern[i] == ']') i += 1;
            while (i < self.pattern.len and self.pattern[i] != ']') : (i += 1) {}
            return @min(i + 1, self.pattern.len);
        }
        if (self.pattern[p] == '\\' and p + 1 < self.pattern.len) return p + 2;
        return p + 1;
    }

    fn atomMatches(self: *RegexEngine, t: usize, p: usize) bool {
        if (p >= self.pattern.len) return false;
        const c = self.pattern[p];
        if (c == '$' and p + 1 == self.pattern.len) return t == self.text.len;
        if (t >= self.text.len) return false;
        const tc = self.text[t];
        if (c == '.') return true;
        if (c == '[') {
            var i = p + 1;
            var neg = false;
            if (i < self.pattern.len and self.pattern[i] == '^') {
                neg = true;
                i += 1;
            }
            var hit = false;
            while (i < self.pattern.len and self.pattern[i] != ']') {
                if (i + 2 < self.pattern.len and self.pattern[i + 1] == '-' and self.pattern[i + 2] != ']') {
                    if (tc >= self.pattern[i] and tc <= self.pattern[i + 2]) hit = true;
                    i += 3;
                } else {
                    if (tc == self.pattern[i]) hit = true;
                    i += 1;
                }
            }
            return if (neg) !hit else hit;
        }
        if (c == '\\' and p + 1 < self.pattern.len) {
            const e = self.pattern[p + 1];
            if (e == 'd') return tc >= '0' and tc <= '9';
            if (e == 'w') return std.ascii.isAlphanumeric(tc) or tc == '_';
            if (e == 's') return tc == ' ' or tc == '\t' or tc == '\n' or tc == '\r';
            return tc == e;
        }
        return tc == c;
    }
};

/// Subset `REGEXP` predicate (unanchored search).
///
/// Supports `.`, `[...]` classes (with `^` negation and `a-b` ranges),
/// `\d`/`\w`/`\s` and escaped literals, `?`/`*`/`+` quantifiers, `^`/`$`
/// anchors, top-level `|` alternation (split on the first `|`), and
/// parenthesised group probing. Anything outside this subset (e.g. `{m,n}`
/// counts, non-greedy modifiers, backreferences, lookarounds) is out of scope
/// and may not match PCRE/SQLite extension behaviour.
pub fn regexp(text: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '|')) |bar| {
        if (regexp(text, pattern[0..bar])) return true;
        return regexp(text, pattern[bar + 1 ..]);
    }
    var depth: usize = 0;
    var start: ?usize = null;
    var pi: usize = 0;
    while (pi < pattern.len) : (pi += 1) {
        if (pattern[pi] == '(') {
            if (depth == 0) start = pi;
            depth += 1;
        } else if (pattern[pi] == ')') {
            if (depth > 0) {
                depth -= 1;
                if (depth == 0) {
                    if (regexp(text, pattern[start.? + 1 .. pi])) return true;
                }
            }
        }
    }
    return RegexEngine.matchFull(text, pattern);
}

/// Case-insensitive substring predicate backing `MATCH` expressions.
///
/// Returns `true` when `needle` occurs in `haystack` under ASCII folding; an
/// empty needle matches anything. SQLite proper reserves `MATCH` for FTS
/// modules — this fallback exists so non-FTS `MATCH` predicates have defined,
/// testable semantics in this engine.
pub fn match(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |b, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(b)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

test "like is ascii case-insensitive with percent and underscore" {
    try std.testing.expect(like("Hello World", "hello%"));
    try std.testing.expect(like("abc", "A_C"));
    try std.testing.expect(!like("abcd", "A_C"));
    try std.testing.expect(like("", "%"));
    try std.testing.expect(like("", ""));
    try std.testing.expect(!like("a", ""));
    try std.testing.expect(like("aaa", "%a%a%a%"));
}

test "like escape makes wildcards literal" {
    try std.testing.expect(likeWithEscape("a%b", "a\\%b", '\\'));
    try std.testing.expect(!likeWithEscape("axb", "a\\%b", '\\'));
    try std.testing.expect(likeWithEscape("a_b", "a\\_b", '\\'));
    try std.testing.expect(!likeWithEscape("ab", "a\\", '\\'));
    try std.testing.expect(like("a%b", "a%b") == likeWithEscape("a%b", "a%b", null));
}

test "glob is case-sensitive with star question and classes" {
    try std.testing.expect(glob("hello", "h*o"));
    try std.testing.expect(!glob("Hello", "h*o"));
    try std.testing.expect(glob("abc", "a?c"));
    try std.testing.expect(!glob("ac", "a?c"));
    try std.testing.expect(glob("b", "[abc]"));
    try std.testing.expect(!glob("d", "[abc]"));
    try std.testing.expect(glob("d", "[^abc]"));
    try std.testing.expect(glob("f", "[a-z]"));
    try std.testing.expect(glob("[", "["));
}

test "regexp subset supports anchors classes and alternation" {
    try std.testing.expect(regexp("abc123", "c123"));
    try std.testing.expect(regexp("abc123", ".*[0-9]"));
    try std.testing.expect(regexp("aaab", "a+b"));
    try std.testing.expect(regexp("ab", "a?b"));
    try std.testing.expect(!regexp("hello!", "^h.llo$"));
    try std.testing.expect(regexp("cat", "cat|dog"));
    try std.testing.expect(regexp("dog", "cat|dog"));
    try std.testing.expect(!regexp("bird", "cat|dog"));
    try std.testing.expect(regexp("a1", "a\\d"));
    try std.testing.expect(!regexp("ab", "a\\d"));
}

test "match is a case-insensitive substring fallback" {
    try std.testing.expect(match("Hello World", "world"));
    try std.testing.expect(match("anything", ""));
    try std.testing.expect(!match("short", "longer needle"));
    try std.testing.expect(!match("abc", "ABD"));
}
