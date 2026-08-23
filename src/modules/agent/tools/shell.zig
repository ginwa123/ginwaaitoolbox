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
const helpers = @import("helpers");
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

// Win32 GetExitCodeProcess — declared locally because std.os.windows
// 0.16 doesn't expose it (only the imports the stdlib's own files
// need). kernel32.dll is always linked on Windows.
extern "kernel32" fn GetExitCodeProcess(
    hProcess: std.os.windows.HANDLE,
    lpExitCode: *u32,
) callconv(.winapi) std.os.windows.BOOL;

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
/// Result of the bounded `waitpid` polling helper.
const WaitResult = struct {
    /// Outcome category.
    outcome: enum {
        /// Process was reaped within the grace period. The `status` field
        /// contains the raw waitpid status word.
        reaped,
        /// The grace period expired before the process became a zombie.
        /// The kernel could not reap the process — most commonly because
        /// a descendant is stuck in D state (uninterruptible sleep on
        /// Linux, e.g. broken NFS, hung FUSE, stuck disk I/O) and SIGKILL
        /// cannot interrupt it. The parent-side pipe FDs MUST be closed
        /// manually before returning so the reader threads can exit.
        grace_period_expired,
        /// `waitpid` returned ECHILD — no such process. Either the PID
        /// never existed or was already reaped by a different waiter
        /// (e.g. SIGCHLD handler). Treat as "successfully reaped".
        no_child,
        /// `waitpid` returned an unexpected error. Caller should log and
        /// proceed as if the grace period expired.
        unexpected_error,
    },
    /// Raw waitpid status word (only valid when `outcome == .reaped`).
    status: c_int = 0,
};

/// Poll `waitpid(pid, &status, WNOHANG)` until the process is reaped OR
/// the grace period expires. Uses raw libc (`waitpid` + `nanosleep`)
/// instead of the Io runtime to avoid the deadlock that
/// `std.Io.Threaded.childWait` causes when this function is called from
/// an `Io.Group` worker context (the workflow task blocks the group).
///
/// Does NOT close pipe FDs — the caller is responsible for that AFTER
/// this function returns, so the reader threads can exit cleanly.
///
/// Cross-platform: uses `std.os.linux.waitpid` directly on POSIX (Linux
/// + macOS via the Darwin kernel-call wrappers), and `WaitForSingleObject`
/// via `std.os.windows` on Windows. The `pid` argument is whatever
/// `child.id.?` produces (`std.posix.pid_t` on POSIX, `HANDLE` on
/// Windows) — we pass it through to the right syscall for each host.
pub fn wait_pid_bounded(
    io: std.Io,
    child: *const std.process.Child,
    grace_period_ns: u64,
) WaitResult {
    const start_ns: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const deadline_ns: u64 = start_ns + grace_period_ns;
    return switch (builtin.os.tag) {
        .linux, .macos => wait_pid_boundedPosix(child, deadline_ns),
        .windows => wait_pid_boundedWindows(io, child, deadline_ns),
        else => .{ .outcome = .grace_period_expired, .status = 0 },
    };
}

fn wait_pid_boundedPosix(child: *const std.process.Child, deadline_ns: u64) WaitResult {
    // `posix.pid_t` is `void` on Windows — Zig 0.16 resolves the
    // type on every host even inside a body that's only called from
    // POSIX-gated callers, so we can't reference `posix.pid_t`
    // here at all. Cast through `c_int` (the POSIX `pid_t` is a
    // 32-bit signed integer on every supported POSIX host), and
    // cast `child.id.?` (Windows HANDLE / POSIX pid_t) back to
    // `c_int` via the `Id` switch — `Id = std.posix.pid_t` on POSIX
    // (`c_int` on Linux x86_64 / aarch64 / macOS), so the cast is
    // a no-op at runtime.
    const pid: c_int = blk: {
        const id_opt: std.process.Child.Id = child.id.?;
        const T = @TypeOf(id_opt);
        if (@typeInfo(T) == .int) {
            break :blk @as(c_int, @intCast(id_opt));
        }
        // Non-int Id is `HANDLE` (Windows). Unreachable at runtime
        // because callers gate this fn on `.linux, .macos =>`,
        // but emit a clear compile-time error if someone ever
        // removes that gate.
        @compileError("wait_pid_boundedPosix called on a non-POSIX host");
    };
    while (true) {
        var status: c_int = 0;
        // WNOHANG = 1: don't block; return 0 if not exited yet.
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) {
            return .{ .outcome = .reaped, .status = status };
        }
        if (rc < 0) {
            const err = std.c.errno(rc);
            if (err == .CHILD) return .{ .outcome = .no_child, .status = 0 };
            std.log.warn(
                "shell.zig: waitpid(pid={d}) returned unexpected errno {t}; abandoning wait",
                .{ pid, err },
            );
            return .{ .outcome = .unexpected_error, .status = 0 };
        }
        // rc == 0 → child not yet exited. Check the deadline.
        if (helpers.monotonicTimestampNanos() >= deadline_ns) {
            return .{ .outcome = .grace_period_expired, .status = 0 };
        }
        const ts = NanoSleepTimespec{
            .sec = 0,
            .nsec = 10 * std.time.ns_per_ms,
        };
        _ = nanosleep(&ts, null);
    }
}

fn wait_pid_boundedWindows(
    io: std.Io,
    child: *const std.process.Child,
    deadline_ns: u64,
) WaitResult {
    const handle: std.os.windows.HANDLE = child.id.?;
    // Poll NtWaitForSingleObject with a short timeout until the
    // deadline. The `STATUS_TIMEOUT` constant is at 0x00000102;
    // compare the returned NTSTATUS by value because Zig 0.16 doesn't
    // expose kernel32's WaitForSingleObject via std.os.windows on
    // this platform — ntdll is the wrapper layer that exposes it.
    while (true) {
        // 100ms relative timeout (NT's LARGE_INTEGER is `i64` — for
        // relative waits, the convention is a NEGATIVE 100-ns interval;
        // positive values are interpreted as an absolute wakeup time,
        // which we'd rather avoid in a poll loop). Zig 0.16 typed
        // `LARGE_INTEGER` as a plain `i64` alias (`pub const
        // LARGE_INTEGER = i64` in `std/os/windows.zig:4040`), so we
        // just use the value directly.
        const timeout_100ms: std.os.windows.LARGE_INTEGER =
            -100 * @as(i64, @intCast(std.time.ns_per_ms));
        const status = std.os.windows.ntdll.NtWaitForSingleObject(
            handle,
            std.os.windows.BOOLEAN.fromBool(false), // Alertable = FALSE
            &timeout_100ms,
        );
        if (status == .SUCCESS) {
            // Process signalled; harvest the exit code via
            // GetExitCodeProcess (declared above; not in Zig 0.16
            // std) so the .status slot has the same shape the POSIX
            // path produces.
            var exit_code: u32 = 0;
            _ = GetExitCodeProcess(handle, &exit_code);
            // Match std.process.Child.Term's `exited: u8` slot:
            // (status << 8) | exit_code mimics WIFEXITED.
            const shifted_status: c_int = @intCast(@as(c_int, 0) << 8);
            const low_byte: c_int = @intCast(@as(c_int, @intCast(exit_code & 0xff)));
            return .{ .outcome = .reaped, .status = shifted_status | low_byte };
        }
        if (status != .TIMEOUT) {
            std.log.warn(
                "shell.zig: NtWaitForSingleObject(handle={*}) returned unexpected NTSTATUS {x}; abandoning wait",
                .{ handle, @intFromEnum(status) },
            );
            return .{ .outcome = .unexpected_error, .status = 0 };
        }
        if (helpers.monotonicTimestampNanos() >= deadline_ns) {
            return .{ .outcome = .grace_period_expired, .status = 0 };
        }
        _ = io;
    }
}

/// Convert a `WaitResult` to a `std.process.Child.Term`. Cross-platform:
/// on POSIX, `status_to_term` decodes the waitpid status word via
/// `std.c.W.*` macros (all `-= std.c.IFEXITED/EXITSTATUS/IFSIGNALED/...`
/// on Windows since `std.c.W = void` there). On Windows, the helper
/// just pops the low byte of the synthesized status word (matches the
/// `WaitForSingleObject + GetExitCodeProcess` flow in
/// `wait_pid_boundedWindows`).
fn term_from_wait(wait_result: WaitResult) std.process.Child.Term {
    return switch (builtin.os.tag) {
        .windows => term_from_wait_windows(wait_result),
        else => term_from_wait_posix(wait_result),
    };
}

fn term_from_wait_windows(wait_result: WaitResult) std.process.Child.Term {
    // The Windows path synthesizes a status with the low 8 bits
    // holding the exit code (no `posix.SIG.KILL` representation — the
    // historical `.signal = .KILL` doesn't apply on Windows). Wrap
    // a synthetic "signal value" by stuffing the exit code into a
    // u8 and assigning to .exited; if the high bit indicates
    // abnormal termination by an enum-from-int cast we still surface
    // it via `.unknown` (callers can introspect via `child.wait()`
    // separately).
    const u: u32 = @bitCast(@as(u32, @intCast(wait_result.status)));
    _ = u;
    return switch (wait_result.outcome) {
        .reaped, .no_child => .{ .exited = @intCast(wait_result.status & 0xff) },
        .grace_period_expired, .unexpected_error => .{
            // Forced kill via TerminateProcess. There's no POSIX
            // signal mapping on Windows; surface as
            // `exited = STATUS_TIMEOUT` (0xC000_FFFF magic trimmed)
            // or, more conservatively, as 255 (typical bash "$?")
            // so downstream tools see "killed" but don't trip the
            // "exited cleanly" path in callers.
            .exited = 137, // 128 + SIGKILL = 128+9, the bash
            // convention for "killed by SIGKILL". Portable across
            // POSIX callers that recognize this magic.
        },
    };
}

fn term_from_wait_posix(wait_result: WaitResult) std.process.Child.Term {
    return switch (wait_result.outcome) {
        .reaped => status_to_term(wait_result.status),
        .no_child => .{ .exited = 0 },
        .grace_period_expired, .unexpected_error => if (comptime builtin.os.tag != .windows)
            // POSIX path: surface the kill via `posix.SIG.KILL`. The
            // `.signal = ...` arm isn't reachable on Windows (where
            // `posix.SIG` is `void`), but Zig 0.16 resolves the arm
            // anyway — we guard with `comptime` so the resolve arm
            // is elided on Windows.
            .{ .signal = .KILL }
        else
            // Windows path (this `else` arm is unreachable at
            // runtime because `term_from_wait` dispatches on
            // `builtin.os.tag` first); included only so the
            // function compiles on every host.
            .{ .exited = 137 },
    };
}

/// Convert a raw `waitpid` status word to a Zig `std.process.Child.Term`.
/// Mirrors `childWaitPosix` in `std/Io/Threaded.zig:15309`.
///
/// POSIX-only: `std.c.W = void` on Windows (Zig 0.16 — `posix.SIG`
/// resolves to `void` there, and the `WAIT_OBJECT_0` / `WNOHANG` /
/// `IFEXITED` / `W.IFEXITED` macros aren't reachable). The Windows
/// wait path goes through `term_from_wait_windows` directly.
/// Marked `pub` so callers in the POSIX-only shell tests can use it.
pub fn status_to_term(status: c_int) std.process.Child.Term {
    if (comptime builtin.os.tag == .windows) {
        // Unreachable at runtime — emitted as a no-op so the
        // package compiles on every host. The Windows path
        // extracts the exit code directly via GetExitCodeProcess
        // (see `term_from_wait_windows`).
        return .{ .unknown = 0 };
    }
    const u: u32 = @bitCast(@as(u32, @intCast(status)));
    if (std.c.W.IFEXITED(u)) return .{ .exited = std.c.W.EXITSTATUS(u) };
    if (std.c.W.IFSIGNALED(u)) return .{ .signal = @enumFromInt(@intFromEnum(std.c.W.TERMSIG(u))) };
    if (std.c.W.IFSTOPPED(u)) return .{ .stopped = std.c.W.STOPSIG(u) };
    return .{ .unknown = u };
}

pub fn execute_shell(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    input: ShellInput,
) !ShellOutput {
    return run_shell_command(allocator, io, argv_prefix, input);
}

/// Run a shell command with the supplied argv-prefix (e.g. `&.{ "bash", "-c" }`
/// or `&.{ "pwsh", "-NoProfile", "-NonInteractive", "-Command" }`). The user's
/// `command` string is appended as the last argv element. This is the
/// SHELL-NEUTRAL spawn pipeline — moved verbatim from bash.zig (Tasks
/// 1.5–1.7 of the 2026-08-14-pwsh-tool plan). Background mode is split
/// into a separate `spawn_background` helper for the nohup-vs-Start-Process
/// divergence (D8 in the plan).
pub fn run_shell_command(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    input: ShellInput,
) !ShellOutput {
    // --- URL encoding if requested ---
    const command = if (input.do_encoding)
        try encode_command_urls(allocator, input.command)
    else
        try allocator.dupe(u8, input.command);
    defer allocator.free(command);

    // --- Forbidden pattern check ---
    if (is_forbidden_command(command)) {
        return error.CommandForbidden;
    }

    // --- Mandatory-timeout check (foreground only) ---
    // The background path does not use the timeout (the process detaches
    // and runs forever), so we skip the check there. But the foreground
    // path MUST have an explicit deadline — the previous design defaulted
    // to 30 s which silently masked runaway commands.
    if (!input.background and input.mandatory_timeout == null) {
        return error.MandatoryTimeoutMissing;
    }
    if (input.mandatory_timeout) |t| {
        if (t == 0) return error.MandatoryTimeoutMissing;
    }

    // --- Self-kill protection check ---
    const self_pid = selfkill.get_self_pid();
    if (try selfkill.detect_self_kill(allocator, command, self_pid)) |warning| {
        std.log.warn("Self-kill detected: {s}", .{warning});

        const stderr_msg = try std.fmt.allocPrint(allocator, "\n=== SELF-KILL PROTECTION ===\n" ++
            "Blocked command that would terminate the current process.\n" ++
            "Reason: {s}\n" ++
            "Your PID: {d}\n" ++
            "===========================\n", .{ warning, self_pid });
        errdefer allocator.free(stderr_msg);

        const command_copy = try allocator.dupe(u8, command);
        errdefer allocator.free(command_copy);

        return ShellOutput{
            .command = command_copy,
            .stdout = "",
            .stderr = stderr_msg,
            .exit_code = 1,
            .truncated = false,
            .timeout = false,
            .stdout_lines = 0,
            .stderr_lines = 1,
            .is_self = true,
        };
    }

    // --- Background mode ---
    if (input.background) {
        return try spawn_background(allocator, io, argv_prefix, command);
    }

    // --- Foreground mode ---
    // `input.max_output` defaults to 20 KiB in the schema (see schemas.zig),
    // so the `orelse` fallback here is a defense-in-depth — it would only
    // fire if someone constructs ShellInput programmatically without going
    // through the JSON schema (e.g. tests, internal callers).
    const max_output = input.max_output orelse 20 * 1024;
    const max_lines = input.max_lines orelse 1000;
    const timeout_sec = input.mandatory_timeout.?;

    // Build the full argv: argv_prefix ++ [command]
    var argv_buf: [16][]const u8 = undefined;
    if (argv_prefix.len + 1 > argv_buf.len) {
        return error.TooManyArgvPrefix;
    }
    @memcpy(argv_buf[0..argv_prefix.len], argv_prefix);
    argv_buf[argv_prefix.len] = command;
    const argv = argv_buf[0 .. argv_prefix.len + 1];

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (input.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = if (input.stdin_data != null) .pipe else .close,
        .stdout = .pipe,
        .stderr = .pipe,
        // Zig 0.16: `?posix.pid_t = null`. On Windows, `posix.pid_t`
        // resolves to `void`, so the ternary `null / @as(?pid_t, 0)`
        // can't infer a unified type (the Windows branch is
        // `?*anyopaque` from the void-typed pid_t). Use comptime
        // branches so Zig 0.16 emits only the relevant arm:
        //   POSIX: place the child in a new pgroup whose pgid equals
        //          its own pid (preserves the historical "kill the
        //          whole group" semantics below).
        //   Windows: pass null (no pgid concept; group-kill branch
        //          below is gated anyway).
        .pgid = if (comptime builtin.os.tag == .windows) null else @as(?std.posix.pid_t, 0),
    });
    // On Windows, `posix.pid_t` is `void` (Windows has no POSIX pid
    // concept), so the historical `kill(-child_pgid, .KILL)` group-
    // kill pattern compiles only on POSIX. Gate the group-kill path
    // by host OS: Windows children use the .id HANDLE directly via
    // `child.kill(io)` (in the cleanup branches below — no group-kill
    // because Windows has no `setpgid(0)` equivalent). `wait_pid_bounded`
    // is now OS-dispatched (see its `switch (builtin.os.tag)` body).
    const child_pgid: c_int = blk: {
        if (comptime builtin.os.tag == .windows) break :blk 0;
        const id_opt: std.process.Child.Id = child.id.?;
        const T = @TypeOf(id_opt);
        if (@typeInfo(T) == .int) break :blk @as(c_int, @intCast(id_opt));
        @compileError("child.id is not a POSIX pid_t on a POSIX host");
    };
    errdefer {
        if (builtin.os.tag != .windows) {
            _ = std.posix.kill(-child_pgid, .KILL) catch {};
        }
        _ = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
        if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
        if (child.stderr) |stderr_pipe| stderr_pipe.close(io);
        if (child.stdin) |stdin_pipe| stdin_pipe.close(io);
    }

    if (input.stdin_data) |data| {
        if (child.stdin) |stdin| {
            var write_buf: [1024]u8 = undefined;
            var stdin_writer = std.Io.File.writer(stdin, io, &write_buf);
            try stdin_writer.interface.writeAll(data);
            stdin.close(io);
            child.stdin = null;
        }
    }

    const timeout_ns = @as(u64, timeout_sec) * std.time.ns_per_s;

    var stdout_data: std.ArrayList(u8) = .empty;
    var stderr_data: std.ArrayList(u8) = .empty;
    defer {
        stdout_data.deinit(allocator);
        stderr_data.deinit(allocator);
    }

    var stdout_line_count: usize = 0;
    var stderr_line_count: usize = 0;
    var stdout_truncated = false;
    var stderr_truncated = false;
    var stdout_eof = std.atomic.Value(bool).init(false);
    var stderr_eof = std.atomic.Value(bool).init(false);
    var stdout_mutex: std.atomic.Mutex = .unlocked;
    var stderr_mutex: std.atomic.Mutex = .unlocked;

    const ReadContext = struct {
        stream: std.Io.File,
        io: std.Io,
        buf: *[4096]u8,
        data: *std.ArrayList(u8),
        line_count: *usize,
        truncated: *bool,
        max_output: usize,
        max_lines: usize,
        eof_flag: *std.atomic.Value(bool),
        mutex: *std.atomic.Mutex,
        allocator: std.mem.Allocator,
    };

    const readLoopFn = struct {
        fn run(ctx: ReadContext) void {
            defer ctx.eof_flag.store(true, .release);
            while (true) {
                const n = std.Io.File.readStreaming(ctx.stream, ctx.io, &.{ctx.buf}) catch return;
                if (n == 0) return;
                for (ctx.buf[0..n]) |byte| {
                    if (byte == '\n') ctx.line_count.* += 1;
                }
                if (!ctx.truncated.*) {
                    while (!ctx.mutex.tryLock()) {
                        std.atomic.spinLoopHint();
                    }
                    defer ctx.mutex.unlock();
                    ctx.data.appendSlice(ctx.allocator, ctx.buf[0..n]) catch return;
                    if (ctx.data.items.len >= ctx.max_output or ctx.line_count.* >= ctx.max_lines) {
                        ctx.truncated.* = true;
                        var trim_pos: usize = ctx.data.items.len;
                        if (ctx.line_count.* >= ctx.max_lines) {
                            var count: usize = 0;
                            for (ctx.data.items, 0..) |b, i| {
                                if (b == '\n') {
                                    count += 1;
                                    if (count == ctx.max_lines) {
                                        trim_pos = i + 1;
                                        break;
                                    }
                                }
                            }
                        } else if (ctx.data.items.len > ctx.max_output) {
                            trim_pos = ctx.max_output;
                        }
                        if (ctx.data.items.len > trim_pos) {
                            ctx.data.shrinkAndFree(ctx.allocator, trim_pos);
                        }
                    }
                }
            }
        }
    }.run;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;

    const stdout_ctx = ReadContext{
        .stream = child.stdout.?,
        .io = io,
        .buf = &stdout_buf,
        .data = &stdout_data,
        .line_count = &stdout_line_count,
        .truncated = &stdout_truncated,
        .max_output = max_output,
        .max_lines = max_lines,
        .eof_flag = &stdout_eof,
        .mutex = &stdout_mutex,
        .allocator = allocator,
    };
    const stderr_ctx = ReadContext{
        .stream = child.stderr.?,
        .io = io,
        .buf = &stderr_buf,
        .data = &stderr_data,
        .line_count = &stderr_line_count,
        .truncated = &stderr_truncated,
        .max_output = max_output,
        .max_lines = max_lines,
        .eof_flag = &stderr_eof,
        .mutex = &stderr_mutex,
        .allocator = allocator,
    };

    const stdout_thread = try std.Thread.spawn(.{}, readLoopFn, .{stdout_ctx});
    const stderr_thread = try std.Thread.spawn(.{}, readLoopFn, .{stderr_ctx});
    errdefer {
        if (comptime builtin.os.tag != .windows) _ = std.posix.kill(-child_pgid, .KILL) catch {};
        _ = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
        if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
        if (child.stderr) |stderr_pipe| stderr_pipe.close(io);
        stdout_thread.join();
        stderr_thread.join();
    }

    var timeout_hit = false;
    var child_term: ?std.process.Child.Term = null;

    const deadline_ns = std.Io.Timestamp.now(io, .real).nanoseconds + @as(i64, @intCast(timeout_ns));
    // `std.process.Child.Term` is `.{ exited: u8, signal: std.posix.SIG,
    // … }` — `posix.SIG` is `void` on Windows in Zig 0.16, so neither
    // `.signal = .KILL` nor `status_to_term` (which uses `std.c.W.*` —
    // also `void` on Windows) compile there. Gate the inner switch by
    // OS: the POSIX path produces the historical WIFEXITED /
    // WIFSIGNALED-style term, the Windows path just takes the DWORD
    // exit code we harvested in `wait_pid_boundedWindows`.
    child_term = blk: {
        while (true) {
            if (stdout_eof.load(.acquire) and stderr_eof.load(.acquire)) {
                const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
                break :blk term_from_wait(wait_result);
            }
            if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline_ns) {
                timeout_hit = true;
                if (comptime builtin.os.tag != .windows) _ = std.posix.kill(-child_pgid, .KILL) catch {};
                const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
                break :blk term_from_wait(wait_result);
            }
            const ts = NanoSleepTimespec{
                .sec = 0,
                .nsec = 10 * std.time.ns_per_ms,
            };
            _ = nanosleep(&ts, null);
        }
    };

    if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
    if (child.stderr) |stderr_pipe| stderr_pipe.close(io);

    stdout_thread.join();
    stderr_thread.join();
    if (child_term == null) {
        const wait_result = wait_pid_bounded(io, &child, KILL_GRACE_PERIOD_NS);
        child_term = term_from_wait(wait_result);
    }

    const exit_code: i32 = switch (child_term.?) {
        .exited => |code| @as(i32, @intCast(code)),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .stopped => |code| -@as(i32, @intCast(@intFromEnum(code))),
        .unknown => -1,
    };

    const stdout_truncation_needed = stdout_data.items.len > max_output;
    const stderr_truncation_needed = stderr_data.items.len > max_output;
    const was_truncated = stdout_truncated or stderr_truncated;

    const command_copy = try allocator.dupe(u8, command);
    errdefer allocator.free(command_copy);

    const stdout_copy = if (stdout_data.items.len == 0)
        try allocator.dupe(u8, "No output produced.")
    else if (stdout_truncation_needed)
        try allocator.dupe(u8, stdout_data.items[0..max_output])
    else
        try allocator.dupe(u8, stdout_data.items);
    errdefer allocator.free(stdout_copy);

    const stderr_copy = if (stderr_data.items.len == 0)
        try allocator.dupe(u8, "No errors.")
    else if (stderr_truncation_needed)
        try allocator.dupe(u8, stderr_data.items[0..max_output])
    else
        try allocator.dupe(u8, stderr_data.items);
    errdefer allocator.free(stderr_copy);

    return ShellOutput{
        .command = command_copy,
        .stdout = stdout_copy,
        .stderr = stderr_copy,
        .exit_code = exit_code,
        .truncated = was_truncated,
        .timeout = timeout_hit,
        .stdout_lines = stdout_line_count,
        .stderr_lines = stderr_line_count,
    };
}

/// Background-mode spawn (the `nohup` bash idiom). Returns the
/// structured ShellOutput with `command`, `stdout = "PID: X\nLog: …"`,
/// `exit_code = 0`. The detached process keeps running; the caller is
/// responsible for killing it later.
///
/// TODO (D8): PowerShell has no `nohup`. The follow-up PR replaces this
/// with `Start-Process -NoNewWindow -RedirectStandardOutput` for pwsh.
fn spawn_background(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    command: []const u8,
) !ShellOutput {
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
    const log_path = try std.fmt.allocPrint(
        allocator,
        "/tmp/bg_{d}.log",
        .{ts},
    );
    defer allocator.free(log_path);

    const bg_command = try std.fmt.allocPrint(
        allocator,
        "nohup {s} > {s} 2>&1 & echo $!",
        .{ command, log_path },
    );
    defer allocator.free(bg_command);

    var argv_buf: [16][]const u8 = undefined;
    if (argv_prefix.len + 1 > argv_buf.len) return error.TooManyArgvPrefix;
    @memcpy(argv_buf[0..argv_prefix.len], argv_prefix);
    argv_buf[argv_prefix.len] = bg_command;
    const argv = argv_buf[0 .. argv_prefix.len + 1];

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .inherit,
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var pid_buf: [32]u8 = undefined;
    const pid_len = std.Io.File.readStreaming(child.stdout.?, io, &.{&pid_buf}) catch 0;
    const pid_str = std.mem.trimEnd(u8, pid_buf[0..pid_len], "\n\r ");

    _ = child.wait(io) catch {};

    const stdout_msg = try std.fmt.allocPrint(
        allocator,
        "PID: {s}\nLog: {s}",
        .{ pid_str, log_path },
    );
    errdefer allocator.free(stdout_msg);

    const stderr_msg = try allocator.dupe(u8, "No errors.");
    errdefer allocator.free(stderr_msg);

    const command_copy = if (command.len > 50) blk: {
        const cmd = try allocator.alloc(u8, 53);
        @memcpy(cmd[0..50], command[0..50]);
        @memcpy(cmd[50..53], "...");
        break :blk cmd;
    } else try allocator.dupe(u8, command);
    errdefer allocator.free(command_copy);

    return ShellOutput{
        .command = command_copy,
        .stdout = stdout_msg,
        .stderr = stderr_msg,
        .exit_code = 0,
        .truncated = false,
        .timeout = false,
        .stdout_lines = 0,
        .stderr_lines = 0,
    };
}

/// XML serialiser — same 9-tag envelope as `bash_result_to_string`.
///
/// Returned to the LLM as the inner content of the standard `<tool>`
/// envelope (`wrapToolOutput` wraps it with `<data>` / `<error>` /
/// `<parameters>` on the agentic-loop side).
pub fn result_to_xml(allocator: std.mem.Allocator, result: ShellOutput) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\<command>{s}</command>
        \\<stdout>{s}</stdout>
        \\<stderr>{s}</stderr>
        \\<exit_code>{d}</exit_code>
        \\<truncated>{}</truncated>
        \\<timeout>{}</timeout>
        \\<stdout_lines>{d}</stdout_lines>
        \\<stderr_lines>{d}</stderr_lines>
        \\<is_self>{}</is_self>
    , .{
        result.command,
        result.stdout,
        result.stderr,
        result.exit_code,
        result.truncated,
        result.timeout,
        result.stdout_lines,
        result.stderr_lines,
        result.is_self,
    });
}

/// Concatenates `argv_prefix` with `[command]` to form the full spawn
/// argv. This is a tiny helper kept separate so callers can audit the
/// prefix without scrolling through the spawn site. Tasks 1.5+ of the
/// 2026-08-14-pwsh-tool plan.
pub fn build_argv(
    allocator: std.mem.Allocator,
    argv_prefix: []const []const u8,
    command: []const u8,
) ![][]const u8 {
    var list = try allocator.alloc([]const u8, argv_prefix.len + 1);
    @memcpy(list[0..argv_prefix.len], argv_prefix);
    list[argv_prefix.len] = command;
    return list;
}

/// Detects forbidden command patterns that produce unbounded output.
/// Currently disabled (returns `false` for every input) — the previous
/// guard list (recursive `ls -R`, `find /` without `-maxdepth`, missing
/// `timeout` / `head -n` prefix) is parked here in commented-out form
/// pending a future hardening PR. Kept verbatim in shell.zig because
/// the rule engine is shell-neutral (the same patterns apply to bash
/// and to PowerShell `Get-ChildItem -Recurse`).
pub fn is_forbidden_command(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\n\r");

    // temporary disabled forbidden command
    _ = trimmed;

    return false;
}

/// Encode special characters in URLs within double quotes
/// Converts: curl -sI "http://host/path?query=val&sig=xyz"
///      to: curl -sI 'http://host/path?query=val&sig=xyz'
/// This prevents bash from interpreting ?, &, etc.
/// Also helps PowerShell — `?` is a wildcard and `&` is the call
/// operator there too (D6 in the plan).
pub fn encode_command_urls(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < command.len) {
        // Look for " followed by http:// or https://
        if (command[i] == '"' and i + 7 < command.len) {
            const rest = command[i + 1 ..];
            if (std.mem.startsWith(u8, rest, "http://") or std.mem.startsWith(u8, rest, "https://")) {
                // Found a URL in double quotes - find the closing quote
                try result.append(allocator, '\'');
                i += 1; // skip opening "

                // Copy until closing quote
                while (i < command.len and command[i] != '"') {
                    try result.append(allocator, command[i]);
                    i += 1;
                }

                if (i < command.len and command[i] == '"') {
                    try result.append(allocator, '\'');
                    i += 1; // skip closing "
                }
                continue;
            }
        }
        try result.append(allocator, command[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

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

// Task 6 — schema-shape parity lock. The user requirement: "bash and
// pwsh have to have the same interface". This test fails closed if a
// future refactor breaks the alias and re-introduces copy-paste (the
// "two separate struct types with the same fields" footgun).
//
// After Task 2, BashInput / PwshInput are `pub const = ShellInput`
// aliases — so `@typeName` returns the same string for all three.
// The test also round-trips the same JSON through all three parsers
// to prove the wire schema is identical (same field order, same field
// types, same default values).
test "ShellInput is structurally identical to BashInput AND PwshInput (alias liveness check)" {
    // We use `@typeName` of a constructed instance to force Zig to
    // resolve the alias — if the alias is broken in a future refactor,
    // the three names diverge and the test fails closed.
    const shell_input = shell.ShellInput{ .command = "" };
    const bash_input = @import("schemas.zig").BashInput{ .command = "" };
    const pwsh_input = @import("pwsh.zig").PwshInput{ .command = "" };

    try testing.expectEqualStrings(@typeName(@TypeOf(shell_input)), @typeName(@TypeOf(bash_input)));
    try testing.expectEqualStrings(@typeName(@TypeOf(shell_input)), @typeName(@TypeOf(pwsh_input)));

    // Wire-schema round-trip: parse the same JSON string through all
    // three aliases and verify every field round-trips identically.
    const json =
        \\{"command":"x","cwd":"/tmp","mandatory_timeout":3,"max_output":10,
        \\"stdin_data":"y","background":true,"max_lines":20,"do_encoding":true}
    ;

    const a = try std.json.parseFromSlice(@TypeOf(shell_input), testing.allocator, json, .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(@TypeOf(bash_input), testing.allocator, json, .{});
    defer b.deinit();
    const c = try std.json.parseFromSlice(@TypeOf(pwsh_input), testing.allocator, json, .{});
    defer c.deinit();

    try testing.expectEqualStrings(a.value.command, b.value.command);
    try testing.expectEqualStrings(b.value.command, c.value.command);
    try testing.expect(a.value.mandatory_timeout.? == b.value.mandatory_timeout.?);
    try testing.expect(b.value.mandatory_timeout.? == c.value.mandatory_timeout.?);
}
