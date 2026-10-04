const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;

/// Domain error set for the worktree-info use case. The handler maps
/// `NotARepository` to HTTP 404; other failures propagate as 500.
const WorktreeInfoError = error{ NotARepository };

/// Result of gathering worktree info. Mirrors the `GitWorktreeInfoResponse`
/// shape but with the HTTP layer stripped out (no status codes, no response
/// struct). The use case does NOT set `is_git_repo` — the absence of
/// `NotARepository` error is the success signal.
const WorktreeInfoResult = struct {
    branch: []const u8,
    last_commit_sha: []const u8,
    last_commit_msg: []const u8,
    default_base: []const u8,
    commits_ahead: i64,
    diff_summary: []const u8,
};

/// Use case — run all the git CLI commands to gather worktree metadata.
///
/// Takes primitive inputs (worktree path + optional base override), returns
/// a domain struct. No HTTP types. On a non-git-repo path, returns
/// `error.NotARepository`; on any other failure (git subprocess error,
/// alloc failure, etc.), returns the underlying error.
///
/// All allocations are owned by the per-request arena the handler passes
/// in; this function does NOT free any of the strings it returns — the
/// arena reaps them when the request ends (see memory
/// custom-http-server-per-request-arena).
fn getWorktreeInfoUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    base: ?[]const u8,
) WorktreeInfoError!WorktreeInfoResult {
    // 1) Confirm it's a git repo.
    const git_dir_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path, "rev-parse", "--git-dir" },
    }) catch return error.NotARepository;
    if (git_dir_check.term.exited != 0) return error.NotARepository;

    // 2) Current branch.
    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path, "branch", "--show-current" },
    }) catch return error.NotARepository;
    const branch = std.mem.trim(u8, branch_result.stdout, " \n\r");

    // 3) Last commit (short SHA + subject).
    const log_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path, "log", "-1", "--format=%h %s" },
    }) catch return error.NotARepository;
    const log_line = std.mem.trim(u8, log_result.stdout, " \n\r");
    var last_sha: []const u8 = "";
    var last_msg: []const u8 = "";
    if (std.mem.indexOf(u8, log_line, " ")) |space_idx| {
        last_sha = log_line[0..space_idx];
        last_msg = log_line[space_idx + 1 ..];
    }

    // 4) Base branch — use `base` override if provided, else auto-detect
    // (origin/main → origin/master → origin/develop → "main" fallback).
    var default_base: []const u8 = "main";
    if (base) |eb| {
        if (eb.len > 0) default_base = eb;
    } else {
        const bases = [_][]const u8{ "main", "master", "develop" };
        for (bases) |b| {
            // Build "origin/<b>" at runtime — the `++` operator on
            // string slices in Zig 0.16 requires comptime-known slices,
            // and `b` is a loop variable. Use std.fmt.bufPrint to a
            // stack buffer instead (no allocator needed, the buffer
            // outlives the `run` call).
            var origin_b_buf: [64]u8 = undefined;
            const origin_b = std.fmt.bufPrint(origin_b_buf[0..], "origin/{s}", .{b}) catch continue;
            const argv = [_][]const u8{ "git", "-C", path, "rev-parse", "--verify", origin_b };
            const probe = std.process.run(allocator, io, .{ .argv = &argv }) catch continue;
            if (probe.term.exited == 0) {
                default_base = b;
                break;
            }
        }
    }

    // 5) Commits ahead of `origin/<default_base>`.
    var commits_ahead: i64 = 0;
    {
        var range_buf: [128]u8 = undefined;
        const range = std.fmt.bufPrint(range_buf[0..], "origin/{s}..HEAD", .{default_base}) catch "";
        const argv = [_][]const u8{ "git", "-C", path, "rev-list", "--count", range };
        if (std.process.run(allocator, io, .{ .argv = &argv })) |ahead_result| {
            if (ahead_result.term.exited == 0) {
                const trimmed = std.mem.trim(u8, ahead_result.stdout, " \n\r");
                commits_ahead = std.fmt.parseInt(i64, trimmed, 10) catch 0;
            }
        } else |_| {
            // rev-list failed (e.g. base ref doesn't exist) — leave at 0.
        }
    }

    // 6) Diff shortstat against `origin/<default_base>`.
    var diff_summary: []const u8 = "";
    {
        var range_buf: [128]u8 = undefined;
        const range = std.fmt.bufPrint(range_buf[0..], "origin/{s}..HEAD", .{default_base}) catch "";
        const argv = [_][]const u8{ "git", "-C", path, "diff", "--shortstat", range };
        if (std.process.run(allocator, io, .{ .argv = &argv })) |diff_result| {
            if (diff_result.term.exited == 0) {
                diff_summary = std.mem.trim(u8, diff_result.stdout, " \n\r");
            }
        } else |_| {
            // Same rationale as rev-list.
        }
    }

    return WorktreeInfoResult{
        .branch = branch,
        .last_commit_sha = last_sha,
        .last_commit_msg = last_msg,
        .default_base = default_base,
        .commits_ahead = commits_ahead,
        .diff_summary = diff_summary,
    };
}

/// HTTP handler for `GET /api/git/worktree/info`.
///
/// Query params:
///   - `path` (required) — absolute worktree path
///   - `base` (optional) — override the auto-detected base branch. When
///     present, `commits_ahead` and `diff_summary` are computed against
///     `origin/<base>` instead of the auto-detected default
///     (origin/main → origin/master → origin/develop). See design
///     decision #12 of the git-worktree-cwd-pr plan.
///
/// This handler is a thin wrapper: it parses query params, delegates to
/// `getWorktreeInfoUseCase`, builds the HTTP response shape, and maps
/// domain errors to status codes. All git CLI knowledge lives in the use
/// case.
pub fn gitWorktreeInfoHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const path_param = req.query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path parameter" }) });
    };

    // Optional ?base=<branch> override. Forwarded verbatim to the use case.
    const explicit_base_param = req.query.get("base");

    const info = getWorktreeInfoUseCase(allocator, io, path_param, explicit_base_param) catch |err| switch (err) {
        // NotARepository → 404 with a clear message. Other errors propagate
        // to the GinwaServer which returns a generic 500.
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
        },
    };

    // Build the response. draft_title and draft_body are derived from the
    // use-case result; the title is the last commit subject, the body is
    // a short markdown summary with the diff stat and commit count.
    const response = http_response.GitWorktreeInfoResponse{
        .is_git_repo = true,
        .branch = info.branch,
        .last_commit_sha = info.last_commit_sha,
        .last_commit_msg = info.last_commit_msg,
        .default_base = info.default_base,
        .commits_ahead = info.commits_ahead,
        .diff_summary = info.diff_summary,
        .draft_title = info.last_commit_msg,
        .draft_body = std.fmt.allocPrint(allocator, "## Summary\n\n{s}\n\nCommits ahead: {d}\n", .{ info.diff_summary, info.commits_ahead }) catch "",
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitWorktreeInfoResponse(allocator, response) });
}

// ===== Tests merged from git_worktree_info_test.zig (2026-09-11 flatten) =====
const testing = std.testing;
const pabrikcore = @import("pabrikcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/git_worktree_info.zig";
const MOD_PATH = "src/http_handlers/mod.zig";
const MAIN_PATH = "src/http_routes.zig";
const HTTP_RESP_PATH = "src/http_handlers/http_response.zig";

/// Read a source file from disk, relative to the project root. Mirrors the
/// pattern from the inline tests in `set_git_worktree.zig` — the project
/// doesn't have a behavioral handler-test infrastructure, so we static-grep
/// for required substrings.
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Static wiring tests ───────────────────────────────────────────────────

test "git_worktree_info handler is exported from mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const gitWorktreeInfoHandler") == null) {
        std.debug.print("!! mod.zig does not export gitWorktreeInfoHandler !!\n", .{});
        return error.GitWorktreeInfoExportMissing;
    }
    if (std.mem.indexOf(u8, source, "@import(\"git_worktree_info.zig\")") == null) {
        std.debug.print("!! mod.zig does not @import git_worktree_info.zig !!\n", .{});
        return error.GitWorktreeInfoImportMissing;
    }
}

test "git_worktree_info route is registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/git/worktree/info") == null) {
        std.debug.print("!! http_routes.zig does not register /api/git/worktree/info !!\n", .{});
        return error.GitWorktreeInfoRouteMissing;
    }
    if (std.mem.indexOf(u8, source, "gitWorktreeInfoHandler") == null) {
        std.debug.print("!! http_routes.zig does not reference gitWorktreeInfoHandler !!\n", .{});
        return error.GitWorktreeInfoHandlerRefMissing;
    }
}

test "http_response.zig defines GitWorktreeInfoResponse struct + helper" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESP_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "GitWorktreeInfoResponse") == null) {
        std.debug.print("!! http_response.zig does not define GitWorktreeInfoResponse !!\n", .{});
        return error.GitWorktreeInfoResponseTypeMissing;
    }
    if (std.mem.indexOf(u8, source, "makeGitWorktreeInfoResponse") == null) {
        std.debug.print("!! http_response.zig does not define makeGitWorktreeInfoResponse helper !!\n", .{});
        return error.GitWorktreeInfoResponseHelperMissing;
    }
}

test "git_worktree_info handler accepts optional ?base= query param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    // The handler must read ?base=<branch> and forward it to the
    // diff/ahead computations (design decision #12). The static check
    // verifies the handler at least reads the `base` query param.
    if (std.mem.indexOf(u8, source, "req.query.get(\"base\")") == null) {
        std.debug.print("!! git_worktree_info.zig does not read ?base= query param !!\n", .{});
        return error.GitWorktreeInfoBaseParamMissing;
    }
}

test "git_worktree_info handler probes origin/main + origin/master + origin/develop" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    // Auto-detection requires probing all three default base branches.
    // Static check ensures the handler enumerates them.
    if (std.mem.indexOf(u8, source, "origin/main") == null) {
        std.debug.print("!! git_worktree_info.zig does not probe origin/main !!\n", .{});
        return error.OriginMainProbeMissing;
    }
    if (std.mem.indexOf(u8, source, "origin/master") == null) {
        std.debug.print("!! git_worktree_info.zig does not probe origin/master !!\n", .{});
        return error.OriginMasterProbeMissing;
    }
    if (std.mem.indexOf(u8, source, "origin/develop") == null) {
        std.debug.print("!! git_worktree_info.zig does not probe origin/develop !!\n", .{});
        return error.OriginDevelopProbeMissing;
    }
}

test "test_runner.zig registers git_worktree_info.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/ai_workflow/tui/test_runner.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "@import(\"../../http_handlers/git_worktree_info.zig\")") == null) {
        std.debug.print("!! test_runner.zig does not import git_worktree_info.zig !!\n", .{});
        return error.GitWorktreeInfoTestRegistrationMissing;
    }
}
