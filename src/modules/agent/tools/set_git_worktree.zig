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
        io, git_path, allocator, .limited(std.Io.Dir.max_path_bytes),
    ) catch {
        // No .git file → plain directory.
        const msg = try std.fmt.allocPrint(
            allocator, "plain directory at {s}", .{target},
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
        allocator, "malformed .git file at {s}: {s}", .{ target, git_contents },
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
fn parseAndMatchBlock(
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
    if (!std.mem.eql(u8, wt_path, target)) return null;

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
        return try std.fmt.allocPrint(allocator,
            "the directory '{s}' already exists on disk and could not be auto-bound. " ++
            "Either pick a different path, or run `git -C <repo> worktree list --porcelain` " ++
            "to see which branch currently occupies it, then re-call set_git_worktree with " ++
            "`branch=<existing-branch>` to bind to it.",
            .{worktree_path});
    }
    // 2. "fatal: 'X' is already checked out at 'Y'" — branch conflict,
    //    not a path conflict. The fix is to pick a different branch
    //    name (or let it default to worktree/<basename>).
    if (std.mem.indexOf(u8, raw_stderr, "is already checked out") != null) {
        return try std.fmt.allocPrint(allocator,
            "branch '{s}' is already checked out by another worktree. " ++
            "Pass `branch=''` (empty) to use the auto-derived branch name " ++
            "`worktree/<basename(path)>`, or pick a different branch name.",
            .{branch});
    }
    // 3. "fatal: not a git repository" — the session's cwd isn't in a
    //    git repo. This usually means the session was started outside
    //    of one, or a parent process chdir'd away.
    if (std.mem.indexOf(u8, raw_stderr, "not a git repository") != null) {
        return try allocator.dupe(u8,
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
            return try std.fmt.allocPrint(allocator,
                "the base ref '{s}' could not be resolved by git. " ++
                "Run `git fetch origin` (the ref may not be fetched yet) or pick " ++
                "a different base branch, then retry. git said: {s}",
                .{ base, raw_stderr });
        }
        return try std.fmt.allocPrint(allocator,
            "the branch name '{s}' is invalid (git refused it). " ++
            "Valid branch names must not contain spaces, '..', '~', '^', ':', " ++
            "'?', '*', '[', '\\', and may not end with '.lock' or '/'.",
            .{branch});
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
                return xmlError(allocator, session_id, try std.fmt.allocPrint(allocator,
                    "path '{s}' is already a worktree on branch '{s}' (you requested '{s}'). " ++
                    "Either pick a different path, or pass branch='{s}' to bind to the existing worktree, " ++
                    "or ask the user how to resolve the conflict (merge, rename, or remove the existing branch).",
                    .{ worktree_path, rwt.branch, branch, rwt.branch }));
            },
            .orphaned_worktree => |gitdir| {
                return xmlError(allocator, session_id, try std.fmt.allocPrint(allocator,
                    "path '{s}' is an orphaned worktree directory (has .git file pointing at {s}, " ++
                    "but is not registered with git). Run `git worktree prune && rm -rf {s}` to clean up, " ++
                    "then retry set_git_worktree.",
                    .{ worktree_path, gitdir, worktree_path }));
            },
            .plain_directory => |desc| {
                return xmlError(allocator, session_id, try std.fmt.allocPrint(allocator,
                    "path '{s}' already exists but is not a worktree directory ({s}). " ++
                    "Remove it manually (after backing up any important content) or pick a different path.",
                    .{ worktree_path, desc }));
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

/// Generate success XML response for the SET path case. `<base>` is
/// emitted only when a base ref was requested, so the element's absence
/// keeps meaning "branched from HEAD". Always emits a `<note>` hint so
/// the agent knows how to open a PR for this branch (create via
/// `gh pr create`, then bind via `set_pull_request`).
fn successSetToXml(allocator: std.mem.Allocator, session_id: []const u8, path: []const u8, branch: []const u8, base: []const u8) []const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<worktree>\n<session_id>") catch return "";
    appendXmlContent(allocator, &result, session_id) catch return "";
    result.appendSlice(allocator, "</session_id>\n<created>true</created>\n<path>") catch return "";
    appendXmlContent(allocator, &result, path) catch return "";
    result.appendSlice(allocator, "</path>\n<branch>") catch return "";
    appendXmlContent(allocator, &result, branch) catch return "";
    result.appendSlice(allocator, "</branch>\n") catch return "";
    if (base.len > 0) {
        result.appendSlice(allocator, "<base>") catch return "";
        appendXmlContent(allocator, &result, base) catch return "";
        result.appendSlice(allocator, "</base>\n") catch return "";
    }
    result.appendSlice(allocator, "<note>If the user asks to open a pull request, or you want to initialize one for this branch, create it with `gh pr create` (or the Create-PR dialog), then call `set_pull_request` with the PR URL to bind it to this session.</note>\n") catch return "";
    result.appendSlice(allocator, "</worktree>") catch return "";

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
