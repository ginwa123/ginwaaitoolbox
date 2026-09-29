const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const pr_provider = nalar_core.pr_provider;
const run_captured = @import("helpers").run_captured;

/// Fields requested from `gh pr view --json`. Kept as a single const so
/// the CLI help and the use case never drift apart.
pub const GH_JSON_FIELDS = "number,title,url,state,mergeable,mergeStateStatus,headRefName,baseRefName,createdAt,updatedAt,mergedAt,closedAt,author,additions,deletions,changedFiles";

const PrStatusError = error{ NotARepository, CliMissing, NoAssociatedPr, FetchFailed };

/// Raw shape of `gh pr view --json ...` output. All fields optional with
/// defaults so a future `gh` version adding/removing a key does not break
/// parsing — missing keys surface as empty strings / zeros.
/// `mergedAt`/`closedAt` are `null` until the PR is merged/closed, so they
/// must stay optional: parsing JSON null into `[]const u8` fails and every
/// OPEN PR would 502 (see PR #584).
const GhPrView = struct {
    number: i64 = 0,
    title: []const u8 = "",
    url: []const u8 = "",
    state: []const u8 = "",
    mergeable: []const u8 = "",
    mergeStateStatus: []const u8 = "",
    headRefName: []const u8 = "",
    baseRefName: []const u8 = "",
    createdAt: []const u8 = "",
    updatedAt: []const u8 = "",
    mergedAt: ?[]const u8 = null,
    closedAt: ?[]const u8 = null,
    author: struct {
        login: []const u8 = "",
    } = .{},
    additions: i64 = 0,
    deletions: i64 = 0,
    changedFiles: i64 = 0,
};

/// Normalize `gh` state (OPEN/CLOSED/MERGED) to the lowercase status
/// the CLI prints. Unknown values pass through lowercased.
fn normalizeStatus(state: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(state, "OPEN")) return "open";
    if (std.ascii.eqlIgnoreCase(state, "CLOSED")) return "closed";
    if (std.ascii.eqlIgnoreCase(state, "MERGED")) return "merged";
    return state;
}

/// Max bytes of `gh` stderr (or context) surfaced in the HTTP 502
/// `error` field. `gh` failures are usually one line (`HTTP 401: ...`,
/// `could not resolve to a Repository ...`), but auth hints can run a
/// few lines — 500 bytes keeps the real cause without dumping pages.
const MAX_FETCH_DETAIL: usize = 500;

/// Store a trimmed + capped copy of `msg` into `slot` (best-effort;
/// leaves `slot` null on empty input or alloc failure so callers can
/// fall back to the generic hint). Allocs from the request arena.
fn setFetchDetail(allocator: std.mem.Allocator, slot: *?[]u8, msg: []const u8) void {
    const trimmed = std.mem.trim(u8, msg, " \n\r\t");
    if (trimmed.len == 0) return;
    const take = @min(trimmed.len, MAX_FETCH_DETAIL);
    slot.* = allocator.dupe(u8, trimmed[0..take]) catch null;
}

/// The `gh` binary. Injectable through `runGhPrViewWith` so the test
/// suite can point it at a fixture script instead of requiring a real
/// GitHub CLI on PATH.
pub const GH_PROGRAM = "gh";

/// Wall-clock budget for one `gh pr view` invocation. `gh` is a thin
/// HTTP client; anything slower than this is a hung network call or a
/// credential prompt nobody can answer, and a wedged worker-pool
/// thread is far more expensive to debug than a 502.
pub const GH_TIMEOUT_MS: u32 = 20_000;

/// Per-stream capture cap. A `gh pr view` payload is a few hundred
/// bytes; anything past this is an error message we truncate anyway.
const GH_MAX_OUTPUT_BYTES: usize = 64 * 1024;

/// Run `gh pr view` in `path` and return the raw stdout JSON (owned).
/// `pr_arg` is "" for "current branch's PR", otherwise a number, URL,
/// or branch name passed straight through to `gh`.
/// On failure the real cause (`gh` stderr or context) is duped into
/// `fetch_detail` so the handler can surface it instead of a generic
/// "check PR number/URL, provider, and gh auth" message.
///
/// `prog` and `timeout_ms` are injected so the inline tests below can
/// drive this against a fixture script with a short deadline, instead
/// of requiring a real, authenticated GitHub CLI on PATH.
///
/// ## Why this goes through `helpers.run_captured` and not
/// `std.process.spawn` + `Child.wait`
///
/// The hand-rolled version (spawn, drain stdout to EOF, drain stderr to
/// EOF, `child.wait(io)`) had two process-killing failure modes:
///
/// 1. `Child.wait` runs `childCleanupPosix`, which `closeFd`s every
///    pipe still attached to the `Child`. Zig 0.16's `closeFd` treats
///    EBADF as `unreachable` in Debug builds, so one request could
///    take the whole server down with
///    `thread N panic: reached unreachable code` — the crash this
///    function's inline tests below are named after.
/// 2. Draining stdout before stderr deadlocks as soon as `gh` writes
///    more than one pipe buffer (64 KiB on Linux) to stderr: `gh`
///    blocks in `write(2)`, never closes stdout, and our read never
///    sees EOF. The request hangs forever and leaks the worker thread.
///
/// `run_captured` detaches both pipes from the `Child` before anything
/// else (so std's cleanup closes nothing), drains the two streams
/// concurrently, and kills + reaps the child at the deadline.
fn runGhPrView(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    path: []const u8,
    pr_arg: []const u8,
    timeout_ms: u32,
    fetch_detail: *?[]u8,
) ![]u8 {
    // Build argv on the stack: `<gh> pr view [<pr>] --json <fields>`.
    // When pr_arg is empty we omit it so `gh` resolves the PR for the
    // current branch (the most common CLI usage).
    var argv_buf: [6][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = prog;
    argc += 1;
    argv_buf[argc] = "pr";
    argc += 1;
    argv_buf[argc] = "view";
    argc += 1;
    if (pr_arg.len > 0) {
        argv_buf[argc] = pr_arg;
        argc += 1;
    }
    argv_buf[argc] = "--json";
    argc += 1;
    argv_buf[argc] = GH_JSON_FIELDS;
    argc += 1;
    const argv = argv_buf[0..argc];

    var res = run_captured.run(allocator, io, argv, .{
        .cwd = path,
        .max_output_bytes = GH_MAX_OUTPUT_BYTES,
        .timeout_ms = timeout_ms,
    }) catch |err| switch (err) {
        // `gh` not on PATH is the overwhelmingly common spawn failure
        // (the repo gate above already proved `path` is a git repo, so
        // a FileNotFound here is the binary, not the directory).
        error.FileNotFound => return error.CliMissing,
        error.AccessDenied, error.PermissionDenied, error.InvalidExe => return error.CliMissing,
        else => {
            var buf: [128]u8 = undefined;
            setFetchDetail(allocator, fetch_detail, std.fmt.bufPrint(&buf, "failed to run {s} pr view ({s})", .{ prog, @errorName(err) }) catch "failed to run gh pr view");
            return error.FetchFailed;
        },
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        var buf: [128]u8 = undefined;
        setFetchDetail(allocator, fetch_detail, std.fmt.bufPrint(&buf, "{s} pr view timed out after {d}s", .{ prog, timeout_ms / 1000 }) catch "gh pr view timed out");
        return error.FetchFailed;
    }

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                const stderr_trimmed = std.mem.trim(u8, res.stderr, " \n\r");
                const is_no_pr = std.ascii.indexOfIgnoreCase(stderr_trimmed, "no pull request") != null or
                    std.ascii.indexOfIgnoreCase(stderr_trimmed, "no pull requests found") != null or
                    std.ascii.indexOfIgnoreCase(stderr_trimmed, "could not find") != null;
                // Surface the real `gh` stderr (auth failures, bad
                // PR numbers, rate limits) instead of a generic hint.
                // `is_no_pr` stays a 404; everything else becomes a
                // 502 carrying this detail.
                if (!is_no_pr) {
                    if (stderr_trimmed.len > 0) {
                        setFetchDetail(allocator, fetch_detail, stderr_trimmed);
                    } else {
                        var code_buf: [64]u8 = undefined;
                        const code_msg = std.fmt.bufPrint(&code_buf, "gh pr view exited with code {d} (no stderr)", .{code}) catch "gh pr view failed (no stderr)";
                        setFetchDetail(allocator, fetch_detail, code_msg);
                    }
                }
                if (is_no_pr) return error.NoAssociatedPr;
                return error.FetchFailed;
            }
        },
        else => {
            setFetchDetail(allocator, fetch_detail, "gh pr view terminated by signal");
            return error.FetchFailed;
        },
    }
    return allocator.dupe(u8, res.stdout);
}

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    fetch_detail: *?[]u8,
) !http_response.GitPrStatusResponse {
    return useCaseWith(allocator, io, GH_PROGRAM, path, pr_arg, provider_override, fetch_detail);
}

/// `useCase` with the `gh` binary injectable so the inline tests can
/// drive the whole path against a fixture script instead of a real,
/// authenticated GitHub CLI.
fn useCaseWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    prog: []const u8,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
    fetch_detail: *?[]u8,
) !http_response.GitPrStatusResponse {
    // 1) Must be a git repo.
    //
    // KNOWN LIMITATION (pre-existing, not introduced here): git honours
    // an ambient `GIT_DIR` / `GIT_WORK_TREE`, and then answers "yes,
    // this is a repository" for ANY path —
    //
    //     $ git -C /tmp/empty rev-parse --git-dir; echo $?
    //     128
    //     $ GIT_DIR=/repo/.git git -C /tmp/empty rev-parse --git-dir; echo $?
    //     /repo/.git
    //     0
    //
    // git exports both to the hooks it runs, so a nalar started from
    // inside a git hook (or any wrapper that exports them) would skip
    // this gate and try to run `gh` in a non-repository. `spawn` also
    // hands the child the `Io.Threaded` CACHED environ, so the process
    // cannot fix this for itself after startup. The fix is to pass an
    // explicit `environ_map` to this probe; tracked as follow-up work.
    {
        const check = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "rev-parse", "--git-dir" } }) catch return error.NotARepository;
        defer {
            allocator.free(check.stdout);
            allocator.free(check.stderr);
        }
        if (check.term.exited != 0) return error.NotARepository;
    }

    // 2) v1 supports GitHub only (`gh`). An explicit gitlab/generic
    // override is a caller error (400 at the handler); auto-detect from
    // a URL-shaped pr arg so `pr-status <gitlab-url>` fails with a
    // clear message instead of a confusing `gh` stderr.
    if (provider_override) |o| {
        if (o.len > 0) {
            const p = pr_provider.PrProvider.fromString(o) orelse {
                setFetchDetail(allocator, fetch_detail, "unknown provider (expected github, gitlab, or generic)");
                return error.FetchFailed;
            };
            if (p != .github) {
                setFetchDetail(allocator, fetch_detail, "only the github provider is supported for PR status in v1");
                return error.FetchFailed;
            }
        }
    } else if (pr_arg.len > 0 and std.mem.indexOf(u8, pr_arg, "://") != null) {
        const normalized = pr_provider.normalizePrUrl(allocator, pr_arg) catch null;
        if (normalized) |n| {
            defer allocator.free(n);
            if (pr_provider.detectProvider(n) != .github) {
                setFetchDetail(allocator, fetch_detail, "PR URL is not a GitHub URL (v1 supports github only)");
                return error.FetchFailed;
            }
        }
    }

    const raw = runGhPrView(allocator, io, prog, path, pr_arg, GH_TIMEOUT_MS, fetch_detail) catch |err| {
        // runGhPrView already stored the `gh` stderr in fetch_detail.
        return err;
    };
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \n\r");
    const parsed = std.json.parseFromSliceLeaky(GhPrView, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
        var parse_buf: [256]u8 = undefined;
        const parse_msg = std.fmt.bufPrint(&parse_buf, "invalid JSON from gh pr view ({d} bytes stdout)", .{raw.len}) catch "invalid JSON from gh pr view";
        setFetchDetail(allocator, fetch_detail, parse_msg);
        return error.FetchFailed;
    };

    // parseFromSliceLeaky BORROWS string slices from `raw` (no dupes),
    // so every string must be duped into the request arena before `raw`
    // is freed — otherwise the handler serializes freed memory
    // (0xAA garbage in debug builds). Numbers copy by value.
    return http_response.GitPrStatusResponse{
        .pr_url = try allocator.dupe(u8, parsed.url),
        .number = parsed.number,
        .title = try allocator.dupe(u8, parsed.title),
        .state = try allocator.dupe(u8, parsed.state),
        .status = try allocator.dupe(u8, normalizeStatus(parsed.state)),
        .mergeable = try allocator.dupe(u8, parsed.mergeable),
        .merge_state = try allocator.dupe(u8, parsed.mergeStateStatus),
        .head_ref = try allocator.dupe(u8, parsed.headRefName),
        .base_ref = try allocator.dupe(u8, parsed.baseRefName),
        .author = try allocator.dupe(u8, parsed.author.login),
        .created_at = try allocator.dupe(u8, parsed.createdAt),
        .updated_at = try allocator.dupe(u8, parsed.updatedAt),
        .merged_at = try allocator.dupe(u8, parsed.mergedAt orelse ""),
        .closed_at = try allocator.dupe(u8, parsed.closedAt orelse ""),
        .additions = parsed.additions,
        .deletions = parsed.deletions,
        .changed_files = parsed.changedFiles,
    };
}

/// GET /api/git/pr/status?path=<repo>[&pr=<number|url|branch>][&provider=github]
/// Returns the PR's open/merged/closed status via `gh pr view`.
/// `pr` is optional: when omitted, `gh` resolves the PR for the
/// current branch. Only the github provider is supported in v1.
pub fn gitPrStatusHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    if (path_param.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "path cannot be empty") });
    }
    const pr_param = query.get("pr") orelse "";
    const provider_param = query.get("provider");
    if (provider_param) |pv| {
        if (pv.len > 0 and pr_provider.PrProvider.fromString(pv) == null) {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "provider must be \"github\", \"gitlab\", or \"generic\"") });
        }
        if (pv.len > 0) {
            const p = pr_provider.PrProvider.fromString(pv).?;
            if (p != .github) {
                return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "only the github provider is supported for PR status in v1 (install gh and use a github PR)") });
            }
        }
    }

    var fetch_detail: ?[]u8 = null;
    const result = useCase(allocator, io, path_param, pr_param, provider_param, &fetch_detail) catch |err| switch (err) {
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, "not a git repository") });
        },
        error.CliMissing => {
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeGitStatusErrorResponse(allocator, "gh CLI not found on PATH (install gh for GitHub PR status)") });
        },
        error.NoAssociatedPr => {
            const msg = if (pr_param.len > 0)
                try std.fmt.allocPrint(allocator, "no pull request found for '{s}'", .{pr_param})
            else
                try allocator.dupe(u8, "no pull request found for the current branch");
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        error.FetchFailed => {
            // Surface the real `gh` stderr (auth, bad PR number, rate
            // limit) so DevTools shows WHY it failed instead of the
            // generic hint. Falls back to the hint when no detail was
            // captured (e.g. empty stderr).
            const msg = if (fetch_detail) |d|
                try std.fmt.allocPrint(allocator, "failed to fetch PR status: {s}", .{d})
            else
                try allocator.dupe(u8, "failed to fetch PR status (check PR number/URL, provider, and gh auth)");
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        else => return err,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrStatusResponse(allocator, result) });
}

// ===== Static wiring tests (git_pr_diff.zig pattern) =====
const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "git_pr_status handler is exported from mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/http_handlers/mod.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const gitPrStatusHandler") == null) {
        std.debug.print("!! mod.zig does not export gitPrStatusHandler !!\n", .{});
        return error.NotExported;
    }
}

test "git_pr_status route is registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/main.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/git/pr/status") == null) {
        std.debug.print("!! main.zig does not register /api/git/pr/status !!\n", .{});
        return error.NotRegistered;
    }
}

test "http_response defines GitPrStatusResponse + helper" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/http_handlers/http_response.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "GitPrStatusResponse") == null) return error.ResponseTypeMissing;
    if (std.mem.indexOf(u8, source, "makeGitPrStatusResponse") == null) return error.ResponseHelperMissing;
}

test "normalizeStatus maps OPEN/CLOSED/MERGED" {
    try testing.expectEqualStrings("open", normalizeStatus("OPEN"));
    try testing.expectEqualStrings("open", normalizeStatus("open"));
    try testing.expectEqualStrings("closed", normalizeStatus("CLOSED"));
    try testing.expectEqualStrings("merged", normalizeStatus("MERGED"));
}

test "GhPrView parses open-PR payload with null mergedAt/closedAt" {
    // `gh pr view --json ...` emits `"mergedAt":null,"closedAt":null` for
    // OPEN PRs. Parsing that into non-optional `[]const u8` fails, which
    // surfaced as HTTP 502 for every open PR (PR #584).
    const allocator = testing.allocator;
    const raw =
        \\{"number":584,"title":"SyncEngine Phase 2","url":"https://github.com/acme/app/pull/584","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","headRefName":"worktree/sync-engine-phase2-cached-delta","baseRefName":"main","createdAt":"2026-09-21T08:51:37Z","updatedAt":"2026-09-21T08:51:37Z","mergedAt":null,"closedAt":null,"author":{"login":"ginwa123"},"additions":286,"deletions":103,"changedFiles":4}
    ;
    const parsed = try std.json.parseFromSliceLeaky(GhPrView, allocator, raw, .{ .ignore_unknown_fields = true });
    try testing.expectEqual(@as(i64, 584), parsed.number);
    try testing.expectEqualStrings("OPEN", parsed.state);
    try testing.expect(parsed.mergedAt == null);
    try testing.expect(parsed.closedAt == null);
    try testing.expectEqualStrings("open", normalizeStatus(parsed.state));
}

// ============================================================================
// Behavioural test suite for the `gh pr view` child-process path.
//
// Everything above in the "Static wiring tests" section used to be
// source-grep assertions only: `runGhPrView` had ZERO functional tests
// while it was the function that aborted the whole server process
// (`thread N panic: reached unreachable code` from
// `std/Io/Threaded.zig:closeFd` <- `childCleanupPosix` <- `Child.wait`)
// and that could deadlock a worker-pool thread forever on a chatty
// `gh`. These tests drive the real code path against fixture scripts.
//
// Fixture shape: `runGhPrView` takes the program name as a parameter,
// so a test points it at a shell script it just wrote. That keeps the
// whole suite hermetic — no `gh` install, no GitHub auth, no network.
// ============================================================================

const builtin_t = @import("builtin");

/// `/bin/sh` fixtures only work on POSIX hosts. Windows CI skips the
/// behavioural suite (the pure parsing / wiring tests above still run).
fn skipOnWindows() bool {
    return builtin_t.os.tag == .windows;
}

/// A throwaway directory under `.zig-cache/tmp` plus fixture scripts
/// inside it. `root` is the absolute path; scripts are chmod 0755 so
/// `execvp` can run them.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try tmp.dir.realPath(std.testing.io, &buf);
        const owned = try allocator.dupe(u8, buf[0..root]);
        return .{ .tmp = tmp, .root = owned, .allocator = allocator };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.allocator.free(self.root);
    }

    /// Write `script` to `<root>/<name>` and mark it executable.
    /// Returns the absolute path.
    fn writeExec(self: *Fixture, name: []const u8, script: []const u8) ![]u8 {
        try self.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = name,
            .data = script,
        });
        if (builtin_t.os.tag != .windows) {
            try self.tmp.dir.setFilePermissions(std.testing.io, name, .executable_file, .{});
        }
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, name });
    }

    /// `writeExec` for a script the caller allocated: writes it, frees
    /// it, and returns the executable path. Keeps the test allocator
    /// honest (no leak) without every call site juggling a `defer`.
    fn writeScript(self: *Fixture, name: []const u8, script: []const u8) ![]u8 {
        defer self.allocator.free(script);
        return self.writeExec(name, script);
    }

    /// A subdirectory of the fixture root, created on demand.
    fn subDir(self: *Fixture, name: []const u8) ![]u8 {
        self.tmp.dir.createDirPath(std.testing.io, name) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, name });
    }
};

/// A fixture script that prints `payload` (verbatim, no trailing
/// newline) on stdout — the shape of a real `gh pr view --json`.
fn scriptPrintingJson(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    // `printf '%s'`, not a heredoc: a heredoc always appends a newline,
    // and `gh pr view --json` output has none. The fixture must be
    // byte-exact or "returns gh stdout verbatim" proves nothing.
    return std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s' '{s}'\n", .{payload});
}

const OPEN_PR_JSON =
    \\{"number":584,"title":"SyncEngine Phase 2","url":"https://github.com/acme/app/pull/584","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","headRefName":"worktree/x","baseRefName":"main","createdAt":"2026-09-21T08:51:37Z","updatedAt":"2026-09-21T08:51:37Z","mergedAt":null,"closedAt":null,"author":{"login":"ginwa123"},"additions":286,"deletions":103,"changedFiles":4}
;

/// True when a usable `git` is on PATH (the `useCase` tests need one).
fn haveGit() bool {
    var c = std.process.spawn(std.testing.io, .{
        .argv = &.{ "git", "--version" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    _ = c.wait(std.testing.io) catch return false;
    return true;
}

/// A real (empty) git repo inside the fixture, so the
/// `git rev-parse --git-dir` gate in `useCaseWith` passes.
fn makeGitRepo(fx: *Fixture) ![]u8 {
    const a = fx.allocator;
    const repo = try fx.subDir("repo");
    var r = run_captured.run(a, std.testing.io, &.{ "git", "init", "-q", repo }, .{
        .timeout_ms = 30_000,
    }) catch return error.SkipZigTest;
    defer r.deinit(a);
    if (r.term.exited != 0) return error.SkipZigTest;
    return repo;
}

/// A directory that is genuinely NOT inside a git repository.
///
/// `std.testing.tmpDir` roots at `.zig-cache/tmp/`, which lives *inside*
/// this repo — `git -C <that dir> rev-parse --git-dir` walks up and
/// succeeds, so the `NotARepository` gate would never trip. Go to the
/// system temp dir instead.
fn makeNonRepoDir(allocator: std.mem.Allocator) ![]u8 {
    var name_buf: [48]u8 = undefined;
    var seed: [4]u8 = undefined;
    std.Io.random(std.testing.io, &seed);
    const name = try std.fmt.bufPrint(&name_buf, "nalar-nonrepo-{x}-{x}{x}{x}", .{
        seed[0], seed[1], seed[2], seed[3],
    });
    const path = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{name});
    errdefer allocator.free(path);
    const dir = try std.Io.Dir.cwd().createDirPathOpen(std.testing.io, path, .{});
    std.Io.Dir.close(dir, std.testing.io);
    return path;
}

fn removeNonRepoDir(allocator: std.mem.Allocator, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
    allocator.free(path);
}

/// True when the ambient environment already makes git claim every path
/// is a repository — see the KNOWN LIMITATION note on the probe in
/// `useCaseWith`. git exports `GIT_DIR` / `GIT_WORK_TREE` to the hooks
/// it runs, so under `git push` (husky's pre-push gate, which runs
/// `zig build test`) this is true and the gate is bypassed for reasons
/// this test cannot fix. Detected by running the very same probe
/// against a directory that is definitely not a repository.
fn gitProbeIsEnvHijacked(allocator: std.mem.Allocator, empty_dir: []const u8) bool {
    const check = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "git", "-C", empty_dir, "rev-parse", "--git-dir" },
    }) catch return true;
    defer {
        allocator.free(check.stdout);
        allocator.free(check.stderr);
    }
    return check.term.exited == 0;
}

/// `useCaseWith` dupes every string of the response into the caller's
/// allocator (the request arena in production). Tests pass
/// `testing.allocator`, so they have to give the copies back.
fn freeResponse(a: std.mem.Allocator, res: http_response.GitPrStatusResponse) void {
    inline for (.{
        res.pr_url,    res.title,       res.state,      res.status,
        res.mergeable, res.merge_state, res.head_ref,   res.base_ref,
        res.author,    res.created_at,  res.updated_at, res.merged_at,
        res.closed_at,
    }) |s| a.free(s);
}

fn openFdCount() ?usize {
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, "/proc/self/fd", .{
        .iterate = true,
    }) catch return null;
    defer std.Io.Dir.close(dir, std.testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(std.testing.io) catch null) |_| n += 1;
    return n;
}

// ─────────────────────────── runGhPrView ───────────────────────────

test "runGhPrView returns gh stdout verbatim" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeScript("gh", try scriptPrintingJson(a, "{\"number\":7,\"state\":\"OPEN\"}"));
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const out = try runGhPrView(a, testing.io, gh, fx.root, "", 10_000, &detail);
    defer a.free(out);
    try testing.expectEqualStrings("{\"number\":7,\"state\":\"OPEN\"}", out);
    try testing.expect(detail == null);
}

test "runGhPrView builds `pr view --json <fields>` and omits an empty pr arg" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeExec("gh", "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const out = try runGhPrView(a, testing.io, gh, fx.root, "", 10_000, &detail);
    defer a.free(out);

    // Exactly four lines when pr_arg is empty: pr / view / --json / fields
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, out, "\n"), '\n');
    try testing.expectEqualStrings("pr", it.next().?);
    try testing.expectEqualStrings("view", it.next().?);
    try testing.expectEqualStrings("--json", it.next().?);
    try testing.expectEqualStrings(GH_JSON_FIELDS, it.next().?);
    try testing.expect(it.next() == null);
}

test "runGhPrView passes a pr number / URL / branch through verbatim" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeExec("gh", "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
    defer a.free(gh);

    for ([_][]const u8{ "42", "https://github.com/acme/app/pull/9", "feature-x" }) |pr_arg| {
        var detail: ?[]u8 = null;
        defer if (detail) |d| a.free(d);
        const out = try runGhPrView(a, testing.io, gh, fx.root, pr_arg, 10_000, &detail);
        defer a.free(out);
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, out, "\n"), '\n');
        try testing.expectEqualStrings("pr", it.next().?);
        try testing.expectEqualStrings("view", it.next().?);
        try testing.expectEqualStrings(pr_arg, it.next().?);
    }
}

test "runGhPrView runs the child in the requested cwd" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeExec("gh", "#!/bin/sh\npwd\n");
    defer a.free(gh);
    const repo = try fx.subDir("repo");
    defer a.free(repo);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const out = try runGhPrView(a, testing.io, gh, repo, "", 10_000, &detail);
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "repo") != null);
}

test "runGhPrView: 'no pull requests found' maps to NoAssociatedPr" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    for ([_][]const u8{
        "no pull requests found for branch",
        "no pull request found for branch",
        "could not find any pull request",
    }) |msg| {
        const gh = try fx.writeScript("gh", try std.fmt.allocPrint(a,
            \\#!/bin/sh
            \\printf '%s' '{s}' 1>&2
            \\exit 1
        , .{msg}));
        defer a.free(gh);

        var detail: ?[]u8 = null;
        defer if (detail) |d| a.free(d);
        try testing.expectError(
            error.NoAssociatedPr,
            runGhPrView(a, testing.io, gh, fx.root, "", 10_000, &detail),
        );
    }
}

test "runGhPrView: auth failure surfaces the real gh stderr in fetch_detail" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeExec("gh",
        \\#!/bin/sh
        \\printf 'gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable.\n' 1>&2
        \\exit 4
    );
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, runGhPrView(a, testing.io, gh, fx.root, "", 10_000, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "GH_TOKEN") != null);
}

test "runGhPrView: a non-zero exit with empty stderr still records the code" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeExec("gh", "#!/bin/sh\nexit 9\n");
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, runGhPrView(a, testing.io, gh, fx.root, "", 10_000, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "exited with code 9") != null);
}

test "runGhPrView: >64 KiB of gh stderr does NOT deadlock (crash-class regression)" {
    // THE regression test for the production hang. The pre-fix code
    // drained stdout to EOF before touching stderr, so a `gh` that
    // printed more than one 64 KiB pipe buffer to stderr blocked in
    // write(2), never closed stdout, and the HTTP request — plus the
    // worker thread running it — hung forever. If this test times out
    // in CI, the concurrent drain is gone.
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeExec("gh",
        \\#!/bin/sh
        \\i=0
        \\while [ $i -lt 1024 ]; do
        \\  i=$((i+1))
        \\  dd if=/dev/zero bs=1024 count=1 2>/dev/null | tr '\0' 'E' 1>&2
        \\done
        \\printf 'never-reached-json'
        \\exit 1
    );
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    // 20s deadline: generous enough to be reliable on a loaded CI box,
    // and the process is killed either way, so this can never hang the
    // suite the way the pre-fix code hung the worker thread.
    try testing.expectError(
        error.FetchFailed,
        runGhPrView(a, testing.io, gh, fx.root, "", 20_000, &detail),
    );
    // 1 MiB of stderr was drained, then trimmed down to MAX_FETCH_DETAIL.
    try testing.expectEqual(@as(usize, MAX_FETCH_DETAIL), detail.?.len);
}

test "runGhPrView: a gh that never exits is killed at the deadline" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeExec("gh", "#!/bin/sh\nsleep 60\n");
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, runGhPrView(a, testing.io, gh, fx.root, "", 300, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "timed out") != null);
}

test "runGhPrView: a gh killed by a signal is reported, not a success" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeExec("gh", "#!/bin/sh\nkill -9 $$\n");
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, runGhPrView(a, testing.io, gh, fx.root, "", 10_000, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "signal") != null);
}

test "runGhPrView: a missing gh binary maps to CliMissing" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.CliMissing, runGhPrView(
        a,
        testing.io,
        "/nalar/definitely/not/gh",
        fx.root,
        "",
        10_000,
        &detail,
    ));
}

test "runGhPrView: empty gh stdout is an empty slice, not a silent failure" {
    if (skipOnWindows()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeExec("gh", "#!/bin/sh\nexit 0\n");
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const out = try runGhPrView(a, testing.io, gh, fx.root, "", 10_000, &detail);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expect(detail == null);
}

const ConcurrentGhCtx = struct {
    a: std.mem.Allocator,
    gh: []const u8,
    root: []const u8,
    ok: *bool,
};

fn concurrentGhWorker(ctx: *ConcurrentGhCtx) void {
    ctx.ok.* = true;
    for (0..8) |_| {
        var detail: ?[]u8 = null;
        defer if (detail) |d| ctx.a.free(d);
        const out = runGhPrView(ctx.a, testing.io, ctx.gh, ctx.root, "", 10_000, &detail) catch {
            ctx.ok.* = false;
            return;
        };
        defer ctx.a.free(out);
        if (!std.mem.eql(u8, out, "{\"number\":1,\"state\":\"OPEN\"}")) {
            ctx.ok.* = false;
            return;
        }
    }
}

test "runGhPrView: 8 concurrent callers never trip the double-close abort" {
    // The reported crash was a `closeFd` EBADF inside
    // `childCleanupPosix` on a worker-pool thread, so it only ever
    // showed up under concurrency. Every one of these calls spawns,
    // drains, closes and reaps a real child from a real thread; if the
    // fd ownership regressed, the test binary aborts rather than fails.
    if (skipOnWindows()) return error.SkipZigTest;
    if (builtin_t.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    const gh = try fx.writeScript("gh", try scriptPrintingJson(a, "{\"number\":1,\"state\":\"OPEN\"}"));
    defer a.free(gh);

    const before = openFdCount() orelse return error.SkipZigTest;
    const oks = try a.alloc(bool, 8);
    defer a.free(oks);
    const ctxs = try a.alloc(ConcurrentGhCtx, 8);
    defer a.free(ctxs);
    const threads = try a.alloc(std.Thread, 8);
    defer a.free(threads);

    for (0..8) |i| {
        oks[i] = false;
        ctxs[i] = .{ .a = a, .gh = gh, .root = fx.root, .ok = &oks[i] };
        threads[i] = try std.Thread.spawn(.{}, concurrentGhWorker, .{&ctxs[i]});
    }
    for (threads) |t| t.join();
    for (oks) |ok| try testing.expect(ok);

    const after = openFdCount() orelse return error.SkipZigTest;
    try testing.expect(after <= before + 8);
}

// ───────────────────────────── useCase ─────────────────────────────

test "useCase maps a valid gh payload onto GitPrStatusResponse" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeScript("gh", try scriptPrintingJson(a, OPEN_PR_JSON));
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWith(a, testing.io, gh, repo, "", null, &detail);
    defer freeResponse(a, res);

    try testing.expectEqual(@as(i64, 584), res.number);
    try testing.expectEqualStrings("https://github.com/acme/app/pull/584", res.pr_url);
    try testing.expectEqualStrings("SyncEngine Phase 2", res.title);
    try testing.expectEqualStrings("OPEN", res.state);
    try testing.expectEqualStrings("open", res.status);
    try testing.expectEqualStrings("MERGEABLE", res.mergeable);
    try testing.expectEqualStrings("UNSTABLE", res.merge_state);
    try testing.expectEqualStrings("worktree/x", res.head_ref);
    try testing.expectEqualStrings("main", res.base_ref);
    try testing.expectEqualStrings("ginwa123", res.author);
    // mergedAt/closedAt are JSON null -> empty strings, never garbage.
    try testing.expectEqualStrings("", res.merged_at);
    try testing.expectEqualStrings("", res.closed_at);
    try testing.expectEqual(@as(i64, 286), res.additions);
    try testing.expectEqual(@as(i64, 103), res.deletions);
    try testing.expectEqual(@as(i64, 4), res.changed_files);
}

test "useCase: a non-git path never spawns gh (repo-gate regression)" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const not_repo = try makeNonRepoDir(a);
    defer removeNonRepoDir(a, not_repo);
    if (gitProbeIsEnvHijacked(a, not_repo)) {
        std.debug.print("!! skipping: this environment exports GIT_DIR/GIT_WORK_TREE, so git calls any path a repository (see the KNOWN LIMITATION note in useCaseWith) !!\n", .{});
        return error.SkipZigTest;
    }

    // A `gh` that succeeds AND drops a sentinel: if the repo gate ever
    // fails to short-circuit, the sentinel appears and this test fails
    // with a message that names the actual problem. Asserting on the
    // sentinel rather than on `error.NotARepository` is deliberate —
    // see the GIT_DIR note below.
    const sentinel = try std.fmt.allocPrint(a, "{s}/gh-was-run", .{fx.root});
    defer a.free(sentinel);
    const gh = try fx.writeScript("gh", try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\touch '{s}'
        \\printf '{{"number":1,"state":"OPEN"}}'
    , .{sentinel}));
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    // A success here means the gate let it through; free the response
    // so the test allocator stays honest either way.
    if (useCaseWith(a, testing.io, gh, not_repo, "", null, &detail)) |res| {
        freeResponse(a, res);
    } else |_| {}
    if (std.Io.Dir.cwd().access(std.testing.io, sentinel, .{})) |_| {
        std.debug.print("!! the repo gate did not short-circuit: gh was spawned for a non-repo path !!\n", .{});
        return error.GhWasSpawned;
    } else |_| {}
}

test "useCase: a missing path is NotARepository" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(
        error.NotARepository,
        useCaseWith(a, testing.io, "/bin/sh", "/nalar/no/such/repo", "", null, &detail),
    );
}

test "useCase: an unknown provider string is rejected" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(
        error.FetchFailed,
        useCaseWith(a, testing.io, "/bin/sh", repo, "", "bitbucket", &detail),
    );
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "unknown provider") != null);
}

test "useCase: gitlab / generic providers are rejected before gh runs" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    for ([_][]const u8{ "gitlab", "generic" }) |p| {
        var detail: ?[]u8 = null;
        defer if (detail) |d| a.free(d);
        try testing.expectError(
            error.FetchFailed,
            useCaseWith(a, testing.io, "/bin/sh", repo, "", p, &detail),
        );
        try testing.expect(std.mem.indexOf(u8, detail.?, "only the github provider") != null);
    }
}

test "useCase: a non-GitHub PR URL is rejected before gh runs" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, useCaseWith(
        a,
        testing.io,
        "/bin/sh",
        repo,
        "https://gitlab.com/acme/app/-/merge_requests/3",
        null,
        &detail,
    ));
    try testing.expect(std.mem.indexOf(u8, detail.?, "not a GitHub URL") != null);
}

test "useCase: a GitHub PR URL is accepted" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeScript("gh", try scriptPrintingJson(a, OPEN_PR_JSON));
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    const res = try useCaseWith(
        a,
        testing.io,
        gh,
        repo,
        "https://github.com/acme/app/pull/584",
        null,
        &detail,
    );
    defer freeResponse(a, res);
    try testing.expectEqual(@as(i64, 584), res.number);
}

test "useCase: garbage stdout from gh is a FetchFailed with a size hint" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeExec("gh", "#!/bin/sh\nprintf 'not json at all'\n");
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, useCaseWith(a, testing.io, gh, repo, "", null, &detail));
    try testing.expect(detail != null);
    try testing.expect(std.mem.indexOf(u8, detail.?, "invalid JSON") != null);
}

test "useCase: an empty stdout from gh is a FetchFailed, never a bogus 200" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeExec("gh", "#!/bin/sh\nexit 0\n");
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.FetchFailed, useCaseWith(a, testing.io, gh, repo, "", null, &detail));
}

test "useCase: 'no pull requests found' surfaces as NoAssociatedPr" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    const gh = try fx.writeExec("gh",
        \\#!/bin/sh
        \\printf 'no pull requests found for branch "worktree/x"\n' 1>&2
        \\exit 1
    );
    defer a.free(gh);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(error.NoAssociatedPr, useCaseWith(a, testing.io, gh, repo, "", null, &detail));
}

test "useCase: a missing gh binary surfaces as CliMissing" {
    if (skipOnWindows()) return error.SkipZigTest;
    if (!haveGit()) return error.SkipZigTest;
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const repo = try makeGitRepo(&fx);
    defer a.free(repo);

    var detail: ?[]u8 = null;
    defer if (detail) |d| a.free(d);
    try testing.expectError(
        error.CliMissing,
        useCaseWith(a, testing.io, "/nalar/definitely/not/gh", repo, "", null, &detail),
    );
}

// ─────────── source-contract guard against the regression ───────────

test "runGhPrView must not hand-roll spawn/read/wait (regression contract)" {
    // The crash shipped because the child-process dance was open-coded
    // in the handler. If a future refactor reintroduces
    // `std.process.spawn` here, it has also reintroduced the
    // `closeFd`-on-stale-fd abort and the sequential-drain deadlock.
    const a = testing.allocator;
    const full = try readSource(a, "src/http_handlers/git_pr_status.zig");
    defer a.free(full);
    // Only the implementation matters. The fixture helpers below spawn
    // `git init` on purpose, so scan everything above the test section.
    const source = full[0 .. std.mem.indexOf(u8, full, "// ===== Static wiring tests") orelse full.len];
    if (std.mem.indexOf(u8, source, "std.process.spawn(") != null) {
        std.debug.print("!! git_pr_status.zig spawns a child by hand — route it through helpers.run_captured !!\n", .{});
        return error.HandRolledSpawn;
    }
    if (std.mem.indexOf(u8, source, "run_captured.run") == null) {
        std.debug.print("!! git_pr_status.zig does not use run_captured !!\n", .{});
        return error.NotUsingHelper;
    }
}

test "git_pr_create.zig no longer hand-rolls the same spawn dance" {
    // Same bug, same crash shape, different handler: `gh pr create`
    // spawned, drained stdout then stderr, and called `Child.wait`.
    const a = testing.allocator;
    const full = try readSource(a, "src/http_handlers/git_pr_create.zig");
    defer a.free(full);
    const source = full[0 .. std.mem.indexOf(u8, full, "// ===== Tests merged from") orelse full.len];
    if (std.mem.indexOf(u8, source, "std.process.spawn(") != null) {
        std.debug.print("!! git_pr_create.zig spawns a child by hand — route it through helpers.run_captured !!\n", .{});
        return error.HandRolledSpawn;
    }
    if (std.mem.indexOf(u8, source, "run_captured.run") == null) {
        std.debug.print("!! git_pr_create.zig does not use run_captured !!\n", .{});
        return error.NotUsingHelper;
    }
}
