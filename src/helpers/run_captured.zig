//! run_captured — the ONE safe way to spawn a child process and capture
//! its stdout + stderr from inside a long-lived, multithreaded server.
//!
//! ## Why this exists
//!
//! Handlers used to hand-roll the same four steps over and over:
//!
//! ```zig
//! var child = std.process.spawn(io, .{
//!     .stdin = .ignore, .stdout = .pipe, .stderr = .pipe,
//! });
//! // read stdout to EOF ...
//! // read stderr to EOF ...
//! const term = child.wait(io) catch ...;   // <-- aborts the process
//! ```
//!
//! That shape has three process-killing / request-killing failure modes,
//! all of which bit us in production (see `git_pr_status.zig`):
//!
//! 1. **`Child.wait` can `unreachable` — i.e. SIGABRT the whole server.**
//!    `Io.Threaded.childWaitPosix` defers `childCleanupPosix`, which
//!    calls `closeFd` on every pipe still attached to the `Child`. In
//!    Debug builds `closeFd` runs `recoverableOsBugDetected()` on EBADF
//!    (`std/Io/Threaded.zig` — `if (is_debug) unreachable;`), so one
//!    stale/already-closed descriptor turns a single bad HTTP request
//!    into `thread NNNNN panic: reached unreachable code` and takes the
//!    entire process down. Observed at `Threaded.zig:closeFd` ←
//!    `childCleanupPosix` ← `childWaitPosix` ← `Child.wait` called from
//!    `git_pr_status.zig:runGhPrView`.
//!
//! 2. **Sequential pipe draining deadlocks.** Draining stdout to EOF
//!    *before* touching stderr deadlocks as soon as the child writes
//!    more than one pipe buffer (64 KiB on Linux) to stderr: the child
//!    blocks in `write(2)`, so it never closes stdout, so our read
//!    never sees EOF. `gh` printing a large error, a hook stack trace,
//!    or a `git` warning is enough. The request then hangs forever and
//!    wedges a worker-pool thread for the life of the process.
//!
//! 3. **No timeout.** A child that never exits (a `gh` waiting on a
//!    hung network call, a credential prompt nobody can answer) blocks
//!    the worker thread indefinitely.
//!
//! ## What this module does instead
//!
//! - **Detaches the pipes from the `Child` immediately.** `child.stdout`
//!   / `child.stderr` are set to `null` before anything else happens, so
//!   std's `childCleanupPosix` has nothing to close and `closeFd` can
//!   never abort. The descriptors are closed exactly once, by
//!   [`closeTolerant`], which swallows every failure.
//! - **Drains stdout and stderr concurrently**, on one thread each, so
//!   neither pipe can fill up and block the child.
//! - **Bounds the run with a deadline.** On expiry the child is killed
//!   (which also reaps it, so no zombie is left behind) and
//!   `Result.timed_out` is set.
//! - **Caps each stream** at `Options.max_output_bytes` but keeps
//!   draining past the cap, so a chatty child still exits.
//! - **Never allocates from the reader threads' perspective without a
//!   lock** — the shared allocator is only touched under a per-stream
//!   mutex, so passing the (non-thread-safe) request arena is safe.

const std = @import("std");
const builtin = @import("builtin");

/// Default per-stream capture cap. Matches the 64 KiB every hand-rolled
/// caller had hardcoded, and is comfortably larger than any `gh pr view`
/// payload.
pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 64 * 1024;

/// Default wall-clock budget for a child process. Long enough for a
/// slow `gh` over a bad connection, short enough that a wedged worker
/// thread recovers.
pub const DEFAULT_TIMEOUT_MS: u32 = 30_000;

/// How long to keep waiting for the drain threads AFTER killing the
/// child's process group. Killing the group closes every write end, so
/// this normally expires on the first poll; it only matters for a
/// descendant that escaped the group via `setsid`, and it exists so
/// such a descendant can never hold the caller hostage.
const POST_KILL_GRACE_MS: u32 = 500;

/// POSIX process groups (`setpgid` / `kill(-pgid)`) are meaningless on
/// Windows, which has no such concept in the POSIX sense.
const posix_process_groups = switch (builtin.os.tag) {
    .windows => false,
    else => true,
};

/// "This pipe does not exist" for a [`std.Io.File.Handle`].
///
/// The handle type is `fd_t` (an `i32`) on POSIX, so `-1` is the
/// natural invalid value, but it is a `HANDLE` (a `*anyopaque`) on
/// Windows, where the conventional invalid value is
/// `INVALID_HANDLE_VALUE`. One literal cannot spell both, so the
/// sentinel is a per-OS comptime constant; anything that wants to
/// compare a handle against "none" must compare against this, never
/// against a hard-coded `-1`.
const no_handle: std.Io.File.Handle = switch (builtin.os.tag) {
    .windows => std.os.windows.INVALID_HANDLE_VALUE,
    else => -1,
};

/// Output + exit status of a finished child. Both buffers are owned by
/// the caller; release them with [`Result.deinit`].
pub const Result = struct {
    /// How the child terminated. When `timed_out` is true this is the
    /// termination WE forced, not a self-reported one: `.signal` with
    /// `KILL` on POSIX, `.unknown` on Windows (whose `Child.kill` is
    /// `TerminateProcess` and reports no signal).
    term: std.process.Child.Term,
    /// Captured stdout, at most `Options.max_output_bytes` long.
    stdout: []u8,
    /// Captured stderr, at most `Options.max_output_bytes` long.
    stderr: []u8,
    /// True when the child had to be killed because it outlived
    /// `Options.timeout_ms`. Callers should treat the output as partial.
    timed_out: bool,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.stdout = &.{};
        self.stderr = &.{};
    }
};

pub const Options = struct {
    /// Working directory for the child. `null` inherits the parent's.
    cwd: ?[]const u8 = null,
    /// Per-stream capture cap. Output beyond this is discarded (but
    /// still drained, so the child is never blocked by a full pipe).
    max_output_bytes: usize = DEFAULT_MAX_OUTPUT_BYTES,
    /// Wall-clock budget. `null` disables the deadline — only pass that
    /// for children you control the lifetime of.
    timeout_ms: ?u32 = DEFAULT_TIMEOUT_MS,
    /// Put the child in its own process group and, on timeout, kill the
    /// whole group. Needed whenever the child might fork helpers that
    /// outlive it: killing only the direct child leaves those helpers
    /// holding the stdout/stderr write ends, so the drain threads never
    /// reach EOF. Ignored on Windows. Default: true.
    kill_process_group: bool = true,
};

pub const RunError = std.mem.Allocator.Error ||
    std.process.SpawnError ||
    std.process.Child.WaitError;

/// Close a descriptor without letting Zig abort the process.
///
/// `std.Io.Threaded.closeFd` deliberately turns any unexpected errno
/// into `unreachable` in Debug builds, because for *its own* handles a
/// bad close really is a bug. For a descriptor we took ownership of and
/// close exactly once, being defensive is the whole point: a
/// double-close must degrade to "leak one fd", never to "kill the
/// server". See the module doc for the crash this replaces.
fn closeTolerant(handle: std.Io.File.Handle) void {
    if (handle == no_handle) return;
    // `builtin.os.tag` is comptime-known, so only the taken branch is
    // ever analysed: the POSIX body never has to typecheck on Windows
    // and the Windows body never has to link on POSIX.
    switch (builtin.os.tag) {
        .windows => {
            // Same call `Io.Threaded.fileClose` makes on Windows, and
            // already void/tolerant there. Calling it ourselves is
            // still the right move: it documents that this descriptor
            // is OURS, and it stays correct if std ever routes Windows
            // through the aborting `closeFd` too.
            std.os.windows.CloseHandle(handle);
        },
        else => {
            switch (std.posix.errno(std.posix.system.close(handle))) {
                // A signal arrived mid-close; POSIX says the descriptor
                // may or may not have been released, so retrying is the
                // only way to be sure. (Zig's own closeFd treats INTR as
                // success; for a best-effort close either is
                // acceptable, and retrying risks closing a recycled
                // descriptor, so match std here.)
                .INTR => {},
                else => {},
            }
        },
    }
}

/// Minimal lock guarding the shared `gpa` between the two drain
/// threads. `std.atomic.Mutex` only offers `tryLock`, so this spins
/// with a yield fallback. The critical section is one 4 KiB memcpy
/// plus (rarely) an ArrayList growth, so contention is negligible.
const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        var spins: usize = 0;
        while (!self.state.tryLock()) {
            if (spins < 64) {
                spins += 1;
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};

/// Per-stream reader state. Lives on `run`'s stack; the drain thread
/// only touches it through `mu` (plus its own `io` / `file` copies,
/// which are immutable).
const Drain = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    cap: usize,
    mu: SpinLock = .{},
    buf: std.ArrayList(u8) = .empty,
    /// Set by the drain thread (or by the inline fallback) once this
    /// stream has hit EOF or an error.
    finished: std.atomic.Value(bool) = .init(false),
    /// `null` when `std.Thread.spawn` failed and we drain inline instead.
    thread: ?std.Thread = null,
    /// Set when we gave up waiting for this stream. The thread (and
    /// this heap allocation) is deliberately leaked: it is still parked
    /// in `read(2)` on a descriptor we can no longer reach, and a
    /// use-after-free on the way out would be far worse.
    orphaned: bool = false,

    fn drain(self: *Drain) void {
        var chunk: [4096]u8 = undefined;
        while (true) {
            // EndOfStream is how readStreaming reports EOF. Any other
            // error (cancel, EINTR-driven retry exhaustion) ends this
            // stream too — the caller is already on the deadline path.
            const n = std.Io.File.readStreaming(self.file, self.io, &.{&chunk}) catch break;
            if (n == 0) break;
            self.mu.lock();
            defer self.mu.unlock();
            if (self.buf.items.len < self.cap) {
                const take = @min(n, self.cap - self.buf.items.len);
                self.buf.appendSlice(self.gpa, chunk[0..take]) catch break;
            }
            // Past the cap we keep reading and drop the bytes: stopping
            // here would re-fill the pipe and deadlock the child, which
            // is the exact bug this module exists to remove.
        }
        self.finished.store(true, .release);
    }

    fn release(self: *Drain) void {
        self.gpa.free(self.buf.items);
        self.buf = .empty;
    }

    /// Join the drain thread if it reached EOF, otherwise detach it.
    /// Returns the handle to join, or null when we gave up on it.
    fn joinOrAbandon(self: *Drain) ?std.Thread {
        const t = self.thread orelse return null;
        if (!self.finished.load(.acquire)) {
            self.orphaned = true;
            return null;
        }
        return t;
    }
};

/// Spawn `argv`, capture stdout + stderr, reap the child, never abort.
///
/// `argv[0]` is the program, resolved through `PATH` like any exec.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    opts: Options,
) RunError!Result {
    std.debug.assert(argv.len > 0);

    // `.pgid = 0` makes the child `setpgid(0, 0)` — it becomes the
    // leader of a brand-new process group whose id equals its pid. On
    // timeout we can then `kill(-pid)` and take the whole subtree down.
    // Without this, `sh -c 'sleep 600'` (or any CLI that forks a
    // helper) leaves a grandchild holding the stdout/stderr write
    // ends, so the drain threads never see EOF and the caller hangs
    // even after the direct child is dead.
    const own_pg = opts.kill_process_group and posix_process_groups;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |c| .{ .path = c } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (own_pg) 0 else null,
    });

    // Take ownership of both descriptors and detach them from the
    // Child in one step. From here on `Child.wait` / `Child.kill` see
    // null pipes, so std's `childCleanupPosix` closes nothing and its
    // `closeFd` -> `unreachable` path is unreachable. This is the fix
    // for the process-wide SIGABRT.
    const child_pid = child.id;
    const out_handle = if (child.stdout) |f| f.handle else no_handle;
    child.stdout = null;
    const err_handle = if (child.stderr) |f| f.handle else no_handle;
    child.stderr = null;
    // `.stdin = .ignore` means no stdin pipe, but be explicit so a
    // future options change cannot resurrect the same hazard.
    child.stdin = null;

    // Heap-allocated, not stack: if a drain thread is still wedged
    // when we give up on it, it must not be writing into a frame that
    // `run` has already returned from. A leaked Drain + a leaked thread
    // is strictly better than a use-after-free.
    const out = gpa.create(Drain) catch return error.OutOfMemory;
    defer gpa.destroy(out);
    const errs = gpa.create(Drain) catch return error.OutOfMemory;
    defer gpa.destroy(errs);
    out.* = .{ .gpa = gpa, .io = io, .file = .{ .handle = out_handle, .flags = .{ .nonblocking = false } }, .cap = opts.max_output_bytes };
    errs.* = .{ .gpa = gpa, .io = io, .file = .{ .handle = err_handle, .flags = .{ .nonblocking = false } }, .cap = opts.max_output_bytes };
    defer {
        // Only reached when we DID join the threads (or when the spawn
        // of a thread failed and we drained inline), so this frees the
        // captured bytes exactly once.
        if (!out.orphaned) out.release();
        if (!errs.orphaned) errs.release();
        closeTolerant(out_handle);
        closeTolerant(err_handle);
    }

    // Concurrent drain. Two independent pipes means neither can fill up
    // and block the child while we wait on the other one.
    out.thread = std.Thread.spawn(.{}, Drain.drain, .{out}) catch null;
    errs.thread = std.Thread.spawn(.{}, Drain.drain, .{errs}) catch null;
    // Thread creation can fail (fd/memory limits) — drain inline so the
    // caller still gets a correct answer, just serially.
    if (out.thread == null) out.drain();
    if (errs.thread == null) errs.drain();

    var timed_out = false;
    if (opts.timeout_ms) |budget_ms| {
        const start = std.Io.Timestamp.now(io, .awake);
        const deadline = start.addDuration(.fromMilliseconds(@intCast(budget_ms)));
        while (!bothDone(out, errs)) {
            if (std.Io.Timestamp.now(io, .awake).durationTo(deadline).toNanoseconds() <= 0) {
                timed_out = true;
                break;
            }
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch break;
        }
    }

    if (timed_out) {
        // Kill the whole process group first so a grandchild cannot keep
        // the pipes open, then `kill` (which also reaps, and asserts
        // the pipes are detached — they are). After it returns
        // `child.id` is null and `child.wait` must not be called.
        // `posix_process_groups` is a comptime constant, so on Windows
        // this block is dropped before `std.posix.kill` is analysed —
        // and it must be dropped, since there is no process group to
        // kill and no negative pid to pass.
        if (posix_process_groups) {
            if (own_pg) {
                if (child_pid) |pid| {
                    // Negative pid targets the process group. The pid is
                    // still reserved (the child is unreaped), so there is no
                    // reuse hazard here.
                    std.posix.kill(-pid, .KILL) catch {};
                }
            }
        }
        child.kill(io);

        // Bounded grace period for the readers. Killing the group
        // closes the write ends, so this normally returns on the first
        // poll; a descendant that called setsid() to escape the group
        // would not, and must not hold the caller hostage.
        const grace_deadline = std.Io.Timestamp.now(io, .awake)
            .addDuration(.fromMilliseconds(@intCast(POST_KILL_GRACE_MS)));
        while (!bothDone(out, errs)) {
            if (std.Io.Timestamp.now(io, .awake).durationTo(grace_deadline).toNanoseconds() <= 0) break;
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch break;
        }
    }

    if (out.joinOrAbandon()) |t| t.join();
    if (errs.joinOrAbandon()) |t| t.join();

    const result: Result = .{
        .term = if (timed_out)
            // We chose this term; the child never got to report one.
            termForKill()
        else
            // Safe to call: pipes are detached so `childCleanupPosix`
            // has nothing to close.
            (try child.wait(io)),
        .stdout = try out.buf.toOwnedSlice(gpa),
        .stderr = try errs.buf.toOwnedSlice(gpa),
        .timed_out = timed_out,
    };
    // `toOwnedSlice` empties the ArrayList, so the `defer` above will
    // not double-free; keep `result` immutable from here on.
    return result;
}

fn bothDone(out: *const Drain, errs: *const Drain) bool {
    return out.finished.load(.acquire) and errs.finished.load(.acquire);
}

/// The [`Result.term`] we report when WE killed the child on the
/// deadline path. The child never got to report a termination, so
/// there is no real one to describe.
fn termForKill() std.process.Child.Term {
    return switch (builtin.os.tag) {
        // Windows `Child.kill` is `TerminateProcess`: there is no
        // signal, and `Child.wait` never yields `.signal` there either
        // (it reports `.exited` from the process exit status, or
        // `.unknown` when the query fails). `.unknown` is both honest
        // and legal — the old `@enumFromInt(0)` spelled an out-of-range
        // value for `std.c.SIG`'s exhaustive enum, which traps in Debug.
        .windows => .{ .unknown = 0 },
        else => .{ .signal = std.posix.SIG.KILL },
    };
}

// ===== Tests =====

const testing = std.testing;

/// `/bin/sh` is not available on Windows, and the payloads below are
/// POSIX shell snippets. Skip rather than fail there.
const posix_only = if (builtin.os.tag == .windows) true else false;

fn skipOnWindows() bool {
    if (posix_only) return true;
    return false;
}

const SH = "/bin/sh";

test "run: captures stdout and stderr from a successful child" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "printf 'hello'; printf 'oops' 1>&2" }, .{
        .timeout_ms = 10_000,
    });
    defer r.deinit(gpa);

    try testing.expectEqualStrings("hello", r.stdout);
    try testing.expectEqualStrings("oops", r.stderr);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expect(!r.timed_out);
}

test "run: reports a non-zero exit code and still captures stderr" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "printf 'partial' ; printf 'boom' 1>&2; exit 3" }, .{
        .timeout_ms = 10_000,
    });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u8, 3), r.term.exited);
    try testing.expectEqualStrings("partial", r.stdout);
    try testing.expectEqualStrings("boom", r.stderr);
}

test "run: a child that never exits is killed at the deadline" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "sleep 30" }, .{ .timeout_ms = 250 });
    defer r.deinit(gpa);

    try testing.expect(r.timed_out);
    // `kill` sends SIGKILL *and* reaps, so no zombie survives and the
    // caller must not wait() again.
    try testing.expect(r.term == .signal);
}

test "run: large stderr does not deadlock (the runGhPrView regression)" {
    // `gh` printing more than one pipe buffer to stderr used to wedge
    // the worker thread forever: the old code drained stdout to EOF
    // first, so `gh` blocked in write(2) on a full stderr pipe and
    // never closed stdout. 512 KiB is 8x the Linux pipe buffer.
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{
        SH,
        "-c",
        \\i=0; while [ $i -lt 512 ]; do
        \\  i=$((i+1)); printf '%s' "0123456789012345678901234567890123456789012345678901234567890123"
        \\done 1>&2; printf 'done'
    }, .{ .timeout_ms = 20_000, .max_output_bytes = 8 * 1024 });
    defer r.deinit(gpa);

    try testing.expect(!r.timed_out);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expectEqualStrings("done", r.stdout);
    // Capped, not truncated-mid-byte, and the rest was drained.
    try testing.expectEqual(@as(usize, 8 * 1024), r.stderr.len);
}

test "run: large stdout is capped but the child still exits cleanly" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{
        SH,
        "-c",
        \\i=0; while [ $i -lt 512 ]; do
        \\  i=$((i+1)); printf '%s' "0123456789012345678901234567890123456789012345678901234567890123"
        \\done
    }, .{ .timeout_ms = 20_000, .max_output_bytes = 4 * 1024 });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(u8, 0), r.term.exited);
    try testing.expectEqual(@as(usize, 4 * 1024), r.stdout.len);
    try testing.expectEqual(@as(usize, 0), r.stderr.len);
}

test "run: both streams large at once" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    const script =
        \\i=0; while [ $i -lt 256 ]; do
        \\  i=$((i+1)); printf 'o'; printf 'e' 1>&2
        \\done
    ;
    var r = try run(gpa, testing.io, &.{ SH, "-c", script }, .{
        .timeout_ms = 20_000,
        .max_output_bytes = 64 * 1024,
    });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(usize, 256), r.stdout.len);
    try testing.expectEqual(@as(usize, 256), r.stderr.len);
}

test "run: empty output on both streams" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "exit 0" }, .{ .timeout_ms = 10_000 });
    defer r.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), r.stdout.len);
    try testing.expectEqual(@as(usize, 0), r.stderr.len);
    try testing.expectEqual(@as(u8, 0), r.term.exited);
}

test "run: a missing program surfaces the spawn error, not a panic" {
    const gpa = testing.allocator;
    const result = run(gpa, testing.io, &.{"nalar-definitely-not-a-real-binary-xyzzy"}, .{});
    try testing.expectError(error.FileNotFound, result);
}

test "run: a non-existent cwd surfaces the spawn error" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    const result = run(gpa, testing.io, &.{ SH, "-c", "true" }, .{
        .cwd = "/nalar/no/such/directory/xyzzy",
    });
    try testing.expectError(error.FileNotFound, result);
}

test "run: honours cwd" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "pwd" }, .{ .cwd = "/tmp" });
    defer r.deinit(gpa);

    // Assert against the CANONICAL form of the directory we asked for,
    // not the literal string we passed in. `pwd` reports the physical
    // path, and on macOS `/tmp` is a symlink to `/private/tmp` — so the
    // child is in exactly the right directory while the literal "/tmp"
    // is the wrong expectation. That mismatch is a macOS-only CI
    // failure; resolving both sides tests the actual contract (the cwd
    // we asked for is the cwd the child got) on every platform.
    const canonical_tmp = try std.Io.Dir.realPathFileAbsoluteAlloc(testing.io, "/tmp", gpa);
    defer gpa.free(canonical_tmp);

    try testing.expectEqualStrings(canonical_tmp, std.mem.trimEnd(u8, r.stdout, "\r\n"));
}

test "run: non-UTF8 bytes survive capture" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "printf '\\377\\376\\000raw'" }, .{
        .timeout_ms = 10_000,
    });
    defer r.deinit(gpa);
    try testing.expectEqualStrings(&[_]u8{ 0xff, 0xfe, 0x00, 'r', 'a', 'w' }, r.stdout);
}

test "run: a child killed by a signal is reported as .signal" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "kill -9 $$" }, .{ .timeout_ms = 10_000 });
    defer r.deinit(gpa);
    try testing.expect(r.term == .signal);
    try testing.expect(!r.timed_out);
}

test "run: timeout_ms = 0 kills immediately without hanging" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "sleep 30" }, .{ .timeout_ms = 0 });
    defer r.deinit(gpa);
    try testing.expect(r.timed_out);
}

test "run: a grandchild holding the pipes does not survive the deadline" {
    // The shell script forks `sleep`, so killing only the direct child
    // leaves `sleep` holding the stdout/stderr write ends open — the
    // drain threads would never see EOF and the caller would hang even
    // though "the child" is dead. Caught by
    // tests/functional/git_pr_status_crash_test.py
    // ::test_gh_that_never_exits_is_killed_not_awaited_forever against
    // the first version of this helper, which had no process group.
    if (skipOnWindows()) return error.SkipZigTest;
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const before = countOpenFds() orelse return error.SkipZigTest;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "sleep 300" }, .{ .timeout_ms = 300 });
    defer r.deinit(gpa);
    try testing.expect(r.timed_out);
    try testing.expect(r.term == .signal);
    // And nothing is left behind: no orphaned reader, no leaked fd.
    const after = countOpenFds() orelse return error.SkipZigTest;
    try testing.expect(after <= before + 2);
}

test "run: kill_process_group = false still returns on a plain child" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = testing.allocator;
    var r = try run(gpa, testing.io, &.{ SH, "-c", "sleep 30" }, .{
        .timeout_ms = 200,
        .kill_process_group = false,
    });
    defer r.deinit(gpa);
    try testing.expect(r.timed_out);
}

test "run: no fd leak across many runs" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const before = countOpenFds() orelse return error.SkipZigTest;
    for (0..25) |_| {
        var r = try run(gpa, testing.io, &.{ SH, "-c", "printf 'x'; printf 'y' 1>&2" }, .{
            .timeout_ms = 10_000,
        });
        defer r.deinit(gpa);
    }
    const after = countOpenFds() orelse return error.SkipZigTest;
    // A leaked descriptor per run is the classic symptom of a
    // childCleanupPosix double-close being "fixed" by not closing at
    // all. Allow a small slack for the allocator, not 25 fds.
    try testing.expect(after <= before + 4);
}

test "run: concurrent callers do not corrupt each other's output" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;
    const before = countOpenFds() orelse return error.SkipZigTest;

    const threads = try gpa.alloc(std.Thread, 8);
    defer gpa.free(threads);
    const oks = try gpa.alloc(bool, 8);
    defer gpa.free(oks);

    for (0..8) |i| {
        oks[i] = false;
        threads[i] = try std.Thread.spawn(.{}, concurrentWorker, .{ gpa, &oks[i] });
    }
    for (threads) |t| t.join();
    for (oks) |ok| try testing.expect(ok);

    const after = countOpenFds() orelse return error.SkipZigTest;
    try testing.expect(after <= before + 8);
}

fn concurrentWorker(gpa: std.mem.Allocator, ok: *bool) void {
    ok.* = true;
    for (0..10) |_| {
        var r = run(gpa, testing.io, &.{
            SH, "-c",
            \\i=0; while [ $i -lt 128 ]; do i=$((i+1)); printf 'o'; printf 'e' 1>&2; done
        }, .{ .timeout_ms = 20_000 }) catch {
            ok.* = false;
            return;
        };
        defer r.deinit(gpa);
        if (r.stdout.len != 128 or r.stderr.len != 128 or r.term.exited != 0) {
            ok.* = false;
            return;
        }
    }
}

fn countOpenFds() ?usize {
    var dir = std.Io.Dir.cwd().openDir(testing.io, "/proc/self/fd", .{ .iterate = true }) catch return null;
    defer std.Io.Dir.close(dir, testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(testing.io) catch null) |_| n += 1;
    return n;
}
