const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const nalar = @import("nalarcore");
const sqlite = nalar.sqlite;

/// Input structure for set_git_worktree tool
pub const SetGitWorktreeInput = struct {
    /// Absolute path to the worktree directory. The directory must NOT
    /// already exist (git worktree add will create it). The parent
    /// directory MUST exist. Examples:
    ///   "/home/me/projects/myapp/.worktrees/auth-fix"
    ///   "/tmp/experiments/rpc-rewrite"
    ///   "/Users/me/code/myapp.worktrees/fix-bug-123"
    /// Required unless `clear=true`. Must be absolute, ≤ 4096 chars,
    /// contain no `..` segments, no null bytes. The basename must
    /// match `[A-Za-z0-9._-]{1,100}` (so the auto-derived branch name
    /// `worktree/<basename>` is legal).
    path: []const u8 = "",
    /// Optional branch name override. Defaults to `worktree/<basename(path)>`.
    /// Rarely needed — the default is consistent and predictable.
    branch: []const u8 = "",
    /// When true, remove the existing worktree binding for this session
    /// AND delete the worktree directory. `path` is ignored when true.
    clear: bool = false,
    /// The session_id this worktree is bound to. The LLM does NOT
    /// supply this — the tool_registry execX wrapper injects
    /// `ctx.session_id` at call time.
    session_id: []const u8 = "",
};

/// Tool definition for set_git_worktree
pub const set_git_worktree_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_git_worktree",
        .description = "Create a git worktree at an absolute path you provide and bind it as the session's working directory. The worktree can be in any folder (e.g. '/home/me/project/.worktrees/auth-fix', '/tmp/experiments/x', or anywhere else). While bound, bash/read_file/write_file/text_replace/glob/search operate on the worktree instead of the session's original cwd. The branch defaults to 'worktree/<basename(path)>'. Call again with a different path to switch the binding to that worktree. Pass clear=true to remove the worktree directory and clear the binding.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the worktree directory. Must be absolute, contain no '..' segments, no null bytes, be ≤ 4096 chars, and the parent directory must already exist. The basename must match [A-Za-z0-9._-]{1,100} (so the auto-derived branch name is legal). Examples: '/home/me/proj/.worktrees/auth-fix', '/tmp/experiments/rpc-rewrite'.",
                },
                .{
                    .name = "branch",
                    .type = "string",
                    .description = "Optional branch name override. Defaults to 'worktree/<basename(path)>'. Rarely needed.",
                },
                .{
                    .name = "clear",
                    .type = "boolean",
                    .description = "If true, remove the worktree directory and clear the binding. 'path' is ignored when clear=true. Default: false.",
                },
            },
            .required = &.{},
        },
    },
};

/// Validate an absolute worktree path. Returns null on success, or an
/// error message on failure. Pure function — no IO. Also validates
/// the basename (which becomes the auto-derived branch name).
pub fn validatePath(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "path cannot be empty";
    if (path.len > 4096) return "path exceeds 4096 characters";
    if (std.mem.indexOfScalar(u8, path, 0) != null) return "path contains null byte";
    if (!std.fs.path.isAbsolute(path)) return "path must be absolute (start with /)";
    if (std.mem.indexOf(u8, path, "..") != null) return "path must not contain '..' segments";

    // Basename must be a legal branch name fragment.
    const basename = std.fs.path.basename(path);
    if (validateBasename(basename)) |err_msg| return err_msg;
    return null;
}

/// Validate a basename (used both by `validatePath` and as a stand-alone
/// check for the auto-derived branch name). Returns null on success.
pub fn validateBasename(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "basename cannot be empty";
    if (name.len > 100) return "basename exceeds 100 characters";
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-';
        if (!ok) return "basename contains invalid character (allowed: A-Za-z0-9._-)";
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return "basename cannot be '.' or '..'";
    }
    return null;
}

/// Pure helper: derive the default branch name from an absolute worktree
/// path. Returns `worktree/<basename>`. Caller frees the result.
pub fn deriveBranchFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    const basename = std.fs.path.basename(path);
    return try std.fmt.allocPrint(allocator, "worktree/{s}", .{basename});
}

/// Read the session's current `git_worktree_cwd` from the DB.
/// Returns empty string when not set. Used by `clear` to know which
/// directory to remove.
fn readExistingWorktreeCwd(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]u8 {
    const sql = "SELECT COALESCE(s.git_worktree_cwd, '') FROM sessions s WHERE s.id = ?";
    var q = try db.query(allocator, sql, &.{session_id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

/// Run `git worktree add -b <branch> <worktree_path>` in the given
/// repository root. Returns the captured stderr on non-zero exit.
fn runGitWorktreeAdd(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
) !void {
    var child = std.process.spawn(io, .{
        .argv = &.{
            "git", "worktree", "add", "-b", branch, worktree_path,
        },
        .cwd = .{ .path = repo_root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return err;

    // Short-lived command (worktree add is sub-second); use a bounded
    // blocking read rather than the threaded + timeout pattern that
    // bash.zig uses for arbitrary user commands. Cap the read to 64KB
    // so a hostile/buggy git can't OOM the tool.
    const stderr_pipe = child.stderr orelse {
        // No stderr pipe (shouldn't happen with .pipe above); just wait
        // and return based on exit code.
        const term = child.wait(io) catch return error.GitWaitFailed;
        return switch (term) {
            .exited => |code| if (code == 0) return else return error.GitAddFailed,
            else => error.GitAddFailed,
        };
    };

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.Io.File.readStreaming(stderr_pipe, io, &.{&read_buf}) catch break;
        if (n == 0) break;
        if (stderr_buf.items.len < 64 * 1024) {
            const take = @min(n, 64 * 1024 - stderr_buf.items.len);
            stderr_buf.appendSlice(allocator, read_buf[0..take]) catch break;
        }
    }

    const term = child.wait(io) catch return error.GitWaitFailed;
    switch (term) {
        .exited => |code| {
            if (code == 0) return;
            const msg = if (stderr_buf.items.len == 0)
                try allocator.dupe(u8, "git worktree add failed (no stderr)")
            else
                try allocator.dupe(u8, stderr_buf.items);
            errdefer allocator.free(msg);
            std.debug.print("git worktree add failed (exit={d}): {s}\n", .{ code, msg });
            return error.GitAddFailed;
        },
        .signal => {
            std.debug.print("git worktree add killed by signal\n", .{});
            return error.GitAddFailed;
        },
        else => return error.GitAddFailed,
    }
}

/// Run `git worktree remove --force <worktree_path>`. The `--force`
/// flag is required because the worktree may have uncommitted changes
/// (the LLM is actively editing inside it).
fn runGitWorktreeRemove(
    allocator: std.mem.Allocator,
    io: std.Io,
    worktree_path: []const u8,
) !void {
    var child = std.process.spawn(io, .{
        .argv = &.{
            "git", "worktree", "remove", "--force", worktree_path,
        },
        .cwd = .inherit, // use the nalar process's cwd (the session cwd is inside the original repo)
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return err;

    const stderr_pipe = child.stderr orelse {
        const term = child.wait(io) catch return error.GitWaitFailed;
        return switch (term) {
            .exited => |code| if (code == 0) return else return error.GitRemoveFailed,
            else => error.GitRemoveFailed,
        };
    };

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.Io.File.readStreaming(stderr_pipe, io, &.{&read_buf}) catch break;
        if (n == 0) break;
        if (stderr_buf.items.len < 64 * 1024) {
            const take = @min(n, 64 * 1024 - stderr_buf.items.len);
            stderr_buf.appendSlice(allocator, read_buf[0..take]) catch break;
        }
    }

    const term = child.wait(io) catch return error.GitWaitFailed;
    switch (term) {
        .exited => |code| {
            if (code == 0) return;
            // It's not an error if the directory was already gone (the
            // user may have `rm -rf`d it manually between sessions).
            // git returns 128 with "fatal: not a working tree" in that
            // case — treat that as success.
            const stderr_text = stderr_buf.items;
            if (std.mem.indexOf(u8, stderr_text, "not a working tree") != null) return;
            if (std.mem.indexOf(u8, stderr_text, "No such file or directory") != null) return;
            std.debug.print("git worktree remove failed (exit={d}): {s}\n", .{ code, stderr_text });
            return error.GitRemoveFailed;
        },
        .signal => {
            std.debug.print("git worktree remove killed by signal\n", .{});
            return error.GitRemoveFailed;
        },
        else => return error.GitRemoveFailed,
    }
}

/// Execute the set_git_worktree tool.
pub fn executeSetGitWorktreeToString(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    session_id: []const u8,
    input: SetGitWorktreeInput,
) ![]const u8 {
    if (session_id.len == 0) return xmlErrorEmpty(allocator, "session_id is required");

    // CLEAR PATH — remove the currently-bound worktree, if any.
    if (input.clear) {
        const existing = try readExistingWorktreeCwd(allocator, db, session_id);
        defer allocator.free(existing);
        if (existing.len > 0) {
            runGitWorktreeRemove(allocator, io, existing) catch |err| {
                const msg = @errorName(err);
                std.debug.print("set_git_worktree clear: remove failed: {s}\n", .{msg});
                return xmlError(allocator, session_id, "failed to remove existing worktree");
            };
        }
        return successClearToXml(allocator, session_id);
    }

    // SET PATH — validate the absolute path, check parent exists, create.
    if (input.path.len == 0) {
        return xmlError(allocator, session_id, "path is required (or pass clear=true)");
    }
    if (validatePath(input.path)) |err_msg| {
        return xmlError(allocator, session_id, err_msg);
    }
    // Parent directory must exist (git won't auto-create it).
    const parent_path = std.fs.path.dirname(input.path) orelse "/";
    std.Io.Dir.cwd().access(io, parent_path, .{}) catch {
        return xmlError(allocator, session_id, "parent directory does not exist");
    };
    const worktree_path = try allocator.dupe(u8, input.path);
    defer allocator.free(worktree_path);
    const branch_owned: ?[]u8 = if (input.branch.len > 0) null else blk: {
        const default = try deriveBranchFromPath(allocator, worktree_path);
        break :blk default;
    };
    defer if (branch_owned) |b| allocator.free(b);
    const branch: []const u8 = if (input.branch.len > 0) input.branch else branch_owned.?;

    runGitWorktreeAdd(allocator, io, cwd, worktree_path, branch) catch |err| {
        const msg = @errorName(err);
        std.debug.print("set_git_worktree add failed: {s}\n", .{msg});
        return xmlError(allocator, session_id, "git worktree add failed");
    };
    return successSetToXml(allocator, session_id, worktree_path, branch);
}

/// Generate success XML response for the SET path case.
fn successSetToXml(allocator: std.mem.Allocator, session_id: []const u8, path: []const u8, branch: []const u8) []const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<worktree>\n<session_id>") catch return "";
    appendXmlContent(allocator, &result, session_id) catch return "";
    result.appendSlice(allocator, "</session_id>\n<created>true</created>\n<path>") catch return "";
    appendXmlContent(allocator, &result, path) catch return "";
    result.appendSlice(allocator, "</path>\n<branch>") catch return "";
    appendXmlContent(allocator, &result, branch) catch return "";
    result.appendSlice(allocator, "</branch>\n</worktree>") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Generate success XML response for the CLEAR case.
fn successClearToXml(allocator: std.mem.Allocator, session_id: []const u8) []const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<worktree>\n<session_id>") catch return "";
    appendXmlContent(allocator, &result, session_id) catch return "";
    result.appendSlice(allocator, "</session_id>\n<cleared>true</cleared>\n</worktree>") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Append XML-safe content to an ArrayList. Mirrors the helper in
/// add_skill.zig: escapes <, >, &, ", '.
fn appendXmlContent(allocator: std.mem.Allocator, result: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }
}

/// Generate error XML response (session_id is present).
pub fn xmlError(allocator: std.mem.Allocator, session_id: []const u8, error_msg: []const u8) []const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<worktree>\n<session_id>") catch return "";
    appendXmlContent(allocator, &result, session_id) catch return "";
    result.appendSlice(allocator, "</session_id>\n<created>false</created>\n<error>") catch return "";
    appendXmlContent(allocator, &result, error_msg) catch return "";
    result.appendSlice(allocator, "</error>\n</worktree>") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Generate error XML response when session_id is unavailable.
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<worktree>\n<session_id></session_id>\n<created>false</created>\n<error>") catch return "";
    appendXmlContent(allocator, &result, error_msg) catch return "";
    result.appendSlice(allocator, "</error>\n</worktree>") catch return "";

    return result.toOwnedSlice(allocator) catch "<worktree><session_id></session_id><created>false</created><error>UnknownError</error></worktree>";
}
