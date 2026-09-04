// command.zig — unified shell-exec tool, merged from bash.zig + pwsh.zig.
//
// Phase A+B of the unify plan: `bash` and `pwsh` were thin wrappers over
// `shell.zig` differing ONLY in the argv-prefix (plus per-shell description
// text). This module MERGES that shared structure (moved, not duplicated):
//
//   * `CommandInput` / `CommandOutput` — aliases for `shell.ShellInput` /
//     `shell.ShellOutput`, so the LLM-facing JSON schema cannot drift.
//   * `COMMAND_BASH_PREFIX` + `COMMAND_PWSH_PREFIX` — the two argv-prefix
//     consts, moved here from bash.zig / pwsh.zig.
//   * `execute_command` — dispatches per-OS (`pwsh` on Windows, `bash`
//     elsewhere) via `shell.execute_shell`.
//   * `command_result_to_string` — the shared 9-tag XML envelope.
//   * `command_tool` — the merged `AgentTool` (name "command").
//
// `bash.zig` / `pwsh.zig` are now deprecated shims over this module.
const std = @import("std");
const builtin = @import("builtin");
const shell = @import("shell.zig");
const schemas = @import("schemas.zig");

const AgentTool = schemas.AgentTool;

/// Canonical input type — alias so the wire schema is identical to the
/// old `bash` / `pwsh` tools.
pub const CommandInput = shell.ShellInput;

/// Canonical output type — alias so the XML envelope is identical to the
/// old `bash` / `pwsh` tools.
pub const CommandOutput = shell.ShellOutput;

/// argv-prefix for the POSIX shell: `bash -c <command>`.
pub const COMMAND_BASH_PREFIX: []const []const u8 = &.{ "bash", "-c" };

/// argv-prefix for PowerShell Core:
/// `pwsh -NoProfile -NonInteractive -Command <script>`.
/// `-NoProfile` skips profile loading (faster, no startup hooks).
/// `-NonInteractive` prevents prompting for input (would hang the agent
/// loop waiting for a TTY that doesn't exist).
pub const COMMAND_PWSH_PREFIX: []const []const u8 = &.{
    "pwsh", "-NoProfile", "-NonInteractive", "-Command",
};

/// Run a shell command on the host-appropriate shell: `pwsh` on Windows,
/// `bash` everywhere else. Same semantics as the old `execute_bash` /
/// `execute_pwsh`: mandatory timeout (returns
/// `error.MandatoryTimeoutMissing` if null), byte + line truncation,
/// foreground / background dispatch, self-kill detection, URL-encoding.
pub fn execute_command(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: CommandInput,
) !CommandOutput {
    if (builtin.os.tag == .windows) {
        return shell.execute_shell(allocator, io, COMMAND_PWSH_PREFIX, input);
    } else {
        return shell.execute_shell(allocator, io, COMMAND_BASH_PREFIX, input);
    }
}

/// XML envelope formatter — same 9-tag shape as the old
/// `bash_result_to_string` / `pwsh_result_to_string`.
pub const command_result_to_string = shell.result_to_xml;

pub const command_tool_system_prompt =
    \\## Command Tool — Behavior
    \\Use `command` to execute shell commands. The host OS picks the shell automatically: `bash` on Linux/macOS, `pwsh` (PowerShell Core) on Windows.
    \\Every command MUST start with `timeout <seconds>` and bound output with `| head -n <N>` or `| tail -n <N>` (bash) or `| Select-Object -First <N>` (pwsh).
    \\- Prefer `search`/`read_file`/`glob` for code exploration over shell `rg`/`grep`/`find`.
    \\- Always set `cwd` explicitly to an absolute path. Never assume the working directory.
    \\- Use `background=true` for long-running processes; it returns PID + log path.
    \\
;

pub const command_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "command",
        .description =
        \\Execute a shell command and return:
        \\stdout, stderr, exit_code, truncated, timeout flags.
        \\
        \\## Per-OS shell dispatch (automatic — you do NOT choose)
        \\- Linux / macOS: runs `bash -c <command>`.
        \\- Windows: runs `pwsh -NoProfile -NonInteractive -Command <command>`.
        \\
        \\## Command Rules (enforced in code)
        \\Every command MUST:
        \\- start with `timeout <seconds>`
        \\- limit output using `| head -n <N> or tail -n <N>` (bash) or `| Select-Object -First <N>` (pwsh) to prevent huge output
        \\- avoid commands that produce unbounded output
        \\- use ripgrep (rg) instead of grep/find for searching
        \\- use fd for finding files (faster alternative to find/glob)
        \\- use tree for directory structure
        \\## Web Browsing
        \\To browse the web or fetch URLs, use the `agent-browser` CLI:
        \\
        \\## Safety
        \\Avoid destructive or system-modifying commands.
        \\Never assume the working directory — always set cwd explicitly.
        \\
        \\## Platform Notes
        \\The shell is `bash` on Linux/macOS and PowerShell Core (`pwsh`) on
        \\Windows. On Windows `pwsh` ships preinstalled (powershell.exe 5.1 +
        \\`pwsh` 7+ via `winget install Microsoft.PowerShell`); on macOS /
        \\Linux install with `brew install --cask powershell` or
        \\`snap install powershell --classic` if the Windows path ever runs
        \\there. If the shell executable is not on PATH, the spawn fails
        \\with `FileNotFound` at spawn time.
        \\
        \\## Argument Type Coercion (lenient)
        \\Numeric fields (`mandatory_timeout`, `max_output`, `max_lines`)
        \\accept either a JSON number or a numeric string. A stray
        \\trailing `</fieldname>` is auto-stripped (e.g.
        \\`"5</mandatory_timeout>"` → 5) — this commonly happens when
        \\the model accidentally echoes back a fragment of a previous
        \\tool envelope. On a real type mismatch the tool returns
        \\`invalid field '<name>': got JSON value "<verbatim>", expected <type>`
        \\so you can self-correct on the next turn. Boolean fields
        \\accept JSON bool or the strings `"true"` / `"false"`.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "command",
                    .type = "string",
                    .description =
                    \\Command to execute.
                    \\
                    \\On bash hosts: `timeout 10 zig build 2>&1 | head -n 50`.
                    \\On pwsh hosts: `Get-ChildItem | Select-Object -First 30`.
                    \\GOOD (bash): `timeout 10 rg 'MyStruct' src/ | head -n 50`
                    \\GOOD (bash): `timeout 10 fd MyStruct src/ | head -n 50`
                    \\GOOD (pwsh): `Get-ChildItem | Select-Object -First 30`
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
                    \\to run. When the deadline elapses the shell process is killed
                    \\(SIGKILL on POSIX, TerminateProcess on Windows) so the agent
                    \\cannot hang on a runaway command. There is no default — the
                    \\tool returns `MandatoryTimeoutMissing` if you omit this.
                    \\Pick a value that matches what the command realistically
                    \\needs (a few seconds for ls/cat, 30–60 s for builds,
                    \\300+ s for long compilations).
                    ,
                },
                .{
                    .name = "max_output",
                    .type = "number",
                    .description =
                        \\Maximum stdout+stderr bytes per stream. Default: 20480 (20 KiB).
                        \\Output exceeding this limit is truncated at read-time
                        \\to keep a single tool call from blowing up the LLM
                        \\context window. Set this explicitly when you need more
                        \\(e.g. when running `cat` on a large file or `head -n 1`
                        \\of a minified file where each line can exceed 20 KiB).
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
                    \\Run command in background using nohup.
                    \\Returns PID and log path in stdout.
                    \\Example stdout: "PID: 12345\nLog: /tmp/bg_1234567890.log"
                    \\Use PID to check status (ps -p <PID>) or kill (kill <PID>).
                    \\Note: when background=true the mandatory_timeout field is
                    \\ignored (the detached process has no deadline enforced by
                    \\this tool — the caller is responsible for killing it later).
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
                    \\Use this for curl/wget commands with URLs containing ? and & characters.
                    \\Example: curl -sI "https://host/path?query=val&sig=xyz" will become curl -sI 'https://host/path?query=val&sig=xyz'
                    ,
                },
            },
            .required = &.{ "command", "cwd", "mandatory_timeout" },
        },
        .system_prompt = command_tool_system_prompt,
    },
};

// ============================================================================
// Inline tests — schema shape (existing bash/pwsh tests are NOT duplicated
// here; bash_test.zig + the pwsh.zig inline tests keep covering the shim
// path).
// ============================================================================

const testing = std.testing;
const command = @import("command.zig");

test "command_tool schema: tool name is 'command'" {
    try testing.expectEqualStrings("command", command.command_tool.function.name);
}

test "command_tool schema: required fields are (command, cwd, mandatory_timeout)" {
    const params = command.command_tool.function.parameters;
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

test "CommandInput is the same type as ShellInput (alias liveness check)" {
    const command_input = command.CommandInput{ .command = "" };
    const shell_input = shell.ShellInput{ .command = "" };
    try testing.expectEqualStrings(@typeName(@TypeOf(command_input)), @typeName(@TypeOf(shell_input)));

    const json =
        \\{"command":"x","cwd":"/tmp","mandatory_timeout":3,"max_output":10,
        \\"stdin_data":"y","background":true,"max_lines":20,"do_encoding":true}
    ;
    const a = try std.json.parseFromSlice(@TypeOf(command_input), testing.allocator, json, .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(@TypeOf(shell_input), testing.allocator, json, .{});
    defer b.deinit();
    try testing.expectEqualStrings(a.value.command, b.value.command);
    try testing.expect(a.value.mandatory_timeout.? == b.value.mandatory_timeout.?);
}

test "command argv prefixes have the expected shape" {
    try testing.expectEqual(@as(usize, 2), command.COMMAND_BASH_PREFIX.len);
    try testing.expectEqualStrings("bash", command.COMMAND_BASH_PREFIX[0]);
    try testing.expectEqualStrings("-c", command.COMMAND_BASH_PREFIX[1]);
    try testing.expectEqual(@as(usize, 4), command.COMMAND_PWSH_PREFIX.len);
    try testing.expectEqualStrings("pwsh", command.COMMAND_PWSH_PREFIX[0]);
    try testing.expectEqualStrings("-NoProfile", command.COMMAND_PWSH_PREFIX[1]);
    try testing.expectEqualStrings("-NonInteractive", command.COMMAND_PWSH_PREFIX[2]);
    try testing.expectEqualStrings("-Command", command.COMMAND_PWSH_PREFIX[3]);
}

test "command.execute_command runs on the host shell (bash off-Windows)" {
    if (builtin.os.tag == .windows) return;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;

    const out = try command.execute_command(testing.allocator, std.testing.io, .{
        .command = "echo hello-command",
        .cwd = "/tmp",
        .mandatory_timeout = 5,
    });
    defer {
        testing.allocator.free(out.command);
        testing.allocator.free(out.stdout);
        testing.allocator.free(out.stderr);
    }
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expect(std.mem.indexOf(u8, out.stdout, "hello-command") != null);
}
