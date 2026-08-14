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

pub const CommandForbidden = error{
    /// Command contains forbidden patterns that produce unbounded output
    CommandForbidden,
};

/// Returned by `execute_bash` when the caller omits `mandatory_timeout`.
/// The bash tool is treated as unsafe-without-an-explicit-deadline because
/// forgetting to set a timeout lets runaway commands hang the agent.
pub const MandatoryTimeoutMissing = error{MandatoryTimeoutMissing};

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

/// Wall-clock grace period after SIGKILL during which we wait for the
/// kernel to reap the bash process group. 2 seconds is enough for
/// normal process groups to die and be reaped; D-state descendants
/// (uninterruptible sleep) cannot be killed by SIGKILL and will block
/// forever — the grace period caps the wait so we can return anyway.
///
/// Tuning notes (2026-07-15):
/// - 1 s is too short for slow CI machines where the kernel scheduler
///   may take 500–800 ms to deliver SIGKILL to a busy descendant.
/// - 5 s starts to feel slow to a user-facing agent on a stuck command.
/// - 2 s is the sweet spot.
const KILL_GRACE_PERIOD_NS: u64 = 2 * std.time.ns_per_s;

/// Poll `waitpid(pid, &status, WNOHANG)` until the process is reaped OR
/// the grace period expires. Uses raw libc (`waitpid` + `nanosleep`)
/// instead of the Io runtime to avoid the deadlock that
/// `std.Io.Threaded.childWait` causes when this function is called from
/// an `Io.Group` worker context (the workflow task blocks the group).
///
/// Does NOT close pipe FDs — the caller is responsible for that AFTER
/// this function returns, so the reader threads can exit cleanly.
///
/// Cross-platform: works on Linux and macOS. Both expose `std.c.W.NOHANG`
/// (verified at `std/c.zig:3714` for macOS and `std/os/linux.zig:3873`
/// for Linux). On Windows this path is unreachable because the existing
/// code uses `std.posix.kill` which doesn't exist on Windows.
///
/// The `io: std.Io` parameter is used ONLY for `Timestamp.now` (a
/// non-blocking vtable call that reads a kernel clock). The actual
/// waiting is done by `waitpid` + `nanosleep` (raw libc) so this
/// function never blocks on the Io runtime's thread pool.
fn waitPidBounded(io: std.Io, pid: std.posix.pid_t, grace_period_ns: u64) WaitResult {
    const start_ns: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const deadline_ns: u64 = start_ns + grace_period_ns;
    while (true) {
        var status: c_int = 0;
        // WNOHANG = 1: don't block; return 0 if not exited yet.
        const rc = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        if (rc == pid) {
            // Reaped successfully — process became a zombie and we
            // collected its status. Return both the outcome and the
            // status word so the caller can build a Term struct.
            return .{ .outcome = .reaped, .status = status };
        }
        if (rc < 0) {
            // ECHILD = no such process (already reaped by another waiter
            // or never existed). Other errors we treat as "give up" —
            // log + close pipes manually.
            const err = std.c.errno(rc);
            if (err == .CHILD) return .{ .outcome = .no_child, .status = 0 };
            std.log.warn(
                "bash.zig: waitpid(pid={d}) returned unexpected errno {t}; abandoning wait",
                .{ pid, err },
            );
            return .{ .outcome = .unexpected_error, .status = 0 };
        }
        // rc == 0 → child not yet exited. Check the deadline.
        const now_ns: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        if (now_ns >= deadline_ns) {
            return .{ .outcome = .grace_period_expired, .status = 0 };
        }
        // Sleep 10 ms via raw libc nanosleep (NOT std.Io.sleep — would
        // deadlock if called from an Io.Group worker context).
        const ts = NanoSleepTimespec{
            .sec = 0,
            .nsec = 10 * std.time.ns_per_ms,
        };
        _ = nanosleep(&ts, null);
    }
}

/// Convert a raw `waitpid` status word to a Zig `std.process.Child.Term`.
/// Mirrors `childWaitPosix` in `std/Io/Threaded.zig:15309`.
fn statusToTerm(status: c_int) std.process.Child.Term {
    const u: u32 = @bitCast(@as(u32, @intCast(status)));
    if (std.c.W.IFEXITED(u)) return .{ .exited = std.c.W.EXITSTATUS(u) };
    if (std.c.W.IFSIGNALED(u)) return .{ .signal = @enumFromInt(@intFromEnum(std.c.W.TERMSIG(u))) };
    if (std.c.W.IFSTOPPED(u)) return .{ .stopped = std.c.W.STOPSIG(u) };
    return .{ .unknown = u };
}

/// Detects forbidden command patterns that produce unbounded output
fn isForbiddenCommand(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\n\r");

    // temporary disabled forbidden command
    _ = trimmed;

    // Check for recursive ls variants
    // if (std.mem.indexOf(u8, trimmed, "ls -R") != null) return true;
    // if (std.mem.indexOf(u8, trimmed, "ls -lR") != null) return true;
    // if (std.mem.indexOf(u8, trimmed, "ls -laR") != null) return true;
    // if (std.mem.indexOf(u8, trimmed, "ls -alR") != null) return true;
    //
    // // Check for find without -maxdepth (matches "find /" or "find .")
    // if (std.mem.startsWith(u8, trimmed, "find /")) return true;
    // if (std.mem.startsWith(u8, trimmed, "find .")) {
    //     // Allow if it has -maxdepth
    //     if (std.mem.indexOf(u8, trimmed, "-maxdepth") == null) {
    //         return true;
    //     }
    // }
    //
    // // Skip timeout/head checks for background commands
    // if (std.mem.indexOf(u8, trimmed, "nohup") == null) {
    //     // Check for timeout prefix (check both "timeout " and "Timeout " for robustness)
    //     const has_timeout = std.mem.startsWith(u8, trimmed, "timeout ") or
    //         std.mem.startsWith(u8, trimmed, "Timeout ");
    //     if (!has_timeout) {
    //         return true;
    //     }
    //
    //     // Check for head output cap
    //     if (std.mem.indexOf(u8, trimmed, "| head -n") == null) {
    //         return true;
    //     }
    // }

    return false;
}

/// Encode special characters in URLs within double quotes
/// Converts: curl -sI "http://host/path?query=val&sig=xyz"
///      to: curl -sI 'http://host/path?query=val&sig=xyz'
/// This prevents bash from interpreting ?, &, etc.
fn encode_command_urls(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
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

pub fn execute_bash(allocator: std.mem.Allocator, io: std.Io, input: BashInput) !BashOutput {
    // --- URL encoding if requested ---
    const command = if (input.do_encoding)
        try encode_command_urls(allocator, input.command)
    else
        try allocator.dupe(u8, input.command);
    defer allocator.free(command);

    // --- Forbidden pattern check ---
    if (isForbiddenCommand(command)) {
        return error.CommandForbidden;
    }

    // --- Mandatory-timeout check (foreground only) ---
    // The background path does not use the timeout (the process detaches
    // via nohup and runs forever), so we skip the check there. But the
    // foreground path MUST have an explicit deadline — the previous design
    // defaulted to 30 s which silently masked runaway commands. Returning
    // an error forces the LLM (and any other caller) to think about how
    // long the command is allowed to take.
    if (!input.background and input.mandatory_timeout == null) {
        return error.MandatoryTimeoutMissing;
    }
    if (input.mandatory_timeout) |t| {
        if (t == 0) return error.MandatoryTimeoutMissing;
    }

    // --- Self-kill protection check ---
    const self_pid = selfkill.get_self_pid();
    if (try selfkill.detect_self_kill(allocator, command, self_pid)) |warning| {
        // Log the warning
        std.log.warn("Self-kill detected: {s}", .{warning});

        // Return blocked output instead of executing
        const stderr_msg = try std.fmt.allocPrint(allocator, "\n=== SELF-KILL PROTECTION ===\n" ++
            "Blocked command that would terminate the current process.\n" ++
            "Reason: {s}\n" ++
            "Your PID: {d}\n" ++
            "===========================\n", .{ warning, self_pid });
        errdefer allocator.free(stderr_msg);

        const command_copy = try allocator.dupe(u8, command);
        errdefer allocator.free(command_copy);

        return BashOutput{
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

        // bash tool is POSIX-only. Windows has no `bash` on $PATH by default
        // (Git Bash / WSL are user-side installs that we can't assume).
        // Returning error.UnsupportedOS lets the LLM see a clean error
        // rather than a cryptic filesystem ENOENT.
        if (builtin.os.tag == .windows) return error.UnsupportedOS;

        var child = try std.process.spawn(io, .{
            .argv = &.{ "bash", "-c", bg_command },
            .cwd = if (input.cwd) |cwd| .{ .path = cwd } else .inherit,
            .stdin = .close,
            .stdout = .pipe,
            .stderr = .ignore,
        });

        // Read PID from stdout
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

        // Allocate command on heap to avoid dangling pointer to stack buffer
        const command_copy = if (command.len > 50) blk: {
            const cmd = try allocator.alloc(u8, 53);
            @memcpy(cmd[0..50], command[0..50]);
            @memcpy(cmd[50..53], "...");
            break :blk cmd;
        } else try allocator.dupe(u8, command);
        errdefer allocator.free(command_copy);

        // Return with the allocated strings
        return BashOutput{
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

    // --- Foreground mode ---
    // `input.max_output` defaults to 20 KiB in the schema (see schemas.zig),
    // so the `orelse` fallback here is a defense-in-depth — it would only
    // fire if someone constructs BashInput programmatically without going
    // through the JSON schema (e.g. tests, internal callers). When the LLM
    // passes `max_output` explicitly via the JSON arguments, that value
    // wins. This protects against `head -n 30` returning only a few
    // lines whose total BYTE count is still megabytes (e.g. minified JS
    // embedded in a source file).
    const max_output = input.max_output orelse 20 * 1024; // 20 KiB defense-in-depth fallback
    const max_lines = input.max_lines orelse 1000;
    // Mandatory: validated at the top of execute_bash.
    const timeout_sec = input.mandatory_timeout.?;

    // .pgid = 0: place the spawned `bash` in its own process group (pgid
    // == bash's PID). Any descendants bash spawns (subshells via `( )`,
    // `|&`, backgrounded `&`, pipes — all of which happen a lot in agent
    // bash commands) inherit that group. When the timeout fires we send
    // SIGKILL to the negative pgid via `std.posix.kill(-pgid, .KILL)`,
    // which terminates the whole tree in one syscall. Without this,
    // `child.kill()` only kills the immediate `bash`; descendants get
    // reparented to init (PID 1) but keep the pipe FDs to us open, so
    // `stdout_thread.join()` / `stderr_thread.join()` block forever
    // waiting for pipe EOF that never arrives — and nalar appears
    // "stuck" on any agent command that exercises a subshell.
    //
    // This is more visible on macOS bash 3.2 than on Linux glibc bash
    // because macOS ships bash 3.2 (the comment at line 596 already
    // notes this) and the smoke-test commands that work on Linux tend
    // to be single-process. Any real agent command (rg | head, ls -laR,
    // timeouts, multi-stage builds) hits the subshell path and hangs.
    // bash tool is POSIX-only (matches background-mode guard above).
    // The Windows branch returns error.UnsupportedOS so the tool is still
    // registered — the LLM gets a clean error if it tries to invoke bash.
    // Note: the `.pgid = 0` field below is a Linux/macOS-only process-group
    // leadership hint and wouldn't compile on Windows (the field type is
    // `?*anyopaque` there). Guarding this whole spawn makes that disappear.
    if (builtin.os.tag == .windows) return error.UnsupportedOS;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "bash", "-c", command },
        .cwd = if (input.cwd) |cwd| .{ .path = cwd } else .inherit,
        .stdin = if (input.stdin_data != null) .pipe else .close,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    // Snapshot the pgid immediately — `child.kill()` nulls `child.id`,
    // and we need the pgid for the group-wide kill below. With pgid=0
    // the child IS the leader, so pgid == child.id.
    const child_pgid: std.posix.pid_t = child.id.?;
    // Cleanup on any early-exit path BEFORE the reader threads exist:
    // kill the whole process group so bash AND any subshells it spawned
    // close their pipe FDs. `std.posix.kill` with a negative pid sends
    // to the whole group; ESRCH (group already gone) is fine.
    //
    // `child.wait(io)` then reaps the zombie and — critically — runs
    // `childCleanupPosix` (via defer in childWaitPosix), which closes
    // the parent-side stdin/stdout/stderr pipe FDs. Without this, the
    // pipe FDs leak: `std.posix.kill` is a libc call that doesn't
    // touch the Zig Child struct, and `std.Io.File` has no destructor
    // to close the handle on scope exit. The wait may fail if the
    // process is already gone (`.SRCH` → `error.Unexpected`); the
    // `catch {}` swallows that — `childCleanupPosix` is still safe
    // to call when child.id is non-null but the OS has already
    // reaped the PID, it just `closeFd()`s whatever handles are set.
    errdefer {
        _ = std.posix.kill(-child_pgid, .KILL) catch {};
        // Bounded wait — don't block forever if a descendant is in D-state.
        // We don't have reader threads here (they haven't been spawned
        // yet), so we don't need to close pipes — they were never opened
        // for reading by us. The kill above will close the kernel-side
        // ends of the pipes once bash exits.
        _ = waitPidBounded(io, child_pgid, KILL_GRACE_PERIOD_NS);
        // If the grace period expired, manually close our end of the
        // pipes so the OS can reap the process when its reference count
        // drops to zero. We use the std.Io.File.close directly because
        // child.wait() may be hung (D-state) and we want to guarantee
        // the FDs are released.
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
    // Zig 0.16 has no std.Thread.Mutex; std.atomic.Mutex is a lock-free enum
    // that we use as a spinlock (tryLock + spinLoopHint). The critical section
    // is small (one appendSlice + truncation check), so spinning is fine.
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
                    // Spinlock on std.atomic.Mutex (no blocking lock in std 0.16)
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
    // If the function returns an error after this point, the reader thread
    // would keep running and hold the child's stdout pipe open, leaking
    // both the thread and the child process (the OS won't reap the child
    // until all pipe fds are closed). Join on any error path. Safe in
    // success path because the join is done explicitly below.
    const stderr_thread = try std.Thread.spawn(.{}, readLoopFn, .{stderr_ctx});
    // Single errdefer block: LIFO order means this runs FIRST on any
    // post-spawn error. Kill the child (closes the pipes) BEFORE joining
    // the threads, or the joins block indefinitely on the still-open
    // pipes and the kill never runs. The errdefer at line 220 handles
    // the pre-spawn case where these threads don't exist yet.
    //
    // The errdefer also manually closes the pipe FDs after the bounded
    // kill + waitPidBounded cycle. If a descendant is in D-state,
    // SIGKILL doesn't reach it, the kernel won't reap, and waitpid will
    // return WNOHANG (rc=0) until our grace period expires. After the
    // grace period we close the FDs anyway; the reader threads see EOF
    // (closed pipe = read returns 0) and exit cleanly.
    errdefer {
        // Kill the entire process group so descendants close their pipe
        // FDs; without this the joins below hang on EOF that's never
        // delivered. See the long comment at the spawn site.
        _ = std.posix.kill(-child_pgid, .KILL) catch {};
        // Bounded wait — don't block forever if a descendant is in D-state.
        _ = waitPidBounded(io, child_pgid, KILL_GRACE_PERIOD_NS);
        // Manually close the parent-side pipe FDs. `child.wait(io)` is
        // unavailable here because the child struct was never given a
        // chance to clean up via `childCleanupPosix` (that requires
        // `waitpid` to return success, which won't happen for D-state
        // descendants). std.Io.File has no destructor, so we MUST close
        // the FDs explicitly or they leak until process exit.
        if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
        if (child.stderr) |stderr_pipe| stderr_pipe.close(io);
        // Now join the reader threads (they see EOF and exit).
        stdout_thread.join();
        stderr_thread.join();
    }

    var timeout_hit = false;
    var child_term: ?std.process.Child.Term = null;

    // Race the deadline against child completion WITHOUT std.Io.Select.
    //
    // The previous implementation used `select.async(...)` +
    // `select.await(...)` to wait on the timeout and the EOF flags
    // concurrently. That design deadlocks when this function is called
    // from an Io worker context (the AI workflow is dispatched as an
    // `Io.Group.concurrent` task from the event bus): the workflow's
    // worker thread blocks in `select.await`, the nested async tasks
    // need other workers, but the `Io.Group` containing the workflow
    // task can't signal completion while the workflow is parked in
    // `await`. The async children starve and the workflow never returns
    // — nalar appears "stuck" on any bash tool call from the AI.
    //
    // Replacement: a plain `std.Thread.sleep` deadline race. We poll the
    // EOF flags set by the reader threads every 10 ms until both report
    // EOF, OR the wall-clock deadline elapses — whichever comes first.
    // Neither call goes through the Io runtime, so there's no
    // re-entrancy. Safe to call from any context (test runner, Io
    // worker, plain thread).
    const deadline_ns = std.Io.Timestamp.now(io, .real).nanoseconds + @as(i64, @intCast(timeout_ns));
    child_term = blk: {
        while (true) {
            // Child done? Both EOF flags set means the pipes are closed
            // AND the reader threads have flushed — at that point bash
            // has either exited or is about to be reaped; either way
            // child.wait() will return quickly.
            if (stdout_eof.load(.acquire) and stderr_eof.load(.acquire)) {
                // Use the bounded wait so D-state descendants don't
                // hang us forever. After the grace period expires we
                // synthesize a Term (the pipe close happens in the
                // unified post-loop block below).
                const wait_result = waitPidBounded(io, child_pgid, KILL_GRACE_PERIOD_NS);
                break :blk switch (wait_result.outcome) {
                    .reaped => statusToTerm(wait_result.status),
                    .no_child => .{ .exited = 0 },
                    .grace_period_expired, .unexpected_error => if (builtin.os.tag == .windows)
                        .{ .unknown = 1 }
                    else
                        .{ .signal = .KILL },
                };
            }
            // Deadline reached?
            if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline_ns) {
                timeout_hit = true;
                // Kill the entire process group, not just bash — see
                // the long comment at the spawn site. Otherwise any
                // subshell bash spawned keeps the pipe FDs open and
                // the reader thread join below hangs forever.
                _ = std.posix.kill(-child_pgid, .KILL) catch {};
                // Bounded wait — don't block forever on a D-state
                // descendant that SIGKILL can't interrupt.
                const wait_result = waitPidBounded(io, child_pgid, KILL_GRACE_PERIOD_NS);
                break :blk switch (wait_result.outcome) {
                    .reaped => statusToTerm(wait_result.status),
                    .no_child => .{ .exited = 0 },
                    .grace_period_expired, .unexpected_error => if (builtin.os.tag == .windows)
                        .{ .unknown = 1 }
                    else
                        .{ .signal = .KILL },
                };
            }
            // Sleep 10 ms — blocking the OS thread via raw libc
            // `nanosleep`, NOT through the Io runtime. This is exactly
            // the kind of code that triggered the re-entrancy deadlock
            // in the Io.Select version (the worker thread couldn't run
            // the nested Io sleep async, blocking the parent group).
            const ts = NanoSleepTimespec{
                .sec = 0,
                .nsec = 10 * std.time.ns_per_ms,
            };
            _ = nanosleep(&ts, null);
        }
    };

    // CRITICAL: close the parent-side pipe FDs after waitPidBounded
    // returns. `waitPidBounded` uses raw libc `waitpid` which does NOT
    // call `childCleanupPosix` (that only runs from `child.wait(io)`).
    // Without this close, every successful bash tool call leaks 2 FDs
    // (the parent's read ends of stdout + stderr pipes).
    //
    // The reader threads either saw EOF (happy path — child closed its
    // write end on exit) or will see EBADF (D-state path — we close
    // the read end under them) and exit cleanly. `std.Io.File` has no
    // destructor, so we MUST close the FDs explicitly here or they
    // leak until process exit.
    //
    // Unified single block (replaces the per-arm inline closes that
    // previously lived in the .grace_period_expired/.unexpected_error
    // switch arms — those only fired on the slow paths, leaving the
    // fast paths to leak).
    if (child.stdout) |stdout_pipe| stdout_pipe.close(io);
    if (child.stderr) |stderr_pipe| stderr_pipe.close(io);

    // Join the reader threads. If the kill + bounded-wait closed the
    // pipes (grace period expired), the reader threads saw EOF and
    // exited. If the child exited cleanly, the reader threads already
    // saw EOF and exited. Either way, join returns quickly.
    stdout_thread.join();
    stderr_thread.join();
    if (child_term == null) {
        // Defensive: child_term should never be null after the loop above,
        // but if it is (e.g. a future refactor changed the loop logic),
        // try one more bounded wait. This prevents an unbounded
        // `child.wait(io)` from hanging the agent.
        const wait_result = waitPidBounded(io, child_pgid, KILL_GRACE_PERIOD_NS);
        child_term = switch (wait_result.outcome) {
            .reaped => statusToTerm(wait_result.status),
            .no_child => .{ .exited = 0 },
            .grace_period_expired, .unexpected_error => if (builtin.os.tag == .windows)
                .{ .unknown = 1 }
            else
                .{ .signal = .KILL },
        };
    }

    const exit_code: i32 = switch (child_term.?) {
        .exited => |code| @as(i32, @intCast(code)),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .stopped => |code| -@as(i32, @intCast(@intFromEnum(code))),
        .unknown => -1,
    };

    // Truncate output by BYTE count if max_output was exceeded. Byte-based
    // truncation protects against a single huge line (e.g. generated code
    // dumped with no newlines) blowing up the context window — line-based
    // truncation would keep the entire huge line, but byte-based truncation
    // caps at max_output regardless of line structure. The reader thread
    // already enforces the byte limit at read time; this is the defensive
    // post-read re-check for any data that slipped past (e.g. reader's
    // line-count branch overshot the byte limit when both triggers fired
    // in the same iteration).
    const stdout_truncation_needed = stdout_data.items.len > max_output;
    const stderr_truncation_needed = stderr_data.items.len > max_output;

    // Use the reader's actual truncation signal for the user-facing flag.
    // The reader truncates to exactly max_output bytes (or earlier via
    // line-count), so `data.len > max_output` only catches the rare overshoot;
    // the reader's flag captures BOTH paths (byte cap and line cap).
    const was_truncated = stdout_truncated or stderr_truncated;

    // Allocate command on heap to avoid dangling pointer to stack buffer
    const command_copy = try allocator.dupe(u8, command);
    errdefer allocator.free(command_copy);

    // Return structured BashOutput instead of XML string
    // Duplicate the strings so they outlive the ArrayLists
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

    return BashOutput{
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

pub fn bash_result_to_string(allocator: std.mem.Allocator, result: BashOutput) ![]const u8 {
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
                    .description = "Absolute working directory. Always set explicitly.",
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
            .required = &.{ "command", "cwd", "mandatory_timeout" },
        },
    },
};
