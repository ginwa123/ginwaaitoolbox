const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.notifications);

/// Maximum characters of the body we pass to the OS. notify-send and friends
/// don't have a hard limit, but very long bodies look bad in toast UIs and
/// are truncated visually anyway. 140 chars is roughly 2 sentences.
const MAX_BODY_LEN: usize = 140;

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
            errdefer allocator.free(title_esc);
            const body_esc = try escapeAppleScript(allocator, truncated);
            errdefer allocator.free(body_esc);
            const script = try std.fmt.allocPrint(
                allocator,
                "display notification \"{s}\" with title \"{s}\"",
                .{ body_esc, title_esc },
            );
            errdefer allocator.free(script);
            try args.append(allocator, try allocator.dupe(u8, "osascript"));
            try args.append(allocator, try allocator.dupe(u8, "-e"));
            try args.append(allocator, script);
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

fn notifyWithArgv(io: std.Io, argv: []const []const u8) NotifyError!void {
    // Any spawn failure (file not found, permission denied, etc.) is
    // collapsed into `BinaryNotFound` so the LLM workflow logs it and
    // moves on. Surfacing the raw error would interrupt the LLM.
    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.BinaryNotFound;

    // Fire-and-forget. We deliberately don't call `child.wait(io)` so
    // a slow toast library can't block the LLM workflow. The OS reaps
    // the child when it exits. The parent's process table will hold
    // the zombie briefly; this is acceptable for short-lived
    // notification daemons.
    //
    // We must reference `child` so the compiler doesn't warn that the
    // `spawn` result is unused — the variable is intentionally leaked
    // for the fire-and-forget pattern.
    if (child.id == null) return error.BinaryNotFound;
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
