const std = @import("std");
const bashMod = @import("bash.zig");
const BashInput = @import("models.zig").BashInput;
const BashOutput = @import("models.zig").BashOutput;

test "bash execute helloworld" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "echo \"hello world\"",
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "hello world") != null);
    try std.testing.expectEqual(r.exit_code, 0);
    try std.testing.expectEqual(r.timeout, false);
}

test "bash execute non-zero exit code" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "exit 42",
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(r.exit_code, 42);
    try std.testing.expectEqual(r.timeout, false);
}

test "bash execute long command truncated in output" {
    const allocator = std.testing.allocator;
    const long_cmd = "echo " ++ "x" ** 250;

    const input = BashInput{
        .command = long_cmd,
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(r.command.len > 53);
    try std.testing.expect(std.mem.indexOf(u8, r.command, "...") != null);
}

test "bash execute bun --version" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "bun --version",
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(r.exit_code, 0);
    try std.testing.expect(r.stdout.len > 0);
}

test "bash execute python3 print" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "python3 -c \"print('hello from python')\"",
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "hello from python") != null);
    try std.testing.expectEqual(r.exit_code, 0);
}

test "bash execute node --version" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "node --version",
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "v") != null);
    try std.testing.expectEqual(r.exit_code, 0);
}

test "bash execute python error" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "python3 -c \"raise Exception('test error')\"",
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "test error") != null);
    try std.testing.expectEqual(r.exit_code, 1);
}

test "bash execute sleep command" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "sleep 0.5 && echo done",
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "done") != null);
    try std.testing.expectEqual(r.exit_code, 0);
}

test "bash timeout test" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "sleep 10 && echo done",
        .timeout = 1,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(r.timeout, true);
    try std.testing.expect(r.exit_code != 0);
}

test "bash timeout with python sleep" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "python3 -c \"import time; time.sleep(15); print('done')\"",
        .timeout = 2,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(r.timeout, true);
}

test "bash stdin closed" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "python3 -c \"input(); print('got input')\"",
        .timeout = 2,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(r.exit_code != 0);
}

test "bash stdin with data" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "python3 -c \"x = input(); print(f'got: {x}')\"",
        .timeout = 5,
        .cwd = null,
        .max_output = null,
        .stdin_data = "hello world",
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "got: hello world") != null);
    try std.testing.expectEqual(r.exit_code, 0);
}

test "bash pipe with multiple stages" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "printf 'line1\\nline2\\nline3\\n' | grep line | wc -l",
        .timeout = 5,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "3") != null);
    try std.testing.expectEqual(r.exit_code, 0);
}

test "bash pipe with slow producer respects timeout" {
    const allocator = std.testing.allocator;
    // This tests the poll-based timeout with a pipe that produces data slowly
    // The command outputs one line every 0.5s, but we timeout after 1s
    const input = BashInput{
        .command = "for i in 1 2 3 4 5; do echo $i; sleep 0.5; done",
        .timeout = 1,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // Should timeout before completing all 5 iterations
    try std.testing.expectEqual(r.timeout, true);
}

test "bash timeout with complex pipe command" {
    const allocator = std.testing.allocator;
    // Simulates command like: zig build test 2>&1 | tail -100
    // Uses a long-running command with pipe that should timeout
    const input = BashInput{
        .command = "for i in $(seq 1 100); do echo \"line $i\"; sleep 0.1; done | tail -50",
        .timeout = 2,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // Should timeout before completing all 100 iterations (would take ~10s)
    try std.testing.expectEqual(r.timeout, true);
}

test "bash timeout with continuous output and pipe" {
    const allocator = std.testing.allocator;
    // Tests that timeout works even when command produces continuous output
    // This simulates a build command that outputs a lot and pipes through tail
    const input = BashInput{
        .command = "seq 1 10000 | while read i; do echo \"output line $i\"; sleep 0.01; done | tail -100",
        .timeout = 1,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // Should timeout - the full command would take ~100 seconds
    try std.testing.expectEqual(r.timeout, true);
}

test "bash timeout with stderr redirect and pipe" {
    const allocator = std.testing.allocator;
    // Tests the exact pattern: command 2>&1 | tail -N
    const input = BashInput{
        .command = "for i in $(seq 1 50); do echo \"stdout $i\"; echo \"stderr $i\" >&2; sleep 0.1; done 2>&1 | tail -20",
        .timeout = 2,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // Should timeout before completing
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "stdout") != null or std.mem.indexOf(u8, r.stderr, "stdout") != null);
    try std.testing.expect(r.timeout == true);
}

test "bash background basic" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "sleep 5 && echo done",
        .cwd = "/tmp",
        .background = true,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // Should return PID and log path
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "PID:") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "Log:") != null);
    try std.testing.expectEqual(r.exit_code, 0);
    try std.testing.expectEqual(r.timeout, false);
}

test "bash background log file" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "echo hello_from_background",
        .cwd = "/tmp",
        .background = true,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // Extract log path from stdout - find "Log: " and extract everything after it
    const log_start = std.mem.indexOf(u8, r.stdout, "Log: ") orelse return error.TestExpectedFound;
    const log_path = std.mem.trim(u8, r.stdout[log_start + 5..], " \n\r");

    // Give a moment for the file to be written
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Read log file and verify content
    const log_file = try std.fs.openFileAbsolute(log_path, .{});
    defer log_file.close();
    const log_content = try log_file.readToEndAlloc(allocator, 4096);
    defer allocator.free(log_content);

    try std.testing.expect(std.mem.indexOf(u8, log_content, "hello_from_background") != null);
}

test "bash background long running" {
    const allocator = std.testing.allocator;
    // Start a long-running background process
    const input = BashInput{
        .command = "for i in 1 2 3 4 5; do echo \"count $i\"; sleep 1; done",
        .cwd = "/tmp",
        .background = true,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    // Should return immediately with PID
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "PID:") != null);
    try std.testing.expectEqual(r.exit_code, 0);
}
