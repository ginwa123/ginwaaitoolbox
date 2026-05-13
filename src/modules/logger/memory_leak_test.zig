const std = @import("std");
const logger = @import("Logger.zig");
const Logger = logger.Logger;
const LogLevel = logger.LogLevel;

test "Logger init and deinit - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());
}

test "Logger custom config - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .debug,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger setMinLevel - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try std.testing.expectEqual(LogLevel.info, logger_inst.getMinLevel());

    logger_inst.setMinLevel(.debug);
    try std.testing.expectEqual(LogLevel.debug, logger_inst.getMinLevel());
}

test "Logger basic logging - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{ .min_level = .debug });
    defer logger_inst.deinit();

    try logger_inst.log(.debug, "Debug message");
    try logger_inst.log(.info, "Info message");
    try logger_inst.log(.warn, "Warning message");
    try logger_inst.log(.err, "Error message");
}

test "Logger with request ID - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    const id = logger_inst.generateAndSetRequestId();
    const id_str = id.toString();
    try std.testing.expect(std.mem.startsWith(u8, id_str, "REQ-"));

    try logger_inst.log(.info, "With request ID");
    try std.testing.expect(logger_inst.getRequestIdString() != null);
}

test "Logger log with context - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.init(allocator, std.testing.io, .{});
    defer logger_inst.deinit();

    try logger_inst.logWithContext(.info, "User action", "user_id=123&action=login");
}

test "Logger JSON formatter - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initJson(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "JSON test message");
}

test "Logger color formatter - no memory leak" {
    const allocator = std.testing.allocator;
    var logger_inst = Logger.initColor(allocator, std.testing.io, .{ .min_level = .info });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Color test message");
    try logger_inst.log(.err, "Color error message");
}

test "Logger file output - no memory leak" {
    const allocator = std.testing.allocator;
    const test_log_path = "/tmp/test_logger_output.log";

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test file output message");
}

test "Logger file rotation - no memory leak" {
    const allocator = std.testing.allocator;
    const test_log_path = "/tmp/test_logger_rotation.log";

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .max_file_size_bytes = 100,
        .enable_auto_rotation = true,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "First message that is long enough to trigger rotation soon");
    try logger_inst.log(.info, "Second message that should cause rotation");
    try logger_inst.log(.info, "Third message after rotation");
}

test "Logger both output mode - no memory leak" {
    const allocator = std.testing.allocator;
    const test_log_path = "/tmp/test_logger_both.log";

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .both,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test both output mode");
}

test "Logger directory creation - no memory leak" {
    const allocator = std.testing.allocator;
    const test_dir = "/tmp/test_logger_nested_dir";
    const test_log_path = test_dir ++ "/nested/log.txt";

    var logger_inst = Logger.init(allocator, std.testing.io, .{
        .min_level = .info,
        .log_file_path = test_log_path,
        .output_mode = .file,
        .include_timestamp = false,
        .include_request_id = false,
    });
    defer logger_inst.deinit();

    try logger_inst.log(.info, "Test directory creation");
}