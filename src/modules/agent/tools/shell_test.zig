const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const shell = @import("shell.zig");

test "shell.ShellInput JSON schema: same field set as BashInput (alias carries through)" {
    // shell.ShellInput is the canonical type; BashInput and PwshInput are
    // `pub const = ShellInput` aliases in their per-shell wrappers. The
    // JSON-schema parser must accept the same JSON for both names. This
    // is the "same interface" promise on the backend wire.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const json_str =
        \\{"command":"echo hi","cwd":"/tmp","mandatory_timeout":5}
    ;

    const a = try std.json.parseFromSlice(
        shell.ShellInput, testing.allocator, json_str, .{},
    );
    defer a.deinit();
    try testing.expectEqualStrings("echo hi", a.value.command);
    try testing.expectEqualStrings("/tmp", a.value.cwd.?);
    try testing.expectEqual(@as(u32, 5), a.value.mandatory_timeout.?);
}

test "shell.ShellOutput has all 9 fields the bash XML envelope uses" {
    // The bash_result_to_string envelope has: command, stdout, stderr,
    // exit_code, truncated, timeout, stdout_lines, stderr_lines, is_self.
    // ShellOutput MUST have the same 9 — pwsh_result_to_string reuses it.
    // We construct a sample instance so the type inference resolves
    // correctly; @hasField works on the inferred type only.
    const sample = shell.ShellOutput{
        .command = "",
        .stdout = "",
        .stderr = "",
        .exit_code = 0,
        .truncated = false,
        .timeout = false,
    };
    const T = @TypeOf(sample);
    try testing.expect(@hasField(T, "command"));
    try testing.expect(@hasField(T, "stdout"));
    try testing.expect(@hasField(T, "stderr"));
    try testing.expect(@hasField(T, "exit_code"));
    try testing.expect(@hasField(T, "truncated"));
    try testing.expect(@hasField(T, "timeout"));
    try testing.expect(@hasField(T, "stdout_lines"));
    try testing.expect(@hasField(T, "stderr_lines"));
    try testing.expect(@hasField(T, "is_self"));
}

test "shell.execute_shell runs bash happy path" {
    // After Task 1.5 lands the spawn pipeline, the placeholder is gone.
    // Sanity-check the wrapper: a trivial `true` should exit 0 with empty
    // stdout.
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = try shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "true",
        .cwd = "/tmp",
        .mandatory_timeout = 5,
    });
    defer {
        testing.allocator.free(out.command);
        testing.allocator.free(out.stdout);
        testing.allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expectEqualStrings("true", out.command);
}

test "shell.execute_shell enforces mandatory_timeout (returns MandatoryTimeoutMissing when null)" {
    // Smoke check that the precondition guard at the top of
    // shell.execute_shell is wired up. The plan locks this contract via
    // bash_test.zig's existing MandatoryTimeoutMissing test (kept unchanged).
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = shell.execute_shell(testing.allocator, std.testing.io, &.{ "bash", "-c" }, .{
        .command = "sleep 60",
        .cwd = "/tmp",
        .mandatory_timeout = null,
    });
    try testing.expectError(error.MandatoryTimeoutMissing, out);
}