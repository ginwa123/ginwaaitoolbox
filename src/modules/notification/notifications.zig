
const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.notifications);

/// Maximum characters of the body we pass to the OS. notify-send and friends
/// don't have a hard limit, but very long bodies look bad in toast UIs and
/// are truncated visually anyway. 140 chars is roughly 2 sentences.
pub const MAX_BODY_LEN: usize = 140;

pub const NotifyError = error{
    /// The OS notification binary is not installed (e.g. notify-send on a
    /// Linux box without libnotify) or the spawn failed. Caller should
    /// log and continue — a notification failure must not break the
    /// LLM workflow.
    BinaryNotFound,
    OutOfMemory,
};

/// Build the argv that would be spawned for the current OS. Public so
/// tests can assert on the command shape without actually running it.
///
/// Every inner string is heap-allocated via the provided allocator, so
/// the caller (and the test) frees them uniformly with
/// `for (cmd) |arg| allocator.free(arg); allocator.free(cmd);`.
///
/// Returns an empty slice on unsupported OSes (with a warn-log).
pub fn buildCommand(allocator: std.mem.Allocator, title: []const u8, body: []const u8) ![]const []const u8 {
    const truncated = try truncateBody(allocator, body, MAX_BODY_LEN);
    errdefer allocator.free(truncated);

    var args: std.ArrayList([]const u8) = .empty;
    // On any error path, free all the strings we've already appended plus
    // the ArrayList's backing buffer.
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    switch (builtin.os.tag) {
        .linux => {
            try args.append(allocator, try allocator.dupe(u8, "notify-send"));
            try args.append(allocator, try allocator.dupe(u8, "--app-name=nalar"));
            try args.append(allocator, try allocator.dupe(u8, title));
            try args.append(allocator, truncated);
        },
        .macos => {
            // AppleScript: display notification "body" with title "title"
            // Body and title are escaped for double-quote and backslash
            // insertion. We do NOT escape backticks or newlines — the
            // caller is responsible for keeping the strings ASCII-clean
            // for this MVP. (A future enhancement can add full escaping.)
            const title_esc = try escapeAppleScript(allocator, title);
            defer allocator.free(title_esc);
            const body_esc = try escapeAppleScript(allocator, truncated);
            defer allocator.free(body_esc);
            const script = try std.fmt.allocPrint(
                allocator,
                "display notification \"{s}\" with title \"{s}\"",
                .{ body_esc, title_esc },
            );
            errdefer allocator.free(script);
            try args.append(allocator, try allocator.dupe(u8, "osascript"));
            try args.append(allocator, try allocator.dupe(u8, "-e"));
            try args.append(allocator, script);
            // `truncated` was consumed by escapeAppleScript (which copies)
            // and the errdefer only fires on error. Free it now since we're
            // about to return successfully.
            allocator.free(truncated);
        },
        .windows => {
            // PowerShell stub: uses MessageBox (a blocking modal) instead
            // of a proper toast. For a real Windows build, swap in the
            // BurntToast module or the new Windows.UI.Notifications API.
            // ASCII-clean input keeps the single-quote escaping simple
            // for the MVP.
            const script = try std.fmt.allocPrint(
                allocator,
                "[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null; " ++
                    "[System.Windows.Forms.MessageBox]::Show('{s}', '{s}')",
                .{ title, truncated },
            );
            errdefer allocator.free(script);
            try args.append(allocator, try allocator.dupe(u8, "powershell"));
            try args.append(allocator, try allocator.dupe(u8, "-NoProfile"));
            try args.append(allocator, try allocator.dupe(u8, "-Command"));
            try args.append(allocator, script);
            // `truncated` was consumed by allocPrint (which copies); free
            // it now since the errdefer only fires on error and we're
            // about to return successfully.
            allocator.free(truncated);
        },
        else => {
            log.warn("notifications: unsupported OS {s}; skipping", .{@tagName(builtin.os.tag)});
            // truncated is no longer needed — free it manually.
            allocator.free(truncated);
        },
    }

    return try args.toOwnedSlice(allocator);
}

/// Fire an OS notification using the platform's native CLI
/// (notify-send / osascript / PowerShell). Fire-and-forget: we do NOT
/// call `child.wait()` so a slow toast library can't block the LLM
/// workflow. Errors are returned but callers typically log+continue.
///
/// `io` is the std.Io handle used to spawn the child. Pass the
/// workflow's `io` from workflow.zig.
pub fn notify(io: std.Io, allocator: std.mem.Allocator, title: []const u8, body: []const u8) NotifyError!void {
    const cmd = buildCommand(allocator, title, body) catch return error.OutOfMemory;
    defer {
        for (cmd) |arg| allocator.free(arg);
        allocator.free(cmd);
    }
    if (cmd.len == 0) return; // Unsupported OS — already logged inside buildCommand.
    return notifyWithArgv(io, cmd);
}

/// Test-only helper: spawn a specific binary path. Used by the
/// `BinaryNotFound` test. Production code uses `notify()` which calls
/// `buildCommand` to pick the path.
pub fn notifyWithPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, title: []const u8, body: []const u8) NotifyError!void {
    const truncated = try truncateBody(allocator, body, MAX_BODY_LEN);
    defer allocator.free(truncated);
    const argv = try allocator.dupe([]const u8, &[_][]const u8{
        path,
        title,
        truncated,
    });
    defer allocator.free(argv);
    return notifyWithArgv(io, argv);
}

/// Args passed to the reaper thread. The struct is copied onto the
/// thread's stack for the thread's lifetime, so no heap allocation
/// is needed. `io` is a fat pointer (vtable + userdata) and `child`
/// is a small handle struct; both are cheap to copy.
const ReaperArgs = struct {
    io: std.Io,
    child: std.process.Child,
};

/// One-shot reaper thread: blocks on `child.wait` so the OS can reap
/// the child when it exits. Fire-and-forget for the LLM workflow — we
/// don't care about the exit status (a toast notification failing
/// is not actionable), so any error from `wait` is silently ignored.
///
/// Note: Zig function parameters are const-by-default. Since
/// `child.wait(io)` requires `*Child` (mutable, because it nulls
/// `child.id` to mark the child as reaped), we copy into a `var`
/// local first.
fn reapChild(args: ReaperArgs) void {
    var local = args;
    _ = local.child.wait(local.io) catch {};
}

fn notifyWithArgv(io: std.Io, argv: []const []const u8) NotifyError!void {
    // Any spawn failure (file not found, permission denied, etc.) is
    // collapsed into `BinaryNotFound` so the LLM workflow logs it and
    // moves on. Surfacing the raw error would interrupt the LLM.
    // Declared as `var` so `child.kill(io)` (in the spawn-failure
    // fallback below) has a mutable pointer to work with.
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.BinaryNotFound;
    if (child.id == null) return error.BinaryNotFound;

    // Fire-and-forget from the LLM workflow's perspective: we must
    // not block waiting for notify-send to exit (a slow toast library
    // would freeze the chat). But dropping the `Child` without
    // reaping leaves the child as a zombie (state Z) in the parent's
    // process table forever — SIGCHLD is left at its default behavior
    // on glibc >= 2.34, which does NOT auto-reap.
    //
    // Fix: spawn a one-shot reaper thread that calls `child.wait(io)`
    // and then exits. The thread is detached so we don't have to
    // join it. Each notification costs ~8 KB of thread stack, bounded
    // by the rate of LLM completions.
    //
    // We deliberately do NOT use `signal(SIGCHLD, SIG_IGN)` because
    // that's process-global and would break `child.wait(io)` in
    // bash.zig + HttpClient.zig, which rely on default SIGCHLD
    // behavior to reap their own children.
    const args = ReaperArgs{ .io = io, .child = child };
    if (std.Thread.spawn(.{}, reapChild, .{args})) |thread| {
        thread.detach();
    } else |_| {
        // Thread spawn failed (out of memory / thread limit). Fall
        // back to inline `child.kill(io)` to at least prevent zombie
        // accumulation. `child.kill(io)` in Zig 0.16 returns void,
        // blocks until the child is reaped, and closes the pipe FDs
        // via childCleanupPosix — so the LLM workflow briefly blocks
        // here (~1-10ms) but no zombie leaks. This is a worst-case
        // safety net; in practice std.Thread.spawn only fails under
        // extreme resource pressure.
        child.kill(io);
    }
}

/// Truncate `body` to `max` characters, appending an ellipsis when
/// truncated. Always returns a freshly-allocated slice that the caller
/// owns and must `allocator.free()`. If `body.len <= max`, the result
/// is a `dupe` of the input (still owned by the caller).
pub fn truncateBody(allocator: std.mem.Allocator, body: []const u8, max: usize) ![]u8 {
    if (body.len <= max) return try allocator.dupe(u8, body);
    const ellipsis: []const u8 = "…";
    const cut = max - ellipsis.len;
    var out = try allocator.alloc(u8, max);
    @memcpy(out[0..cut], body[0..cut]);
    @memcpy(out[cut..max], ellipsis);
    return out;
}

fn escapeAppleScript(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"', '\\' => try out.append(allocator, '\\'),
            else => {},
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}
