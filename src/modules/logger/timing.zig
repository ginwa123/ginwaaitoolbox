const std = @import("std");

/// Get current timestamp in milliseconds since epoch
pub fn timestampMs() i64 {
    return std.time.milliTimestamp();
}

/// Calculate elapsed time in milliseconds
pub fn elapsedMs(start: i64) i64 {
    return timestampMs() - start;
}

/// Duration unit for human-readable output
pub const Duration = struct {
    value: i64,
    unit: []const u8,
};

/// Format duration for human-readable output
pub fn formatDuration(ms: i64) Duration {
    if (ms < 1000) return .{ .value = ms, .unit = "ms" };
    if (ms < 60000) return .{ .value = @divTrunc(ms, 1000), .unit = "s" };
    if (ms < 3600000) return .{ .value = @divTrunc(ms, 60000), .unit = "min" };
    return .{ .value = @divTrunc(ms, 3600000), .unit = "h" };
}

/// Get current timestamp as ISO 8601 string (caller owns memory)
/// Format: YYYY-MM-DDTHH:MM:SS.mmmZ
pub fn timestampIso(allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.time.timestamp();
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    
    const hours = day_seconds.getHoursIntoDay();
    const minutes = day_seconds.getMinutesIntoHour();
    const seconds = day_seconds.getSecondsIntoMinute();
    
    // Get milliseconds from millisecond timestamp
    const ms_ts = std.time.milliTimestamp();
    const ms = @as(u32, @intCast(@mod(ms_ts, 1000)));
    
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            hours,
            minutes,
            seconds,
            ms,
        },
    );
}

/// Get current timestamp as compact format for request IDs
/// Format: YYYYMMDD-HHMMSS
pub fn timestampCompact(allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.time.timestamp();
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    
    const hours = day_seconds.getHoursIntoDay();
    const minutes = day_seconds.getMinutesIntoHour();
    const seconds = day_seconds.getSecondsIntoMinute();
    
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            hours,
            minutes,
            seconds,
        },
    );
}

// Tests

test {
    _ = @import("timing_test.zig");
}
