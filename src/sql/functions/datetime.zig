//! Date and time SQL functions.
//!
//! Inputs borrowed; text results are caller-owned.
//! Unparseable input yields NULL.

const std = @import("std");
const Value = @import("../../vm/value.zig").Value;

// System libc wall clock for targets where the toolchain exposes no
// pure-Zig syscall layer (Apple and BSD families). Linking the reference was
// verified for these targets with no extra link flags. The declaration is
// only referenced from the branches below; other targets never emit a
// reference to it.
const CTimeval = extern struct {
    tv_sec: c_long,
    tv_usec: c_int,
};

extern "c" fn gettimeofday(tp: *CTimeval, tzp: ?*anyopaque) c_int;

/// Broken-down calendar timestamp; `valid` is always true for produced values.
pub const DateTime = struct {
    /// Proleptic year (may be <= 0 for ancient Julian days; formatted clamped).
    year: i32,
    /// Month 1-12 for well-formed input.
    month: i32,
    /// Day of month 1-31.
    day: i32,
    /// Hour 0-23.
    hour: i32,
    /// Minute 0-59.
    minute: i32,
    /// Second 0-59.
    second: i32,
    /// Fractional second in [0,1).
    fraction: f64 = 0.0,
    /// Always true; reserved for future validation failures.
    valid: bool = true,

    /// Convert to Julian day number (fractional).
    pub fn toJulianDay(self: DateTime) f64 {
        var y = self.year;
        var m = self.month;
        if (m <= 2) {
            y -= 1;
            m += 12;
        }
        const a = @divTrunc(y, 100);
        const b = 2 - a + @divTrunc(a, 4);
        const jdInt = @as(f64, @floatFromInt(@as(i64, @intFromFloat(365.25 * @as(f64, @floatFromInt(y + 4716)))))) +
            @as(f64, @floatFromInt(@as(i64, @intFromFloat(30.6001 * @as(f64, @floatFromInt(m + 1)))))) +
            @as(f64, @floatFromInt(self.day)) + @as(f64, @floatFromInt(b)) - 1524.5;
        const timeFrac = (@as(f64, @floatFromInt(self.hour)) * 3600.0 +
            @as(f64, @floatFromInt(self.minute)) * 60.0 +
            @as(f64, @floatFromInt(self.second)) + self.fraction) / 86400.0;
        return jdInt + timeFrac;
    }

    /// Inverse of `toJulianDay`; clamps negative day fractions to zero.
    pub fn fromJulianDay(jd: f64) DateTime {
        const z = @as(i64, @intFromFloat(jd + 0.5));
        const f = (jd + 0.5) - @as(f64, @floatFromInt(z));
        var a = z;
        if (z >= 2299161) {
            const alpha = @as(i64, @intFromFloat((@as(f64, @floatFromInt(z)) - 1867216.25) / 36524.25));
            a = z + 1 + alpha - @divTrunc(alpha, 4);
        }
        const bRev = a + 1524;
        const c = @as(i64, @intFromFloat((@as(f64, @floatFromInt(bRev)) - 122.1) / 365.25));
        const d = @as(i64, @intFromFloat(365.25 * @as(f64, @floatFromInt(c))));
        const e = @as(i64, @intFromFloat(@as(f64, @floatFromInt(bRev - d)) / 30.6001));
        const dayCalc: i32 = @intCast(bRev - d - @as(i64, @intFromFloat(30.6001 * @as(f64, @floatFromInt(e)))));
        const monthCalc: i32 = if (e < 14) @intCast(e - 1) else @intCast(e - 13);
        const yearCalc: i32 = if (monthCalc > 2) @intCast(c - 4716) else @intCast(c - 4715);
        var dayFrac = f * 86400.0;
        if (dayFrac < 0.0) dayFrac = 0.0;
        const secTotal = @as(i64, @intFromFloat(dayFrac));
        const hourCalc: i32 = @intCast(@mod(@divTrunc(secTotal, 3600), 24));
        const minCalc: i32 = @intCast(@divTrunc(@mod(secTotal, 3600), 60));
        const secCalc: i32 = @intCast(@mod(secTotal, 60));
        const fracCalc = dayFrac - @as(f64, @floatFromInt(secTotal));
        return .{
            .year = yearCalc,
            .month = monthCalc,
            .day = dayCalc,
            .hour = hourCalc,
            .minute = minCalc,
            .second = secCalc,
            .fraction = fracCalc,
            .valid = true,
        };
    }

    /// Seconds since 1970-01-01 UTC, truncated toward zero.
    pub fn toUnixEpoch(self: DateTime) i64 {
        const jd = self.toJulianDay();
        // Julian-day math is floating point; round to the nearest second so
        // exact timestamps (e.g. 1970-01-01 00:00:01 -> 1) do not truncate
        // to one less on rounding error.
        return @as(i64, @intFromFloat(@round((jd - 2440587.5) * 86400.0)));
    }

    /// Inverse of `toUnixEpoch` via Julian-day arithmetic.
    pub fn fromUnixEpoch(sec: i64) DateTime {
        const jd = (@as(f64, @floatFromInt(sec)) / 86400.0) + 2440587.5;
        return fromJulianDay(jd);
    }
};

fn parseTimeOnly(str: []const u8) ?DateTime {
    var hour: i32 = 0;
    var min: i32 = 0;
    var sec: i32 = 0;
    var frac: f64 = 0.0;
    if (str.len < 5 or str[2] != ':') return null;
    hour = std.fmt.parseInt(i32, str[0..2], 10) catch return null;
    min = std.fmt.parseInt(i32, str[3..5], 10) catch return null;
    var rest: []const u8 = "";
    if (str.len >= 8 and str[5] == ':') {
        sec = std.fmt.parseInt(i32, str[6..8], 10) catch return null;
        if (str.len > 8 and str[8] == '.') {
            var j: usize = 9;
            var num: f64 = 0.0;
            var den: f64 = 1.0;
            while (j < str.len and str[j] >= '0' and str[j] <= '9') : (j += 1) {
                num = num * 10.0 + @as(f64, @floatFromInt(str[j] - '0'));
                den *= 10.0;
            }
            if (j > 9) {
                frac = num / den;
                rest = str[j..];
            } else {
                rest = str[8..];
            }
        } else if (str.len > 8) {
            rest = str[8..];
        }
    }
    var dt = DateTime{
        .year = 2000,
        .month = 1,
        .day = 1,
        .hour = hour,
        .minute = min,
        .second = sec,
        .fraction = frac,
        .valid = true,
    };
    shiftByZoneOffset(&dt, zoneOffsetMinutes(rest));
    return dt;
}

/// Minutes east of UTC from a trailing `Z`/`z` (zero) or `±HH[:MM]` suffix.
/// Anything else (including absent) is zero; unrecognized text is ignored
/// rather than failing, preserving the long-standing lenient parse.
fn zoneOffsetMinutes(rest: []const u8) i32 {
    if (rest.len == 0) return 0;
    if (rest[0] == 'Z' or rest[0] == 'z') return 0;
    if (rest[0] != '+' and rest[0] != '-') return 0;
    const neg = rest[0] == '-';
    var s = rest[1..];
    if (s.len < 2 or !isDigit(s[0]) or !isDigit(s[1])) return 0;
    const hh: i32 = @as(i32, s[0] - '0') * 10 + @as(i32, s[1] - '0');
    s = s[2..];
    var mm: i32 = 0;
    if (s.len > 0 and s[0] == ':') {
        s = s[1..];
        if (s.len < 2 or !isDigit(s[0]) or !isDigit(s[1])) return 0;
        mm = @as(i32, s[0] - '0') * 10 + @as(i32, s[1] - '0');
    } else if (s.len >= 2 and isDigit(s[0]) and isDigit(s[1])) {
        mm = @as(i32, s[0] - '0') * 10 + @as(i32, s[1] - '0');
    }
    if (hh > 23 or mm > 59) return 0;
    const total = hh * 60 + mm;
    return if (neg) -total else total;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Shift a timestamp by `-offsetMinutes` (local wall time to UTC), carrying
/// whole days through the Julian calendar. Zero offsets are a no-op.
fn shiftByZoneOffset(dt: *DateTime, offsetMinutes: i32) void {
    if (offsetMinutes == 0) return;
    var totalMin: i32 = dt.hour * 60 + dt.minute - offsetMinutes;
    var dayCarry: i32 = 0;
    while (totalMin < 0) {
        totalMin += 1440;
        dayCarry -= 1;
    }
    while (totalMin >= 1440) {
        totalMin -= 1440;
        dayCarry += 1;
    }
    dt.hour = @divTrunc(totalMin, 60);
    dt.minute = @mod(totalMin, 60);
    if (dayCarry != 0) {
        const noon = DateTime{ .year = dt.year, .month = dt.month, .day = dt.day, .hour = 12, .minute = 0, .second = 0, .fraction = 0.0, .valid = true };
        const shifted = DateTime.fromJulianDay(noon.toJulianDay() + @as(f64, @floatFromInt(dayCarry)));
        dt.year = shifted.year;
        dt.month = shifted.month;
        dt.day = shifted.day;
    }
}

const ClockError = error{ClockUnavailable};

/// Frozen "now" for deterministic tests; null means the wall clock.
/// Test-only: set it, run, and reset to null when done.
var testClock: ?i64 = null;

/// Pin or release the frozen test clock (epoch seconds, UTC).
pub fn setTestClock(seconds: ?i64) void {
    testClock = seconds;
}

fn getCurrentTimestamp() ClockError!i64 {
    if (testClock) |frozen| return frozen;
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .windows => {
            const win100ns = @as(i64, @bitCast(std.os.windows.ntdll.RtlGetSystemTimePrecise()));
            return @divTrunc(win100ns, 10_000_000) + std.time.epoch.windows;
        },
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            if (std.os.linux.clock_gettime(.REALTIME, &ts) != 0) return error.ClockUnavailable;
            return ts.sec;
        },
        .macos,
        .ios,
        .tvos,
        .watchos,
        .visionos,
        .freebsd,
        .netbsd,
        .openbsd,
        .dragonfly,
        .haiku,
        .illumos,
        => {
            var tv: CTimeval = undefined;
            if (gettimeofday(&tv, null) != 0) return error.ClockUnavailable;
            return @intCast(tv.tv_sec);
        },
        else => return error.ClockUnavailable,
    }
}

fn parseDateTimeString(str: []const u8) ?DateTime {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "now")) {
        const nowSec = getCurrentTimestamp() catch return null;
        return DateTime.fromUnixEpoch(nowSec);
    }
    if (trimmed.len >= 10 and trimmed[4] == '-' and trimmed[7] == '-') {
        const y = std.fmt.parseInt(i32, trimmed[0..4], 10) catch return null;
        const m = std.fmt.parseInt(i32, trimmed[5..7], 10) catch return null;
        const d = std.fmt.parseInt(i32, trimmed[8..10], 10) catch return null;
        var hour: i32 = 0;
        var min: i32 = 0;
        var sec: i32 = 0;
        var frac: f64 = 0.0;
        var offsetMinutes: i32 = 0;
        if (trimmed.len > 10 and (trimmed[10] == ' ' or trimmed[10] == 'T')) {
            const timePart = trimmed[11..];
            if (timePart.len >= 5 and timePart[2] == ':') {
                hour = std.fmt.parseInt(i32, timePart[0..2], 10) catch return null;
                min = std.fmt.parseInt(i32, timePart[3..5], 10) catch return null;
                if (timePart.len >= 8 and timePart[5] == ':') {
                    sec = std.fmt.parseInt(i32, timePart[6..8], 10) catch return null;
                    if (timePart.len > 8 and timePart[8] == '.') {
                        var j: usize = 9;
                        var num: f64 = 0.0;
                        var den: f64 = 1.0;
                        while (j < timePart.len and timePart[j] >= '0' and timePart[j] <= '9') : (j += 1) {
                            num = num * 10.0 + @as(f64, @floatFromInt(timePart[j] - '0'));
                            den *= 10.0;
                        }
                        if (j > 9) {
                            frac = num / den;
                            offsetMinutes = zoneOffsetMinutes(timePart[j..]);
                        }
                    } else if (timePart.len > 8) {
                        offsetMinutes = zoneOffsetMinutes(timePart[8..]);
                    }
                }
            }
        }
        var dt = DateTime{
            .year = y,
            .month = m,
            .day = d,
            .hour = hour,
            .minute = min,
            .second = sec,
            .fraction = frac,
            .valid = true,
        };
        shiftByZoneOffset(&dt, offsetMinutes);
        return dt;
    }
    if (parseTimeOnly(trimmed)) |dt| return dt;
    if (std.fmt.parseFloat(f64, trimmed)) |num| {
        return DateTime.fromJulianDay(num);
    } else |_| {}
    return null;
}

// `utc` is an exact no-op (timestamps are already UTC); `localtime` cannot
// convert without a timezone database, so it stays unconverted.
fn applyModifiers(dt: *DateTime, modifiers: []const Value) void {
    for (modifiers) |modVal| {
        if (modVal != .text) continue;
        const modText = std.mem.trim(u8, modVal.text, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(modText, "start of month")) {
            dt.day = 1;
            dt.hour = 0;
            dt.minute = 0;
            dt.second = 0;
            dt.fraction = 0.0;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(modText, "start of year")) {
            dt.month = 1;
            dt.day = 1;
            dt.hour = 0;
            dt.minute = 0;
            dt.second = 0;
            dt.fraction = 0.0;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(modText, "start of day")) {
            dt.hour = 0;
            dt.minute = 0;
            dt.second = 0;
            dt.fraction = 0.0;
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(modText, "weekday ")) {
            const numStr = std.mem.trim(u8, modText[8..], " \t\r\n");
            if (std.fmt.parseInt(i64, numStr, 10)) |targetDay| {
                const curJd = dt.toJulianDay();
                const curDow = @mod(@as(i64, @intFromFloat(@floor(curJd + 1.5))), 7);
                const diff = @rem(targetDay - curDow + 7, 7);
                const nextJd = curJd + @as(f64, @floatFromInt(diff));
                dt.* = DateTime.fromJulianDay(nextJd);
            } else |_| {}
            continue;
        }
        if (std.ascii.eqlIgnoreCase(modText, "auto") or std.ascii.eqlIgnoreCase(modText, "utc") or std.ascii.eqlIgnoreCase(modText, "localtime")) {
            continue;
        }
        var split = std.mem.splitScalar(u8, modText, ' ');
        const numPart = split.next() orelse continue;
        const unitPart = split.next() orelse continue;
        const num = std.fmt.parseFloat(f64, numPart) catch continue;
        if (std.ascii.startsWithIgnoreCase(unitPart, "day")) {
            const nextJd = dt.toJulianDay() + num;
            dt.* = DateTime.fromJulianDay(nextJd);
        } else if (std.ascii.startsWithIgnoreCase(unitPart, "hour")) {
            const nextJd = dt.toJulianDay() + (num / 24.0);
            dt.* = DateTime.fromJulianDay(nextJd);
        } else if (std.ascii.startsWithIgnoreCase(unitPart, "minute")) {
            const nextJd = dt.toJulianDay() + (num / 1440.0);
            dt.* = DateTime.fromJulianDay(nextJd);
        } else if (std.ascii.startsWithIgnoreCase(unitPart, "second")) {
            const nextJd = dt.toJulianDay() + (num / 86400.0);
            dt.* = DateTime.fromJulianDay(nextJd);
        } else if (std.ascii.startsWithIgnoreCase(unitPart, "month")) {
            const months = @as(i32, @intFromFloat(num));
            const totalMonths = dt.year * 12 + (dt.month - 1) + months;
            dt.year = @divTrunc(totalMonths, 12);
            dt.month = @rem(totalMonths, 12) + 1;
            if (dt.month <= 0) {
                dt.month += 12;
                dt.year -= 1;
            }
            const nextJd = dt.toJulianDay();
            dt.* = DateTime.fromJulianDay(nextJd);
        } else if (std.ascii.startsWithIgnoreCase(unitPart, "year")) {
            const years = @as(i32, @intFromFloat(num));
            dt.year += years;
            const nextJd = dt.toJulianDay();
            dt.* = DateTime.fromJulianDay(nextJd);
        }
    }
}

fn parseDateTimeWithModifiers(args: []const Value) ?DateTime {
    if (args.len == 0) return null;
    const baseVal = args[0];
    if (baseVal == .null) return null;
    var hasUnixEpochMod = false;
    for (args[1..]) |m| {
        if (m == .text and std.ascii.eqlIgnoreCase(m.text, "unixepoch")) {
            hasUnixEpochMod = true;
            break;
        }
    }
    var dt: DateTime = undefined;
    if (hasUnixEpochMod) {
        const sec: i64 = switch (baseVal) {
            .integer => |i| i,
            .real => |r| @intFromFloat(r),
            .text => |t| std.fmt.parseInt(i64, std.mem.trim(u8, t, " \t\r\n"), 10) catch return null,
            else => return null,
        };
        dt = DateTime.fromUnixEpoch(sec);
    } else {
        switch (baseVal) {
            .text => |t| {
                dt = parseDateTimeString(t) orelse return null;
            },
            .integer => |i| {
                dt = DateTime.fromJulianDay(@floatFromInt(i));
            },
            .real => |r| {
                dt = DateTime.fromJulianDay(r);
            },
            else => return null,
        }
    }
    applyModifiers(&dt, args[1..]);
    return dt;
}

/// `date(...)`: `YYYY-MM-DD` text or NULL when unparseable/empty.
pub fn evalDate(allocator: std.mem.Allocator, args: []const Value) !Value {
    const dt = parseDateTimeWithModifiers(args) orelse return .null;
    const y: u32 = if (dt.year >= 0) @intCast(dt.year) else 0;
    const m: u32 = if (dt.month >= 0) @intCast(dt.month) else 0;
    const d: u32 = if (dt.day >= 0) @intCast(dt.day) else 0;
    const res = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, m, d });
    return .{ .text = res };
}

/// `time(...)`: `HH:MM:SS` text or NULL when unparseable/empty.
pub fn evalTime(allocator: std.mem.Allocator, args: []const Value) !Value {
    const dt = parseDateTimeWithModifiers(args) orelse return .null;
    const h: u32 = if (dt.hour >= 0) @intCast(dt.hour) else 0;
    const mi: u32 = if (dt.minute >= 0) @intCast(dt.minute) else 0;
    const s: u32 = if (dt.second >= 0) @intCast(dt.second) else 0;
    const res = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, mi, s });
    return .{ .text = res };
}

/// `datetime(...)`: `YYYY-MM-DD HH:MM:SS` text or NULL when unparseable/empty.
pub fn evalDatetime(allocator: std.mem.Allocator, args: []const Value) !Value {
    const dt = parseDateTimeWithModifiers(args) orelse return .null;
    const y: u32 = if (dt.year >= 0) @intCast(dt.year) else 0;
    const m: u32 = if (dt.month >= 0) @intCast(dt.month) else 0;
    const d: u32 = if (dt.day >= 0) @intCast(dt.day) else 0;
    const h: u32 = if (dt.hour >= 0) @intCast(dt.hour) else 0;
    const mi: u32 = if (dt.minute >= 0) @intCast(dt.minute) else 0;
    const s: u32 = if (dt.second >= 0) @intCast(dt.second) else 0;
    const res = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ y, m, d, h, mi, s });
    return .{ .text = res };
}

/// `julianday(...)`: REAL Julian day or NULL when unparseable/empty.
pub fn evalJulianday(args: []const Value) Value {
    const dt = parseDateTimeWithModifiers(args) orelse return .null;
    return .{ .real = dt.toJulianDay() };
}

/// `unixepoch(...)`: INTEGER seconds since epoch or NULL when unparseable/empty.
pub fn evalUnixepoch(args: []const Value) Value {
    const dt = parseDateTimeWithModifiers(args) orelse return .null;
    return .{ .integer = dt.toUnixEpoch() };
}

/// `strftime(fmt,...)`: format subset (`%Y %m %d %H %M %S %f %s %j %J %w %W %%`).
/// NULL when fmt is not text, args < 2, or the timestamp is unparseable.
pub fn evalStrftime(allocator: std.mem.Allocator, args: []const Value) !Value {
    if (args.len < 2) return .null;
    const fmtVal = args[0];
    if (fmtVal != .text) return .null;
    const dt = parseDateTimeWithModifiers(args[1..]) orelse return .null;
    const fmt = fmtVal.text;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            const spec = fmt[i + 1];
            switch (spec) {
                'd' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{@as(u32, @intCast(@max(0, dt.day)))});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'f' => {
                    const totalSec = @as(f64, @floatFromInt(dt.second)) + dt.fraction;
                    const s = try std.fmt.allocPrint(allocator, "{d:0>6.3}", .{totalSec});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'H' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{@as(u32, @intCast(@max(0, dt.hour)))});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'j' => {
                    const jdStart = (DateTime{ .year = dt.year, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }).toJulianDay();
                    const dayOfYear = @as(i64, @intFromFloat(@floor(dt.toJulianDay() - jdStart))) + 1;
                    const s = try std.fmt.allocPrint(allocator, "{d:0>3}", .{@as(u32, @intCast(@max(0, dayOfYear)))});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'J' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:.16}", .{dt.toJulianDay()});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'm' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{@as(u32, @intCast(@max(0, dt.month)))});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'M' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{@as(u32, @intCast(@max(0, dt.minute)))});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                's' => {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{dt.toUnixEpoch()});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'S' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{@as(u32, @intCast(@max(0, dt.second)))});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'w' => {
                    const curDow = @mod(@as(i64, @intFromFloat(@floor(dt.toJulianDay() + 1.5))), 7);
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{curDow});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'W' => {
                    const jdStart = (DateTime{ .year = dt.year, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }).toJulianDay();
                    const dayOfYear = @as(i64, @intFromFloat(@floor(dt.toJulianDay() - jdStart)));
                    const weekOfYear = @divTrunc(dayOfYear, 7);
                    const s = try std.fmt.allocPrint(allocator, "{d:0>2}", .{@as(u32, @intCast(@max(0, weekOfYear)))});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                'Y' => {
                    const s = try std.fmt.allocPrint(allocator, "{d:0>4}", .{@as(u32, @intCast(@max(0, dt.year)))});
                    defer allocator.free(s);
                    try out.appendSlice(allocator, s);
                    i += 1;
                    continue;
                },
                '%' => {
                    try out.append(allocator, '%');
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(allocator, fmt[i]);
    }
    return .{ .text = try out.toOwnedSlice(allocator) };
}

test "datetime normal behavior" {
    const alloc = std.testing.allocator;
    const d = try evalDate(alloc, &.{.{ .text = "2024-02-29" }});
    defer d.free(alloc);
    try std.testing.expectEqualStrings("2024-02-29", d.text);
    const t = try evalTime(alloc, &.{.{ .text = "2024-01-02 03:04:05" }});
    defer t.free(alloc);
    try std.testing.expectEqualStrings("03:04:05", t.text);
    const dt = try evalDatetime(alloc, &.{.{ .text = "2024-01-02" }});
    defer dt.free(alloc);
    try std.testing.expectEqualStrings("2024-01-02 00:00:00", dt.text);
    const jd = evalJulianday(&.{.{ .text = "2000-01-01 12:00:00" }});
    try std.testing.expect(jd == .real);
    const ux = evalUnixepoch(&.{.{ .text = "1970-01-01 00:00:01" }});
    try std.testing.expectEqual(@as(i64, 1), ux.integer);
    const sf = try evalStrftime(alloc, &.{ .{ .text = "%Y-%m-%d" }, .{ .text = "2024-03-04 05:06:07" } });
    defer sf.free(alloc);
    try std.testing.expectEqualStrings("2024-03-04", sf.text);
}

test "datetime null empty and boundary" {
    const alloc = std.testing.allocator;
    try std.testing.expect((try evalDate(alloc, &.{})) == .null);
    try std.testing.expect((try evalDate(alloc, &.{.null})) == .null);
    try std.testing.expect((try evalDate(alloc, &.{.{ .text = "" }})) == .null);
    try std.testing.expect((try evalDate(alloc, &.{.{ .text = "not-a-date" }})) == .null);
    try std.testing.expect((try evalStrftime(alloc, &.{.{ .text = "%Y" }})) == .null);
    try std.testing.expect((try evalStrftime(alloc, &.{ .{ .integer = 1 }, .{ .text = "2024-01-01" } })) == .null);
    // Modifiers: start-of-month truncates, +1 day advances.
    const som = try evalDate(alloc, &.{ .{ .text = "2024-03-15" }, .{ .text = "start of month" } });
    defer som.free(alloc);
    try std.testing.expectEqualStrings("2024-03-01", som.text);
    const nxt = try evalDate(alloc, &.{ .{ .text = "2024-03-01" }, .{ .text = "1 day" } });
    defer nxt.free(alloc);
    try std.testing.expectEqualStrings("2024-03-02", nxt.text);
    // Julian round-trip through DateTime helpers.
    const rt = DateTime.fromJulianDay((DateTime{ .year = 2024, .month = 5, .day = 6, .hour = 7, .minute = 8, .second = 9 }).toJulianDay());
    try std.testing.expectEqual(@as(i32, 2024), rt.year);
    try std.testing.expectEqual(@as(i32, 5), rt.month);
    try std.testing.expectEqual(@as(i32, 6), rt.day);
}

test "datetime invalid modifiers fail soft to null or ignored" {
    const alloc = std.testing.allocator;
    // Unknown modifier text is ignored, base date still formats.
    const kept = try evalDate(alloc, &.{ .{ .text = "2024-01-02" }, .{ .text = "frobnicate" } });
    defer kept.free(alloc);
    try std.testing.expectEqualStrings("2024-01-02", kept.text);
    // Non-text modifier skipped; unixepoch modifier path with bad int is NULL.
    try std.testing.expect(evalUnixepoch(&.{ .{ .text = "abc" }, .{ .text = "unixepoch" } }) == .null);
    try std.testing.expect(evalJulianday(&.{.null}) == .null);
}

test "datetime parses timezone suffixes into UTC" {
    const alloc = std.testing.allocator;
    // Z means UTC already.
    const zulu = try evalDatetime(alloc, &.{.{ .text = "2024-03-04 05:06:07Z" }});
    defer zulu.free(alloc);
    try std.testing.expectEqualStrings("2024-03-04 05:06:07", zulu.text);
    // Positive offsets shift back; negative shift forward, across midnight.
    const plus = try evalDatetime(alloc, &.{.{ .text = "2024-03-04 05:06:07+02:00" }});
    defer plus.free(alloc);
    try std.testing.expectEqualStrings("2024-03-04 03:06:07", plus.text);
    const minus = try evalDatetime(alloc, &.{.{ .text = "2024-03-04 00:30:00-02:00" }});
    defer minus.free(alloc);
    try std.testing.expectEqualStrings("2024-03-04 02:30:00", minus.text);
    const backDay = try evalDate(alloc, &.{.{ .text = "2024-03-04 01:00:00+03:00" }});
    defer backDay.free(alloc);
    try std.testing.expectEqualStrings("2024-03-03", backDay.text);
    const fwdDay = try evalDate(alloc, &.{.{ .text = "2024-03-04 23:00:00-03:00" }});
    defer fwdDay.free(alloc);
    try std.testing.expectEqualStrings("2024-03-05", fwdDay.text);
    // Compact +HHMM and bare +HH forms work the same.
    const compact = try evalTime(alloc, &.{.{ .text = "05:06:07+0200" }});
    defer compact.free(alloc);
    try std.testing.expectEqualStrings("03:06:07", compact.text);
    const bareHour = try evalTime(alloc, &.{.{ .text = "05:06:07+02" }});
    defer bareHour.free(alloc);
    try std.testing.expectEqualStrings("03:06:07", bareHour.text);
    // T separator plus fractional seconds survive the shift.
    const frac = try evalStrftime(alloc, &.{ .{ .text = "%Y-%m-%d %H:%M:%f" }, .{ .text = "2024-03-04T05:06:07.5+02:00" } });
    defer frac.free(alloc);
    try std.testing.expectEqualStrings("2024-03-04 03:06:07.500", frac.text);
}

test "datetime frozen clock pins now deterministically" {
    const alloc = std.testing.allocator;
    setTestClock(1704067200); // 2024-01-01 00:00:00 UTC.
    defer setTestClock(null);
    const d = try evalDate(alloc, &.{.{ .text = "now" }});
    defer d.free(alloc);
    try std.testing.expectEqualStrings("2024-01-01", d.text);
    const dt = try evalDatetime(alloc, &.{.{ .text = "now" }});
    defer dt.free(alloc);
    try std.testing.expectEqualStrings("2024-01-01 00:00:00", dt.text);
    const ux = evalUnixepoch(&.{.{ .text = "now" }});
    try std.testing.expectEqual(@as(i64, 1704067200), ux.integer);
}
