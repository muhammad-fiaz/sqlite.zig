const std = @import("std");
const Cost = @import("cost.zig").Cost;
const cost = @import("cost.zig");
const ast = @import("../sql/ast.zig");
const exprEvaluator = @import("../sql/expr.zig");
const Schema = @import("../catalog/schema.zig").Schema;
const Table = @import("../catalog/schema.zig").Table;
const Index = @import("../catalog/schema.zig").Index;

pub const Access = enum { tableScan, indexSeek, rowidLookup, coveringIndexScan, indexScan };
pub const ScanType = enum { tableScan, rowidLookup, indexSeek, coveringIndexScan, indexScan };

pub const IndexMatch = struct {
    indexName: []const u8,
    tableName: []const u8,
    eqColumns: []const []const u8,
    rangeColumn: ?[]const u8 = null,
    rangeOp1: ?ast.CompareOp = null,
    rangeOp2: ?ast.CompareOp = null,
    isCovering: bool = false,
    satisfiesOrderBy: bool = false,
};

pub const QueryPlan = struct {
    tableName: []const u8,
    scanType: ScanType,
    indexMatch: ?IndexMatch = null,
    cost: Cost,
    needsTempSort: bool = false,
    joinPlan: ?*QueryPlan = null,
    allocator: std.mem.Allocator,

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
                baseText = try std.fmt.allocPrint(allocator, "SEARCH {s} USING INTEGER PRIMARY KEY (rowid=?)", .{self.tableName});
            },
            .indexScan => {
                if (self.indexMatch) |im| {
                    if (im.isCovering) {
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

                    const formattedPrefix = if (im.isCovering)
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

    const orderOpt: ?ast.Order = selectStmt.order;
    const conditionOpt: ?ast.Conditions = selectStmt.condition;
    const joinList: []const ast.Join = selectStmt.joins;

    const table = schema.findConst(tableName) orelse return error.UnknownTable;
    const rowCount = if (table.rows.items.len > 1000) table.rows.items.len else 1000;

    var bestPlan = QueryPlan{
        .tableName = table.name,
        .scanType = .tableScan,
        .cost = cost.tableScan(rowCount),
        .needsTempSort = orderOpt != null,
        .allocator = allocator,
    };
    if (bestPlan.needsTempSort) {
        bestPlan.cost.total += cost.sortCost(rowCount).total;
    }

    if (conditionOpt) |conditions| {
        for (conditions) |cond| {
            const isRowid = std.ascii.eqlIgnoreCase(cond.column, "rowid") or std.ascii.eqlIgnoreCase(cond.column, "_rowid_") or std.ascii.eqlIgnoreCase(cond.column, "oid");
            var isPkInt = false;
            for (table.columns) |col| {
                if (col.primaryKey and std.ascii.eqlIgnoreCase(col.name, cond.column) and std.ascii.eqlIgnoreCase(col.typeName, "INTEGER")) {
                    isPkInt = true;
                    break;
                }
            }
            if ((isRowid or isPkInt) and cond.op == .equal) {
                var rowidCost = cost.rowidLookup(rowCount);
                var rowidNeedsSort = orderOpt != null;
                if (orderOpt) |ord| {
                    if (std.ascii.eqlIgnoreCase(ord.column, cond.column)) {
                        rowidNeedsSort = false;
                    }
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
                    };
                }
            }
        }

        for (schema.indexes.items) |index| {
            if (!std.ascii.eqlIgnoreCase(index.table, table.name)) continue;
            if (index.whereExpr) |predicate| {
                if (!exprEvaluator.partialPredicateImpliedBy(predicate, conditions)) continue;
            }

            var eqCols = std.ArrayList([]const u8).empty;
            errdefer eqCols.deinit(allocator);

            var rangeCol: ?[]const u8 = null;
            var rangeOp1: ?ast.CompareOp = null;
            var rangeOp2: ?ast.CompareOp = null;

            for (index.columns, 0..) |idxCol, keyPosition| {
                if (index.keyExpr(keyPosition)) |key| {
                    var conjunctive = true;
                    for (conditions, 0..) |cond, condPosition| {
                        if (condPosition > 0 and cond.joinOr) conjunctive = false;
                    }
                    var foundExprEq = false;
                    if (conjunctive) for (conditions) |cond| {
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
                for (conditions) |cond| {
                    if (std.ascii.eqlIgnoreCase(cond.column, idxCol) and cond.op == .equal) {
                        try eqCols.append(allocator, idxCol);
                        foundEq = true;
                        break;
                    }
                }
                if (foundEq) continue;

                for (conditions) |cond| {
                    if (std.ascii.eqlIgnoreCase(cond.column, idxCol)) {
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

                var satisfiesOrder = false;
                if (orderOpt) |ord| {
                    const nextOrderColIdx = eqCols.items.len;
                    if (nextOrderColIdx < index.columns.len) {
                        if (std.ascii.eqlIgnoreCase(ord.column, index.columns[nextOrderColIdx])) {
                            satisfiesOrder = true;
                        }
                    }
                }

                var idxCost = cost.indexSeek(rowCount, eqCols.items.len, rangeCol != null, index.unique);
                if (isCovering) {
                    idxCost.startup *= 0.5;
                    idxCost.total *= 0.8;
                }
                const idxNeedsSort = orderOpt != null and !satisfiesOrder;
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
        if (orderOpt) |ord| {
            for (schema.indexes.items) |index| {
                if (!std.ascii.eqlIgnoreCase(index.table, table.name)) continue;
                if (index.columns.len > 0 and std.ascii.eqlIgnoreCase(index.columns[0], ord.column)) {
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
                            },
                            .cost = scanCost,
                            .needsTempSort = false,
                            .allocator = allocator,
                        };
                    }
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
        .order = @as(?ast.Order, null),
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
        .order = @as(?ast.Order, null),
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
        .order = @as(?ast.Order, null),
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
        .order = @as(?ast.Order, null),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &.{}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SEARCH users USING INTEGER PRIMARY KEY (rowid=?)", explained);
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
        .order = @as(?ast.Order, .{ .column = "c", .descending = false }),
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
        .order = @as(?ast.Order, null),
        .projections = @as([]const ast.Projection, &.{}),
        .joins = @as([]const ast.Join, &[_]ast.Join{joinDef}),
    });
    defer plan.deinit();

    const explained = try plan.explain(std.testing.allocator);
    defer std.testing.allocator.free(explained);
    try std.testing.expectEqualStrings("SCAN authors\nSEARCH books USING INDEX books_author_idx (author_id=?)", explained);
}
