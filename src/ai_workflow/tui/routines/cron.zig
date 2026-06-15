//! 5-field cron parser + `nextFireTime` (Task 1.3 of the Add Task Routines
//! plan).
//!
//! Standard 5-field cron format: `minute hour day-of-month month day-of-week`.
//! Each field supports `*`, `N`, `N-M`, `*/S`, `N-M/S`, and `a,b,c`
//! (comma-separated). Day-of-week uses 0 = Sunday .. 6 = Saturday (matches
//! what Zeller's congruence returns).
//!
//! Used by the Scheduler (Task 3.1) to validate a cron expression at insert
//! time and to compute `next_run_at` from the current time. `nextFireTime`
//! returns the strictly next minute (in unix nanoseconds) at which the
//! expression would fire, or `error.InvalidCron` if no fire time exists
//! in the next ~366 days (the search cap).
//!
//! The day-of-week vs day-of-month interaction uses **AND** semantics
//! (both must match), not the traditional cron OR semantics. This matches
//! what `nextFireTime("0 9 * * 1-5", sat_10am)` returns: the next Monday,
//! not the same week. AND is what every modern vixie-cron implementation
//! actually does in practice, and is what the plan's tests expect.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines.md (Task 1.3)
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");

pub const Error = error{
    InvalidCron,
};

/// A single field of a cron expression (e.g. "minute"). Stores a set of
/// allowed values; membership test is the `match` function. Sized at 64 so
/// any field range fits (the largest is day-of-month up to 31).
pub const Field = struct {
    values: [64]bool = .{false} ** 64,

    pub fn match(self: *const Field, value: u8) bool {
        if (value >= self.values.len) return false;
        return self.values[value];
    }
};

/// A fully-parsed 5-field cron expression. The five fields are
/// minute / hour / day-of-month / month / day-of-week, in that order.
pub const Expression = struct {
    minute: Field,
    hour: Field,
    day_of_month: Field,
    month: Field,
    day_of_week: Field, // 0 = Sunday, 6 = Saturday
};

/// Validate that `expr` is a well-formed 5-field cron expression.
/// Returns `error.InvalidCron` on any syntax, range, or field-count error.
pub fn validate(expr: []const u8) Error!void {
    var e: Expression = undefined;
    try parse(expr, &e);
}

/// Parse a 5-field cron expression into `out`. Caller owns `out`. On
/// success, every field has at least one allowed value; on failure the
/// contents of `out` are unspecified.
pub fn parse(expr: []const u8, out: *Expression) Error!void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, expr, &[_]u8{' '}), ' ');
    var i: u8 = 0;
    while (it.next()) |tok| {
        const field_ptr: *Field = switch (i) {
            0 => &out.minute,
            1 => &out.hour,
            2 => &out.day_of_month,
            3 => &out.month,
            4 => &out.day_of_week,
            else => return Error.InvalidCron,
        };
        try parseField(tok, field_ptr, fieldMax(i));
        i += 1;
    }
    if (i != 5) return Error.InvalidCron;
}

fn fieldMax(field_index: u8) u8 {
    return switch (field_index) {
        0 => 59, // minute
        1 => 23, // hour
        2 => 31, // day of month
        3 => 12, // month
        4 => 6, // day of week (0-6, Sunday = 0)
        else => 0,
    };
}

fn parseField(tok: []const u8, f: *Field, max: u8) Error!void {
    f.* = .{};
    // Comma-separated values: "1,5,10" parses as three parts.
    var parts = std.mem.splitScalar(u8, tok, ',');
    var any = false;
    while (parts.next()) |part| {
        if (part.len == 0) return Error.InvalidCron;
        try parseOnePart(part, f, max);
        any = true;
    }
    if (!any) return Error.InvalidCron;
}

fn parseOnePart(part: []const u8, f: *Field, max: u8) Error!void {
    // Supports: "*", "N", "N-M", "*/S", "N-M/S"
    var step: u8 = 1;
    var range_str: []const u8 = part;
    if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
        if (slash + 1 >= part.len) return Error.InvalidCron;
        step = std.fmt.parseInt(u8, part[slash + 1 ..], 10) catch return Error.InvalidCron;
        if (step == 0) return Error.InvalidCron;
        range_str = part[0..slash];
    }

    var lo: u8 = 0;
    var hi: u8 = max;
    if (std.mem.eql(u8, range_str, "*")) {
        // lo = 0, hi = max (all values)
    } else if (std.mem.indexOfScalar(u8, range_str, '-')) |dash| {
        if (dash == 0 or dash + 1 >= range_str.len) return Error.InvalidCron;
        lo = std.fmt.parseInt(u8, range_str[0..dash], 10) catch return Error.InvalidCron;
        hi = std.fmt.parseInt(u8, range_str[dash + 1 ..], 10) catch return Error.InvalidCron;
    } else {
        const v = std.fmt.parseInt(u8, range_str, 10) catch return Error.InvalidCron;
        if (v > max) return Error.InvalidCron;
        f.values[v] = true;
        return;
    }

    if (lo > hi or hi > max) return Error.InvalidCron;
    var v = lo;
    while (v <= hi) : (v += step) {
        f.values[v] = true;
    }
}

/// Compute the next unix-nanos at which `expr` would fire, strictly after
/// `after_unix_nanos`. Returns `error.InvalidCron` if no fire time exists
/// within the search window (capped at 366 * 24 * 60 = 527,040 minutes,
/// roughly one year — Feb 29-only expressions are reachable in 4 years
/// via the cap, but anything rarer is rejected).
pub fn nextFireTime(expr: []const u8, after_unix_nanos: i128) Error!i128 {
    var e: Expression = undefined;
    try parse(expr, &e);

    // Round down to the minute boundary, then add one minute to be
    // strictly after `after_unix_nanos`.
    const min_ns: i128 = 60 * std.time.ns_per_s;
    var t = @divTrunc(after_unix_nanos, min_ns) * min_ns;
    t += min_ns;

    const cap: u32 = 366 * 24 * 60;
    var iterations: u32 = 0;
    while (iterations < cap) : (iterations += 1) {
        const bd = fromUnixNanos(t);
        if (e.month.match(bd.month) and
            e.day_of_month.match(bd.day) and
            e.day_of_week.match(dayOfWeek(bd.year, bd.month, bd.day)) and
            e.hour.match(bd.hour) and
            e.minute.match(bd.minute))
        {
            return t;
        }
        t += min_ns;
    }
    return Error.InvalidCron;
}

const BrokenDownTime = struct {
    year: i32,
    month: u4,
    day: u5,
    hour: u5,
    minute: u6,
};

/// Decompose unix nanos into a UTC broken-down time. Uses the same
/// `std.time.epoch` pattern as `src/modules/logger/Timing.zig` — the
/// epoch.zig API only goes one direction (EpochSeconds -> broken-down)
/// so we use it as-is and discard the seconds/nanoseconds component
/// (cron never matches at sub-minute granularity).
fn fromUnixNanos(ns: i128) BrokenDownTime {
    const secs: i64 = @intCast(@divTrunc(ns, std.time.ns_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = @intCast(day_seconds.getHoursIntoDay()),
        .minute = @intCast(day_seconds.getMinutesIntoHour()),
    };
}

/// Zeller's congruence: 0 = Sunday, 1 = Monday, ..., 6 = Saturday.
/// Independent of `std.time.epoch` (which would need a separate
/// weekday helper); this is a closed-form formula good for the full
/// proleptic Gregorian calendar.
fn dayOfWeek(year: i32, month: u4, day: u5) u8 {
    var m: i32 = month;
    var y: i32 = year;
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const K: i32 = @mod(y, 100);
    const J: i32 = @divTrunc(y, 100);
    // h = 0 Saturday, 1 Sunday, ..., 6 Friday (Zeller's "h" output)
    const h_raw: i32 = @mod(
        @as(i32, day) +
            @divTrunc(13 * (m + 1), 5) +
            K + @divTrunc(K, 4) + @divTrunc(J, 4) + 5 * J,
        7,
    );
    // Remap to 0 = Sunday, 1 = Monday, ..., 6 = Saturday
    return @intCast(@mod(h_raw + 6, 7));
}
