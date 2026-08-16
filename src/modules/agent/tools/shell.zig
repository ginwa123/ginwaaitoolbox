// SPDX-License-Identifier: TBD
// shell.zig — shared shell-execution core used by `bash.zig` and `pwsh.zig`.
//
// This module owns the parts of the shell-tool pipeline that are SHELL-NEUTRAL:
//   * the wire schema (`ShellInput` / `ShellOutput`) — `BashInput` / `BashOutput`
//     and `PwshInput` / `PwshOutput` are type aliases so the LLM-facing JSON
//     schema cannot drift between shells
//   * the spawn + reader-thread + byte-truncation + line-count pipeline
//   * the mandatory-timeout enforcement
//   * the background-detach path (currently bash's `nohup` idiom)
//   * the self-kill detection (shared between bash + pwsh)
//   * the URL-encoding step (swaps `"…"` → `'…'` around URLs to keep both
//     bash and PowerShell from interpreting `?` / `&` as wildcards)
//   * the XML serialisation of `ShellOutput` to the LLM-facing envelope
//
// Shell-SPECIFIC code (executable name, argv-prefix, Windows availability)
// lives in the per-shell wrappers (bash.zig, pwsh.zig). The two wrappers
// are ~80 lines each and supply ONLY:
//   * `ShellInput` is the input type — already aliased to bash / pwsh
//   * the argv-prefix (e.g. `&.{ "bash", "-c" }` or
//     `&.{ "pwsh", "-NoProfile", "-NonInteractive", "-Command" }`)
//   * the bash/pwsh-specific `AgentTool` schema (tool name, description,
//     example commands)
//
// Cross-platform: shell.zig is POSIX-only because the process-group SIGKILL
// `std.posix.kill(-pgid, .KILL)` + `.pgid = 0` field on `std.process.Child`
// are POSIX-only primitives. The Windows guard for `bash` lives in the
// bash.zig wrapper (`if (builtin.os.tag == .windows) return error.UnsupportedOS;`).
// pwsh is NOT guarded at the wrapper — PowerShell Core ships preinstalled on
// Windows and pwsh on macOS / Linux via Homebrew / Microsoft's tarball. If
// pwsh is not on `$PATH`, the spawn fails with FileNotFound (the same shape
// of error bash gives on Windows today).

const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("nalarcore").helpers;
const schemas = @import("schemas.zig");

const selfkill = @import("bash_selfkill.zig"); // shared per D5 (bash + pwsh)
const xmlEscape = helpers.xml_escape;

/// Canonical wire schema. Per-shell wrappers (bash.zig, pwsh.zig) re-export
/// this as `BashInput` / `PwshInput` so the JSON contract is identical.
pub const ShellInput = struct {
    command: []const u8,
    mandatory_timeout: ?u32 = null,
    cwd: ?[]const u8 = null,
    max_output: ?usize = 20 * 1024,
    stdin_data: ?[]const u8 = null,
    background: bool = false,
    max_lines: ?usize = 1000,
    do_encoding: bool = false,
};

pub const ShellOutput = struct {
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    truncated: bool,
    timeout: bool,
    stdout_lines: usize = 0,
    stderr_lines: usize = 0,
    is_self: bool = false,
};

/// Returned by `execute_shell` when the caller omits `mandatory_timeout`.
/// Same semantics as the bash.zig version; shell-neutral.
pub const MandatoryTimeoutMissing = error{MandatoryTimeoutMissing};

// POSIX `nanosleep(req, rem)` — declared as `extern "c"` so the call
// doesn't go through Zig 0.16's Io runtime. We deliberately avoid
// `std.Io.sleep` here because shell.zig is invoked from the AI
// workflow, which itself runs as an `Io.Group` concurrent task. Blocking
// on `std.Io.sleep` inside that context would dead-lock the group.
// Plain `nanosleep` parks the OS thread without involving the Io runtime,
// so the rest of the group keeps making progress.
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

/// Wall-clock grace period after SIGKILL during which we wait for the
/// kernel to reap the spawned process group. 2 seconds is enough for
/// normal process groups to die and be reaped; D-state descendants
/// (uninterruptible sleep) cannot be killed by SIGKILL and will block
/// forever — the grace period caps the wait so we can return anyway.
const KILL_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

// Sentinel stub — Task 1.1 only lands the SKELETON. Subsequent tasks
// (1.2–1.7) progressively move helpers and the spawn pipeline from
// bash.zig into this module. The execute_shell body is intentionally
// a NotImplemented error until Task 1.5 lands the foreground spawn.
pub fn execute_shell(
    _allocator: std.mem.Allocator,
    _io: std.Io,
    _argv_prefix: []const []const u8,
    _input: ShellInput,
) !ShellOutput {
    // Touch every helper imported so the unused-import lint stays quiet
    // while we incrementally fill in execute_shell. Each subsequent task
    // removes the corresponding `_ = …;` line as it consumes the helper.
    _ = builtin;
    _ = selfkill;
    _ = xmlEscape;
    _ = NanoSleepTimespec;
    _ = nanosleep;
    _ = KILL_GRACE_PERIOD_NS;
    _ = _allocator;
    _ = _io;
    _ = _argv_prefix;
    _ = _input;
    return error.NotImplemented;
}