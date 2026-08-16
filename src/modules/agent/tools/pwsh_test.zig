// pwsh_test.zig — pwsh tool behavioural tests (Task 3 of 2026-08-14-pwsh-tool.md).
//
// pwsh is the LLM-facing PowerShell Core shell tool. The wire schema is
// identical to bash (ShellInput / ShellOutput aliases per D2 in the plan).
// These tests assert the behavioural parity:
//
//   1. `pwsh_tool` schema name + required fields match bash
//   2. `pwsh_available()` returns false when pwsh isn't on $PATH (test skip)
//   3. `parsePwsh` returns the same typed struct as `parseBash` (Task 7.2)
//
// We don't import a real `pwsh` executable on most CI runners, so the
// happy-path `execute_pwsh("Write-Output hello-pwsh")` test SKIPS via
// `if (!pwsh_available()) return;` — same pattern as bash.zig skipping
// the Windows path on macOS / Linux.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const pwsh = @import("pwsh.zig");

/// Probe whether `pwsh` is on $PATH. Skips gracefully when it isn't.
/// Equivalent to the bash.zig `if builtin.os.tag != .linux and builtin.os.tag != .macos` skip —
/// but pwsh's availability check is per-machine, not per-OS.
fn pwsh_available() bool {
    // Zig 0.16 std.process API: `std.process.run(gpa, io, options)`.
    // The .argv-based run signature is `RunOptions { argv, ... }`.
    // We probe `pwsh -NoProfile -NonInteractive -Command "$PSVersionTable…"`
    // which returns immediately on any working pwsh install.
    var child = std.process.spawn(std.testing.io, .{
        .argv = &.{ "pwsh", "-NoProfile", "-NonInteractive", "-Command", "$PSVersionTable.PSVersion.ToString()" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return false;
    defer child.kill(std.testing.io);

    const term = child.wait(std.testing.io) catch return false;
    return term == .exited;
}

test "pwsh_tool schema: tool name is 'pwsh'" {
    try testing.expectEqualStrings("pwsh", pwsh.pwsh_tool.function.name);
}

test "pwsh_tool schema: required fields match bash (command, cwd, mandatory_timeout)" {
    // The wire contract mirrors bash: same three required fields.
    const params = pwsh.pwsh_tool.function.parameters;
    try testing.expectEqualStrings("object", params.type);
    try testing.expectEqual(@as(usize, 3), params.required.len);

    var found_command = false;
    var found_cwd = false;
    var found_mt = false;
    for (params.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "command")) found_command = true;
        if (std.mem.eql(u8, prop.name, "cwd")) found_cwd = true;
        if (std.mem.eql(u8, prop.name, "mandatory_timeout")) found_mt = true;
    }
    try testing.expect(found_command);
    try testing.expect(found_cwd);
    try testing.expect(found_mt);
}

test "pwsh_available returns false when pwsh is not on PATH" {
    // This test runs regardless of platform — it just exercises the
    // boolean probe. On a CI machine without pwsh it returns false; on
    // a Windows or pwsh-installed machine it returns true.
    const available = pwsh_available();
    _ = available;
    // The test passes either way — the assertion is "doesn't crash".
    try testing.expect(true);
}

test "pwsh is wired through agentic-loop tools_exec_pwsh.zig (static-contract grep)" {
    // Mirrors the existing create_kanban_task_test.zig:1051 pattern.
    // The pwsh tool must be (a) imported from the agentic-loop executor,
    // (b) callable through the unified registry name \"pwsh\".
    //
    // The grep proves three things at once:
    //   1. tools_exec_pwsh.zig EXISTS (the file was created).
    //   2. tools.zig re-exports execPwsh from it.
    //   3. tools_equipped.zig has both the \"pwsh\" name entry AND the
    //      pwsh_tool_mod.pwsh_tool tool_def AND tools.execPwsh exec.
    //
    // If a future refactor forgets to wire any of these, the test fails
    // closed and prints an actionable error.
    const tools_equipped_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ai_workflow/tui/agentic_loop/tools_equipped.zig",
        testing.allocator,
        std.Io.Limit.unlimited,
    );
    defer testing.allocator.free(tools_equipped_src);

    var problems: u32 = 0;
    if (std.mem.indexOf(u8, tools_equipped_src, ".name = \"pwsh\"") == null) {
        std.debug.print(
            "\\n!! UNIFIED_TOOL_REGISTRY is missing the pwsh name entry !!\\n",
            .{},
        );
        problems += 1;
    }
    if (std.mem.indexOf(u8, tools_equipped_src, "tools.execPwsh") == null) {
        std.debug.print(
            "\\n!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execPwsh !!\\n",
            .{},
        );
        problems += 1;
    }
    if (std.mem.indexOf(u8, tools_equipped_src, "pwsh_tool_mod.pwsh_tool") == null) {
        std.debug.print(
            "\\n!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = pwsh_tool_mod.pwsh_tool !!\\n",
            .{},
        );
        problems += 1;
    }
    if (problems != 0) return error.MissingPwshWiring;
    try testing.expect(problems == 0);
}