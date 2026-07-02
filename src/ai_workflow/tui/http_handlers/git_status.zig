const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

pub const GitStatusError = error{
    OutOfMemory,
};

/// Git status endpoint - returns current branch and status for a directory
pub fn gitStatusHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path from query parameter
    const path_param = req.query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };

    // Check if we're in a git repo by running git rev-parse --git-dir with -C
    const git_check = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "rev-parse", "--git-dir" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Determine if it's a git repo based on rev-parse exit code
    const is_git_repo = git_check.term.exited == 0;

    // If not a git repo, return early with a 200 + is_git_repo=false body.
    // This is NOT a server error — it's a perfectly valid answer to "what's
    // the git status of <path>?" (answer: not a git repo). The frontend
    // (GitChanges.vue / RightSidebar.vue) reads `data.is_git_repo` and
    // gracefully hides the git panel when false; returning 500 here would
    // trigger the apiFetch error-toast for every non-repo path the user
    // navigates to. Sibling endpoint `git_changes.zig` does the same thing
    // correctly with status_code=200 — keep them in sync.
    if (!is_git_repo) {
        const response = http_response.GitStatusResponse{
            .is_git_repo = false,
        };
        return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitStatusResponse(allocator, response) });
    }

    // It IS a git repo — hand off to the use case for branch + status.
    const result = useCase(allocator, io, path_param) catch |err| {
        const message: []const u8 = switch (err) {
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, message) });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitStatusResponse(allocator, result) });
}

/// Use case: when the path IS a git repo, fetch branch + status and
/// return a populated `GitStatusResponse`. The "not a git repo" early-return
/// lives in the handler because the response semantics (200 vs any error
/// code) is an HTTP-level concern.
fn useCase(allocator: std.mem.Allocator, io: std.Io, path_param: []const u8) GitStatusError!http_response.GitStatusResponse {
    // Get current branch using: git -C <path> branch --show-current
    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "branch", "--show-current" },
    }) catch return error.OutOfMemory;

    // Get status using: git -C <path> status --porcelain
    const status_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "status", "--porcelain" },
    }) catch return error.OutOfMemory;

    // Parse branch name
    const branch_name = std.mem.trim(u8, branch_result.stdout, " \n\r");

    // Check if there are changes
    const has_changes = status_result.stdout.len > 0;

    // Build response
    const is_clean = !has_changes;
    const status_text: []const u8 = if (has_changes) "modified" else "clean";

    return http_response.GitStatusResponse{
        .is_git_repo = true,
        .branch = branch_name,
        .has_changes = has_changes,
        .is_clean = is_clean,
        .status = status_text,
    };
}