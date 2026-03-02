const std = @import("std");
const formatter = @import("formatter.zig");
const LogLevel = formatter.LogLevel;
const LogEntry = formatter.LogEntry;
const TextFormatter = formatter.TextFormatter;
const JsonFormatter = formatter.JsonFormatter;
const ColorFormatter = formatter.ColorFormatter;
const AnsiColors = formatter.AnsiColors;
const getAgentColor = formatter.getAgentColor;

test "LogLevel toString" {
    try std.testing.expectEqualStrings("TRACE", LogLevel.trace.toString());
    try std.testing.expectEqualStrings("DEBUG", LogLevel.debug.toString());
    try std.testing.expectEqualStrings("INFO", LogLevel.info.toString());
    try std.testing.expectEqualStrings("WARN", LogLevel.warn.toString());
    try std.testing.expectEqualStrings("ERROR", LogLevel.err.toString());
}

test "LogLevel fromString" {
    try std.testing.expectEqual(LogLevel.trace, LogLevel.fromString("trace").?);
    try std.testing.expectEqual(LogLevel.debug, LogLevel.fromString("DEBUG").?);
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString("Info").?);
    try std.testing.expectEqual(LogLevel.warn, LogLevel.fromString("WARN").?);
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("error").?);
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.fromString("invalid"));
}

test "TextFormatter produces correct output" {
    var formatter_inst = TextFormatter.init();
    const entry = LogEntry{
        .level = .info,
        .timestamp = 1234567890000,
        .request_id = "REQ-20240101-120000-ab12",
        .message = "Test message",
    };
    
    const output = try formatter_inst.formatter().format(std.testing.allocator, entry);
    defer std.testing.allocator.free(output);
    
    try std.testing.expect(std.mem.indexOf(u8, output, "[INFO]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "REQ-20240101-120000-ab12") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test message") != null);
}

test "JsonFormatter produces valid JSON" {
    var formatter_inst = JsonFormatter{ .pretty = false };
    const entry = LogEntry{
        .level = .info,
        .timestamp = 1234567890000,
        .request_id = "REQ-20240101-120000-ab12",
        .message = "Test message",
    };
    
    const output = try formatter_inst.formatter().format(std.testing.allocator, entry);
    defer std.testing.allocator.free(output);
    
    // Verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    
    try std.testing.expectEqualStrings("INFO", parsed.value.object.get("level").?.string);
    try std.testing.expectEqualStrings("Test message", parsed.value.object.get("message").?.string);
}

test "ColorFormatter includes ANSI codes" {
    var formatter_inst = ColorFormatter.init();
    const entry = LogEntry{
        .level = .err,
        .timestamp = 1234567890000,
        .request_id = null,
        .message = "Error message",
    };
    
    const output = try formatter_inst.formatter().format(std.testing.allocator, entry);
    defer std.testing.allocator.free(output);
    
    // Should contain ANSI reset code
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[0m") != null);
    // Should contain red color for error level
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[31m") != null);
}

test "getAgentColor rotates through colors" {
    try std.testing.expectEqualStrings(AnsiColors.cyan, getAgentColor(0));
    try std.testing.expectEqualStrings(AnsiColors.green, getAgentColor(1));
    try std.testing.expectEqualStrings(AnsiColors.yellow, getAgentColor(2));
    try std.testing.expectEqualStrings(AnsiColors.dim, getAgentColor(3));
    try std.testing.expectEqualStrings(AnsiColors.cyan, getAgentColor(4)); // Wraps around
}

test "LogEntry with context" {
    var formatter_inst = TextFormatter{ .include_timestamp = false, .include_request_id = false };
    const entry = LogEntry{
        .level = .info,
        .timestamp = 1234567890000,
        .request_id = null,
        .message = "User logged in",
        .context = "user_id=123",
    };
    
    const output = try formatter_inst.formatter().format(std.testing.allocator, entry);
    defer std.testing.allocator.free(output);
    
    try std.testing.expect(std.mem.indexOf(u8, output, "User logged in") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(user_id=123)") != null);
}
