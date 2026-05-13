const std = @import("std");
const logger = @import("Logger.zig");
const Logger = logger.Logger;
const LoggerConfig = logger.LoggerConfig;
const LogLevel = logger.LogLevel;
const OutputMode = logger.OutputMode;
const generateRequestId = logger.generateRequestId;

test "Logger init and deinit" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());
}

test "Logger with custom config" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .debug,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger setMinLevel" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());

    logger_inst.setMinLevel(.debug);
    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger request ID management" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
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
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    const id = logger_inst.generateAndSetRequestId();
    const id_str = id.toString();

    try std.testing.expect(std.mem.startsWith(u8, id_str, "REQ-"));
    try std.testing.expectEqual(id_str.len, 24);
}

test "Logger with JSON formatter" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initJson(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test JSON message");
}

test "Logger with color formatter" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initColor(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test color message");
    try logger_inst.log(.err, "Test error message");
}

test "Logger formatted messages" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .debug });
    defer logger_inst.deinit();

    // All formatted log methods return void (not error union)
    logger_inst.debugFmt("User {s} logged in", .{"alice"});
    logger_inst.infoFmt("Processing {d} items", .{42});
    logger_inst.warnFmt("Low memory: {d}MB remaining", .{128});
    logger_inst.errFmt("Failed to connect to {s}:{d}", .{ "localhost", 8080 });
}

test "Logger logWithContext" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.logWithContext(.info, "User action", "user_id=123&action=login");
}

test "LogLevel ordering" {
    // Verify log levels are ordered correctly for filtering
    try std.testing.expect(@intFromEnum(LogLevel.trace) < @intFromEnum(LogLevel.debug));
    try std.testing.expect(@intFromEnum(LogLevel.debug) < @intFromEnum(LogLevel.info));
    try std.testing.expect(@intFromEnum(LogLevel.info) < @intFromEnum(LogLevel.warn));
    try std.testing.expect(@intFromEnum(LogLevel.warn) < @intFromEnum(LogLevel.err));
}

// New tests for file output, rotation, and location features

test "Logger file output creates file and writes logs" {
    const allocator = std.testing.allocator;
    const test_log_path = "/tmp/test_logger_output.log";

    // Clean up any existing file
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer {
        logger_inst.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};
    }

    // Log a message
    try logger_inst.log(.info, "Test file output message");

    // Verify file was created by opening it successfully
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, test_log_path, .{});
    file.close(std.testing.io);
}

test "Logger file rotation at size limit" {
    const allocator = std.testing.allocator;
    const test_log_path = "/tmp/test_logger_rotation.log";

    // Clean up any existing file
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .max_file_size_bytes = 100, // Small limit for testing
        .enable_auto_rotation = true,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer {
        logger_inst.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};
    }

    // Write multiple messages to exceed size limit
    try logger_inst.log(.info, "First message that is long enough to trigger rotation soon");
    try logger_inst.log(.info, "Second message that should cause rotation");
    try logger_inst.log(.info, "Third message after rotation");

    // File should exist after rotation
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, test_log_path, .{});
    file.close(std.testing.io);
}

test "Logger both output mode writes to stdout and file" {
    const allocator = std.testing.allocator;
    const test_log_path = "/tmp/test_logger_both.log";

    // Clean up any existing file
    std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .both,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer {
        logger_inst.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, test_log_path) catch {};
    }

    // Log a message (goes to both stdout and file)
    try logger_inst.log(.info, "Test both output mode");

    // Verify file was created by opening it
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, test_log_path, .{});
    file.close(std.testing.io);
}

test "Logger directory creation for log file" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/test_logger_nested_dir";
    const test_log_path = test_dir ++ "/nested/log.txt";

    // Clean up any existing directory
    std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer {
        logger_inst.deinit();
        std.Io.Dir.cwd().deleteTree(std.testing.io, test_dir) catch {};
    }

    // Log a message - this should create the nested directories
    try logger_inst.log(.info, "Test directory creation");

    // Verify file was created by opening it
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, test_log_path, .{});
    file.close(std.testing.io);
}

test "Logger backward compatibility - default config works" {
    const allocator = std.testing.allocator;

    // Test that old-style config without new fields still works
    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .debug,
        .include_timestamp = true,
        .include_request_id = true,
    });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
    try logger_inst.log(.info, "Backward compatibility test");
}
