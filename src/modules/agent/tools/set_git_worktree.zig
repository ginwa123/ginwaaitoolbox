const std = @import("std");
const builtin = @import("builtin");
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
    /// directory MUST exist. Canonical root (Option A):
    ///   "/home/you/.config/nalar/.worktrees/fix-login"
    /// Ad-hoc paths elsewhere are accepted.
    /// Required unless `clear=true`. Must be absolute, ≤ 4096 chars,
    /// contain no `..` segments, no null bytes. The basename must
    /// match `[A-Za-z0-9._-]{1,100}` (so the auto-derived branch name
    /// `worktree/<basename>` is legal).
    path: []const u8 = "",
    /// Optional branch name override. Defaults to `worktree/<basename(path)>`.
    /// Rarely needed — the default is consistent and predictable.
    branch: []const u8 = "",
    /// Optional base ref the new branch is created FROM, e.g. `origin/main`.
    /// The kanban task note carries it as the `Base:` line right after
    /// `#Notes UseGitWorktree` / `Path:`. Empty (the default) = branch
    /// from the repo's current HEAD, which is the pre-existing behavior.
    base: []const u8 = "",
    /// When true, remove the existing worktree binding for this session
    /// AND delete the worktree directory. `path` is ignored when true.
    clear: bool = false,
    /// The session_id this worktree is bound to. The LLM does NOT
    /// supply this — the tool_registry execX wrapper injects
    /// `ctx.session_id` at call time.
    session_id: []const u8 = "",
};

/// Tool definition for set_git_worktree
pub const set_git_worktree_tool_system_prompt =
    \\## Set Git Worktree Tool — Behavior (MANDATORY when applicable)
    \\If you are creating a worktree, or the human requests a git worktree,
    \\you MUST call `set_git_worktree` before any `bash`/`read_file`/`write_file`
    \\operation touches repo files. Never operate on the original repo path.
    \\
    \\- Canonical root (Option A): `$HOME/.config/nalar/.worktrees/<task-slug>`.
    \\  Example: `/home/you/.config/nalar/.worktrees/fix-login`.
    \\  The kanban dialog prefills this absolute path as the `Path:` line after
    \\  `#Notes UseGitWorktree`. Prefer it when given; when the note has no
    \\  `Path:` line, create the worktree under the same root derived from the
    \\  task name.
    \\- If a `Path:` value starts with `~/`, expand `~` to `$HOME` first —
    \\  `validatePath` rejects non-absolute paths.
    \\- The note may also carry a `Base: <ref>` line (e.g. `Base: origin/main`).
    \\  Pass that value as the `base` argument so the worktree branches FROM
    \\  that ref instead of the repo's current HEAD. Omit `base` when the note
    \\  has no `Base:` line.
    \\- `path` MUST NOT contain `..`.
    \\- The parent directory MUST exist.
    \\- Once set, all subsequent `bash`/`read_file`/`write_file` operations run
    \\  inside that worktree.
    \\- Pass `clear=true` to remove the binding before switching or finishing.
    \\
;
pub const set_git_worktree_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "set_git_worktree",
        .description =
        \\Create a git worktree at an absolute path you provide and bind it as the session's working directory. Canonical root is `$HOME/.config/nalar/.worktrees/<task-slug>` (e.g. '/home/you/.config/nalar/.worktrees/fix-login') — the kanban dialog prefills this as the `Path:` line after `#Notes UseGitWorktree`. A custom absolute path elsewhere is accepted for ad-hoc use. While bound, bash/read_file/write_file/text_replace/glob/search operate on the worktree instead of the session's original cwd. The branch defaults to 'worktree/<basename(path)>'. Pass `base` (e.g. 'origin/main') to create the branch FROM that ref instead of the repo's current HEAD — the kanban note carries it as the `Base:` line. If a path starts with `~/`, expand `~` to `$HOME` before calling (non-absolute paths are rejected). Call again with a different path to switch the binding to that worktree. Pass clear=true to remove the worktree directory and clear the binding.
        \\
        \\On error, recover by: (1) the tool pre-checks for path collisions before invoking git, so a "path already exists" error means the path is occupied by an existing worktree — pass `branch=<existing-branch>` to auto-bind to it, or pick a different path; (2) for branch conflicts (a different worktree already has the same branch checked out), pass `branch=''` to use the auto-derived name `worktree/<basename(path)>`; (3) NEVER `rm -rf` the conflicting path — there may be uncommitted work in it. Use `bash` + `git -C <repo> worktree list --porcelain` to inspect the current state if the error is unclear.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Absolute path to the worktree directory. Canonical root is `$HOME/.config/nalar/.worktrees/<task-slug>` (e.g. '/home/you/.config/nalar/.worktrees/fix-login'). Must be absolute, contain no '..' segments, no null bytes, be ≤ 4096 chars, and the parent directory must already exist. The basename must match [A-Za-z0-9._-]{1,100} (so the auto-derived branch name is legal). Expand a leading `~/` to `$HOME` before calling.",
                },
                .{
                    .name = "branch",
                    .type = "string",
                    .description = "Optional branch name override. Defaults to 'worktree/<basename(path)>'. Rarely needed.",
                },
                .{
                    .name = "base",
                    .type = "string",
                    .description = "Optional ref the new branch is created FROM, e.g. 'origin/main'. Take it verbatim from the `Base:` line after `#Notes UseGitWorktree` in the task note. Omit when there is no `Base:` line (the worktree then branches from the repo's current HEAD).",
                },
                .{
                    .name = "clear",
                    .type = "boolean",
                    .description = "If true, remove the worktree directory and clear the binding. 'path' is ignored when clear=true. Default: false.",
                },
            },
            .required = &.{},
        },
        .system_prompt = set_git_worktree_tool_system_prompt,
    },
};

/// Validate an absolute worktree path. Returns null on success, or an
/// error message on failure. Pure function — no IO. Also validates
/// the basename (which becomes the auto-derived branch name).
pub fn validatePath(path: []const u8) ?[]const u8 {
    if (path.len == 0) return "path cannot be empty";
    if (path.len > 4096) return "path exceeds 4096 characters";
    if (std.mem.indexOfScalar(u8, path, 0) != null) return "path contains null byte";
    if (!std.fs.path.isAbsolute(path)) return "path must be absolute";
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

/// Validate an optional `base` ref (e.g. `origin/main`). Empty is valid
/// and means "branch from the repo's current HEAD". Returns null on
/// success, or an error message. Pure — no IO.
///
/// The ref reaches `git` as an argv element (never as a shell string),
/// so this is defence against a leading `-` being read as a flag, plus
/// git's own `check-ref-format` rules for the cases that produce a
/// confusing raw stderr otherwise.
pub fn validateBaseRef(base: []const u8) ?[]const u8 {
    if (base.len == 0) return null;
    if (base.len > 255) return "base exceeds 255 characters";
    if (base[0] == '-') return "base must not start with '-'";
    if (base[0] == '/') return "base must not start with '/'";
    if (base[base.len - 1] == '/') return "base must not end with '/'";
    if (std.mem.indexOf(u8, base, "..") != null) return "base must not contain '..'";
    if (std.mem.indexOf(u8, base, "//") != null) return "base must not contain '//'";
    if (std.mem.indexOf(u8, base, "@{") != null) return "base must not contain '@{'";
    if (std.mem.endsWith(u8, base, ".lock")) return "base must not end with '.lock'";
    if (std.mem.eql(u8, base, "@")) return "base must not be '@'";
    for (base) |c| {
        const bad = c <= 0x20 or c == 0x7f or c == '~' or c == '^' or
            c == ':' or c == '?' or c == '*' or c == '[' or c == '\\';
        if (bad) return "base contains an invalid character (no spaces, '~', '^', ':', '?', '*', '[', '\\')";
    }
    return null;
}

/// Build the argv for `git worktree add`. With a non-empty `base` the new
/// branch is created from that ref
/// (`git worktree add -b <branch> <path> <base>`), otherwise from the
/// repo's current HEAD (no trailing start-point). Pure — the caller owns
/// the returned slice; the strings inside it are borrowed from the
/// arguments.
pub fn buildWorktreeAddArgv(
    allocator: std.mem.Allocator,
    branch: []const u8,
    worktree_path: []const u8,
    base: []const u8,
) ![][]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "worktree", "add", "-b", branch, worktree_path });
    if (base.len > 0) try argv.append(allocator, base);
    return argv.toOwnedSlice(allocator);
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

/// Classified state of a candidate worktree path. Returned by
/// `classifyPath`. The strings inside `plain_directory`,
/// `orphaned_worktree`, and `registered_worktree` are owned by the
/// returned value — the caller is responsible for freeing them
/// (typically by `classifyPath`'s `defer allocator.free` idiom or
/// by extracting the slices and using them before the classifyPath
/// scope exits).
pub const PathState = union(enum) {
    /// Path does not exist on disk. Git worktree add will create it.
    not_found,
    /// Path exists but has no `.git` file — a plain leftover directory.
    plain_directory: []const u8,
    /// Path exists, has a `.git` file, but is NOT in
    /// `git worktree list --porcelain`. The string is the gitdir value
    /// (e.g. `/abs/repo/.git/worktrees/foo`).
    orphaned_worktree: []const u8,
    /// Path exists AND is a registered worktree. All strings are owned
    /// by this struct.
    registered_worktree: RegisteredWorktree,

    pub const RegisteredWorktree = struct {
        /// Branch reference as reported by git, e.g. `refs/heads/refactor/x`.
        /// Empty string when the worktree is in detached HEAD state.
        branch_ref: []const u8,
        /// Short branch name (branch_ref minus the `refs/heads/` prefix),
        /// or empty string when detached.
        branch: []const u8,
        /// HEAD commit SHA (40 hex chars).
        commit: []const u8,
        /// Absolute path as reported by git worktree list.
        path: []const u8,
    };
};

/// Classify the state of `target` relative to the git worktree system
/// rooted at `repo_root`. Pure (no side effects beyond the returned
/// allocations). Errors only on allocation failure; on any unexpected
/// git state, returns a best-effort classification.
///
/// `repo_root` must be the absolute path to the git repository root
/// (NOT a worktree path — git worktree list is run from there).
pub fn classifyPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    target: []const u8,
) !PathState {
    // ── 1. Does `target` exist on disk? ──────────────────────────────
    std.Io.Dir.cwd().access(io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => {
            // Permission denied, etc. — treat as "exists but unreadable".
            // We can't classify further without disk access.
            return .{
                .plain_directory = try std.fmt.allocPrint(
                    allocator,
                    "path exists but is unreadable: {s}",
                    .{@errorName(err)},
                ),
            };
        },
    };

    // ── 2. Is target a registered worktree? ──────────────────────────
    const list_output = runGitWorktreeList(allocator, io, repo_root) catch |err| blk: {
        // If git worktree list itself fails (rare — usually means
        // repo_root is not a git repo), fall back to checking the .git file.
        std.debug.print("classifyPath: git worktree list failed: {s}\n", .{@errorName(err)});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(list_output);

    var line_it = std.mem.splitScalar(u8, list_output, '\n');
    var current_block: std.ArrayList(u8) = .empty;
    defer current_block.deinit(allocator);

    while (line_it.next()) |line| {
        if (line.len == 0) {
            // Blank line separates blocks. Check this block.
            if (current_block.items.len > 0) {
                if (try parseAndMatchBlock(
                    allocator,
                    current_block.items,
                    target,
                )) |rwt| {
                    return .{ .registered_worktree = rwt };
                }
                current_block.clearRetainingCapacity();
            }
        } else {
            current_block.appendSlice(allocator, line) catch continue;
            current_block.append(allocator, '\n') catch continue;
        }
    }
    // Trailing block without final blank line (rare but possible).
    if (current_block.items.len > 0) {
        if (try parseAndMatchBlock(allocator, current_block.items, target)) |rwt| {
            return .{ .registered_worktree = rwt };
        }
    }

    // ── 3. Exists but not a registered worktree. .git file? ──────────
    const git_path = std.fs.path.joinZ(allocator, &.{ target, ".git" }) catch {
        return .{ .plain_directory = try allocator.dupe(u8, "unclassifiable") };
    };
    defer allocator.free(git_path);

    const git_contents = std.Io.Dir.cwd().readFileAlloc(
        io,
        git_path,
        allocator,
        .limited(std.Io.Dir.max_path_bytes),
    ) catch {
        // No .git file → plain directory.
        const msg = try std.fmt.allocPrint(
            allocator,
            "plain directory at {s}",
            .{target},
        );
        return .{ .plain_directory = msg };
    };
    defer allocator.free(git_contents);

    // .git file points at /abs/repo/.git/worktrees/<name>
    if (std.mem.startsWith(u8, git_contents, "gitdir: ")) {
        return .{ .orphaned_worktree = try allocator.dupe(
            u8,
            git_contents["gitdir: ".len..],
        ) };
    }
    // .git file is malformed (e.g. raw gitdir without "gitdir: " prefix).
    return .{ .plain_directory = try std.fmt.allocPrint(
        allocator,
        "malformed .git file at {s}: {s}",
        .{ target, git_contents },
    ) };
}

/// Parse one block of `git worktree list --porcelain` output and return
/// the registered worktree if its `path` matches `target`. Returns
/// `null` if the block is for a different worktree.
///
/// One block looks like:
/// ```
/// worktree /abs/path
/// HEAD 0123456789abcdef...
/// branch refs/heads/refactor/x
/// ```
/// (The `branch` line is absent for detached HEAD worktrees.)
/// Do two strings denote the same directory, even though they were written
/// with different separators or a trailing slash?
///
/// git for Windows prints worktree paths with FORWARD slashes
/// (`worktree C:/Users/me/wt`) while the model, told to pass an absolute
/// path, sends BACKSLASHES (`C:\Users\me\wt`). A raw `std.mem.eql`
/// therefore never matches on Windows, so a live, registered worktree
/// falls through to the `.orphaned_worktree` arm — whose error tells the
/// model to run `git worktree prune && rm -rf <path>` on the very
/// directory that holds its in-flight work.
///
/// Canonicalization (`realPath`) would be the ideal answer but is not
/// always available: the not-found arm compares a path that does not exist
/// yet. So this compares on the normalized form instead — separators
/// unified, trailing separators dropped, and case ignored on Windows only
/// (where the filesystem does; on Linux `wt` and `WT` are two directories).
pub fn pathsDenoteSameDir(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        // Skip trailing/duplicate separators on both sides.
        while (i < a.len and isPathSep(a[i])) : (i += 1) {}
        while (j < b.len and isPathSep(b[j])) : (j += 1) {}

        const a_end = i >= a.len;
        const b_end = j >= b.len;
        if (a_end or b_end) return a_end and b_end;

        if (!eqlPathChar(a[i], b[j])) return false;
        i += 1;
        j += 1;
    }
}

fn isPathSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn eqlPathChar(a: u8, b: u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.toLower(a) == std.ascii.toLower(b);
    return a == b;
}

pub fn parseAndMatchBlock(
    allocator: std.mem.Allocator,
    block: []const u8,
    target: []const u8,
) !?PathState.RegisteredWorktree {
    var worktree_path: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var branch_ref_raw: ?[]const u8 = null;

    var line_it = std.mem.splitScalar(u8, block, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) {
            worktree_path = line["worktree ".len..];
        } else if (std.mem.startsWith(u8, line, "HEAD ")) {
            commit = line["HEAD ".len..];
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            branch_ref_raw = line["branch ".len..];
        }
        // "detached" line is present for detached HEAD; we just ignore it.
    }

    const wt_path = worktree_path orelse return null;
    // Not `std.mem.eql`: git's separator choice differs from the model's on
    // Windows, and a false negative here means advising `rm -rf` on a live
    // worktree. See `pathsDenoteSameDir`.
    // Not `std.mem.eql`: git's separator choice differs from the model's on
    // Windows, and a false negative here means advising `rm -rf` on a live
    // worktree. See `pathsDenoteSameDir`.
    if (!pathsDenoteSameDir(wt_path, target)) return null;

    const commit_owned = try allocator.dupe(u8, commit orelse "");
    errdefer allocator.free(commit_owned);

    const branch_ref_owned = if (branch_ref_raw) |br|
        try allocator.dupe(u8, br)
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(branch_ref_owned);

    // Derive short branch name from refs/heads/X.
    const short_branch: []u8 = if (branch_ref_raw) |br| brblk: {
        if (std.mem.startsWith(u8, br, "refs/heads/")) {
            break :brblk try allocator.dupe(u8, br["refs/heads/".len..]);
        }
        break :brblk try allocator.dupe(u8, br);
    } else blk: {
        break :blk try allocator.dupe(u8, "");
    };
    errdefer allocator.free(short_branch);

    return .{
        .branch_ref = branch_ref_owned,
        .branch = short_branch,
        .commit = commit_owned,
        .path = try allocator.dupe(u8, wt_path),
    };
}

/// Run `git -C <repo_root> worktree list --porcelain` and return the
/// raw stdout. On non-zero exit, returns a diagnostic string suitable
/// for surfacing in tool errors. The caller owns the returned slice.
fn runGitWorktreeList(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
) ![]u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{
            "git", "worktree", "list", "--porcelain",
        },
        .cwd = .{ .path = repo_root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.debug.print("git worktree list spawn failed: {s}\n", .{@errorName(err)});
        return try std.fmt.allocPrint(
            allocator,
            "failed to spawn git worktree list: {s}",
            .{@errorName(err)},
        );
    };

    const stdout_pipe = child.stdout orelse {
        const term = child.wait(io) catch {
            return try allocator.dupe(u8, "git worktree list: wait failed (no stdout pipe)");
        };
        return switch (term) {
            .exited => |code| if (code == 0)
                try allocator.dupe(u8, "")
            else
                try std.fmt.allocPrint(
                    allocator,
                    "git worktree list exited with code {d} (no stdout captured)",
                    .{code},
                ),
            .signal => try allocator.dupe(u8, "git worktree list killed by signal (no stdout)"),
            else => try allocator.dupe(u8, "git worktree list terminated abnormally (no stdout)"),
        };
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.Io.File.readStreaming(stdout_pipe, io, &.{&read_buf}) catch break;
        if (n == 0) break;
        if (stdout_buf.items.len < 64 * 1024) {
            const take = @min(n, 64 * 1024 - stdout_buf.items.len);
            stdout_buf.appendSlice(allocator, read_buf[0..take]) catch break;
        }
    }

    const term = child.wait(io) catch {
        return try allocator.dupe(u8, "git worktree list: failed to wait for child process");
    };
    return switch (term) {
        .exited => |code| {
            if (code == 0) return try allocator.dupe(u8, stdout_buf.items);
            std.debug.print("git worktree list failed (exit={d})\n", .{code});
            return try std.fmt.allocPrint(
                allocator,
                "git worktree list exited with code {d}",
                .{code},
            );
        },
        .signal => try allocator.dupe(u8, "git worktree list was killed by a signal"),
        else => try allocator.dupe(u8, "git worktree list terminated abnormally"),
    };
}

/// "Are these two branches the same logical work?" Returns true if both
/// branches share a known project-prefix family
/// (`refactor/`, `feature/`, `fix/`, `feat/`). Empty branches are never
/// compatible. Used by `executeSetGitWorktreeToString` to decide
/// whether an existing worktree at the path is a reasonable auto-bind
/// candidate for a new request.
pub fn isCompatibleBranchFamily(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const families = [_][]const u8{ "refactor/", "feature/", "fix/", "feat/" };
    for (families) |prefix| {
        if (std.mem.startsWith(u8, a, prefix) and
            std.mem.startsWith(u8, b, prefix)) return true;
    }
    return false;
}

/// Rewrite a raw git stderr string into a tool-friendly error message
/// that points the LLM at a recovery path. The default (no match) is
/// to return the raw stderr verbatim — we never lose information that
/// git provided, we only ADD context for the common cases.
///
/// `base` is the start-point the caller asked for (empty when the
/// worktree branches from HEAD). It disambiguates the
/// "invalid reference" case, where the unresolvable name is usually the
/// base ref rather than the new branch.
///
/// Caller owns the returned slice.
pub fn rewriteGitStderr(
    allocator: std.mem.Allocator,
    raw_stderr: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
    base: []const u8,
) ![]u8 {
    if (raw_stderr.len == 0) return try allocator.dupe(u8, "");

    // 1. "fatal: 'X' already exists" — precheck should have caught this,
    //    but if a race or precheck failure let it through, give actionable
    //    advice here.
    if (std.mem.indexOf(u8, raw_stderr, "already exists") != null) {
        return try std.fmt.allocPrint(allocator, "the directory '{s}' already exists on disk and could not be auto-bound. " ++
            "Either pick a different path, or run `git -C <repo> worktree list --porcelain` " ++
            "to see which branch currently occupies it, then re-call set_git_worktree with " ++
            "`branch=<existing-branch>` to bind to it.", .{worktree_path});
    }
    // 2. "fatal: 'X' is already checked out at 'Y'" — branch conflict,
    //    not a path conflict. The fix is to pick a different branch
    //    name (or let it default to worktree/<basename>).
    if (std.mem.indexOf(u8, raw_stderr, "is already checked out") != null) {
        return try std.fmt.allocPrint(allocator, "branch '{s}' is already checked out by another worktree. " ++
            "Pass `branch=''` (empty) to use the auto-derived branch name " ++
            "`worktree/<basename(path)>`, or pick a different branch name.", .{branch});
    }
    // 3. "fatal: not a git repository" — the session's cwd isn't in a
    //    git repo. This usually means the session was started outside
    //    of one, or a parent process chdir'd away.
    if (std.mem.indexOf(u8, raw_stderr, "not a git repository") != null) {
        return try allocator.dupe(
            u8,
            "the current working directory is not inside a git repository. " ++
                "set_git_worktree requires being called from within a git repo " ++
                "(or a worktree of one).",
        );
    }
    // 4. "fatal: invalid reference: X" — the branch name has bad
    //    characters, or the start-point (`base`) does not resolve.
    //    When a `base` was requested, that is the far more likely
    //    culprit (typically an `origin/<branch>` that has not been
    //    fetched yet), so point at it instead of at the new branch name.
    if (std.mem.indexOf(u8, raw_stderr, "invalid reference") != null) {
        if (base.len > 0) {
            return try std.fmt.allocPrint(allocator, "the base ref '{s}' could not be resolved by git. " ++
                "Run `git fetch origin` (the ref may not be fetched yet) or pick " ++
                "a different base branch, then retry. git said: {s}", .{ base, raw_stderr });
        }
        return try std.fmt.allocPrint(allocator, "the branch name '{s}' is invalid (git refused it). " ++
            "Valid branch names must not contain spaces, '..', '~', '^', ':', " ++
            "'?', '*', '[', '\\', and may not end with '.lock' or '/'.", .{branch});
    }
    // 5. Default: return the raw stderr verbatim. The user (LLM) gets
    //    exactly what git said, no more, no less.
    return try allocator.dupe(u8, raw_stderr);
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

/// Run `git worktree add -b <branch> <worktree_path> [<base>]` in the
/// given repository root. On success, returns an empty string. On failure
/// (non-zero exit, spawn failure, wait failure, signal), returns a
/// diagnostic string suitable for surfacing to the user — usually
/// git's own stderr (e.g. "fatal: '/foo' already exists"), or a
/// descriptive fallback that includes the exit code when stderr is
/// empty. The caller owns the returned slice.
fn runGitWorktreeAdd(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
    base: []const u8,
) ![]u8 {
    const argv = try buildWorktreeAddArgv(allocator, branch, worktree_path, base);
    defer allocator.free(argv);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = repo_root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.debug.print("git worktree add spawn failed: {s}\n", .{@errorName(err)});
        return try std.fmt.allocPrint(
            allocator,
            "failed to spawn git worktree add: {s}",
            .{@errorName(err)},
        );
    };

    // Short-lived command (worktree add is sub-second); use a bounded
    // blocking read rather than the threaded + timeout pattern that
    // bash.zig uses for arbitrary user commands. Cap the read to 64KB
    // so a hostile/buggy git can't OOM the tool.
    const stderr_pipe = child.stderr orelse {
        // No stderr pipe (shouldn't happen with .pipe above); just wait
        // and return based on exit code.
        const term = child.wait(io) catch {
            return try allocator.dupe(
                u8,
                "git worktree add: child process wait failed (no stderr pipe)",
            );
        };
        return switch (term) {
            .exited => |code| if (code == 0)
                try allocator.dupe(u8, "")
            else
                try std.fmt.allocPrint(
                    allocator,
                    "git worktree add exited with code {d} (no stderr captured)",
                    .{code},
                ),
            .signal => try allocator.dupe(u8, "git worktree add was killed by a signal (no stderr captured)"),
            else => try allocator.dupe(u8, "git worktree add terminated abnormally (no stderr captured)"),
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

    const term = child.wait(io) catch {
        return try allocator.dupe(u8, "git worktree add: failed to wait for child process");
    };
    switch (term) {
        .exited => |code| {
            if (code == 0) return try allocator.dupe(u8, "");
            const stderr_text = stderr_buf.items;
            std.debug.print("git worktree add failed (exit={d}): {s}\n", .{ code, stderr_text });
            // Surface git's own stderr to the user. Common messages:
            //   - "fatal: '/abs/path' already exists"
            //   - "fatal: not a git repository"
            //   - "fatal: invalid reference: <branch>"
            //   - "fatal: '<branch>' is already checked out at '<path>'"
            // These tell the user EXACTLY what's wrong and how to fix it,
            // which the previous generic "git worktree add failed" did not.
            return if (stderr_text.len == 0)
                try std.fmt.allocPrint(
                    allocator,
                    "git worktree add exited with code {d} (no stderr output)",
                    .{code},
                )
            else
                try allocator.dupe(u8, stderr_text);
        },
        .signal => {
            std.debug.print("git worktree add killed by signal\n", .{});
            return try allocator.dupe(u8, "git worktree add was killed by a signal");
        },
        else => return try allocator.dupe(u8, "git worktree add terminated abnormally"),
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

    // Optional base ref the new branch is created FROM (`origin/main`,
    // …). Trim first so a padded LLM argument does not trip the
    // character check, then validate before it reaches git's argv.
    const base = std.mem.trim(u8, input.base, " \t\r\n");
    if (validateBaseRef(base)) |err_msg| {
        return xmlError(allocator, session_id, err_msg);
    }

    // ── Precheck: classify the path before invoking git ──────────────────
    // Avoids the "fatal: '...' already exists" raw stderr the LLM has to
    // guess about. If the path is already a worktree on a compatible
    // branch, auto-bind (success) and let the session start working.
    // If incompatible, surface the existing branch + recovery options.
    {
        const state = classifyPath(allocator, io, cwd, worktree_path) catch |err| blk: {
            // classifyPath only fails on alloc; fall through to git and
            // let it produce a normal error.
            std.debug.print("set_git_worktree: classifyPath failed: {s}\n", .{@errorName(err)});
            break :blk PathState{ .not_found = {} };
        };
        // Free the state when we leave this scope (any variant with owned slices).
        defer freePathState(allocator, state);
        switch (state) {
            .not_found => {
                // Normal path: fall through to git worktree add.
            },
            .registered_worktree => |rwt| {
                // Path is already a worktree. Is the requested branch the same
                // (or a compatible family member)? If so, auto-bind; if not,
                // surface a structured error so the LLM can decide.
                const branch_matches = std.mem.eql(u8, rwt.branch, branch) or
                    std.mem.eql(u8, rwt.branch_ref, branch);
                const branch_compatible = isCompatibleBranchFamily(rwt.branch, branch);
                if (branch_matches or branch_compatible) {
                    std.debug.print(
                        "set_git_worktree: auto-bound session {s} to existing worktree on branch {s}\n",
                        .{ session_id, rwt.branch },
                    );
                    return successSetToXml(allocator, session_id, worktree_path, rwt.branch, "");
                }
                return xmlError(allocator, session_id, try std.fmt.allocPrint(allocator, "path '{s}' is already a worktree on branch '{s}' (you requested '{s}'). " ++
                    "Either pick a different path, or pass branch='{s}' to bind to the existing worktree, " ++
                    "or ask the user how to resolve the conflict (merge, rename, or remove the existing branch).", .{ worktree_path, rwt.branch, branch, rwt.branch }));
            },
            .orphaned_worktree => |gitdir| {
                return xmlError(allocator, session_id, try std.fmt.allocPrint(allocator, "path '{s}' is an orphaned worktree directory (has .git file pointing at {s}, " ++
                    "but is not registered with git). Run `git worktree prune && rm -rf {s}` to clean up, " ++
                    "then retry set_git_worktree.", .{ worktree_path, gitdir, worktree_path }));
            },
            .plain_directory => |desc| {
                return xmlError(allocator, session_id, try std.fmt.allocPrint(allocator, "path '{s}' already exists but is not a worktree directory ({s}). " ++
                    "Remove it manually (after backing up any important content) or pick a different path.", .{ worktree_path, desc }));
            },
        }
    }

    // runGitWorktreeAdd returns the captured git stderr on failure (or a
    // descriptive fallback including the exit code). Empty string = success.
    // We surface this directly in the XML error so the user sees WHY git
    // refused (e.g. "fatal: '/foo' already exists") instead of the previous
    // generic "git worktree add failed" which left them guessing.
    const git_detail = runGitWorktreeAdd(allocator, io, cwd, worktree_path, branch, base) catch |err| {
        // Alloc failure inside runGitWorktreeAdd — extremely rare.
        std.debug.print("set_git_worktree add dispatch failed: {s}\n", .{@errorName(err)});
        return xmlError(allocator, session_id, @errorName(err));
    };
    defer allocator.free(git_detail);
    if (git_detail.len > 0) {
        // Precheck may have let git run (race or precheck failure);
        // rewrite the raw stderr to add recovery guidance for the
        // common cases (path collision, branch conflict, non-repo cwd,
        // invalid branch name, unresolvable base ref). Unknown stderr
        // patterns pass through unchanged.
        const rewritten = rewriteGitStderr(allocator, git_detail, worktree_path, branch, base) catch |err| blk: {
            std.debug.print("set_git_worktree: rewriteGitStderr failed: {s}\n", .{@errorName(err)});
            break :blk git_detail;
        };
        defer if (rewritten.ptr != git_detail.ptr) allocator.free(rewritten);
        return xmlError(allocator, session_id, rewritten);
    }
    return successSetToXml(allocator, session_id, worktree_path, branch, base);
}

/// Free the owned slices inside a `PathState`. Safe to call on any
/// variant (no-op for `not_found`, frees the string for the others).
pub fn freePathState(allocator: std.mem.Allocator, state: PathState) void {
    switch (state) {
        .not_found => {},
        .plain_directory => |s| allocator.free(s),
        .orphaned_worktree => |s| allocator.free(s),
        .registered_worktree => |rwt| {
            allocator.free(rwt.branch_ref);
            allocator.free(rwt.branch);
            allocator.free(rwt.commit);
            allocator.free(rwt.path);
        },
    }
}

/// JSON payload for set_git_worktree results. Matches the frontend's
/// `parseSetGitWorktree` expectations (`path`/`branch`/`cleared`/`created`/
/// `error`) plus `session_id`/`base`/`note` context. `std.json` handles all
/// escaping — no manual XML layer.
pub const SetGitWorktreeJSON = struct {
    session_id: []const u8,
    created: bool = false,
    cleared: bool = false,
    path: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    base: ?[]const u8 = null,
    note: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Guidance handed back after a successful worktree create. Forge-neutral
/// on purpose: the repo may live on GitHub OR GitLab, and telling a
/// GitLab user to run `gh pr create` sends them to a CLI that cannot
/// work. Both spellings are named so the agent picks by the repo's
/// remote, and `set_pull_request` auto-detects the provider from the URL
/// either way.
pub const worktree_pr_note =
    "If the user asks to open a pull request or a merge request, or you want to initialize one for this branch, create it with the forge CLI for this repo — `gh pr create` on GitHub, `glab mr create` on GitLab — or use the Create-PR dialog, then call the agent tool `set_pull_request` with the PR/MR URL to bind it to this session.";

pub fn jsonSet(allocator: std.mem.Allocator, session_id: []const u8, path: []const u8, branch: []const u8, base: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(allocator, SetGitWorktreeJSON{
        .session_id = session_id,
        .created = true,
        .path = path,
        .branch = branch,
        .base = if (base.len > 0) base else null,
        .note = worktree_pr_note,
    }, .{}) catch "";
}

pub fn jsonClear(allocator: std.mem.Allocator, session_id: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(allocator, SetGitWorktreeJSON{
        .session_id = session_id,
        .cleared = true,
    }, .{}) catch "";
}

/// Generate error JSON response (session_id is present).
pub fn jsonError(allocator: std.mem.Allocator, session_id: []const u8, error_msg: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(allocator, SetGitWorktreeJSON{
        .session_id = session_id,
        .created = false,
        .@"error" = error_msg,
    }, .{}) catch "";
}

/// Generate error JSON response when session_id is unavailable.
pub fn jsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(allocator, SetGitWorktreeJSON{
        .session_id = "",
        .created = false,
        .@"error" = error_msg,
    }, .{}) catch "{\"created\":false,\"error\":\"UnknownError\"}";
}

// Legacy aliases kept so old grep-based tests and any external callers
// keep resolving; all emit JSON now.
pub const xmlError = jsonError;
pub const xmlErrorEmpty = jsonErrorEmpty;
fn successSetToXml(allocator: std.mem.Allocator, session_id: []const u8, path: []const u8, branch: []const u8, base: []const u8) []const u8 {
    return jsonSet(allocator, session_id, path, branch, base);
}
fn successClearToXml(allocator: std.mem.Allocator, session_id: []const u8) []const u8 {
    return jsonClear(allocator, session_id);
}

// ===== Tests merged from set_git_worktree_test.zig (2026-09-29 flatten) =====
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const TOOL_PATH = "src/modules/agent/tools/set_git_worktree.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
/// Read a source file from disk, relative to the project root, sliced down
/// to its implementation half when it is THIS file. The inline suite at the
/// bottom carries the very needles these tests assert on (`<worktree>`,
/// `xmlError(..., "git worktree add failed")`), so an un-sliced read makes
/// the "must be absent" checks match their own assertion text.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(4 * 1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    const impl = try text_normalize.implementationOnly(allocator, normalized);
    allocator.free(normalized); // the caller owns `impl`, not this intermediate
    return impl;
}

// ─── Static source-check tests ────────────────────────────────────────────

test "set_git_worktree tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, ".name = \"set_git_worktree\"") == null) {
        std.debug.print("!! set_git_worktree.zig does not define the tool with .name = \"set_git_worktree\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "set_git_worktree tool description mentions absolute path" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "absolute path") == null) {
        std.debug.print("!! set_git_worktree.zig description does not mention 'absolute path' !!\n", .{});
        return error.AbsolutePathMissing;
    }
}

test "set_git_worktree input struct has path + clear + branch fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "path: []const u8") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'path' field !!\n", .{});
        return error.PathFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "clear: bool") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'clear' field !!\n", .{});
        return error.ClearFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "branch: []const u8") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'branch' field !!\n", .{});
        return error.BranchFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "base: []const u8") == null) {
        std.debug.print("!! SetGitWorktreeInput is missing the 'base' field !!\n", .{});
        return error.BaseFieldMissing;
    }
}

test "xmlError for add failure surfaces git stderr, not a generic literal" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Regression: the previous line was
    //     return xmlError(allocator, session_id, "git worktree add failed");
    // which left the user with zero info about WHY git refused (path
    // already exists? not a git repo? bad branch name?). The fix
    // surfaces the captured git stderr (e.g. "fatal: '/foo' already exists")
    // via runGitWorktreeAdd's new ![]u8 return type. This test guards
    // against the generic literal coming back.
    //
    // We look for the specific xmlError call pattern (not just the bare
    // phrase) so the test does not false-positive on docstring mentions
    // of the old behavior.
    if (std.mem.indexOf(u8, source, "xmlError(allocator, session_id, \"git worktree add failed\")") != null) {
        std.debug.print("!! set_git_worktree.zig still calls xmlError(..., \"git worktree add failed\") — surface git's captured stderr instead !!\n", .{});
        return error.GenericGitWorktreeAddErrorLiteralPresent;
    }
}

test "runGitWorktreeAdd returns captured stderr on failure" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The new contract: runGitWorktreeAdd returns ![]u8 — empty string
    // on success, captured stderr (or descriptive fallback) on failure.
    // The caller uses the returned string as the XML error detail.
    // Check that the function signature includes the ![]u8 return type
    // and that the caller binds the result to a `git_detail` variable.
    if (std.mem.indexOf(u8, source, "fn runGitWorktreeAdd(") == null) {
        std.debug.print("!! runGitWorktreeAdd function is missing !!\n", .{});
        return error.RunGitWorktreeAddMissing;
    }
    if (std.mem.indexOf(u8, source, "const git_detail = runGitWorktreeAdd(") == null) {
        std.debug.print("!! caller of runGitWorktreeAdd does not bind the result to a 'git_detail' variable !!\n", .{});
        return error.GitDetailBindingMissing;
    }
    if (std.mem.indexOf(u8, source, "if (git_detail.len > 0)") == null) {
        std.debug.print("!! caller of runGitWorktreeAdd does not check git_detail.len > 0 to surface stderr !!\n", .{});
        return error.GitDetailCheckMissing;
    }
}

// ─── Behavioral tests for validatePath ────────────────────────────────────

test "validatePath accepts valid absolute paths" {
    const valid_paths = [_][]const u8{
        "/home/me/proj/.worktrees/auth-fix",
        "/tmp/experiments/rpc-rewrite",
        "/a/b/c",
        "/x",
    };
    for (valid_paths) |p| {
        try testing.expect(validatePath(p) == null);
    }
}

test "validatePath rejects empty path" {
    try testing.expect(validatePath("") != null);
}

test "validatePath rejects relative path" {
    try testing.expect(validatePath("foo/bar") != null);
}

test "validatePath rejects path with .." {
    try testing.expect(validatePath("/home/me/../etc/passwd") != null);
}

test "validatePath rejects null byte" {
    try testing.expect(validatePath("/foo\x00bar") != null);
}

test "validatePath rejects too-long path" {
    var long_path: [5000]u8 = undefined;
    @memset(long_path[0..], '/');
    long_path[0] = '/';
    for (1..5000) |i| long_path[i] = 'a';
    try testing.expect(validatePath(long_path[0..]) != null);
}

test "validatePath rejects illegal basename" {
    const bad_paths = [_][]const u8{
        "/foo/hello world",
        "/foo/bad!char",
        "/foo/.",
        "/foo/..",
    };
    for (bad_paths) |p| {
        try testing.expect(validatePath(p) != null);
    }
}

// ─── Behavioral tests for validateBasename ────────────────────────────────

test "validateBasename accepts legal names" {
    const ok = [_][]const u8{ "auth-fix", "v2", "x", "a..b" };
    for (ok) |n| {
        try testing.expect(validateBasename(n) == null);
    }
}

test "validateBasename rejects illegal names" {
    const bad = [_][]const u8{ "hello world", "a/b", ".", ".." };
    for (bad) |n| {
        try testing.expect(validateBasename(n) != null);
    }
}

// ─── Behavioral tests for deriveBranchFromPath ────────────────────────────

test "deriveBranchFromPath returns worktree/<basename>" {
    const allocator = testing.allocator;

    const b1 = try deriveBranchFromPath(allocator, "/abs/.worktrees/auth-fix");
    defer allocator.free(b1);
    try testing.expectEqualStrings("worktree/auth-fix", b1);

    const b2 = try deriveBranchFromPath(allocator, "/tmp/foo");
    defer allocator.free(b2);
    try testing.expectEqualStrings("worktree/foo", b2);

    const b3 = try deriveBranchFromPath(allocator, "/Users/me/proj/.worktrees/fix-bug-123");
    defer allocator.free(b3);
    try testing.expectEqualStrings("worktree/fix-bug-123", b3);
}

// ─── Static wiring tests (Chunk 3) ───────────────────────────────────────

const TOOL_REGISTRY_PATH = "src/agentic_loop/tools_equipped.zig"; // legacy alias; tool_registry.zig was deleted 2026-08-06 — see plan
/// The exec function was migrated from `tool_registry.zig` to
/// `src/agentic_loop/tools_exec_set_git_worktree.zig`
/// (re-exported as `agentic_loop_mod.tools.execSetGitWorktree`).
const TOOL_EXEC_PATH = "src/agentic_loop/tools_exec_set_git_worktree.zig";
/// The cwd_override field moved with the rest of ToolExecContext to
/// `src/agentic_loop/tools.zig`. This is the new
/// canonical home of the struct declaration.
const TOOL_EXEC_CONTEXT_PATH = "src/agentic_loop/tools.zig";
/// The comptime tool list moved out of `tool_registry.zig` into
/// `src/agentic_loop/tools_equipped.zig` (which
/// `agentic_loop.tools.all_agent_tools` re-exports as `equips`).
/// Each entry in that comptime `tools_list` array uses the
/// trailing-comma format (`.tool_name,`) that this test grep matches.
const TOOLS_EQUIPPED_PATH = "src/agentic_loop/tools_equipped.zig";

test "tools_equipped.zig imports set_git_worktree module" {
    // After deduplication of `UNIFIED_TOOL_REGISTRY` (2026-08-06), the
    // registry body lives in `tools_equipped.zig` and no longer lives
    // in `tool_registry.zig`. This test now reads the imports from
    // the canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "const set_git_worktree_mod = nalarcore.set_git_worktree;") == null) {
        std.debug.print("!! tools_equipped.zig does not bind set_git_worktree_mod = nalarcore.set_git_worktree !!\n", .{});
        return error.SetGitWorktreeModBindingMissing;
    }
}

test "agentic_loop defines execSetGitWorktree" {
    // After the migration, the exec function lives in
    // `tools_exec_set_git_worktree.zig` (re-exported via
    // `agentic_loop_mod.tools.execSetGitWorktree`). The DB
    // persistence call (`updateSessionGitWorktreeCwd`) moved with it.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn execSetGitWorktree(") == null) {
        std.debug.print("!! tools_exec_set_git_worktree.zig does not define pub fn execSetGitWorktree !!\n", .{});
        return error.ExecSetGitWorktreeMissing;
    }
    if (std.mem.indexOf(u8, source, "updateSessionGitWorktreeCwd") == null) {
        std.debug.print("!! execSetGitWorktree does not call updateSessionGitWorktreeCwd for DB persistence !!\n", .{});
        return error.PersistenceCallMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains set_git_worktree entry" {
    // The registry body moved from `tool_registry.zig` (deleted) to
    // `tools_equipped.zig` (canonical home) on 2026-08-06. The test
    // now reads from the canonical file. tools_equipped.zig imports
    // `tools = @import("tools.zig")` directly, so the `.exec` binding
    // is `tools.execSetGitWorktree` (NOT `agentic_loop_mod.tools.execSetGitWorktree`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    // The registry entry should be a struct literal that wires the
    // exec function and the tool definition together.
    if (std.mem.indexOf(u8, source, ".name = \"set_git_worktree\"") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the set_git_worktree name entry !!\n", .{});
        return error.RegistryNameEntryMissing;
    }
    if (std.mem.indexOf(u8, source, ".exec = tools.execSetGitWorktree") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execSetGitWorktree !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (std.mem.indexOf(u8, source, ".tool_def = set_git_worktree_mod.set_git_worktree_tool") == null) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = set_git_worktree_mod.set_git_worktree_tool !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains set_git_worktree tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "set_git_worktree_mod.set_git_worktree_tool,") == null) {
        std.debug.print("!! tools_equipped.zig comptime list is missing set_git_worktree_mod.set_git_worktree_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "ToolExecContext has cwd_override field (Plan B forward-compat)" {
    // After migration, the canonical ToolExecContext struct lives in
    // `agentic_loop/tools.zig` (re-exported from tool_registry.zig).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_CONTEXT_PATH);
    defer allocator.free(source);
    // Plan B (conservative) for the CWD override: add the field as
    // future-proofing. Mutating it from a tool exec is currently
    // dead-letter (ToolExecContext is passed by value), but the field
    // is required to be present so a follow-up plan can opt exec
    // functions in to read it.
    if (std.mem.indexOf(u8, source, "cwd_override: ?[]const u8 = null") == null) {
        std.debug.print("!! ToolExecContext is missing the cwd_override field !!\n", .{});
        return error.CwdOverrideFieldMissing;
    }
}

// ─── Chunk 1 helpers: classifyPath / runGitWorktreeList ───────────────

test "set_git_worktree.zig defines PathState tagged union" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const PathState = union(enum) {") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'pub const PathState = union(enum)' !!\n", .{});
        return error.PathStateMissing;
    }
    if (std.mem.indexOf(u8, source, "not_found,") == null) {
        std.debug.print("!! PathState is missing the 'not_found' variant !!\n", .{});
        return error.PathStateNotFoundMissing;
    }
    if (std.mem.indexOf(u8, source, "plain_directory:") == null) {
        std.debug.print("!! PathState is missing the 'plain_directory' variant !!\n", .{});
        return error.PathStatePlainDirectoryMissing;
    }
    if (std.mem.indexOf(u8, source, "orphaned_worktree:") == null) {
        std.debug.print("!! PathState is missing the 'orphaned_worktree' variant !!\n", .{});
        return error.PathStateOrphanedWorktreeMissing;
    }
    if (std.mem.indexOf(u8, source, "registered_worktree: RegisteredWorktree") == null) {
        std.debug.print("!! PathState is missing the 'registered_worktree' variant !!\n", .{});
        return error.PathStateRegisteredWorktreeMissing;
    }
}

test "set_git_worktree.zig defines classifyPath function" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn classifyPath(") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'pub fn classifyPath' !!\n", .{});
        return error.ClassifyPathMissing;
    }
    // Must take the 4 documented args: allocator, io, repo_root, target.
    if (std.mem.indexOf(u8, source, "pub fn classifyPath(\n    allocator: std.mem.Allocator,\n    io: std.Io,\n    repo_root: []const u8,\n    target: []const u8,\n) !PathState {") == null) {
        std.debug.print("!! classifyPath signature does not match the documented 4-arg form !!\n", .{});
        return error.ClassifyPathSignatureMismatch;
    }
}

test "set_git_worktree.zig defines runGitWorktreeList (private)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "fn runGitWorktreeList(") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'fn runGitWorktreeList' !!\n", .{});
        return error.RunGitWorktreeListMissing;
    }
    // Must use --porcelain (machine-readable output) for parsing.
    if (std.mem.indexOf(u8, source, "\"--porcelain\"") == null) {
        std.debug.print("!! runGitWorktreeList does not pass --porcelain to git !!\n", .{});
        return error.RunGitWorktreeListNotPorcelain;
    }
}

// ─── Behavioral tests for isCompatibleBranchFamily (pure) ──────────────

test "isCompatibleBranchFamily matches same-family branches" {
    // refactor/x ↔ refactor/y  →  same family
    try testing.expect(isCompatibleBranchFamily("refactor/x", "refactor/y"));
    // feature/x ↔ feature/y  →  same family
    try testing.expect(isCompatibleBranchFamily("feature/auth", "feature/routines"));
    // fix/x ↔ fix/y  →  same family
    try testing.expect(isCompatibleBranchFamily("fix/typo", "fix/bug-42"));
    // feat/x ↔ feat/y  →  same family
    try testing.expect(isCompatibleBranchFamily("feat/ui-redesign", "feat/api-rename"));
    // main ↔ main  →  no family, but the question is "compatible?" — same
    //   exact branch name is the strongest compatibility, but this helper
    //   only tests family prefixes (used as a tie-breaker, not a final answer).
    try testing.expect(!isCompatibleBranchFamily("main", "main"));
    // worktree/x ↔ refactor/x  →  different family
    try testing.expect(!isCompatibleBranchFamily("worktree/x", "refactor/x"));
    // Empty strings are never compatible.
    try testing.expect(!isCompatibleBranchFamily("", "refactor/x"));
    try testing.expect(!isCompatibleBranchFamily("refactor/x", ""));
    try testing.expect(!isCompatibleBranchFamily("", ""));
    // One branch in a known family, the other in a non-family prefix.
    try testing.expect(!isCompatibleBranchFamily("refactor/x", "main"));
    try testing.expect(!isCompatibleBranchFamily("main", "refactor/x"));
}

test "isCompatibleBranchFamily rejects cross-family combinations" {
    const cases = [_][2][]const u8{
        .{ "refactor/x", "feature/y" },
        .{ "feature/x", "fix/y" },
        .{ "fix/x", "feat/y" },
        .{ "feat/x", "refactor/y" },
    };
    for (cases) |pair| {
        try testing.expect(!isCompatibleBranchFamily(pair[0], pair[1]));
    }
}

// ─── Chunk 2: precheck wired into executeSetGitWorktreeToString ────────

test "executeSetGitWorktreeToString calls classifyPath before runGitWorktreeAdd" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The precheck call must appear textually before the
    // runGitWorktreeAdd call in the source (Zig source order is
    // execution order; the precheck must run first).
    const pre_idx = std.mem.indexOf(u8, source, "classifyPath(allocator, io, cwd, worktree_path)") orelse {
        std.debug.print("!! set_git_worktree.zig does not call classifyPath on worktree_path !!\n", .{});
        return error.ClassifyPathCallMissing;
    };
    const add_idx = std.mem.indexOf(u8, source, "runGitWorktreeAdd(allocator, io, cwd, worktree_path, branch, base)") orelse {
        std.debug.print("!! set_git_worktree.zig is missing the runGitWorktreeAdd call !!\n", .{});
        return error.RunGitWorktreeAddCallMissing;
    };
    if (pre_idx >= add_idx) {
        std.debug.print("!! classifyPath must be called BEFORE runGitWorktreeAdd !!\n", .{});
        return error.ClassifyPathNotBeforeRunGitWorktreeAdd;
    }
}

test "executeSetGitWorktreeToString handles all 4 PathState variants" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Look for the explicit switch arm names that the precheck must
    // contain. (Zig's switch on tagged unions does not require an
    // else branch if all variants are listed, but the runtime error
    // for an unhandled variant is unhelpful — we want all 4.)
    const required_arms = [_][]const u8{
        ".not_found =>",
        ".registered_worktree =>",
        ".orphaned_worktree =>",
        ".plain_directory =>",
    };
    for (required_arms) |arm| {
        if (std.mem.indexOf(u8, source, arm) == null) {
            std.debug.print("!! set_git_worktree.zig is missing switch arm '{s}' !!\n", .{arm});
            return error.SwitchArmMissing;
        }
    }
}

test "executeSetGitWorktreeToString auto-binds on compatible branch" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The auto-bind path should call successSetToXml directly from
    // inside the .registered_worktree arm, without re-invoking git.
    // The specific marker is "auto-bound session" — that's the log
    // line + the early return is on the same block.
    if (std.mem.indexOf(u8, source, "auto-bound session") == null) {
        std.debug.print("!! set_git_worktree.zig is missing the 'auto-bound session' log line !!\n", .{});
        return error.AutoBindLogMissing;
    }
    if (std.mem.indexOf(u8, source, "isCompatibleBranchFamily(rwt.branch, branch)") == null) {
        std.debug.print("!! set_git_worktree.zig does not call isCompatibleBranchFamily in the precheck !!\n", .{});
        return error.IsCompatibleBranchFamilyCallMissing;
    }
}

test "set_git_worktree.zig defines freePathState helper" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn freePathState(") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'pub fn freePathState' !!\n", .{});
        return error.FreePathStateMissing;
    }
}

test "structured error for incompatible branch mentions existing branch name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The XML error must include the existing branch name and the
    // requested branch name so the LLM can recognize the conflict.
    if (std.mem.indexOf(u8, source, "is already a worktree on branch") == null) {
        std.debug.print("!! set_git_worktree.zig's precheck error does not mention 'is already a worktree on branch' !!\n", .{});
        return error.StructuredErrorMissingBranchName;
    }
    if (std.mem.indexOf(u8, source, "you requested") == null) {
        std.debug.print("!! set_git_worktree.zig's precheck error does not mention the requested branch !!\n", .{});
        return error.StructuredErrorMissingRequestedBranch;
    }
}

// ─── Chunk 3: rewriteGitStderr ─────────────────────────────────────────

test "set_git_worktree.zig defines rewriteGitStderr function" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub fn rewriteGitStderr(") == null) {
        std.debug.print("!! set_git_worktree.zig is missing 'pub fn rewriteGitStderr' !!\n", .{});
        return error.RewriteGitStderrMissing;
    }
    if (std.mem.indexOf(u8, source, "already exists") == null) {
        std.debug.print("!! rewriteGitStderr does not handle 'already exists' pattern !!\n", .{});
        return error.RewriteGitStderrMissingAlreadyExists;
    }
    if (std.mem.indexOf(u8, source, "is already checked out") == null) {
        std.debug.print("!! rewriteGitStderr does not handle 'is already checked out' pattern !!\n", .{});
        return error.RewriteGitStderrMissingAlreadyCheckedOut;
    }
    if (std.mem.indexOf(u8, source, "not a git repository") == null) {
        std.debug.print("!! rewriteGitStderr does not handle 'not a git repository' pattern !!\n", .{});
        return error.RewriteGitStderrMissingNotARepo;
    }
    if (std.mem.indexOf(u8, source, "invalid reference") == null) {
        std.debug.print("!! rewriteGitStderr does not handle 'invalid reference' pattern !!\n", .{});
        return error.RewriteGitStderrMissingInvalidReference;
    }
}

test "rewriteGitStderr rewrites 'already exists' to recovery advice" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: '/abs/.worktrees/foo' already exists",
        "/abs/.worktrees/foo",
        "worktree/foo",
        "",
    );
    defer allocator.free(out);
    // The original "fatal: ... already exists" must be GONE (replaced),
    // and the new message must mention recovery.
    if (std.mem.indexOf(u8, out, "fatal:") != null) {
        std.debug.print("!! rewriteGitStderr left the 'fatal:' prefix in the output !!\n", .{});
        return error.RewriteKeptFatalPrefix;
    }
    if (std.mem.indexOf(u8, out, "git -C <repo> worktree list --porcelain") == null) {
        std.debug.print("!! rewriteGitStderr's 'already exists' branch does not suggest worktree list !!\n", .{});
        return error.RewriteMissingWorktreeListSuggestion;
    }
}

test "rewriteGitStderr rewrites 'is already checked out' to branch advice" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: 'worktree/foo' is already checked out at '/abs/.worktrees/foo'",
        "/abs/.worktrees/new",
        "worktree/foo",
        "",
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "auto-derived branch name") == null) {
        std.debug.print("!! rewriteGitStderr's branch-conflict branch does not mention auto-derived branch name !!\n", .{});
        return error.RewriteMissingAutoDerivedSuggestion;
    }
}

test "rewriteGitStderr rewrites 'not a git repository'" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: not a git repository (or any parent up to mount point /)",
        "/abs/.worktrees/foo",
        "worktree/foo",
        "",
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "set_git_worktree requires being called from within a git repo") == null) {
        std.debug.print("!! rewriteGitStderr's not-a-repo branch does not mention the git-repo requirement !!\n", .{});
        return error.RewriteMissingNotARepoExplanation;
    }
}

test "rewriteGitStderr rewrites 'invalid reference' to branch-name rules" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: invalid reference: bad..name",
        "/abs/.worktrees/foo",
        "bad..name",
        "",
    );
    defer allocator.free(out);
    if (std.mem.indexOf(u8, out, "Valid branch names must not contain") == null) {
        std.debug.print("!! rewriteGitStderr's invalid-reference branch does not explain branch-name rules !!\n", .{});
        return error.RewriteMissingBranchRules;
    }
}

test "rewriteGitStderr blames the base ref when one was requested" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(
        allocator,
        "fatal: invalid reference: origin/nope",
        "/abs/.worktrees/foo",
        "worktree/foo",
        "origin/nope",
    );
    defer allocator.free(out);
    // The base ref is the likely culprit, so the message must name it and
    // point at `git fetch` rather than at the new branch name.
    if (std.mem.indexOf(u8, out, "origin/nope") == null) {
        std.debug.print("!! rewriteGitStderr does not name the unresolvable base ref !!\n", .{});
        return error.RewriteMissingBaseRefName;
    }
    if (std.mem.indexOf(u8, out, "git fetch origin") == null) {
        std.debug.print("!! rewriteGitStderr does not suggest `git fetch origin` for an unresolved base !!\n", .{});
        return error.RewriteMissingFetchSuggestion;
    }
}

test "rewriteGitStderr passes through unknown stderr verbatim" {
    const allocator = testing.allocator;
    const unknown = "fatal: some weird edge-case error we did not anticipate\n";
    const out = try rewriteGitStderr(allocator, unknown, "/x", "worktree/x", "");
    defer allocator.free(out);
    try testing.expectEqualStrings(unknown, out);
}

test "rewriteGitStderr returns empty for empty input" {
    const allocator = testing.allocator;
    const out = try rewriteGitStderr(allocator, "", "/x", "worktree/x", "");
    defer allocator.free(out);
    try testing.expectEqualStrings("", out);
}

// ─── Base ref (kanban `Base:` line) ────────────────────────────────────

test "validateBaseRef accepts refs the kanban dialog emits" {
    const ok = [_][]const u8{
        "",
        "origin/main",
        "origin/feat/some-branch",
        "main",
        "worktree/foo-1757792000000",
        "v1.2.3",
    };
    for (ok) |ref| {
        if (validateBaseRef(ref)) |msg| {
            std.debug.print("!! validateBaseRef rejected '{s}': {s} !!\n", .{ ref, msg });
            return error.ValidBaseRefRejected;
        }
    }
}

test "validateBaseRef rejects flag-shaped and malformed refs" {
    const bad = [_][]const u8{
        "-b",
        "--hard",
        "origin/ main",
        "origin/..main",
        "origin//main",
        "origin/main.lock",
        "origin/main@{1}",
        "origin/ma~in",
        "origin/ma^in",
        "origin/ma:in",
        "origin/ma?in",
        "origin/ma*in",
        "origin/ma[in",
        "origin/ma\\in",
        "/origin/main",
        "origin/main/",
    };
    for (bad) |ref| {
        if (validateBaseRef(ref) == null) {
            std.debug.print("!! validateBaseRef accepted invalid ref '{s}' !!\n", .{ref});
            return error.InvalidBaseRefAccepted;
        }
    }
}

test "buildWorktreeAddArgv omits the start-point when base is empty" {
    const argv = try buildWorktreeAddArgv(testing.allocator, "worktree/x", "/tmp/wt/x", "");
    defer testing.allocator.free(argv);

    const expected = [_][]const u8{ "git", "worktree", "add", "-b", "worktree/x", "/tmp/wt/x" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "buildWorktreeAddArgv appends the base as the start-point" {
    const argv = try buildWorktreeAddArgv(testing.allocator, "worktree/x", "/tmp/wt/x", "origin/main");
    defer testing.allocator.free(argv);

    const expected = [_][]const u8{ "git", "worktree", "add", "-b", "worktree/x", "/tmp/wt/x", "origin/main" };
    try testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try testing.expectEqualStrings(want, got);
}

test "runGitWorktreeAdd receives the base from executeSetGitWorktreeToString" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The base must flow into the git call, not just be parsed.
    if (std.mem.indexOf(u8, source, "runGitWorktreeAdd(allocator, io, cwd, worktree_path, branch, base)") == null) {
        std.debug.print("!! set_git_worktree.zig does not pass `base` to runGitWorktreeAdd !!\n", .{});
        return error.BaseNotForwardedToGit;
    }
    if (std.mem.indexOf(u8, source, "validateBaseRef(base)") == null) {
        std.debug.print("!! set_git_worktree.zig does not validate `base` !!\n", .{});
        return error.BaseNotValidated;
    }
}

test "set_git_worktree tool schema exposes the base property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, ".name = \"base\"") == null) {
        std.debug.print("!! set_git_worktree tool schema is missing the `base` property !!\n", .{});
        return error.BasePropertyMissing;
    }
    // The system prompt must teach the LLM where the value comes from,
    // otherwise the kanban `Base:` line stays inert text.
    if (std.mem.indexOf(u8, source, "`Base:` line") == null) {
        std.debug.print("!! set_git_worktree system prompt does not mention the `Base:` line !!\n", .{});
        return error.BaseNoteNotPrompted;
    }
}

// ─── Chunk 4: tool description recovery guidance ───────────────────────

test "set_git_worktree description mentions recovery on error" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "On error, recover by:") == null) {
        std.debug.print("!! set_git_worktree.zig description is missing the 'On error, recover by:' guidance !!\n", .{});
        return error.RecoveryGuidanceMissing;
    }
    if (std.mem.indexOf(u8, source, "pass `branch=<existing-branch>` to auto-bind to it") == null) {
        std.debug.print("!! set_git_worktree.zig description does not mention auto-bind recovery !!\n", .{});
        return error.AutoBindRecoveryMissing;
    }
}

test "set_git_worktree description warns against rm -rf" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "NEVER `rm -rf` the conflicting path") == null) {
        std.debug.print("!! set_git_worktree.zig description does not warn against 'rm -rf' !!\n", .{});
        return error.RmRfWarningMissing;
    }
    if (std.mem.indexOf(u8, source, "uncommitted work") == null) {
        std.debug.print("!! set_git_worktree.zig description does not mention uncommitted work risk !!\n", .{});
        return error.UncommittedWorkWarningMissing;
    }
}

test "success SET json includes PR hint note with set_pull_request" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "worktree_pr_note") == null) {
        std.debug.print("!! set_git_worktree.zig does not define worktree_pr_note !!\n", .{});
        return error.SuccessNoteMissing;
    }
    if (std.mem.indexOf(u8, source, "set_pull_request") == null) {
        std.debug.print("!! success note does not mention set_pull_request !!\n", .{});
        return error.SuccessNoteMissingSetPullRequest;
    }
    // Both forges must be named. Pinning only `gh pr create` is how a
    // GitLab user ends up being told to run a CLI that cannot open a
    // merge request for them.
    if (std.mem.indexOf(u8, source, "gh pr create") == null) {
        std.debug.print("!! success note does not mention `gh pr create` !!\n", .{});
        return error.SuccessNoteMissingGhPrCreate;
    }
    if (std.mem.indexOf(u8, source, "glab mr create") == null) {
        std.debug.print("!! success note does not mention `glab mr create` (GitLab) !!\n", .{});
        return error.SuccessNoteMissingGlabMrCreate;
    }
    if (std.mem.indexOf(u8, source, "agent tool `set_pull_request`") == null) {
        std.debug.print("!! success note must explicitly say agent tool `set_pull_request` !!\n", .{});
        return error.SuccessNoteMissingAgentToolWording;
    }
}

test "set_git_worktree emits JSON (no XML envelope)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "SetGitWorktreeJSON") == null) {
        std.debug.print("!! set_git_worktree.zig does not define SetGitWorktreeJSON !!\n", .{});
        return error.JsonPayloadMissing;
    }
    if (std.mem.indexOf(u8, source, "std.json.Stringify.valueAlloc") == null) {
        std.debug.print("!! set_git_worktree.zig does not serialize via std.json !!\n", .{});
        return error.JsonSerializeMissing;
    }
    if (std.mem.indexOf(u8, source, "<worktree>") != null) {
        std.debug.print("!! set_git_worktree.zig still emits <worktree> XML envelope !!\n", .{});
        return error.XmlEnvelopeStillPresent;
    }
}

test "jsonError carries message with special chars raw" {
    const payload = jsonError(testing.allocator, "s1", "bad <tag> & \"quote\"");
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("s1", obj.get("session_id").?.string);
    try testing.expectEqualStrings("bad <tag> & \"quote\"", obj.get("error").?.string);
    try testing.expect(!obj.get("created").?.bool);
}

test "jsonSet carries path/branch/note" {
    const payload = jsonSet(testing.allocator, "s1", "/tmp/wt", "worktree/wt", "");
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("created").?.bool);
    try testing.expectEqualStrings("/tmp/wt", obj.get("path").?.string);
    try testing.expectEqualStrings("worktree/wt", obj.get("branch").?.string);
    try testing.expect(obj.get("note").?.string.len > 0);
}

test "jsonClear sets cleared flag" {
    const payload = jsonClear(testing.allocator, "s1");
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("cleared").?.bool);
}

// ─── Cross-separator worktree matching (Windows) ──────────────────────────
// The bug: `parseAndMatchBlock` compared git's worktree path against the
// model's with `std.mem.eql`. git for Windows prints FORWARD slashes
// (`worktree C:/Users/me/wt`); the model sends BACKSLASHES. The compare
// never matched, so a live registered worktree was classified
// `.orphaned_worktree`, and that arm's error text instructs the model to
// run `git worktree prune && rm -rf <path>` — on the directory holding the
// work in flight.
//
// These tests run on EVERY platform: `pathsDenoteSameDir` is a pure string
// comparison parameterised by host case-sensitivity, so the Windows-shaped
// input can be exercised from Linux.
test "pathsDenoteSameDir: git forward slashes match the model's backslashes" {
    try testing.expect(pathsDenoteSameDir(
        "C:/Users/ginwa/.config/nalar/.worktrees/fix-login",
        "C:\\Users\\ginwa\\.config\\nalar\\.worktrees\\fix-login",
    ));
}

test "pathsDenoteSameDir: trailing and duplicate separators are ignored" {
    try testing.expect(pathsDenoteSameDir("C:/a/b/", "C:\\a\\b"));
    try testing.expect(pathsDenoteSameDir("C:/a//b", "C:\\a\\b"));
    try testing.expect(pathsDenoteSameDir("/home/ginwa/wt/", "/home/ginwa/wt"));
    try testing.expect(pathsDenoteSameDir("", ""));
}

test "pathsDenoteSameDir: different directories still do not match" {
    try testing.expect(!pathsDenoteSameDir("C:/a/wt", "C:\\a\\wt2"));
    try testing.expect(!pathsDenoteSameDir("C:/a/wt", "C:\\b\\wt"));
    // A prefix must not match a longer path.
    try testing.expect(!pathsDenoteSameDir("C:/a/wt", "C:\\a\\wt\\sub"));
    try testing.expect(!pathsDenoteSameDir("/home/ginwa/wt", "/home/other/wt"));
    try testing.expect(!pathsDenoteSameDir("C:/a/wt", ""));
}

// Case sensitivity is host-dependent on purpose: Windows filesystems ignore
// case, Linux ones do not. Asserting the POSIX behaviour everywhere and the
// Windows behaviour in a gated leg keeps the function honest on both.
test "pathsDenoteSameDir: case is ignored only on Windows" {
    if (@import("builtin").os.tag == .windows) {
        try testing.expect(pathsDenoteSameDir("C:/Users/Ginwa/wt", "C:\\users\\ginwa\\WT"));
    } else {
        try testing.expect(!pathsDenoteSameDir("C:/Users/Ginwa/wt", "C:\\users\\ginwa\\WT"));
    }
}

// The end-to-end leg: a real `git worktree list --porcelain` block, exactly
// as Windows git prints it, matched against the path the model would send.
test "parseAndMatchBlock: a Windows worktree listing matches the model's backslash path" {
    const block =
        \\worktree C:/Users/ginwa/.config/nalar/.worktrees/fix-login
        \\HEAD 0123456789abcdef0123456789abcdef01234567
        \\branch refs/heads/worktree/fix-login
        \\
        \\
    ;
    const matched = try parseAndMatchBlock(
        testing.allocator,
        block,
        "C:\\Users\\ginwa\\.config\\nalar\\.worktrees\\fix-login",
    );
    try testing.expect(matched != null);
    defer if (matched) |m| {
        testing.allocator.free(m.branch_ref);
        testing.allocator.free(m.branch);
        testing.allocator.free(m.commit);
        testing.allocator.free(m.path);
    };
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", matched.?.commit);
    try testing.expectEqualStrings("worktree/fix-login", matched.?.branch);
}

test "parseAndMatchBlock: a genuinely different worktree is not matched" {
    const block =
        \\worktree C:/Users/ginwa/.config/nalar/.worktrees/other
        \\HEAD 0123456789abcdef0123456789abcdef01234567
        \\branch refs/heads/worktree/other
        \\
    ;
    const matched = try parseAndMatchBlock(
        testing.allocator,
        block,
        "C:\\Users\\ginwa\\.config\\nalar\\.worktrees\\fix-login",
    );
    try testing.expect(matched == null);
}

// Pin the CAUSE as well as the behaviour, so a future "simplification" back
// to raw equality is caught even on a host where it happens to work.
test "static contract: parseAndMatchBlock does not compare worktree paths with std.mem.eql" {
    const source = try readSource(testing.allocator, TOOL_PATH);
    defer testing.allocator.free(source);

    try testing.expect(std.mem.indexOf(u8, source, "fn parseAndMatchBlock(") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pathsDenoteSameDir(wt_path, target)") != null);
    try testing.expect(std.mem.indexOf(u8, source, "pub fn pathsDenoteSameDir(") != null);
}
