//! Database file image codec (pages, b-trees, catalog).
//!
//! `encode` returns a fresh image; `decode` returns an owned Schema.
//! Corrupt pages fail closed; b-tree depth and allocs stay bounded.

const std = @import("std");
const Header = @import("../format/header.zig").Header;
const headerSize = @import("../format/header.zig").size;
const varint = @import("../format/varint.zig");
const record = @import("../format/record.zig");
const Schema = @import("../catalog/schema.zig").Schema;
const Value = @import("../vm/value.zig").Value;
const ast = @import("../sql/ast.zig");
const Parser = @import("../sql/parser.zig").Parser;
const exprEvaluator = @import("../sql/expr.zig");

/// Decoded table-leaf cell: rowid plus owned values (text/blob duped).
const Cell = struct { rowid: u64, values: []Value };

/// Default page size used by `encode` (matches fresh-file geometry).
pub const pageSize: usize = 4096;

/// Maximum b-tree descent depth while decoding.
/// Bounds untrusted child pages so cycles fail instead of overflowing.
pub const maxBtreeDepth: usize = 64;

/// Writes a big-endian u16 at `offset`.
///
/// Safety: bounds-checked — returns `PageOverflow` instead of writing out of
/// bounds, so corrupt offsets fail closed on both encode and decode paths.
fn putU16(bytes: []u8, offset: usize, value: u16) !void {
    if (offset + 2 > bytes.len) return error.PageOverflow;
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

/// Reads a big-endian u16 at `offset`.
///
/// Safety: bounds-checked — short buffers return `InvalidHeader` instead of
/// reading out of bounds.
fn getU16(bytes: []const u8, offset: usize) !u16 {
    if (offset + 2 > bytes.len) return error.InvalidHeader;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

/// Case-insensitive column lookup; `null` when the table has no such column.
fn columnIndex(table: anytype, name: []const u8) ?usize {
    for (table.columns, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name, name)) return index;
    return null;
}

/// Renders a `DEFAULT` literal for regenerated `CREATE TABLE` SQL
/// (NULL/numbers verbatim, text/blob single-quoted with `''` escapes).
fn appendSqlLiteral(allocator: std.mem.Allocator, sql: *std.ArrayList(u8), value: Value) !void {
    switch (value) {
        .null => try sql.appendSlice(allocator, "NULL"),
        .integer => |number| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{number});
            defer allocator.free(rendered);
            try sql.appendSlice(allocator, rendered);
        },
        .real => |number| {
            const rendered = try std.fmt.allocPrint(allocator, "{d}", .{number});
            defer allocator.free(rendered);
            try sql.appendSlice(allocator, rendered);
        },
        .text, .blob => |bytes| {
            try sql.append(allocator, '\'');
            for (bytes) |byte| {
                if (byte == '\'') try sql.append(allocator, '\'');
                try sql.append(allocator, byte);
            }
            try sql.append(allocator, '\'');
        },
    }
}

/// Appends one varint to a cell being framed (payload lengths, rowids).
fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buffer: [9]u8 = undefined;
    const length = try varint.encode(value, &buffer);
    try list.appendSlice(allocator, buffer[0..length]);
}

/// Scratch arena of zeroed page buffers during `encode`.
/// Owns every page; numbers are 1-based indices into `pages`.
const PageBuilder = struct {
    /// Allocator for page buffers and the page list.
    allocator: std.mem.Allocator,
    /// Image geometry (validated power of two, 512..65536).
    pageSize: usize,
    /// Owned page images in 1-based page-number order.
    pages: std.ArrayList([]u8),

    /// Creates an empty builder (no pages until `newPage`).
    fn init(allocator: std.mem.Allocator, ps: usize) PageBuilder {
        return .{ .allocator = allocator, .pageSize = ps, .pages = .empty };
    }

    /// Frees every page image and the list itself.
    fn deinit(self: *PageBuilder) void {
        for (self.pages.items) |p| self.allocator.free(p);
        self.pages.deinit(self.allocator);
    }

    /// Appends a zeroed page, returning its 1-based number.
    fn newPage(self: *PageBuilder) !u32 {
        const page = try self.allocator.alloc(u8, self.pageSize);
        @memset(page, 0);
        try self.pages.append(self.allocator, page);
        return @intCast(self.pages.items.len);
    }

    /// Borrows a built page by 1-based number (caller must hold a valid one).
    fn getPage(self: *PageBuilder, pageNumber: u32) []u8 {
        return self.pages.items[pageNumber - 1];
    }
};

/// Frames one table-leaf cell (payload varint + rowid varint + local bytes).
/// Large payloads spill to overflow pages; returns a caller-owned buffer.
fn buildCell(pageBuilder: *PageBuilder, rowid: u64, values: []const Value, databasePageSize: usize) ![]u8 {
    const payload = try record.encode(pageBuilder.allocator, values);
    defer pageBuilder.allocator.free(payload);

    const maxLeaf = databasePageSize - 35;
    const minLeaf = ((databasePageSize - 12) * 32 / 255) - 23;

    if (payload.len <= maxLeaf) {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(pageBuilder.allocator);
        try appendVarint(&result, pageBuilder.allocator, payload.len);
        try appendVarint(&result, pageBuilder.allocator, rowid);
        try result.appendSlice(pageBuilder.allocator, payload);
        return result.toOwnedSlice(pageBuilder.allocator);
    } else {
        const usableMinus4 = databasePageSize - 4;
        const surplus = minLeaf + (payload.len - minLeaf) % usableMinus4;
        const localBytes = if (surplus <= maxLeaf) surplus else minLeaf;
        const overflowBytes = payload.len - localBytes;

        const numOverflowPages = (overflowBytes + usableMinus4 - 1) / usableMinus4;
        const overflowPageNums = try pageBuilder.allocator.alloc(u32, numOverflowPages);
        defer pageBuilder.allocator.free(overflowPageNums);
        for (overflowPageNums) |*pNum| {
            pNum.* = try pageBuilder.newPage();
        }

        var offset = localBytes;
        for (overflowPageNums, 0..) |pNum, i| {
            const nextPageNum: u32 = if (i + 1 < numOverflowPages) overflowPageNums[i + 1] else 0;
            const chunkLen = @min(usableMinus4, payload.len - offset);
            const pageData = pageBuilder.getPage(pNum);
            std.mem.writeInt(u32, pageData[0..4], nextPageNum, .big);
            @memcpy(pageData[4 .. 4 + chunkLen], payload[offset .. offset + chunkLen]);
            offset += chunkLen;
        }

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(pageBuilder.allocator);
        try appendVarint(&result, pageBuilder.allocator, payload.len);
        try appendVarint(&result, pageBuilder.allocator, rowid);
        try result.appendSlice(pageBuilder.allocator, payload[0..localBytes]);
        var pBuf: [4]u8 = undefined;
        std.mem.writeInt(u32, &pBuf, overflowPageNums[0], .big);
        try result.appendSlice(pageBuilder.allocator, &pBuf);
        return result.toOwnedSlice(pageBuilder.allocator);
    }
}

/// Frames one index-leaf cell (payload varint + local bytes, no rowid).
/// Follows `buildCell` for overflow; returns a caller-owned buffer.
fn buildIndexCell(pageBuilder: *PageBuilder, values: []const Value, databasePageSize: usize) ![]u8 {
    const payload = try record.encode(pageBuilder.allocator, values);
    defer pageBuilder.allocator.free(payload);

    const maxLocal = ((databasePageSize - 12) * 64 / 255) - 23;
    const minLocal = ((databasePageSize - 12) * 32 / 255) - 23;

    if (payload.len <= maxLocal) {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(pageBuilder.allocator);
        try appendVarint(&result, pageBuilder.allocator, payload.len);
        try result.appendSlice(pageBuilder.allocator, payload);
        return result.toOwnedSlice(pageBuilder.allocator);
    } else {
        const usableMinus4 = databasePageSize - 4;
        const surplus = minLocal + (payload.len - minLocal) % usableMinus4;
        const localBytes = if (surplus <= maxLocal) surplus else minLocal;
        const overflowBytes = payload.len - localBytes;

        const numOverflowPages = (overflowBytes + usableMinus4 - 1) / usableMinus4;
        const overflowPageNums = try pageBuilder.allocator.alloc(u32, numOverflowPages);
        defer pageBuilder.allocator.free(overflowPageNums);
        for (overflowPageNums) |*pNum| {
            pNum.* = try pageBuilder.newPage();
        }

        var offset = localBytes;
        for (overflowPageNums, 0..) |pNum, i| {
            const nextPageNum: u32 = if (i + 1 < numOverflowPages) overflowPageNums[i + 1] else 0;
            const chunkLen = @min(usableMinus4, payload.len - offset);
            const pageData = pageBuilder.getPage(pNum);
            std.mem.writeInt(u32, pageData[0..4], nextPageNum, .big);
            @memcpy(pageData[4 .. 4 + chunkLen], payload[offset .. offset + chunkLen]);
            offset += chunkLen;
        }

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(pageBuilder.allocator);
        try appendVarint(&result, pageBuilder.allocator, payload.len);
        try result.appendSlice(pageBuilder.allocator, payload[0..localBytes]);
        var pBuf: [4]u8 = undefined;
        std.mem.writeInt(u32, &pBuf, overflowPageNums[0], .big);
        try result.appendSlice(pageBuilder.allocator, &pBuf);
        return result.toOwnedSlice(pageBuilder.allocator);
    }
}

/// Lays out one table/index leaf page (encode path).
/// Checked arithmetic fails with `PageOverflow` instead of writing out of bounds.
fn addLeafPage(page: []u8, pageStart: usize, headerOffset: usize, pageType: u8, cells: []const []const u8, databasePageSize: usize) !void {
    if (cells.len > 0xffff) return error.PageOverflow;
    const header = std.math.add(usize, pageStart, headerOffset) catch return error.PageOverflow;
    const pageEnd = std.math.add(usize, pageStart, databasePageSize) catch return error.PageOverflow;
    if (pageEnd > page.len) return error.PageOverflow;
    if (header + 8 > pageEnd) return error.PageOverflow;
    const arrayBytes = std.math.mul(usize, cells.len, 2) catch return error.PageOverflow;
    const reservedEnd = std.math.add(usize, header + 8, arrayBytes) catch return error.PageOverflow;
    if (reservedEnd > pageEnd) return error.PageOverflow;
    var content = pageEnd;
    for (cells) |item| {
        // `content >= reservedEnd` holds by construction, so the subtract
        // cannot underflow; cells that exceed the free gap overflow cleanly.
        if (item.len > content - reservedEnd) return error.PageOverflow;
        content -= item.len;
        @memcpy(page[content .. content + item.len], item);
    }
    page[header] = pageType;
    try putU16(page, header + 1, 0);
    try putU16(page, header + 3, @intCast(cells.len));
    try putU16(page, header + 5, @intCast(content - pageStart));
    page[header + 7] = 0;
    content = pageEnd;
    for (cells, 0..) |item, index| {
        content -= item.len;
        try putU16(page, header + 8 + index * 2, @intCast(content - pageStart));
    }
}

/// Lays out one table-interior page (encode path; checked like `addLeafPage`).
fn addInteriorTablePage(allocator: std.mem.Allocator, page: []u8, pageStart: usize, headerOffset: usize, leftChildren: []const u32, keys: []const u64, rightChild: u32, databasePageSize: usize) !void {
    const header = std.math.add(usize, pageStart, headerOffset) catch return error.PageOverflow;
    const pageEnd = std.math.add(usize, pageStart, databasePageSize) catch return error.PageOverflow;
    if (pageEnd > page.len) return error.PageOverflow;
    if (header + 12 > pageEnd) return error.PageOverflow;
    if (leftChildren.len != keys.len) return error.InvalidParam;
    if (leftChildren.len > 0xffff) return error.PageOverflow;
    const arrayBytes = std.math.mul(usize, leftChildren.len, 2) catch return error.PageOverflow;
    const reservedEnd = std.math.add(usize, header + 12, arrayBytes) catch return error.PageOverflow;
    if (reservedEnd > pageEnd) return error.PageOverflow;
    var content = pageEnd;
    const offsets = try allocator.alloc(u16, leftChildren.len);
    defer allocator.free(offsets);

    for (leftChildren, 0..) |child, idx| {
        var keyBuf: [9]u8 = undefined;
        const keyLen = try varint.encode(keys[idx], &keyBuf);
        const cellSize = 4 + keyLen;
        if (cellSize > content - reservedEnd) return error.PageOverflow;
        content -= cellSize;
        std.mem.writeInt(u32, page[content .. content + 4][0..4], child, .big);
        @memcpy(page[content + 4 .. content + 4 + keyLen], keyBuf[0..keyLen]);
        offsets[idx] = @intCast(content - pageStart);
    }

    page[header] = 0x05;
    try putU16(page, header + 1, 0);
    try putU16(page, header + 3, @intCast(leftChildren.len));
    try putU16(page, header + 5, @intCast(content - pageStart));
    page[header + 7] = 0;
    std.mem.writeInt(u32, page[header + 8 .. header + 12][0..4], rightChild, .big);

    for (offsets, 0..) |off, idx| {
        try putU16(page, header + 12 + idx * 2, off);
    }
}

fn addInteriorIndexPage(allocator: std.mem.Allocator, page: []u8, pageStart: usize, headerOffset: usize, leftChildren: []const u32, payloads: []const []const u8, rightChild: u32, databasePageSize: usize) !void {
    const header = std.math.add(usize, pageStart, headerOffset) catch return error.PageOverflow;
    const pageEnd = std.math.add(usize, pageStart, databasePageSize) catch return error.PageOverflow;
    if (pageEnd > page.len) return error.PageOverflow;
    if (header + 12 > pageEnd) return error.PageOverflow;
    if (leftChildren.len != payloads.len) return error.InvalidParam;
    if (leftChildren.len > 0xffff) return error.PageOverflow;
    const arrayBytes = std.math.mul(usize, leftChildren.len, 2) catch return error.PageOverflow;
    const reservedEnd = std.math.add(usize, header + 12, arrayBytes) catch return error.PageOverflow;
    if (reservedEnd > pageEnd) return error.PageOverflow;
    var content = pageEnd;
    const offsets = try allocator.alloc(u16, leftChildren.len);
    defer allocator.free(offsets);

    for (leftChildren, 0..) |child, idx| {
        var lenBuf: [9]u8 = undefined;
        const lenBytes = try varint.encode(payloads[idx].len, &lenBuf);
        const cellSize = 4 + lenBytes + payloads[idx].len;
        if (cellSize > content - reservedEnd) return error.PageOverflow;
        content -= cellSize;
        std.mem.writeInt(u32, page[content .. content + 4][0..4], child, .big);
        @memcpy(page[content + 4 .. content + 4 + lenBytes], lenBuf[0..lenBytes]);
        @memcpy(page[content + 4 + lenBytes .. content + 4 + lenBytes + payloads[idx].len], payloads[idx]);
        offsets[idx] = @intCast(content - pageStart);
    }

    page[header] = 0x02;
    try putU16(page, header + 1, 0);
    try putU16(page, header + 3, @intCast(leftChildren.len));
    try putU16(page, header + 5, @intCast(content - pageStart));
    page[header + 7] = 0;
    std.mem.writeInt(u32, page[header + 8 .. header + 12][0..4], rightChild, .big);

    for (offsets, 0..) |off, idx| {
        try putU16(page, header + 12 + idx * 2, off);
    }
}

/// Builds a one- or two-level table b-tree, returning its root page.
///
/// Single leaf while the cells fit; otherwise chunks cells across leaves
/// under one interior page. Rowids are positional (`rowIndex + 1`).
fn buildTableBtree(allocator: std.mem.Allocator, pageBuilder: *PageBuilder, table: anytype, databasePageSize: usize) !u32 {
    var cellsList = std.ArrayList([]u8).empty;
    defer {
        for (cellsList.items) |c| allocator.free(c);
        cellsList.deinit(allocator);
    }
    var rowids = std.ArrayList(u64).empty;
    defer rowids.deinit(allocator);

    for (table.rows.items, 0..) |row, rowIndex| {
        const rowid: u64 = @intCast(rowIndex + 1);
        const item = try buildCell(pageBuilder, rowid, row.values, databasePageSize);
        try cellsList.append(allocator, item);
        try rowids.append(allocator, rowid);
    }

    var totalBytes: usize = 0;
    for (cellsList.items) |c| totalBytes += c.len + 2;

    if (totalBytes <= databasePageSize - 8) {
        const rootPage = try pageBuilder.newPage();
        try addLeafPage(pageBuilder.getPage(rootPage), 0, 0, 0x0d, cellsList.items, databasePageSize);
        return rootPage;
    }

    var leafPages = std.ArrayList(u32).empty;
    defer leafPages.deinit(allocator);
    var leafMaxKeys = std.ArrayList(u64).empty;
    defer leafMaxKeys.deinit(allocator);

    var startIdx: usize = 0;
    while (startIdx < cellsList.items.len) {
        var chunkBytes: usize = 0;
        var endIdx = startIdx;
        while (endIdx < cellsList.items.len) : (endIdx += 1) {
            const itemSize = cellsList.items[endIdx].len + 2;
            if (chunkBytes + itemSize > databasePageSize - 8 and endIdx > startIdx) break;
            chunkBytes += itemSize;
        }
        const leafPageNum = try pageBuilder.newPage();
        try addLeafPage(pageBuilder.getPage(leafPageNum), 0, 0, 0x0d, cellsList.items[startIdx..endIdx], databasePageSize);
        try leafPages.append(allocator, leafPageNum);
        try leafMaxKeys.append(allocator, rowids.items[endIdx - 1]);
        startIdx = endIdx;
    }

    const rootPage = try pageBuilder.newPage();
    const leftKids = leafPages.items[0 .. leafPages.items.len - 1];
    const keys = leafMaxKeys.items[0 .. leafPages.items.len - 1];
    const rightKid = leafPages.items[leafPages.items.len - 1];
    try addInteriorTablePage(allocator, pageBuilder.getPage(rootPage), 0, 0, leftKids, keys, rightKid, databasePageSize);
    return rootPage;
}

/// Builds an index b-tree over a table's rows, returning its root page.
/// Bad tables or columns fail instead of writing garbage.
fn buildIndexBtree(allocator: std.mem.Allocator, pageBuilder: *PageBuilder, schema: *const Schema, index: anytype, databasePageSize: usize) !u32 {
    const table = schema.findConst(index.table) orelse return error.UnknownTable;
    var indexCells = std.ArrayList([]u8).empty;
    defer {
        for (indexCells.items) |item| allocator.free(item);
        indexCells.deinit(allocator);
    }

    var colNames = try allocator.alloc([]const u8, table.columns.len);
    defer allocator.free(colNames);
    for (table.columns, 0..) |col, position| colNames[position] = col.name;
    for (table.rows.items, 0..) |row, rowPosition| {
        if (index.whereExpr) |predicate| {
            const holds = try exprEvaluator.evalPredicate(allocator, colNames, row.values, predicate);
            if (!holds) continue;
        }
        var values = try allocator.alloc(Value, index.columns.len + 1);
        defer allocator.free(values);
        for (index.columns, 0..) |column, position| {
            if (index.keyExpr(position)) |key| {
                values[position] = try exprEvaluator.eval(allocator, colNames, row.values, key);
                continue;
            }
            values[position] = row.values[columnIndex(table, column) orelse return error.UnknownColumn];
        }
        values[index.columns.len] = .{ .integer = @intCast(rowPosition + 1) };
        const item = try buildIndexCell(pageBuilder, values, databasePageSize);
        try indexCells.append(allocator, item);
        for (index.columns, 0..) |_, position| {
            if (index.keyExpr(position) != null) exprEvaluator.freeValue(allocator, values[position]);
        }
    }

    var totalBytes: usize = 0;
    for (indexCells.items) |c| totalBytes += c.len + 2;

    if (totalBytes <= databasePageSize - 8) {
        const rootPage = try pageBuilder.newPage();
        try addLeafPage(pageBuilder.getPage(rootPage), 0, 0, 0x0a, indexCells.items, databasePageSize);
        return rootPage;
    }

    var leafPages = std.ArrayList(u32).empty;
    defer leafPages.deinit(allocator);
    var dividerPayloads = std.ArrayList([]const u8).empty;
    defer dividerPayloads.deinit(allocator);

    var startIdx: usize = 0;
    while (startIdx < indexCells.items.len) {
        var chunkBytes: usize = 0;
        var endIdx = startIdx;
        while (endIdx < indexCells.items.len) : (endIdx += 1) {
            const itemSize = indexCells.items[endIdx].len + 2;
            if (chunkBytes + itemSize > databasePageSize - 8 and endIdx > startIdx) break;
            chunkBytes += itemSize;
        }
        const leafPageNum = try pageBuilder.newPage();
        try addLeafPage(pageBuilder.getPage(leafPageNum), 0, 0, 0x0a, indexCells.items[startIdx..endIdx], databasePageSize);
        try leafPages.append(allocator, leafPageNum);
        try dividerPayloads.append(allocator, indexCells.items[endIdx - 1]);
        startIdx = endIdx;
    }

    const rootPage = try pageBuilder.newPage();
    const leftKids = leafPages.items[0 .. leafPages.items.len - 1];
    const payloads = dividerPayloads.items[0 .. leafPages.items.len - 1];
    const rightKid = leafPages.items[leafPages.items.len - 1];
    try addInteriorIndexPage(allocator, pageBuilder.getPage(rootPage), 0, 0, leftKids, payloads, rightKid, databasePageSize);
    return rootPage;
}

/// Regenerates canonical `CREATE TABLE` SQL for the page-1 catalog.
///
/// CHECK constraints are intentionally skipped (stored separately), and
/// virtual tables take the `CREATE VIRTUAL TABLE ... USING` path.
fn createSql(allocator: std.mem.Allocator, table: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    if (table.virtualModule) |module| {
        try sql.appendSlice(allocator, "CREATE VIRTUAL TABLE ");
        try sql.appendSlice(allocator, table.name);
        try sql.appendSlice(allocator, " USING ");
        try sql.appendSlice(allocator, module);
        try sql.append(allocator, '(');
        for (table.virtualArguments, 0..) |argument, index| {
            if (index != 0) try sql.appendSlice(allocator, ", ");
            try sql.appendSlice(allocator, argument);
        }
        try sql.appendSlice(allocator, ");");
        return sql.toOwnedSlice(allocator);
    }
    try sql.appendSlice(allocator, "CREATE TABLE ");
    try sql.appendSlice(allocator, table.name);
    try sql.appendSlice(allocator, " (");
    for (table.columns, 0..) |column, index| {
        if (index != 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, column.name);
        if (column.typeName.len != 0) {
            try sql.append(allocator, ' ');
            try sql.appendSlice(allocator, column.typeName);
        }
        if (column.primaryKey) try sql.appendSlice(allocator, " PRIMARY KEY");
        if (column.autoincrement) try sql.appendSlice(allocator, " AUTOINCREMENT");
        if (column.notNull) try sql.appendSlice(allocator, " NOT NULL");
        if (column.unique) try sql.appendSlice(allocator, " UNIQUE");
        if (column.defaultValue) |default| {
            try sql.appendSlice(allocator, " DEFAULT ");
            try appendSqlLiteral(allocator, &sql, default);
        }
        if (column.foreignTable) |foreignTable| {
            try sql.appendSlice(allocator, " REFERENCES ");
            try sql.appendSlice(allocator, foreignTable);
            try sql.append(allocator, '(');
            try sql.appendSlice(allocator, column.foreignColumn.?);
            try sql.append(allocator, ')');
            switch (column.onDelete) {
                .restrict, .noAction => {},
                .cascade => try sql.appendSlice(allocator, " ON DELETE CASCADE"),
                .setNull => try sql.appendSlice(allocator, " ON DELETE SET NULL"),
                .setDefault => try sql.appendSlice(allocator, " ON DELETE SET DEFAULT"),
            }
            switch (column.onUpdate) {
                .restrict, .noAction => {},
                .cascade => try sql.appendSlice(allocator, " ON UPDATE CASCADE"),
                .setNull => try sql.appendSlice(allocator, " ON UPDATE SET NULL"),
                .setDefault => try sql.appendSlice(allocator, " ON UPDATE SET DEFAULT"),
            }
            if (column.fkDeferrable) {
                if (column.fkInitiallyDeferred) try sql.appendSlice(allocator, " DEFERRABLE INITIALLY DEFERRED") else try sql.appendSlice(allocator, " DEFERRABLE INITIALLY IMMEDIATE");
            }
        }
    }
    for (table.constraints) |constraint| {
        if (constraint.kind == .check) continue;
        try sql.appendSlice(allocator, ", ");
        if (constraint.kind == .foreignKey) {
            try sql.appendSlice(allocator, "FOREIGN KEY (");
        } else try sql.appendSlice(allocator, switch (constraint.kind) {
            .primaryKey => "PRIMARY KEY (",
            .unique => "UNIQUE (",
            .foreignKey, .check => unreachable,
        });
        for (constraint.columns, 0..) |column, position| {
            if (position != 0) try sql.appendSlice(allocator, ", ");
            try sql.appendSlice(allocator, column);
        }
        try sql.append(allocator, ')');
        if (constraint.kind == .foreignKey) {
            try sql.appendSlice(allocator, " REFERENCES ");
            try sql.appendSlice(allocator, constraint.foreignTable.?);
            try sql.appendSlice(allocator, " (");
            for (constraint.referencedColumns, 0..) |column, position| {
                if (position != 0) try sql.appendSlice(allocator, ", ");
                try sql.appendSlice(allocator, column);
            }
            try sql.append(allocator, ')');
            switch (constraint.onDelete) {
                .restrict, .noAction => {},
                .cascade => try sql.appendSlice(allocator, " ON DELETE CASCADE"),
                .setNull => try sql.appendSlice(allocator, " ON DELETE SET NULL"),
                .setDefault => try sql.appendSlice(allocator, " ON DELETE SET DEFAULT"),
            }
            switch (constraint.onUpdate) {
                .restrict, .noAction => {},
                .cascade => try sql.appendSlice(allocator, " ON UPDATE CASCADE"),
                .setNull => try sql.appendSlice(allocator, " ON UPDATE SET NULL"),
                .setDefault => try sql.appendSlice(allocator, " ON UPDATE SET DEFAULT"),
            }
            if (constraint.deferrable) {
                if (constraint.initiallyDeferred) try sql.appendSlice(allocator, " DEFERRABLE INITIALLY DEFERRED") else try sql.appendSlice(allocator, " DEFERRABLE INITIALLY IMMEDIATE");
            }
        }
    }
    try sql.appendSlice(allocator, ")");
    if (table.withoutRowid) try sql.appendSlice(allocator, " WITHOUT ROWID");
    if (table.strict) {
        if (table.withoutRowid) try sql.appendSlice(allocator, ",");
        try sql.appendSlice(allocator, " STRICT");
    }
    try sql.appendSlice(allocator, ";");
    return sql.toOwnedSlice(allocator);
}

/// Regenerates `CREATE [UNIQUE] INDEX` SQL (plus `WHERE` for partial indexes).
fn createIndexSql(allocator: std.mem.Allocator, index: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    try sql.appendSlice(allocator, if (index.unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
    try sql.appendSlice(allocator, index.name);
    try sql.appendSlice(allocator, " ON ");
    try sql.appendSlice(allocator, index.table);
    try sql.appendSlice(allocator, " (");
    for (index.columns, 0..) |column, position| {
        if (position != 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, column);
    }
    try sql.appendSlice(allocator, ")");
    if (index.whereSql) |predicate| {
        try sql.appendSlice(allocator, " WHERE ");
        try sql.appendSlice(allocator, predicate);
    }
    try sql.appendSlice(allocator, ";");
    return sql.toOwnedSlice(allocator);
}

/// Regenerates `CREATE VIEW` SQL from the stored select text.
fn createViewSql(allocator: std.mem.Allocator, view: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    try sql.appendSlice(allocator, "CREATE VIEW ");
    try sql.appendSlice(allocator, view.name);
    try sql.appendSlice(allocator, " AS ");
    try sql.appendSlice(allocator, view.sql);
    return sql.toOwnedSlice(allocator);
}

/// Regenerates `CREATE TRIGGER` SQL (timing, event, column list, body).
fn createTriggerSql(allocator: std.mem.Allocator, trigger: anytype) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    try sql.appendSlice(allocator, "CREATE TRIGGER ");
    try sql.appendSlice(allocator, trigger.name);
    try sql.appendSlice(allocator, switch (trigger.timing) {
        .before => " BEFORE ",
        .after => " AFTER ",
    });
    try sql.appendSlice(allocator, switch (trigger.event) {
        .insert => "INSERT",
        .update => "UPDATE",
        .delete => "DELETE",
    });
    if (trigger.updateOf.len != 0) {
        try sql.appendSlice(allocator, " OF ");
        for (trigger.updateOf, 0..) |column, position| {
            if (position != 0) try sql.appendSlice(allocator, ", ");
            try sql.appendSlice(allocator, column);
        }
    }
    try sql.appendSlice(allocator, " ON ");
    try sql.appendSlice(allocator, trigger.table);
    if (trigger.whenSql) |whenSql| {
        try sql.appendSlice(allocator, " WHEN ");
        try sql.appendSlice(allocator, whenSql);
    }
    try sql.appendSlice(allocator, " BEGIN ");
    try sql.appendSlice(allocator, trigger.body);
    try sql.appendSlice(allocator, " END;");
    return sql.toOwnedSlice(allocator);
}

/// Frames one page-1 catalog cell (schema rows never use overflow pages:
/// catalog SQL is short, so the whole payload stays local).
fn buildSchemaCell(allocator: std.mem.Allocator, rowid: u64, values: []const Value) ![]u8 {
    const payload = try record.encode(allocator, values);
    defer allocator.free(payload);
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try appendVarint(&result, allocator, payload.len);
    try appendVarint(&result, allocator, rowid);
    try result.appendSlice(allocator, payload);
    return result.toOwnedSlice(allocator);
}

/// Encodes `schema` into a fresh caller-owned image with `databasePageSize`.
/// Virtual tables use root page 0; a full page-1 catalog fails with `PageOverflow`.
pub fn encodeWithPageSize(allocator: std.mem.Allocator, schema: *const Schema, databasePageSize: usize) ![]u8 {
    if (databasePageSize < 512 or databasePageSize > 65536 or (databasePageSize & (databasePageSize - 1)) != 0) return error.InvalidPageSize;

    var pageBuilder = PageBuilder.init(allocator, databasePageSize);
    defer pageBuilder.deinit();

    _ = try pageBuilder.newPage();

    var tableRootPages = try allocator.alloc(u32, schema.tables.items.len);
    defer allocator.free(tableRootPages);

    for (schema.tables.items, 0..) |table, index| {
        if (table.virtualModule != null) {
            tableRootPages[index] = 0;
        } else {
            tableRootPages[index] = try buildTableBtree(allocator, &pageBuilder, table, databasePageSize);
        }
    }

    var indexRootPages = try allocator.alloc(u32, schema.indexes.items.len);
    defer allocator.free(indexRootPages);

    for (schema.indexes.items, 0..) |index, position| {
        indexRootPages[position] = try buildIndexBtree(allocator, &pageBuilder, schema, index, databasePageSize);
    }

    var schemaCells = try allocator.alloc([]const u8, schema.tables.items.len + schema.indexes.items.len + schema.views.items.len + schema.triggers.items.len);
    defer allocator.free(schemaCells);
    var schemaOwned = std.ArrayList([]u8).empty;
    defer {
        for (schemaOwned.items) |item| allocator.free(item);
        schemaOwned.deinit(allocator);
    }

    for (schema.tables.items, 0..) |table, index| {
        const sql = try createSql(allocator, table);
        defer allocator.free(sql);
        const values = [_]Value{
            .{ .text = "table" },
            .{ .text = table.name },
            .{ .text = table.name },
            .{ .integer = @intCast(tableRootPages[index]) },
            .{ .text = sql },
        };
        const item = try buildSchemaCell(allocator, index + 1, &values);
        try schemaOwned.append(allocator, item);
        schemaCells[index] = item;
    }

    for (schema.indexes.items, 0..) |index, position| {
        const sql = if (std.mem.startsWith(u8, index.name, "sqlite_autoindex_")) null else try createIndexSql(allocator, index);
        defer if (sql) |ownedSql| allocator.free(ownedSql);
        const values = [_]Value{
            .{ .text = "index" },
            .{ .text = index.name },
            .{ .text = index.table },
            .{ .integer = @intCast(indexRootPages[position]) },
            if (sql) |ownedSql| .{ .text = ownedSql } else .null,
        };
        const item = try buildSchemaCell(allocator, schema.tables.items.len + position + 1, &values);
        try schemaOwned.append(allocator, item);
        schemaCells[schema.tables.items.len + position] = item;
    }

    for (schema.views.items, 0..) |view, position| {
        const sql = try createViewSql(allocator, view);
        defer allocator.free(sql);
        const values = [_]Value{
            .{ .text = "view" },
            .{ .text = view.name },
            .{ .text = view.name },
            .{ .integer = 0 },
            .{ .text = sql },
        };
        const item = try buildSchemaCell(allocator, schema.tables.items.len + schema.indexes.items.len + position + 1, &values);
        try schemaOwned.append(allocator, item);
        schemaCells[schema.tables.items.len + schema.indexes.items.len + position] = item;
    }

    for (schema.triggers.items, 0..) |trigger, position| {
        const sql = try createTriggerSql(allocator, trigger);
        defer allocator.free(sql);
        const values = [_]Value{
            .{ .text = "trigger" },
            .{ .text = trigger.name },
            .{ .text = trigger.table },
            .{ .integer = 0 },
            .{ .text = sql },
        };
        const item = try buildSchemaCell(allocator, schema.tables.items.len + schema.indexes.items.len + schema.views.items.len + position + 1, &values);
        try schemaOwned.append(allocator, item);
        schemaCells[schema.tables.items.len + schema.indexes.items.len + schema.views.items.len + position] = item;
    }

    try addLeafPage(pageBuilder.getPage(1), 0, headerSize, 0x0d, schemaCells, databasePageSize);

    var header = Header{
        .pageSize = @intCast(databasePageSize),
        .databaseSizePages = @intCast(pageBuilder.pages.items.len),
        .changeCounter = 1,
        .schemaCookie = 1,
    };
    header.encode(@ptrCast(pageBuilder.getPage(1)[0..headerSize].ptr));

    const totalBytes = pageBuilder.pages.items.len * databasePageSize;
    const finalBytes = try allocator.alloc(u8, totalBytes);
    errdefer allocator.free(finalBytes);

    for (pageBuilder.pages.items, 0..) |pData, pIdx| {
        @memcpy(finalBytes[pIdx * databasePageSize .. (pIdx + 1) * databasePageSize], pData);
    }

    return finalBytes;
}

/// Encodes `schema` with the default 4096-byte pages (see `pageSize`).
pub fn encode(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    return encodeWithPageSize(allocator, schema, pageSize);
}

/// One parsed catalog row: the b-tree root to replay plus its stored SQL.
const SchemaEntry = struct { rootPage: u32, sql: []const u8 };

/// Frees a cell's value array (text/blob bodies plus the array itself).
fn freeCellValues(allocator: std.mem.Allocator, values: []const Value) void {
    for (values) |v| {
        if (v == .text) {
            allocator.free(v.text);
        } else if (v == .blob) {
            allocator.free(v.blob);
        }
    }
    allocator.free(values);
}

/// Reads one table-leaf cell at `cellOffset` (decode path, untrusted input).
/// Every slice and overflow hop is bounds-checked; bad chains fail closed.
fn readCell(allocator: std.mem.Allocator, bytes: []const u8, cellOffset: usize, databasePageSize: usize) !Cell {
    var cursor = cellOffset;
    if (cursor >= bytes.len) return error.InvalidHeader;
    const payloadLengthDec = varint.decode(bytes[cursor..]) catch return error.InvalidHeader;
    cursor = std.math.add(usize, cursor, payloadLengthDec.length) catch return error.InvalidHeader;
    if (cursor >= bytes.len) return error.InvalidHeader;
    const rowidDec = varint.decode(bytes[cursor..]) catch return error.InvalidHeader;
    cursor = std.math.add(usize, cursor, rowidDec.length) catch return error.InvalidHeader;

    const totalPayload: usize = std.math.cast(usize, payloadLengthDec.value) orelse return error.InvalidHeader;
    // The whole payload (local + overflow) lives inside the image, so a
    // larger claim is corruption — and this check bounds the alloc below.
    if (totalPayload > bytes.len) return error.InvalidHeader;
    const maxLeaf = databasePageSize - 35;

    var fullPayload: ?[]u8 = null;
    defer if (fullPayload) |fp| allocator.free(fp);

    var rawValues: []Value = undefined;
    if (totalPayload <= maxLeaf) {
        if (cursor + totalPayload > bytes.len) return error.InvalidHeader;
        rawValues = try record.decode(allocator, bytes[cursor .. cursor + totalPayload]);
    } else {
        const minLeaf = ((databasePageSize - 12) * 32 / 255) - 23;
        const usableMinus4 = databasePageSize - 4;
        const surplus = minLeaf + (totalPayload - minLeaf) % usableMinus4;
        const localBytes = if (surplus <= maxLeaf) surplus else minLeaf;

        if (cursor + localBytes + 4 > bytes.len) return error.InvalidHeader;
        const firstOverflow = std.mem.readInt(u32, bytes[cursor + localBytes .. cursor + localBytes + 4][0..4], .big);

        const fp = try allocator.alloc(u8, totalPayload);
        fullPayload = fp;
        @memcpy(fp[0..localBytes], bytes[cursor .. cursor + localBytes]);

        const maxHops: usize = bytes.len / databasePageSize + 1;
        var assembled = localBytes;
        var currentOverflow = firstOverflow;
        var hops: usize = 0;
        while (currentOverflow != 0 and assembled < totalPayload) {
            // Each hop consumes a distinct page budget; cycles and over-long
            // chains exhaust it and fail closed instead of looping forever.
            if (hops >= maxHops) return error.InvalidHeader;
            hops += 1;
            if (currentOverflow == 0) return error.InvalidHeader;
            if (@as(u64, currentOverflow) > @as(u64, maxHops)) return error.InvalidHeader;
            const pageOffset = std.math.mul(usize, @as(usize, currentOverflow) - 1, databasePageSize) catch return error.InvalidHeader;
            if (pageOffset + databasePageSize > bytes.len) return error.InvalidHeader;
            const nextPage = std.mem.readInt(u32, bytes[pageOffset .. pageOffset + 4][0..4], .big);
            const chunkLen = @min(usableMinus4, totalPayload - assembled);
            @memcpy(fp[assembled .. assembled + chunkLen], bytes[pageOffset + 4 .. pageOffset + 4 + chunkLen]);
            assembled += chunkLen;
            currentOverflow = nextPage;
        }
        if (assembled != totalPayload) return error.InvalidHeader;

        rawValues = try record.decode(allocator, fp);
    }

    var processed: usize = 0;
    errdefer {
        for (rawValues[0..processed]) |v| {
            if (v == .text) allocator.free(v.text) else if (v == .blob) allocator.free(v.blob);
        }
        allocator.free(rawValues);
    }

    for (rawValues) |*v| {
        if (v.* == .text) {
            v.* = .{ .text = try allocator.dupe(u8, v.text) };
        } else if (v.* == .blob) {
            v.* = .{ .blob = try allocator.dupe(u8, v.blob) };
        }
        processed += 1;
    }

    return .{ .rowid = rowidDec.value, .values = rawValues };
}

/// Walks one table b-tree, appending owned leaf cells to `rowsOut`.
/// Depth-bounded and range-checked; bad pages fail with `InvalidHeader`.
fn readTableBtree(allocator: std.mem.Allocator, bytes: []const u8, pageNumber: u32, databasePageSize: usize, rowsOut: *std.ArrayList(Cell)) anyerror!void {
    return readTableBtreeDepth(allocator, bytes, pageNumber, databasePageSize, rowsOut, 0);
}

/// Depth-counting worker behind `readTableBtree` (see it for the contract).
fn readTableBtreeDepth(allocator: std.mem.Allocator, bytes: []const u8, pageNumber: u32, databasePageSize: usize, rowsOut: *std.ArrayList(Cell), depth: usize) anyerror!void {
    if (pageNumber == 0) return;
    if (depth > maxBtreeDepth) return error.InvalidHeader;
    const pageStart = std.math.mul(usize, @as(usize, pageNumber) - 1, databasePageSize) catch return error.InvalidHeader;
    if (pageStart + databasePageSize > bytes.len) return error.InvalidHeader;
    const hOffset: usize = if (pageNumber == 1) headerSize else 0;
    const header = pageStart + hOffset;
    if (header + 8 > pageStart + databasePageSize) return error.InvalidHeader;
    const pageType = bytes[header];

    if (pageType == 0x0d) {
        const cellCount = try getU16(bytes, header + 3);
        const arrayEnd = std.math.add(usize, header + 8, std.math.mul(usize, cellCount, 2) catch return error.InvalidHeader) catch return error.InvalidHeader;
        if (arrayEnd > pageStart + databasePageSize) return error.InvalidHeader;
        var i: usize = 0;
        while (i < cellCount) : (i += 1) {
            const pointer = try getU16(bytes, header + 8 + i * 2);
            const cellOffset = std.math.add(usize, pageStart, pointer) catch return error.InvalidHeader;
            if (cellOffset >= pageStart + databasePageSize) return error.InvalidHeader;
            const cellData = try readCell(allocator, bytes, cellOffset, databasePageSize);
            errdefer freeCellValues(allocator, cellData.values);
            try rowsOut.append(allocator, cellData);
        }
    } else if (pageType == 0x05) {
        const cellCount = try getU16(bytes, header + 3);
        const arrayEnd = std.math.add(usize, header + 12, std.math.mul(usize, cellCount, 2) catch return error.InvalidHeader) catch return error.InvalidHeader;
        if (arrayEnd > pageStart + databasePageSize) return error.InvalidHeader;
        if (header + 12 > pageStart + databasePageSize) return error.InvalidHeader;
        const rightChild = std.mem.readInt(u32, bytes[header + 8 .. header + 12][0..4], .big);
        const totalPages: u64 = @as(u64, @intCast(bytes.len / databasePageSize));
        if (rightChild == 0 or @as(u64, rightChild) > totalPages) return error.InvalidHeader;
        var i: usize = 0;
        while (i < cellCount) : (i += 1) {
            const pointer = try getU16(bytes, header + 12 + i * 2);
            const cellOffset = std.math.add(usize, pageStart, pointer) catch return error.InvalidHeader;
            if (cellOffset + 4 > bytes.len or cellOffset + 4 > pageStart + databasePageSize) return error.InvalidHeader;
            const leftChild = std.mem.readInt(u32, bytes[cellOffset .. cellOffset + 4][0..4], .big);
            if (leftChild == 0 or @as(u64, leftChild) > totalPages) return error.InvalidHeader;
            try readTableBtreeDepth(allocator, bytes, leftChild, databasePageSize, rowsOut, depth + 1);
        }
        try readTableBtreeDepth(allocator, bytes, rightChild, databasePageSize, rowsOut, depth + 1);
    } else {
        return error.InvalidHeader;
    }
}

/// Decodes a whole database image into an owned `Schema`.
/// Validates geometry first; bad catalog rows are skipped per-row.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Schema {
    if (bytes.len < headerSize or !std.mem.eql(u8, bytes[0..16], "SQLite format 3\x00")) return error.InvalidHeader;
    const encodedPageSize = std.mem.readInt(u16, bytes[16..18], .big);
    const databasePageSize: usize = if (encodedPageSize == 1) 65536 else encodedPageSize;
    if (databasePageSize < 512 or databasePageSize > 65536 or (databasePageSize & (databasePageSize - 1)) != 0 or bytes.len < databasePageSize) return error.InvalidPageSize;
    const databasePages = std.mem.readInt(u32, bytes[28..32], .big);
    if (databasePages == 0 or @as(u64, databasePages) * databasePageSize > bytes.len) return error.InvalidHeader;

    var schema = Schema.init(allocator);
    errdefer schema.deinit();
    schema.foreignKeysEnabled = false;

    var schemaRows = std.ArrayList(Cell).empty;
    defer {
        for (schemaRows.items) |row| {
            freeCellValues(allocator, row.values);
        }
        schemaRows.deinit(allocator);
    }

    try readTableBtree(allocator, bytes, 1, databasePageSize, &schemaRows);

    var entries = std.ArrayList(SchemaEntry).empty;
    defer entries.deinit(allocator);

    for (schemaRows.items) |row| {
        if (row.values.len < 5 or row.values[0] != .text) continue;
        if (row.values[3] != .integer or row.values[4] != .text) continue;
        // The root page rides in a signed record field: negative values are
        // corruption, not pages — skip the row instead of panicking in the
        // cast. Out-of-range pages fail later inside `readTableBtree`.
        if (row.values[3].integer < 0) continue;
        try entries.append(allocator, .{ .rootPage = @intCast(row.values[3].integer), .sql = row.values[4].text });
    }

    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .createVirtualTable) {
            try schema.createVirtualTable(statement.createVirtualTable.name, statement.createVirtualTable.module, statement.createVirtualTable.arguments);
            continue;
        }
        if (statement != .createTable) continue;
        try schema.createTableWithOptions(statement.createTable.name, statement.createTable.columns, statement.createTable.constraints, .{ .strict = statement.createTable.strict, .withoutRowid = statement.createTable.withoutRowid });
        const table = schema.find(statement.createTable.name).?;

        var tableRows = std.ArrayList(Cell).empty;
        defer {
            for (tableRows.items) |row| {
                freeCellValues(allocator, row.values);
            }
            tableRows.deinit(allocator);
        }

        try readTableBtree(allocator, bytes, entry.rootPage, databasePageSize, &tableRows);

        for (tableRows.items) |row| {
            try schema.appendRow(table, row.values);
        }
    }

    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .createIndex and schema.findIndexConst(statement.createIndex.name) == null) try schema.createIndex(statement.createIndex);
    }

    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .createView) try schema.createView(statement.createView.name, statement.createView.sql);
    }

    for (entries.items) |entry| {
        var parser = try Parser.init(allocator, entry.sql);
        defer parser.deinit();
        var statement = parser.parse() catch continue;
        defer ast.deinit(allocator, &statement);
        if (statement == .createTrigger) try schema.createTrigger(statement.createTrigger);
    }

    schema.foreignKeysEnabled = true;
    return schema;
}

test "SQLite image writes a compatible page-one b-tree" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const definitions = [_]ast.ColumnDef{ .{ .name = "id", .typeName = "INTEGER" }, .{ .name = "name", .typeName = "TEXT" } };
    try schema.createTable("users", &definitions, &.{});
    var values = [_]Value{ .{ .integer = 1 }, .{ .text = "Fiaz" } };
    try schema.appendRow(schema.find("users").?, &values);
    const bytes = try encode(std.testing.allocator, &schema);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(u8, 0x0d), bytes[100]);
    try std.testing.expectEqualStrings("SQLite format 3\x00", bytes[0..16]);
}

test "SQLite image round trips with an 8192-byte page size" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const definitions = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER" }};
    try schema.createTable("wide_pages", &definitions, &.{});
    var values = [_]Value{.{ .integer = 7 }};
    try schema.appendRow(schema.find("wide_pages").?, &values);
    const bytes = try encodeWithPageSize(std.testing.allocator, &schema, 8192);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 8192 * 2), bytes.len);
    try std.testing.expectEqual(@as(u16, 8192), std.mem.readInt(u16, bytes[16..18], .big));
    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.findConst("wide_pages").?.rows.items.len);
    try std.testing.expectEqual(@as(i64, 7), decoded.findConst("wide_pages").?.rows.items[0].values[0].integer);
}

test "SQLite image handles multi-page tables with interior nodes and overflow pages" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const definitions = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "data", .typeName = "TEXT" },
    };
    try schema.createTable("big_table", &definitions, &.{});
    const table = schema.find("big_table").?;

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        var row = [_]Value{
            .{ .integer = @intCast(i + 1) },
            .{ .text = "some long textual content stored to fill up b-tree pages and cause leaf splits into interior pages" },
        };
        try schema.appendRow(table, &row);
    }

    const bytes = try encodeWithPageSize(std.testing.allocator, &schema, 1024);
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(bytes.len > 1024 * 3);

    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit();

    const decodedTable = decoded.findConst("big_table").?;
    try std.testing.expectEqual(@as(usize, 300), decodedTable.rows.items.len);
    try std.testing.expectEqual(@as(i64, 1), decodedTable.rows.items[0].values[0].integer);
    try std.testing.expectEqual(@as(i64, 300), decodedTable.rows.items[299].values[0].integer);
}

test "SQLite image handles overflow pages for large records" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const definitions = [_]ast.ColumnDef{
        .{ .name = "id", .typeName = "INTEGER", .primaryKey = true },
        .{ .name = "large_payload", .typeName = "TEXT" },
    };
    try schema.createTable("overflow_table", &definitions, &.{});
    const table = schema.find("overflow_table").?;

    const largeString = try std.testing.allocator.alloc(u8, 5000);
    defer std.testing.allocator.free(largeString);
    @memset(largeString, 'A');

    var row = [_]Value{
        .{ .integer = 1 },
        .{ .text = largeString },
    };
    try schema.appendRow(table, &row);

    const bytes = try encodeWithPageSize(std.testing.allocator, &schema, 1024);
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(bytes.len >= 1024 * 6);

    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit();

    const decodedTable = decoded.findConst("overflow_table").?;
    try std.testing.expectEqual(@as(usize, 1), decodedTable.rows.items.len);
    try std.testing.expectEqual(@as(i64, 1), decodedTable.rows.items[0].values[0].integer);
    try std.testing.expectEqualStrings(largeString, decodedTable.rows.items[0].values[1].text);
}

test "SQLite image decode rejects corrupt inputs without panic or overread" {
    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    const definitions = [_]ast.ColumnDef{.{ .name = "id", .typeName = "INTEGER" }};
    try schema.createTable("t", &definitions, &.{});
    var values = [_]Value{.{ .integer = 42 }};
    try schema.appendRow(schema.find("t").?, &values);
    const bytes = try encode(std.testing.allocator, &schema);
    defer std.testing.allocator.free(bytes);
    // Error: empty, truncated, and bad-magic inputs fail closed.
    try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, &[_]u8{}));
    try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, bytes[0..50]));
    var badMagic = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(badMagic);
    badMagic[0] ^= 0xff;
    try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, badMagic));
    // Error: every truncation fails closed (sampled stride keeps it fast).
    // Prefixes shorter than one page report InvalidPageSize, longer corrupt
    // prefixes report InvalidHeader — both are controlled failures.
    var cut: usize = 101;
    while (cut < bytes.len) : (cut += 37) {
        var decoded = decode(std.testing.allocator, bytes[0..cut]) catch |err| {
            try std.testing.expect(err == error.InvalidHeader or err == error.InvalidPageSize);
            continue;
        };
        decoded.deinit();
        return error.TestUnexpectedError;
    }
    // Error: impossible page sizes fail closed, including non-powers of two.
    for ([_]u16{ 0, 100, 511, 513, 1000, 3000 }) |ps| {
        var badSize = try std.testing.allocator.dupe(u8, bytes);
        defer std.testing.allocator.free(badSize);
        std.mem.writeInt(u16, badSize[16..18], ps, .big);
        try std.testing.expectError(error.InvalidPageSize, decode(std.testing.allocator, badSize));
    }
    // Error: unknown page flags are rejected, not misread as tables.
    for ([_]u8{ 0x00, 0x09, 0xff }) |flag| {
        var badFlag = try std.testing.allocator.dupe(u8, bytes);
        defer std.testing.allocator.free(badFlag);
        badFlag[100] = flag;
        try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, badFlag));
    }
    // Error: a cyclic interior graph terminates via the depth bound instead
    // of recursing forever. A two-page image is built by hand: page 2 loops
    // to itself as its own right child.
    {
        const ps: usize = 512;
        var cyclic = Schema.init(std.testing.allocator);
        defer cyclic.deinit();
        try cyclic.createTable("loop", &definitions, &.{});
        const img = try encodeWithPageSize(std.testing.allocator, &cyclic, ps);
        defer std.testing.allocator.free(img);
        // Corrupt page 1's type byte to interior with right child = 1
        // (self-loop): decode must fail closed, not stack-overflow.
        var looped = try std.testing.allocator.dupe(u8, img);
        defer std.testing.allocator.free(looped);
        looped[100] = 0x05;
        // cell count 0, cell content start, fragmented, right child = 1.
        std.mem.writeInt(u16, looped[103..105], 0, .big);
        std.mem.writeInt(u32, looped[108..112], 1, .big);
        try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, looped));
    }
}
