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
test "timestampMs returns reasonable value" {
    const ts = timestampMs();
    try std.testing.expect(ts > 1700000000000); // After 2023
    try std.testing.expect(ts < 2000000000000); // Before 2033
}

test "elapsedMs calculates correctly" {
    const start = timestampMs();
    std.Thread.sleep(10_000_000); // 10ms
    const elapsed = elapsedMs(start);
    try std.testing.expect(elapsed >= 10);
}

test "formatDuration returns correct units" {
    const d1 = formatDuration(500);
    try std.testing.expectEqual(@as(i64, 500), d1.value);
    try std.testing.expectEqualStrings("ms", d1.unit);
    
    const d2 = formatDuration(5000);
    try std.testing.expectEqual(@as(i64, 5), d2.value);
    try std.testing.expectEqualStrings("s", d2.unit);
    
    const d3 = formatDuration(120000);
    try std.testing.expectEqual(@as(i64, 2), d3.value);
    try std.testing.expectEqualStrings("min", d3.unit);
    
    const d4 = formatDuration(7200000);
    try std.testing.expectEqual(@as(i64, 2), d4.value);
    try std.testing.expectEqualStrings("h", d4.unit);
}

test "timestampIso produces valid format" {
    const iso = try timestampIso(std.testing.allocator);
    defer std.testing.allocator.free(iso);
    
    // Should be 24 chars: YYYY-MM-DDTHH:MM:SS.mmmZ
    try std.testing.expectEqual(@as(usize, 24), iso.len);
    try std.testing.expectEqual('-', iso[4]);
    try std.testing.expectEqual('-', iso[7]);
    try std.testing.expectEqual('T', iso[10]);
    try std.testing.expectEqual(':', iso[13]);
    try std.testing.expectEqual(':', iso[16]);
    try std.testing.expectEqual('.', iso[19]);
    try std.testing.expectEqual('Z', iso[23]);
}

test "timestampCompact produces valid format" {
    const compact = try timestampCompact(std.testing.allocator);
    defer std.testing.allocator.free(compact);
    
    // Should be 15 chars: YYYYMMDD-HHMMSS
    try std.testing.expectEqual(@as(usize, 15), compact.len);
    try std.testing.expectEqual('-', compact[8]);
}
