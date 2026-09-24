//! JSON SQL functions.
//!
//! Inputs borrowed; text results are caller-owned.
//! Bad JSON or paths yield NULL.

const std = @import("std");
const Value = @import("../../vm/value.zig").Value;
const scalarFn = @import("scalar.zig");

const PathStep = union(enum) {
    key: []const u8,
    index: i64,
};

fn parsePath(allocator: std.mem.Allocator, pathStr: []const u8) ![]PathStep {
    var trimmed = std.mem.trim(u8, pathStr, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "$")) {
        trimmed = trimmed[1..];
    }
    var steps = std.ArrayList(PathStep).empty;
    errdefer steps.deinit(allocator);

    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '.') {
            i += 1;
            if (i >= trimmed.len) break;
            if (trimmed[i] == '"') {
                i += 1;
                const start = i;
                while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {}
                const key = trimmed[start..i];
                if (i < trimmed.len and trimmed[i] == '"') i += 1;
                try steps.append(allocator, .{ .key = key });
            } else {
                const start = i;
                while (i < trimmed.len and trimmed[i] != '.' and trimmed[i] != '[') : (i += 1) {}
                try steps.append(allocator, .{ .key = trimmed[start..i] });
            }
        } else if (trimmed[i] == '[') {
            i += 1;
            var isHash = false;
            if (i < trimmed.len and trimmed[i] == '#') {
                isHash = true;
                i += 1;
            }
            const start = i;
            while (i < trimmed.len and trimmed[i] != ']') : (i += 1) {}
            const numStr = trimmed[start..i];
            if (i < trimmed.len and trimmed[i] == ']') i += 1;
            var idx = std.fmt.parseInt(i64, numStr, 10) catch 0;
            if (isHash and idx <= 0) {
                idx = idx - 1;
            }
            try steps.append(allocator, .{ .index = idx });
        } else {
            const start = i;
            while (i < trimmed.len and trimmed[i] != '.' and trimmed[i] != '[') : (i += 1) {}
            try steps.append(allocator, .{ .key = trimmed[start..i] });
        }
    }
    return steps.toOwnedSlice(allocator);
}

fn jsonTypeString(val: std.json.Value) []const u8 {
    return switch (val) {
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer => "integer",
        .float => "real",
        .number_string => "real",
        .string => "text",
        .array => "array",
        .object => "object",
    };
}

fn jsonValueToSql(allocator: std.mem.Allocator, val: std.json.Value) !Value {
    return switch (val) {
        .null => .null,
        .bool => |b| .{ .integer = if (b) 1 else 0 },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .real = f },
        .number_string => |s| blk: {
            if (std.fmt.parseInt(i64, s, 10)) |i| break :blk .{ .integer = i } else |_| {}
            if (std.fmt.parseFloat(f64, s)) |f| break :blk .{ .real = f } else |_| {}
            break :blk .{ .text = try allocator.dupe(u8, s) };
        },
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .array, .object => .{ .text = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(val, .{})}) },
    };
}

fn sqlValueToJson(arena: std.mem.Allocator, val: Value) !std.json.Value {
    return switch (val) {
        .null => .null,
        .integer => |i| .{ .integer = i },
        .real => |r| .{ .float = r },
        .text => |t| blk: {
            const parsed = parseJsonDocument(arena, t) catch {
                break :blk .{ .string = t };
            };
            break :blk parsed.value;
        },
        .blob => .null,
    };
}

// Deep documents must fail closed, not stack-overflow: every parse below
// goes through `parseJsonDocument`, which rejects nesting past
// `max_json_depth` before the recursive parser, cloner, and formatter run.
// Sized for small stacks: each level costs several frames across parse,
// clone, and format, and 400-deep input already overflows a 1MB stack.
const max_json_depth: usize = 128;

/// Iterative bracket-depth scan: true when nesting stays within budget.
/// String-aware (escapes respected), saturating on unbalanced closers.
/// Invalid documents pass here and fail later in the real parser as NULL.
fn jsonDepthWithin(text: []const u8, maxDepth: usize) bool {
    var depth: usize = 0;
    var i: usize = 0;
    var inString = false;
    while (i < text.len) {
        const c = text[i];
        if (inString) {
            if (c == '\\') i += 1;
            if (c == '"') inString = false;
        } else if (c == '"') {
            inString = true;
        } else if (c == '[' or c == '{') {
            depth += 1;
            if (depth > maxDepth) return false;
        } else if (c == ']' or c == '}') {
            depth -|= 1;
        }
        i += 1;
    }
    return true;
}

/// Parse one JSON document with the depth gate applied. Too-deep input
/// fails `TooDeep` (callers map it to NULL like any other bad document).
fn parseJsonDocument(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    if (!jsonDepthWithin(text, max_json_depth)) return error.TooDeep;
    return try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

fn cloneJson(arena: std.mem.Allocator, val: std.json.Value) !std.json.Value {
    return switch (val) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |ns| .{ .number_string = try arena.dupe(u8, ns) },
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .array => |arr| {
            var newArr = std.json.Array.init(arena);
            for (arr.items) |item| {
                try newArr.append(try cloneJson(arena, item));
            }
            return .{ .array = newArr };
        },
        .object => |obj| {
            var newObj: std.json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const k = try arena.dupe(u8, entry.key_ptr.*);
                const v = try cloneJson(arena, entry.value_ptr.*);
                try newObj.put(arena, k, v);
            }
            return .{ .object = newObj };
        },
    };
}

fn getPath(root: std.json.Value, steps: []const PathStep) ?std.json.Value {
    var cur = root;
    for (steps) |step| {
        switch (step) {
            .key => |k| {
                if (cur != .object) return null;
                cur = cur.object.get(k) orelse return null;
            },
            .index => |idx| {
                if (cur != .array) return null;
                const items = cur.array.items;
                const actualIdx: usize = if (idx >= 0)
                    @as(usize, @intCast(idx))
                else blk: {
                    const fromEnd = @as(usize, @intCast(-idx));
                    if (fromEnd > items.len) return null;
                    break :blk items.len - fromEnd;
                };
                if (actualIdx >= items.len) return null;
                cur = items[actualIdx];
            },
        }
    }
    return cur;
}

/// `json_set`/`json_insert`/`json_replace` write modes.
pub const ModifyMode = enum { set, insert, replace };

fn setPath(arena: std.mem.Allocator, root: *std.json.Value, steps: []const PathStep, newVal: std.json.Value, mode: ModifyMode) !void {
    if (steps.len == 0) {
        if (mode != .insert) root.* = newVal;
        return;
    }
    var cur = root;
    for (steps[0 .. steps.len - 1]) |step| {
        switch (step) {
            .key => |k| {
                if (cur.* != .object) return;
                var obj = &cur.object;
                if (!obj.contains(k)) {
                    if (mode == .replace) return;
                    try obj.put(arena, try arena.dupe(u8, k), .{ .object = .empty });
                }
                cur = obj.getPtr(k) orelse return;
            },
            .index => |idx| {
                if (cur.* != .array) return;
                const items = cur.array.items;
                const actualIdx: usize = if (idx >= 0)
                    @as(usize, @intCast(idx))
                else blk: {
                    const fromEnd = @as(usize, @intCast(-idx));
                    if (fromEnd > items.len) return;
                    break :blk items.len - fromEnd;
                };
                if (actualIdx >= items.len) return;
                cur = &cur.array.items[actualIdx];
            },
        }
    }
    const lastStep = steps[steps.len - 1];
    switch (lastStep) {
        .key => |k| {
            if (cur.* != .object) return;
            const exists = cur.object.contains(k);
            if (exists and mode == .insert) return;
            if (!exists and mode == .replace) return;
            try cur.object.put(arena, try arena.dupe(u8, k), newVal);
        },
        .index => |idx| {
            if (cur.* != .array) return;
            const items = cur.array.items;
            if (idx < 0) return;
            const uIdx: usize = @intCast(idx);
            if (uIdx < items.len) {
                if (mode == .insert) return;
                cur.array.items[uIdx] = newVal;
            } else if (uIdx == items.len) {
                if (mode == .replace) return;
                try cur.array.append(newVal);
            }
        },
    }
}

fn removePath(root: *std.json.Value, steps: []const PathStep) void {
    if (steps.len == 0) return;
    var cur = root;
    for (steps[0 .. steps.len - 1]) |step| {
        switch (step) {
            .key => |k| {
                if (cur.* != .object) return;
                cur = cur.object.getPtr(k) orelse return;
            },
            .index => |idx| {
                if (cur.* != .array) return;
                const items = cur.array.items;
                const actualIdx: usize = if (idx >= 0)
                    @as(usize, @intCast(idx))
                else blk: {
                    const fromEnd = @as(usize, @intCast(-idx));
                    if (fromEnd > items.len) return;
                    break :blk items.len - fromEnd;
                };
                if (actualIdx >= items.len) return;
                cur = &cur.array.items[actualIdx];
            },
        }
    }
    const lastStep = steps[steps.len - 1];
    switch (lastStep) {
        .key => |k| {
            if (cur.* != .object) return;
            _ = cur.object.orderedRemove(k);
        },
        .index => |idx| {
            if (cur.* != .array) return;
            const items = cur.array.items;
            const actualIdx: usize = if (idx >= 0)
                @as(usize, @intCast(idx))
            else blk: {
                const fromEnd = @as(usize, @intCast(-idx));
                if (fromEnd > items.len) return;
                break :blk items.len - fromEnd;
            };
            if (actualIdx < items.len) {
                _ = cur.array.orderedRemove(actualIdx);
            }
        },
    }
}

/// `json(X)`: canonical minified JSON text, or NULL for non-text/NULL/bad JSON.
/// Large documents allocate proportionally and fail closed on OOM; depth is
/// capped by `parseJsonDocument`, size is not (big JSON is legitimate input).
pub fn evalJson(allocator: std.mem.Allocator, arg: Value) !Value {
    if (arg == .null or arg != .text) return .null;
    const parsed = parseJsonDocument(allocator, arg.text) catch return .null;
    defer parsed.deinit();
    const str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(parsed.value, .{})});
    return .{ .text = str };
}

/// `json_valid(X)`: 1 when X is well-formed JSON text, else 0 (never NULL).
pub fn evalJsonValid(allocator: std.mem.Allocator, arg: Value) Value {
    if (arg == .null or arg != .text) return .{ .integer = 0 };
    const parsed = parseJsonDocument(allocator, arg.text) catch return .{ .integer = 0 };
    parsed.deinit();
    return .{ .integer = 1 };
}

/// `json_type(X[,path])`: `null|true|false|integer|real|text|array|object` or NULL.
pub fn evalJsonType(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len == 0 or args[0] == .null or args[0] != .text) return .null;
    const parsed = parseJsonDocument(allocator, args[0].text) catch return .null;
    defer parsed.deinit();
    if (args.len >= 2 and args[1] != .null and args[1] == .text) {
        const steps = try parsePath(allocator, args[1].text);
        defer allocator.free(steps);
        const node = getPath(parsed.value, steps) orelse return .null;
        return .{ .text = try allocator.dupe(u8, jsonTypeString(node)) };
    }
    return .{ .text = try allocator.dupe(u8, jsonTypeString(parsed.value)) };
}

/// `json_extract(X,paths...)`: scalar SQL value for one path, JSON array text for N paths.
/// Missing paths yield NULL (single) or JSON null elements (multi).
pub fn evalJsonExtract(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len < 2 or args[0] == .null or args[0] != .text) return .null;
    const parsed = parseJsonDocument(allocator, args[0].text) catch return .null;
    defer parsed.deinit();

    if (args.len == 2) {
        if (args[1] == .null or args[1] != .text) return .null;
        const steps = try parsePath(allocator, args[1].text);
        defer allocator.free(steps);
        const node = getPath(parsed.value, steps) orelse return .null;
        return try jsonValueToSql(allocator, node);
    }

    var resultList = std.json.Array.init(allocator);
    defer resultList.deinit();
    for (args[1..]) |pathVal| {
        if (pathVal == .null or pathVal != .text) {
            try resultList.append(.null);
            continue;
        }
        const steps = try parsePath(allocator, pathVal.text);
        defer allocator.free(steps);
        if (getPath(parsed.value, steps)) |node| {
            try resultList.append(try cloneJson(allocator, node));
        } else {
            try resultList.append(.null);
        }
    }
    const resStr = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(std.json.Value{ .array = resultList }, .{})});
    return .{ .text = resStr };
}

/// `json -> key` / `json ->> key` (and integer indexes): SQL-value extract
/// for `->`, always-text extract for `->>`. NULL input/path → NULL.
pub fn evalJsonArrowOperator(allocator: std.mem.Allocator, jsonVal: Value, pathVal: Value, asText: bool) !Value {
    if (jsonVal == .null or pathVal == .null) return .null;
    if (jsonVal != .text) return .null;
    const pathText: []const u8 = switch (pathVal) {
        .text => |t| t,
        .integer => |i| blk: {
            const buf = try std.fmt.allocPrint(allocator, "[{d}]", .{i});
            defer allocator.free(buf);
            break :blk try allocator.dupe(u8, buf);
        },
        .real => |r| blk: {
            if (r != std.math.trunc(r)) return .null;
            const buf = try std.fmt.allocPrint(allocator, "[{d}]", .{@as(i64, @intFromFloat(r))});
            defer allocator.free(buf);
            break :blk try allocator.dupe(u8, buf);
        },
        else => return .null,
    };
    defer if (pathVal != .text) allocator.free(pathText);
    // Build a json_extract-style path: `.name` or `[n]`.
    var pathBuf = std.ArrayList(u8).empty;
    defer pathBuf.deinit(allocator);
    if (std.mem.startsWith(u8, pathText, "$")) {
        try pathBuf.appendSlice(allocator, pathText);
    } else if (std.mem.startsWith(u8, pathText, "[") or std.mem.indexOfScalar(u8, pathText, '.') != null) {
        try pathBuf.appendSlice(allocator, "$");
        try pathBuf.appendSlice(allocator, pathText);
    } else {
        try pathBuf.appendSlice(allocator, "$.");
        try pathBuf.appendSlice(allocator, pathText);
    }
    const args = [_]Value{ jsonVal, .{ .text = pathBuf.items } };
    const extracted = try evalJsonExtract(allocator, &args);
    if (asText) {
        if (extracted == .null) return .null;
        // Unwrap text to plain SQL text; stringify non-text via json_quote.
        if (extracted == .text) return extracted;
        const quoted = try scalarFn.evalJsonQuote(allocator, extracted);
        freeValueShallow(allocator, extracted);
        return quoted;
    }
    return extracted;
}

fn freeValueShallow(allocator: std.mem.Allocator, v: Value) void {
    switch (v) {
        .text => |t| allocator.free(t),
        .blob => |b| allocator.free(b),
        else => {},
    }
}

/// `json_array_length(X[,P])`: element count of the array at path P (or
/// the root); non-array JSON yields 0, bad JSON/NULL/missing paths yield NULL.
pub fn evalJsonArrayLength(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len == 0 or args.len > 2 or args[0] == .null or args[0] != .text) return .null;
    const parsed = parseJsonDocument(allocator, args[0].text) catch return .null;
    defer parsed.deinit();
    var node = parsed.value;
    if (args.len == 2) {
        if (args[1] == .null or args[1] != .text) return .null;
        const steps = try parsePath(allocator, args[1].text);
        defer allocator.free(steps);
        node = getPath(parsed.value, steps) orelse return .null;
    }
    return switch (node) {
        .array => |arr| .{ .integer = @intCast(arr.items.len) },
        else => .{ .integer = 0 },
    };
}

/// `json_array(v...)`: JSON array text; SQL values convert (text tries JSON parse first).
pub fn evalJsonArray(allocator: std.mem.Allocator, args: []const Value) !Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    var arr = std.json.Array.init(arenaAlloc);
    for (args) |a| {
        try arr.append(try sqlValueToJson(arenaAlloc, a));
    }
    const resStr = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(std.json.Value{ .array = arr }, .{})});
    return .{ .text = resStr };
}

/// `json_object(k,v...)`: JSON object text; odd arity errors, non-text keys error.
pub fn evalJsonObject(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len % 2 != 0) return error.InvalidArgumentCount;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    var obj: std.json.ObjectMap = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const kVal = args[i];
        if (kVal != .text) return error.InvalidArgument;
        const vVal = args[i + 1];
        try obj.put(arenaAlloc, try arenaAlloc.dupe(u8, kVal.text), try sqlValueToJson(arenaAlloc, vVal));
    }
    const resStr = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(std.json.Value{ .object = obj }, .{})});
    return .{ .text = resStr };
}

/// `json_set/insert/replace(X,path,val...)`: modified JSON text; bad pairs skipped.
/// NULL/non-text base or bad JSON yields NULL.
pub fn evalJsonModify(allocator: std.mem.Allocator, args: []const Value, mode: ModifyMode) !Value {
    if (args.len < 3 or args[0] == .null or args[0] != .text) return .null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    const parsed = parseJsonDocument(arenaAlloc, args[0].text) catch return .null;
    var root = try cloneJson(arenaAlloc, parsed.value);

    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const pathVal = args[i];
        if (pathVal != .text) continue;
        const valVal = args[i + 1];
        const steps = try parsePath(arenaAlloc, pathVal.text);
        const jVal = try sqlValueToJson(arenaAlloc, valVal);
        try setPath(arenaAlloc, &root, steps, jVal, mode);
    }
    const resStr = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(root, .{})});
    return .{ .text = resStr };
}

/// Renders a JSON function input to text like value_text (numbers render,
/// blobs contribute bytes); NULL stays NULL for the caller to reject.
/// Older entry points in this module keep strict text-only inputs; new
/// ones coerce like the reference.
fn jsonArgText(allocator: std.mem.Allocator, val: Value) !?[]u8 {
    return switch (val) {
        .null => null,
        .text => |t| try allocator.dupe(u8, t),
        .blob => |b| try allocator.dupe(u8, b),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .real => |r| try std.fmt.allocPrint(allocator, "{d}", .{r}),
    };
}

/// RFC 7396 merge step: non-object patches replace wholesale; object
/// patches merge key by key (null deletes, missing keys start empty).
/// Everything lives in `arena`; depth-guarded like the reference.
fn mergePatch(arena: std.mem.Allocator, target: ?std.json.Value, patch: std.json.Value, depth: usize) !std.json.Value {
    if (depth > max_json_depth) return error.TooDeep;
    if (patch != .object) return try cloneJson(arena, patch);
    var obj: std.json.ObjectMap = if (target) |t| (if (t == .object) t.object else .empty) else .empty;
    var it = patch.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) {
            _ = obj.swapRemove(entry.key_ptr.*);
        } else {
            const current = obj.get(entry.key_ptr.*);
            const merged = try mergePatch(arena, current, entry.value_ptr.*, depth + 1);
            try obj.put(arena, try arena.dupe(u8, entry.key_ptr.*), merged);
        }
    }
    return .{ .object = obj };
}

/// `json_patch(TARGET,PATCH)`: RFC 7396 merge-patch text. Bad JSON or
/// non-text input yields NULL; depth overflow fails `TooDeep`.
pub fn evalJsonPatch(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len != 2) return error.InvalidArgumentCount;
    const targetText = try jsonArgText(allocator, args[0]) orelse return .null;
    defer allocator.free(targetText);
    const patchText = try jsonArgText(allocator, args[1]) orelse return .null;
    defer allocator.free(patchText);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();
    const parsedTarget = parseJsonDocument(arenaAlloc, targetText) catch return .null;
    const parsedPatch = parseJsonDocument(arenaAlloc, patchText) catch return .null;
    const merged = try mergePatch(arenaAlloc, parsedTarget.value, parsedPatch.value, 0);
    const resStr = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(merged, .{})});
    return .{ .text = resStr };
}

/// Emits one value in pretty form: containers break lines with per-level
/// indentation, scalars render compactly. Mirrors the reference layout
/// (`": "` after keys, `[]`/`{}` when empty).
fn renderPretty(allocator: std.mem.Allocator, out: *std.ArrayList(u8), val: std.json.Value, indent: []const u8, level: usize) !void {
    switch (val) {
        .array => |arr| {
            if (arr.items.len == 0) {
                try out.appendSlice(allocator, "[]");
                return;
            }
            try out.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.appendSlice(allocator, ",");
                try out.append(allocator, '\n');
                var l: usize = 0;
                while (l <= level) : (l += 1) try out.appendSlice(allocator, indent);
                try renderPretty(allocator, out, item, indent, level + 1);
            }
            try out.append(allocator, '\n');
            var l: usize = 0;
            while (l < level) : (l += 1) try out.appendSlice(allocator, indent);
            try out.append(allocator, ']');
        },
        .object => |obj| {
            if (obj.count() == 0) {
                try out.appendSlice(allocator, "{}");
                return;
            }
            try out.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.appendSlice(allocator, ",");
                first = false;
                try out.append(allocator, '\n');
                var l: usize = 0;
                while (l <= level) : (l += 1) try out.appendSlice(allocator, indent);
                const keyStr = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(std.json.Value{ .string = entry.key_ptr.* }, .{})});
                defer allocator.free(keyStr);
                try out.appendSlice(allocator, keyStr);
                try out.appendSlice(allocator, ": ");
                try renderPretty(allocator, out, entry.value_ptr.*, indent, level + 1);
            }
            try out.append(allocator, '\n');
            var l: usize = 0;
            while (l < level) : (l += 1) try out.appendSlice(allocator, indent);
            try out.append(allocator, '}');
        },
        else => {
            const leaf = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(val, .{})});
            defer allocator.free(leaf);
            try out.appendSlice(allocator, leaf);
        },
    }
}

/// `json_pretty(X[,indent])`: human-readable JSON text (4-space default;
/// NULL indent selects the default, like the reference). Bad JSON or
/// non-text input yields NULL.
pub fn evalJsonPretty(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len == 0 or args.len > 2) return error.InvalidArgumentCount;
    const docText = try jsonArgText(allocator, args[0]) orelse return .null;
    defer allocator.free(docText);
    // NULL indent selects the default; numbers render like value_text.
    var ownedIndent: ?[]u8 = null;
    defer if (ownedIndent) |bytes| allocator.free(bytes);
    const indentSlice: []const u8 = if (args.len < 2 or args[1] == .null) "    " else switch (args[1]) {
        .text => |t| t,
        .blob => |b| b,
        .integer => |i| blk: {
            ownedIndent = try std.fmt.allocPrint(allocator, "{d}", .{i});
            break :blk ownedIndent.?;
        },
        .real => |r| blk: {
            ownedIndent = try std.fmt.allocPrint(allocator, "{d}", .{r});
            break :blk ownedIndent.?;
        },
        else => return .null,
    };
    const parsed = parseJsonDocument(allocator, docText) catch return .null;
    defer parsed.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try renderPretty(allocator, &out, parsed.value, indentSlice, 0);
    return .{ .text = try out.toOwnedSlice(allocator) };
}

/// `json_remove(X,paths...)`: JSON text with pointed values deleted.
/// NULL/non-text base or bad JSON yields NULL; bad paths skipped.
pub fn evalJsonRemove(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len < 2 or args[0] == .null or args[0] != .text) return .null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    const parsed = parseJsonDocument(arenaAlloc, args[0].text) catch return .null;
    var root = try cloneJson(arenaAlloc, parsed.value);

    for (args[1..]) |pathVal| {
        if (pathVal != .text) continue;
        const steps = try parsePath(arenaAlloc, pathVal.text);
        removePath(&root, steps);
    }
    const resStr = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(root, .{})});
    return .{ .text = resStr };
}

test "json normal behavior" {
    const alloc = std.testing.allocator;
    const ok = try evalJson(alloc, .{ .text = "{\"a\":1}" });
    defer ok.free(alloc);
    try std.testing.expect(ok == .text);
    try std.testing.expectEqual(@as(i64, 1), evalJsonValid(alloc, .{ .text = "[1,2]" }).integer);
    try std.testing.expectEqual(@as(i64, 0), evalJsonValid(alloc, .{ .text = "{bad" }).integer);
    const ty = try evalJsonType(alloc, &.{ .{ .text = "{\"a\":[1,2]}" }, .{ .text = "$.a" } });
    defer ty.free(alloc);
    try std.testing.expectEqualStrings("array", ty.text);
    const ex = try evalJsonExtract(alloc, &.{ .{ .text = "{\"a\":{\"b\":42}}" }, .{ .text = "$.a.b" } });
    defer ex.free(alloc);
    try std.testing.expectEqual(@as(i64, 42), ex.integer);
    const arr = try evalJsonArray(alloc, &.{ .{ .integer = 1 }, .{ .text = "x" } });
    defer arr.free(alloc);
    try std.testing.expectEqualStrings("[1,\"x\"]", arr.text);
    const obj = try evalJsonObject(alloc, &.{ .{ .text = "k" }, .{ .integer = 1 } });
    defer obj.free(alloc);
    try std.testing.expectEqualStrings("{\"k\":1}", obj.text);
}

test "json null empty and boundary" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try evalJson(alloc, .null)) == .null);
    try std.testing.expect((try evalJson(alloc, .{ .integer = 1 })) == .null);
    try std.testing.expect((try evalJson(alloc, .{ .text = "" })) == .null);
    try std.testing.expect((try evalJsonExtract(alloc, &.{ .{ .text = "{\"a\":1}" }, .{ .text = "$.missing" } })) == .null);
    // Negative index counts from end.
    const last = try evalJsonExtract(alloc, &.{ .{ .text = "[1,2,3]" }, .{ .text = "$[-1]" } });
    defer last.free(alloc);
    try std.testing.expectEqual(@as(i64, 3), last.integer);
    const empty_arr = try evalJsonArray(alloc, &.{});
    defer empty_arr.free(alloc);
    try std.testing.expectEqualStrings("[]", empty_arr.text);
    // set/insert/replace modes differ on existing keys.
    const base = Value{ .text = "{\"a\":1}" };
    const set = try evalJsonModify(alloc, &.{ base, .{ .text = "$.a" }, .{ .integer = 2 } }, .set);
    defer set.free(alloc);
    try std.testing.expectEqualStrings("{\"a\":2}", set.text);
    const ins = try evalJsonModify(alloc, &.{ base, .{ .text = "$.a" }, .{ .integer = 2 } }, .insert);
    defer ins.free(alloc);
    try std.testing.expectEqualStrings("{\"a\":1}", ins.text);
    const rem = try evalJsonRemove(alloc, &.{ base, .{ .text = "$.a" } });
    defer rem.free(alloc);
    try std.testing.expectEqualStrings("{}", rem.text);
}

test "json array length counts arrays and paths" {
    const alloc = std.testing.allocator;
    const root = try evalJsonArrayLength(alloc, &.{.{ .text = "[1,[2],{\"a\":3}]" }});
    defer root.free(alloc);
    try std.testing.expectEqual(@as(i64, 3), root.integer);
    const empty = try evalJsonArrayLength(alloc, &.{.{ .text = "[]" }});
    defer empty.free(alloc);
    try std.testing.expectEqual(@as(i64, 0), empty.integer);
    const scalar = try evalJsonArrayLength(alloc, &.{.{ .text = "42" }});
    defer scalar.free(alloc);
    try std.testing.expectEqual(@as(i64, 0), scalar.integer);
    const nested = try evalJsonArrayLength(alloc, &.{ .{ .text = "{\"a\":{\"b\":[1]}}" }, .{ .text = "$.a.b" } });
    defer nested.free(alloc);
    try std.testing.expectEqual(@as(i64, 1), nested.integer);
    try std.testing.expect((try evalJsonArrayLength(alloc, &.{ .{ .text = "{\"a\":1}" }, .{ .text = "$.missing" } })) == .null);
    try std.testing.expect((try evalJsonArrayLength(alloc, &.{.null})) == .null);
    try std.testing.expect((try evalJsonArrayLength(alloc, &.{})) == .null);
}

test "json pretty renders indented blocks" {
    const alloc = std.testing.allocator;
    const pretty = try evalJsonPretty(alloc, &.{.{ .text = "{\"b\":[1,2],\"a\":{}}" }});
    defer pretty.free(alloc);
    try std.testing.expectEqualStrings("{\n    \"b\": [\n        1,\n        2\n    ],\n    \"a\": {}\n}", pretty.text);
    const custom = try evalJsonPretty(alloc, &.{ .{ .text = "[1]" }, .{ .text = "  " } });
    defer custom.free(alloc);
    try std.testing.expectEqualStrings("[\n  1\n]", custom.text);
    const scalar = try evalJsonPretty(alloc, &.{.{ .text = "42" }});
    defer scalar.free(alloc);
    try std.testing.expectEqualStrings("42", scalar.text);
    try std.testing.expect((try evalJsonPretty(alloc, &.{.{ .text = "{bad" }})) == .null);
    try std.testing.expectError(error.InvalidArgumentCount, evalJsonPretty(alloc, &.{}));
}

test "json patch merges per RFC 7396" {
    const alloc = std.testing.allocator;
    const merged = try evalJsonPatch(alloc, &.{ .{ .text = "{\"a\":1,\"b\":2}" }, .{ .text = "{\"b\":null,\"c\":3}" } });
    defer merged.free(alloc);
    try std.testing.expectEqualStrings("{\"a\":1,\"c\":3}", merged.text);
    const nested = try evalJsonPatch(alloc, &.{ .{ .text = "{\"a\":{\"x\":1,\"y\":2}}" }, .{ .text = "{\"a\":{\"y\":null,\"z\":9}}" } });
    defer nested.free(alloc);
    try std.testing.expectEqualStrings("{\"a\":{\"x\":1,\"z\":9}}", nested.text);
    const replace = try evalJsonPatch(alloc, &.{ .{ .text = "{\"a\":1}" }, .{ .text = "[1,2]" } });
    defer replace.free(alloc);
    try std.testing.expectEqualStrings("[1,2]", replace.text);
    const fresh = try evalJsonPatch(alloc, &.{ .{ .integer = 1 }, .{ .text = "{\"a\":1}" } });
    defer fresh.free(alloc);
    try std.testing.expectEqualStrings("{\"a\":1}", fresh.text);
    try std.testing.expect((try evalJsonPatch(alloc, &.{ .{ .text = "{bad" }, .{ .text = "{}" } })) == .null);
    try std.testing.expectError(error.InvalidArgumentCount, evalJsonPatch(alloc, &.{.{ .text = "{}" }}));
}

test "json error behavior" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgumentCount, evalJsonObject(alloc, &.{.{ .text = "k" }}));
    try std.testing.expectError(error.InvalidArgument, evalJsonObject(alloc, &.{ .{ .integer = 1 }, .{ .integer = 2 } }));
    try std.testing.expect((try evalJsonModify(alloc, &.{ .{ .text = "{bad" }, .{ .text = "$.a" }, .{ .integer = 1 } }, .set)) == .null);
    try std.testing.expect((try evalJsonRemove(alloc, &.{.null})) == .null);
}

test "json rejects hostile nesting depth without crashing" {
    const alloc = std.testing.allocator;
    // 600-deep arrays: far past the gate, tiny in bytes.
    var deep = std.ArrayList(u8).empty;
    defer deep.deinit(alloc);
    for (0..600) |_| try deep.appendSlice(alloc, "[");
    for (0..600) |_| try deep.appendSlice(alloc, "]");
    const deepText = try deep.toOwnedSlice(alloc);
    defer alloc.free(deepText);
    try std.testing.expect((try evalJson(alloc, .{ .text = deepText })) == .null);
    try std.testing.expectEqual(@as(i64, 0), evalJsonValid(alloc, .{ .text = deepText }).integer);
    try std.testing.expect((try evalJsonExtract(alloc, &.{ .{ .text = deepText }, .{ .text = "$[0]" } })) == .null);
    try std.testing.expect((try evalJsonModify(alloc, &.{ .{ .text = deepText }, .{ .text = "$[0]" }, .{ .integer = 1 } }, .set)) == .null);
    // Brackets inside strings do not count toward depth.
    const tricky = try evalJson(alloc, .{ .text = "{\"a\":\"[[[[\"}" });
    defer tricky.free(alloc);
    try std.testing.expectEqualStrings("{\"a\":\"[[[[\"}", tricky.text);
    // Boundary depth still parses.
    var edge = std.ArrayList(u8).empty;
    defer edge.deinit(alloc);
    for (0..max_json_depth) |_| try edge.appendSlice(alloc, "[");
    try edge.appendSlice(alloc, "0");
    for (0..max_json_depth) |_| try edge.appendSlice(alloc, "]");
    const edgeText = try edge.toOwnedSlice(alloc);
    defer alloc.free(edgeText);
    const edgeOk = try evalJson(alloc, .{ .text = edgeText });
    defer edgeOk.free(alloc);
    try std.testing.expect(edgeOk == .text);
}
