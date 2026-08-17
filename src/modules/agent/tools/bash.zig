const std = @import("std");
const builtin = @import("builtin");

// === Cross-platform note (2026-07-24) ===
//
// The bash tool spawns `bash -c <command>` by argv, sends signals to
// process groups via std.posix.kill(-pgid, ...), and uses other
// POSIX-only primitives (std.posix.pid_t, std.posix.kill, the .pgid
// field on std.process.Child). None of these exist on Windows in
// Zig 0.16 (`std.posix.pid_t` is `*anyopaque`, `std.posix.kill` has
// `@compileError`, `.pgid` is `?*anyopaque`).
//
// The plan §2.1 alternative of a FILE-LEVEL `@compileError("bash is
// POSIX-only")` is NOT chosen here — that would block the entire
// tool_registry.zig (and therefore workflow.zig and nalarcore) from
// compiling on Windows, because they `const bash_tool_mod =
// nalar_mod.bash_tool` at module scope. Instead we guard only the two
// spawn sites with `if (builtin.os.tag == .windows) return error.UnsupportedOS;`.
// The tool stays in the registered tool table on Windows (with its
// full schema + description so the LLM can learn about it), but invoking
// it returns a clean error rather than failing to compile.

// POSIX `nanosleep(req, rem)` — declared as `extern "c"` so the call
// doesn't go through Zig 0.16's Io runtime. We deliberately avoid
// `std.Io.sleep` here because the bash tool is invoked from the AI
// workflow, which itself runs as an `Io.Group` concurrent task. Blocking
// on `std.Io.sleep` inside that context would dead-lock the group
// (the workflow task can't make progress while a nested Io task waits
// for a worker that the blocked workflow IS). Plain `nanosleep` parks
// the OS thread without involving the Io runtime, so the rest of the
// group keeps making progress.
//
// Field names differ between libc implementations: glibc uses `tv_sec`/
// `tv_nsec`, Darwin and most BSDs use `sec`/`nsec`. We mirror the local
// `PosixTimespec` shape from helpers/mod.zig (sec/nsec) so this works
// on macOS too.
const NanoSleepTimespec = extern struct {
    sec: c_long,
    nsec: c_long,
};
extern "c" fn nanosleep(req: *const NanoSleepTimespec, rem: ?*NanoSleepTimespec) c_int;
const schemas = @import("schemas.zig");
const BashInput = schemas.BashInput;
const BashOutput = schemas.BashOutput;
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const selfkill = @import("bash_selfkill.zig");
const shell = @import("shell.zig");

pub const CommandForbidden = error{
    /// Command contains forbidden patterns that produce unbounded output
    CommandForbidden,
};

/// Returned by `execute_bash` when the caller omits `mandatory_timeout`.
/// The bash tool is treated as unsafe-without-an-explicit-deadline because
/// forgetting to set a timeout lets runaway commands hang the agent.
pub const MandatoryTimeoutMissing = error{MandatoryTimeoutMissing};

/// Result of the bounded `waitpid` polling helper. (Moved to shell.zig.)
const WaitResult = struct {
    outcome: enum { reaped, grace_period_expired, no_child, unexpected_error },
    status: c_int = 0,
};

/// Wall-clock grace period after SIGKILL during which we wait for the
/// kernel to reap the bash process group. (Moved to shell.zig.)
const KILL_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

/// Run a bash command. Cross-platform: bash is POSIX-only (returns
/// `error.UnsupportedOS` on Windows — bash is rarely on PATH there).
/// Everything else (the spawn pipeline, the reader threads, the
/// timeout race, the self-kill check, the URL-encoding step, the
/// `bash_result_to_string` formatter) lives in `shell.zig` because
/// it's shared with pwsh.
pub fn execute_bash(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: BashInput,
) !BashOutput {
    if (builtin.os.tag == .windows) return error.UnsupportedOS;
    // BashInput is a type alias for ShellInput (Task 2 of the plan) so
    // the cast is a no-op at compile time. If a future refactor breaks
    // the alias the compiler will catch it here.
    return shell.execute_shell(allocator, io, &.{ "bash", "-c" }, input);
}

/// XML serialiser — re-export from shell.zig under the bash name for
/// ergonomic callers.
pub const bash_result_to_string = shell.result_to_xml;

pub const bash_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "bash",
        .description =
        \\Execute a bash command and return:
        \\stdout, stderr, exit_code, truncated, timeout flags.
        \\
        \\## Command Rules (enforced in code)
        \\Every command MUST:
        \\- start with `timeout <seconds>`
        \\- limit output using `| head -n <N> or tail -n <N>` to prevent huge output
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
        \\The shell is `bash` on every platform. On Windows you must have
        \\`bash.exe` on PATH. The most common sources are:
        \\- [Git for Windows](https://git-scm.com/download/win) — ships Git Bash.
        \\- [WSL](https://learn.microsoft.com/windows/wsl/install) — full Linux bash.
        \\- MSYS2, Cygwin, or a manual `bash` install.
        \\If bash is not on PATH, the tool will fail with `FileNotFound` at
        \\spawn time. macOS users: stock macOS ships bash 3.2; install
        \\bash 4+ via Homebrew (`brew install bash`) for modern syntax.
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
                    \\ fd is a faster alternative to find and rg is a faster alternative to grep.
                    \\GOOD: `timeout 10 zig build 2>&1 | head -n 50`
                    \\GOOD: `timeout 10 rg 'MyStruct' src/ | head -n 50`
                    \\GOOD: `timeout 10 fd MyStruct src/ | head -n 50`
                    \\GOOD: `timeout 10 fd -e zig src/ | head -n 50`
                    \\GOOD: `timeout 5 ls -la /some/dir | head -n 30`
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
                    \\to run. When the deadline elapses the bash process is killed
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
            .required = &.{ "command", "mandatory_timeout" },
        },
    },
};
