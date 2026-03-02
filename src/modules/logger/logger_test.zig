const std = @import("std");
const logger = @import("logger.zig");
const Logger = logger.Logger;
const LoggerConfig = logger.LoggerConfig;
const LogLevel = logger.LogLevel;
const generateRequestId = logger.generateRequestId;
const initGlobal = logger.initGlobal;
const deinitGlobal = logger.deinitGlobal;
const getGlobal = logger.getGlobal;

test "Logger init and deinit" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, .{});
    defer logger_inst.deinit();
    
    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());
}

test "Logger with custom config" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, .{
        .min_level = .debug,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();
    
    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger setMinLevel" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, .{ .min_level = .info });
    defer logger_inst.deinit();
    
    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());
    
    logger_inst.setMinLevel(.debug);
    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger request ID management" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, .{});
    defer logger_inst.deinit();
    
    // Initially no request ID
    try std.testing.expectEqual(@as(?[]const u8, null), logger_inst.getRequestIdString());
    
    // Set a request ID
    const id = generateRequestId();
    logger_inst.setRequestId(id);
    
    const id_str = logger_inst.getRequestIdString();
    try std.testing.expect(id_str != null);
    try std.testing.expect(std.mem.startsWith(u8, id_str.?, "REQ-"));
    
    // Clear request ID
    logger_inst.clearRequestId();
    try std.testing.expectEqual(@as(?[]const u8, null), logger_inst.getRequestIdString());
}

test "Logger generateAndSetRequestId" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, .{});
    defer logger_inst.deinit();
    
    const id = logger_inst.generateAndSetRequestId();
    const id_str = id.toString();
    
    try std.testing.expect(std.mem.startsWith(u8, id_str, "REQ-"));
    try std.testing.expectEqual(id_str.len, 24);
}

test "Logger filters by minimum level" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, .{ .min_level = .warn });
    defer logger_inst.deinit();
    
    // These should be filtered (no error, just skipped)
    try logger_inst.trace("trace message");
    try logger_inst.debug("debug message");
    try logger_inst.info("info message");
    
    // These should pass
    try logger_inst.warn("warn message");
    try logger_inst.err("error message");
}

test "Logger with JSON formatter" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initJson(allocator, .{ .min_level = .info });
    defer logger_inst.deinit();
    
    try logger_inst.info("Test JSON message");
}

test "Logger with color formatter" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initColor(allocator, .{ .min_level = .info });
    defer logger_inst.deinit();
    
    try logger_inst.info("Test color message");
    try logger_inst.err("Test error message");
}

test "Logger formatted messages" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, .{ .min_level = .debug });
    defer logger_inst.deinit();
    
    try logger_inst.debugFmt("User {s} logged in", .{"alice"});
    try logger_inst.infoFmt("Processing {d} items", .{42});
    try logger_inst.warnFmt("Low memory: {d}MB remaining", .{128});
    try logger_inst.errFmt("Failed to connect to {s}:{d}", .{ "localhost", 8080 });
}

test "Logger logWithContext" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, .{ .min_level = .info });
    defer logger_inst.deinit();
    
    try logger_inst.logWithContext(.info, "User action", "user_id=123&action=login");
}

test "Global logger" {
    const allocator = std.testing.allocator;
    initGlobal(allocator, .{ .min_level = .info });
    defer deinitGlobal();
    
    const logger_ptr = getGlobal();
    try std.testing.expect(logger_ptr != null);
    try std.testing.expectEqual(LogLevel.info, logger_ptr.?.getMinLevel());
}

test "LogLevel ordering" {
    // Verify log levels are ordered correctly for filtering
    try std.testing.expect(@intFromEnum(LogLevel.trace) < @intFromEnum(LogLevel.debug));
    try std.testing.expect(@intFromEnum(LogLevel.debug) < @intFromEnum(LogLevel.info));
    try std.testing.expect(@intFromEnum(LogLevel.info) < @intFromEnum(LogLevel.warn));
    try std.testing.expect(@intFromEnum(LogLevel.warn) < @intFromEnum(LogLevel.err));
}
