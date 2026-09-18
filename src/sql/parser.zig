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
            if (call.argument2) |argument| {
                freeParserExpr(allocator, argument.*);
                allocator.destroy(argument);
            }
            if (call.argument3) |argument| {
                freeParserExpr(allocator, argument.*);
                allocator.destroy(argument);
            }
        },
        .binary => |binary| {
            freeParserExpr(allocator, binary.left.*);
            freeParserExpr(allocator, binary.right.*);
            allocator.destroy(binary.left);
            allocator.destroy(binary.right);
        },
        .unary => |unary| {
            freeParserExpr(allocator, unary.expr.*);
            allocator.destroy(unary.expr);
        },
        .caseExpr => |caseBlock| {
            if (caseBlock.base) |base| {
                freeParserExpr(allocator, base.*);
                allocator.destroy(base);
            }
            for (caseBlock.whens) |when| {
                freeParserExpr(allocator, when.condition);
                freeParserExpr(allocator, when.result);
            }
            allocator.free(caseBlock.whens);
            if (caseBlock.otherwise) |otherwise| {
                freeParserExpr(allocator, otherwise.*);
                allocator.destroy(otherwise);
            }
        },
        .patternMatch => |match| {
            freeParserExpr(allocator, match.value.*);
            allocator.destroy(match.value);
            freeParserExpr(allocator, match.pattern.*);
            allocator.destroy(match.pattern);
            if (match.escape) |escape| {
                freeParserExpr(allocator, escape.*);
                allocator.destroy(escape);
            }
        },
        .collate => |node| {
            freeParserExpr(allocator, node.expr.*);
            allocator.destroy(node.expr);
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
    nextParameter: usize = 1,
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

    fn isAggregateName(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "count") or std.ascii.eqlIgnoreCase(name, "sum") or std.ascii.eqlIgnoreCase(name, "avg") or std.ascii.eqlIgnoreCase(name, "average") or std.ascii.eqlIgnoreCase(name, "min") or std.ascii.eqlIgnoreCase(name, "max");
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
            const pragmaName = try self.word();
            var pragmaValue: ?[]const u8 = null;
            if (self.acceptTag(.equal)) {
                const token = self.current();
                if (token.tag != .word and token.tag != .number and token.tag != .string) return Error.UnexpectedToken;
                _ = self.advance();
                pragmaValue = token.text;
            }
            statement = .{ .pragma = .{ .name = pragmaName, .value = pragmaValue } };
        } else if (self.acceptWord("with")) statement = try self.parseWith() else if (self.acceptWord("explain")) {
            try self.requireWord("query");
            try self.requireWord("plan");
            const start = self.current().position;
            try self.requireWord("select");
            var query = try self.parseSelect();
            defer ast.deinit(self.allocator, &query);
            const end = self.current().position;
            statement = .{ .explainQueryPlan = try self.copy(self.source[start..end]) };
        } else if (self.acceptWord("create")) statement = try self.parseCreate() else if (self.acceptWord("drop")) statement = try self.parseDrop() else if (self.acceptWord("alter")) statement = try self.parseAlter() else if (self.acceptWord("insert")) statement = try self.parseInsert() else if (self.acceptWord("select")) statement = try self.parseSelect() else if (self.acceptWord("update")) statement = try self.parseUpdate() else if (self.acceptWord("delete")) statement = try self.parseDelete() else if (self.acceptWord("begin")) {
            _ = self.acceptWord("deferred");
            _ = self.acceptWord("immediate");
            _ = self.acceptWord("exclusive");
            statement = .begin;
        } else if (self.acceptWord("start")) {
            try self.requireWord("transaction");
            statement = .begin;
        } else if (self.acceptWord("commit")) statement = .commit else if (self.acceptWord("rollback")) {
            if (self.acceptWord("to")) statement = .{ .rollbackTo = try self.word() } else statement = .rollback;
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
            const queryStart = self.current().position;
            try self.requireWord("select");
            var queryStatement = try self.parseSelect();
            defer ast.deinit(self.allocator, &queryStatement);
            const queryEnd = self.current().position;
            var recursiveSql: ?[]const u8 = null;
            if (self.acceptWord("union")) {
                _ = self.acceptWord("all");
                const recursiveStart = self.current().position;
                try self.requireWord("select");
                var recursiveStatement = try self.parseSelect();
                defer ast.deinit(self.allocator, &recursiveStatement);
                const recursiveEnd = self.current().position;
                recursiveSql = try self.copy(self.source[recursiveStart..recursiveEnd]);
            }
            try self.requireTag(.rparen);
            try ctes.append(self.allocator, .{ .name = name, .querySql = try self.copy(self.source[queryStart..queryEnd]), .recursiveSql = recursiveSql });
            if (!self.acceptTag(.comma)) break;
        }
        const bodyStart = self.current().position;
        try self.requireWord("select");
        var bodyStatement = try self.parseSelect();
        defer ast.deinit(self.allocator, &bodyStatement);
        const bodyEnd = self.current().position;
        return .{ .withSelect = .{ .ctes = try ctes.toOwnedSlice(self.allocator), .bodySql = try self.copy(self.source[bodyStart..bodyEnd]), .recursive = recursive } };
    }

    fn parseCreate(self: *Parser) !ast.Statement {
        if (self.acceptWord("trigger")) return self.parseTrigger();
        if (self.acceptWord("virtual")) {
            try self.requireWord("table");
            const ifNotExists = if (self.acceptWord("if")) blk: {
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
            return .{ .createVirtualTable = .{ .name = name, .module = module, .arguments = try arguments.toOwnedSlice(self.allocator), .ifNotExists = ifNotExists } };
        }
        if (self.acceptWord("view")) {
            const ifNotExists = if (self.acceptWord("if")) blk: {
                try self.requireWord("not");
                try self.requireWord("exists");
                break :blk true;
            } else false;
            const name = try self.word();
            try self.requireWord("as");
            const start = self.current().position;
            try self.requireWord("select");
            var selectStatement = try self.parseSelect();
            defer ast.deinit(self.allocator, &selectStatement);
            if (selectStatement != .select) {
                return Error.InvalidSql;
            }
            const end = self.current().position;
            return .{ .createView = .{ .name = name, .sql = try self.copy(self.source[start..end]), .ifNotExists = ifNotExists } };
        }
        if (self.acceptWord("unique")) {
            try self.requireWord("index");
            return self.parseIndex(true);
        }
        if (self.acceptWord("index")) return self.parseIndex(false);
        try self.requireWord("table");
        const ifNotExists = if (self.acceptWord("if")) blk: {
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
                .primaryKey => |names| self.allocator.free(names),
                .unique => |names| self.allocator.free(names),
                .foreignKey => |foreignKey| {
                    self.allocator.free(foreignKey.columns);
                    self.allocator.free(foreignKey.referencedColumns);
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
                    var childColumns = std.ArrayList([]const u8).empty;
                    errdefer childColumns.deinit(self.allocator);
                    while (true) {
                        try childColumns.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    try self.requireWord("references");
                    const foreignTable = try self.word();
                    try self.requireTag(.lparen);
                    var parentColumns = std.ArrayList([]const u8).empty;
                    errdefer parentColumns.deinit(self.allocator);
                    while (true) {
                        try parentColumns.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    if (childColumns.items.len == 0 or childColumns.items.len != parentColumns.items.len) return Error.InvalidSql;
                    var onDelete: ast.ReferentialAction = .restrict;
                    var onUpdate: ast.ReferentialAction = .restrict;
                    while (self.acceptWord("on")) {
                        const action = if (self.acceptWord("delete")) blk: {
                            break :blk &onDelete;
                        } else if (self.acceptWord("update")) blk: {
                            break :blk &onUpdate;
                        } else return Error.UnexpectedToken;
                        action.* = if (self.acceptWord("cascade")) .cascade else if (self.acceptWord("set")) blk: {
                            try self.requireWord("null");
                            break :blk .setNull;
                        } else if (self.acceptWord("restrict")) .restrict else return Error.UnexpectedToken;
                    }
                    try constraints.append(self.allocator, .{ .foreignKey = .{ .columns = try childColumns.toOwnedSlice(self.allocator), .table = foreignTable, .referencedColumns = try parentColumns.toOwnedSlice(self.allocator), .onDelete = onDelete, .onUpdate = onUpdate } });
                } else {
                    const kind: enum { primaryKey, unique } = if (self.acceptWord("primary")) blk: {
                        try self.requireWord("key");
                        break :blk .primaryKey;
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
                    const ownedNames = try names.toOwnedSlice(self.allocator);
                    try constraints.append(self.allocator, switch (kind) {
                        .primaryKey => .{ .primaryKey = ownedNames },
                        .unique => .{ .unique = ownedNames },
                    });
                }
                if (!self.acceptTag(.comma)) break;
                continue;
            }
            const columnName = try self.word();
            const typeName = try self.word();
            var primaryKey = false;
            var notNull = false;
            var unique = false;
            var foreignKey: ?ast.ForeignKeyDef = null;
            var defaultValue: ?Value = null;
            if (self.acceptWord("primary")) {
                try self.requireWord("key");
                primaryKey = true;
            }
            if (self.acceptWord("not")) {
                try self.requireWord("null");
                notNull = true;
            }
            if (self.acceptWord("unique")) unique = true;
            if (self.acceptWord("default")) {
                const expression = try self.parseExpr();
                defaultValue = switch (expression) {
                    .literal => |value| value,
                    else => return Error.InvalidSql,
                };
            }
            if (self.acceptWord("references")) {
                const foreignTable = try self.word();
                try self.requireTag(.lparen);
                const foreignColumn = try self.word();
                try self.requireTag(.rparen);
                var onDelete: ast.ReferentialAction = .restrict;
                var onUpdate: ast.ReferentialAction = .restrict;
                while (self.acceptWord("on")) {
                    const action = if (self.acceptWord("delete")) blk: {
                        break :blk &onDelete;
                    } else if (self.acceptWord("update")) blk: {
                        break :blk &onUpdate;
                    } else return Error.UnexpectedToken;
                    action.* = if (self.acceptWord("cascade")) .cascade else if (self.acceptWord("set")) blk: {
                        try self.requireWord("null");
                        break :blk .setNull;
                    } else if (self.acceptWord("restrict")) .restrict else return Error.UnexpectedToken;
                }
                foreignKey = .{ .table = foreignTable, .column = foreignColumn, .onDelete = onDelete, .onUpdate = onUpdate };
            }
            try columns.append(self.allocator, .{ .name = columnName, .typeName = typeName, .primaryKey = primaryKey, .notNull = notNull, .unique = unique, .foreignKey = foreignKey, .defaultValue = defaultValue });
            if (!self.acceptTag(.comma)) break;
        }
        try self.requireTag(.rparen);
        return .{ .createTable = .{ .name = name, .columns = try columns.toOwnedSlice(self.allocator), .constraints = try constraints.toOwnedSlice(self.allocator), .ifNotExists = ifNotExists } };
    }

    fn parseIndex(self: *Parser, unique: bool) !ast.Statement {
        const ifNotExists = if (self.acceptWord("if")) blk: {
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
        return .{ .createIndex = .{ .name = name, .table = table, .columns = try columns.toOwnedSlice(self.allocator), .unique = unique, .ifNotExists = ifNotExists } };
    }

    fn parseTrigger(self: *Parser) !ast.Statement {
        const ifNotExists = if (self.acceptWord("if")) blk: {
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
        const bodyStart = self.current().position;
        while (self.current().tag != .eof and !(self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "end"))) _ = self.advance();
        if (self.current().tag == .eof or self.current().position == bodyStart) return Error.UnexpectedToken;
        const bodyEnd = self.current().position;
        _ = self.advance();
        return .{ .createTrigger = .{ .name = name, .table = table, .event = event, .body = try self.copy(self.source[bodyStart..bodyEnd]), .ifNotExists = ifNotExists } };
    }

    fn parseDrop(self: *Parser) !ast.Statement {
        const kind: enum { table, index, view, trigger } = if (self.acceptWord("table")) .table else if (self.acceptWord("index")) .index else if (self.acceptWord("view")) .view else if (self.acceptWord("trigger")) .trigger else return Error.UnexpectedToken;
        const ifExists = if (self.acceptWord("if")) blk: {
            try self.requireWord("exists");
            break :blk true;
        } else false;
        const name = try self.word();
        return switch (kind) {
            .table => .{ .dropTable = .{ .name = name, .ifExists = ifExists } },
            .index => .{ .dropIndex = .{ .name = name, .ifExists = ifExists } },
            .view => .{ .dropView = .{ .name = name, .ifExists = ifExists } },
            .trigger => .{ .dropTrigger = .{ .name = name, .ifExists = ifExists } },
        };
    }

    fn parseAlter(self: *Parser) !ast.Statement {
        try self.requireWord("table");
        const table = try self.word();
        if (self.acceptWord("add")) {
            _ = self.acceptWord("column");
            const name = try self.word();
            const typeName = if (self.current().tag == .word) try self.word() else "";
            return .{ .alterTable = .{ .addColumn = .{ .table = table, .definition = .{ .name = name, .typeName = typeName } } } };
        }
        if (self.acceptWord("rename")) {
            if (self.acceptWord("to")) return .{ .alterTable = .{ .renameTable = .{ .table = table, .newName = try self.word() } } };
            try self.requireWord("column");
            const oldName = try self.word();
            try self.requireWord("to");
            return .{ .alterTable = .{ .renameColumn = .{ .table = table, .oldName = oldName, .newName = try self.word() } } };
        }
        if (self.acceptWord("drop")) {
            _ = self.acceptWord("column");
            return .{ .alterTable = .{ .dropColumn = .{ .table = table, .column = try self.word() } } };
        }
        return Error.UnexpectedToken;
    }

    fn parseLiteral(self: *Parser) Error!ast.Expr {
        if (self.acceptTag(.star)) return .wildcard;
        if (self.acceptTag(.lparen)) {
            const inner = try self.parseExpr();
            try self.requireTag(.rparen);
            return inner;
        }
        if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "case")) {
            _ = self.advance();
            return self.parseCase();
        }
        const token = self.current();
        if (token.tag == .parameter) {
            _ = self.advance();
            const index = if (token.text.len > 1) std.fmt.parseInt(usize, token.text[1..], 10) catch self.nextParameter else self.nextParameter;
            if (token.text.len == 1) self.nextParameter += 1;
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
            if (std.ascii.eqlIgnoreCase(name, "substring") and self.current().tag == .lparen) name = "substr";
            if (self.acceptTag(.lparen)) {
                const distinct = self.acceptWord("distinct");
                if (distinct and !isAggregateName(name)) return Error.UnexpectedToken;
                const argument = try self.allocator.create(ast.Expr);
                errdefer self.allocator.destroy(argument);
                argument.* = try self.parseExpr();
                if (distinct and argument.* == .wildcard) return Error.UnexpectedToken;
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
                return .{ .function = .{ .name = name, .argument = argument, .argument2 = argument2, .argument3 = argument3, .distinct = distinct } };
            }
            return .{ .identifier = name };
        }
        return Error.UnexpectedToken;
    }

    fn binaryNode(self: *Parser, op: ast.BinaryOp, left: ast.Expr, right: ast.Expr) !ast.Expr {
        const leftNode = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, left);
            self.allocator.destroy(leftNode);
        }
        leftNode.* = left;
        const rightNode = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, right);
            self.allocator.destroy(rightNode);
        }
        rightNode.* = right;
        return .{ .binary = .{ .op = op, .left = leftNode, .right = rightNode } };
    }

    fn unaryNode(self: *Parser, op: ast.UnaryOp, expr: ast.Expr) !ast.Expr {
        const node = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, expr);
            self.allocator.destroy(node);
        }
        node.* = expr;
        return .{ .unary = .{ .op = op, .expr = node } };
    }

    fn parseExpr(self: *Parser) Error!ast.Expr {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) Error!ast.Expr {
        var left = try self.parseAnd();
        while (self.acceptWord("or")) {
            left = try self.binaryNode(.logicalOr, left, try self.parseAnd());
        }
        return left;
    }

    fn parseAnd(self: *Parser) Error!ast.Expr {
        var left = try self.parseLike();
        while (self.acceptWord("and")) {
            left = try self.binaryNode(.logicalAnd, left, try self.parseLike());
        }
        return left;
    }

    fn patternNode(self: *Parser, value: ast.Expr, pattern: ast.Expr, escape: ?ast.Expr, negated: bool, glob: bool) !ast.Expr {
        return self.patternNodeFull(value, pattern, escape, negated, glob, false, false);
    }

    fn patternNodeFull(self: *Parser, value: ast.Expr, pattern: ast.Expr, escape: ?ast.Expr, negated: bool, glob: bool, isRegexp: bool, isMatch: bool) !ast.Expr {
        const valueNode = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, value);
            self.allocator.destroy(valueNode);
        }
        valueNode.* = value;
        const patternExpr = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, pattern);
            self.allocator.destroy(patternExpr);
        }
        patternExpr.* = pattern;
        var escapeNode: ?*const ast.Expr = null;
        errdefer if (escapeNode) |node| {
            if (escape) |expr| freeParserExpr(self.allocator, expr);
            self.allocator.destroy(node);
        };
        if (escape) |expr| {
            const node = try self.allocator.create(ast.Expr);
            node.* = expr;
            escapeNode = node;
        }
        return .{ .patternMatch = .{ .value = valueNode, .pattern = patternExpr, .escape = escapeNode, .negated = negated, .glob = glob, .isRegexp = isRegexp, .isMatch = isMatch } };
    }

    fn collateNode(self: *Parser, inner: ast.Expr, name: []const u8) !ast.Expr {
        const node = try self.allocator.create(ast.Expr);
        errdefer {
            freeParserExpr(self.allocator, inner);
            self.allocator.destroy(node);
        }
        node.* = inner;
        return .{ .collate = .{ .expr = node, .name = name } };
    }

    fn parseLike(self: *Parser) Error!ast.Expr {
        var left = try self.parseCmp();
        left = try self.parseCollateSuffix(left);
        while (true) {
            const negated = self.acceptWord("not");
            if (self.acceptWord("like")) {
                var pattern = try self.parseCmp();
                pattern = try self.parseCollateSuffix(pattern);
                left = try self.patternNode(left, pattern, try self.parseEscape(), negated, false);
            } else if (self.acceptWord("glob")) {
                var pattern = try self.parseCmp();
                pattern = try self.parseCollateSuffix(pattern);
                left = try self.patternNodeFull(left, pattern, null, negated, true, false, false);
            } else if (self.acceptWord("regexp")) {
                var pattern = try self.parseCmp();
                pattern = try self.parseCollateSuffix(pattern);
                left = try self.patternNodeFull(left, pattern, null, negated, false, true, false);
            } else if (self.acceptWord("match")) {
                var pattern = try self.parseCmp();
                pattern = try self.parseCollateSuffix(pattern);
                left = try self.patternNodeFull(left, pattern, null, negated, false, false, true);
            } else {
                if (negated) return Error.UnexpectedToken;
                return left;
            }
            left = try self.parseCollateSuffix(left);
        }
    }

    fn parseCollateSuffix(self: *Parser, inner: ast.Expr) !ast.Expr {
        if (!self.acceptWord("collate")) return inner;
        const name = try self.word();
        return self.collateNode(inner, name);
    }

    fn parseCmp(self: *Parser) Error!ast.Expr {
        var left = try self.parseBitOr();
        while (true) {
            const op: ?ast.BinaryOp = if (self.acceptTag(.equal))
                .equal
            else if (self.acceptTag(.notEqual))
                .notEqual
            else if (self.acceptTag(.less))
                .less
            else if (self.acceptTag(.lessEqual))
                .lessEqual
            else if (self.acceptTag(.greater))
                .greater
            else if (self.acceptTag(.greaterEqual))
                .greaterEqual
            else
                null;
            if (op == null) return left;
            left = try self.binaryNode(op.?, left, try self.parseBitOr());
        }
    }

    fn parseBitOr(self: *Parser) Error!ast.Expr {
        var left = try self.parseBitAnd();
        while (self.acceptTag(.pipe)) {
            left = try self.binaryNode(.bitOr, left, try self.parseBitAnd());
        }
        return left;
    }

    fn parseBitAnd(self: *Parser) Error!ast.Expr {
        var left = try self.parseShift();
        while (self.acceptTag(.amp)) {
            left = try self.binaryNode(.bitAnd, left, try self.parseShift());
        }
        return left;
    }

    fn parseShift(self: *Parser) Error!ast.Expr {
        var left = try self.parseAdd();
        while (true) {
            if (self.acceptTag(.lshift)) {
                left = try self.binaryNode(.shiftLeft, left, try self.parseAdd());
            } else if (self.acceptTag(.rshift)) {
                left = try self.binaryNode(.shiftRight, left, try self.parseAdd());
            } else break;
        }
        return left;
    }

    fn parseAdd(self: *Parser) Error!ast.Expr {
        var left = try self.parseMul();
        while (true) {
            if (self.acceptTag(.plus)) {
                left = try self.binaryNode(.add, left, try self.parseMul());
            } else if (self.acceptTag(.minus)) {
                left = try self.binaryNode(.subtract, left, try self.parseMul());
            } else break;
        }
        return left;
    }

    fn parseMul(self: *Parser) Error!ast.Expr {
        var left = try self.parseConcat();
        while (true) {
            if (self.acceptTag(.star)) {
                left = try self.binaryNode(.multiply, left, try self.parseConcat());
            } else if (self.acceptTag(.slash)) {
                left = try self.binaryNode(.divide, left, try self.parseConcat());
            } else if (self.acceptTag(.percent)) {
                left = try self.binaryNode(.modulo, left, try self.parseConcat());
            } else break;
        }
        return left;
    }

    fn parseConcat(self: *Parser) Error!ast.Expr {
        var left = try self.parseUnary();
        while (self.acceptTag(.concat)) {
            left = try self.binaryNode(.concat, left, try self.parseUnary());
        }
        return left;
    }

    fn parseUnary(self: *Parser) Error!ast.Expr {
        if (self.acceptWord("not")) return self.unaryNode(.logicalNot, try self.parseUnary());
        if (self.acceptTag(.minus)) return self.unaryNode(.negate, try self.parseUnary());
        if (self.acceptTag(.plus)) return self.unaryNode(.positive, try self.parseUnary());
        if (self.acceptTag(.tilde)) return self.unaryNode(.bitNot, try self.parseUnary());
        return self.parseLiteral();
    }

    fn parseCase(self: *Parser) !ast.Expr {
        var base: ?*const ast.Expr = null;
        errdefer if (base) |node| {
            freeParserExpr(self.allocator, node.*);
            self.allocator.destroy(node);
        };
        if (!(self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "when"))) {
            const baseNode = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(baseNode);
            baseNode.* = try self.parseExpr();
            base = baseNode;
        }
        var whens = std.ArrayList(ast.CaseWhen).empty;
        errdefer {
            for (whens.items) |item| {
                freeParserExpr(self.allocator, item.condition);
                freeParserExpr(self.allocator, item.result);
            }
            whens.deinit(self.allocator);
        }
        while (self.acceptWord("when")) {
            const condition = try self.parseExpr();
            errdefer freeParserExpr(self.allocator, condition);
            try self.requireWord("then");
            const result = try self.parseExpr();
            errdefer freeParserExpr(self.allocator, result);
            try whens.append(self.allocator, .{ .condition = condition, .result = result });
        }
        if (whens.items.len == 0) return Error.UnexpectedToken;
        var otherwise: ?*const ast.Expr = null;
        errdefer if (otherwise) |node| {
            freeParserExpr(self.allocator, node.*);
            self.allocator.destroy(node);
        };
        if (self.acceptWord("else")) {
            const elseNode = try self.allocator.create(ast.Expr);
            errdefer self.allocator.destroy(elseNode);
            elseNode.* = try self.parseExpr();
            otherwise = elseNode;
        }
        try self.requireWord("end");
        return .{ .caseExpr = .{ .base = base, .whens = try whens.toOwnedSlice(self.allocator), .otherwise = otherwise } };
    }

    fn parseInsert(self: *Parser) !ast.Statement {
        var conflict: ast.InsertConflict = .none;
        var upsertColumns: []const []const u8 = &.{};
        var upsertValues: []const ast.Expr = &.{};
        var upsertWhere: ?ast.Conditions = null;
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
            const emptyRow = try self.allocator.alloc(ast.Expr, 0);
            var defaultRows = try self.allocator.alloc([]const ast.Expr, 1);
            defaultRows[0] = emptyRow;
            return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = defaultRows, .conflict = conflict } };
        }
        if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
            const selectStart = self.current().position;
            _ = self.advance();
            var query = try self.parseSelect();
            defer ast.deinit(self.allocator, &query);
            const selectEnd = self.current().position;
            const emptyRows = try self.allocator.alloc([]const ast.Expr, 0);
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
                    upsertColumns = try names.toOwnedSlice(self.allocator);
                    upsertValues = try expressions.toOwnedSlice(self.allocator);
                    conflict = .update;
                    if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) upsertWhere = try self.parseCondition();
                }
            }
            return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = emptyRows, .selectSql = try self.copy(self.source[selectStart..selectEnd]), .conflict = conflict, .upsertWhere = upsertWhere } };
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
                upsertColumns = try names.toOwnedSlice(self.allocator);
                upsertValues = try expressions.toOwnedSlice(self.allocator);
                conflict = .update;
                if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) upsertWhere = try self.parseCondition();
            }
        }
        return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = try rows.toOwnedSlice(self.allocator), .conflict = conflict, .upsertColumns = upsertColumns, .upsertValues = upsertValues, .upsertWhere = upsertWhere } };
    }

    fn parseCondition(self: *Parser) anyerror!?ast.Conditions {
        if (!self.acceptWord("where")) return null;
        var conditions = std.ArrayList(ast.Condition).empty;
        var joinOr = false;
        while (true) {
            var leadingNot = false;
            if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "not") and self.index + 1 < self.tokens.len) {
                const next = self.tokens[self.index + 1];
                if (next.tag == .word and (std.ascii.eqlIgnoreCase(next.text, "exists") or std.ascii.eqlIgnoreCase(next.text, "like") or std.ascii.eqlIgnoreCase(next.text, "glob") or std.ascii.eqlIgnoreCase(next.text, "regexp") or std.ascii.eqlIgnoreCase(next.text, "match") or std.ascii.eqlIgnoreCase(next.text, "between") or std.ascii.eqlIgnoreCase(next.text, "in"))) {} else if (!(next.tag == .word and std.ascii.eqlIgnoreCase(next.text, "exists"))) {
                    _ = self.advance();
                    leadingNot = true;
                    if (self.acceptTag(.lparen)) {
                        const inner = try self.parseExpr();
                        try self.requireTag(.rparen);
                        try conditions.append(self.allocator, .{ .column = "", .op = .equal, .value = inner, .leftExpr = .{ .literal = .{ .integer = 0 } }, .joinOr = joinOr, .negated = false });
                        if (self.acceptWord("or")) {
                            joinOr = true;
                        } else if (self.acceptWord("and")) {
                            joinOr = false;
                        } else break;
                        continue;
                    }
                }
            }
            if (self.acceptWord("not")) {
                if (self.acceptWord("exists")) {
                    try self.requireTag(.lparen);
                    const start = self.current().position;
                    try self.requireWord("select");
                    var subquery = try self.parseSelect();
                    defer ast.deinit(self.allocator, &subquery);
                    const end = self.current().position;
                    try self.requireTag(.rparen);
                    try conditions.append(self.allocator, .{ .column = "", .op = .notExists, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .joinOr = joinOr, .negated = leadingNot });
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
                try conditions.append(self.allocator, .{ .column = "", .op = .exists, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .joinOr = joinOr, .negated = leadingNot });
            } else {
                var leftExpr: ?ast.Expr = null;
                var column: []const u8 = undefined;
                if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "case")) {
                    _ = self.advance();
                    leftExpr = try self.parseCase();
                    column = "";
                } else if (self.acceptTag(.lparen)) {
                    leftExpr = try self.parseExpr();
                    try self.requireTag(.rparen);
                    column = "";
                } else if (self.current().tag == .word and self.index + 1 < self.tokens.len and self.tokens[self.index + 1].tag == .lparen) {
                    leftExpr = try self.parseLiteral();
                    column = "";
                } else {
                    const qualified = try self.qualifiedName();
                    column = if (qualified.table.len == 0) qualified.column else blk: {
                        const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ qualified.table, qualified.column });
                        defer self.allocator.free(combined);
                        break :blk try self.copy(combined);
                    };
                }
                var collate: ?[]const u8 = null;
                if (self.acceptWord("collate")) collate = try self.word();
                if (self.acceptWord("is")) {
                    const isNot = self.acceptWord("not");
                    if (self.acceptWord("null")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = if (isNot) .isNotNull else .isNull, .value = .{ .literal = .null }, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("distinct")) {
                        try self.requireWord("from");
                        try conditions.append(self.allocator, .{ .column = column, .op = if (isNot) .isNotDistinct else .isDistinct, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else {
                        try conditions.append(self.allocator, .{ .column = column, .op = if (isNot) .isNotValue else .isValue, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    }
                } else if (self.acceptWord("between")) {
                    const lower = try self.parseCmp();
                    try self.requireWord("and");
                    try conditions.append(self.allocator, .{ .column = column, .op = .between, .value = lower, .value2 = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                } else if (self.acceptWord("not")) {
                    if (self.acceptWord("like")) {
                        const pattern = try self.parseCmp();
                        try conditions.append(self.allocator, .{ .column = column, .op = .notLike, .value = pattern, .escape = try self.parseEscape(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("glob")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = .notGlob, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("regexp")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = .notRegexp, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("match")) {
                        try conditions.append(self.allocator, .{ .column = column, .op = .notMatch, .value = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else if (self.acceptWord("between")) {
                        const lower = try self.parseCmp();
                        try self.requireWord("and");
                        try conditions.append(self.allocator, .{ .column = column, .op = .notBetween, .value = lower, .value2 = try self.parseCmp(), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
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
                            try conditions.append(self.allocator, .{ .column = column, .op = .notIn, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                        } else {
                            var values = std.ArrayList(ast.Expr).empty;
                            errdefer {
                                for (values.items) |item| freeParserExpr(self.allocator, item);
                                values.deinit(self.allocator);
                            }
                            while (true) {
                                try values.append(self.allocator, try self.parseCmp());
                                if (!self.acceptTag(.comma)) break;
                            }
                            try self.requireTag(.rparen);
                            try conditions.append(self.allocator, .{ .column = column, .op = .notIn, .value = .{ .literal = .null }, .listValues = try values.toOwnedSlice(self.allocator), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
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
                        try conditions.append(self.allocator, .{ .column = column, .op = .in, .value = .{ .literal = .null }, .subquery = try self.copy(self.source[start..end]), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    } else {
                        var values = std.ArrayList(ast.Expr).empty;
                        errdefer {
                            for (values.items) |item| freeParserExpr(self.allocator, item);
                            values.deinit(self.allocator);
                        }
                        while (true) {
                            try values.append(self.allocator, try self.parseCmp());
                            if (!self.acceptTag(.comma)) break;
                        }
                        try self.requireTag(.rparen);
                        try conditions.append(self.allocator, .{ .column = column, .op = .in, .value = .{ .literal = .null }, .listValues = try values.toOwnedSlice(self.allocator), .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = collate });
                    }
                } else {
                    const op: ast.CompareOp = if (self.acceptTag(.equal)) .equal else if (self.acceptTag(.notEqual)) .notEqual else if (self.acceptTag(.less)) .less else if (self.acceptTag(.lessEqual)) .lessEqual else if (self.acceptTag(.greater)) .greater else if (self.acceptTag(.greaterEqual)) .greaterEqual else if (self.acceptWord("like")) .like else if (self.acceptWord("glob")) .glob else if (self.acceptWord("regexp")) .regexp else if (self.acceptWord("match")) .match else return Error.UnexpectedToken;
                    const pattern = try self.parseCmp();
                    const escape: ?ast.Expr = if (op == .like) try self.parseEscape() else null;
                    var tailCollate: ?[]const u8 = null;
                    if (self.acceptWord("collate")) tailCollate = try self.word();
                    const useCollate = tailCollate orelse collate;
                    try conditions.append(self.allocator, .{ .column = column, .op = op, .value = pattern, .escape = escape, .joinOr = joinOr, .leftExpr = leftExpr, .negated = leadingNot, .collate = useCollate });
                }
            }
            if (self.acceptWord("or")) {
                joinOr = true;
            } else if (self.acceptWord("and")) {
                joinOr = false;
            } else break;
        }
        return try conditions.toOwnedSlice(self.allocator);
    }

    fn parseEscape(self: *Parser) !?ast.Expr {
        if (!self.acceptWord("escape")) return null;
        return try self.parseCmp();
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
                const joinedTable = try self.word();
                if (kind != .cross) {
                    try self.requireWord("on");
                    const left = try self.qualifiedName();
                    try self.requireTag(.equal);
                    const right = try self.qualifiedName();
                    join = .{ .kind = kind orelse .inner, .table = joinedTable, .leftTable = left.table, .leftColumn = left.column, .rightTable = right.table, .rightColumn = right.column };
                } else join = .{ .kind = .cross, .table = joinedTable, .leftTable = "", .leftColumn = "", .rightTable = "", .rightColumn = "" };
            }
        }
        const condition = try self.parseCondition();
        var groupBy: ?[]const u8 = null;
        if (self.acceptWord("group")) {
            try self.requireWord("by");
            groupBy = try self.word();
        }
        var having: ?ast.Having = null;
        if (self.acceptWord("having")) {
            const left = try self.parseBitOr();
            const op: ast.CompareOp = if (self.acceptTag(.equal)) .equal else if (self.acceptTag(.notEqual)) .notEqual else if (self.acceptTag(.less)) .less else if (self.acceptTag(.lessEqual)) .lessEqual else if (self.acceptTag(.greater)) .greater else if (self.acceptTag(.greaterEqual)) .greaterEqual else return Error.UnexpectedToken;
            having = .{ .left = left, .op = op, .right = try self.parseBitOr() };
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
        return .{ .select = .{ .projections = try projections.toOwnedSlice(self.allocator), .table = table, .join = join, .condition = condition, .groupBy = groupBy, .having = having, .order = order, .limit = limit, .offset = offset, .distinct = distinct } };
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
            const sourceTable = try self.word();
            try self.requireWord("where");
            const left = try self.qualifiedName();
            try self.requireTag(.equal);
            const right = try self.qualifiedName();
            from = .{ .table = sourceTable, .leftTable = left.table, .leftColumn = left.column, .rightTable = right.table, .rightColumn = right.column };
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
