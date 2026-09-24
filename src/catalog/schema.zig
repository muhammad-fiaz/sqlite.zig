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
const strictMod = @import("strict.zig");
const sequenceMod = @import("sequence.zig");
const statsMod = @import("stats.zig");

/// Owned column descriptor. `name`/`typeName`/FK strings are schema-owned
/// dupes; `defaultValue` owns its text/blob payload; `checkExpr`/
/// `generatedExpr` are schema-owned cloned ASTs. Borrowed views dangle after
/// drop/rename/deinit.
pub const Column = struct { name: []u8, typeName: []u8, primaryKey: bool, notNull: bool, unique: bool = false, autoincrement: bool = false, defaultValue: ?Value = null, defaultExpr: ?ast.Expr = null, collate: ?[]u8 = null, conflict: ast.ConflictPolicy = .none, foreignTable: ?[]u8 = null, foreignColumn: ?[]u8 = null, onDelete: ast.ReferentialAction = .restrict, onUpdate: ast.ReferentialAction = .restrict, fkDeferrable: bool = false, fkInitiallyDeferred: bool = false, checkExpr: ?ast.Expr = null, generatedExpr: ?ast.Expr = null, generatedStored: bool = false };
/// Owned row: `values` has one entry per column and owns text/blob payloads.
/// Freed by schema lifecycle ops; never retain after drop/truncate/deinit.
pub const Row = struct { values: []Value };
/// Owned table-level constraint. Name lists and FK strings are schema-owned
/// dupes; `checkExpr` is a schema-owned cloned AST.
pub const Constraint = struct { kind: enum { primaryKey, unique, foreignKey, check }, columns: [][]u8, foreignTable: ?[]u8 = null, referencedColumns: [][]u8 = &.{}, onDelete: ast.ReferentialAction = .restrict, onUpdate: ast.ReferentialAction = .restrict, deferrable: bool = false, initiallyDeferred: bool = false, checkExpr: ?ast.Expr = null, conflict: ast.ConflictPolicy = .none };
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
    /// True for `FOR EACH ROW` (default); false for `FOR EACH STATEMENT`.
    eachRow: bool = true,

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
    /// Set when the last `appendRow`/`validateUpdate` failed with a
    /// constraint-level `ON CONFLICT` policy (`.none` = default ABORT).
    lastConstraintConflict: ast.ConflictPolicy = .none,

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
        // Canonical value free lives in sql/expr.zig; do not duplicate it here.
        exprEvaluator.freeValue(allocator, value);
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
        try self.triggers.append(self.allocator, .{ .name = try self.allocator.dupe(u8, definition.name), .table = try self.allocator.dupe(u8, definition.table), .timing = definition.timing, .event = definition.event, .updateOf = updateOf, .whenSql = whenSql, .body = try self.allocator.dupe(u8, definition.body), .eachRow = definition.eachRow });
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
    /// True for the five STRICT storage types plus ANY. Canonical
    /// implementation lives in `strict.zig`; this wrapper preserves the
    /// `Schema.` API for existing callers.
    pub fn isValidStrictType(typeName: []const u8) bool {
        return strictMod.isValidStrictType(typeName);
    }

    /// Coerce a borrowed `Value` to a STRICT type. Canonical implementation
    /// lives in `strict.zig` (mirrors `OP_TypeCheck`); this wrapper preserves
    /// the `Schema.` API. NULL passes through; failures are
    /// `ConstraintViolation`; TEXT renders allocate and are caller-owned.
    pub fn coerceStrict(allocator: std.mem.Allocator, typeName: []const u8, value: Value) !Value {
        return strictMod.coerceStrict(allocator, typeName, value);
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
                    if (c == .primaryKey and c.primaryKey.columns.len > 0) {
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
            if (column.defaultExpr) |de| ast.freeOwnedExpr(self.allocator, de);
            if (column.collate) |colName| self.allocator.free(colName);
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
                    for (c.primaryKey.columns) |pkCol| {
                        if (std.ascii.eqlIgnoreCase(pkCol, definition.name)) {
                            inPk = true;
                            if (c.primaryKey.columns.len == 1) isPk = true;
                            break;
                        }
                    }
                }
            }
            const isNotNull = definition.notNull or (options.withoutRowid and inPk);
            var clonedCheck = if (definition.checkExpr) |chk| try ast.cloneOwnedExpr(self.allocator, chk) else null;
            errdefer if (clonedCheck) |chk| ast.freeOwnedExpr(self.allocator, chk);
            var clonedGen = if (definition.generatedExpr) |gen| try ast.cloneOwnedExpr(self.allocator, gen) else null;
            errdefer if (clonedGen) |gen| ast.freeOwnedExpr(self.allocator, gen);
            var clonedDefaultExpr = if (definition.defaultExpr) |de| try ast.cloneOwnedExpr(self.allocator, de) else null;
            errdefer if (clonedDefaultExpr) |de| ast.freeOwnedExpr(self.allocator, de);

            columns[index] = blk: {
                const ownedColName = try self.allocator.dupe(u8, definition.name);
                errdefer self.allocator.free(ownedColName);
                const ownedColType = try self.allocator.dupe(u8, definition.typeName);
                errdefer self.allocator.free(ownedColType);
                const ownedColDefault = if (definition.defaultValue) |value| try self.copyValue(value) else null;
                errdefer if (ownedColDefault) |val| freeValue(self.allocator, val);
                const ownedColCollate = if (definition.collate) |colName| try self.allocator.dupe(u8, colName) else null;
                errdefer if (ownedColCollate) |val| self.allocator.free(val);
                const ownedColForeignTable = if (definition.foreignKey) |foreignKey| try self.allocator.dupe(u8, foreignKey.table) else null;
                errdefer if (ownedColForeignTable) |val| self.allocator.free(val);
                const ownedColForeignColumn = if (definition.foreignKey) |foreignKey| if (foreignKey.column.len != 0) try self.allocator.dupe(u8, foreignKey.column) else null else null;
                errdefer if (ownedColForeignColumn) |val| self.allocator.free(val);
                break :blk .{
                    .name = ownedColName,
                    .typeName = ownedColType,
                    .primaryKey = isPk,
                    .notNull = isNotNull,
                    .unique = definition.unique,
                    .autoincrement = definition.autoincrement,
                    .defaultValue = ownedColDefault,
                    .defaultExpr = clonedDefaultExpr,
                    .collate = ownedColCollate,
                    .conflict = definition.conflict,
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
            // Ownership moved into columns[index]: disarm clone errdefers.
            clonedCheck = null;
            clonedGen = null;
            clonedDefaultExpr = null;
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
                .primaryKey => |value| value.columns,
                .unique => |value| value.columns,
                .foreignKey => |value| value.columns,
                .check => &.{},
            };
            const sourceConflict = switch (definition) {
                .primaryKey => |value| value.conflict,
                .unique => |value| value.conflict,
                .check => |value| value.conflict,
                .foreignKey => ast.ConflictPolicy.none,
            };
            const copiedColumns = try self.allocator.alloc([]u8, sourceColumns.len);
            var copiedCount: usize = 0;
            errdefer for (copiedColumns[0..copiedCount]) |column| self.allocator.free(column);
            for (sourceColumns, 0..) |column, columnIdx| {
                if (self.columnIndexByName(definitions, column) == null) return error.UnknownColumn;
                copiedColumns[columnIdx] = try self.allocator.dupe(u8, column);
                copiedCount += 1;
            }
            const clonedCheck = if (definition == .check) try ast.cloneOwnedExpr(self.allocator, definition.check.expr) else null;
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
                .conflict = sourceConflict,
            };
            switch (definition) {
                .foreignKey => |foreignKey| {
                    // Bare `REFERENCES t` (empty column list) targets the
                    // parent primary key when the parent is already known.
                    var parentCols = foreignKey.referencedColumns;
                    var bareResolved = false;
                    if (parentCols.len == 0) {
                        if (self.findConst(foreignKey.table)) |parent| {
                            var pks = std.ArrayList([]const u8).empty;
                            defer pks.deinit(self.allocator);
                            for (parent.columns) |col| if (col.primaryKey) try pks.append(self.allocator, col.name);
                            if (pks.items.len == 0) {
                                // WITHOUT ROWID composite PK is table-level; scan constraints.
                                for (parent.constraints) |c| if (c.kind == .primaryKey) for (c.columns) |pkName| try pks.append(self.allocator, pkName);
                            }
                            if (pks.items.len != 0 and pks.items.len == sourceColumns.len) {
                                parentCols = try pks.toOwnedSlice(self.allocator);
                                bareResolved = true;
                            }
                        }
                    }
                    defer if (bareResolved) {
                        for (parentCols) |c| self.allocator.free(c);
                        self.allocator.free(parentCols);
                    };
                    if (parentCols.len != sourceColumns.len) return error.ConstraintViolation;
                    const referencedColumns = try self.allocator.alloc([]u8, parentCols.len);
                    for (parentCols, 0..) |column, columnIdx| {
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
            const ownedColDefault = if (definition.defaultValue) |value| try self.copyValue(value) else null;
            errdefer if (ownedColDefault) |val| freeValue(self.allocator, val);
            const clonedDefaultExpr = if (definition.defaultExpr) |de| try ast.cloneOwnedExpr(self.allocator, de) else null;
            errdefer if (clonedDefaultExpr) |de| ast.freeOwnedExpr(self.allocator, de);
            const ownedColCollate = if (definition.collate) |colName| try self.allocator.dupe(u8, colName) else null;
            errdefer if (ownedColCollate) |val| self.allocator.free(val);
            const ownedForeignTable = if (definition.foreignKey) |foreignKey| try self.allocator.dupe(u8, foreignKey.table) else null;
            errdefer if (ownedForeignTable) |val| self.allocator.free(val);
            const ownedForeignColumn = if (definition.foreignKey) |foreignKey| if (foreignKey.column.len != 0) try self.allocator.dupe(u8, foreignKey.column) else null else null;
            errdefer if (ownedForeignColumn) |val| self.allocator.free(val);
            break :blk .{
                .name = ownedName,
                .typeName = ownedType,
                .primaryKey = definition.primaryKey,
                .notNull = definition.notNull,
                .unique = definition.unique,
                .autoincrement = definition.autoincrement,
                .defaultValue = ownedColDefault,
                .defaultExpr = clonedDefaultExpr,
                .collate = ownedColCollate,
                .conflict = definition.conflict,
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
            if (newColumns[table.columns.len].defaultExpr) |de| ast.freeOwnedExpr(self.allocator, de);
            if (newColumns[table.columns.len].collate) |colName| self.allocator.free(colName);
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
        if (oldColumn.defaultExpr) |de| ast.freeOwnedExpr(self.allocator, de);
        if (oldColumn.collate) |colName| self.allocator.free(colName);
        if (oldColumn.foreignTable) |value| self.allocator.free(value);
        if (oldColumn.foreignColumn) |value| self.allocator.free(value);
        if (oldColumn.checkExpr) |chk| ast.freeOwnedExpr(self.allocator, chk);
        if (oldColumn.generatedExpr) |gen| ast.freeOwnedExpr(self.allocator, gen);
        self.allocator.free(table.columns);
        table.columns = newColumns;
    }

    /// Position of `name` in `table.columns` (case-insensitive), or null.
    /// Public so `stats.zig` and other catalog submodules reuse the one
    /// canonical lookup instead of duplicating the scan.
    pub fn columnIndex(self: *const Schema, table: *const Table, name: []const u8) ?usize {
        _ = self;
        for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
        return null;
    }

    /// Index of the parent table's single-column primary key (column-level
    /// `PRIMARY KEY` or one-column table-level PK). Null for composite or
    /// missing PKs — bare `REFERENCES t` needs a single parent key column.
    pub fn parentPkColumnIndex(table: *const Table) ?usize {
        var found: ?usize = null;
        for (table.columns, 0..) |column, index| {
            if (!column.primaryKey) continue;
            if (found != null) return null;
            found = index;
        }
        if (found != null) {
            for (table.constraints) |c| if (c.kind == .primaryKey and c.columns.len > 1) return null;
            return found;
        }
        // Table-level single-column PK.
        var pkCount: usize = 0;
        var pkIdx: ?usize = null;
        for (table.constraints) |c| {
            if (c.kind != .primaryKey) continue;
            if (c.columns.len != 1) return null;
            pkCount += 1;
            pkIdx = columnIndexInner(table, c.columns[0]);
        }
        if (pkCount == 1) return pkIdx;
        return null;
    }

    fn columnIndexInner(table: *const Table, name: []const u8) ?usize {
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
            if (column.defaultExpr) |de| ast.freeOwnedExpr(self.allocator, de);
            if (column.collate) |colName| self.allocator.free(colName);
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
        self.lastConstraintConflict = .none;
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
            if (col.notNull and owned[index] == .null) {
                self.lastConstraintConflict = col.conflict;
                return error.ConstraintViolation;
            }
        }
        var policy: ast.ConflictPolicy = .none;
        self.validateConstraints(table, owned, null, &policy) catch |err| {
            if (err == error.ConstraintViolation) self.lastConstraintConflict = policy;
            return err;
        };
        try table.rows.append(self.allocator, .{ .values = owned });
    }

    /// Validate a proposed in-place row update (AUTOINCREMENT/rowid/STRICT/
    /// NOT NULL/constraints, ignoring the row itself for uniqueness). The
    /// caller applies the mutation only on success.
    pub fn validateUpdate(self: *Schema, table: *const Table, rowIndex: usize, values: []Value) !void {
        self.lastConstraintConflict = .none;
        try self.applyAutoincrement(table, values);
        try assignRowidAlias(table, values);
        if (table.strict) {
            for (table.columns, 0..) |col, index| {
                if (col.generatedExpr != null and !col.generatedStored) continue;
                _ = try coerceStrict(self.allocator, col.typeName, values[index]);
            }
        }
        for (table.columns, 0..) |col, index| {
            if (col.notNull and values[index] == .null) {
                self.lastConstraintConflict = col.conflict;
                return error.ConstraintViolation;
            }
        }
        var policy: ast.ConflictPolicy = .none;
        self.validateConstraints(table, values, rowIndex, &policy) catch |err| {
            if (err == error.ConstraintViolation) self.lastConstraintConflict = policy;
            return err;
        };
    }

    /// Re-validate a stored row in place (shape, NOT NULL, constraints).
    /// Used after external row surgery; fails `ConstraintViolation` on drift.
    pub fn validateExistingRow(self: *const Schema, table: *const Table, rowIndex: usize) !void {
        const row = table.rows.items[rowIndex];
        if (row.values.len != table.columns.len) return error.ConstraintViolation;
        for (table.columns, 0..) |col, index| {
            if (col.notNull and row.values[index] == .null) return error.ConstraintViolation;
        }
        var policy: ast.ConflictPolicy = .none;
        try self.validateConstraints(table, row.values, rowIndex, &policy);
    }

    /// True when an FK check postpones to COMMIT/statement end: the
    /// `defer_foreign_keys` pragma defers everything, otherwise only
    /// `DEFERRABLE INITIALLY DEFERRED` constraints defer.
    pub fn fkCheckDeferred(self: *const Schema, deferrable: bool, initiallyDeferred: bool) bool {
        return self.deferForeignKeys or (deferrable and initiallyDeferred);
    }

    fn validateConstraints(self: *const Schema, table: *const Table, values: []const Value, ignoredRow: ?usize, outPolicy: *ast.ConflictPolicy) !void {
        outPolicy.* = .none;
        var colNames = try self.allocator.alloc([]const u8, table.columns.len);
        defer self.allocator.free(colNames);
        for (table.columns, 0..) |col, idx| colNames[idx] = col.name;

        for (table.columns) |column| {
            if (column.checkExpr) |chk| {
                const passed = try exprEvaluator.evalCheck(self.allocator, colNames, values, chk);
                if (!passed) {
                    outPolicy.* = column.conflict;
                    return error.ConstraintViolation;
                }
            }
        }
        for (table.columns, 0..) |column, index| {
            if (column.primaryKey and values[index] == .null) {
                outPolicy.* = column.conflict;
                return error.ConstraintViolation;
            }
            if (column.unique or column.primaryKey) {
                if (values[index] != .null) for (table.rows.items, 0..) |existing, existingIndex| {
                    if (ignoredRow != null and ignoredRow.? == existingIndex) continue;
                    if (valuesEqual(existing.values[index], values[index])) {
                        outPolicy.* = column.conflict;
                        return error.ConstraintViolation;
                    }
                };
            }
            if (self.foreignKeysEnabled and !self.fkCheckDeferred(column.fkDeferrable, column.fkInitiallyDeferred)) {
                if (column.foreignTable) |foreignTableName| {
                    const foreignTable = self.findConst(foreignTableName) orelse return error.ConstraintViolation;
                    // Bare `REFERENCES t`: resolve the parent single-column PK.
                    const foreignIndex = if (column.foreignColumn) |name| blk: {
                        if (name.len == 0) break :blk parentPkColumnIndex(foreignTable) orelse return error.ConstraintViolation;
                        break :blk self.columnIndex(foreignTable, name) orelse return error.ConstraintViolation;
                    } else parentPkColumnIndex(foreignTable) orelse return error.ConstraintViolation;
                    if (values[index] != .null) {
                        var found = false;
                        // Self-reference: like the reference engine, the row
                        // under validation can satisfy its own parent key
                        // (immediate checks see the statement's own row).
                        if (std.ascii.eqlIgnoreCase(foreignTable.name, table.name) and valuesEqual(values[foreignIndex], values[index])) {
                            found = true;
                        }
                        if (!found) for (foreignTable.rows.items) |foreignRow| if (valuesEqual(foreignRow.values[foreignIndex], values[index])) {
                            found = true;
                            break;
                        };
                        if (!found) {
                            outPolicy.* = column.conflict;
                            return error.ConstraintViolation;
                        }
                    }
                }
            }
        }
        for (table.constraints) |constraint| {
            if (constraint.kind == .check) {
                if (constraint.checkExpr) |chk| {
                    const passed = try exprEvaluator.evalCheck(self.allocator, colNames, values, chk);
                    if (!passed) {
                        outPolicy.* = constraint.conflict;
                        return error.ConstraintViolation;
                    }
                }
                continue;
            }
            var hasNull = false;
            for (constraint.columns) |name| {
                const index = self.columnIndex(table, name) orelse return error.UnknownColumn;
                if (values[index] == .null) hasNull = true;
            }
            if (constraint.kind == .primaryKey and hasNull) {
                outPolicy.* = constraint.conflict;
                return error.ConstraintViolation;
            }
            if (constraint.kind == .unique and hasNull) continue;
            if (constraint.kind == .foreignKey) {
                if (!self.foreignKeysEnabled) continue;
                if (self.fkCheckDeferred(constraint.deferrable, constraint.initiallyDeferred)) continue;
                if (hasNull) continue;
                const foreignTable = self.findConst(constraint.foreignTable orelse return error.ConstraintViolation) orelse return error.ConstraintViolation;
                // Self-reference: the row under validation can satisfy its
                // own parent key (immediate checks see the statement's row).
                var selfMatched = std.ascii.eqlIgnoreCase(foreignTable.name, table.name);
                if (selfMatched) for (constraint.columns, constraint.referencedColumns) |childName, parentName| {
                    const childIndex = self.columnIndex(table, childName) orelse return error.UnknownColumn;
                    const parentIndex = self.columnIndex(foreignTable, parentName) orelse return error.UnknownColumn;
                    if (!valuesEqual(values[childIndex], values[parentIndex])) selfMatched = false;
                };
                if (!selfMatched) {
                    for (foreignTable.rows.items) |foreignRow| {
                        var matched = true;
                        for (constraint.columns, constraint.referencedColumns) |childName, parentName| {
                            const childIndex = self.columnIndex(table, childName) orelse return error.UnknownColumn;
                            const parentIndex = self.columnIndex(foreignTable, parentName) orelse return error.UnknownColumn;
                            if (!valuesEqual(values[childIndex], foreignRow.values[parentIndex])) matched = false;
                        }
                        if (matched) break;
                    } else {
                        outPolicy.* = constraint.conflict;
                        return error.ConstraintViolation;
                    }
                }
                continue;
            }
            for (table.rows.items, 0..) |existing, existingIndex| {
                if (ignoredRow != null and ignoredRow.? == existingIndex) continue;
                if (indexValuesEqual(table, values, existing.values, constraint.columns)) {
                    outPolicy.* = constraint.conflict;
                    return error.ConstraintViolation;
                }
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

    /// Ensure the `sqlite_stat1(tbl, idx, stat)` table exists. Canonical
    /// implementation lives in `stats.zig`; this wrapper preserves the
    /// `Schema.` API for existing callers (connection, planner).
    pub fn ensureStatTable(self: *Schema) !*Table {
        return statsMod.ensureStatTable(self);
    }

    /// Delete stat rows for a table (optionally one index). Canonical
    /// implementation lives in `stats.zig`; never fails.
    pub fn clearStatScope(self: *Schema, tableName: ?[]const u8, indexName: ?[]const u8) void {
        statsMod.clearStatScope(self, tableName, indexName);
    }

    /// Table row count from the stat table, or null when absent. Canonical
    /// implementation lives in `stats.zig`; borrowed name, never fails.
    pub fn statRowCount(self: *const Schema, tableName: []const u8) ?usize {
        return statsMod.statRowCount(self, tableName);
    }

    /// Ensure the `sqlite_sequence(name, seq)` table exists. Canonical
    /// implementation lives in `sequence.zig`; idempotent.
    pub fn ensureSequenceTable(self: *Schema) anyerror!void {
        return sequenceMod.ensureSequenceTable(self);
    }

    /// Current AUTOINCREMENT sequence for a table, or 0 when absent.
    /// Canonical implementation lives in `sequence.zig`; never fails.
    pub fn sequenceValue(self: *const Schema, tableName: []const u8) i64 {
        return sequenceMod.sequenceValue(self, tableName);
    }

    /// Set the AUTOINCREMENT sequence, creating the row when absent.
    /// Canonical implementation lives in `sequence.zig`.
    pub fn setSequenceValue(self: *Schema, tableName: []const u8, next: i64) anyerror!void {
        return sequenceMod.setSequenceValue(self, tableName, next);
    }

    fn applyAutoincrement(self: *Schema, table: *const Table, values: []Value) anyerror!void {
        // Canonical AUTOINCREMENT assignment lives in `sequence.zig`.
        return sequenceMod.applyAutoincrement(self, table, values);
    }

    /// Append a table row-count entry to `sqlite_stat1`. Canonical
    /// implementation lives in `stats.zig`; borrowed table.
    pub fn collectTableStats(self: *Schema, table: *const Table) !void {
        return statsMod.collectTableStats(self, table);
    }

    /// Append an index selectivity entry for rows matching the partial
    /// predicate. Canonical implementation lives in `stats.zig`.
    pub fn collectIndexStats(self: *Schema, table: *const Table, index: *const Index) !void {
        return statsMod.collectIndexStats(self, table, index);
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
                .defaultExpr = column.defaultExpr,
                .collate = column.collate,
                .conflict = column.conflict,
                .foreignKey = if (column.foreignTable != null) .{ .table = column.foreignTable.?, .column = column.foreignColumn orelse "", .onDelete = column.onDelete, .onUpdate = column.onUpdate, .deferrable = column.fkDeferrable, .initiallyDeferred = column.fkInitiallyDeferred } else null,
                .checkExpr = column.checkExpr,
                .generatedExpr = column.generatedExpr,
                .generatedStored = column.generatedStored,
            };
            const constraintDefinitions = try self.allocator.alloc(ast.TableConstraint, table.constraints.len);
            defer self.allocator.free(constraintDefinitions);
            for (table.constraints, 0..) |constraint, index| constraintDefinitions[index] = switch (constraint.kind) {
                .primaryKey => .{ .primaryKey = .{ .columns = constraint.columns, .conflict = constraint.conflict } },
                .unique => .{ .unique = .{ .columns = constraint.columns, .conflict = constraint.conflict } },
                .foreignKey => .{ .foreignKey = .{ .columns = constraint.columns, .table = constraint.foreignTable.?, .referencedColumns = constraint.referencedColumns, .onDelete = constraint.onDelete, .onUpdate = constraint.onUpdate, .deferrable = constraint.deferrable, .initiallyDeferred = constraint.initiallyDeferred } },
                .check => .{ .check = .{ .expr = constraint.checkExpr orelse .{ .literal = .null }, .conflict = constraint.conflict } },
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
        for (self.triggers.items) |trigger| try result.createTrigger(.{ .name = trigger.name, .table = trigger.table, .timing = trigger.timing, .event = trigger.event, .updateOf = trigger.updateOf, .whenSql = trigger.whenSql, .body = trigger.body, .eachRow = trigger.eachRow });
        result.foreignKeysEnabled = self.foreignKeysEnabled;
        result.deferForeignKeys = self.deferForeignKeys;
        return result;
    }
};

/// Borrowed value equality: NULL==NULL, ints by value, reals numerically
/// (int/real mix compares as floats), texts/blobs by bytes. Never fails.
/// Canonical implementation lives in `stats.zig`; this wrapper preserves the
/// existing `schema.valuesEqual` API for constraint checks.
pub fn valuesEqual(left: Value, right: Value) bool {
    return statsMod.valuesEqual(left, right);
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
