const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const Value = @import("../vm/value.zig").Value;

pub const Error = error{ InvalidSql, UnexpectedToken, OutOfMemory } || std.mem.Allocator.Error || lexer.Error;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []Token,
    index: usize = 0,
    next_parameter: usize = 1,
    allocations: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, sql: []const u8) !Parser {
        return .{ .allocator = allocator, .tokens = try lexer.tokenize(allocator, sql), .allocations = .empty };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.tokens);
        self.allocations.deinit(self.allocator);
    }

    fn current(self: *Parser) Token {
        return self.tokens[self.index];
    }
    fn advance(self: *Parser) Token {
        const token = self.current();
        self.index += 1;
        return token;
    }
    fn acceptTag(self: *Parser, tag: Tag) bool {
        if (self.current().tag == tag) {
            self.index += 1;
            return true;
        }
        return false;
    }
    fn acceptWord(self: *Parser, expected: []const u8) bool {
        if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, expected)) {
            self.index += 1;
            return true;
        }
        return false;
    }
    fn requireTag(self: *Parser, tag: Tag) !void {
        if (!self.acceptTag(tag)) return Error.UnexpectedToken;
    }
    fn requireWord(self: *Parser, expected: []const u8) !void {
        if (!self.acceptWord(expected)) return Error.UnexpectedToken;
    }
    fn word(self: *Parser) ![]const u8 {
        if (self.current().tag != .word) return Error.UnexpectedToken;
        return self.advance().text;
    }

    fn qualifiedName(self: *Parser) !struct { table: []const u8, column: []const u8 } {
        const first = try self.word();
        if (self.acceptTag(.dot)) return .{ .table = first, .column = try self.word() };
        return .{ .table = "", .column = first };
    }
    fn copy(self: *Parser, bytes: []const u8) ![]const u8 {
        const result = try self.allocator.dupe(u8, bytes);
        try self.allocations.append(self.allocator, result);
        return result;
    }

    pub fn parse(self: *Parser) !ast.Statement {
        var statement: ast.Statement = undefined;
        if (self.acceptWord("create")) statement = try self.parseCreate() else if (self.acceptWord("drop")) statement = try self.parseDrop() else if (self.acceptWord("insert")) statement = try self.parseInsert() else if (self.acceptWord("select")) statement = try self.parseSelect() else if (self.acceptWord("update")) statement = try self.parseUpdate() else if (self.acceptWord("delete")) statement = try self.parseDelete() else if (self.acceptWord("begin")) {
            _ = self.acceptWord("deferred");
            _ = self.acceptWord("immediate");
            _ = self.acceptWord("exclusive");
            statement = .begin;
        } else if (self.acceptWord("start")) {
            try self.requireWord("transaction");
            statement = .begin;
        } else if (self.acceptWord("commit")) statement = .commit else if (self.acceptWord("rollback")) {
            if (self.acceptWord("to")) statement = .{ .rollback_to = try self.word() } else statement = .rollback;
        } else if (self.acceptWord("savepoint")) statement = .{ .savepoint = try self.word() } else if (self.acceptWord("release")) {
            _ = self.acceptWord("savepoint");
            statement = .{ .release = try self.word() };
        } else return Error.InvalidSql;
        _ = self.acceptTag(.semicolon);
        if (self.current().tag != .eof) {
            ast.deinit(self.allocator, &statement);
            return Error.UnexpectedToken;
        }
        return statement;
    }

    fn parseCreate(self: *Parser) !ast.Statement {
        try self.requireWord("table");
        const if_not_exists = if (self.acceptWord("if")) blk: {
            try self.requireWord("not");
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.word();
        try self.requireTag(.lparen);
        var columns = std.ArrayList(ast.ColumnDef).empty;
        while (true) {
            const column_name = try self.word();
            const type_name = try self.word();
            var primary_key = false;
            var not_null = false;
            var unique = false;
            var foreign_key: ?ast.ForeignKeyDef = null;
            if (self.acceptWord("primary")) {
                try self.requireWord("key");
                primary_key = true;
            }
            if (self.acceptWord("not")) {
                try self.requireWord("null");
                not_null = true;
            }
            if (self.acceptWord("unique")) unique = true;
            if (self.acceptWord("references")) {
                const foreign_table = try self.word();
                try self.requireTag(.lparen);
                const foreign_column = try self.word();
                try self.requireTag(.rparen);
                foreign_key = .{ .table = foreign_table, .column = foreign_column };
            }
            try columns.append(self.allocator, .{ .name = column_name, .type_name = type_name, .primary_key = primary_key, .not_null = not_null, .unique = unique, .foreign_key = foreign_key });
            if (!self.acceptTag(.comma)) break;
        }
        try self.requireTag(.rparen);
        return .{ .create_table = .{ .name = name, .columns = try columns.toOwnedSlice(self.allocator), .if_not_exists = if_not_exists } };
    }

    fn parseDrop(self: *Parser) !ast.Statement {
        try self.requireWord("table");
        return .{ .drop_table = try self.word() };
    }

    fn parseLiteral(self: *Parser) Error!ast.Expr {
        const token = self.current();
        if (token.tag == .parameter) {
            _ = self.advance();
            const index = if (token.text.len > 1) std.fmt.parseInt(usize, token.text[1..], 10) catch self.next_parameter else self.next_parameter;
            if (token.text.len == 1) self.next_parameter += 1;
            return .{ .parameter = index };
        }
        if (token.tag == .number) {
            _ = self.advance();
            if (std.mem.indexOfScalar(u8, token.text, '.')) |_| return .{ .literal = .{ .real = std.fmt.parseFloat(f64, token.text) catch return Error.InvalidSql } };
            return .{ .literal = .{ .integer = std.fmt.parseInt(i64, token.text, 10) catch return Error.InvalidSql } };
        }
        if (token.tag == .string) {
            _ = self.advance();
            return .{ .literal = .{ .text = token.text } };
        }
        if (self.acceptWord("null")) return .{ .literal = .null };
        if (self.acceptWord("true")) return .{ .literal = .{ .integer = 1 } };
        if (self.acceptWord("false")) return .{ .literal = .{ .integer = 0 } };
        if (token.tag == .word) {
            var name = self.advance().text;
            if (self.acceptTag(.dot)) {
                const column = try self.word();
                name = try self.copy(try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, column }));
            }
            if (self.acceptTag(.lparen)) {
                const argument = try self.allocator.create(ast.Expr);
                errdefer self.allocator.destroy(argument);
                argument.* = try self.parseExpr();
                try self.requireTag(.rparen);
                return .{ .function = .{ .name = name, .argument = argument } };
            }
            return .{ .identifier = name };
        }
        return Error.UnexpectedToken;
    }

    fn parseExpr(self: *Parser) Error!ast.Expr {
        if (self.acceptTag(.star)) return .wildcard;
        return self.parseLiteral();
    }

    fn parseInsert(self: *Parser) !ast.Statement {
        try self.requireWord("into");
        const table = try self.word();
        var columns = std.ArrayList([]const u8).empty;
        if (self.acceptTag(.lparen)) {
            while (true) {
                try columns.append(self.allocator, try self.word());
                if (!self.acceptTag(.comma)) break;
            }
            try self.requireTag(.rparen);
        }
        try self.requireWord("values");
        var rows = std.ArrayList([]const ast.Expr).empty;
        while (true) {
            try self.requireTag(.lparen);
            var row = std.ArrayList(ast.Expr).empty;
            while (true) {
                try row.append(self.allocator, try self.parseExpr());
                if (!self.acceptTag(.comma)) break;
            }
            try self.requireTag(.rparen);
            try rows.append(self.allocator, try row.toOwnedSlice(self.allocator));
            if (!self.acceptTag(.comma)) break;
        }
        return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = try rows.toOwnedSlice(self.allocator) } };
    }

    fn parseCondition(self: *Parser) !?ast.Conditions {
        if (!self.acceptWord("where")) return null;
        var conditions = std.ArrayList(ast.Condition).empty;
        var join_or = false;
        while (true) {
            const column = try self.word();
            if (self.acceptWord("is")) {
                const is_not = self.acceptWord("not");
                try self.requireWord("null");
                try conditions.append(self.allocator, .{ .column = column, .op = if (is_not) .is_not_null else .is_null, .value = .{ .literal = .null }, .join_or = join_or });
            } else if (self.acceptWord("between")) {
                const lower = try self.parseExpr();
                try self.requireWord("and");
                try conditions.append(self.allocator, .{ .column = column, .op = .between, .value = lower, .value2 = try self.parseExpr(), .join_or = join_or });
            } else {
                const op: ast.CompareOp = if (self.acceptTag(.equal)) .equal else if (self.acceptTag(.not_equal)) .not_equal else if (self.acceptTag(.less)) .less else if (self.acceptTag(.less_equal)) .less_equal else if (self.acceptTag(.greater)) .greater else if (self.acceptTag(.greater_equal)) .greater_equal else if (self.acceptWord("like")) .like else return Error.UnexpectedToken;
                try conditions.append(self.allocator, .{ .column = column, .op = op, .value = try self.parseExpr(), .join_or = join_or });
            }
            if (self.acceptWord("or")) {
                join_or = true;
            } else if (self.acceptWord("and")) {
                join_or = false;
            } else break;
        }
        return try conditions.toOwnedSlice(self.allocator);
    }

    fn parseSelect(self: *Parser) !ast.Statement {
        var projections = std.ArrayList(ast.Projection).empty;
        const distinct = self.acceptWord("distinct");
        while (true) {
            const expr = try self.parseExpr();
            var alias: ?[]const u8 = null;
            if (self.acceptWord("as")) alias = try self.word();
            try projections.append(self.allocator, .{ .expr = expr, .alias = alias });
            if (!self.acceptTag(.comma)) break;
        }
        var table: ?[]const u8 = null;
        if (self.acceptWord("from")) table = try self.word();
        var join: ?ast.Join = null;
        if (table != null) {
            var kind: ?ast.JoinKind = null;
            if (self.acceptWord("inner")) kind = .inner else if (self.acceptWord("left")) kind = .left else if (self.acceptWord("right")) kind = .right else if (self.acceptWord("full")) kind = .full else if (self.acceptWord("cross")) kind = .cross;
            if (kind != null or self.acceptWord("join")) {
                if (kind != .cross) _ = self.acceptWord("join") else _ = self.acceptWord("join");
                const joined_table = try self.word();
                if (kind != .cross) {
                    try self.requireWord("on");
                    const left = try self.qualifiedName();
                    try self.requireTag(.equal);
                    const right = try self.qualifiedName();
                    join = .{ .kind = kind orelse .inner, .table = joined_table, .left_table = left.table, .left_column = left.column, .right_table = right.table, .right_column = right.column };
                } else join = .{ .kind = .cross, .table = joined_table, .left_table = "", .left_column = "", .right_table = "", .right_column = "" };
            }
        }
        const condition = try self.parseCondition();
        var order: ?ast.Order = null;
        if (self.acceptWord("order")) {
            try self.requireWord("by");
            order = .{ .column = try self.word(), .descending = self.acceptWord("desc") };
            _ = self.acceptWord("asc");
        }
        var limit: ?usize = null;
        if (self.acceptWord("limit")) {
            const token = self.advance();
            limit = std.fmt.parseInt(usize, token.text, 10) catch return Error.InvalidSql;
        }
        var offset: ?usize = null;
        if (self.acceptWord("offset")) {
            const token = self.advance();
            offset = std.fmt.parseInt(usize, token.text, 10) catch return Error.InvalidSql;
        }
        return .{ .select = .{ .projections = try projections.toOwnedSlice(self.allocator), .table = table, .join = join, .condition = condition, .order = order, .limit = limit, .offset = offset, .distinct = distinct } };
    }

    fn parseUpdate(self: *Parser) !ast.Statement {
        const table = try self.word();
        try self.requireWord("set");
        var columns = std.ArrayList([]const u8).empty;
        var values = std.ArrayList(ast.Expr).empty;
        while (true) {
            try columns.append(self.allocator, try self.word());
            try self.requireTag(.equal);
            try values.append(self.allocator, try self.parseExpr());
            if (!self.acceptTag(.comma)) break;
        }
        return .{ .update = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .values = try values.toOwnedSlice(self.allocator), .condition = try self.parseCondition() } };
    }

    fn parseDelete(self: *Parser) !ast.Statement {
        try self.requireWord("from");
        const table = try self.word();
        return .{ .delete = .{ .table = table, .condition = try self.parseCondition() } };
    }
};

test "parser builds insert and select statements" {
    var parser = try Parser.init(std.testing.allocator, "INSERT INTO users (name) VALUES ('A');");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .insert);
}
