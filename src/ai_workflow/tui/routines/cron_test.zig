//! Behavioral tests for the 5-field cron parser + `nextFireTime` (Task 1.3
//! of the Add Task Routines plan).
//!
//! The parser handles the standard 5-field cron format:
//!     minute hour day-of-month month day-of-week
//!
//! Each field supports `*`, `N`, `N-M`, `*/S`, `N-M/S`, and `a,b,c`
//! (comma-separated). Day-of-week uses 0 = Sunday .. 6 = Saturday
//! (matches what Zeller's congruence returns).
//!
//! `nextFireTime(expr, after_unix_nanos)` returns the strictly next minute
//! at which the expression would fire. Used by the Scheduler (Task 3.1) to
//! populate `next_run_at` at insert time and after each fire.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines.md (Task 1.3)
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");
const testing = std.testing;
const cron = @import("cron.zig");

// ─── Time helper ──────────────────────────────────────────────────────────

/// Compose a UTC unix-nanos value from broken-down date + time fields.
/// Uses Howard Hinnant's `days_from_civil` (public domain) to compute
/// days-since-1970-01-01, then multiplies by `ns_per_day` and adds the
/// hour/minute component. This is the inverse of the same project's
/// `src/modules/logger/Timing.zig` `timestampIso` (which uses
/// `std.time.epoch` to go in the other direction).
fn tsUtc(year: i32, month: u4, day: u5, hour: u5, minute: u6) i128 {
    // Howard Hinnant days_from_civil, adapted to Zig signed-int arithmetic.
    // The algorithm treats the date as a shift of the civil-from-days
    // function and works for the full proleptic Gregorian calendar
    // (positive and negative years). Reference:
    //   http://howardhinnant.github.io/date_algorithms.html#days_from_civil
    const y: i32 = if (month <= 2) year - 1 else year;
    // Note: the original C++ is `(y >= 0 ? y : y - 399) / 400` — the
    // division is part of the expression. Don't drop the `/ 400` or
    // `era` becomes the year itself and the whole formula diverges.
    const era: i32 = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe: u32 = @intCast(@mod(y - era * 400, 400)); // [0, 399]
    const doy: u32 = (153 * @as(u32, @intCast((if (month > 2) month - 3 else month + 9))) + 2) / 5 + day - 1; // [0, 365]
    const doe: u32 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    const days: i64 = @as(i64, era) * 146097 + @as(i64, @intCast(doe)) - 719468;

    const secs_in_day: i64 = @as(i64, hour) * std.time.s_per_hour +
        @as(i64, minute) * std.time.s_per_min;
    return @as(i128, days * std.time.s_per_day + secs_in_day) * std.time.ns_per_s;
}

// ─── Tests ────────────────────────────────────────────────────────────────

// Sanity check the time helper itself — if these are wrong, every other
// test fails for a confusing reason. Verified against `date -u -d` and
// `timegm(3)`: 2025-06-13 04:57 UTC = 1749790620 sec; 2024-02-29 00:00
// UTC = 1709164800 sec.
test "tsUtc: known unix seconds" {
    try testing.expectEqual(@as(i128, 1749790620) * std.time.ns_per_s, tsUtc(2025, 6, 13, 4, 57));
    try testing.expectEqual(@as(i128, 1749790680) * std.time.ns_per_s, tsUtc(2025, 6, 13, 4, 58));
    try testing.expectEqual(@as(i128, 1709164800) * std.time.ns_per_s, tsUtc(2024, 2, 29, 0, 0));
    try testing.expectEqual(@as(i128, 0), tsUtc(1970, 1, 1, 0, 0));
    try testing.expectEqual(@as(i128, 946684800) * std.time.ns_per_s, tsUtc(2000, 1, 1, 0, 0));
}

test "validate: accepts a simple expression" {
    try cron.validate("*/5 * * * *");
    try cron.validate("0 9 * * 1-5");
    try cron.validate("0 0 1 * *");
    try cron.validate("30 14 1 1 *");
}

test "validate: rejects garbage" {
    try testing.expectError(error.InvalidCron, cron.validate("not a cron"));
    try testing.expectError(error.InvalidCron, cron.validate("60 * * * *")); // minute out of range
    try testing.expectError(error.InvalidCron, cron.validate("* * *")); // too few fields
    try testing.expectError(error.InvalidCron, cron.validate("a b c d e")); // non-numeric
}

test "nextFireTime: every 5 minutes lands on next /5 minute" {
    // 2025-06-13 04:57 UTC -> next /5 minute is 05:00 (00, 05, 10, ...).
    // The plan originally said "04:58" but 04:58 is not divisible by 5;
    // the correct next /5 boundary after 04:57 is 05:00.
    const after = tsUtc(2025, 6, 13, 4, 57);
    const next = try cron.nextFireTime("*/5 * * * *", after);
    const expected = tsUtc(2025, 6, 13, 5, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: hourly on the hour" {
    const after = tsUtc(2025, 6, 13, 4, 32);
    const next = try cron.nextFireTime("0 * * * *", after);
    const expected = tsUtc(2025, 6, 13, 5, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: daily at 09:00" {
    const after = tsUtc(2025, 6, 13, 10, 0);
    const next = try cron.nextFireTime("0 9 * * *", after);
    const expected = tsUtc(2025, 6, 14, 9, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: weekdays at 09:00 (Sat -> Mon)" {
    // 2025-06-14 is a Saturday; 2025-06-16 is the next Monday
    const after = tsUtc(2025, 6, 14, 10, 0);
    const next = try cron.nextFireTime("0 9 * * 1-5", after);
    const expected = tsUtc(2025, 6, 16, 9, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: monthly on the 1st" {
    const after = tsUtc(2025, 6, 15, 12, 0);
    const next = try cron.nextFireTime("0 0 1 * *", after);
    const expected = tsUtc(2025, 7, 1, 0, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: leap year Feb 29" {
    // 2024 is a leap year. From 2024-02-28 12:00, the 29th at 00:00 should be next.
    const after = tsUtc(2024, 2, 28, 12, 0);
    const next = try cron.nextFireTime("0 0 29 2 *", after);
    const expected = tsUtc(2024, 2, 29, 0, 0);
    try testing.expectEqual(expected, next);
}

test "nextFireTime: result is always strictly after `after`" {
    const expressions = [_][]const u8{
        "*/5 * * * *",
        "0 * * * *",
        "0 9 * * *",
        "0 9 * * 1-5",
        "0 0 1 * *",
    };
    const after = tsUtc(2025, 6, 13, 4, 57);
    for (expressions) |expr| {
        const next = try cron.nextFireTime(expr, after);
        try testing.expect(next > after);
    }
}
