//! Picks table scans, index seeks, and join order.
//!
//! Plans borrow the schema; `QueryPlan` owns its column copies.
//! Planning falls back to a scan; only out of memory fails.
const std = @import("std");
const Cost = @import("cost.zig").Cost;
const cost = @import("cost.zig");
const ast = @import("../sql/ast.zig");
const exprEvaluator = @import("../sql/expr.zig");
const functions = @import("../sql/functions.zig");
const Value = @import("../vm/value.zig").Value;
const Schema = @import("../catalog/schema.zig").Schema;
const Table = @import("../catalog/schema.zig").Table;
const Index = @import("../catalog/schema.zig").Index;

/// Chosen access path for one table reference. See module docs for the SCAN /
/// SEARCH vocabulary and ownership (plan owns eqColumns + joinPlan only).
pub const Access = enum { tableScan, indexSeek, rowidLookup, coveringIndexScan, indexScan };
/// Physical scan flavor backing a `QueryPlan`. `coveringIndexScan` serves the
/// projection from the index alone; `rowidLookup` is an INTEGER PRIMARY KEY path.
pub const ScanType = enum { tableScan, rowidLookup, indexSeek, coveringIndexScan, indexScan };

/// Index match detail: equality prefix, optional range, covering/order flags.
/// Name slices borrow the schema; `eqColumns` is an owned copy (see deinit).
pub const IndexMatch = struct {
    indexName: []const u8,
    tableName: []const u8,
    eqColumns: []const []const u8,
    rangeColumn: ?[]const u8 = null,
    rangeOp1: ?ast.CompareOp = null,
    rangeOp2: ?ast.CompareOp = null,
    isCovering: bool = false,
    satisfiesOrderBy: bool = false,
    /// The matched index IS the WITHOUT ROWID primary key: `explain`
    /// renders `USING PRIMARY KEY (...)` with no index name, like the
    /// reference (`IsPrimaryKeyIndex` in EXPLAIN output).
    isPrimaryKey: bool = false,
};

/// Order-insensitive column-set equality (ASCII case-insensitive); the
/// reference requires equal cardinality between targets and index keys.
fn columnsMatchSet(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left) |a| {
        var found = false;
        for (right) |b| if (std.ascii.eqlIgnoreCase(a, b)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}

/// True when `index` is the PRIMARY KEY index of a WITHOUT ROWID table:
/// unique with exactly the PK column set (table-level group preferred,
/// else the single flagged column). Rowid tables keep the INTEGER
/// PRIMARY KEY wording through the rowidLookup path instead.
fn isPrimaryKeyIndex(table: *const Table, index: Index) bool {
    if (!table.withoutRowid or !index.unique) return false;
    for (index.columns, 0..) |_, position| if (index.keyExpr(position) != null) return false;
    for (table.constraints) |constraint| {
        if (constraint.kind != .primaryKey) continue;
        return columnsMatchSet(constraint.columns, index.columns);
    }
    var pkCount: usize = 0;
    var pkName: ?[]const u8 = null;
    for (table.columns) |col| if (col.primaryKey) {
        pkCount += 1;
        pkName = col.name;
    };
    if (pkCount != 1) return false;
    return index.columns.len == 1 and std.ascii.eqlIgnoreCase(index.columns[0], pkName.?);
}

/// Owned plan for one table reference plus an optional chained join plan.
/// Caller `deinit`s; `explain` renders owned SQLite-style plan text.
pub const QueryPlan = struct {
    tableName: []const u8,
    scanType: ScanType,
    indexMatch: ?IndexMatch = null,
    cost: Cost,
    needsTempSort: bool = false,
    joinPlan: ?*QueryPlan = null,
    allocator: std.mem.Allocator,
    /// Borrowed schema column name for a WITHOUT ROWID primary-key lookup
    /// (which has no rowid to name); `explain` renders it as
    /// `USING PRIMARY KEY (col=?)` like the reference.
    pkLookupColumn: ?[]const u8 = null,

    pub fn deinit(self: *QueryPlan) void {
        if (self.indexMatch) |im| {
            if (im.eqColumns.len > 0) {
                self.allocator.free(im.eqColumns);
            }
        }
        if (self.joinPlan) |jp| {
            jp.deinit();
            self.allocator.destroy(jp);
            self.joinPlan = null;
        }
    }

    pub fn explain(self: *const QueryPlan, allocator: std.mem.Allocator) ![]u8 {
        var baseText: []u8 = undefined;
        switch (self.scanType) {
            .tableScan => {
                if (self.tableName.len == 0) {
                    baseText = try allocator.dupe(u8, "SCAN CONSTANT ROW");
                } else {
                    baseText = try std.fmt.allocPrint(allocator, "SCAN {s}", .{self.tableName});
                }
            },
            .rowidLookup => {
                if (self.pkLookupColumn) |pkCol| {
                    baseText = try std.fmt.allocPrint(allocator, "SEARCH {s} USING PRIMARY KEY ({s}=?)", .{ self.tableName, pkCol });
                } else {
                    baseText = try std.fmt.allocPrint(allocator, "SEARCH {s} USING INTEGER PRIMARY KEY (rowid=?)", .{self.tableName});
                }
            },
            .indexScan => {
                if (self.indexMatch) |im| {
                    // A full WITHOUT ROWID primary-key scan names no index,
                    // like the reference (which only appends USING for
                    // searches, never for scans).
                    if (im.isPrimaryKey) {
                        baseText = try std.fmt.allocPrint(allocator, "SCAN {s}", .{self.tableName});
                    } else if (im.isCovering) {
                        baseText = try std.fmt.allocPrint(allocator, "SCAN {s} USING COVERING INDEX {s}", .{ self.tableName, im.indexName });
                    } else {
                        baseText = try std.fmt.allocPrint(allocator, "SCAN {s} USING INDEX {s}", .{ self.tableName, im.indexName });
                    }
                } else {
                    baseText = try std.fmt.allocPrint(allocator, "SCAN {s}", .{self.tableName});
                }
            },
            .indexSeek, .coveringIndexScan => {
                if (self.indexMatch) |im| {
                    var buf = std.ArrayList(u8).empty;
                    errdefer buf.deinit(allocator);

                    const formattedPrefix = if (im.isPrimaryKey)
                        try std.fmt.allocPrint(allocator, "SEARCH {s} USING PRIMARY KEY (", .{self.tableName})
                    else if (im.isCovering)
                        try std.fmt.allocPrint(allocator, "SEARCH {s} USING COVERING INDEX {s} (", .{ self.tableName, im.indexName })
                    else
                        try std.fmt.allocPrint(allocator, "SEARCH {s} USING INDEX {s} (", .{ self.tableName, im.indexName });
                    defer allocator.free(formattedPrefix);
                    try buf.appendSlice(allocator, formattedPrefix);

                    var termCount: usize = 0;
                    for (im.eqColumns) |col| {
                        if (termCount > 0) try buf.appendSlice(allocator, " AND ");
                        const formattedTerm = try std.fmt.allocPrint(allocator, "{s}=?", .{col});
                        defer allocator.free(formattedTerm);
                        try buf.appendSlice(allocator, formattedTerm);
                        termCount += 1;
                    }
                    if (im.rangeColumn) |rCol| {
                        if (im.rangeOp1) |op1| {
                            if (termCount > 0) try buf.appendSlice(allocator, " AND ");
                            const opStr = switch (op1) {
                                .greater => ">?",
                                .greaterEqual => ">=?",
                                .less => "<?",
                                .lessEqual => "<=?",
                                else => "=?",
                            };
                            const formattedRange = try std.fmt.allocPrint(allocator, "{s}{s}", .{ rCol, opStr });
                            defer allocator.free(formattedRange);
                            try buf.appendSlice(allocator, formattedRange);
                            termCount += 1;
                        }
                        if (im.rangeOp2) |op2| {
                            if (termCount > 0) try buf.appendSlice(allocator, " AND ");
                            const opStr = switch (op2) {
                                .greater => ">?",
                                .greaterEqual => ">=?",
                                .less => "<?",
                                .lessEqual => "<=?",
                                else => "=?",
                            };
                            const formattedRange = try std.fmt.allocPrint(allocator, "{s}{s}", .{ rCol, opStr });
                            defer allocator.free(formattedRange);
                            try buf.appendSlice(allocator, formattedRange);
                            termCount += 1;
                        }
                    }
                    try buf.appendSlice(allocator, ")");
                    baseText = try buf.toOwnedSlice(allocator);
                } else {
                    baseText = try std.fmt.allocPrint(allocator, "SCAN {s}", .{self.tableName});
                }
            },
        }

        if (self.needsTempSort) {
            defer allocator.free(baseText);
            baseText = try std.fmt.allocPrint(allocator, "{s} USE TEMP B-TREE FOR ORDER BY", .{baseText});
        }

        if (self.joinPlan) |jp| {
            defer allocator.free(baseText);
            const innerText = try jp.explain(allocator);
            defer allocator.free(innerText);
            return try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ baseText, innerText });
        }

        return baseText;
    }
};

pub const Plan = struct {
    access: Access,
    cost: Cost,
    queryPlan: ?QueryPlan = null,
};

/// One derived `column = constant` equality; both borrow the condition list.
const DerivedEquality = struct { column: []const u8, value: Value };

/// True when `conditions[index]` is AND-joined (not OR-joined, not negated).
/// Only such predicates are safe to seek on or derive from: an OR branch or
/// a negation does not hold for every result row.
fn isConjunctive(conditions: []const ast.Condition, index: usize) bool {
    if (conditions[index].negated) return false;
    if (conditions[index].joinOr) return false;
    if (index > 0 and conditions[index - 1].joinOr) return false;
    return true;
}

/// Case-insensitive full-string column key match (`a.x` and `b.x` differ).
fn columnKeyEq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn derivedHasColumn(entries: []const DerivedEquality, column: []const u8) bool {
    for (entries) |entry| if (columnKeyEq(entry.column, column)) return true;
    return false;
}

fn derivedLiteralFor(entries: []const DerivedEquality, column: []const u8) ?Value {
    for (entries) |entry| if (columnKeyEq(entry.column, column)) return entry.value;
    return null;
}

/// True when an equality or range bound can drive an index seek: the value
/// must resolve without a row (literals, parameters, pure combinations).
/// Column references, subqueries, and anything else fall back to scans —
/// seeking on them would bind a meaningless lookup (this mirrors what the
/// executor can resolve row-less in `plannedIndices`).
fn isSeekableValue(expr: ast.Expr) bool {
    return switch (expr) {
        .literal, .parameter => true,
        .unary => |un| isSeekableValue(un.expr.*),
        .binary => |bin| isSeekableValue(bin.left.*) and isSeekableValue(bin.right.*),
        .function => |call| functions.classify(call.name, functions.argCount(call)) == .scalar and seekableCallArgs(call),
        else => false,
    };
}

/// All arguments of a scalar call must themselves be seekable.
fn seekableCallArgs(call: anytype) bool {
    if (!isSeekableValue(call.argument.*)) return false;
    if (call.argument2) |a2| if (!isSeekableValue(a2.*)) return false;
    if (call.argument3) |a3| if (!isSeekableValue(a3.*)) return false;
    for (call.extraArgs) |arg| if (!isSeekableValue(arg)) return false;
    return true;
}

/// Equality closure over AND-joined `=` predicates: direct column=literal
/// facts plus column=column edges resolved to fixpoint, so
/// `a.x = b.x AND b.x = 5` also yields `a.x = 5`. OR-joined, negated,
/// parameter, null, and subquery equalities never derive. Entries whose
/// qualifier names `tableName` are additionally emitted bare, so the
/// planned table's own index matching (which compares bare names) sees
/// them. Output borrows `conditions`; the caller frees the outer slice.
/// Bounded: at most conditions.len + 1 fixpoint passes over a monotone set.
fn transitiveEqualities(
    allocator: std.mem.Allocator,
    conditions: []const ast.Condition,
    tableName: []const u8,
) ![]DerivedEquality {
    var out = std.ArrayList(DerivedEquality).empty;
    errdefer out.deinit(allocator);
    for (conditions, 0..) |cond, i| {
        if (!isConjunctive(conditions, i) or cond.op != .equal) continue;
        if (cond.value != .literal or cond.value.literal == .null) continue;
        if (derivedHasColumn(out.items, cond.column)) continue;
        try out.append(allocator, .{ .column = cond.column, .value = cond.value.literal });
    }
    var changed = true;
    var passes: usize = 0;
    while (changed and passes <= conditions.len) : (passes += 1) {
        changed = false;
        for (conditions, 0..) |cond, i| {
            if (!isConjunctive(conditions, i) or cond.op != .equal) continue;
            if (cond.value != .identifier) continue;
            if (derivedHasColumn(out.items, cond.column)) continue;
            if (derivedLiteralFor(out.items, cond.value.identifier)) |lit| {
                try out.append(allocator, .{ .column = cond.column, .value = lit });
                changed = true;
            }
        }
    }
    // Bare duplicates for own-table keys so bare-name index matching sees
    // `a.x = 5` on table `a` as `x = 5` (sound: the equality holds for
    // every result row, exactly like a directly written conjunct).
    const baseLen = out.items.len;
    var k: usize = 0;
    while (k < baseLen) : (k += 1) {
        const entry = out.items[k];
        const dot = std.mem.indexOfScalar(u8, entry.column, '.') orelse continue;
        if (!std.ascii.eqlIgnoreCase(entry.column[0..dot], tableName)) continue;
        const bare = entry.column[dot + 1 ..];
        if (bare.len == 0 or derivedHasColumn(out.items, bare)) continue;
        try out.append(allocator, .{ .column = bare, .value = entry.value });
    }
    return out.toOwnedSlice(allocator);
}

pub fn choose(rowCount: usize, hasIndex: bool, selective: bool) Plan {
    if (hasIndex and selective) return .{ .access = .indexSeek, .cost = cost.indexSeek(rowCount, 1, false, false) };
    return .{ .access = .tableScan, .cost = cost.tableScan(rowCount) };
}

pub fn planSelect(allocator: std.mem.Allocator, schema: *const Schema, selectStmt: anytype) !QueryPlan {
    const tableNameOpt: ?[]const u8 = selectStmt.table;
    const tableName = tableNameOpt orelse {
        return QueryPlan{
            .tableName = "",
            .scanType = .tableScan,
            .cost = cost.tableScan(1),
            .needsTempSort = false,
            .allocator = allocator,
        };
    };

    const orderList: []const ast.Order = selectStmt.orders;
    const conditionOpt: ?ast.Conditions = selectStmt.condition;
    const joinList: []const ast.Join = selectStmt.joins;

    const table = schema.findConst(tableName) orelse return error.UnknownTable;
    const rowCount = schema.statRowCount(table.name) orelse if (table.rows.items.len > 1000) table.rows.items.len else 1000;

    var bestPlan = QueryPlan{
        .tableName = table.name,
        .scanType = .tableScan,
        .cost = cost.tableScan(rowCount),
        .needsTempSort = orderList.len != 0,
        .allocator = allocator,
    };
    if (bestPlan.needsTempSort) {
        bestPlan.cost.total += cost.sortCost(rowCount).total;
    }

    if (conditionOpt) |conditions| {
        // Derived equalities join the direct ones for every access-path
        // check below (rowid, equality, range): each holds for every result
        // row exactly like a written AND conjunct, so seeking on one is
        // sound whenever seeking on a direct predicate is.
        const derived = try transitiveEqualities(allocator, conditions, table.name);
        defer allocator.free(derived);
        var allConds = try allocator.alloc(ast.Condition, conditions.len + derived.len);
        defer allocator.free(allConds);
        @memcpy(allConds[0..conditions.len], conditions);
        for (derived, 0..) |d, i| {
            allConds[conditions.len + i] = .{ .column = d.column, .op = .equal, .value = .{ .literal = d.value } };
        }
        const conds = allConds;
        for (conds) |cond| {
            const isRowid = std.ascii.eqlIgnoreCase(cond.column, "rowid") or std.ascii.eqlIgnoreCase(cond.column, "_rowid_") or std.ascii.eqlIgnoreCase(cond.column, "oid");
            var isPkInt = false;
            var pkCol: ?[]const u8 = null;
            for (table.columns) |col| {
                if (col.primaryKey and std.ascii.eqlIgnoreCase(col.name, cond.column) and std.ascii.eqlIgnoreCase(col.typeName, "INTEGER")) {
                    isPkInt = true;
                    pkCol = col.name;
                    break;
                }
            }
            if ((isRowid or isPkInt) and cond.op == .equal and isSeekableValue(cond.value)) {
                var rowidCost = cost.rowidLookup(rowCount);
                // A rowid-ordered scan satisfies the ORDER BY only when the
                // leading key is the looked-up rowid column (prefix rule).
                var rowidNeedsSort = true;
                if (orderList.len == 0) {
                    rowidNeedsSort = false;
                } else if (std.ascii.eqlIgnoreCase(orderList[0].column, cond.column)) {
                    rowidNeedsSort = false;
                }
                if (rowidNeedsSort) {
                    rowidCost.total += cost.sortCost(1).total;
                }
                if (rowidCost.compare(bestPlan.cost) == .lt) {
                    bestPlan = QueryPlan{
                        .tableName = table.name,
                        .scanType = .rowidLookup,
                        .cost = rowidCost,
                        .needsTempSort = rowidNeedsSort,
                        .allocator = allocator,
                        // WITHOUT ROWID tables have no rowid: name the PK
                        // column like the reference does.
                        .pkLookupColumn = if (table.withoutRowid) pkCol else null,
                    };
                }
            }
        }

        for (schema.indexes.items) |index| {
            if (!std.ascii.eqlIgnoreCase(index.table, table.name)) continue;
            if (index.whereExpr) |predicate| {
                if (!exprEvaluator.partialPredicateImpliedBy(predicate, conds)) continue;
            }

            var eqCols = std.ArrayList([]const u8).empty;
            errdefer eqCols.deinit(allocator);

            var rangeCol: ?[]const u8 = null;
            var rangeOp1: ?ast.CompareOp = null;
            var rangeOp2: ?ast.CompareOp = null;

            for (index.columns, 0..) |idxCol, keyPosition| {
                if (index.keyExpr(keyPosition)) |key| {
                    var conjunctive = true;
                    for (conds, 0..) |cond, condPosition| {
                        if (condPosition > 0 and cond.joinOr) conjunctive = false;
                    }
                    var foundExprEq = false;
                    if (conjunctive) for (conds) |cond| {
                        if (cond.leftExpr == null or cond.op != .equal) continue;
                        if (exprEvaluator.exprEqual(cond.leftExpr.?, key)) {
                            try eqCols.append(allocator, idxCol);
                            foundExprEq = true;
                            break;
                        }
                    };
                    if (foundExprEq) continue;
                }
                var foundEq = false;
                for (conds) |cond| {
                    if (std.ascii.eqlIgnoreCase(cond.column, idxCol) and cond.op == .equal and isSeekableValue(cond.value)) {
                        try eqCols.append(allocator, idxCol);
                        foundEq = true;
                        break;
                    }
                }
                if (foundEq) continue;

                for (conds) |cond| {
                    if (std.ascii.eqlIgnoreCase(cond.column, idxCol) and isSeekableValue(cond.value)) {
                        if (cond.op == .greater or cond.op == .greaterEqual or cond.op == .less or cond.op == .lessEqual) {
                            if (rangeCol == null) {
                                rangeCol = idxCol;
                                rangeOp1 = cond.op;
                            } else if (std.ascii.eqlIgnoreCase(rangeCol.?, idxCol)) {
                                rangeOp2 = cond.op;
                            }
                        }
                    }
                }
                break;
            }

            if (eqCols.items.len > 0 or rangeCol != null) {
                var isCovering = true;
                if (selectStmt.projections.len == 0) {
                    isCovering = false;
                }
                for (selectStmt.projections) |proj| {
                    switch (proj.expr) {
                        .identifier => |id| {
                            var inIdx = false;
                            for (index.columns) |idxCol| {
                                if (std.ascii.eqlIgnoreCase(idxCol, id)) {
                                    inIdx = true;
                                    break;
                                }
                            }
                            if (!inIdx) {
                                isCovering = false;
                                break;
                            }
                        },
                        .wildcard => {
                            isCovering = false;
                            break;
                        },
                        else => {},
                    }
                }

                // An index scan satisfies ORDER BY only when the leading sort
                // keys match the index column prefix past the equality
                // columns (SQLite may scan the index in either direction).
                var satisfiesOrder = false;
                if (orderList.len != 0) {
                    satisfiesOrder = true;
                    const nextOrderColIdx = eqCols.items.len;
                    for (orderList, 0..) |ord, keyOffset| {
                        const idxPos = nextOrderColIdx + keyOffset;
                        if (idxPos >= index.columns.len or !std.ascii.eqlIgnoreCase(ord.column, index.columns[idxPos])) {
                            satisfiesOrder = false;
                            break;
                        }
                    }
                }

                var idxCost = cost.indexSeek(rowCount, eqCols.items.len, rangeCol != null, index.unique);
                if (isCovering) {
                    idxCost.startup *= 0.5;
                    idxCost.total *= 0.8;
                }
                const idxNeedsSort = orderList.len != 0 and !satisfiesOrder;
                if (idxNeedsSort) {
                    idxCost.total += cost.sortCost(idxCost.rows).total;
                }

                if (idxCost.compare(bestPlan.cost) == .lt) {
                    if (bestPlan.indexMatch) |oldIm| {
                        if (oldIm.eqColumns.len > 0) allocator.free(oldIm.eqColumns);
                    }
                    bestPlan = QueryPlan{
                        .tableName = table.name,
                        .scanType = if (isCovering) .coveringIndexScan else .indexSeek,
                        .indexMatch = .{
                            .indexName = index.name,
                            .tableName = table.name,
                            .eqColumns = try eqCols.toOwnedSlice(allocator),
                            .rangeColumn = rangeCol,
                            .rangeOp1 = rangeOp1,
                            .rangeOp2 = rangeOp2,
                            .isCovering = isCovering,
                            .satisfiesOrderBy = satisfiesOrder,
                            .isPrimaryKey = isPrimaryKeyIndex(table, index),
                        },
                        .cost = idxCost,
                        .needsTempSort = idxNeedsSort,
                        .allocator = allocator,
                    };
                } else {
                    eqCols.deinit(allocator);
                }
            } else {
                eqCols.deinit(allocator);
            }
        }
    } else {
        // Without WHERE, an index scan in index order satisfies ORDER BY
        // when the leading sort keys match the index column prefix.
        if (orderList.len != 0) {
            for (schema.indexes.items) |index| {
                if (!std.ascii.eqlIgnoreCase(index.table, table.name)) continue;
                var prefixMatch = true;
                for (orderList, 0..) |ord, keyOffset| {
                    if (keyOffset >= index.columns.len or !std.ascii.eqlIgnoreCase(index.columns[keyOffset], ord.column)) {
                        prefixMatch = false;
                        break;
                    }
                }
                if (!prefixMatch) continue;
                var isCovering = true;
                if (selectStmt.projections.len == 0) {
                    isCovering = false;
                }
                for (selectStmt.projections) |proj| {
                    switch (proj.expr) {
                        .identifier => |id| {
                            var inIdx = false;
                            for (index.columns) |idxCol| {
                                if (std.ascii.eqlIgnoreCase(idxCol, id)) {
                                    inIdx = true;
                                    break;
                                }
                            }
                            if (!inIdx) {
                                isCovering = false;
                                break;
                            }
                        },
                        .wildcard => {
                            isCovering = false;
                            break;
                        },
                        else => {},
                    }
                }

                var scanCost = cost.tableScan(rowCount);
                if (isCovering) {
                    scanCost.startup *= 0.5;
                    scanCost.total *= 0.8;
                }
                scanCost.ordered = true;

                if (scanCost.compare(bestPlan.cost) == .lt) {
                    if (bestPlan.indexMatch) |oldIm| {
                        if (oldIm.eqColumns.len > 0) allocator.free(oldIm.eqColumns);
                    }
                    bestPlan = QueryPlan{
                        .tableName = table.name,
                        .scanType = .indexScan,
                        .indexMatch = .{
                            .indexName = index.name,
                            .tableName = table.name,
                            .eqColumns = &.{},
                            .rangeColumn = null,
                            .isCovering = isCovering,
                            .satisfiesOrderBy = true,
                            .isPrimaryKey = isPrimaryKeyIndex(table, index),
                        },
                        .cost = scanCost,
                        .needsTempSort = false,
                        .allocator = allocator,
                    };
                }
            }
        }
    }

    var joinHead: ?*QueryPlan = null;
    errdefer if (joinHead) |head| {
        head.deinit();
        allocator.destroy(head);
    };
    for (joinList) |join| {
        const innerTable = schema.findConst(join.table) orelse return error.UnknownTable;
        const innerRows = if (innerTable.rows.items.len > 1000) innerTable.rows.items.len else 1000;
        var innerBest = QueryPlan{
            .tableName = innerTable.name,
            .scanType = .tableScan,
            .cost = cost.tableScan(innerRows),
            .needsTempSort = false,
            .allocator = allocator,
        };
        for (schema.indexes.items) |idx| {
            if (!std.ascii.eqlIgnoreCase(idx.table, innerTable.name)) continue;
            if (idx.columns.len > 0 and std.ascii.eqlIgnoreCase(idx.columns[0], join.rightColumn)) {
                var innerIdxCost = cost.indexSeek(innerRows, 1, false, idx.unique);
                if (innerIdxCost.compare(innerBest.cost) == .lt) {
                    var innerEq = try allocator.alloc([]const u8, 1);
                    innerEq[0] = idx.columns[0];
                    innerBest = QueryPlan{
                        .tableName = innerTable.name,
                        .scanType = .indexSeek,
                        .indexMatch = .{
                            .indexName = idx.name,
                            .tableName = innerTable.name,
                            .eqColumns = innerEq,
                            .isCovering = false,
                            .satisfiesOrderBy = false,
                            .isPrimaryKey = isPrimaryKeyIndex(innerTable, idx),
                        },
                        .cost = innerIdxCost,
                        .needsTempSort = false,
                        .allocator = allocator,
                    };
                }
            }
        }

        const jpPtr = allocator.create(QueryPlan) catch |err| {
            innerBest.deinit();
            return err;
        };
        jpPtr.* = innerBest;
        jpPtr.joinPlan = joinHead;
        joinHead = jpPtr;
        bestPlan.cost = cost.joinCost(bestPlan.cost, innerBest.cost);
    }
    bestPlan.joinPlan = joinHead;

    return bestPlan;
}

test "planner chooses table scan or index seek" {
    try std.testing.expectEqual(Access.indexSeek, choose(100, true, true).access);
    try std.testing.expectEqual(Access.tableScan, choose(100, false, true).access);
}

test "planner plans full table scan without index" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER" },
        .{ .name = "val", .typeName = "TEXT" },
    };
    try schema.createTable("items", &cols, &.{});

    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "items"),
        .condition = @as(?ast.Conditions, null),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SCAN items", explained);
}

test "planner plans index seek for equality on indexed column" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER" },
        .{ .name = "code", .typeName = "TEXT" },
    };
    try schema.createTable("items", &cols, &.{});
    const idxCols = [_][]const u8{"code"};
    try schema.createIndex(.{
        .name = "items_code_idx",
        .table = "items",
        .columns = &idxCols,
    });

    const conds = [_]ast.Condition{
        .{ .column = "code", .op = .equal, .value = .{ .literal = .{ .text = "abc" } } },
    };
    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "items"),
        .condition = @as(?ast.Conditions, &conds),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SEARCH items USING INDEX items_code_idx (code=?)", explained);
}

test "planner plans composite index prefix and range scan" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "a", .typeName = "INTEGER" },
        .{ .name = "b", .typeName = "INTEGER" },
        .{ .name = "c", .typeName = "INTEGER" },
    };
    try schema.createTable("t1", &cols, &.{});
    const idxCols = [_][]const u8{ "a", "b" };
    try schema.createIndex(.{
        .name = "i1",
        .table = "t1",
        .columns = &idxCols,
    });

    const conds = [_]ast.Condition{
        .{ .column = "a", .op = .equal, .value = .{ .literal = .{ .integer = 1 } } },
        .{ .column = "b", .op = .greater, .value = .{ .literal = .{ .integer = 2 } } },
    };
    const projs = [_]ast.Projection{
        .{ .expr = .{ .identifier = "a" } },
        .{ .expr = .{ .identifier = "b" } },
    };
    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "t1"),
        .condition = @as(?ast.Conditions, &conds),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &projs),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SEARCH t1 USING COVERING INDEX i1 (a=? AND b>?)", explained);
}

test "planner plans integer primary key rowid search" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "val", .typeName = "TEXT" },
    };
    try schema.createTable("users", &cols, &.{});

    const conds = [_]ast.Condition{
        .{ .column = "id", .op = .equal, .value = .{ .literal = .{ .integer = 42 } } },
    };
    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "users"),
        .condition = @as(?ast.Conditions, &conds),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SEARCH users USING INTEGER PRIMARY KEY (rowid=?)", explained);
}

test "planner names the pk column for without rowid lookups" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "val", .typeName = "TEXT" },
    };
    try schema.createTableWithOptions("widgets", &cols, &.{}, .{ .withoutRowid = true });

    const conds = [_]ast.Condition{
        .{ .column = "id", .op = .equal, .value = .{ .literal = .{ .integer = 7 } } },
    };
    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "widgets"),
        .condition = @as(?ast.Conditions, &conds),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SEARCH widgets USING PRIMARY KEY (id=?)", explained);
}

test "planner renders composite without rowid pk without index name" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "a", .typeName = "INTEGER" },
        .{ .name = "b", .typeName = "TEXT" },
        .{ .name = "v", .typeName = "INTEGER" },
    };
    const pkCols = [_][]const u8{ "a", "b" };
    const constraints = [_]ast.TableConstraint{
        .{ .primaryKey = &pkCols },
    };
    try schema.createTableWithOptions("pairs", &cols, &constraints, .{ .withoutRowid = true });

    const conds = [_]ast.Condition{
        .{ .column = "a", .op = .equal, .value = .{ .literal = .{ .integer = 1 } } },
        .{ .column = "b", .op = .equal, .value = .{ .literal = .{ .text = "x" } } },
    };
    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "pairs"),
        .condition = @as(?ast.Conditions, &conds),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SEARCH pairs USING PRIMARY KEY (a=? AND b=?)", explained);
}

test "planner keeps index name for ordinary unique seeks" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "email", .typeName = "TEXT", .unique = true },
    };
    try schema.createTable("accounts", &cols, &.{});

    const conds = [_]ast.Condition{
        .{ .column = "email", .op = .equal, .value = .{ .literal = .{ .text = "a@x" } } },
    };
    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "accounts"),
        .condition = @as(?ast.Conditions, &conds),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    // Rowid tables never render PRIMARY KEY for plain unique indexes.
    try std.testing.expect(std.mem.indexOf(u8, explained, "USING INDEX ") != null);
}

test "planner uses index for order by to elide temp sort" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "c", .typeName = "INTEGER" },
        .{ .name = "d", .typeName = "TEXT" },
    };
    try schema.createTable("t2", &cols, &.{});
    const idxCols = [_][]const u8{"c"};
    try schema.createIndex(.{
        .name = "i4",
        .table = "t2",
        .columns = &idxCols,
    });

    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "t2"),
        .condition = @as(?ast.Conditions, null),
        .orders = @as([]const ast.Order, &.{.{ .column = "c", .descending = false }}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SCAN t2 USING INDEX i4", explained);
}

test "planner plans nested loop join with indexed inner table" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const colsA = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "name", .typeName = "TEXT" },
    };
    try schema.createTable("authors", &colsA, &.{});

    const colsB = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "author_id", .typeName = "INTEGER" },
        .{ .name = "title", .typeName = "TEXT" },
    };
    try schema.createTable("books", &colsB, &.{});
    const idxCols = [_][]const u8{"author_id"};
    try schema.createIndex(.{
        .name = "books_author_idx",
        .table = "books",
        .columns = &idxCols,
    });

    const joinDef = ast.Join{
        .kind = .inner,
        .table = "books",
        .leftTable = "authors",
        .leftColumn = "id",
        .rightTable = "books",
        .rightColumn = "author_id",
    };

    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "authors"),
        .condition = @as(?ast.Conditions, null),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &[_]ast.Join{joinDef}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SCAN authors\nSEARCH books USING INDEX books_author_idx (author_id=?)", explained);
}

test "planner row counts follow analyzed statistics" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER" },
    };
    try schema.createTable("widgets", &cols, &.{});
    const table = schema.find("widgets").?;
    var values = [_]Value{.{ .integer = 1 }};
    var second = [_]Value{.{ .integer = 2 }};
    var third = [_]Value{.{ .integer = 3 }};
    var fourth = [_]Value{.{ .integer = 4 }};
    var fifth = [_]Value{.{ .integer = 5 }};
    try schema.appendRow(table, &values);
    try schema.appendRow(table, &second);
    try schema.appendRow(table, &third);
    try schema.appendRow(table, &fourth);
    try schema.appendRow(table, &fifth);

    var fresh = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "widgets"),
        .condition = @as(?ast.Conditions, null),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer fresh.deinit();
    try std.testing.expectEqual(@as(f64, 1000.0), fresh.cost.total);

    try schema.collectTableStats(table);
    var analyzed = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "widgets"),
        .condition = @as(?ast.Conditions, null),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer analyzed.deinit();
    try std.testing.expectEqual(@as(f64, 5.0), analyzed.cost.total);

    while (table.rows.items.len > 1) {
        const removed = table.rows.orderedRemove(1);
        std.testing.allocator.free(removed.values);
    }
    var stale = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "widgets"),
        .condition = @as(?ast.Conditions, null),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer stale.deinit();
    try std.testing.expectEqual(@as(f64, 5.0), stale.cost.total);
}

test "planner derives join-transitive equalities for index seeks" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const aCols = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER" },
        .{ .name = "x", .typeName = "INTEGER" },
    };
    try schema.createTable("a", &aCols, &.{});
    const idxCols = [_][]const u8{"x"};
    try schema.createIndex(.{
        .name = "a_x_idx",
        .table = "a",
        .columns = &idxCols,
    });
    const bCols = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER" },
        .{ .name = "x", .typeName = "INTEGER" },
    };
    try schema.createTable("b", &bCols, &.{});

    // a.x = b.x AND b.x = 5 derives a.x = 5: index seek, not a scan.
    const conds = [_]ast.Condition{
        .{ .column = "a.x", .op = .equal, .value = .{ .identifier = "b.x" } },
        .{ .column = "b.x", .op = .equal, .value = .{ .literal = .{ .integer = 5 } } },
    };
    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "a"),
        .condition = @as(?ast.Conditions, &conds),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SEARCH a USING INDEX a_x_idx (x=?)", explained);
}

test "planner chains single-table equalities to constants" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "x", .typeName = "INTEGER" },
        .{ .name = "y", .typeName = "INTEGER" },
    };
    try schema.createTable("t", &cols, &.{});
    const idxCols = [_][]const u8{"x"};
    try schema.createIndex(.{
        .name = "t_x_idx",
        .table = "t",
        .columns = &idxCols,
    });

    // x = y AND y = 7 derives x = 7 through the equality closure.
    const conds = [_]ast.Condition{
        .{ .column = "x", .op = .equal, .value = .{ .identifier = "y" } },
        .{ .column = "y", .op = .equal, .value = .{ .literal = .{ .integer = 7 } } },
    };
    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "t"),
        .condition = @as(?ast.Conditions, &conds),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SEARCH t USING INDEX t_x_idx (x=?)", explained);
}

test "planner never derives through OR branches" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();

    const cols = [_]ast.ColumnDef{
        .{ .name = "x", .typeName = "INTEGER" },
        .{ .name = "y", .typeName = "INTEGER" },
    };
    try schema.createTable("t", &cols, &.{});
    const idxCols = [_][]const u8{"x"};
    try schema.createIndex(.{
        .name = "t_x_idx",
        .table = "t",
        .columns = &idxCols,
    });

    // x = y OR y = 7: neither arm holds for every row, so no seek.
    const conds = [_]ast.Condition{
        .{ .column = "x", .op = .equal, .value = .{ .identifier = "y" }, .joinOr = true },
        .{ .column = "y", .op = .equal, .value = .{ .literal = .{ .integer = 7 } } },
    };
    var plan = try planSelect(std.testing.allocator, &schema, .{
        .table = @as(?[]const u8, "t"),
        .condition = @as(?ast.Conditions, &conds),
        .orders = @as([]const ast.Order, &.{}),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SCAN t", explained);
}
