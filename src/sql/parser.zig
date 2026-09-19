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
            for (call.extraArgs) |argument| {
                freeParserExpr(allocator, argument);
            }
            if (call.extraArgs.len != 0) allocator.free(call.extraArgs);
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
        .inSubquery => |inSub| {
            freeParserExpr(allocator, inSub.expr.*);
            allocator.destroy(inSub.expr);
        },
        .inList => |inL| {
            freeParserExpr(allocator, inL.expr.*);
            allocator.destroy(inL.expr);
            for (inL.list) |item| freeParserExpr(allocator, item);
            if (inL.list.len != 0) allocator.free(inL.list);
        },
        .window => |w| {
            if (w.argument) |arg| {
                freeParserExpr(allocator, arg.*);
                allocator.destroy(arg);
            }
            if (w.argument2) |arg| {
                freeParserExpr(allocator, arg.*);
                allocator.destroy(arg);
            }
            for (w.extraArgs) |arg| {
                freeParserExpr(allocator, arg);
            }
            if (w.extraArgs.len != 0) allocator.free(w.extraArgs);
            for (w.partitionBy) |item| freeParserExpr(allocator, item);
            if (w.partitionBy.len != 0) allocator.free(w.partitionBy);
            for (w.orderBy) |item| freeParserExpr(allocator, item.expr);
            if (w.orderBy.len != 0) allocator.free(w.orderBy);
        },
        else => {},
    }
}
pub const Error = error{ InvalidSql, UnexpectedToken, OutOfMemory, Unsupported } || std.mem.Allocator.Error || lexer.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError;

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

    fn identifierOrNumber(self: *Parser) ![]const u8 {
        if (self.current().tag != .word and self.current().tag != .number) return Error.UnexpectedToken;
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

    fn signedPragmaValue(self: *Parser, sign: []const u8, text: []const u8) ![]const u8 {
        const combined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ sign, text });
        defer self.allocator.free(combined);
        return self.copy(combined);
    }

    fn asParserError(err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnexpectedToken => Error.UnexpectedToken,
            else => Error.InvalidSql,
        };
    }

    pub fn parse(self: *Parser) !ast.Statement {
        var statement: ast.Statement = undefined;
        if (self.acceptWord("pragma")) {
            const pragmaName = try self.word();
            var pragmaValue: ?[]const u8 = null;
            var pragmaArgument: ?[]const u8 = null;
            if (self.acceptTag(.lparen)) {
                const token = self.current();
                if (token.tag != .word and token.tag != .number) return Error.UnexpectedToken;
                _ = self.advance();
                pragmaArgument = token.text;
                try self.requireTag(.rparen);
            } else if (self.acceptTag(.equal)) {
                const token = self.current();
                if (token.tag == .minus or token.tag == .plus) {
                    const sign = self.advance();
                    const inner = self.current();
                    if (inner.tag != .word and inner.tag != .number and inner.tag != .string) return Error.UnexpectedToken;
                    _ = self.advance();
                    pragmaValue = try self.signedPragmaValue(sign.text, inner.text);
                } else {
                    if (token.tag != .word and token.tag != .number and token.tag != .string) return Error.UnexpectedToken;
                    _ = self.advance();
                    pragmaValue = token.text;
                }
            }
            statement = .{ .pragma = .{ .name = pragmaName, .value = pragmaValue, .argument = pragmaArgument } };
        } else if (self.acceptWord("with")) statement = try self.parseWith() else if (self.acceptWord("explain")) {
            try self.requireWord("query");
            try self.requireWord("plan");
            const start = self.current().position;
            try self.requireWord("select");
            var query = try self.parseSelectOrCompound();
            defer ast.deinit(self.allocator, &query);
            const end = self.current().position;
            statement = .{ .explainQueryPlan = try self.copy(self.source[start..end]) };
        } else if (self.acceptWord("attach")) {
            _ = self.acceptWord("database");
            const expr = try self.parseExpr();
            try self.requireWord("as");
            const schemaName = try self.word();
            statement = .{ .attach = .{ .expr = expr, .schemaName = schemaName } };
        } else if (self.acceptWord("detach")) {
            _ = self.acceptWord("database");
            const schemaName = try self.word();
            statement = .{ .detach = .{ .schemaName = schemaName } };
        } else if (self.acceptWord("vacuum")) {
            var schemaName: ?[]const u8 = null;
            var intoExpr: ?ast.Expr = null;
            if (self.current().tag == .word and !std.ascii.eqlIgnoreCase(self.current().text, "into") and self.current().tag != .semicolon and self.current().tag != .eof) {
                schemaName = try self.word();
            }
            if (self.acceptWord("into")) {
                intoExpr = try self.parseExpr();
            }
            statement = .{ .vacuum = .{ .schemaName = schemaName, .into = intoExpr } };
        } else if (self.acceptWord("create")) statement = try self.parseCreate() else if (self.acceptWord("drop")) statement = try self.parseDrop() else if (self.acceptWord("alter")) statement = try self.parseAlter() else if (self.acceptWord("insert")) statement = try self.parseInsert() else if (self.acceptWord("select")) statement = try self.parseSelectOrCompound() else if (self.acceptWord("update")) statement = try self.parseUpdate() else if (self.acceptWord("delete")) statement = try self.parseDelete() else if (self.acceptWord("begin")) {
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

    fn isTypeNameStop(text: []const u8) bool {
        return std.ascii.eqlIgnoreCase(text, "primary") or std.ascii.eqlIgnoreCase(text, "foreign") or std.ascii.eqlIgnoreCase(text, "not") or std.ascii.eqlIgnoreCase(text, "unique") or std.ascii.eqlIgnoreCase(text, "check") or std.ascii.eqlIgnoreCase(text, "default") or std.ascii.eqlIgnoreCase(text, "generated") or std.ascii.eqlIgnoreCase(text, "as") or std.ascii.eqlIgnoreCase(text, "references") or std.ascii.eqlIgnoreCase(text, "collate") or std.ascii.eqlIgnoreCase(text, "constraint");
    }

    fn parseColumnTypeName(self: *Parser) ![]const u8 {
        if (self.current().tag != .word or isTypeNameStop(self.current().text)) return "";
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(self.allocator);
        while (self.current().tag == .word and !isTypeNameStop(self.current().text)) {
            try parts.append(self.allocator, try self.word());
        }
        if (parts.items.len == 1 and self.current().tag != .lparen) return parts.items[0];
        var params: ?[]const u8 = null;
        defer if (params) |p| self.allocator.free(p);
        if (self.current().tag == .lparen) {
            try self.requireTag(.lparen);
            if (self.current().tag != .number) return Error.UnexpectedToken;
            const whole = try self.identifierOrNumber();
            params = try std.fmt.allocPrint(self.allocator, "({s}", .{whole});
            if (self.acceptTag(.comma)) {
                if (self.current().tag != .number) return Error.UnexpectedToken;
                const frac = try self.identifierOrNumber();
                const extended = try std.fmt.allocPrint(self.allocator, "{s},{s}", .{ params.?, frac });
                self.allocator.free(params.?);
                params = extended;
            }
            try self.requireTag(.rparen);
            const closed = try std.fmt.allocPrint(self.allocator, "{s})", .{params.?});
            self.allocator.free(params.?);
            params = closed;
        }
        const names = try std.mem.join(self.allocator, " ", parts.items);
        defer self.allocator.free(names);
        if (params) |p| {
            const combined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ names, p });
            defer self.allocator.free(combined);
            return self.copy(combined);
        }
        return self.copy(names);
    }

    fn parseColumnDef(self: *Parser) !ast.ColumnDef {
        const columnName = try self.word();
        const typeName = try self.parseColumnTypeName();
        var primaryKey = false;
        var notNull = false;
        var unique = false;
        var foreignKey: ?ast.ForeignKeyDef = null;
        var defaultValue: ?Value = null;
        var checkExpr: ?ast.Expr = null;
        var generatedExpr: ?ast.Expr = null;
        var generatedStored = false;
        while (self.current().tag == .word) {
            if (self.acceptWord("primary")) {
                try self.requireWord("key");
                primaryKey = true;
            } else if (self.acceptWord("not")) {
                try self.requireWord("null");
                notNull = true;
            } else if (self.acceptWord("unique")) {
                unique = true;
            } else if (self.acceptWord("check")) {
                try self.requireTag(.lparen);
                checkExpr = try self.parseExpr();
                try self.requireTag(.rparen);
            } else if (self.acceptWord("default")) {
                const expression = try self.parseExpr();
                defaultValue = switch (expression) {
                    .literal => |value| value,
                    else => return Error.InvalidSql,
                };
            } else if (self.acceptWord("generated")) {
                try self.requireWord("always");
                try self.requireWord("as");
                try self.requireTag(.lparen);
                generatedExpr = try self.parseExpr();
                try self.requireTag(.rparen);
                if (self.acceptWord("stored")) {
                    generatedStored = true;
                } else if (self.acceptWord("virtual")) {
                    generatedStored = false;
                }
            } else if (self.acceptWord("as")) {
                try self.requireTag(.lparen);
                generatedExpr = try self.parseExpr();
                try self.requireTag(.rparen);
                if (self.acceptWord("stored")) {
                    generatedStored = true;
                } else if (self.acceptWord("virtual")) {
                    generatedStored = false;
                }
            } else if (self.acceptWord("references")) {
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
                        if (self.acceptWord("null")) break :blk .setNull else if (self.acceptWord("default")) break :blk .setDefault else return Error.UnexpectedToken;
                    } else if (self.acceptWord("restrict")) .restrict else if (self.acceptWord("no")) blk: {
                        try self.requireWord("action");
                        break :blk .noAction;
                    } else return Error.UnexpectedToken;
                }
                foreignKey = .{ .table = foreignTable, .column = foreignColumn, .onDelete = onDelete, .onUpdate = onUpdate };
            } else break;
        }
        return .{ .name = columnName, .typeName = typeName, .primaryKey = primaryKey, .notNull = notNull, .unique = unique, .foreignKey = foreignKey, .defaultValue = defaultValue, .checkExpr = checkExpr, .generatedExpr = generatedExpr, .generatedStored = generatedStored };
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
                .check => |chk| freeParserExpr(self.allocator, chk),
            };
            constraints.deinit(self.allocator);
        }
        while (true) {
            if (self.current().tag == .word and (std.ascii.eqlIgnoreCase(self.current().text, "primary") or std.ascii.eqlIgnoreCase(self.current().text, "unique") or std.ascii.eqlIgnoreCase(self.current().text, "foreign") or std.ascii.eqlIgnoreCase(self.current().text, "check") or std.ascii.eqlIgnoreCase(self.current().text, "constraint"))) {
                if (self.acceptWord("constraint")) _ = try self.word();
                if (self.acceptWord("check")) {
                    try self.requireTag(.lparen);
                    const checkExpr = try self.parseExpr();
                    try self.requireTag(.rparen);
                    try constraints.append(self.allocator, .{ .check = checkExpr });
                } else if (self.acceptWord("foreign")) {
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
                            if (self.acceptWord("null")) break :blk .setNull else if (self.acceptWord("default")) break :blk .setDefault else return Error.UnexpectedToken;
                        } else if (self.acceptWord("restrict")) .restrict else if (self.acceptWord("no")) blk: {
                            try self.requireWord("action");
                            break :blk .noAction;
                        } else return Error.UnexpectedToken;
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
            const colDef = try self.parseColumnDef();
            try columns.append(self.allocator, colDef);
            if (!self.acceptTag(.comma)) break;
        }
        try self.requireTag(.rparen);
        var strict = false;
        var withoutRowid = false;
        while (true) {
            if (self.acceptWord("without")) {
                try self.requireWord("rowid");
                withoutRowid = true;
            } else if (self.acceptWord("strict")) {
                strict = true;
            } else break;
            _ = self.acceptTag(.comma);
        }
        return .{ .createTable = .{ .name = name, .columns = try columns.toOwnedSlice(self.allocator), .constraints = try constraints.toOwnedSlice(self.allocator), .ifNotExists = ifNotExists, .strict = strict, .withoutRowid = withoutRowid } };
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
        const timing: ast.TriggerTiming = if (self.acceptWord("before")) .before else blk: {
            try self.requireWord("after");
            break :blk .after;
        };
        const event: ast.TriggerEvent = if (self.acceptWord("insert")) .insert else if (self.acceptWord("update")) .update else if (self.acceptWord("delete")) .delete else return Error.UnexpectedToken;
        try self.requireWord("on");
        const table = try self.word();
        var whenSql: ?[]const u8 = null;
        if (self.acceptWord("when")) {
            const whenStart = self.current().position;
            const whenExpr = try self.parseExpr();
            defer ast.freeExprRec(self.allocator, whenExpr);
            const whenEnd = self.current().position;
            if (whenEnd <= whenStart) return Error.UnexpectedToken;
            whenSql = try self.copy(std.mem.trim(u8, self.source[whenStart..whenEnd], " \t\r\n"));
            if (whenSql.?.len == 0) return Error.UnexpectedToken;
        }
        try self.requireWord("begin");
        const bodyStart = self.current().position;
        while (self.current().tag != .eof and !(self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "end"))) _ = self.advance();
        if (self.current().tag == .eof or self.current().position == bodyStart) return Error.UnexpectedToken;
        const bodyEnd = self.current().position;
        _ = self.advance();
        return .{ .createTrigger = .{ .name = name, .table = table, .timing = timing, .event = event, .whenSql = whenSql, .body = try self.copy(self.source[bodyStart..bodyEnd]), .ifNotExists = ifNotExists } };
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
            const def = try self.parseColumnDef();
            return .{ .alterTable = .{ .addColumn = .{ .table = table, .definition = def } } };
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

    const BoundResult = struct {
        bound: ast.WindowFrameBound,
        offset: usize = 0,
    };

    fn parseWindowBound(self: *Parser) !BoundResult {
        if (self.acceptWord("unbounded")) {
            if (self.acceptWord("preceding")) return .{ .bound = .unboundedPreceding, .offset = 0 };
            if (self.acceptWord("following")) return .{ .bound = .unboundedFollowing, .offset = 0 };
            return Error.UnexpectedToken;
        }
        if (self.acceptWord("current")) {
            try self.requireWord("row");
            return .{ .bound = .currentRow, .offset = 0 };
        }
        if (self.current().tag == .number) {
            const numTok = self.advance();
            const offset = std.fmt.parseInt(usize, numTok.text, 10) catch 0;
            if (self.acceptWord("preceding")) return .{ .bound = .preceding, .offset = offset };
            if (self.acceptWord("following")) return .{ .bound = .following, .offset = offset };
            return Error.UnexpectedToken;
        }
        return Error.UnexpectedToken;
    }

    fn parseWindowFrame(self: *Parser) !?ast.WindowFrame {
        const kind: ast.WindowFrameKind = if (self.acceptWord("rows"))
            .rows
        else if (self.acceptWord("range"))
            .range
        else if (self.acceptWord("groups"))
            .groups
        else
            return null;

        if (self.acceptWord("between")) {
            const start = try self.parseWindowBound();
            try self.requireWord("and");
            const end = try self.parseWindowBound();
            return .{ .kind = kind, .start = start.bound, .startOffset = start.offset, .end = end.bound, .endOffset = end.offset };
        } else {
            const start = try self.parseWindowBound();
            return .{ .kind = kind, .start = start.bound, .startOffset = start.offset, .end = null, .endOffset = 0 };
        }
    }

    fn parseWindowSpec(self: *Parser) !struct { partitionBy: []const ast.Expr, orderBy: []const ast.OrderItem, frame: ?ast.WindowFrame } {
        try self.requireTag(.lparen);
        var partitionBy = std.ArrayList(ast.Expr).empty;
        errdefer {
            for (partitionBy.items) |item| freeParserExpr(self.allocator, item);
            partitionBy.deinit(self.allocator);
        }
        if (self.acceptWord("partition")) {
            try self.requireWord("by");
            while (true) {
                try partitionBy.append(self.allocator, try self.parseExpr());
                if (!self.acceptTag(.comma)) break;
            }
        }
        var orderBy = std.ArrayList(ast.OrderItem).empty;
        errdefer {
            for (orderBy.items) |item| freeParserExpr(self.allocator, item.expr);
            orderBy.deinit(self.allocator);
        }
        if (self.acceptWord("order")) {
            try self.requireWord("by");
            while (true) {
                const expr = try self.parseExpr();
                const descending = self.acceptWord("desc");
                if (!descending) _ = self.acceptWord("asc");
                var nullsFirst = false;
                if (self.acceptWord("nulls")) {
                    if (self.acceptWord("first")) {
                        nullsFirst = true;
                    } else if (self.acceptWord("last")) {
                        nullsFirst = false;
                    } else return Error.UnexpectedToken;
                }
                try orderBy.append(self.allocator, .{ .expr = expr, .descending = descending, .nullsFirst = nullsFirst });
                if (!self.acceptTag(.comma)) break;
            }
        }
        const frame = try self.parseWindowFrame();
        try self.requireTag(.rparen);
        return .{
            .partitionBy = try partitionBy.toOwnedSlice(self.allocator),
            .orderBy = try orderBy.toOwnedSlice(self.allocator),
            .frame = frame,
        };
    }

    fn parseLiteral(self: *Parser) Error!ast.Expr {
        if (self.acceptTag(.star)) return .wildcard;
        if (self.acceptTag(.lparen)) {
            if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
                const start = self.current().position;
                _ = self.advance();
                var sub = self.parseSelectOrCompound() catch |err| return asParserError(err);
                defer ast.deinit(self.allocator, &sub);
                const end = self.current().position;
                try self.requireTag(.rparen);
                return .{ .scalarSubquery = try self.copy(self.source[start..end]) };
            }
            const inner = try self.parseExpr();
            try self.requireTag(.rparen);
            return inner;
        }
        if (self.acceptWord("exists")) {
            try self.requireTag(.lparen);
            const start = self.current().position;
            try self.requireWord("select");
            var sub = self.parseSelectOrCompound() catch |err| return asParserError(err);
            defer ast.deinit(self.allocator, &sub);
            const end = self.current().position;
            try self.requireTag(.rparen);
            return .{ .existsSubquery = try self.copy(self.source[start..end]) };
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
        if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "x") and self.index + 1 < self.tokens.len and self.tokens[self.index + 1].tag == .string) {
            _ = self.advance();
            const strToken = self.advance();
            const hexText = strToken.text;
            if (hexText.len % 2 != 0) return Error.InvalidSql;
            const bytes = try self.allocator.alloc(u8, hexText.len / 2);
            errdefer self.allocator.free(bytes);
            _ = std.fmt.hexToBytes(bytes, hexText) catch return Error.InvalidSql;
            try self.allocations.append(self.allocator, bytes);
            return .{ .literal = .{ .blob = bytes } };
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
                var argument: ?*ast.Expr = null;
                var argument2: ?*const ast.Expr = null;
                var argument3: ?*const ast.Expr = null;
                var extraArgs = std.ArrayList(ast.Expr).empty;
                defer extraArgs.deinit(self.allocator);
                var distinct = false;
                if (!self.acceptTag(.rparen)) {
                    distinct = self.acceptWord("distinct");
                    if (distinct and !isAggregateName(name)) return Error.UnexpectedToken;
                    const first = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(first);
                    first.* = try self.parseExpr();
                    argument = first;
                    if (distinct and first.* == .wildcard) return Error.UnexpectedToken;
                    if (std.ascii.eqlIgnoreCase(name, "cast")) {
                        try self.requireWord("as");
                        const target = try self.allocator.create(ast.Expr);
                        errdefer self.allocator.destroy(target);
                        const castTarget = try self.parseColumnTypeName();
                        if (castTarget.len == 0) return Error.UnexpectedToken;
                        target.* = .{ .identifier = castTarget };
                        argument2 = target;
                        try self.requireTag(.rparen);
                    } else {
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
                                while (self.acceptTag(.comma)) {
                                    try extraArgs.append(self.allocator, try self.parseExpr());
                                }
                            }
                        }
                        try self.requireTag(.rparen);
                    }
                }
                if (self.acceptWord("over")) {
                    const spec = try self.parseWindowSpec();
                    var winExtra = std.ArrayList(ast.Expr).empty;
                    defer winExtra.deinit(self.allocator);
                    if (argument3) |a3| {
                        try winExtra.append(self.allocator, a3.*);
                        self.allocator.destroy(a3);
                    }
                    for (extraArgs.items) |ea| try winExtra.append(self.allocator, ea);
                    return .{ .window = .{
                        .funcName = name,
                        .argument = argument,
                        .argument2 = argument2,
                        .extraArgs = try winExtra.toOwnedSlice(self.allocator),
                        .partitionBy = spec.partitionBy,
                        .orderBy = spec.orderBy,
                        .frame = spec.frame,
                    } };
                }
                if (argument == null) {
                    const nullArg = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(nullArg);
                    nullArg.* = .wildcard;
                    argument = nullArg;
                }
                return .{ .function = .{
                    .name = name,
                    .argument = argument.?,
                    .argument2 = argument2,
                    .argument3 = argument3,
                    .extraArgs = try extraArgs.toOwnedSlice(self.allocator),
                    .distinct = distinct,
                } };
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
            } else if (self.acceptWord("in")) {
                try self.requireTag(.lparen);
                if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
                    const start = self.current().position;
                    _ = self.advance();
                    var sub = self.parseSelectOrCompound() catch |err| return asParserError(err);
                    defer ast.deinit(self.allocator, &sub);
                    const end = self.current().position;
                    try self.requireTag(.rparen);
                    const leftNode = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(leftNode);
                    leftNode.* = left;
                    left = .{ .inSubquery = .{ .expr = leftNode, .subquery = try self.copy(self.source[start..end]), .negated = negated } };
                } else {
                    var list = std.ArrayList(ast.Expr).empty;
                    errdefer {
                        for (list.items) |item| freeParserExpr(self.allocator, item);
                        list.deinit(self.allocator);
                    }
                    while (true) {
                        try list.append(self.allocator, try self.parseExpr());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                    const leftNode = try self.allocator.create(ast.Expr);
                    errdefer self.allocator.destroy(leftNode);
                    leftNode.* = left;
                    left = .{ .inList = .{ .expr = leftNode, .list = try list.toOwnedSlice(self.allocator), .negated = negated } };
                }
            } else if (self.acceptWord("is")) {
                var isNot = negated or self.acceptWord("not");
                if (self.acceptWord("distinct")) {
                    try self.requireWord("from");
                    isNot = !isNot;
                }
                var right = try self.parseCmp();
                right = try self.parseCollateSuffix(right);
                left = try self.binaryNode(if (isNot) .isNotOp else .isOp, left, right);
            } else if (self.acceptWord("between")) {
                const lower = try self.parseCmp();
                try self.requireWord("and");
                const upper = try self.parseCmp();
                const leftCopy = try ast.cloneOwnedExpr(self.allocator, left);
                if (!negated) {
                    const geNode = try self.binaryNode(.greaterEqual, left, lower);
                    const leNode = try self.binaryNode(.lessEqual, leftCopy, upper);
                    left = try self.binaryNode(.logicalAnd, geNode, leNode);
                } else {
                    const ltNode = try self.binaryNode(.less, left, lower);
                    const gtNode = try self.binaryNode(.greater, leftCopy, upper);
                    left = try self.binaryNode(.logicalOr, ltNode, gtNode);
                }
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

    fn parseReturning(self: *Parser) ![]const ast.Projection {
        if (!self.acceptWord("returning")) return &.{};
        var projections = std.ArrayList(ast.Projection).empty;
        errdefer {
            for (projections.items) |item| freeParserExpr(self.allocator, item.expr);
            projections.deinit(self.allocator);
        }
        while (true) {
            const expr = try self.parseExpr();
            var alias: ?[]const u8 = null;
            if (self.acceptWord("as")) {
                alias = try self.word();
            } else if (self.current().tag == .word and !std.ascii.eqlIgnoreCase(self.current().text, ";") and self.current().tag != .semicolon) {
                alias = try self.word();
            }
            try projections.append(self.allocator, .{ .expr = expr, .alias = alias });
            if (!self.acceptTag(.comma)) break;
        }
        return try projections.toOwnedSlice(self.allocator);
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
            const returning = try self.parseReturning();
            return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = defaultRows, .conflict = conflict, .returning = returning } };
        }
        if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "select")) {
            const selectStart = self.current().position;
            _ = self.advance();
            var query = try self.parseSelect();
            defer ast.deinit(self.allocator, &query);
            const selectEnd = self.current().position;
            const emptyRows = try self.allocator.alloc([]const ast.Expr, 0);
            var conflictTargetColumns = std.ArrayList([]const u8).empty;
            var conflictTargetWhere: ?ast.Conditions = null;
            if (self.acceptWord("on")) {
                try self.requireWord("conflict");
                if (self.acceptTag(.lparen)) {
                    while (true) {
                        try conflictTargetColumns.append(self.allocator, try self.word());
                        if (!self.acceptTag(.comma)) break;
                    }
                    try self.requireTag(.rparen);
                }
                if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) conflictTargetWhere = try self.parseCondition();
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
            const returning = try self.parseReturning();
            return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = emptyRows, .selectSql = try self.copy(self.source[selectStart..selectEnd]), .conflict = conflict, .conflictTargetColumns = try conflictTargetColumns.toOwnedSlice(self.allocator), .conflictTargetWhere = conflictTargetWhere, .upsertColumns = upsertColumns, .upsertValues = upsertValues, .upsertWhere = upsertWhere, .returning = returning } };
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
        var conflictTargetColumns = std.ArrayList([]const u8).empty;
        var conflictTargetWhere: ?ast.Conditions = null;
        if (self.acceptWord("on")) {
            try self.requireWord("conflict");
            if (self.acceptTag(.lparen)) {
                while (true) {
                    try conflictTargetColumns.append(self.allocator, try self.word());
                    if (!self.acceptTag(.comma)) break;
                }
                try self.requireTag(.rparen);
            }
            if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "where")) conflictTargetWhere = try self.parseCondition();
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
        const returning = try self.parseReturning();
        return .{ .insert = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .rows = try rows.toOwnedSlice(self.allocator), .conflict = conflict, .conflictTargetColumns = try conflictTargetColumns.toOwnedSlice(self.allocator), .conflictTargetWhere = conflictTargetWhere, .upsertColumns = upsertColumns, .upsertValues = upsertValues, .upsertWhere = upsertWhere, .returning = returning } };
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
                            var subquery = self.parseSelectOrCompound() catch |err| return asParserError(err);
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
                        var subquery = self.parseSelectOrCompound() catch |err| return asParserError(err);
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

    fn isReservedQueryKeyword(text: []const u8) bool {
        return std.ascii.eqlIgnoreCase(text, "where") or
            std.ascii.eqlIgnoreCase(text, "group") or
            std.ascii.eqlIgnoreCase(text, "having") or
            std.ascii.eqlIgnoreCase(text, "order") or
            std.ascii.eqlIgnoreCase(text, "limit") or
            std.ascii.eqlIgnoreCase(text, "offset") or
            std.ascii.eqlIgnoreCase(text, "inner") or
            std.ascii.eqlIgnoreCase(text, "left") or
            std.ascii.eqlIgnoreCase(text, "right") or
            std.ascii.eqlIgnoreCase(text, "full") or
            std.ascii.eqlIgnoreCase(text, "cross") or
            std.ascii.eqlIgnoreCase(text, "join") or
            std.ascii.eqlIgnoreCase(text, "natural") or
            std.ascii.eqlIgnoreCase(text, "union") or
            std.ascii.eqlIgnoreCase(text, "intersect") or
            std.ascii.eqlIgnoreCase(text, "except") or
            std.ascii.eqlIgnoreCase(text, "on") or
            std.ascii.eqlIgnoreCase(text, "using") or
            std.ascii.eqlIgnoreCase(text, "window");
    }

    fn parseSelect(self: *Parser) !ast.Statement {
        var projections = std.ArrayList(ast.Projection).empty;
        const distinct = self.acceptWord("distinct");
        while (true) {
            if (self.current().tag == .word and std.ascii.eqlIgnoreCase(self.current().text, "from")) return Error.UnexpectedToken;
            const expr = try self.parseExpr();
            var alias: ?[]const u8 = null;
            if (self.acceptWord("as")) {
                alias = try self.word();
            } else if (self.current().tag == .word and !isReservedQueryKeyword(self.current().text) and self.current().tag != .semicolon and !std.ascii.eqlIgnoreCase(self.current().text, "from")) {
                alias = try self.word();
            }
            try projections.append(self.allocator, .{ .expr = expr, .alias = alias });
            if (!self.acceptTag(.comma)) break;
        }
        var table: ?[]const u8 = null;
        var tableAlias: ?[]const u8 = null;
        var fromSubquery: ?[]const u8 = null;
        if (self.acceptWord("from")) {
            if (self.acceptTag(.lparen)) {
                const subStart = self.current().position;
                try self.requireWord("select");
                var subStmt = try self.parseSelectOrCompound();
                ast.deinit(self.allocator, &subStmt);
                try self.requireTag(.rparen);
                const subEnd = self.tokens[self.index - 1].position;
                fromSubquery = try self.copy(std.mem.trim(u8, self.source[subStart..subEnd], " \t\r\n"));
                if (self.acceptWord("as")) {
                    tableAlias = try self.word();
                } else if (self.current().tag == .word and !isReservedQueryKeyword(self.current().text) and self.current().tag != .semicolon) {
                    tableAlias = try self.word();
                }
                table = tableAlias orelse "__subquery__";
            } else {
                table = try self.word();
                if (self.acceptWord("as")) {
                    tableAlias = try self.word();
                } else if (self.current().tag == .word and !isReservedQueryKeyword(self.current().text) and self.current().tag != .semicolon) {
                    tableAlias = try self.word();
                }
            }
        }
        var joins = std.ArrayList(ast.Join).empty;
        defer joins.deinit(self.allocator);
        if (table != null) {
            while (true) {
                const natural = self.acceptWord("natural");
                var kind: ?ast.JoinKind = null;
                if (self.acceptWord("inner")) {
                    kind = .inner;
                } else if (self.acceptWord("left")) {
                    _ = self.acceptWord("outer");
                    kind = .left;
                } else if (self.acceptWord("right")) {
                    _ = self.acceptWord("outer");
                    kind = .right;
                } else if (self.acceptWord("full")) {
                    _ = self.acceptWord("outer");
                    kind = .full;
                } else if (self.acceptWord("cross")) {
                    kind = .cross;
                }
                if (kind == null and !natural and !self.acceptWord("join")) break;
                _ = self.acceptWord("join");
                const joinedTable = try self.word();
                var joinedAlias: ?[]const u8 = null;
                if (self.acceptWord("as")) {
                    joinedAlias = try self.word();
                } else if (self.current().tag == .word and !isReservedQueryKeyword(self.current().text) and self.current().tag != .semicolon) {
                    joinedAlias = try self.word();
                }
                const effectiveKind: ast.JoinKind = kind orelse .inner;
                if (effectiveKind != .cross and !natural) {
                    if (self.acceptWord("using")) {
                        try self.requireTag(.lparen);
                        var usingCols = std.ArrayList([]const u8).empty;
                        defer usingCols.deinit(self.allocator);
                        while (true) {
                            try usingCols.append(self.allocator, try self.word());
                            if (!self.acceptTag(.comma)) break;
                        }
                        try self.requireTag(.rparen);
                        if (usingCols.items.len == 1) {
                            const usingCol = usingCols.items[0];
                            try joins.append(self.allocator, .{ .kind = effectiveKind, .table = joinedTable, .tableAlias = joinedAlias, .leftTable = table.?, .leftColumn = usingCol, .rightTable = joinedTable, .rightColumn = usingCol, .mergeOutput = true });
                        } else {
                            const owned = try usingCols.toOwnedSlice(self.allocator);
                            try joins.append(self.allocator, .{ .kind = effectiveKind, .table = joinedTable, .tableAlias = joinedAlias, .leftTable = table.?, .leftColumn = "", .rightTable = joinedTable, .rightColumn = "", .mergeOutput = true, .usingColumns = owned });
                        }
                    } else {
                        try self.requireWord("on");
                        const left = try self.qualifiedName();
                        try self.requireTag(.equal);
                        const right = try self.qualifiedName();
                        try joins.append(self.allocator, .{ .kind = effectiveKind, .table = joinedTable, .tableAlias = joinedAlias, .leftTable = left.table, .leftColumn = left.column, .rightTable = right.table, .rightColumn = right.column });
                    }
                } else {
                    try joins.append(self.allocator, .{ .kind = effectiveKind, .table = joinedTable, .tableAlias = joinedAlias, .leftTable = "", .leftColumn = "", .rightTable = "", .rightColumn = "", .mergeOutput = natural });
                }
            }
        }
        const condition = try self.parseCondition();
        var groupBy: ?[]const u8 = null;
        if (self.acceptWord("group")) {
            try self.requireWord("by");
            const groupQualifier = try self.word();
            if (self.acceptTag(.dot)) {
                const groupColumn = try self.word();
                const combined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ groupQualifier, groupColumn });
                defer self.allocator.free(combined);
                groupBy = try self.copy(combined);
            } else groupBy = groupQualifier;
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
            var orderColumn = try self.identifierOrNumber();
            if (self.acceptTag(.dot)) orderColumn = try self.word();
            order = .{ .column = orderColumn, .descending = self.acceptWord("desc") };
            _ = self.acceptWord("asc");
        }
        return .{ .select = .{ .projections = try projections.toOwnedSlice(self.allocator), .table = table, .tableAlias = tableAlias, .fromSubquery = fromSubquery, .joins = if (joins.items.len == 0) &.{} else try joins.toOwnedSlice(self.allocator), .condition = condition, .groupBy = groupBy, .having = having, .order = order, .limit = null, .offset = null, .distinct = distinct } };
    }

    fn branchOrderStart(self: *Parser, endIndex: usize) ?usize {
        if (endIndex < 2) return null;
        var j = endIndex - 1;
        if (self.tokens[j].tag == .word and (std.ascii.eqlIgnoreCase(self.tokens[j].text, "desc") or std.ascii.eqlIgnoreCase(self.tokens[j].text, "asc"))) {
            if (j == 0) return null;
            j -= 1;
        }
        if (self.tokens[j].tag != .word and self.tokens[j].tag != .number) return null;
        if (j == 0) return null;
        j -= 1;
        if (self.tokens[j].tag == .dot) {
            if (j < 2) return null;
            j -= 1;
            if (self.tokens[j].tag != .word) return null;
            if (j == 0) return null;
            j -= 1;
        }
        if (self.tokens[j].tag != .word or !std.ascii.eqlIgnoreCase(self.tokens[j].text, "by")) return null;
        if (j == 0) return null;
        j -= 1;
        if (self.tokens[j].tag != .word or !std.ascii.eqlIgnoreCase(self.tokens[j].text, "order")) return null;
        return j;
    }

    fn parseSelectOrCompound(self: *Parser) anyerror!ast.Statement {
        const startPos = self.tokens[self.index - 1].position;
        var selectStmt = try self.parseSelect();
        errdefer ast.deinit(self.allocator, &selectStmt);
        var hasCompound = false;
        var lastOp: ast.CompoundOp = .unionOp;
        var leftEnd: usize = 0;
        var rightStart: usize = 0;
        var rightEnd: usize = 0;
        var pendingBranchHadOrder = selectStmt.select.order != null;
        var lastBranchOrder: ?ast.Order = null;
        var lastBranchOrderStart: ?usize = null;
        while (true) {
            const op: ast.CompoundOp = if (self.acceptWord("union"))
                (if (self.acceptWord("all")) .unionAllOp else .unionOp)
            else if (self.acceptWord("intersect"))
                .intersectOp
            else if (self.acceptWord("except"))
                .exceptOp
            else
                break;

            if (pendingBranchHadOrder) return Error.InvalidSql;
            hasCompound = true;
            lastOp = op;
            leftEnd = self.tokens[self.index - if (op == .unionAllOp) @as(usize, 2) else @as(usize, 1)].position;
            rightStart = self.current().position;
            try self.requireWord("select");
            var nextStmt = try self.parseSelect();
            pendingBranchHadOrder = nextStmt.select.order != null;
            lastBranchOrder = nextStmt.select.order;
            if (nextStmt.select.order != null) lastBranchOrderStart = self.branchOrderStart(self.index) orelse return Error.InvalidSql;
            ast.deinit(self.allocator, &nextStmt);
            rightEnd = self.current().position;
        }
        var limit: ?usize = null;
        var offset: ?usize = null;
        if (self.acceptWord("limit")) {
            const token = self.advance();
            limit = std.fmt.parseInt(usize, token.text, 10) catch return Error.InvalidSql;
        }
        if (self.acceptWord("offset")) {
            const token = self.advance();
            offset = std.fmt.parseInt(usize, token.text, 10) catch return Error.InvalidSql;
        }
        if (hasCompound) {
            if (lastBranchOrderStart) |orderStart| rightEnd = self.tokens[orderStart].position;
            ast.deinit(self.allocator, &selectStmt);
            return .{ .compoundSelect = .{
                .leftSql = try self.copy(std.mem.trim(u8, self.source[startPos..leftEnd], " \t\r\n")),
                .op = lastOp,
                .rightSql = try self.copy(std.mem.trim(u8, self.source[rightStart..rightEnd], " \t\r\n")),
                .order = lastBranchOrder,
                .limit = limit,
                .offset = offset,
            } };
        }
        selectStmt.select.limit = limit;
        selectStmt.select.offset = offset;
        return selectStmt;
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
        const returning = try self.parseReturning();
        return .{ .update = .{ .table = table, .columns = try columns.toOwnedSlice(self.allocator), .values = try values.toOwnedSlice(self.allocator), .condition = condition, .from = from, .returning = returning } };
    }

    fn parseDelete(self: *Parser) !ast.Statement {
        try self.requireWord("from");
        const table = try self.word();
        const condition = try self.parseCondition();
        const returning = try self.parseReturning();
        return .{ .delete = .{ .table = table, .condition = condition, .returning = returning } };
    }
};

test "parser builds insert and select statements" {
    var parser = try Parser.init(std.testing.allocator, "INSERT INTO users (name) VALUES ('A');");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .insert);
}

test "parser parses compound select queries with limit and offset" {
    var parser = try Parser.init(std.testing.allocator, "SELECT 1 UNION ALL SELECT 2 LIMIT 10 OFFSET 5;");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .compoundSelect);
    try std.testing.expectEqual(ast.CompoundOp.unionAllOp, statement.compoundSelect.op);
    try std.testing.expectEqual(@as(?usize, 10), statement.compoundSelect.limit);
    try std.testing.expectEqual(@as(?usize, 5), statement.compoundSelect.offset);
    var chained = try Parser.init(std.testing.allocator, "SELECT 1 UNION SELECT 2 UNION SELECT 3 ORDER BY 1;");
    defer chained.deinit();
    var chainedStmt = try chained.parse();
    defer ast.deinit(std.testing.allocator, &chainedStmt);
    try std.testing.expect(chainedStmt == .compoundSelect);
    try std.testing.expectEqual(ast.CompoundOp.unionOp, chainedStmt.compoundSelect.op);
    try std.testing.expectEqualStrings("SELECT 1 UNION SELECT 2", chainedStmt.compoundSelect.leftSql);
    try std.testing.expectEqualStrings("SELECT 3", chainedStmt.compoundSelect.rightSql);
    try std.testing.expect(chainedStmt.compoundSelect.order != null);
    try std.testing.expectEqualStrings("1", chainedStmt.compoundSelect.order.?.column);
    var branchOrdered = try Parser.init(std.testing.allocator, "SELECT 1 ORDER BY 1 UNION SELECT 2;");
    defer branchOrdered.deinit();
    if (branchOrdered.parse()) |stale| {
        var owned = stale;
        ast.deinit(std.testing.allocator, &owned);
        return error.ExpectedBranchOrderRejected;
    } else |err| {
        try std.testing.expectEqual(Error.InvalidSql, err);
    }
}

test "parser parses joins with aliases, outer keywords and using" {
    var p1 = try Parser.init(std.testing.allocator, "SELECT u.name, o.id FROM users u LEFT OUTER JOIN orders o ON u.id = o.user_id;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .select);
    try std.testing.expectEqualStrings("u", s1.select.tableAlias.?);
    try std.testing.expect(s1.select.joins.len == 1);
    try std.testing.expectEqual(ast.JoinKind.left, s1.select.joins[0].kind);
    try std.testing.expectEqualStrings("o", s1.select.joins[0].tableAlias.?);

    var p2 = try Parser.init(std.testing.allocator, "SELECT * FROM a JOIN b USING (id);");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .select);
    try std.testing.expect(s2.select.joins.len == 1);
    try std.testing.expectEqualStrings("id", s2.select.joins[0].leftColumn);
    try std.testing.expectEqual(@as(usize, 0), s2.select.joins[0].usingColumns.len);

    var p2m = try Parser.init(std.testing.allocator, "SELECT * FROM a JOIN b USING (id, grp);");
    defer p2m.deinit();
    var s2m = try p2m.parse();
    defer ast.deinit(std.testing.allocator, &s2m);
    try std.testing.expect(s2m == .select);
    try std.testing.expect(s2m.select.joins.len == 1);
    try std.testing.expectEqual(@as(usize, 2), s2m.select.joins[0].usingColumns.len);
    try std.testing.expectEqualStrings("id", s2m.select.joins[0].usingColumns[0]);
    try std.testing.expectEqualStrings("grp", s2m.select.joins[0].usingColumns[1]);

    var p3 = try Parser.init(std.testing.allocator, "SELECT * FROM a NATURAL JOIN b;");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .select);
    try std.testing.expect(s3.select.joins.len == 1);
}

test "parser parses chained joins" {
    var parser = try Parser.init(std.testing.allocator, "SELECT u.name FROM users u JOIN orders o ON u.id = o.uid LEFT JOIN items i ON o.item = i.name CROSS JOIN shippers;");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .select);
    try std.testing.expectEqual(@as(usize, 3), statement.select.joins.len);
    try std.testing.expectEqual(ast.JoinKind.inner, statement.select.joins[0].kind);
    try std.testing.expectEqualStrings("orders", statement.select.joins[0].table);
    try std.testing.expectEqualStrings("o", statement.select.joins[0].tableAlias.?);
    try std.testing.expectEqualStrings("u", statement.select.joins[0].leftTable);
    try std.testing.expectEqualStrings("id", statement.select.joins[0].leftColumn);
    try std.testing.expectEqual(ast.JoinKind.left, statement.select.joins[1].kind);
    try std.testing.expectEqualStrings("items", statement.select.joins[1].table);
    try std.testing.expectEqualStrings("o", statement.select.joins[1].leftTable);
    try std.testing.expectEqual(ast.JoinKind.cross, statement.select.joins[2].kind);
    try std.testing.expectEqualStrings("shippers", statement.select.joins[2].table);
}

test "parser parses subqueries in expressions" {
    var p1 = try Parser.init(std.testing.allocator, "SELECT (SELECT max(age) FROM users) AS max_age;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .select);
    try std.testing.expect(s1.select.projections[0].expr == .scalarSubquery);

    var p2 = try Parser.init(std.testing.allocator, "SELECT id FROM users WHERE id IN (SELECT user_id FROM orders);");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .select);

    var p3 = try Parser.init(std.testing.allocator, "SELECT id FROM users WHERE id IN (1, 2, 3);");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .select);
}

test "parser parses window functions with partition, order, and frame" {
    var parser = try Parser.init(std.testing.allocator, "SELECT id, row_number() OVER (PARTITION BY dept ORDER BY salary DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM emp;");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .select);
    const winExpr = statement.select.projections[1].expr;
    try std.testing.expect(winExpr == .window);
    try std.testing.expectEqualStrings("row_number", winExpr.window.funcName);
    try std.testing.expectEqual(@as(usize, 1), winExpr.window.partitionBy.len);
    try std.testing.expectEqual(@as(usize, 1), winExpr.window.orderBy.len);
    try std.testing.expect(winExpr.window.frame != null);
    try std.testing.expectEqual(ast.WindowFrameKind.rows, winExpr.window.frame.?.kind);
    try std.testing.expectEqual(ast.WindowFrameBound.unboundedPreceding, winExpr.window.frame.?.start);
    try std.testing.expectEqual(ast.WindowFrameBound.currentRow, winExpr.window.frame.?.end.?);
}

test "parser parses returning clause for insert, update, and delete" {
    var p1 = try Parser.init(std.testing.allocator, "INSERT INTO users (name) VALUES ('Alice') RETURNING id, name AS user_name;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .insert);
    try std.testing.expectEqual(@as(usize, 2), s1.insert.returning.len);
    try std.testing.expectEqualStrings("user_name", s1.insert.returning[1].alias.?);

    var p2 = try Parser.init(std.testing.allocator, "UPDATE users SET name = 'Bob' WHERE id = 1 RETURNING name;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .update);
    try std.testing.expectEqual(@as(usize, 1), s2.update.returning.len);

    var p3 = try Parser.init(std.testing.allocator, "DELETE FROM users WHERE id = 1 RETURNING id;");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .delete);
    try std.testing.expectEqual(@as(usize, 1), s3.delete.returning.len);
}

test "parser parses table constraints, generated columns, strict, and without rowid" {
    var parser = try Parser.init(std.testing.allocator, "CREATE TABLE items (id INTEGER PRIMARY KEY, price REAL CHECK (price > 0), doubled REAL GENERATED ALWAYS AS (price * 2) STORED, CONSTRAINT valid_item CHECK (id > 0)) STRICT, WITHOUT ROWID;");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .createTable);
    try std.testing.expect(statement.createTable.strict);
    try std.testing.expect(statement.createTable.withoutRowid);
    try std.testing.expect(statement.createTable.columns[1].checkExpr != null);
    try std.testing.expect(statement.createTable.columns[2].generatedExpr != null);
    try std.testing.expect(statement.createTable.columns[2].generatedStored);
    try std.testing.expectEqual(@as(usize, 1), statement.createTable.constraints.len);
    try std.testing.expect(statement.createTable.constraints[0] == .check);
}

test "parser parses attach, detach, and vacuum statements" {
    var p1 = try Parser.init(std.testing.allocator, "ATTACH DATABASE 'test.db' AS test_schema;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .attach);
    try std.testing.expectEqualStrings("test_schema", s1.attach.schemaName);

    var p2 = try Parser.init(std.testing.allocator, "DETACH DATABASE test_schema;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .detach);
    try std.testing.expectEqualStrings("test_schema", s2.detach.schemaName);

    var p3 = try Parser.init(std.testing.allocator, "VACUUM main INTO 'backup.db';");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .vacuum);
    try std.testing.expectEqualStrings("main", s3.vacuum.schemaName.?);
    try std.testing.expect(s3.vacuum.into != null);
}

test "parser parses pragma values, signs, and arguments" {
    var p1 = try Parser.init(std.testing.allocator, "PRAGMA cache_size = -100;");
    defer p1.deinit();
    var s1 = try p1.parse();
    defer ast.deinit(std.testing.allocator, &s1);
    try std.testing.expect(s1 == .pragma);
    try std.testing.expectEqualStrings("cache_size", s1.pragma.name);
    try std.testing.expectEqualStrings("-100", s1.pragma.value.?);
    try std.testing.expect(s1.pragma.argument == null);

    var p2 = try Parser.init(std.testing.allocator, "PRAGMA synchronous = OFF;");
    defer p2.deinit();
    var s2 = try p2.parse();
    defer ast.deinit(std.testing.allocator, &s2);
    try std.testing.expect(s2 == .pragma);
    try std.testing.expectEqualStrings("OFF", s2.pragma.value.?);

    var p3 = try Parser.init(std.testing.allocator, "PRAGMA foreign_key_check(kids);");
    defer p3.deinit();
    var s3 = try p3.parse();
    defer ast.deinit(std.testing.allocator, &s3);
    try std.testing.expect(s3 == .pragma);
    try std.testing.expect(s3.pragma.value == null);
    try std.testing.expectEqualStrings("kids", s3.pragma.argument.?);

    var p4 = try Parser.init(std.testing.allocator, "PRAGMA integrity_check(10);");
    defer p4.deinit();
    var s4 = try p4.parse();
    defer ast.deinit(std.testing.allocator, &s4);
    try std.testing.expect(s4 == .pragma);
    try std.testing.expectEqualStrings("10", s4.pragma.argument.?);

    var p5 = try Parser.init(std.testing.allocator, "PRAGMA integrity_check;");
    defer p5.deinit();
    var s5 = try p5.parse();
    defer ast.deinit(std.testing.allocator, &s5);
    try std.testing.expect(s5 == .pragma);
    try std.testing.expect(s5.pragma.value == null);
    try std.testing.expect(s5.pragma.argument == null);
}

test "parser parses multi-word column type names with precision" {
    var parser = try Parser.init(std.testing.allocator, "CREATE TABLE matrix (a INT, b INTEGER PRIMARY KEY, c TINYINT, d SMALLINT, e MEDIUMINT, f BIGINT, g UNSIGNED BIG INT, h INT2, i INT8, j CHARACTER(20), k VARCHAR(255), l VARYING CHARACTER(255), m NCHAR(55), n NATIVE CHARACTER(70), o NVARCHAR(100), p TEXT, q CLOB, r REAL, s DOUBLE, t DOUBLE PRECISION, u FLOAT, v FLOATING POINT, w NUMERIC, x DECIMAL(10,5), y BOOLEAN, z DATE, aa DATETIME, ab BLOB, ac VARCHAR(10) NOT NULL);");
    defer parser.deinit();
    var statement = try parser.parse();
    defer ast.deinit(std.testing.allocator, &statement);
    try std.testing.expect(statement == .createTable);
    const columns = statement.createTable.columns;
    const expected = [_][]const u8{ "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT", "UNSIGNED BIG INT", "INT2", "INT8", "CHARACTER(20)", "VARCHAR(255)", "VARYING CHARACTER(255)", "NCHAR(55)", "NATIVE CHARACTER(70)", "NVARCHAR(100)", "TEXT", "CLOB", "REAL", "DOUBLE", "DOUBLE PRECISION", "FLOAT", "FLOATING POINT", "NUMERIC", "DECIMAL(10,5)", "BOOLEAN", "DATE", "DATETIME", "BLOB", "VARCHAR(10)" };
    try std.testing.expectEqual(expected.len, columns.len);
    for (expected, 0..) |name, index| try std.testing.expectEqualStrings(name, columns[index].typeName);
    try std.testing.expect(columns[1].primaryKey);
    try std.testing.expect(columns[columns.len - 1].notNull);

    var untyped = try Parser.init(std.testing.allocator, "CREATE TABLE bare (id PRIMARY KEY);");
    defer untyped.deinit();
    var untypedStatement = try untyped.parse();
    defer ast.deinit(std.testing.allocator, &untypedStatement);
    try std.testing.expectEqualStrings("", untypedStatement.createTable.columns[0].typeName);
    try std.testing.expect(untypedStatement.createTable.columns[0].primaryKey);

    var casted = try Parser.init(std.testing.allocator, "SELECT CAST(x AS DOUBLE PRECISION) FROM t;");
    defer casted.deinit();
    var castedStatement = try casted.parse();
    defer ast.deinit(std.testing.allocator, &castedStatement);
    try std.testing.expect(castedStatement == .select);
    const call = castedStatement.select.projections[0].expr;
    try std.testing.expect(call == .function);
    try std.testing.expectEqualStrings("DOUBLE PRECISION", call.function.argument2.?.identifier);

    var empty = try Parser.init(std.testing.allocator, "SELECT CAST(x AS ) FROM t;");
    defer empty.deinit();
    try std.testing.expectError(Error.UnexpectedToken, empty.parse());
}

test "parser keeps group by qualifiers" {
    var qualified = try Parser.init(std.testing.allocator, "SELECT a.id, count(*) FROM a JOIN b ON a.id = b.aid GROUP BY a.id;");
    defer qualified.deinit();
    var qualifiedStatement = try qualified.parse();
    defer ast.deinit(std.testing.allocator, &qualifiedStatement);
    try std.testing.expect(qualifiedStatement == .select);
    try std.testing.expectEqualStrings("a.id", qualifiedStatement.select.groupBy.?);

    var bare = try Parser.init(std.testing.allocator, "SELECT id, count(*) FROM a GROUP BY id;");
    defer bare.deinit();
    var bareStatement = try bare.parse();
    defer ast.deinit(std.testing.allocator, &bareStatement);
    try std.testing.expectEqualStrings("id", bareStatement.select.groupBy.?);
}
