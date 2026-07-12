const std = @import("std");
const builtin = @import("builtin");

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
    const max_output = input.max_output orelse 20 * 1024; // 20KB default
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
    // Cleanup on any early-exit path: kill the whole process group so
    // bash AND any subshells it spawned close their pipe FDs and the
    // reader threads can see EOF. `std.posix.kill` with a negative pid
    // sends to the whole group; ESRCH (group already gone) is fine.
    errdefer _ = std.posix.kill(-child_pgid, .KILL) catch {};

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
    errdefer {
        // Kill the entire process group so descendants close their pipe
        // FDs; without this the joins below hang on EOF that's never
        // delivered. See the long comment at the spawn site.
        _ = std.posix.kill(-child_pgid, .KILL) catch {};
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
                break :blk child.wait(io) catch .{ .unknown = 1 };
            }
            // Deadline reached?
            if (std.Io.Timestamp.now(io, .real).nanoseconds >= deadline_ns) {
                timeout_hit = true;
                // Kill the entire process group, not just bash — see
                // the long comment at the spawn site. Otherwise any
                // subshell bash spawned keeps the pipe FDs open and
                // the reader thread join below hangs forever.
                _ = std.posix.kill(-child_pgid, .KILL) catch {};
                // Do not call child.wait() here; kill invalidates
                // child.id. The wait happens after the threads join.
                break :blk if (builtin.os.tag == .windows)
                    .{ .unknown = 1 }
                else
                    .{ .signal = .KILL };
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

    stdout_thread.join();
    stderr_thread.join();
    if (child_term == null) {
        child_term = child.wait(io) catch .{ .unknown = 1 };
    }

    const exit_code: i32 = switch (child_term.?) {
        .exited => |code| @as(i32, @intCast(code)),
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .stopped => |code| -@as(i32, @intCast(@intFromEnum(code))),
        .unknown => -1,
    };

    // Truncate output by line count if max_lines was exceeded
    var stdout_lines_to_keep = stdout_data.items.len;
    const stdout_truncation_needed = stdout_line_count > max_lines;
    if (stdout_truncation_needed) {
        var count: usize = 0;
        for (stdout_data.items, 0..) |byte, i| {
            if (byte == '\n') {
                count += 1;
                if (count == max_lines) {
                    stdout_lines_to_keep = i + 1;
                    break;
                }
            }
        }
    }

    // Truncate stderr by line count
    var stderr_lines_to_keep = stderr_data.items.len;
    const stderr_truncation_needed = stderr_line_count > max_lines;
    if (stderr_truncation_needed) {
        var count: usize = 0;
        for (stderr_data.items, 0..) |byte, i| {
            if (byte == '\n') {
                count += 1;
                if (count == max_lines) {
                    stderr_lines_to_keep = i + 1;
                    break;
                }
            }
        }
    }

    const was_truncated = stdout_truncation_needed or stderr_truncation_needed or (stdout_data.items.len >= max_output or stderr_data.items.len >= max_output);

    // Allocate command on heap to avoid dangling pointer to stack buffer
    const command_copy = try allocator.dupe(u8, command);
    errdefer allocator.free(command_copy);

    // Return structured BashOutput instead of XML string
    // Duplicate the strings so they outlive the ArrayLists
    const stdout_copy = if (stdout_data.items.len == 0)
        try allocator.dupe(u8, "No output produced.")
    else if (stdout_truncation_needed)
        try allocator.dupe(u8, stdout_data.items[0..stdout_lines_to_keep])
    else
        try allocator.dupe(u8, stdout_data.items);
    errdefer allocator.free(stdout_copy);

    const stderr_copy = if (stderr_data.items.len == 0)
        try allocator.dupe(u8, "No errors.")
    else if (stderr_truncation_needed)
        try allocator.dupe(u8, stderr_data.items[0..stderr_lines_to_keep])
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
                    .description = "Maximum stdout+stderr bytes. Default: 20480 (20KB). Output exceeding this limit is truncated.",
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
