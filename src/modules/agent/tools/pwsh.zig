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
                    .description =
                    \\Working directory. Relative paths only (absolute paths
                    \\are rejected — security policy). Resolved against the
                    \\session's cwd (or the active git-worktree binding if
                    \\set). Omit to default to the session's cwd.
                    ,
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
            .required = &.{ "command", "mandatory_timeout" },
        },
    },
};