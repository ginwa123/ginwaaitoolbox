// src/service/main_service_test.zig
//
// Tests for the `nalar service` subcommand parser + idempotent stop.

const std = @import("std");
const testing = std.testing;
const main_service = @import("main_service.zig");

test "parseServiceSubcommand accepts start with --port" {
    const cmd = try main_service.parseServiceSubcommand(&.{ "start", "--port", "8081" });
    try testing.expect(cmd == .start);
    try testing.expectEqual(@as(u16, 8081), cmd.start.port);
}

test "parseServiceSubcommand start defaults port to 8081" {
    const cmd = try main_service.parseServiceSubcommand(&.{"start"});
    try testing.expectEqual(@as(u16, 8081), cmd.start.port);
    try testing.expect(!cmd.start.no_static_dir);
}

test "parseServiceSubcommand rejects unknown verb" {
    const result = main_service.parseServiceSubcommand(&.{"reboot"});
    try testing.expectError(error.UnknownSubcommand, result);
}

test "parseServiceSubcommand rejects invalid --port" {
    const result = main_service.parseServiceSubcommand(&.{ "start", "--port", "notanumber" });
    try testing.expectError(error.InvalidPort, result);
}

test "parseServiceSubcommand accepts status with no args" {
    const cmd = try main_service.parseServiceSubcommand(&.{"status"});
    try testing.expect(cmd == .status);
}

test "parseServiceSubcommand rejects status with extra args" {
    const result = main_service.parseServiceSubcommand(&.{ "status", "extra" });
    try testing.expectError(error.UnknownSubcommand, result);
}

test "parseServiceSubcommand accepts stop with --graceful-timeout-ms" {
    const cmd = try main_service.parseServiceSubcommand(&.{ "stop", "--graceful-timeout-ms", "1000" });
    try testing.expectEqual(@as(u32, 1000), cmd.stop.graceful_timeout_ms);
}

test "parseServiceSubcommand accepts restart with --port and --graceful-timeout-ms" {
    const cmd = try main_service.parseServiceSubcommand(&.{
        "restart", "--port", "9999", "--graceful-timeout-ms", "2000",
    });
    try testing.expectEqual(@as(u16, 9999), cmd.restart.port);
    try testing.expectEqual(@as(u32, 2000), cmd.restart.graceful_timeout_ms);
    try testing.expect(cmd.restart.static_dir == null);
}

test "parseServiceSubcommand accepts restart --static-dir (webapp survives a restart)" {
    // Regression: the usage text advertised --static-dir for `restart` but
    // the parser rejected it with UnknownSubcommand, and main.zig never
    // forwarded the value either — so a restarted daemon silently lost its
    // webapp dir (and state.json's static_dir stayed null). The desktop's
    // webview then showed `404 Not Found` after a restart.
    const cmd = try main_service.parseServiceSubcommand(&.{
        "restart", "--port", "9999", "--static-dir", "/tmp/webapp",
    });
    try testing.expectEqualStrings("/tmp/webapp", cmd.restart.static_dir.?);
}

test "parseServiceSubcommand start keeps --static-dir" {
    const cmd = try main_service.parseServiceSubcommand(&.{
        "start", "--port", "9999", "--static-dir", "/tmp/webapp",
    });
    try testing.expectEqualStrings("/tmp/webapp", cmd.start.static_dir.?);
}

test "parseServiceSubcommand rejects empty args" {
    const result = main_service.parseServiceSubcommand(&.{});
    try testing.expectError(error.UnknownSubcommand, result);
}