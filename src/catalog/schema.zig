//! In-memory catalog: tables, indexes, views, triggers, and their rows.
//!
//! Owns every descriptor string, stored value, and cloned expression.
//! `find` borrows (dangles after drop/rename/deinit); `appendRow` and the
//! create calls duplicate inputs. `deinit` frees everything exactly once.
//! DDL misuse returns the matching error; failed creates leave the schema
//! unchanged. Names resolve case-insensitively.

const std = @import("std");
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");
const exprEvaluator = @import("../sql/expr.zig");
const functions = @import("../sql/functions.zig");
const coerce = @import("../sql/coerce.zig");

/// Owned column descriptor. `name`/`typeName`/FK strings are schema-owned
/// dupes; `defaultValue` owns its text/blob payload; `checkExpr`/
/// `generatedExpr` are schema-owned cloned ASTs. Borrowed views dangle after
/// drop/rename/deinit.
pub const Column = struct { name: []u8, typeName: []u8, primaryKey: bool, notNull: bool, unique: bool = false, autoincrement: bool = false, defaultValue: ?Value = null, foreignTable: ?[]u8 = null, foreignColumn: ?[]u8 = null, onDelete: ast.ReferentialAction = .restrict, onUpdate: ast.ReferentialAction = .restrict, fkDeferrable: bool = false, fkInitiallyDeferred: bool = false, checkExpr: ?ast.Expr = null, generatedExpr: ?ast.Expr = null, generatedStored: bool = false };
/// Owned row: `values` has one entry per column and owns text/blob payloads.
/// Freed by schema lifecycle ops; never retain after drop/truncate/deinit.
pub const Row = struct { values: []Value };
/// Owned table-level constraint. Name lists and FK strings are schema-owned
/// dupes; `checkExpr` is a schema-owned cloned AST.
pub const Constraint = struct { kind: enum { primaryKey, unique, foreignKey, check }, columns: [][]u8, foreignTable: ?[]u8 = null, referencedColumns: [][]u8 = &.{}, onDelete: ast.ReferentialAction = .restrict, onUpdate: ast.ReferentialAction = .restrict, deferrable: bool = false, initiallyDeferred: bool = false, checkExpr: ?ast.Expr = null };
/// Owned table: heap-allocated by the schema (`tables` holds `*Table`).
/// `name`/columns/constraints/rows/virtual strings are schema-owned. A `*Table`
/// from `find` borrows the schema and dangles after drop/remove/deinit.
pub const Table = struct { name: []u8, columns: []Column, constraints: []Constraint, rows: std.ArrayList(Row), virtualModule: ?[]u8 = null, virtualArguments: [][]u8 = &.{}, strict: bool = false, withoutRowid: bool = false };
/// Owned index descriptor. Names/columns/SQL are schema-owned dupes;
/// `keyExprs`/`whereExpr` are schema-owned cloned ASTs.
pub const Index = struct {
    name: []u8,
    table: []u8,
    columns: [][]u8,
    keyExprs: []?ast.Expr = &.{},
    unique: bool = false,
    whereExpr: ?ast.Expr = null,
    whereSql: ?[]u8 = null,

    /// Borrowed key expression for one indexed position, or null for a plain
    /// column key. The expression stays schema-owned; do not free it.
    pub fn keyExpr(self: *const Index, position: usize) ?ast.Expr {
        if (position >= self.keyExprs.len) return null;
        return self.keyExprs[position];
    }
};
/// Owned view: `name` + stored SELECT text, both schema-owned dupes.
pub const View = struct { name: []u8, sql: []u8 };
/// Owned trigger descriptor. Names/body/SQL are schema-owned dupes;
/// `updateOf` holds owned column names (empty means "any UPDATE").
pub const Trigger = struct {
    name: []u8,
    table: []u8,
    timing: ast.TriggerTiming = .after,
    event: ast.TriggerEvent,
    updateOf: [][]u8 = &.{},
    whenSql: ?[]u8 = null,
    body: []u8,

    /// True when this trigger fires for an UPDATE touching `updatedColumns`.
    /// Non-UPDATE events and column-less UPDATE triggers always fire.
    /// Comparison is case-insensitive; borrowed inputs, never fails.
    pub fn firesOnUpdate(self: *const Trigger, updatedColumns: []const []const u8) bool {
        if (self.event != .update) return true;
        if (self.updateOf.len == 0) return true;
        for (updatedColumns) |updated| {
            for (self.updateOf) |listed| if (std.ascii.eqlIgnoreCase(updated, listed)) return true;
        }
        return false;
    }
};

/// The catalog itself. Owns all descriptors, rows, and cloned expressions.
/// Borrow the allocator for its lifetime; call `deinit` exactly once.
pub const Schema = struct {
    allocator: std.mem.Allocator,
    tables: std.ArrayList(*Table),
    indexes: std.ArrayList(Index),
    views: std.ArrayList(View),
    triggers: std.ArrayList(Trigger),
    foreignKeysEnabled: bool = true,
    /// `PRAGMA defer_foreign_keys`: every FK check postpones to COMMIT (or
    /// statement end in autocommit), including NOT DEFERRABLE constraints.
    deferForeignKeys: bool = false,

    /// Borrow an empty catalog over `allocator`. Owns nothing yet; `deinit`
    /// releases whatever is created afterwards. Never fails.
    pub fn init(allocator: std.mem.Allocator) Schema {
        return .{ .allocator = allocator, .tables = .empty, .indexes = .empty, .views = .empty, .triggers = .empty };
    }

    /// Release every owned descriptor, row, expression, and SQL string. Call
    /// exactly once; afterwards every borrowed table/index/view pointer dangles.
    pub fn deinit(self: *Schema) void {
        for (self.tables.items) |table| {
            self.deinitTable(table);
            self.allocator.destroy(table);
        }
        self.tables.deinit(self.allocator);
        for (self.indexes.items) |index| {
            self.allocator.free(index.name);
            self.allocator.free(index.table);
            for (index.columns) |column| self.allocator.free(column);
            self.allocator.free(index.columns);
            for (index.keyExprs) |maybeKey| if (maybeKey) |key| ast.freeOwnedExpr(self.allocator, key);
            self.allocator.free(index.keyExprs);
            if (index.whereExpr) |predicate| ast.freeOwnedExpr(self.allocator, predicate);
            if (index.whereSql) |sql| self.allocator.free(sql);
        }
        self.indexes.deinit(self.allocator);
        for (self.views.items) |view| {
            self.allocator.free(view.name);
            self.allocator.free(view.sql);
        }
        self.views.deinit(self.allocator);
        for (self.triggers.items) |trigger| {
            self.allocator.free(trigger.name);
            self.allocator.free(trigger.table);
            for (trigger.updateOf) |column| self.allocator.free(column);
            self.allocator.free(trigger.updateOf);
            if (trigger.whenSql) |when| self.allocator.free(when);
            self.allocator.free(trigger.body);
        }
        self.triggers.deinit(self.allocator);
    }

    fn freeValue(allocator: std.mem.Allocator, value: Value) void {
        switch (value) {
            .text => |v| allocator.free(v),
            .blob => |v| allocator.free(v),
            else => {},
        }
    }
    fn copyValue(self: *Schema, value: Value) !Value {
        return switch (value) {
            .text => |v| .{ .text = try self.allocator.dupe(u8, v) },
            .blob => |v| .{ .blob = try self.allocator.dupe(u8, v) },
            else => value,
        };
    }

    /// Mutable borrow of a table by case-insensitive name, or null. Dangles
    /// after drop/remove/rename/deinit.
    pub fn find(self: *Schema, name: []const u8) ?*Table {
        for (self.tables.items) |table| if (std.ascii.eqlIgnoreCase(table.name, name)) return table;
        return null;
    }
    /// Shared borrow of a table by case-insensitive name, or null. Same
    /// lifetime rules as `find`.
    pub fn findConst(self: *const Schema, name: []const u8) ?*const Table {
        for (self.tables.items) |table| if (std.ascii.eqlIgnoreCase(table.name, name)) return table;
        return null;
    }

    /// Mutable borrow of an index by case-insensitive name, or null.
    pub fn findIndex(self: *Schema, name: []const u8) ?*Index {
        for (self.indexes.items) |*index| if (std.ascii.eqlIgnoreCase(index.name, name)) return index;
        return null;
    }

    /// Shared borrow of an index by case-insensitive name, or null.
    pub fn findIndexConst(self: *const Schema, name: []const u8) ?*const Index {
        for (self.indexes.items) |*index| if (std.ascii.eqlIgnoreCase(index.name, name)) return index;
        return null;
    }

    /// Mutable borrow of a view by case-insensitive name, or null.
    pub fn findView(self: *Schema, name: []const u8) ?*View {
        for (self.views.items) |*view| if (std.ascii.eqlIgnoreCase(view.name, name)) return view;
        return null;
    }

    /// Shared borrow of a view by case-insensitive name, or null.
    pub fn findViewConst(self: *const Schema, name: []const u8) ?*const View {
        for (self.views.items) |*view| if (std.ascii.eqlIgnoreCase(view.name, name)) return view;
        return null;
    }

    /// Create a view, duping `name`/`sql` into the schema. Fails `ViewExists`
    /// when a table, index, or view already uses the name.
    pub fn createView(self: *Schema, name: []const u8, sql: []const u8) !void {
        if (self.find(name) != null or self.findIndexConst(name) != null or self.findView(name) != null) return error.ViewExists;
        try self.views.append(self.allocator, .{ .name = try self.allocator.dupe(u8, name), .sql = try self.allocator.dupe(u8, sql) });
    }

    /// Drop a view by name, freeing its dupes. Fails `UnknownView` when absent.
    pub fn dropView(self: *Schema, name: []const u8) !void {
        for (self.views.items, 0..) |view, position| if (std.ascii.eqlIgnoreCase(view.name, name)) {
            const removed = self.views.orderedRemove(position);
            self.allocator.free(removed.name);
            self.allocator.free(removed.sql);
            return;
        };
        return error.UnknownView;
    }

    /// Mutable borrow of a trigger by case-insensitive name, or null.
    pub fn findTrigger(self: *Schema, name: []const u8) ?*Trigger {
        for (self.triggers.items) |*trigger| if (std.ascii.eqlIgnoreCase(trigger.name, name)) return trigger;
        return null;
    }

    /// Shared borrow of a trigger by case-insensitive name, or null.
    pub fn findTriggerConst(self: *const Schema, name: []const u8) ?*const Trigger {
        for (self.triggers.items) |*trigger| if (std.ascii.eqlIgnoreCase(trigger.name, name)) return trigger;
        return null;
    }

    /// Create a trigger from a borrowed def, duping names/SQL/columns after
    /// validating the target table and UPDATE OF columns. Fails `TriggerExists`,
    /// `UnknownTable`, `UnknownColumn`, or `InvalidSql` (UPDATE OF on non-UPDATE).
    pub fn createTrigger(self: *Schema, definition: ast.TriggerDef) !void {
        if (self.findTrigger(definition.name) != null) return error.TriggerExists;
        if (definition.timing == .insteadOf) {
            // INSTEAD OF triggers live on views; the connection validates
            // UPDATE OF names against the view's output columns first.
            if (self.find(definition.table) != null) return error.InvalidSql;
            if (self.findViewConst(definition.table) == null) return error.UnknownTable;
            if (definition.event != .update and definition.updateOf.len != 0) return error.InvalidSql;
        } else {
            const table = self.find(definition.table) orelse return error.UnknownTable;
            if (definition.event != .update and definition.updateOf.len != 0) return error.InvalidSql;
            for (definition.updateOf) |name| if (self.columnIndex(table, name) == null) return error.UnknownColumn;
        }
        const whenSql = if (definition.whenSql) |when| try self.allocator.dupe(u8, when) else null;
        errdefer if (whenSql) |when| self.allocator.free(when);
        const updateOf = try self.allocator.alloc([]u8, definition.updateOf.len);
        errdefer self.allocator.free(updateOf);
        var copied: usize = 0;
        errdefer for (updateOf[0..copied]) |column| self.allocator.free(column);
        for (definition.updateOf, 0..) |column, index| {
            updateOf[index] = try self.allocator.dupe(u8, column);
            copied += 1;
        }
        try self.triggers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, definition.name), .table = try self.allocator.dupe(u8, definition.table), .timing = definition.timing, .event = definition.event, .updateOf = updateOf, .whenSql = whenSql, .body = try self.allocator.dupe(u8, definition.body) });
    }

    /// Drop a trigger by name, freeing its dupes. Fails `UnknownTrigger`.
    pub fn dropTrigger(self: *Schema, name: []const u8) !void {
        for (self.triggers.items, 0..) |trigger, position| if (std.ascii.eqlIgnoreCase(trigger.name, name)) {
            const removed = self.triggers.orderedRemove(position);
            self.allocator.free(removed.name);
            self.allocator.free(removed.table);
            for (removed.updateOf) |column| self.allocator.free(column);
            self.allocator.free(removed.updateOf);
            if (removed.whenSql) |when| self.allocator.free(when);
            self.allocator.free(removed.body);
            return;
        };
        return error.UnknownTrigger;
    }

    fn validateIndexPredicate(self: *const Schema, table: *const Table, tableName: []const u8, expr: ast.Expr, sawColumn: *bool) !void {
        switch (expr) {
            .literal => {},
            .identifier => |id| {
                const clean = if (std.mem.indexOfScalar(u8, id, '.')) |dot| blk: {
                    if (!std.ascii.eqlIgnoreCase(id[0..dot], tableName)) return error.UnknownColumn;
                    break :blk id[dot + 1 ..];
                } else id;
                if (self.columnIndex(table, clean) == null) return error.UnknownColumn;
                sawColumn.* = true;
            },
            .parameter => return error.InvalidSql,
            .wildcard => return error.InvalidSql,
            .binary => |bin| {
                try self.validateIndexPredicate(table, tableName, bin.left.*, sawColumn);
                try self.validateIndexPredicate(table, tableName, bin.right.*, sawColumn);
            },
            .unary => |un| try self.validateIndexPredicate(table, tableName, un.expr.*, sawColumn),
            .collate => |col| try self.validateIndexPredicate(table, tableName, col.expr.*, sawColumn),
            .patternMatch => |match| {
                try self.validateIndexPredicate(table, tableName, match.value.*, sawColumn);
                try self.validateIndexPredicate(table, tableName, match.pattern.*, sawColumn);
                if (match.escape) |escape| try self.validateIndexPredicate(table, tableName, escape.*, sawColumn);
            },
            .caseExpr => |caseBlock| {
                if (caseBlock.base) |base| try self.validateIndexPredicate(table, tableName, base.*, sawColumn);
                for (caseBlock.whens) |when| {
                    try self.validateIndexPredicate(table, tableName, when.condition, sawColumn);
                    try self.validateIndexPredicate(table, tableName, when.result, sawColumn);
                }
                if (caseBlock.otherwise) |otherwise| try self.validateIndexPredicate(table, tableName, otherwise.*, sawColumn);
            },
            .inList => |list| {
                try self.validateIndexPredicate(table, tableName, list.expr.*, sawColumn);
                for (list.list) |item| try self.validateIndexPredicate(table, tableName, item, sawColumn);
            },
            .function => |call| {
                // Aggregates and window functions cannot appear here; scalar
                // functions (including multi-arg min/max) validate per-arg.
                if (functions.classify(call.name, functions.argCount(call)) != .scalar) return error.InvalidSql;
                try self.validateIndexPredicate(table, tableName, call.argument.*, sawColumn);
                if (call.argument2) |argument| try self.validateIndexPredicate(table, tableName, argument.*, sawColumn);
                if (call.argument3) |argument| try self.validateIndexPredicate(table, tableName, argument.*, sawColumn);
                for (call.extraArgs) |argument| try self.validateIndexPredicate(table, tableName, argument, sawColumn);
            },
            .scalarSubquery, .existsSubquery, .inSubquery, .window => return error.InvalidSql,
        }
    }

    /// Evaluate a partial index's WHERE predicate for `values`. No predicate
    /// means "applies to all rows". Borrowed inputs; transient allocations
    /// freed before returning.
    pub fn indexPredicateHolds(self: *const Schema, table: *const Table, index: *const Index, values: []const Value) !bool {
        const predicate = index.whereExpr orelse return true;
        var colNames = try self.allocator.alloc([]const u8, table.columns.len);
        defer self.allocator.free(colNames);
        for (table.columns, 0..) |col, idx| colNames[idx] = col.name;
        return exprEvaluator.evalPredicate(self.allocator, colNames, values, predicate);
    }

    /// Compare two rows' index keys (expression keys evaluated, NULL never
    /// equal). Borrowed inputs; transient evaluation values freed internally.
    pub fn indexKeysEqual(self: *const Schema, table: *const Table, index: *const Index, colNames: []const []const u8, left: []const Value, right: []const Value) !bool {
        for (index.columns, 0..) |_, position| {
            if (index.keyExpr(position)) |key| {
                const leftVal = try exprEvaluator.eval(self.allocator, colNames, left, key);
                defer exprEvaluator.freeValue(self.allocator, leftVal);
                const rightVal = try exprEvaluator.eval(self.allocator, colNames, right, key);
                defer exprEvaluator.freeValue(self.allocator, rightVal);
                if (leftVal == .null or rightVal == .null) return false;
                if (!valuesEqual(leftVal, rightVal)) return false;
                continue;
            }
            const columnIdx = self.columnIndex(table, index.columns[position]) orelse return false;
            if (left[columnIdx] == .null or right[columnIdx] == .null) return false;
            if (!valuesEqual(left[columnIdx], right[columnIdx])) return false;
        }
        return true;
    }

    /// Create an index from a borrowed def: validates columns/key/predicate
    /// (rejecting aggregates, window-only functions, subqueries, params),
    /// clones owned state, and pre-checks UNIQUE violations against existing
    /// rows. Fails `IndexExists`/`UnknownTable`/`UnknownColumn`/`InvalidSql`/
    /// `ConstraintViolation`.
    pub fn createIndex(self: *Schema, definition: ast.IndexDef) !void {
        if (self.findIndex(definition.name) != null) return error.IndexExists;
        const table = self.find(definition.table) orelse return error.UnknownTable;
        if (definition.columns.len == 0) return error.InvalidSql;
        if (definition.keyExprs.len != 0 and definition.keyExprs.len != definition.columns.len) return error.InvalidSql;
        for (definition.columns, 0..) |name, position| {
            if (position < definition.keyExprs.len and definition.keyExprs[position] != null) continue;
            if (self.columnIndex(table, name) == null) return error.UnknownColumn;
        }
        for (definition.keyExprs) |maybeKey| if (maybeKey) |key| {
            var sawColumn = false;
            try self.validateIndexPredicate(table, definition.table, key, &sawColumn);
            if (!sawColumn) return error.InvalidSql;
        };
        var predicateColumn = false;
        if (definition.whereExpr) |predicate| try self.validateIndexPredicate(table, definition.table, predicate, &predicateColumn);
        const name = try self.allocator.dupe(u8, definition.name);
        errdefer self.allocator.free(name);
        const tableName = try self.allocator.dupe(u8, definition.table);
        errdefer self.allocator.free(tableName);
        const columns = try self.allocator.alloc([]u8, definition.columns.len);
        errdefer self.allocator.free(columns);
        var copied: usize = 0;
        errdefer for (columns[0..copied]) |column| self.allocator.free(column);
        for (definition.columns, 0..) |column, index| {
            columns[index] = try self.allocator.dupe(u8, column);
            copied += 1;
        }
        const keyExprs = try self.allocator.alloc(?ast.Expr, definition.columns.len);
        errdefer self.allocator.free(keyExprs);
        var cloned: usize = 0;
        errdefer {
            for (keyExprs[0..cloned]) |maybeKey| if (maybeKey) |key| ast.freeOwnedExpr(self.allocator, key);
        }
        for (definition.columns, 0..) |_, index| {
            keyExprs[index] = if (index < definition.keyExprs.len and definition.keyExprs[index] != null) try ast.cloneOwnedExpr(self.allocator, definition.keyExprs[index].?) else null;
            cloned += 1;
        }
        const ownedPredicate = if (definition.whereExpr) |predicate| try ast.cloneOwnedExpr(self.allocator, predicate) else null;
        errdefer if (ownedPredicate) |predicate| ast.freeOwnedExpr(self.allocator, predicate);
        const ownedWhereSql = if (definition.whereSql) |sql| try self.allocator.dupe(u8, sql) else null;
        errdefer if (ownedWhereSql) |sql| self.allocator.free(sql);
        if (definition.unique) {
            const pending = Index{ .name = name, .table = tableName, .columns = columns, .keyExprs = keyExprs, .unique = true, .whereExpr = ownedPredicate, .whereSql = ownedWhereSql };
            var colNames = try self.allocator.alloc([]const u8, table.columns.len);
            defer self.allocator.free(colNames);
            for (table.columns, 0..) |col, idx| colNames[idx] = col.name;
            for (table.rows.items, 0..) |row, rowIndex| {
                if (!try self.indexPredicateHolds(table, &pending, row.values)) continue;
                for (table.rows.items[rowIndex + 1 ..]) |other| {
                    if (!try self.indexPredicateHolds(table, &pending, other.values)) continue;
                    if (try self.indexKeysEqual(table, &pending, colNames, row.values, other.values)) return error.ConstraintViolation;
                }
            }
        }
        try self.indexes.append(self.allocator, .{ .name = name, .table = tableName, .columns = columns, .keyExprs = keyExprs, .unique = definition.unique, .whereExpr = ownedPredicate, .whereSql = ownedWhereSql });
    }

    /// Drop an index by name, freeing names/columns/cloned exprs/SQL and its
    /// stat scope. Fails `UnknownIndex` when absent.
    pub fn dropIndex(self: *Schema, name: []const u8) !void {
        for (self.indexes.items, 0..) |index, position| if (std.ascii.eqlIgnoreCase(index.name, name)) {
            self.clearStatScope(index.table, index.name);
            const removed = self.indexes.orderedRemove(position);
            self.allocator.free(removed.name);
            self.allocator.free(removed.table);
            for (removed.columns) |column| self.allocator.free(column);
            self.allocator.free(removed.columns);
            for (removed.keyExprs) |maybeKey| if (maybeKey) |key| ast.freeOwnedExpr(self.allocator, key);
            self.allocator.free(removed.keyExprs);
            if (removed.whereExpr) |predicate| ast.freeOwnedExpr(self.allocator, predicate);
            if (removed.whereSql) |sql| self.allocator.free(sql);
            return;
        };
        return error.UnknownIndex;
    }

    /// True for the six STRICT table types (INT/INTEGER/REAL/TEXT/BLOB/ANY),
    /// case-insensitive. Borrowed input; never fails.
    pub fn isValidStrictType(typeName: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(typeName, "INT")) return true;
        if (std.ascii.eqlIgnoreCase(typeName, "INTEGER")) return true;
        if (std.ascii.eqlIgnoreCase(typeName, "REAL")) return true;
        if (std.ascii.eqlIgnoreCase(typeName, "TEXT")) return true;
        if (std.ascii.eqlIgnoreCase(typeName, "BLOB")) return true;
        if (std.ascii.eqlIgnoreCase(typeName, "ANY")) return true;
        return false;
    }

    /// Coerce a borrowed `Value` to a STRICT type, passing NULL through.
    /// INT/INTEGER accept ints and integral reals; REAL widens ints; TEXT/BLOB
    /// accept only their kind; ANY passes through. Fails `ConstraintViolation`.
    /// STRICT single-value check with affinity conversion first, mirroring
    /// the reference `OP_TypeCheck`: each type applies its affinity, then
    /// the converted storage class must match. INTEGER affinity converts
    /// well-formed text numerals and lossless reals; REAL keeps small
    /// integers as integers (`IntReal`) and widens the rest past 2**47;
    /// TEXT renders numbers but never blobs; BLOB converts nothing. Blobs
    /// (not strings) skip numeric affinity entirely. NULL passes through
    /// (`NOT NULL` rejects separately).
    pub fn coerceStrict(allocator: std.mem.Allocator, typeName: []const u8, value: Value) !Value {
        if (value == .null) return .null;
        if (std.ascii.eqlIgnoreCase(typeName, "INT") or std.ascii.eqlIgnoreCase(typeName, "INTEGER")) {
            return switch (value) {
                .integer => value,
                .real => |r| if (coerce.realAffinityInt(r)) |i| .{ .integer = i } else error.ConstraintViolation,
                .text => |t| switch (coerce.affinityNumeric(t) orelse return error.ConstraintViolation) {
                    .int => |i| Value{ .integer = i },
                    .real => |r| if (coerce.realAffinityInt(r)) |i| .{ .integer = i } else error.ConstraintViolation,
                    .none => error.ConstraintViolation,
                },
                else => error.ConstraintViolation,
            };
        }
        if (std.ascii.eqlIgnoreCase(typeName, "REAL")) {
            return switch (value) {
                .real => |r| if (coerce.realAffinityInt(r)) |i| .{ .integer = i } else value,
                .integer => |i| if (i <= 140737488355327 and i >= -140737488355328) value else .{ .real = @floatFromInt(i) },
                .text => |t| switch (coerce.affinityNumeric(t) orelse return error.ConstraintViolation) {
                    .int => |i| if (i <= 140737488355327 and i >= -140737488355328) Value{ .integer = i } else .{ .real = @floatFromInt(i) },
                    .real => |r| .{ .real = r },
                    .none => error.ConstraintViolation,
                },
                else => error.ConstraintViolation,
            };
        }
        if (std.ascii.eqlIgnoreCase(typeName, "TEXT")) {
            return switch (value) {
                .text => value,
                .integer => |i| .{ .text = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
                .real => |r| .{ .text = try coerce.formatReal(allocator, r) },
                else => error.ConstraintViolation,
            };
        }
        if (std.ascii.eqlIgnoreCase(typeName, "BLOB")) {
            return switch (value) {
                .blob => value,
                else => error.ConstraintViolation,
            };
        }
        if (std.ascii.eqlIgnoreCase(typeName, "ANY")) {
            return value;
        }
        return error.ConstraintViolation;
    }

    /// DDL flags for `createTableWithOptions`. WITHOUT ROWID requires a PK;
    /// STRICT restricts column types (see `isValidStrictType`).
    pub const TableOptions = struct {
        strict: bool = false,
        withoutRowid: bool = false,
    };

    /// Create a table with default options. Dupes every name/default/expression
    /// and builds autoindexes for PK/UNIQUE scope. Fails `TableExists` and the
    /// usual DDL errors.
    pub fn createTable(self: *Schema, name: []const u8, definitions: []const ast.ColumnDef, definitionsConstraints: []const ast.TableConstraint) !void {
        return self.createTableWithOptions(name, definitions, definitionsConstraints, .{});
    }

    /// Create a table with STRICT/WITHOUT ROWID enforcement plus the base
    /// `createTable` semantics. WITHOUT ROWID without a PK, AUTOINCREMENT on a
    /// WITHOUT ROWID or non-INTEGER-PK column, and non-STRICT types under
    /// STRICT all fail (`ConstraintViolation`/`InvalidSql`).
    pub fn createTableWithOptions(self: *Schema, name: []const u8, definitions: []const ast.ColumnDef, definitionsConstraints: []const ast.TableConstraint, options: TableOptions) !void {
        if (self.find(name) != null) return error.TableExists;
        if (options.strict) {
            for (definitions) |def| {
                if (!isValidStrictType(def.typeName)) return error.ConstraintViolation;
            }
        }
        if (options.withoutRowid) {
            var hasPk = false;
            for (definitions) |def| {
                if (def.primaryKey) {
                    hasPk = true;
                    break;
                }
            }
            if (!hasPk) {
                for (definitionsConstraints) |c| {
                    if (c == .primaryKey and c.primaryKey.len > 0) {
                        hasPk = true;
                        break;
                    }
                }
            }
            if (!hasPk) return error.ConstraintViolation;
        }
        const ownedName = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(ownedName);
        const columns = try self.allocator.alloc(Column, definitions.len);
        errdefer self.allocator.free(columns);
        var count: usize = 0;
        errdefer for (columns[0..count]) |column| {
            self.allocator.free(column.name);
            self.allocator.free(column.typeName);
            if (column.defaultValue) |value| freeValue(self.allocator, value);
            if (column.foreignTable) |value| self.allocator.free(value);
            if (column.foreignColumn) |value| self.allocator.free(value);
            if (column.checkExpr) |chk| ast.freeOwnedExpr(self.allocator, chk);
            if (column.generatedExpr) |gen| ast.freeOwnedExpr(self.allocator, gen);
        };
        for (definitions, 0..) |definition, index| {
            var isPk = definition.primaryKey;
            var inPk = definition.primaryKey;
            for (definitionsConstraints) |c| {
                if (c == .primaryKey) {
                    for (c.primaryKey) |pkCol| {
                        if (std.ascii.eqlIgnoreCase(pkCol, definition.name)) {
                            inPk = true;
                            if (c.primaryKey.len == 1) isPk = true;
                            break;
                        }
                    }
                }
            }
            const isNotNull = definition.notNull or (options.withoutRowid and inPk);
            const clonedCheck = if (definition.checkExpr) |chk| try ast.cloneOwnedExpr(self.allocator, chk) else null;
            errdefer if (clonedCheck) |chk| ast.freeOwnedExpr(self.allocator, chk);
            const clonedGen = if (definition.generatedExpr) |gen| try ast.cloneOwnedExpr(self.allocator, gen) else null;
            errdefer if (clonedGen) |gen| ast.freeOwnedExpr(self.allocator, gen);

            columns[index] = blk: {
                const ownedColName = try self.allocator.dupe(u8, definition.name);
                errdefer self.allocator.free(ownedColName);
                const ownedColType = try self.allocator.dupe(u8, definition.typeName);
                errdefer self.allocator.free(ownedColType);
                const ownedColDefault = if (definition.defaultValue) |value| try self.copyValue(value) else null;
                errdefer if (ownedColDefault) |val| freeValue(self.allocator, val);
                const ownedColForeignTable = if (definition.foreignKey) |foreignKey| try self.allocator.dupe(u8, foreignKey.table) else null;
                errdefer if (ownedColForeignTable) |val| self.allocator.free(val);
                const ownedColForeignColumn = if (definition.foreignKey) |foreignKey| try self.allocator.dupe(u8, foreignKey.column) else null;
                errdefer if (ownedColForeignColumn) |val| self.allocator.free(val);
                break :blk .{
                    .name = ownedColName,
                    .typeName = ownedColType,
                    .primaryKey = isPk,
                    .notNull = isNotNull,
                    .unique = definition.unique,
                    .autoincrement = definition.autoincrement,
                    .defaultValue = ownedColDefault,
                    .foreignTable = ownedColForeignTable,
                    .foreignColumn = ownedColForeignColumn,
                    .onDelete = if (definition.foreignKey) |foreignKey| foreignKey.onDelete else .restrict,
                    .onUpdate = if (definition.foreignKey) |foreignKey| foreignKey.onUpdate else .restrict,
                    .fkDeferrable = if (definition.foreignKey) |foreignKey| foreignKey.deferrable else false,
                    .fkInitiallyDeferred = if (definition.foreignKey) |foreignKey| foreignKey.initiallyDeferred else false,
                    .checkExpr = clonedCheck,
                    .generatedExpr = clonedGen,
                    .generatedStored = definition.generatedStored,
                };
            };
            count += 1;
        }
        const constraints = try self.allocator.alloc(Constraint, definitionsConstraints.len);
        errdefer self.allocator.free(constraints);
        var constraintCount: usize = 0;
        errdefer for (constraints[0..constraintCount]) |constraint| {
            for (constraint.columns) |column| self.allocator.free(column);
            self.allocator.free(constraint.columns);
            if (constraint.foreignTable) |foreignTable| self.allocator.free(foreignTable);
            for (constraint.referencedColumns) |column| self.allocator.free(column);
            self.allocator.free(constraint.referencedColumns);
            if (constraint.checkExpr) |chk| ast.freeOwnedExpr(self.allocator, chk);
        };
        for (definitionsConstraints, 0..) |definition, index| {
            const sourceColumns = switch (definition) {
                .primaryKey => |value| value,
                .unique => |value| value,
                .foreignKey => |value| value.columns,
                .check => &.{},
            };
            const copiedColumns = try self.allocator.alloc([]u8, sourceColumns.len);
            var copiedCount: usize = 0;
            errdefer for (copiedColumns[0..copiedCount]) |column| self.allocator.free(column);
            for (sourceColumns, 0..) |column, columnIdx| {
                if (self.columnIndexByName(definitions, column) == null) return error.UnknownColumn;
                copiedColumns[columnIdx] = try self.allocator.dupe(u8, column);
                copiedCount += 1;
            }
            const clonedCheck = if (definition == .check) try ast.cloneOwnedExpr(self.allocator, definition.check) else null;
            errdefer if (clonedCheck) |chk| ast.freeOwnedExpr(self.allocator, chk);

            constraints[index] = .{
                .kind = switch (definition) {
                    .primaryKey => .primaryKey,
                    .unique => .unique,
                    .foreignKey => .foreignKey,
                    .check => .check,
                },
                .columns = copiedColumns,
                .checkExpr = clonedCheck,
            };
            switch (definition) {
                .foreignKey => |foreignKey| {
                    if (foreignKey.referencedColumns.len != sourceColumns.len) return error.ConstraintViolation;
                    const referencedColumns = try self.allocator.alloc([]u8, foreignKey.referencedColumns.len);
                    for (foreignKey.referencedColumns, 0..) |column, columnIdx| {
                        referencedColumns[columnIdx] = try self.allocator.dupe(u8, column);
                        if (self.findConst(foreignKey.table)) |parent| {
                            if (self.columnIndex(parent, column) == null) return error.UnknownColumn;
                        }
                    }
                    constraints[index].foreignTable = try self.allocator.dupe(u8, foreignKey.table);
                    constraints[index].referencedColumns = referencedColumns;
                    constraints[index].onDelete = foreignKey.onDelete;
                    constraints[index].onUpdate = foreignKey.onUpdate;
                    constraints[index].deferrable = foreignKey.deferrable;
                    constraints[index].initiallyDeferred = foreignKey.initiallyDeferred;
                },
                else => {},
            }
            constraintCount += 1;
        }
        for (definitions, 0..) |definition, index| {
            if (!definition.autoincrement) continue;
            if (options.withoutRowid) return error.InvalidSql;
            const declared = std.mem.trim(u8, definition.typeName, " \t\n\r");
            if (!std.ascii.eqlIgnoreCase(declared, "integer")) return error.InvalidSql;
            if (!columns[index].primaryKey) return error.InvalidSql;
        }
        const table = try self.allocator.create(Table);
        errdefer self.allocator.destroy(table);
        table.* = .{
            .name = ownedName,
            .columns = columns,
            .constraints = constraints,
            .rows = .empty,
            .strict = options.strict,
            .withoutRowid = options.withoutRowid,
        };
        try self.tables.append(self.allocator, table);
        for (columns) |column| {
            if (!column.autoincrement) continue;
            try self.ensureSequenceTable();
            break;
        }
        var autoindexNumber: usize = 0;
        for (constraints) |constraint| {
            if (constraint.kind == .foreignKey or constraint.kind == .check) continue;
            autoindexNumber += 1;
            const indexName = try std.fmt.allocPrint(self.allocator, "sqlite_autoindex_{s}_{d}", .{ name, autoindexNumber });
            const indexTable = try self.allocator.dupe(u8, name);
            const indexColumns = try self.allocator.alloc([]u8, constraint.columns.len);
            for (constraint.columns, 0..) |column, columnIdx| {
                indexColumns[columnIdx] = try self.allocator.dupe(u8, column);
            }
            try self.indexes.append(self.allocator, .{ .name = indexName, .table = indexTable, .columns = indexColumns, .unique = true });
        }
        const created = self.find(name).?;
        for (created.columns, 0..) |column, columnIdx| {
            if (!column.unique and !column.primaryKey) continue;
            if (rowidAliasColumn(created)) |alias| if (alias == columnIdx) continue;
            if (column.primaryKey) {
                var composite = false;
                for (constraints) |constraint| if (constraint.kind == .primaryKey and constraint.columns.len > 1) {
                    composite = true;
                    break;
                };
                if (composite) continue;
            }
            var covered = false;
            for (self.indexes.items) |existing| {
                if (!std.ascii.eqlIgnoreCase(existing.table, name)) continue;
                if (existing.columns.len != 1 or existing.keyExpr(0) != null) continue;
                if (std.ascii.eqlIgnoreCase(existing.columns[0], column.name)) {
                    covered = true;
                    break;
                }
            }
            if (covered) continue;
            autoindexNumber += 1;
            const indexName = try std.fmt.allocPrint(self.allocator, "sqlite_autoindex_{s}_{d}", .{ name, autoindexNumber });
            const indexTable = try self.allocator.dupe(u8, name);
            const indexColumns = try self.allocator.alloc([]u8, 1);
            indexColumns[0] = try self.allocator.dupe(u8, column.name);
            try self.indexes.append(self.allocator, .{ .name = indexName, .table = indexTable, .columns = indexColumns, .unique = true });
        }
    }

    /// Create the `generate_series` virtual table (the only supported module),
    /// materializing `start..stop` (inclusive, default step ±1) up to 1M rows
    /// into a single INTEGER `value` column. Fails `Unsupported`/`InvalidSql`/
    /// `VirtualTableTooLarge`/`TableExists`.
    pub fn createVirtualTable(self: *Schema, name: []const u8, module: []const u8, arguments: []const []const u8) !void {
        if (self.find(name) != null) return error.TableExists;
        if (!std.ascii.eqlIgnoreCase(module, "generate_series")) return error.Unsupported;
        if (arguments.len < 2 or arguments.len > 3) return error.InvalidSql;
        const start = std.fmt.parseInt(i64, arguments[0], 10) catch return error.InvalidSql;
        const stop = std.fmt.parseInt(i64, arguments[1], 10) catch return error.InvalidSql;
        const step = if (arguments.len == 3) std.fmt.parseInt(i64, arguments[2], 10) catch return error.InvalidSql else if (start <= stop) @as(i64, 1) else @as(i64, -1);
        if (step == 0) return error.InvalidSql;
        const definitions = [_]ast.ColumnDef{.{ .name = "value", .typeName = "INTEGER" }};
        try self.createTable(name, &definitions, &.{});
        const table = self.find(name).?;
        table.virtualModule = try self.allocator.dupe(u8, module);
        const copiedArguments = try self.allocator.alloc([]u8, arguments.len);
        for (arguments, 0..) |argument, index| copiedArguments[index] = try self.allocator.dupe(u8, argument);
        table.virtualArguments = copiedArguments;
        var current = start;
        var count: usize = 0;
        while (if (step > 0) current <= stop else current >= stop) : (current += step) {
            if (count >= 1_000_000) return error.VirtualTableTooLarge;
            const row = [_]Value{.{ .integer = current }};
            try self.appendRow(table, &row);
            count += 1;
        }
    }

    /// Drop a table and its indexes/triggers/stat scope/sequence row, freeing
    /// everything. Borrowed name; fails `UnknownTable` when absent.
    pub fn dropTable(self: *Schema, name: []const u8) !void {
        for (self.tables.items, 0..) |table, index| {
            if (std.ascii.eqlIgnoreCase(table.name, name)) {
                var indexPosition: usize = 0;
                while (indexPosition < self.indexes.items.len) {
                    if (std.ascii.eqlIgnoreCase(self.indexes.items[indexPosition].table, name)) {
                        const removed = self.indexes.orderedRemove(indexPosition);
                        self.allocator.free(removed.name);
                        self.allocator.free(removed.table);
                        for (removed.columns) |column| self.allocator.free(column);
                        self.allocator.free(removed.columns);
                        for (removed.keyExprs) |maybeKey| if (maybeKey) |key| ast.freeOwnedExpr(self.allocator, key);
                        self.allocator.free(removed.keyExprs);
                        if (removed.whereExpr) |predicate| ast.freeOwnedExpr(self.allocator, predicate);
                        if (removed.whereSql) |sql| self.allocator.free(sql);
                    } else indexPosition += 1;
                }
                var triggerPosition: usize = 0;
                while (triggerPosition < self.triggers.items.len) {
                    if (std.ascii.eqlIgnoreCase(self.triggers.items[triggerPosition].table, name)) {
                        const removed = self.triggers.orderedRemove(triggerPosition);
                        self.allocator.free(removed.name);
                        self.allocator.free(removed.table);
                        for (removed.updateOf) |column| self.allocator.free(column);
                        self.allocator.free(removed.updateOf);
                        if (removed.whenSql) |when| self.allocator.free(when);
                        self.allocator.free(removed.body);
                    } else triggerPosition += 1;
                }
                self.clearStatScope(name, null);
                if (!std.ascii.eqlIgnoreCase(name, "sqlite_sequence")) {
                    if (self.find("sqlite_sequence")) |sequence| {
                        var rowPosition: usize = 0;
                        while (rowPosition < sequence.rows.items.len) {
                            const values = sequence.rows.items[rowPosition].values;
                            var matches = false;
                            if (values.len == sequence.columns.len and values[0] == .text) {
                                if (std.ascii.eqlIgnoreCase(values[0].text, name)) matches = true;
                            }
                            if (matches) {
                                const removed = sequence.rows.orderedRemove(rowPosition);
                                for (removed.values) |value| freeValue(self.allocator, value);
                                self.allocator.free(removed.values);
                            } else rowPosition += 1;
                        }
                    }
                }
                self.removeTable(index);
                return;
            }
        }
        return error.UnknownTable;
    }

    fn renameExprIdentifier(self: *Schema, expr: *ast.Expr, scopeTable: []const u8, oldName: []const u8, newName: []const u8, isTableRename: bool) !void {
        switch (expr.*) {
            .identifier => |name| {
                if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                    const qualifier = name[0..dot];
                    const column = name[dot + 1 ..];
                    if (isTableRename) {
                        if (!std.ascii.eqlIgnoreCase(qualifier, oldName)) return;
                        const rebuilt = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ newName, column });
                        self.allocator.free(name);
                        expr.* = .{ .identifier = rebuilt };
                    } else {
                        if (!std.ascii.eqlIgnoreCase(qualifier, scopeTable)) return;
                        if (!std.ascii.eqlIgnoreCase(column, oldName)) return;
                        const rebuilt = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ qualifier, newName });
                        self.allocator.free(name);
                        expr.* = .{ .identifier = rebuilt };
                    }
                } else if (!isTableRename and std.ascii.eqlIgnoreCase(name, oldName)) {
                    const owned = try self.allocator.dupe(u8, newName);
                    self.allocator.free(name);
                    expr.* = .{ .identifier = owned };
                }
            },
            .function => |*call| {
                try self.renameExprIdentifier(@constCast(call.argument), scopeTable, oldName, newName, isTableRename);
                if (call.argument2) |argument| try self.renameExprIdentifier(@constCast(argument), scopeTable, oldName, newName, isTableRename);
                if (call.argument3) |argument| try self.renameExprIdentifier(@constCast(argument), scopeTable, oldName, newName, isTableRename);
                for (call.extraArgs) |*argument| try self.renameExprIdentifier(@constCast(argument), scopeTable, oldName, newName, isTableRename);
            },
            .binary => |*binary| {
                try self.renameExprIdentifier(@constCast(binary.left), scopeTable, oldName, newName, isTableRename);
                try self.renameExprIdentifier(@constCast(binary.right), scopeTable, oldName, newName, isTableRename);
            },
            .unary => |*unary| try self.renameExprIdentifier(@constCast(unary.expr), scopeTable, oldName, newName, isTableRename),
            .caseExpr => |*caseBlock| {
                if (caseBlock.base) |base| try self.renameExprIdentifier(@constCast(base), scopeTable, oldName, newName, isTableRename);
                for (caseBlock.whens) |*when| {
                    try self.renameExprIdentifier(&when.condition, scopeTable, oldName, newName, isTableRename);
                    try self.renameExprIdentifier(&when.result, scopeTable, oldName, newName, isTableRename);
                }
                if (caseBlock.otherwise) |otherwise| try self.renameExprIdentifier(@constCast(otherwise), scopeTable, oldName, newName, isTableRename);
            },
            .patternMatch => |*match| {
                try self.renameExprIdentifier(@constCast(match.value), scopeTable, oldName, newName, isTableRename);
                try self.renameExprIdentifier(@constCast(match.pattern), scopeTable, oldName, newName, isTableRename);
                if (match.escape) |escape| try self.renameExprIdentifier(@constCast(escape), scopeTable, oldName, newName, isTableRename);
            },
            .collate => |*node| try self.renameExprIdentifier(@constCast(node.expr), scopeTable, oldName, newName, isTableRename),
            .inList => |*inL| {
                try self.renameExprIdentifier(@constCast(inL.expr), scopeTable, oldName, newName, isTableRename);
                for (inL.list) |*item| try self.renameExprIdentifier(@constCast(item), scopeTable, oldName, newName, isTableRename);
            },
            .window => |*window| {
                if (window.argument) |argument| try self.renameExprIdentifier(@constCast(argument), scopeTable, oldName, newName, isTableRename);
                if (window.argument2) |argument| try self.renameExprIdentifier(@constCast(argument), scopeTable, oldName, newName, isTableRename);
                for (window.extraArgs) |*argument| try self.renameExprIdentifier(@constCast(argument), scopeTable, oldName, newName, isTableRename);
                for (window.partitionBy) |*part| try self.renameExprIdentifier(@constCast(part), scopeTable, oldName, newName, isTableRename);
            },
            .inSubquery => |*sub| try self.renameExprIdentifier(@constCast(sub.expr), scopeTable, oldName, newName, isTableRename),
            .literal, .parameter, .wildcard, .scalarSubquery, .existsSubquery => {},
        }
    }

    fn viewTargetsSingleTable(self: *Schema, sql: []const u8, tableName: []const u8) bool {
        const lexer = @import("../sql/lexer.zig");
        const Tag = @import("../sql/token.zig").Tag;
        const tokens = lexer.tokenize(self.allocator, sql) catch return false;
        defer self.allocator.free(tokens);
        var depth: usize = 0;
        var fromCount: usize = 0;
        var index: usize = 0;
        while (index < tokens.len) : (index += 1) {
            const token = tokens[index];
            if (token.tag == Tag.lparen) {
                depth += 1;
                continue;
            }
            if (token.tag == Tag.rparen) {
                if (depth > 0) depth -= 1;
                continue;
            }
            if (token.tag != Tag.word) continue;
            if (depth == 0 and std.ascii.eqlIgnoreCase(token.text, "join")) return false;
            if (depth == 0 and std.ascii.eqlIgnoreCase(token.text, "from")) {
                fromCount += 1;
                if (fromCount > 1) return false;
                var cursor = index + 1;
                while (true) {
                    if (cursor >= tokens.len or tokens[cursor].tag != Tag.word) return false;
                    if (!std.ascii.eqlIgnoreCase(tokens[cursor].text, tableName)) return false;
                    cursor += 1;
                    if (cursor < tokens.len and tokens[cursor].tag == Tag.comma) {
                        cursor += 1;
                        continue;
                    }
                    break;
                }
                index = cursor - 1;
                continue;
            }
            if (depth > 0 and std.ascii.eqlIgnoreCase(token.text, "from")) return false;
        }
        return fromCount == 1;
    }

    fn isRewriteKeyword(name: []const u8) bool {
        const keywords = [_][]const u8{ "and", "or", "not", "null", "is", "isnull", "notnull", "like", "glob", "between", "in", "case", "when", "then", "else", "end", "cast", "collate", "escape", "exists", "as", "on" };
        for (keywords) |keyword| if (std.ascii.eqlIgnoreCase(name, keyword)) return true;
        return false;
    }

    fn rewriteStoredSql(self: *Schema, sql: []const u8, qualifiers: []const []const u8, oldName: []const u8, newName: []const u8, isTableRename: bool, bareOldName: ?[]const u8) !?[]u8 {
        const lexer = @import("../sql/lexer.zig");
        const Tag = @import("../sql/token.zig").Tag;
        const tokens = lexer.tokenize(self.allocator, sql) catch return null;
        defer self.allocator.free(tokens);
        const bareKeyword = if (bareOldName) |bare| isRewriteKeyword(bare) else true;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        var cursor: usize = 0;
        var changed = false;
        for (tokens, 0..) |token, index| {
            if (token.tag != Tag.word) continue;
            const bareMatch = if (bareOldName) |bare| std.ascii.eqlIgnoreCase(token.text, bare) else false;
            if (!bareMatch and !std.ascii.eqlIgnoreCase(token.text, oldName)) continue;
            var span = token.text.len;
            if (token.position < sql.len and (sql[token.position] == '"' or sql[token.position] == '`')) span += 2;
            var replace = bareMatch and !isTableRename and !bareKeyword;
            if (replace and index + 1 < tokens.len and tokens[index + 1].tag == Tag.lparen) replace = false;
            if (isTableRename) {
                if (index + 1 < tokens.len and tokens[index + 1].tag == Tag.dot) {
                    replace = true;
                } else if (index == 0 or tokens[index - 1].tag != Tag.dot) {
                    if (index > 0 and tokens[index - 1].tag == Tag.word) {
                        const keyword = tokens[index - 1].text;
                        replace = std.ascii.eqlIgnoreCase(keyword, "from") or std.ascii.eqlIgnoreCase(keyword, "join") or std.ascii.eqlIgnoreCase(keyword, "into") or std.ascii.eqlIgnoreCase(keyword, "update") or std.ascii.eqlIgnoreCase(keyword, "table") or std.ascii.eqlIgnoreCase(keyword, "on");
                    }
                }
            } else {
                if (index >= 2 and tokens[index - 1].tag == Tag.dot and tokens[index - 2].tag == Tag.word) {
                    for (qualifiers) |qualifier| {
                        if (std.ascii.eqlIgnoreCase(tokens[index - 2].text, qualifier)) {
                            replace = true;
                            break;
                        }
                    }
                }
            }
            if (!replace) continue;
            try out.appendSlice(self.allocator, sql[cursor..token.position]);
            if (token.position < sql.len and (sql[token.position] == '"' or sql[token.position] == '`')) {
                try out.append(self.allocator, sql[token.position]);
                try out.appendSlice(self.allocator, newName);
                try out.append(self.allocator, sql[token.position]);
            } else {
                try out.appendSlice(self.allocator, newName);
            }
            cursor = token.position + span;
            changed = true;
        }
        if (!changed) {
            out.deinit(self.allocator);
            return null;
        }
        try out.appendSlice(self.allocator, sql[cursor..]);
        return try out.toOwnedSlice(self.allocator);
    }

    fn rewriteTriggerSql(self: *Schema, trigger: *Trigger, qualifiers: []const []const u8, oldName: []const u8, newName: []const u8, isTableRename: bool) !void {
        if (trigger.whenSql) |when| {
            if (try self.rewriteStoredSql(when, qualifiers, oldName, newName, isTableRename, null)) |rewritten| {
                self.allocator.free(when);
                trigger.whenSql = rewritten;
            }
        }
        if (try self.rewriteStoredSql(trigger.body, qualifiers, oldName, newName, isTableRename, null)) |rewritten| {
            self.allocator.free(trigger.body);
            trigger.body = rewritten;
        }
    }

    fn renameIndexSqlFragments(self: *Schema, tableName: []const u8, oldName: []const u8, newName: []const u8, isTableRename: bool, allowBare: bool) !void {
        const qualifiers = [_][]const u8{tableName};
        for (self.indexes.items) |*index| {
            if (!std.ascii.eqlIgnoreCase(index.table, tableName)) continue;
            for (index.columns, 0..) |column, position| {
                if (position >= index.keyExprs.len or index.keyExprs[position] == null) continue;
                if (try self.rewriteStoredSql(column, &qualifiers, oldName, newName, isTableRename, if (allowBare) oldName else null)) |rewritten| {
                    self.allocator.free(column);
                    index.columns[position] = rewritten;
                }
            }
            if (index.whereSql) |predicate| {
                if (try self.rewriteStoredSql(predicate, &qualifiers, oldName, newName, isTableRename, if (allowBare) oldName else null)) |rewritten| {
                    self.allocator.free(predicate);
                    index.whereSql = rewritten;
                }
            }
        }
    }

    fn renameStoredExprs(self: *Schema, tableName: []const u8, oldName: []const u8, newName: []const u8, isTableRename: bool) !void {
        for (self.tables.items) |other| {
            if (!std.ascii.eqlIgnoreCase(other.name, tableName)) continue;
            for (other.columns) |*column| {
                if (column.checkExpr) |*check| try self.renameExprIdentifier(check, other.name, oldName, newName, isTableRename);
                if (column.generatedExpr) |*generated| try self.renameExprIdentifier(generated, other.name, oldName, newName, isTableRename);
            }
            for (other.constraints) |*constraint| {
                if (constraint.checkExpr) |*check| try self.renameExprIdentifier(check, other.name, oldName, newName, isTableRename);
            }
        }
        for (self.indexes.items) |*index| {
            if (!std.ascii.eqlIgnoreCase(index.table, tableName)) continue;
            for (index.keyExprs) |*maybeKey| if (maybeKey.*) |*key| try self.renameExprIdentifier(key, index.table, oldName, newName, isTableRename);
            if (index.whereExpr) |*predicate| try self.renameExprIdentifier(predicate, index.table, oldName, newName, isTableRename);
        }
    }

    /// Rename a table, updating indexes, triggers, FK references, sequence
    /// rows, stored expressions, and stored view/trigger/index SQL. Borrowed
    /// names; fails `TableExists`/`UnknownTable`.
    pub fn renameTable(self: *Schema, oldName: []const u8, newName: []const u8) !void {
        if (self.find(newName) != null) return error.TableExists;
        const table = self.find(oldName) orelse return error.UnknownTable;
        const owned = try self.allocator.dupe(u8, newName);
        self.allocator.free(table.name);
        table.name = owned;
        for (self.indexes.items) |*idx| {
            if (std.ascii.eqlIgnoreCase(idx.table, oldName)) {
                self.allocator.free(idx.table);
                idx.table = try self.allocator.dupe(u8, newName);
            }
        }
        for (self.triggers.items) |*trg| {
            if (std.ascii.eqlIgnoreCase(trg.table, oldName)) {
                self.allocator.free(trg.table);
                trg.table = try self.allocator.dupe(u8, newName);
            }
        }
        for (self.tables.items) |other| {
            for (other.columns) |*column| {
                if (column.foreignTable) |foreignTable| {
                    if (std.ascii.eqlIgnoreCase(foreignTable, oldName)) {
                        self.allocator.free(foreignTable);
                        column.foreignTable = try self.allocator.dupe(u8, newName);
                    }
                }
            }
            for (other.constraints) |*constraint| {
                if (constraint.foreignTable) |foreignTable| {
                    if (std.ascii.eqlIgnoreCase(foreignTable, oldName)) {
                        self.allocator.free(foreignTable);
                        constraint.foreignTable = try self.allocator.dupe(u8, newName);
                    }
                }
            }
        }
        if (self.find("sqlite_sequence")) |sequence| {
            for (sequence.rows.items) |*row| {
                if (row.values.len != sequence.columns.len) continue;
                if (row.values[0] != .text) continue;
                if (!std.ascii.eqlIgnoreCase(row.values[0].text, oldName)) continue;
                freeValue(self.allocator, row.values[0]);
                row.values[0] = .{ .text = try self.allocator.dupe(u8, newName) };
            }
        }
        try self.renameStoredExprs(newName, oldName, newName, true);
        try self.renameIndexSqlFragments(newName, oldName, newName, true, false);
        const noQualifiers: []const []const u8 = &.{};
        for (self.triggers.items) |*trigger| try self.rewriteTriggerSql(trigger, noQualifiers, oldName, newName, true);
        for (self.views.items) |*view| {
            if (try self.rewriteStoredSql(view.sql, noQualifiers, oldName, newName, true, null)) |rewritten| {
                self.allocator.free(view.sql);
                view.sql = rewritten;
            }
        }
    }

    /// Delete all rows, freeing payloads but retaining capacity and the
    /// descriptor. Fails `UnknownTable` when absent.
    pub fn truncateTable(self: *Schema, name: []const u8) !void {
        const table = self.find(name) orelse return error.UnknownTable;
        for (table.rows.items) |row| {
            for (row.values) |value| freeValue(self.allocator, value);
            self.allocator.free(row.values);
        }
        table.rows.clearRetainingCapacity();
    }

    /// Append a column, backfilling existing rows with the default (or NULL)
    /// and evaluating GENERATED values plus CHECKs. Rejects PK/UNIQUE/
    /// AUTOINCREMENT, NOT NULL-without-default on non-empty tables, and
    /// non-STRICT types under STRICT. Atomic: new row images are fully staged
    /// in scratch (defaults, GENERATED values, CHECKs) before anything is
    /// swapped in, so any allocation or constraint failure leaves the table
    /// exactly as it was.
    pub fn addColumn(self: *Schema, tableName: []const u8, definition: ast.ColumnDef) !void {
        const table = self.find(tableName) orelse return error.UnknownTable;
        for (table.columns) |column| if (std.ascii.eqlIgnoreCase(column.name, definition.name)) return error.ColumnExists;
        if (table.strict and !isValidStrictType(definition.typeName)) return error.ConstraintViolation;
        if (definition.primaryKey or definition.unique or definition.autoincrement) return error.ConstraintViolation;
        if (definition.notNull and definition.defaultValue == null and table.rows.items.len != 0 and definition.generatedExpr == null) return error.ConstraintViolation;

        var clonedCheck = if (definition.checkExpr) |chk| try ast.cloneOwnedExpr(self.allocator, chk) else null;
        errdefer if (clonedCheck) |chk| ast.freeOwnedExpr(self.allocator, chk);
        var clonedGen = if (definition.generatedExpr) |gen| try ast.cloneOwnedExpr(self.allocator, gen) else null;
        errdefer if (clonedGen) |gen| ast.freeOwnedExpr(self.allocator, gen);

        const newColumns = try self.allocator.alloc(Column, table.columns.len + 1);
        errdefer self.allocator.free(newColumns);
        for (table.columns, 0..) |column, index| newColumns[index] = column;
        // Built in a block so a mid-literal allocation failure frees only
        // the pieces duped so far (a flat literal would leak them, since the
        // array-level errdefer below cannot see partial fields).
        newColumns[table.columns.len] = blk: {
            const ownedName = try self.allocator.dupe(u8, definition.name);
            errdefer self.allocator.free(ownedName);
            const ownedType = try self.allocator.dupe(u8, definition.typeName);
            errdefer self.allocator.free(ownedType);
            const ownedDefault = if (definition.defaultValue) |value| try self.copyValue(value) else null;
            errdefer if (ownedDefault) |val| freeValue(self.allocator, val);
            const ownedForeignTable = if (definition.foreignKey) |foreignKey| try self.allocator.dupe(u8, foreignKey.table) else null;
            errdefer if (ownedForeignTable) |val| self.allocator.free(val);
            const ownedForeignColumn = if (definition.foreignKey) |foreignKey| try self.allocator.dupe(u8, foreignKey.column) else null;
            errdefer if (ownedForeignColumn) |val| self.allocator.free(val);
            break :blk .{
                .name = ownedName,
                .typeName = ownedType,
                .primaryKey = definition.primaryKey,
                .notNull = definition.notNull,
                .unique = definition.unique,
                .autoincrement = definition.autoincrement,
                .defaultValue = ownedDefault,
                .foreignTable = ownedForeignTable,
                .foreignColumn = ownedForeignColumn,
                .onDelete = if (definition.foreignKey) |foreignKey| foreignKey.onDelete else .noAction,
                .onUpdate = if (definition.foreignKey) |foreignKey| foreignKey.onUpdate else .noAction,
                .fkDeferrable = if (definition.foreignKey) |foreignKey| foreignKey.deferrable else false,
                .fkInitiallyDeferred = if (definition.foreignKey) |foreignKey| foreignKey.initiallyDeferred else false,
                .checkExpr = clonedCheck,
                .generatedExpr = clonedGen,
                .generatedStored = definition.generatedStored,
            };
        };
        // Ownership moved into newColumns above: disarm the clone errdefers
        // so a later staging failure frees each expression exactly once (via
        // the array-level errdefer below, not here).
        clonedCheck = null;
        clonedGen = null;
        errdefer {
            self.allocator.free(newColumns[table.columns.len].name);
            self.allocator.free(newColumns[table.columns.len].typeName);
            if (newColumns[table.columns.len].defaultValue) |val| freeValue(self.allocator, val);
            if (newColumns[table.columns.len].foreignTable) |val| self.allocator.free(val);
            if (newColumns[table.columns.len].foreignColumn) |val| self.allocator.free(val);
            if (newColumns[table.columns.len].checkExpr) |chk| ast.freeOwnedExpr(self.allocator, chk);
            if (newColumns[table.columns.len].generatedExpr) |gen| ast.freeOwnedExpr(self.allocator, gen);
        }

        const defaultVal = if (definition.defaultValue) |value| value else .null;
        // Stage every new row image in scratch: a failure anywhere below
        // (default copy, GENERATED eval, CHECK) frees scratch and leaves the
        // table untouched.
        const staged = try self.allocator.alloc([]Value, table.rows.items.len);
        errdefer self.allocator.free(staged);
        var stagedCount: usize = 0;
        errdefer {
            for (staged[0..stagedCount]) |values| {
                for (values) |value| freeValue(self.allocator, value);
                self.allocator.free(values);
            }
        }
        for (table.rows.items) |row| {
            // Deep copy: staged rows must own their payloads, since the
            // commit phase below frees every old payload.
            const values = try self.allocator.alloc(Value, row.values.len + 1);
            var copied: usize = 0;
            errdefer {
                for (values[0..copied]) |value| freeValue(self.allocator, value);
                self.allocator.free(values);
            }
            for (row.values, 0..) |value, index| {
                values[index] = try self.copyValue(value);
                copied += 1;
            }
            values[row.values.len] = try self.copyValue(defaultVal);
            staged[stagedCount] = values;
            stagedCount += 1;
        }

        var colNames = try self.allocator.alloc([]const u8, newColumns.len);
        defer self.allocator.free(colNames);
        for (newColumns, 0..) |col, idx| colNames[idx] = col.name;

        if (definition.generatedExpr) |genExpr| {
            for (staged[0..stagedCount]) |rowValues| {
                const genVal = try exprEvaluator.eval(self.allocator, colNames, rowValues, genExpr);
                freeValue(self.allocator, rowValues[rowValues.len - 1]);
                rowValues[rowValues.len - 1] = genVal;
            }
        }
        if (definition.checkExpr) |chk| {
            for (staged[0..stagedCount]) |rowValues| {
                const passed = try exprEvaluator.evalCheck(self.allocator, colNames, rowValues, chk);
                if (!passed) return error.ConstraintViolation;
            }
        }

        // Commit: infallible swap of row images, then of the column list.
        for (table.rows.items, 0..) |*row, index| {
            for (row.values) |value| freeValue(self.allocator, value);
            self.allocator.free(row.values);
            row.values = staged[index];
        }
        self.allocator.free(staged);
        self.allocator.free(table.columns);
        table.columns = newColumns;
    }

    /// Rename a column, updating indexes, constraints, FK references, trigger
    /// UPDATE OF lists/bodies, view SQL, and stored CHECK/GENERATED/index
    /// expressions. Borrowed names; fails `UnknownTable`/`UnknownColumn`/
    /// `ColumnExists`.
    pub fn renameColumn(self: *Schema, tableName: []const u8, oldName: []const u8, newName: []const u8) !void {
        const table = self.find(tableName) orelse return error.UnknownTable;
        if (self.columnIndex(table, newName)) |_| return error.ColumnExists;
        const index = self.columnIndex(table, oldName) orelse return error.UnknownColumn;
        const owned = try self.allocator.dupe(u8, newName);
        self.allocator.free(table.columns[index].name);
        table.columns[index].name = owned;
        for (self.indexes.items) |*idx| {
            if (std.ascii.eqlIgnoreCase(idx.table, tableName)) {
                for (idx.columns, 0..) |col, cIdx| {
                    if (std.ascii.eqlIgnoreCase(col, oldName)) {
                        self.allocator.free(col);
                        idx.columns[cIdx] = try self.allocator.dupe(u8, newName);
                    }
                }
            }
        }
        for (table.constraints) |*constraint| {
            for (constraint.columns, 0..) |col, cIdx| {
                if (std.ascii.eqlIgnoreCase(col, oldName)) {
                    self.allocator.free(col);
                    constraint.columns[cIdx] = try self.allocator.dupe(u8, newName);
                }
            }
        }
        for (self.tables.items) |other| {
            for (other.columns) |*column| {
                if (column.foreignTable) |foreignTable| {
                    if (std.ascii.eqlIgnoreCase(foreignTable, tableName)) {
                        if (column.foreignColumn) |foreignColumn| {
                            if (std.ascii.eqlIgnoreCase(foreignColumn, oldName)) {
                                self.allocator.free(foreignColumn);
                                column.foreignColumn = try self.allocator.dupe(u8, newName);
                            }
                        }
                    }
                }
            }
            for (other.constraints) |*constraint| {
                if (constraint.foreignTable) |foreignTable| {
                    if (std.ascii.eqlIgnoreCase(foreignTable, tableName)) {
                        for (constraint.referencedColumns, 0..) |referenced, rIdx| {
                            if (std.ascii.eqlIgnoreCase(referenced, oldName)) {
                                self.allocator.free(referenced);
                                constraint.referencedColumns[rIdx] = try self.allocator.dupe(u8, newName);
                            }
                        }
                    }
                }
            }
        }
        for (self.triggers.items) |*trigger| {
            if (!std.ascii.eqlIgnoreCase(trigger.table, tableName)) continue;
            for (trigger.updateOf, 0..) |listed, position| {
                if (std.ascii.eqlIgnoreCase(listed, oldName)) {
                    self.allocator.free(listed);
                    trigger.updateOf[position] = try self.allocator.dupe(u8, newName);
                }
            }
            const rowQualifiers = [_][]const u8{ tableName, "NEW", "OLD" };
            try self.rewriteTriggerSql(trigger, &rowQualifiers, oldName, newName, false);
        }
        const tableQualifier = [_][]const u8{tableName};
        for (self.views.items) |*view| {
            const bare: ?[]const u8 = if (self.viewTargetsSingleTable(view.sql, tableName)) oldName else null;
            if (try self.rewriteStoredSql(view.sql, &tableQualifier, oldName, newName, false, bare)) |rewritten| {
                self.allocator.free(view.sql);
                view.sql = rewritten;
            }
        }
        try self.renameStoredExprs(tableName, oldName, newName, false);
        try self.renameIndexSqlFragments(tableName, oldName, newName, false, true);
    }

    /// Drop a column and its row slots, freeing the descriptor. Rejects the
    /// last column, PK/UNIQUE members, constraint/FK/index references. Atomic:
    /// narrowed row images are staged in scratch before anything is dropped,
    /// so an allocation failure leaves every row at the old width.
    pub fn dropColumn(self: *Schema, tableName: []const u8, columnName: []const u8) !void {
        const table = self.find(tableName) orelse return error.UnknownTable;
        const index = self.columnIndex(table, columnName) orelse return error.UnknownColumn;
        if (table.columns.len == 1) return error.ConstraintViolation;
        if (table.columns[index].primaryKey or table.columns[index].unique) return error.ConstraintViolation;
        for (table.constraints) |constraint| {
            for (constraint.columns) |c| if (std.ascii.eqlIgnoreCase(c, columnName)) return error.ConstraintViolation;
            for (constraint.referencedColumns) |c| if (std.ascii.eqlIgnoreCase(c, columnName)) return error.ConstraintViolation;
        }
        for (self.tables.items) |otherTable| {
            for (otherTable.columns) |c| {
                if (c.foreignTable) |ft| if (std.ascii.eqlIgnoreCase(ft, tableName)) {
                    if (c.foreignColumn) |fc| if (std.ascii.eqlIgnoreCase(fc, columnName)) return error.ConstraintViolation;
                };
            }
            for (otherTable.constraints) |c| {
                if (c.foreignTable) |ft| if (std.ascii.eqlIgnoreCase(ft, tableName)) {
                    for (c.referencedColumns) |rc| if (std.ascii.eqlIgnoreCase(rc, columnName)) return error.ConstraintViolation;
                };
            }
        }
        for (self.indexes.items) |idx| {
            if (std.ascii.eqlIgnoreCase(idx.table, tableName)) {
                for (idx.columns) |c| if (std.ascii.eqlIgnoreCase(c, columnName)) return error.ConstraintViolation;
            }
        }
        const oldColumn = table.columns[index];
        var newColumns = try self.allocator.alloc(Column, table.columns.len - 1);
        // Contents stay borrowed until commit; only the array is owned here.
        errdefer self.allocator.free(newColumns);
        var targetIndex: usize = 0;
        for (table.columns, 0..) |column, sourceIndex| {
            if (sourceIndex == index) continue;
            newColumns[targetIndex] = column;
            targetIndex += 1;
        }
        // Stage narrowed rows: payloads stay owned by the live rows until
        // commit, so staging cleanup frees arrays only, never payloads.
        const staged = try self.allocator.alloc([]Value, table.rows.items.len);
        errdefer self.allocator.free(staged);
        var stagedCount: usize = 0;
        errdefer {
            for (staged[0..stagedCount]) |values| self.allocator.free(values);
        }
        for (table.rows.items) |row| {
            const newValues = try self.allocator.alloc(Value, row.values.len - 1);
            var valueIndex: usize = 0;
            for (row.values, 0..) |value, sourceIndex| {
                if (sourceIndex == index) continue;
                newValues[valueIndex] = value;
                valueIndex += 1;
            }
            staged[stagedCount] = newValues;
            stagedCount += 1;
        }
        // Commit: drop each removed payload, swap arrays and descriptors.
        for (table.rows.items, 0..) |*row, position| {
            freeValue(self.allocator, row.values[index]);
            self.allocator.free(row.values);
            row.values = staged[position];
        }
        self.allocator.free(staged);
        self.allocator.free(oldColumn.name);
        self.allocator.free(oldColumn.typeName);
        if (oldColumn.defaultValue) |value| freeValue(self.allocator, value);
        if (oldColumn.foreignTable) |value| self.allocator.free(value);
        if (oldColumn.foreignColumn) |value| self.allocator.free(value);
        if (oldColumn.checkExpr) |chk| ast.freeOwnedExpr(self.allocator, chk);
        if (oldColumn.generatedExpr) |gen| ast.freeOwnedExpr(self.allocator, gen);
        self.allocator.free(table.columns);
        table.columns = newColumns;
    }

    fn columnIndex(self: *const Schema, table: *const Table, name: []const u8) ?usize {
        _ = self;
        for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
        return null;
    }

    fn columnIndexByName(self: *const Schema, definitions: []const ast.ColumnDef, name: []const u8) ?usize {
        _ = self;
        for (definitions, 0..) |definition, index| if (std.ascii.eqlIgnoreCase(definition.name, name)) return index;
        return null;
    }

    fn removeTable(self: *Schema, index: usize) void {
        const table = self.tables.orderedRemove(index);
        self.deinitTable(table);
        self.allocator.destroy(table);
    }

    fn deinitTable(self: *Schema, table: *Table) void {
        for (table.rows.items) |row| {
            for (row.values) |value| freeValue(self.allocator, value);
            self.allocator.free(row.values);
        }
        table.rows.deinit(self.allocator);
        for (table.columns) |column| {
            self.allocator.free(column.name);
            self.allocator.free(column.typeName);
            if (column.defaultValue) |value| freeValue(self.allocator, value);
            if (column.foreignTable) |value| self.allocator.free(value);
            if (column.foreignColumn) |value| self.allocator.free(value);
            if (column.checkExpr) |chk| ast.freeOwnedExpr(self.allocator, chk);
            if (column.generatedExpr) |gen| ast.freeOwnedExpr(self.allocator, gen);
        }
        self.allocator.free(table.columns);
        for (table.constraints) |constraint| {
            for (constraint.columns) |column| self.allocator.free(column);
            self.allocator.free(constraint.columns);
            if (constraint.foreignTable) |foreignTable| self.allocator.free(foreignTable);
            for (constraint.referencedColumns) |column| self.allocator.free(column);
            self.allocator.free(constraint.referencedColumns);
            if (constraint.checkExpr) |chk| ast.freeOwnedExpr(self.allocator, chk);
        }
        self.allocator.free(table.constraints);
        if (table.virtualModule) |module| self.allocator.free(module);
        for (table.virtualArguments) |argument| self.allocator.free(argument);
        self.allocator.free(table.virtualArguments);
        self.allocator.free(table.name);
    }

    /// Position of the INTEGER-PRIMARY-KEY rowid alias, or null for WITHOUT
    /// ROWID, composite PKs, or non-INTEGER PKs. Borrowed table; never fails.
    pub fn rowidAliasColumn(table: *const Table) ?usize {
        if (table.withoutRowid) return null;
        var found: ?usize = null;
        for (table.columns, 0..) |column, index| {
            if (!column.primaryKey) continue;
            if (found != null) return null;
            found = index;
        }
        const alias = found orelse return null;
        for (table.constraints) |constraint| {
            if (constraint.kind == .primaryKey and constraint.columns.len > 1) return null;
        }
        const declared = std.mem.trim(u8, table.columns[alias].typeName, " \t\n\r");
        if (!std.ascii.eqlIgnoreCase(declared, "integer")) return null;
        return alias;
    }

    fn assignRowidAlias(table: *const Table, values: []Value) !void {
        const alias = rowidAliasColumn(table) orelse return;
        if (values[alias] != .null) return;
        var max: ?i64 = null;
        for (table.rows.items) |existing| {
            switch (existing.values[alias]) {
                .integer => |current| {
                    if (max) |best| {
                        if (current > best) max = current;
                    } else max = current;
                },
                else => {},
            }
        }
        const next = if (max) |best| blk: {
            if (best == std.math.maxInt(i64)) return error.ConstraintViolation;
            break :blk best + 1;
        } else 1;
        values[alias] = .{ .integer = next };
    }

    /// Append a borrowed row: dupes payloads, assigns AUTOINCREMENT/rowid
    /// aliases, evaluates GENERATED columns to fixpoint, enforces STRICT and
    /// NOT NULL, then validates constraints. Fails `ColumnCountMismatch`/
    /// `ConstraintViolation`.
    pub fn appendRow(self: *Schema, table: *Table, values: []const Value) !void {
        if (values.len != table.columns.len) return error.ColumnCountMismatch;
        const owned = try self.allocator.alloc(Value, values.len);
        errdefer self.allocator.free(owned);
        var count: usize = 0;
        errdefer for (owned[0..count]) |value| freeValue(self.allocator, value);
        for (values, 0..) |value, index| {
            owned[index] = try self.copyValue(value);
            count += 1;
        }
        try self.applyAutoincrement(table, owned);
        try assignRowidAlias(table, owned);
        var colNames = try self.allocator.alloc([]const u8, table.columns.len);
        defer self.allocator.free(colNames);
        for (table.columns, 0..) |col, idx| colNames[idx] = col.name;

        var pass: usize = 0;
        while (pass < table.columns.len) : (pass += 1) {
            var anyChanged = false;
            for (table.columns, 0..) |col, index| {
                if (col.generatedExpr) |genExpr| {
                    const genVal = try exprEvaluator.eval(self.allocator, colNames, owned, genExpr);
                    if (!owned[index].sameValue(genVal)) {
                        freeValue(self.allocator, owned[index]);
                        owned[index] = genVal;
                        anyChanged = true;
                    } else {
                        freeValue(self.allocator, genVal);
                    }
                }
            }
            if (!anyChanged) break;
        }
        if (table.strict) {
            for (table.columns, 0..) |col, index| {
                // VIRTUAL generated columns skip the check (like the
                // reference OP_TypeCheck); STORED ones are checked.
                if (col.generatedExpr != null and !col.generatedStored) continue;
                const old = owned[index];
                const coerced = try coerceStrict(self.allocator, col.typeName, old);
                // Affinity rendering allocates a replacement (numbers to
                // TEXT); release the staged payload it supersedes. Staged
                // slots are always owned here, and pass-through keeps the
                // same buffer (pointer check, never a double free).
                const dropped = switch (old) {
                    .text => |t| if (coerced == .text) coerced.text.ptr != t.ptr else true,
                    .blob => |b| if (coerced == .blob) coerced.blob.ptr != b.ptr else true,
                    else => false,
                };
                if (dropped) freeValue(self.allocator, old);
                owned[index] = coerced;
            }
        }
        for (table.columns, 0..) |col, index| {
            if (col.notNull and owned[index] == .null) return error.ConstraintViolation;
        }
        try self.validateConstraints(table, owned, null);
        try table.rows.append(self.allocator, .{ .values = owned });
    }

    /// Validate a proposed in-place row update (AUTOINCREMENT/rowid/STRICT/
    /// NOT NULL/constraints, ignoring the row itself for uniqueness). The
    /// caller applies the mutation only on success.
    pub fn validateUpdate(self: *Schema, table: *const Table, rowIndex: usize, values: []Value) !void {
        try self.applyAutoincrement(table, values);
        try assignRowidAlias(table, values);
        if (table.strict) {
            for (table.columns, 0..) |col, index| {
                if (col.generatedExpr != null and !col.generatedStored) continue;
                _ = try coerceStrict(self.allocator, col.typeName, values[index]);
            }
        }
        for (table.columns, 0..) |col, index| {
            if (col.notNull and values[index] == .null) return error.ConstraintViolation;
        }
        try self.validateConstraints(table, values, rowIndex);
    }

    /// Re-validate a stored row in place (shape, NOT NULL, constraints).
    /// Used after external row surgery; fails `ConstraintViolation` on drift.
    pub fn validateExistingRow(self: *const Schema, table: *const Table, rowIndex: usize) !void {
        const row = table.rows.items[rowIndex];
        if (row.values.len != table.columns.len) return error.ConstraintViolation;
        for (table.columns, 0..) |col, index| {
            if (col.notNull and row.values[index] == .null) return error.ConstraintViolation;
        }
        try self.validateConstraints(table, row.values, rowIndex);
    }

    /// True when an FK check postpones to COMMIT/statement end: the
    /// `defer_foreign_keys` pragma defers everything, otherwise only
    /// `DEFERRABLE INITIALLY DEFERRED` constraints defer.
    pub fn fkCheckDeferred(self: *const Schema, deferrable: bool, initiallyDeferred: bool) bool {
        return self.deferForeignKeys or (deferrable and initiallyDeferred);
    }

    fn validateConstraints(self: *const Schema, table: *const Table, values: []const Value, ignoredRow: ?usize) !void {
        var colNames = try self.allocator.alloc([]const u8, table.columns.len);
        defer self.allocator.free(colNames);
        for (table.columns, 0..) |col, idx| colNames[idx] = col.name;

        for (table.columns) |column| {
            if (column.checkExpr) |chk| {
                const passed = try exprEvaluator.evalCheck(self.allocator, colNames, values, chk);
                if (!passed) return error.ConstraintViolation;
            }
        }
        for (table.columns, 0..) |column, index| {
            if (column.primaryKey and values[index] == .null) return error.ConstraintViolation;
            if (column.unique or column.primaryKey) {
                if (values[index] != .null) for (table.rows.items, 0..) |existing, existingIndex| {
                    if (ignoredRow != null and ignoredRow.? == existingIndex) continue;
                    if (valuesEqual(existing.values[index], values[index])) return error.ConstraintViolation;
                };
            }
            if (self.foreignKeysEnabled and !self.fkCheckDeferred(column.fkDeferrable, column.fkInitiallyDeferred)) {
                if (column.foreignTable) |foreignTableName| {
                    const foreignTable = self.findConst(foreignTableName) orelse return error.ConstraintViolation;
                    const foreignColumnName = column.foreignColumn orelse return error.ConstraintViolation;
                    const foreignIndex = self.columnIndex(foreignTable, foreignColumnName) orelse return error.ConstraintViolation;
                    if (values[index] != .null) {
                        var found = false;
                        for (foreignTable.rows.items) |foreignRow| if (valuesEqual(foreignRow.values[foreignIndex], values[index])) {
                            found = true;
                            break;
                        };
                        if (!found) return error.ConstraintViolation;
                    }
                }
            }
        }
        for (table.constraints) |constraint| {
            if (constraint.kind == .check) {
                if (constraint.checkExpr) |chk| {
                    const passed = try exprEvaluator.evalCheck(self.allocator, colNames, values, chk);
                    if (!passed) return error.ConstraintViolation;
                }
                continue;
            }
            var hasNull = false;
            for (constraint.columns) |name| {
                const index = self.columnIndex(table, name) orelse return error.UnknownColumn;
                if (values[index] == .null) hasNull = true;
            }
            if (constraint.kind == .primaryKey and hasNull) return error.ConstraintViolation;
            if (constraint.kind == .unique and hasNull) continue;
            if (constraint.kind == .foreignKey) {
                if (!self.foreignKeysEnabled) continue;
                if (self.fkCheckDeferred(constraint.deferrable, constraint.initiallyDeferred)) continue;
                if (hasNull) continue;
                const foreignTable = self.findConst(constraint.foreignTable orelse return error.ConstraintViolation) orelse return error.ConstraintViolation;
                for (foreignTable.rows.items) |foreignRow| {
                    var matched = true;
                    for (constraint.columns, constraint.referencedColumns) |childName, parentName| {
                        const childIndex = self.columnIndex(table, childName) orelse return error.UnknownColumn;
                        const parentIndex = self.columnIndex(foreignTable, parentName) orelse return error.UnknownColumn;
                        if (!valuesEqual(values[childIndex], foreignRow.values[parentIndex])) matched = false;
                    }
                    if (matched) break;
                } else return error.ConstraintViolation;
                continue;
            }
            for (table.rows.items, 0..) |existing, existingIndex| {
                if (ignoredRow != null and ignoredRow.? == existingIndex) continue;
                if (indexValuesEqual(table, values, existing.values, constraint.columns)) return error.ConstraintViolation;
            }
        }
        for (self.indexes.items) |index| if (index.unique and std.ascii.eqlIgnoreCase(index.table, table.name)) {
            if (!try self.indexPredicateHolds(table, &index, values)) continue;
            for (table.rows.items, 0..) |existing, existingIndex| {
                if (ignoredRow != null and ignoredRow.? == existingIndex) continue;
                if (!try self.indexPredicateHolds(table, &index, existing.values)) continue;
                if (try self.indexKeysEqual(table, &index, colNames, values, existing.values)) return error.ConstraintViolation;
            }
        };
    }

    fn statTable(self: *Schema) ?*Table {
        return self.find("sqlite_stat1");
    }

    /// Ensure the `sqlite_stat1(tbl, idx, stat)` table exists with the exact
    /// shape, creating it when absent. Returns a schema-owned borrow. Fails
    /// `SchemaMismatch` on a wrong-shaped existing table.
    pub fn ensureStatTable(self: *Schema) !*Table {
        if (self.find("sqlite_stat1")) |existing| {
            if (existing.columns.len != 3) return error.SchemaMismatch;
            for (existing.columns, 0..) |column, index| {
                const expected: []const u8 = if (index == 0) "tbl" else if (index == 1) "idx" else "stat";
                if (!std.ascii.eqlIgnoreCase(column.name, expected)) return error.SchemaMismatch;
            }
            return existing;
        }
        const definitions = [_]ast.ColumnDef{
            .{ .name = "tbl", .typeName = "TEXT" },
            .{ .name = "idx", .typeName = "TEXT" },
            .{ .name = "stat", .typeName = "TEXT" },
        };
        try self.createTable("sqlite_stat1", &definitions, &.{});
        return self.find("sqlite_stat1").?;
    }

    /// Delete stat rows for a table (optionally one index). `null` table
    /// clears all; `null` index with a table clears the table scope. No-op
    /// when the stat table is absent. Never fails.
    pub fn clearStatScope(self: *Schema, tableName: ?[]const u8, indexName: ?[]const u8) void {
        const stat = self.find("sqlite_stat1") orelse return;
        var position = stat.rows.items.len;
        while (position > 0) {
            position -= 1;
            const row = stat.rows.items[position];
            if (row.values.len != 3) continue;
            if (tableName) |wanted| {
                if (row.values[0] != .text or !std.ascii.eqlIgnoreCase(row.values[0].text, wanted)) continue;
                if (indexName) |wantedIndex| {
                    if (row.values[1] != .text or !std.ascii.eqlIgnoreCase(row.values[1].text, wantedIndex)) continue;
                }
            } else if (indexName != null) {
                continue;
            }
            const removed = stat.rows.orderedRemove(position);
            for (removed.values) |value| freeValue(self.allocator, value);
            self.allocator.free(removed.values);
        }
    }

    /// Table row count from the stat table (`tbl` row with NULL `idx`), or
    /// null when absent/unparseable. Borrowed name; never fails.
    pub fn statRowCount(self: *const Schema, tableName: []const u8) ?usize {
        const stat = self.findConst("sqlite_stat1") orelse return null;
        var tableIdx: ?usize = null;
        var idxIdx: ?usize = null;
        var statIdx: ?usize = null;
        for (stat.columns, 0..) |column, index| {
            if (std.ascii.eqlIgnoreCase(column.name, "tbl")) tableIdx = index;
            if (std.ascii.eqlIgnoreCase(column.name, "idx")) idxIdx = index;
            if (std.ascii.eqlIgnoreCase(column.name, "stat")) statIdx = index;
        }
        const tIdx = tableIdx orelse return null;
        const iIdx = idxIdx orelse return null;
        const sIdx = statIdx orelse return null;
        for (stat.rows.items) |row| {
            if (row.values.len != stat.columns.len) continue;
            if (row.values[tIdx] != .text) continue;
            if (!std.ascii.eqlIgnoreCase(row.values[tIdx].text, tableName)) continue;
            if (row.values[iIdx] != .null) continue;
            if (row.values[sIdx] != .text) continue;
            const count = std.fmt.parseInt(usize, std.mem.trim(u8, row.values[sIdx].text, " \t"), 10) catch continue;
            return count;
        }
        return null;
    }

    /// Ensure the `sqlite_sequence(name, seq)` table exists. Idempotent.
    pub fn ensureSequenceTable(self: *Schema) anyerror!void {
        if (self.find("sqlite_sequence") != null) return;
        const definitions = [_]ast.ColumnDef{
            .{ .name = "name", .typeName = "TEXT" },
            .{ .name = "seq", .typeName = "INTEGER" },
        };
        try self.createTable("sqlite_sequence", &definitions, &.{});
    }

    /// Current AUTOINCREMENT sequence for a table, or 0 when absent. Borrowed
    /// name; never fails.
    pub fn sequenceValue(self: *const Schema, tableName: []const u8) i64 {
        const sequence = self.findConst("sqlite_sequence") orelse return 0;
        if (sequence.columns.len < 2) return 0;
        for (sequence.rows.items) |row| {
            if (row.values.len != sequence.columns.len) continue;
            if (row.values[0] != .text) continue;
            if (!std.ascii.eqlIgnoreCase(row.values[0].text, tableName)) continue;
            if (row.values[1] == .integer) return row.values[1].integer;
            return 0;
        }
        return 0;
    }

    /// Set the AUTOINCREMENT sequence, creating the row when absent. Borrowed
    /// name; dupes the name for new rows.
    pub fn setSequenceValue(self: *Schema, tableName: []const u8, next: i64) anyerror!void {
        try self.ensureSequenceTable();
        const sequence = self.find("sqlite_sequence").?;
        for (sequence.rows.items) |*row| {
            if (row.values.len != sequence.columns.len) continue;
            if (row.values[0] != .text) continue;
            if (!std.ascii.eqlIgnoreCase(row.values[0].text, tableName)) continue;
            freeValue(self.allocator, row.values[1]);
            row.values[1] = .{ .integer = next };
            return;
        }
        const nameValue = Value{ .text = tableName };
        const seqValue = Value{ .integer = next };
        try self.appendRow(sequence, &.{ nameValue, seqValue });
    }

    fn applyAutoincrement(self: *Schema, table: *const Table, values: []Value) anyerror!void {
        var columnIdx: ?usize = null;
        for (table.columns, 0..) |column, index| if (column.autoincrement) {
            if (columnIdx != null) return error.InvalidSql;
            columnIdx = index;
        };
        const alias = columnIdx orelse return;
        switch (values[alias]) {
            .null => {
                var max = self.sequenceValue(table.name);
                for (table.rows.items) |existing| {
                    switch (existing.values[alias]) {
                        .integer => |current| {
                            if (current > max) max = current;
                        },
                        else => {},
                    }
                }
                if (max == std.math.maxInt(i64)) return error.ConstraintViolation;
                const next = max + 1;
                try self.setSequenceValue(table.name, next);
                values[alias] = .{ .integer = next };
            },
            .integer => |explicit| {
                if (explicit > self.sequenceValue(table.name)) try self.setSequenceValue(table.name, explicit);
            },
            else => return error.ConstraintViolation,
        }
    }

    fn statKeyValue(self: *const Schema, table: *const Table, index: *const Index, colNames: []const []const u8, position: usize, values: []const Value) !Value {
        if (index.keyExpr(position)) |key| return exprEvaluator.eval(self.allocator, colNames, values, key);
        const columnIdx = self.columnIndex(table, index.columns[position]) orelse return error.UnknownColumn;
        return switch (values[columnIdx]) {
            .text => |text| .{ .text = try self.allocator.dupe(u8, text) },
            .blob => |blob| .{ .blob = try self.allocator.dupe(u8, blob) },
            else => |value| value,
        };
    }

    fn statPrefixDistinct(self: *const Schema, table: *const Table, index: *const Index, colNames: []const []const u8, rows: []const Row, prefixLen: usize) !usize {
        var distinct: usize = 0;
        for (rows, 0..) |row, rowIndex| {
            var seen = false;
            for (rows[0..rowIndex]) |other| {
                var same = true;
                for (0..prefixLen) |position| {
                    const left = try self.statKeyValue(table, index, colNames, position, row.values);
                    defer exprEvaluator.freeValue(self.allocator, left);
                    const right = try self.statKeyValue(table, index, colNames, position, other.values);
                    defer exprEvaluator.freeValue(self.allocator, right);
                    if (left == .null or right == .null) {
                        if (left != .null or right != .null) same = false;
                        continue;
                    }
                    if (!valuesEqual(left, right)) same = false;
                }
                if (same) {
                    seen = true;
                    break;
                }
            }
            if (!seen) distinct += 1;
        }
        return distinct;
    }

    /// Append a table row-count entry to `sqlite_stat1`. Borrowed table;
    /// dupes names/payloads into the stat table.
    pub fn collectTableStats(self: *Schema, table: *const Table) !void {
        const stat = try self.ensureStatTable();
        const countText = try std.fmt.allocPrint(self.allocator, "{d}", .{table.rows.items.len});
        defer self.allocator.free(countText);
        const row = [_]Value{ .{ .text = table.name }, .null, .{ .text = countText } };
        try self.appendRow(stat, &row);
    }

    /// Append an index selectivity entry (`count avg-per-prefix...`) for rows
    /// matching the partial predicate. Borrowed inputs; transient evaluation
    /// values freed internally.
    pub fn collectIndexStats(self: *Schema, table: *const Table, index: *const Index) !void {
        const stat = try self.ensureStatTable();
        var colNames = try self.allocator.alloc([]const u8, table.columns.len);
        defer self.allocator.free(colNames);
        for (table.columns, 0..) |col, idx| colNames[idx] = col.name;
        var matched = std.ArrayList(Row).empty;
        defer matched.deinit(self.allocator);
        for (table.rows.items) |row| {
            if (try self.indexPredicateHolds(table, index, row.values)) try matched.append(self.allocator, row);
        }
        var text = std.ArrayList(u8).empty;
        defer text.deinit(self.allocator);
        const countText = try std.fmt.allocPrint(self.allocator, "{d}", .{matched.items.len});
        defer self.allocator.free(countText);
        try text.appendSlice(self.allocator, countText);
        for (0..index.columns.len) |prefixLen| {
            const distinct = try self.statPrefixDistinct(table, index, colNames, matched.items, prefixLen + 1);
            var average: usize = 0;
            if (distinct != 0) average = (matched.items.len + distinct / 2) / distinct;
            if (positionIsUnique(index, prefixLen)) average = 1;
            const averageText = try std.fmt.allocPrint(self.allocator, " {d}", .{average});
            defer self.allocator.free(averageText);
            try text.appendSlice(self.allocator, averageText);
        }
        const statText = try text.toOwnedSlice(self.allocator);
        defer self.allocator.free(statText);
        const row = [_]Value{ .{ .text = table.name }, .{ .text = index.name }, .{ .text = statText } };
        try self.appendRow(stat, &row);
    }

    fn positionIsUnique(index: *const Index, position: usize) bool {
        return index.unique and position + 1 == index.columns.len;
    }

    /// Deep copy: tables (descriptors + rows), non-auto indexes, views, and
    /// triggers, with FK enforcement restored at the end. Caller owns the
    /// result and must `deinit` it. Virtual tables re-materialize from args.
    pub fn clone(self: *const Schema) !Schema {
        var result = Schema.init(self.allocator);
        result.foreignKeysEnabled = false;
        errdefer result.deinit();
        for (self.tables.items) |table| {
            if (std.ascii.eqlIgnoreCase(table.name, "sqlite_sequence")) continue;
            if (table.virtualModule) |module| {
                try result.createVirtualTable(table.name, module, table.virtualArguments);
                continue;
            }
            const definitions = try self.allocator.alloc(ast.ColumnDef, table.columns.len);
            defer self.allocator.free(definitions);
            for (table.columns, 0..) |column, index| definitions[index] = .{
                .name = column.name,
                .typeName = column.typeName,
                .primaryKey = column.primaryKey,
                .notNull = column.notNull,
                .unique = column.unique,
                .autoincrement = column.autoincrement,
                .defaultValue = column.defaultValue,
                .foreignKey = if (column.foreignTable != null) .{ .table = column.foreignTable.?, .column = column.foreignColumn.?, .onDelete = column.onDelete, .onUpdate = column.onUpdate, .deferrable = column.fkDeferrable, .initiallyDeferred = column.fkInitiallyDeferred } else null,
                .checkExpr = column.checkExpr,
                .generatedExpr = column.generatedExpr,
                .generatedStored = column.generatedStored,
            };
            const constraintDefinitions = try self.allocator.alloc(ast.TableConstraint, table.constraints.len);
            defer self.allocator.free(constraintDefinitions);
            for (table.constraints, 0..) |constraint, index| constraintDefinitions[index] = switch (constraint.kind) {
                .primaryKey => .{ .primaryKey = constraint.columns },
                .unique => .{ .unique = constraint.columns },
                .foreignKey => .{ .foreignKey = .{ .columns = constraint.columns, .table = constraint.foreignTable.?, .referencedColumns = constraint.referencedColumns, .onDelete = constraint.onDelete, .onUpdate = constraint.onUpdate, .deferrable = constraint.deferrable, .initiallyDeferred = constraint.initiallyDeferred } },
                .check => .{ .check = constraint.checkExpr orelse .{ .literal = .null } },
            };
            try result.createTableWithOptions(table.name, definitions, constraintDefinitions, .{ .strict = table.strict, .withoutRowid = table.withoutRowid });
            const target = result.find(table.name).?;
            for (table.rows.items) |row| try result.appendRow(target, row.values);
        }
        if (self.findConst("sqlite_sequence")) |sequence| {
            try result.ensureSequenceTable();
            try result.truncateTable("sqlite_sequence");
            const target = result.find("sqlite_sequence").?;
            for (sequence.rows.items) |row| try result.appendRow(target, row.values);
        }
        for (self.indexes.items) |index| {
            if (std.mem.startsWith(u8, index.name, "sqlite_autoindex_")) continue;
            const columns = try self.allocator.alloc([]const u8, index.columns.len);
            defer self.allocator.free(columns);
            for (index.columns, 0..) |column, position| columns[position] = column;
            try result.createIndex(.{ .name = index.name, .table = index.table, .columns = columns, .keyExprs = index.keyExprs, .unique = index.unique, .whereExpr = index.whereExpr, .whereSql = index.whereSql });
        }
        for (self.views.items) |view| try result.createView(view.name, view.sql);
        for (self.triggers.items) |trigger| try result.createTrigger(.{ .name = trigger.name, .table = trigger.table, .timing = trigger.timing, .event = trigger.event, .updateOf = trigger.updateOf, .whenSql = trigger.whenSql, .body = trigger.body });
        result.foreignKeysEnabled = self.foreignKeysEnabled;
        result.deferForeignKeys = self.deferForeignKeys;
        return result;
    }
};

/// Borrowed value equality: NULL==NULL, ints by value, reals numerically
/// (int/real mix compares as floats), texts/blobs by bytes. Never fails.
pub fn valuesEqual(left: Value, right: Value) bool {
    return switch (left) {
        .null => right == .null,
        .integer => |value| switch (right) {
            .integer => |other| value == other,
            else => false,
        },
        .real => |value| switch (right) {
            .real => |other| value == other,
            .integer => |other| value == @as(f64, @floatFromInt(other)),
            else => false,
        },
        .text => |value| switch (right) {
            .text => |other| std.mem.eql(u8, value, other),
            else => false,
        },
        .blob => |value| switch (right) {
            .blob => |other| std.mem.eql(u8, value, other),
            else => false,
        },
    };
}

fn indexValuesEqual(table: *const Table, left: []const Value, right: []const Value, columns: []const []const u8) bool {
    for (columns) |name| {
        var columnIndex: ?usize = null;
        for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) {
            columnIndex = index;
            break;
        };
        const index = columnIndex orelse return false;
        if (left[index] == .null or right[index] == .null) return false;
        if (!valuesEqual(left[index], right[index])) return false;
    }
    return true;
}

test "schema owns tables and rows" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{ .{ .name = "id", .typeName = "INTEGER" }, .{ .name = "name", .typeName = "TEXT" } };
    try schema.createTable("users", &defs, &.{});
    var values = [_]Value{ .{ .integer = 1 }, .{ .text = "A" } };
    try schema.appendRow(schema.find("users").?, &values);
    try std.testing.expectEqual(@as(usize, 1), schema.find("users").?.rows.items.len);
}

test "schema enforces uniqueness strictness and renames" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    // UNIQUE column rejects duplicates but ignores NULL rows (SQLite rule).
    const defs = [_]ast.ColumnDef{ .{ .name = "id", .typeName = "INTEGER", .primaryKey = true }, .{ .name = "email", .typeName = "TEXT", .unique = true } };
    try schema.createTable("users", &defs, &.{});
    const t = schema.find("users").?;
    try schema.appendRow(t, &[_]Value{ .{ .integer = 1 }, .{ .text = "a" } });
    try std.testing.expectError(error.ConstraintViolation, schema.appendRow(t, &[_]Value{ .{ .integer = 2 }, .{ .text = "a" } }));
    try schema.appendRow(t, &[_]Value{ .{ .integer = 3 }, .null });
    try schema.appendRow(t, &[_]Value{ .{ .integer = 4 }, .null });
    // Case-insensitive lookup; duplicate create and bad row width fail.
    try std.testing.expect(schema.find("USERS") != null);
    try std.testing.expectError(error.TableExists, schema.createTable("users", &defs, &.{}));
    try std.testing.expectError(error.ColumnCountMismatch, schema.appendRow(t, &[_]Value{.null}));
    // STRICT table rejects cross-type inserts.
    const strictDefs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER" }};
    try schema.createTableWithOptions("strict_t", &strictDefs, &.{}, .{ .strict = true });
    try std.testing.expectError(error.ConstraintViolation, schema.appendRow(schema.find("strict_t").?, &[_]Value{.{ .text = "nope" }}));
    try schema.appendRow(schema.find("strict_t").?, &[_]Value{.{ .integer = 1 }});
    // Rename keeps rows and is visible under the new name only.
    try schema.renameTable("users", "people");
    try std.testing.expect(schema.find("users") == null);
    try std.testing.expectEqual(@as(usize, 3), schema.find("people").?.rows.items.len);
    try schema.renameColumn("people", "email", "mail");
    try std.testing.expectError(error.UnknownColumn, schema.renameColumn("people", "email", "x"));
    // valuesEqual covers the NULL/int/real/text matrix used by constraints.
    try std.testing.expect(valuesEqual(.null, .null));
    try std.testing.expect(!valuesEqual(.null, .{ .integer = 1 }));
    try std.testing.expect(valuesEqual(.{ .real = 1.0 }, .{ .integer = 1 }));
    try std.testing.expect(!valuesEqual(.{ .text = "a" }, .{ .text = "b" }));
}

test "strict coercion applies affinity before the type check" {
    const alloc = std.testing.allocator;
    // Well-formed text numerals convert; junk stays TEXT and fails.
    const fromText = try Schema.coerceStrict(alloc, "INT", .{ .text = "123" });
    try std.testing.expectEqual(@as(i64, 123), fromText.integer);
    try std.testing.expectError(error.ConstraintViolation, Schema.coerceStrict(alloc, "INT", .{ .text = "12x" }));
    try std.testing.expectError(error.ConstraintViolation, Schema.coerceStrict(alloc, "INT", .{ .text = "1.5" }));
    const floatText = try Schema.coerceStrict(alloc, "INT", .{ .text = "48.00" });
    try std.testing.expectEqual(@as(i64, 48), floatText.integer);
    const toReal = try Schema.coerceStrict(alloc, "REAL", .{ .text = "2.5" });
    try std.testing.expectEqual(@as(f64, 2.5), toReal.real);
    // Small integers stay integers in REAL columns (IntReal); large ones widen.
    const intReal = try Schema.coerceStrict(alloc, "REAL", .{ .integer = 42 });
    try std.testing.expectEqual(@as(i64, 42), intReal.integer);
    const wide = try Schema.coerceStrict(alloc, "REAL", .{ .integer = std.math.maxInt(i64) });
    try std.testing.expect(wide == .real);
    // Lossless reals become integers; the rest (and huge magnitudes) fail
    // for INT without trapping.
    const lossless = try Schema.coerceStrict(alloc, "INT", .{ .real = 50.0 });
    try std.testing.expectEqual(@as(i64, 50), lossless.integer);
    try std.testing.expectError(error.ConstraintViolation, Schema.coerceStrict(alloc, "INT", .{ .real = 1e30 }));
    try std.testing.expectError(error.ConstraintViolation, Schema.coerceStrict(alloc, "INT", .{ .real = 1.5 }));
    // Numbers render to TEXT; blobs never convert.
    const rendered = try Schema.coerceStrict(alloc, "TEXT", .{ .integer = 999 });
    defer alloc.free(rendered.text);
    try std.testing.expectEqualStrings("999", rendered.text);
    try std.testing.expectError(error.ConstraintViolation, Schema.coerceStrict(alloc, "TEXT", .{ .blob = "x" }));
    try std.testing.expectError(error.ConstraintViolation, Schema.coerceStrict(alloc, "BLOB", .{ .integer = 1 }));
    try std.testing.expectError(error.ConstraintViolation, Schema.coerceStrict(alloc, "BLOB", .{ .text = "x" }));
    const anyBlob = try Schema.coerceStrict(alloc, "ANY", .{ .blob = "x" });
    try std.testing.expect(anyBlob == .blob);
}

test "addColumn stages fully before committing" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER" }};
    try schema.createTable("t", &defs, &.{});
    const t = schema.find("t").?;
    try schema.appendRow(t, &[_]Value{.{ .integer = 1 }});
    try schema.appendRow(t, &[_]Value{.{ .integer = 2 }});
    // Happy path: default backfills every row.
    try schema.addColumn("t", .{ .name = "extra", .typeName = "INTEGER", .defaultValue = .{ .integer = 9 } });
    try std.testing.expectEqual(@as(usize, 2), t.columns.len);
    try std.testing.expectEqual(@as(i64, 9), t.rows.items[0].values[1].integer);
    try std.testing.expectEqual(@as(i64, 9), t.rows.items[1].values[1].integer);
    // CHECK failure stages nothing: no column, old widths, intact values.
    const bad = ast.ColumnDef{ .name = "nope", .typeName = "INTEGER", .checkExpr = .{ .literal = .{ .integer = 0 } } };
    try std.testing.expectError(error.ConstraintViolation, schema.addColumn("t", bad));
    try std.testing.expectEqual(@as(usize, 2), t.columns.len);
    for (t.rows.items) |row| {
        try std.testing.expectEqual(@as(usize, 2), row.values.len);
        try std.testing.expect(row.values[0] == .integer);
    }
    try std.testing.expectEqual(@as(i64, 1), t.rows.items[0].values[0].integer);
    try std.testing.expectEqual(@as(i64, 2), t.rows.items[1].values[0].integer);
    try std.testing.expectEqual(@as(i64, 9), t.rows.items[0].values[1].integer);
}

test "addColumn survives allocation failure without partial state" {
    // Fail-point sweep over addColumn only: the schema is built once with
    // the real allocator, then each iteration swaps in a fresh failing
    // allocator (counter starts at zero, so fail_index names addColumn's
    // own allocation sites exactly). Every OOM must leave columns, widths,
    // and values untouched; some index must succeed to prove the sweep ran
    // past the last failure point. The allocator is restored before deinit.
    const defs = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER" }};
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    try schema.createTable("t", &defs, &.{});
    const t = schema.find("t").?;
    try schema.appendRow(t, &[_]Value{.{ .integer = 1 }});
    try schema.appendRow(t, &[_]Value{.{ .integer = 2 }});
    var succeeded = false;
    var failAt: usize = 0;
    while (failAt < 128) : (failAt += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failAt });
        schema.allocator = failing.allocator();
        const extra = ast.ColumnDef{ .name = "extra", .typeName = "INTEGER", .defaultValue = .{ .integer = 9 } };
        schema.addColumn("t", extra) catch |err| {
            schema.allocator = std.testing.allocator;
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 1), t.columns.len);
            for (t.rows.items) |row| {
                try std.testing.expectEqual(@as(usize, 1), row.values.len);
                try std.testing.expect(row.values[0] == .integer);
            }
            try std.testing.expectEqual(@as(i64, 1), t.rows.items[0].values[0].integer);
            try std.testing.expectEqual(@as(i64, 2), t.rows.items[1].values[0].integer);
            continue;
        };
        schema.allocator = std.testing.allocator;
        try std.testing.expectEqual(@as(usize, 2), t.columns.len);
        try std.testing.expectEqual(@as(i64, 9), t.rows.items[0].values[1].integer);
        succeeded = true;
        break;
    }
    schema.allocator = std.testing.allocator;
    try std.testing.expect(succeeded);
}

test "dropColumn stages fully before committing" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const defs = [_]ast.ColumnDef{ .{ .name = "id", .typeName = "INTEGER" }, .{ .name = "gone", .typeName = "TEXT" } };
    try schema.createTable("t", &defs, &.{});
    const t = schema.find("t").?;
    try schema.appendRow(t, &[_]Value{ .{ .integer = 1 }, .{ .text = "a" } });
    try schema.appendRow(t, &[_]Value{ .{ .integer = 2 }, .{ .text = "b" } });
    try schema.dropColumn("t", "gone");
    try std.testing.expectEqual(@as(usize, 1), t.columns.len);
    try std.testing.expectEqualStrings("id", t.columns[0].name);
    for (t.rows.items) |row| try std.testing.expectEqual(@as(usize, 1), row.values.len);
    try std.testing.expectEqual(@as(i64, 1), t.rows.items[0].values[0].integer);
    try std.testing.expectEqual(@as(i64, 2), t.rows.items[1].values[0].integer);
}

test "dropColumn survives allocation failure without partial state" {
    const defs = [_]ast.ColumnDef{ .{ .name = "id", .typeName = "INTEGER" }, .{ .name = "gone", .typeName = "TEXT" } };
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    try schema.createTable("t", &defs, &.{});
    const t = schema.find("t").?;
    try schema.appendRow(t, &[_]Value{ .{ .integer = 1 }, .{ .text = "a" } });
    try schema.appendRow(t, &[_]Value{ .{ .integer = 2 }, .{ .text = "b" } });
    var succeeded = false;
    var failAt: usize = 0;
    while (failAt < 128) : (failAt += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = failAt });
        schema.allocator = failing.allocator();
        schema.dropColumn("t", "gone") catch |err| {
            schema.allocator = std.testing.allocator;
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 2), t.columns.len);
            for (t.rows.items) |row| try std.testing.expectEqual(@as(usize, 2), row.values.len);
            try std.testing.expectEqual(@as(i64, 1), t.rows.items[0].values[0].integer);
            try std.testing.expectEqualStrings("a", t.rows.items[0].values[1].text);
            try std.testing.expectEqual(@as(i64, 2), t.rows.items[1].values[0].integer);
            try std.testing.expectEqualStrings("b", t.rows.items[1].values[1].text);
            continue;
        };
        schema.allocator = std.testing.allocator;
        try std.testing.expectEqual(@as(usize, 1), t.columns.len);
        succeeded = true;
        break;
    }
    schema.allocator = std.testing.allocator;
    try std.testing.expect(succeeded);
}
