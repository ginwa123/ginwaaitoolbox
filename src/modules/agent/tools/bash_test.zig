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

    const expected =
        \\<command>echo "hello world"</command>
        \\<stdout>hello world
        \\</stdout>
        \\<stderr></stderr>
        \\<exit_code>0</exit_code>
        \\<truncated>false</truncated>
        \\<timeout>false</timeout>
    ;
    try std.testing.expectEqualStrings(expected, r);
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
