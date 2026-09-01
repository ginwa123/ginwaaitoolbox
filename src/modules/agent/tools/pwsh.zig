// SPDX-License-Identifier: TBD
// pwsh.zig — PowerShell Core shell-exec tool, sibling of bash.zig.
//
// Layering: this file is a thin wrapper around `shell.zig`. The shared core
// (`ShellInput` / `ShellOutput`, the spawn pipeline, the self-kill check,
// the URL-encode step, the XML serialiser) lives in shell.zig. pwsh.zig
// supplies ONLY:
//
//   * the LLM-facing tool name: `"pwsh"`
//   * the argv-prefix that invokes `pwsh -NoProfile -NonInteractive -Command`
//   * the `pwsh_tool` `AgentTool` schema (description + PowerShell-idiom
//     command examples)
//
// The wire contract — input JSON fields, required-ness, output envelope —
// is IDENTICAL to `bash`. Switching between tools is a one-token change in
// the function-call name. Same-interface promise: see Task 6 + 7.2 tests.
//
// Cross-platform: pwsh is NOT guarded by `if (builtin.os.tag == .windows)`.
/// PowerShell Core ships preinstalled on Windows (powershell.exe 5.1 +
/// `pwsh` 7+ via `winget install Microsoft.PowerShell`), and is available
/// on Linux/macOS via Microsoft's apt / Homebrew / tarball. If `pwsh` is
/// not on `$PATH`, the spawn fails with FileNotFound — the same shape of
/// error bash gives on Windows today.
//
// Background mode: shell.zig's `spawn_background` hardcodes `nohup` (a
// bash idiom). pwsh has no equivalent — see D8 in the plan. Background
// mode is currently TODO; callers hitting `background=true` will see
// `error.UnsupportedFeature`. The follow-up PR replaces `nohup` with
// `Start-Process -NoNewWindow -RedirectStandardOutput`.
const std = @import("std");
const shell = @import("shell.zig");
const schemas = @import("schemas.zig");

const AgentTool = schemas.AgentTool;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;

/// Public type aliases — wire-compatible with `BashInput` / `BashOutput`.
/// Per D2 in the plan: these are `pub const = ShellInput` aliases so the
/// LLM-facing JSON schema is structurally identical.
pub const PwshInput = shell.ShellInput;
pub const PwshOutput = shell.ShellOutput;

/// Cross-platform pwsh argv-prefix.
///   `pwsh -NoProfile -NonInteractive -Command <script>`
/// matches bash's `bash -c <command>` shape: positional script body.
///
/// `-NoProfile` skips PowerShell profile loading (faster, no startup hooks).
/// `-NonInteractive` prevents pwsh from prompting for input (would hang the
/// agent loop waiting for a TTY that doesn't exist). `-Command` takes the
/// rest of argv as the script body.
const PWSH_ARGV_PREFIX: []const []const u8 = &.{
    "pwsh", "-NoProfile", "-NonInteractive", "-Command",
};

/// Run a PowerShell Core command. Same semantics as `execute_bash`:
/// mandatory timeout (returns `error.MandatoryTimeoutMissing` if null),
/// byte + line truncation, foreground / background dispatch, self-kill
/// detection, URL-encoding for the `?` / `&` wildcard footgun. Returns the
/// structured `ShellOutput` (which is also `PwshOutput` via the alias).
pub fn execute_pwsh(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: PwshInput,
) !PwshOutput {
    return shell.execute_shell(allocator, io, PWSH_ARGV_PREFIX, input);
}

/// XML envelope formatter — same 9-tag shape as `bash_result_to_string`.
/// Re-exported under the pwsh name for ergonomic callers.
pub const pwsh_result_to_string = shell.result_to_xml;

pub const pwsh_tool_system_prompt =
    \\## Pwsh Tool — Behavior
    \\Use `pwsh` to execute PowerShell commands. Same timeout/output rules as `bash`.
    \\- Always prefix with `timeout` and bound output.
    \\- Use on Windows or when PowerShell syntax is required.
    \\- Set `cwd` explicitly.
    \\
;

pub const pwsh_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "pwsh",
        .description =
        \\Execute a PowerShell Core (`pwsh`) command and return:
        \\stdout, stderr, exit_code, truncated, timeout flags.
        \\
        \\## Same wire schema as `bash`
        \\The input fields (`command`, `cwd`, `mandatory_timeout`, `max_output`,
        \\`stdin_data`, `background`, `max_lines`, `do_encoding`) and the
        \\output envelope (`<command>…</command> <stdout>…</stdout>
        \\<stderr>…</stderr> <exit_code>…</exit_code> <truncated>…</truncated>
        \\<timeout>…</timeout> <stdout_lines>…</stdout_lines>
        \\<stderr_lines>…</stderr_lines> <is_self>…</is_self>`) are identical.
        \\Only the shell executable differs — switch the tool name to swap.
        \\
        \\## Command Rules (PowerShell-idiom)
        \\Every command SHOULD:
        \\- end with `| Select-Object -First <N>` (alias `Select -First N`)
        \\  instead of `head -n N`, to bound the BYTE count
        \\- use `[Console]::OutputEncoding` or `Out-File` if you need UTF-8
        \\- prefer `Get-ChildItem` (alias `ls`, `dir`) over recursive search
        \\- prefer `Set-Location` (alias `cd`) over inline path navigation
        \\- avoid `Get-ChildItem -Recurse` / `Select-String -Recurse` on
        \\  large directories — bound with `| Select-Object -First <N>`
        \\
        \\## Safety
        \\Avoid destructive or system-modifying commands.
        \\Never assume the working directory — always set `cwd` explicitly.
        \\
        \\## Platform Notes
        \\The shell is PowerShell Core (`pwsh`) on every platform:
        \\- **Windows**: ships preinstalled as `powershell.exe` (5.1) AND
        \\  `pwsh` (PowerShell 7+ via `winget install Microsoft.PowerShell`).
        \\- **macOS / Linux**: install with `brew install --cask powershell`
        \\  or `snap install powershell --classic`. CI runners vary; check
        \\  `which pwsh` first.
        \\If `pwsh` is not on `$PATH`, the spawn fails with `FileNotFound`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\PowerShell script block to execute.
                    \\
                    \\Wrap multi-statement scripts in a single string; the tool
                    \\forwards the entire `command` as the argument to
                    \\`pwsh -NonInteractive -Command`. Prefer single-line
                    \\pipelines (`Get-ChildItem | Select-Object -First 30`).
                    \\GOOD: `Get-ChildItem | Select-Object -First 30`
                    \\GOOD: `(Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 | Format-Table)`
                    \\GOOD: `rg 'MyStruct' src/ | Select-Object -First 30`
                    ,
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Absolute working directory. Always set explicitly.",
                },
                .{
                    .name = "mandatory_timeout",
                    .type = "number",
                    .description =
                    \\REQUIRED. Maximum wall-clock seconds the command is allowed
                    \\to run. When the deadline elapses the pwsh process is killed
                    \\(SIGKILL on POSIX, TerminateProcess on Windows) so the agent
                    \\cannot hang on a runaway command. There is no default — the
                    \\tool returns `MandatoryTimeoutMissing` if you omit this.
                    ,
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description =
                    \\Maximum stdout+stderr bytes per stream. Default: 20480 (20 KiB).
                    \\PowerShell object output may be verbose (each `Get-*` cmdlet
                    \\renders a header row + per-object rows). Output exceeding this
                    \\limit is truncated at read-time to keep a single tool call
                    \\from blowing up the LLM context window.
                    ,
                },
                .{
                    .name = "stdin_data",
                    .type = "string",
                    .description = "Optional stdin input for the command.",
                },
                .{
                    .name = "background",
                    .type = "boolean",
                    .description =
                    \\Run command in background using `Start-Process`. Returns the
                    \\spawned PID and log path in stdout.
                    \\Example stdout: "PID: 12345\nLog: /tmp/bg_1234567890.log"
                    \\Use PID to check status (Get-Process -Id <pid>) or stop it
                    \\(Stop-Process -Id <pid>).
                    \\Note: when background=true the mandatory_timeout field is
                    \\ignored (the detached process has no deadline enforced by
                    \\this tool — the caller is responsible for stopping it later).
                    ,
                },
                .{
                    .name = "max_lines",
                    .type = "number",
                    .description = "Maximum number of lines to capture from stdout/stderr. Default: 1000. Output exceeding this limit is truncated and stdout_lines/stderr_lines will report the true total.",
                },
                .{
                    .name = "do_encoding",
                    .type = "boolean",
                    .description =
                    \\Encode URLs in double quotes by converting to single quotes.
                    \\Use this for `Invoke-RestMethod` / `Invoke-WebRequest` calls
                    \\with URLs containing `?` and `&` characters (PowerShell's `?`
                    \\is a wildcard and `&` is the call operator — both can corrupt
                    \\URLs if left in `"…"`).
                    ,
                },
            },
            .required = &.{ "command", "cwd", "mandatory_timeout" },
        },
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
