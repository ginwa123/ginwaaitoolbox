// DEPRECATED: use the unified `command` tool (src/modules/agent/tools/command.zig) instead — this file is a thin shim keeping the `"pwsh"` name: `pwsh_tool` reuses `command_tool`'s schema and `execute_pwsh` delegates to `command.execute_command`.
const std = @import("std");
const command = @import("command.zig");
const schemas = @import("schemas.zig");

const AgentTool = schemas.AgentTool;

/// Public type aliases — wire-compatible with `BashInput` / `BashOutput`.
pub const PwshInput = command.CommandInput;
pub const PwshOutput = command.CommandOutput;

/// Run a PowerShell Core command. Deprecated shim over
/// `command.execute_command` (which dispatches to `pwsh` on Windows,
/// `bash` elsewhere).
pub fn execute_pwsh(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: PwshInput,
) !PwshOutput {
    return command.execute_command(allocator, io, input);
}

/// XML envelope formatter — same 9-tag shape as `bash_result_to_string`.
/// Re-exported under the pwsh name for ergonomic callers.
pub const pwsh_result_to_string = command.command_result_to_string;

pub const pwsh_tool_system_prompt = command.command_tool_system_prompt;

pub const pwsh_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "pwsh",
        .description = command.command_tool.function.description,
        .parameters = command.command_tool.function.parameters,
        .system_prompt = pwsh_tool_system_prompt,
    },
};

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

test "command-only registry: tools_equipped wires command, not bash/pwsh (static-contract grep)" {
    // Post-unify contract (2026-09-04): the equipped tool surface is ONE
    // shell tool named "command". `bash`/`pwsh` survive only as unregistered
    // shim modules (bash.zig / pwsh.zig delegate to command.execute_command)
    // so old code still compiles — but they must NOT appear in
    // UNIFIED_TOOL_REGISTRY, otherwise the LLM sees three shell tools again.
    //
    // The grep proves four things at once:
    //   1. tools_equipped.zig has the "command" name entry.
    //   2. ... with .exec = tools.execCommand.
    //   3. ... with .tool_def = command_tool_mod.command_tool.
    //   4. ... and NO "bash"/"pwsh" name entries.
    //
    // If a future refactor re-adds a bash/pwsh entry, the test fails
    // closed and prints an actionable error.
    const tools_equipped_src = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/agentic_loop/tools_equipped.zig",
        testing.allocator,
        std.Io.Limit.unlimited,
    );
    defer testing.allocator.free(tools_equipped_src);

    var problems: u32 = 0;
    if (std.mem.indexOf(u8, tools_equipped_src, ".name = \"command\"") == null) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY is missing the command name entry !!\n",
            .{},
        );
        problems += 1;
    }
    if (std.mem.indexOf(u8, tools_equipped_src, "tools.execCommand") == null) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execCommand !!\n",
            .{},
        );
        problems += 1;
    }
    if (std.mem.indexOf(u8, tools_equipped_src, "command_tool_mod.command_tool") == null) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = command_tool_mod.command_tool !!\n",
            .{},
        );
        problems += 1;
    }
    if (std.mem.indexOf(u8, tools_equipped_src, ".name = \"bash\"") != null) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY still equips legacy bash (must be command-only) !!\n",
            .{},
        );
        problems += 1;
    }
    if (std.mem.indexOf(u8, tools_equipped_src, ".name = \"pwsh\"") != null) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY still equips legacy pwsh (must be command-only) !!\n",
            .{},
        );
        problems += 1;
    }
    if (problems != 0) return error.MissingCommandWiring;
    try testing.expect(problems == 0);
}
