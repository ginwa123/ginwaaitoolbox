const std = @import("std");
const bashMod = @import("bash.zig");
const BashInput = @import("models.zig").BashInput;

test "bash execute helloworld" {
    const allocator = std.testing.allocator;
    const input = BashInput{
        .command = "echo \"hello world\"",
        .timeout = null,
        .cwd = null,
        .max_output = null,
    };
    const r = try bashMod.executeBash(allocator, input);
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "<stdout>hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>0</exit_code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<timeout>false</timeout>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>42</exit_code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<timeout>false</timeout>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(r.len > 203);
    try std.testing.expect(std.mem.indexOf(u8, r, "...") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>0</exit_code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<stdout>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "hello from python") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>0</exit_code>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "v") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>0</exit_code>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "test error") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>1</exit_code>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "done") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>0</exit_code>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "<timeout>true</timeout>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "<timeout>true</timeout>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>1</exit_code>") != null or
        std.mem.indexOf(u8, r, "<exit_code>0</exit_code>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "got: hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>0</exit_code>") != null);
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
    defer allocator.free(r);

    try std.testing.expect(std.mem.indexOf(u8, r, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "<exit_code>0</exit_code>") != null);
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
    defer allocator.free(r);

    // Should timeout before completing all 5 iterations
    try std.testing.expect(std.mem.indexOf(u8, r, "<timeout>true</timeout>") != null);
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
    defer allocator.free(r);

    // Should timeout before completing all 100 iterations (would take ~10s)
    try std.testing.expect(std.mem.indexOf(u8, r, "<timeout>true</timeout>") != null);
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
    defer allocator.free(r);

    // Should timeout - the full command would take ~100 seconds
    try std.testing.expect(std.mem.indexOf(u8, r, "<timeout>true</timeout>") != null);
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
    defer allocator.free(r);

    // Should timeout before completing
    try std.testing.expect(std.mem.indexOf(u8, r, "<timeout>true</timeout>") != null);
}
