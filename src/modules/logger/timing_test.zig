const std = @import("std");
const timing = @import("timing.zig");

test "timestampMs returns reasonable value" {
    const ts = timing.timestampMs();
    try std.testing.expect(ts > 1700000000000); // After 2023
    try std.testing.expect(ts < 2000000000000); // Before 2033
}

test "elapsedMs calculates correctly" {
    const start = timing.timestampMs();
    std.Thread.sleep(10_000_000); // 10ms
    const elapsed = timing.elapsedMs(start);
    try std.testing.expect(elapsed >= 10);
}

test "formatDuration returns correct units" {
    const d1 = timing.formatDuration(500);
    try std.testing.expectEqual(@as(i64, 500), d1.value);
    try std.testing.expectEqualStrings("ms", d1.unit);
    
    const d2 = timing.formatDuration(5000);
    try std.testing.expectEqual(@as(i64, 5), d2.value);
    try std.testing.expectEqualStrings("s", d2.unit);
    
    const d3 = timing.formatDuration(120000);
    try std.testing.expectEqual(@as(i64, 2), d3.value);
    try std.testing.expectEqualStrings("min", d3.unit);
    
    const d4 = timing.formatDuration(7200000);
    try std.testing.expectEqual(@as(i64, 2), d4.value);
    try std.testing.expectEqualStrings("h", d4.unit);
}

test "timestampIso produces valid format" {
    const iso = try timing.timestampIso(std.testing.allocator);
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
    const compact = try timing.timestampCompact(std.testing.allocator);
    defer std.testing.allocator.free(compact);
    
    // Should be 15 chars: YYYYMMDD-HHMMSS
    try std.testing.expectEqual(@as(usize, 15), compact.len);
    try std.testing.expectEqual('-', compact[8]);
}
