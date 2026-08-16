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

test "shell.execute_shell skeleton returns error.NotImplemented (placeholder)" {
    // Task 1.1 — the skeleton is a stub. Subsequent tasks (1.2–1.7) replace
    // this body with the real spawn pipeline. Until then, every call must
    // surface error.NotImplemented so the test fails loudly if a future
    // task forgets to remove the placeholder.
    const result = shell.execute_shell(testing.allocator, std.testing.io, &.{"bash", "-c"}, .{
        .command = "true",
        .mandatory_timeout = 5,
    });
    try testing.expectError(error.NotImplemented, result);
}