const std = @import("std");
const Token = @import("token.zig").Token;
const Tag = @import("token.zig").Tag;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const Value = @import("../vm/value.zig").Value;

fn freeParserExpr(allocator: std.mem.Allocator, expr: ast.Expr) void {
    switch (expr) {
        .function => |call| {
            freeParserExpr(allocator, call.argument.*);
            allocator.destroy(call.argument);
            if (call.argument2) |argument| { freeParserExpr(allocator, argument.*); allocator.destroy(argument); }
            if (call.argument3) |argument| { freeParserExpr(allocator, argument.*); allocator.destroy(argument); }
        },
        .binary => |binary| {
            freeParserExpr(allocator, binary.left.*);
            freeParserExpr(allocator, binary.right.*);
            allocator.destroy(binary.left);
            allocator.destroy(binary.right);
        },
        else => {},
    }
}
pub const Error = error{ InvalidSql, UnexpectedToken, OutOfMemory } || std.mem.Allocator.Error || lexer.Error;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []Token,
    index: usize = 0,
    next_parameter: usize = 1,
    allocations: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, sql: []const u8) !Parser {
        return .{ .allocator = allocator, .source = sql, .tokens = try lexer.tokenize(allocator, sql), .allocations = .empty };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.tokens);
        for (self.allocations.items) |allocation| self.allocator.free(allocation);
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
        if (self.acceptWord("pragma")) {
            const pragma_name = try self.word();
            var pragma_value: ?[]const u8 = null;
            if (self.acceptTag(.equal)) {
                const token = self.current();
                if (token.tag != .word and token.tag != .number and token.tag != .string) return Error.UnexpectedToken;
                _ = self.advance();
                pragma_value = token.text;
            }
            statement = .{ .pragma = .{ .name = pragma_name, .value = pragma_value } };
        } else if (self.acceptWord("with")) statement = try self.parseWith() else if (self.acceptWord("explain")) {
            try self.requireWord("query");
            try self.requireWord("plan");
            const start = self.current().position;
            try self.requireWord("select");
            var query = try self.parseSelect();
            defer ast.deinit(self.allocator, &query);
            const end = self.current().position;
            statement = .{ .explain_query_plan = try self.copy(self.source[start..end]) };
        } else if (self.acceptWord("create")) statement = try self.parseCreate() else if (self.acceptWord("drop")) statement = try self.parseDrop() else if (self.acceptWord("alter")) statement = try self.parseAlter() else if (self.acceptWord("insert")) statement = try self.parseInsert() else if (self.acceptWord("select")) statement = try self.parseSelect() else if (self.acceptWord("update")) statement = try self.parseUpdate() else if (self.acceptWord("delete")) statement = try self.parseDelete() else if (self.acceptWord("begin")) {
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

    fn parseWith(self: *Parser) !ast.Statement {
        const recursive = self.acceptWord("recursive");
        var ctes = std.ArrayList(ast.CteDef).empty;
        errdefer ctes.deinit(self.allocator);
        while (true) {
            const name = try self.word();
            if (self.acceptTag(.lparen)) {
                while (true) {
                    _ = try self.word();
                    if (!self.acceptTag(.comma)) break;
                }
                try self.requireTag(.rparen);
            }
            try self.requireWord("as");
            try self.requireTag(.lparen);
            const query_start = self.current().position;
            try self.requireWord("select");
            var query_statement = try self.parseSelect();
            defer ast.deinit(self.allocator, &query_statement);
            const query_end = self.current().position;
            var recursive_sql: ?[]const u8 = null;
            if (self.acceptWord("union")) {
                _ = self.acceptWord("all");
                const recursive_start = self.current().position;
                try self.requireWord("select");
                var recursive_statement = try self.parseSelect();
                defer ast.deinit(self.allocator, &recursive_statement);
                const recursive_end = self.current().position;
                recursive_sql = try self.copy(self.source[recursive_start..recursive_end]);
            }
            try self.requireTag(.rparen);
            try ctes.append(self.allocator, .{ .name = name, .query_sql = try self.copy(self.source[query_start..query_end]), .recursive_sql = recursive_sql });
            if (!self.acceptTag(.comma)) break;
        }
        const body_start = self.current().position;
        try self.requireWord("select");
        var body_statement = try self.parseSelect();
        defer ast.deinit(self.allocator, &body_statement);
        const body_end = self.current().position;
        return .{ .with_select = .{ .ctes = try ctes.toOwnedSlice(self.allocator), .body_sql = try self.copy(self.source[body_start..body_end]), .recursive = recursive } };
    }

    fn parseCreate(self: *Parser) !ast.Statement {
        if (self.acceptWord("trigger")) return self.parseTrigger();
        if (self.acceptWord("virtual")) {
            try self.requireWord("table");
            const if_not_exists = if (self.acceptWord("if")) blk: {
                try self.requireWord("not");
                try self.requireWord("exists");
                break :blk true;
            } else false;
            const name = try self.word();
            try self.requireWord("using");
            const module = try self.word();
            try self.requireTag(.lparen);
            var arguments = std.ArrayList([]const u8).empty;
            errdefer arguments.deinit(self.allocator);
            if (!self.acceptTag(.rparen)) {
                while (true) {
                    const token = self.current();
                    if (token.tag != .number and token.tag != .word and token.tag != .string and token.tag != .parameter) return Error.UnexpectedToken;
                    _ = self.advance();
                    try arguments.append(self.allocator, token.text);
                    if (!self.acceptTag(.comma)) break;
                }
                try self.requireTag(.rparen);
            }
            return .{ .create_virtual_table = .{ .name = name, .module = module, .arguments = try arguments.toOwnedSlice(self.allocator), .if_not_exists = if_not_exists } };
        }
        if (self.acceptWord("view")) {
            const if_not_exists = if (self.acceptWord("if")) blk: {
                try self.requireWord("not");
                try self.requireWord("exists");
                break :blk true;
            } else false;
            const name = try self.word();
            try self.requireWord("as");
            const start = self.current().position;
            try self.requireWord("select");
            var select_statement = try self.parseSelect();
            defer ast.deinit(self.allocator, &select_statement);
            if (select_statement != .select) {
                return Error.InvalidSql;
            }
            const end = self.current().position;
            return .{ .create_view = .{ .name = name, .sql = try self.copy(self.source[start..end]), .if_not_exists = if_not_exists } };
        }
        if (self.acceptWord("unique")) {
            try self.requireWord("index");
            return self.parseIndex(true);
        }
        if (self.acceptWord("index")) return self.parseIndex(false);
        try self.requireWord("table");
        const if_not_exists = if (self.acceptWord("if")) blk: {
            try self.requireWord("not");
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.word();
        try self.requireTag(.lparen);
        var columns = std.ArrayList(ast.ColumnDef).empty;
        errdefer columns.deinit(self.allocator);
        var constraints = std.ArrayList(ast.TableConstraint).empty;
        errdefer {
            for (constraints.items) |constraint| switch (constraint) {
                .primary_key => |names| self.allocator.free(names),
                .unique => |names| self.allocator.free(names),
                .foreign_key => |foreign_key| {
                    self.allocator.free(foreign_key.columns);
                    self.allocator.free(foreign_key.referenced_columns);
                },
            };
            constraints.deinit(self.allocator);
        }
        while (true) {
            if (self.current().tag == .word and (std.ascii.eqlIgnoreCase(self.current().text, "primary") or std.ascii.eqlIgnoreCase(self.current().text, "unique") or std.ascii.eqlIgnoreCase(self.current().text, "foreign") or std.ascii.eqlIgnoreCase(self.current().text, "constraint"))) {
                if (self.acceptWord("constraint")) _ = try self.word();
                if (self.acceptWord("foreign")) {
                    try self.requireWord("key");
                    try self.requireTag(.lparen);
                    var child_columns = std.ArrayList([]const u8).empty;
                    errdefer child_columns.deinit(self.allocator);
                    while (true) {
                        try child_columns.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    try self.requireWord("references");
                    const foreign_table = try self.word();
                    try self.requireTag(.lparen);
                    var parent_columns = std.ArrayList([]const u8).empty;
                    errdefer parent_columns.deinit(self.allocator);
                    while (true) {
                        try parent_columns.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    if (child_columns.items.len == 0 or child_columns.items.len != parent_columns.items.len) return Error.InvalidSql;
                    var on_delete: ast.ReferentialAction = .restrict;
                    var on_update: ast.ReferentialAction = .restrict;
                    while (self.acceptWord("on")) {
                        const action = if (self.acceptWord("delete")) blk: {
                            break :blk &on_delete;
                        } else if (self.acceptWord("update")) blk: {
                            break :blk &on_update;
                        } else return Error.UnexpectedToken;
                        action.* = if (self.acceptWord("cascade")) .cascade else if (self.acceptWord("set")) blk: {
                            try self.requireWord("null");
                            break :blk .set_null;
                        } else if (self.acceptWord("restrict")) .restrict else return Error.UnexpectedToken;
                    }
                    try constraints.append(self.allocator, .{ .foreign_key = .{ .columns = try child_columns.toOwnedSlice(self.allocator), .table = foreign_table, .referenced_columns = try parent_columns.toOwnedSlice(self.allocator), .on_delete = on_delete, .on_update = on_update } });
                } else {
                    const kind: enum { primary_key, unique } = if (self.acceptWord("primary")) blk: {
                        try self.requireWord("key");
                        break :blk .primary_key;
                    } else if (self.acceptWord("unique")) .unique else return Error.UnexpectedToken;
                    try self.requireTag(.lparen);
                    var names = std.ArrayList([]const u8).empty;
                    errdefer names.deinit(self.allocator);
                    while (true) {
                        try names.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    if (names.items.len == 0) return Error.InvalidSql;
                    const owned_names = try names.toOwnedSlice(self.allocator);
                    try constraints.append(self.allocator, switch (kind) {
                        .primary_key => .{ .primary_key = owned_names },
                        .unique => .{ .unique = owned_names },
                    });
                }
                if (!self.acceptTag(.comma)) break;
                continue;
            }
            const column_name = try self.word();
            const type_name = try self.word();
            var primary_key = false;
            var not_null = false;
            var unique = false;
            var foreign_key: ?ast.ForeignKeyDef = null;
            var default_value: ?Value = null;
            if (self.acceptWord("primary")) {
                try self.requireWord("key");
                primary_key = true;
            }
            if (self.acceptWord("not")) {
                try self.requireWord("null");
                not_null = true;
            }
            if (self.acceptWord("unique")) unique = true;
            if (self.acceptWord("default")) {
                const expression = try self.parseExpr();
                default_value = switch (expression) {
                    .literal => |value| value,
                    else => return Error.InvalidSql,
                };
            }
            if (self.acceptWord("references")) {
                const foreign_table = try self.word();
                try self.requireTag(.lparen);
                const foreign_column = try self.word();
                try self.requireTag(.rparen);
                var on_delete: ast.ReferentialAction = .restrict;
                var on_update: ast.ReferentialAction = .restrict;
                while (self.acceptWord("on")) {
                    const action = if (self.acceptWord("delete")) blk: {
                        break :blk &on_delete;
                    } else if (self.acceptWord("update")) blk: {
                        break :blk &on_update;
                    } else return Error.UnexpectedToken;
                    action.* = if (self.acceptWord("cascade")) .cascade else if (self.acceptWord("set")) blk: {
                        try self.requireWord("null");
                        break :blk .set_null;
                    } else if (self.acceptWord("restrict")) .restrict else return Error.UnexpectedToken;
                }
                foreign_key = .{ .table = foreign_table, .column = foreign_column, .on_delete = on_delete, .on_update = on_update };
            }
            try columns.append(self.allocator, .{ .name = column_name, .type_name = type_name, .primary_key = primary_key, .not_null = not_null, .unique = unique, .foreign_key = foreign_key, .default_value = default_value });
            if (!self.acceptTag(.comma)) break;
        }
        try self.requireTag(.rparen);
        return .{ .create_table = .{ .name = name, .columns = try columns.toOwnedSlice(self.allocator), .constraints = try constraints.toOwnedSlice(self.allocator), .if_not_exists = if_not_exists } };
    }

    fn parseIndex(self: *Parser, unique: bool) !ast.Statement {
        const if_not_exists = if (self.acceptWord("if")) blk: {
            try self.requireWord("not");
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.word();
        try self.requireWord("on");
        const table = try self.word();
        try self.requireTag(.lparen);
        var columns = std.ArrayList([]const u8).empty;
        while (true) {
            try columns.append(self.allocator, try self.word());
            if (!self.acceptTag(.comma)) break;
        }
        try self.requireTag(.rparen);
        return .{ .create_index = .{ .name = name, .table = table, .columns = try columns.toOwnedSlice(self.allocator), .unique = unique, .if_not_exists = if_not_exists } };
    }

    fn parseTrigger(self: *Parser) !ast.Statement {
        const if_not_exists = if (self.acceptWord("if")) blk: {
            try self.requireWord("not");
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.word();
        try self.requireWord("after");
        const event: ast.TriggerEvent = if (self.acceptWord("insert")) .insert else if (self.acceptWord("update")) .update else if (self.acceptWord("delete")) .delete else return Error.UnexpectedToken;
        try self.requireWord("on");
        const table = try self.word();
        try self.requireWord("begin");
        const body_start = self.current().position;
        while (self.current().tag != .eof and !(self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "end"))) _ = self.advance();
        if (self.current().tag == .eof or self.current().position == body_start) return Error.UnexpectedToken;
        const body_end = self.current().position;
        _ = self.advance();
        return .{ .create_trigger = .{ .name = name, .table = table, .event = event, .body = try self.copy(self.source[body_start..body_end]), .if_not_exists = if_not_exists } };
    }

    fn parseDrop(self: *Parser) !ast.Statement {
        const kind: enum { table, index, view, trigger } = if (self.acceptWord("table")) .table else if (self.acceptWord("index")) .index else if (self.acceptWord("view")) .view else if (self.acceptWord("trigger")) .trigger else return Error.UnexpectedToken;
        const if_exists = if (self.acceptWord("if")) blk: {
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.word();
        return switch (kind) {
            .table => .{ .drop_table = .{ .name = name, .if_exists = if_exists } },
            .index => .{ .drop_index = .{ .name = name, .if_exists = if_exists } },
            .view => .{ .drop_view = .{ .name = name, .if_exists = if_exists } },
            .trigger => .{ .drop_trigger = .{ .name = name, .if_exists = if_exists } },
        };
    }

    fn parseAlter(self: *Parser) !ast.Statement {
        try self.requireWord("table");
        const table = try self.word();
        if (self.acceptWord("add")) {
            _ = self.acceptWord("column");
            const name = try self.word();
            const type_name = if (self.current().tag == .word) try self.word() else "";
            return .{ .alter_table = .{ .add_column = .{ .table = table, .definition = .{ .name = name, .type_name = type_name } } } };
        }
        if (self.acceptWord("rename")) {
            if (self.acceptWord("to")) return .{ .alter_table = .{ .rename_table = .{ .table = table, .new_name = try self.word() } } };
            try self.requireWord("column");
            const old_name = try self.word();
            try self.requireWord("to");
            return .{ .alter_table = .{ .rename_column = .{ .table = table, .old_name = old_name, .new_name = try self.word() } } };
        }
        if (self.acceptWord("drop")) {
            _ = self.acceptWord("column");
            return .{ .alter_table = .{ .drop_column = .{ .table = table, .column = try self.word() } } };
        }
        return Error.UnexpectedToken;
    }

    fn parseLiteral(self: *Parser) Error!ast.Expr {
        if (self.acceptTag(.minus)) {
            const inner = try self.parseLiteral();
            return switch (inner) {
                .literal => |value| switch (value) {
                    .integer => |n| .{ .literal = .{ .integer = -n } },
                    .real => |n| .{ .literal = .{ .real = -n } },
                    else => return Error.InvalidSql,
                },
                else => {
                    freeParserExpr(self.allocator, inner);
                    return Error.InvalidSql;
                },
            };
        }
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
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, column });
                defer self.allocator.free(qualified);
                name = try self.copy(qualified);
            }
            if (self.acceptTag(.lparen)) {
                const argument = try self.allocator.create(ast.Expr);
                errdefer self.allocator.destroy(argument);
                argument.* = try self.parseExpr();
                if (std.ascii.eqlIgnoreCase(name, "cast")) {
                    try self.requireWord("as");
                    const target = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(target);
                    target.* = .{ .identifier = try self.copy(try self.word()) };
                    try self.requireTag(.rparen);
                    return .{ .function = .{ .name = name, .argument = argument, .argument2 = target } };
                }
                var argument2: ?*const ast.Expr = null;
                var argument3: ?*const ast.Expr = null;
                if (self.acceptTag(.comma)) {
                    const second = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(second);
                    second.* = try self.parseExpr();
                    argument2 = second;
                    if (self.acceptTag(.comma)) {
                        const third = try self.allocator.create(ast.Expr);
                        errdefer self.allocator.destroy(third);
                        third.* = try self.parseExpr();
                        argument3 = third;
                    }
                }
                try self.requireTag(.rparen);
                return .{ .function = .{ .name = name, .argument = argument, .argument2 = argument2, .argument3 = argument3 } };
            }
            return .{ .identifier = name };
        }
        return Error.UnexpectedToken;
    }

    fn parseExpr(self: *Parser) Error!ast.Expr {
        if (self.acceptTag(.star)) return .wildcard;
        var left = try self.parseLiteral();
        while (self.current().tag == .plus or self.current().tag == .minus) {
            const op: ast.BinaryOp = if (self.acceptTag(.plus)) .add else blk: {
                _ = self.acceptTag(.minus);
                break :blk .subtract;
            };
            const left_node = try self.allocator.create(ast.Expr);
            left_node.* = left;
            const right_node = try self.allocator.create(ast.Expr);
            right_node.* = try self.parseLiteral();
            left = .{ .binary = .{ .op = op, .left = left_node, .right = right_node } };
        }
        return left;
    }

    fn parseInsert(self: *Parser) !ast.Statement {
        var conflict: ast.InsertConflict = .none;
        var upsert_columns: []const []const u8 = &.{};
        var upsert_values: []const ast.Expr = &.{};
        var upsert_where: ?ast.Conditions = null;
        if (self.acceptWord("or")) {
            if (self.acceptWord("ignore")) conflict = .ignore else if (self.acceptWord("replace")) conflict = .replace else return Error.UnexpectedToken;
        }
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
        if (self.acceptWord("default")) {
            try self.requireWord("values");
            const empty_row = try self.allocator.alloc(ast.Expr, 0);
            var default_rows = try self.allocator.alloc([]const ast.Expr, 1);
            default_rows[0] = empty_row;
            return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = default_rows, .conflict = conflict } };
        }
        if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
            const select_start = self.current().position;
            _ = self.advance();
            var query = try self.parseSelect();
            defer ast.deinit(self.allocator, &query);
            const select_end = self.current().position;
            const empty_rows = try self.allocator.alloc([]const ast.Expr, 0);
            if (self.acceptWord("on")) {
                try self.requireWord("conflict");
                if (self.acceptTag(.lparen)) {
                    while (true) {
                        _ = try self.word();
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                }
                try self.requireWord("do");
                if (self.acceptWord("nothing")) {
                    conflict = .ignore;
                } else {
                    try self.requireWord("update");
                    try self.requireWord("set");
                    var names = std.ArrayList([]const u8).empty;
                    var expressions = std.ArrayList(ast.Expr).empty;
                    while (true) {
                        try names.append(self.allocator, try self.word());
                        try self.requireTag(.equal);
                        try expressions.append(self.allocator, try self.parseExpr());
                        if (!self.acceptTag(.comma)) break;
                    }
                    upsert_columns = try names.toOwnedSlice(self.allocator);
                    upsert_values = try expressions.toOwnedSlice(self.allocator);
                    conflict = .update;
                    if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) upsert_where = try self.parseCondition();
                }
            }
            return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = empty_rows, .select_sql = try self.copy(self.source[select_start..select_end]), .conflict = conflict, .upsert_where = upsert_where } };
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
        if (self.acceptWord("on")) {
            try self.requireWord("conflict");
            if (self.acceptTag(.lparen)) {
                while (true) {
                    _ = try self.word();
                    if (!self.acceptTag(.comma)) break;
                }
                try self.requireTag(.rparen);
            }
            try self.requireWord("do");
            if (self.acceptWord("nothing")) {
                conflict = .ignore;
            } else {
                try self.requireWord("update");
                try self.requireWord("set");
                var names = std.ArrayList([]const u8).empty;
                var expressions = std.ArrayList(ast.Expr).empty;
                while (true) {
                    try names.append(self.allocator, try self.word());
                    try self.requireTag(.equal);
                    try expressions.append(self.allocator, try self.parseExpr());
                    if (!self.acceptTag(.comma)) break;
                }
                upsert_columns = try names.toOwnedSlice(self.allocator);
                upsert_values = try expressions.toOwnedSlice(self.allocator);
                conflict = .update;
                if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) upsert_where = try self.parseCondition();
            }
        }
        return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = try rows.toOwnedSlice(self.allocator), .conflict = conflict, .upsert_columns = upsert_columns, .upsert_values = upsert_values, .upsert_where = upsert_where } };
    }

    fn parseCondition(self: *Parser) anyerror!?ast.Conditions {
        if (!self.acceptWord("where")) return null;
        var conditions = std.ArrayList(ast.Condition).empty;
        var join_or = false;
        while (true) {
            if (self.acceptWord("not")) {
                if (self.acceptWord("exists")) {
                    try self.requireTag(.lparen);
                    const start = self.current().position;
                    try self.requireWord("select");
                    var subquery = try self.parseSelect();
                    defer ast.deinit(self.allocator, &subquery);
                    const end = self.current().position;
                    try self.requireTag(.rparen);
                    try conditions.append(self.allocator, .{ .column = "", .op = .not_exists, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .join_or = join_or });
                } else {
                    return Error.UnexpectedToken;
                }
            } else if (self.acceptWord("exists")) {
                try self.requireTag(.lparen);
                const start = self.current().position;
                try self.requireWord("select");
                var subquery = try self.parseSelect();
                defer ast.deinit(self.allocator, &subquery);
                const end = self.current().position;
                try self.requireTag(.rparen);
                try conditions.append(self.allocator, .{ .column = "", .op = .exists, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .join_or = join_or });
            } else {
                var left_expr: ?ast.Expr = null;
                var column: []const u8 = undefined;
                if (self.current().tag == .word and self.index + 1 < self.tokens.len and self.tokens[self.index + 1].tag == .lparen) {
                    left_expr = try self.parseLiteral();
                    column = "";
                } else {
                    const qualified = try self.qualifiedName();
                    column = if (qualified.table.len == 0) qualified.column else blk: {
                        const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ qualified.table, qualified.column });
                        defer self.allocator.free(combined);
                        break :blk try self.copy(combined);
                    };
                }
                if (self.acceptWord("is")) {
                    const is_not = self.acceptWord("not");
                    if (self.acceptWord("null")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = if (is_not) .is_not_null else .is_null, .value = .{ .literal = .null }, .join_or = join_or });
                    } else if (self.acceptWord("distinct")) {
                        try self.requireWord("from");
                        try conditions.append(self.allocator, .{ .column = column, .op = if (is_not) .is_not_distinct else .is_distinct, .value = try self.parseExpr(), .join_or = join_or, .left_expr = left_expr });
                    } else {
                        try conditions.append(self.allocator, .{ .column = column, .op = if (is_not) .is_not_value else .is_value, .value = try self.parseExpr(), .join_or = join_or });
                    }
                } else if (self.acceptWord("between")) {
                    const lower = try self.parseExpr();
                    try self.requireWord("and");
                    try conditions.append(self.allocator, .{ .column = column, .op = .between, .value = lower, .value2 = try self.parseExpr(), .join_or = join_or });
                } else if (self.acceptWord("not")) {
                    if (self.acceptWord("like")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = .not_like, .value = try self.parseExpr(), .join_or = join_or });
                    } else if (self.acceptWord("glob")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = .not_glob, .value = try self.parseExpr(), .join_or = join_or });
                    } else {
                        try self.requireWord("in");
                        try self.requireTag(.lparen);
                        if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
                            const start = self.current().position;
                            try self.requireWord("select");
                            var subquery = try self.parseSelect();
                            defer ast.deinit(self.allocator, &subquery);
                            const end = self.current().position;
                            try self.requireTag(.rparen);
                            try conditions.append(self.allocator, .{ .column = column, .op = .not_in, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .join_or = join_or });
                        } else {
                            var values = std.ArrayList(ast.Expr).empty;
                            errdefer {
                                for (values.items) |item| freeParserExpr(self.allocator, item);
                                values.deinit(self.allocator);
                            }
                            while (true) {
                                try values.append(self.allocator, try self.parseExpr());
                                if (!self.acceptTag(.comma)) break;
                            }
                            try self.requireTag(.rparen);
                            try conditions.append(self.allocator, .{ .column = column, .op = .not_in, .value = .{ .literal = .null }, .list_values = try values.toOwnedSlice(self.allocator), .join_or = join_or });
                        }
                    }
                } else if (self.acceptWord("in")) {
                    try self.requireTag(.lparen);
                    if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
                        const start = self.current().position;
                        try self.requireWord("select");
                        var subquery = try self.parseSelect();
                        defer ast.deinit(self.allocator, &subquery);
                        const end = self.current().position;
                        try self.requireTag(.rparen);
                        try conditions.append(self.allocator, .{ .column = column, .op = .in, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .join_or = join_or });
                    } else {
                        var values = std.ArrayList(ast.Expr).empty;
                        errdefer {
                            for (values.items) |item| freeParserExpr(self.allocator, item);
                            values.deinit(self.allocator);
                        }
                        while (true) {
                            try values.append(self.allocator, try self.parseExpr());
                            if (!self.acceptTag(.comma)) break;
                        }
                        try self.requireTag(.rparen);
                        try conditions.append(self.allocator, .{ .column = column, .op = .in, .value = .{ .literal = .null }, .list_values = try values.toOwnedSlice(self.allocator), .join_or = join_or });
                    }
                } else {
                    const op: ast.CompareOp = if (self.acceptTag(.equal)) .equal else if (self.acceptTag(.not_equal)) .not_equal else if (self.acceptTag(.less)) .less else if (self.acceptTag(.less_equal)) .less_equal else if (self.acceptTag(.greater)) .greater else if (self.acceptTag(.greater_equal)) .greater_equal else if (self.acceptWord("like")) .like else if (self.acceptWord("glob")) .glob else return Error.UnexpectedToken;
                    try conditions.append(self.allocator, .{ .column = column, .op = op, .value = try self.parseExpr(), .join_or = join_or, .left_expr = left_expr });
                }
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
        var group_by: ?[]const u8 = null;
        if (self.acceptWord("group")) {
            try self.requireWord("by");
            group_by = try self.word();
        }
        var having: ?ast.Having = null;
        if (self.acceptWord("having")) {
            const left = try self.parseExpr();
            const op: ast.CompareOp = if (self.acceptTag(.equal)) .equal else if (self.acceptTag(.not_equal)) .not_equal else if (self.acceptTag(.less)) .less else if (self.acceptTag(.less_equal)) .less_equal else if (self.acceptTag(.greater)) .greater else if (self.acceptTag(.greater_equal)) .greater_equal else return Error.UnexpectedToken;
            having = .{ .left = left, .op = op, .right = try self.parseExpr() };
        }
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
        return .{ .select = .{ .projections = try projections.toOwnedSlice(self.allocator), .table = table, .join = join, .condition = condition, .group_by = group_by, .having = having, .order = order, .limit = limit, .offset = offset, .distinct = distinct } };
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
        var from: ?ast.UpdateFrom = null;
        var condition: ?ast.Conditions = null;
        if (self.acceptWord("from")) {
            const source_table = try self.word();
            try self.requireWord("where");
            const left = try self.qualifiedName();
            try self.requireTag(.equal);
            const right = try self.qualifiedName();
            from = .{ .table = source_table, .left_table = left.table, .left_column = left.column, .right_table = right.table, .right_column = right.column };
        } else condition = try self.parseCondition();
        return .{ .update = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .values = try values.toOwnedSlice(self.allocator), .condition = condition, .from = from } };
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
