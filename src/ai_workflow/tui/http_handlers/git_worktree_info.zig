const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// Git worktree info endpoint — returns branch, last commit, base-branch
/// auto-detection, and a draft PR title/body for the worktree at `path`.
///
/// Query params:
///   - `path` (required) — absolute worktree path
///   - `base` (optional) — override the auto-detected base branch. When
///     present, `commits_ahead` and `diff_summary` are computed against
///     `origin/<base>` instead of the auto-detected default
///     (origin/main → origin/master → origin/develop). See design
///     decision #12 of the git-worktree-cwd-pr plan.
///
/// Returns:
///   {
///     "is_git_repo": true,
///     "branch": "worktree/feature-x",
///     "last_commit_sha": "abc1234",
///     "last_commit_msg": "Add feature x",
///     "default_base": "main",        // first of origin/main, origin/master, origin/develop
///     "commits_ahead": 3,
///     "diff_summary": " 3 files changed, 42 insertions(+), 7 deletions(-)",
///     "draft_title": "Add feature x",
///     "draft_body": "## Summary\n\n- Change 1\n- Change 2\n"
///   }
pub fn gitWorktreeInfoHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const path_param = req.query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing path parameter" }) });
    };

    // Optional ?base=<branch> override. When present, the diff + commit
    // count are calculated against `origin/<base>` instead of the
    // auto-detected default. The frontend passes this on the
    // regenerate button click in CreatePrDialog.
    const explicit_base_param = req.query.get("base");

    // 1) Confirm it's a git repo
    const git_dir_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-parse", "--git-dir" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };
    defer {
        allocator.free(git_dir_check.stdout);
        allocator.free(git_dir_check.stderr);
    }

    if (git_dir_check.term.exited != 0) {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "not a git repository" }) });
    }

    // 2) Current branch
    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "branch", "--show-current" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };
    defer allocator.free(branch_result.stdout);
    defer allocator.free(branch_result.stderr);

    const branch = std.mem.trim(u8, branch_result.stdout, " \n\r");

    // 3) Last commit (short SHA + subject)
    const log_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "log", "-1", "--format=%h %s" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }) });
    };
    defer allocator.free(log_result.stdout);
    defer allocator.free(log_result.stderr);

    const log_line = std.mem.trim(u8, log_result.stdout, " \n\r");
    var last_sha: []const u8 = "";
    var last_msg: []const u8 = "";
    if (std.mem.indexOf(u8, log_line, " ")) |space_idx| {
        last_sha = log_line[0..space_idx];
        last_msg = log_line[space_idx + 1 ..];
    }

    // 4) Default base branch — try origin/main, origin/master, origin/develop in order.
    // If the `?base=` query param was supplied, use it directly and skip
    // auto-detection (the user has already chosen the base).
    var default_base: []const u8 = "main";
    if (explicit_base_param) |eb| {
        if (eb.len > 0) default_base = eb;
    } else {
        const bases = [_][]const u8{ "main", "master", "develop" };
        for (bases) |b| {
            const probe = std.process.run(allocator, io, .{
                .argv = &.{ "git", "-C", path_param, "rev-parse", "--verify", "origin/" ++ b },
            }) catch continue;
            defer {
                allocator.free(probe.stdout);
                allocator.free(probe.stderr);
            }
            if (probe.term.exited == 0) {
                default_base = b;
                break;
            }
        }
    }

    // 5) Commits ahead (against `origin/<default_base>`, which may have been overridden by ?base=)
    var commits_ahead: i64 = 0;
    if (std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-list", "--count", "origin/" ++ default_base ++ "..HEAD" },
    })) |ahead_result| {
        defer {
            allocator.free(ahead_result.stdout);
            allocator.free(ahead_result.stderr);
        }
        if (ahead_result.term.exited == 0) {
            const trimmed = std.mem.trim(u8, ahead_result.stdout, " \n\r");
            commits_ahead = std.fmt.parseInt(i64, trimmed, 10) catch 0;
        }
    } else |_| {
        // rev-list failed (e.g. the base ref doesn't actually exist) — leave
        // commits_ahead at 0 rather than returning an error.
    }

    // 6) Diff summary against `origin/<default_base>`
    var diff_summary: []const u8 = "";
    if (std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "diff", "--shortstat", "origin/" ++ default_base ++ "..HEAD" },
    })) |diff_result| {
        defer {
            allocator.free(diff_result.stdout);
            allocator.free(diff_result.stderr);
        }
        if (diff_result.term.exited == 0) {
            diff_summary = std.mem.trim(u8, diff_result.stdout, " \n\r");
        }
    } else |_| {
        // Same rationale as rev-list — leave diff_summary empty.
    }

    // 7) Draft title = last commit subject. Draft body = "## Summary\n\n<diff shortstat>\n\nCommits ahead: N\n"
    const draft_title = last_msg;
    const draft_body = try std.fmt.allocPrint(allocator, "## Summary\n\n{s}\n\nCommits ahead: {d}\n", .{ diff_summary, commits_ahead });
    defer allocator.free(draft_body);

    const response = http_response.GitWorktreeInfoResponse{
        .is_git_repo = true,
        .branch = branch,
        .last_commit_sha = last_sha,
        .last_commit_msg = last_msg,
        .default_base = default_base,
        .commits_ahead = commits_ahead,
        .diff_summary = diff_summary,
        .draft_title = draft_title,
        .draft_body = draft_body,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitWorktreeInfoResponse(allocator, response) });
}