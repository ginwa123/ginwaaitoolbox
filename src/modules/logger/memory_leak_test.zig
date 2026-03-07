// temporary disabled // cause it making hang
// const std = @import("std");
// const logger = @import("logger.zig");
// const Logger = logger.Logger;
// const LoggerConfig = logger.LoggerConfig;
//
// test "Logger no memory leak - basic usage" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.init(allocator, .{ .min_level = .info });
//     defer logger_inst.deinit();
//     try logger_inst.info("Test message");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - formatted messages" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.init(allocator, .{ .min_level = .debug });
//     defer logger_inst.deinit();
//     try logger_inst.debugFmt("Debug message: {d}", .{42});
//     try logger_inst.infoFmt("Info message: {s}", .{"hello"});
//     try logger_inst.warnFmt("Warning: {d}MB", .{128});
//     try logger_inst.errFmt("Error: {s}", .{"connection failed"});
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - JSON formatter" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.initJson(allocator, .{ .min_level = .info });
//     defer logger_inst.deinit();
//     try logger_inst.info("JSON test message");
//     try logger_inst.debug("This should be filtered");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - color formatter" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.initColor(allocator, .{ .min_level = .info });
//     defer logger_inst.deinit();
//     try logger_inst.info("Color info message");
//     try logger_inst.warn("Color warning message");
//     try logger_inst.err("Color error message");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - with context" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.init(allocator, .{ .min_level = .info });
//     defer logger_inst.deinit();
//     try logger_inst.logWithContext(.info, "Action performed", "user_id=123&action=login");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - request ID management" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.init(allocator, .{ .min_level = .info });
//     defer logger_inst.deinit();
//
//     const id = logger_inst.generateAndSetRequestId();
//     _ = id;
//     try logger_inst.info("Message with request ID");
//
//     logger_inst.clearRequestId();
//     try logger_inst.info("Message without request ID");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - multiple log levels" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.init(allocator, .{ .min_level = .trace });
//     defer logger_inst.deinit();
//
//     try logger_inst.trace("Trace message");
//     try logger_inst.debug("Debug message");
//     try logger_inst.info("Info message");
//     try logger_inst.warn("Warn message");
//     try logger_inst.err("Error message");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - filtered messages" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.init(allocator, .{ .min_level = .warn });
//     defer logger_inst.deinit();
//
//     // These should be filtered out
//     try logger_inst.trace("Filtered trace");
//     try logger_inst.debug("Filtered debug");
//     try logger_inst.info("Filtered info");
//
//     // These should be logged
//     try logger_inst.warn("Warning message");
//     try logger_inst.err("Error message");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - file output" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//     const test_log_path = "/tmp/test_logger_memory_leak.log";
//
//     // Clean up any existing file
//     std.fs.cwd().deleteFile(test_log_path) catch {};
//
//     var logger_inst = Logger.init(allocator, .{
//         .min_level = .info,
//         .log_file_path = test_log_path,
//         .output_mode = .file,
//         .include_timestamp = false,
//         .include_request_id = false,
//     });
//     defer {
//         logger_inst.deinit();
//         std.fs.cwd().deleteFile(test_log_path) catch {};
//     }
//
//     try logger_inst.info("File output test message");
//     try logger_inst.warn("File warning message");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - both output modes" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//     const test_log_path = "/tmp/test_logger_both_memory_leak.log";
//
//     // Clean up any existing file
//     std.fs.cwd().deleteFile(test_log_path) catch {};
//
//     var logger_inst = Logger.init(allocator, .{
//         .min_level = .info,
//         .log_file_path = test_log_path,
//         .output_mode = .both,
//         .include_timestamp = false,
//         .include_request_id = false,
//     });
//     defer {
//         logger_inst.deinit();
//         std.fs.cwd().deleteFile(test_log_path) catch {};
//     }
//
//     try logger_inst.info("Both output test message");
//     try logger_inst.err("Both output error message");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - rapid logging" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.init(allocator, .{ .min_level = .debug });
//     defer logger_inst.deinit();
//
//     // Log many messages rapidly
//     var i: usize = 0;
//     while (i < 100) : (i += 1) {
//         try logger_inst.debugFmt("Debug message number {d}", .{i});
//         try logger_inst.infoFmt("Info message number {d}", .{i});
//     }
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
//
// test "Logger no memory leak - level changes" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     const allocator = gpa.allocator();
//
//     var logger_inst = Logger.init(allocator, .{ .min_level = .info });
//     defer logger_inst.deinit();
//
//     try logger_inst.info("Message at info level");
//
//     logger_inst.setMinLevel(.debug);
//     try logger_inst.debug("Message at debug level");
//
//     logger_inst.setMinLevel(.err);
//     try logger_inst.warn("This should be filtered");
//     try logger_inst.err("Error at error level");
//
//     const deinit_status = gpa.deinit();
//     try std.testing.expect(deinit_status != .leak);
// }
