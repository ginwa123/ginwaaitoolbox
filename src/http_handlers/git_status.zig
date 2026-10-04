const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;

/// Git status endpoint - returns current branch and status for a directory
pub fn gitStatusHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // Get path from query parameter
    const query = req.query;
    const path_param = query.get("path") orelse {
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

    // Get current branch using: git -C <path> branch --show-current
    const branch_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "branch", "--show-current" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Get status using: git -C <path> status --porcelain
    const status_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", path_param, "status", "--porcelain" },
    }) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeGitStatusErrorResponse(allocator, @errorName(err)) });
    };

    // Parse branch name
    const branch_name = std.mem.trim(u8, branch_result.stdout, " \n\r");

    // Check if there are changes
    const has_changes = status_result.stdout.len > 0;

    // Build response
    const is_clean = !has_changes;
    const status_text: []const u8 = if (has_changes) "modified" else "clean";

    const response = http_response.GitStatusResponse{
        .is_git_repo = true,
        .branch = branch_name,
        .has_changes = has_changes,
        .is_clean = is_clean,
        .status = status_text,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitStatusResponse(allocator, response) });
}

// ===== Tests merged from git_status_test.zig (2026-09-11 flatten) =====
// Static regression checks for `gitStatusHandler`.
// 
// Why this file exists
// ────────────────────
// The handler originally returned HTTP 500 + `{is_git_repo: false}` for the
// "requested path is not a git repo" case. That is internally contradictory —
// the body is a perfectly valid answer to "what's the git status of <path>?",
// yet the 500 status code triggers the frontend `apiFetch` error-toast wrapper
// (see `src/apps/desktop/src/api/index.ts`) and breaks the GitChanges.vue /
// RightSidebar.vue contract that reads `data.is_git_repo` to decide whether
// to render the git panel. Sibling endpoint `git_changes.zig:150` returns 200
// for the same case; `git_status.zig` must match.
// 
// This file enforces ONE contract:
//   1. The `if (!is_git_repo)` branch returns `.status_code = 200` (NOT 500).

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/git_status.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
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

// ─── Contract 1: not-a-repo branch returns 200, not 500 ────────────────────

test "git_status.zig: not-a-git-repo branch returns 200, not 500" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Find the response literal for the not-a-repo branch. It's the only
    // place in the file that uses `is_git_repo = false` for the response
    // struct (the other branch — is_git_repo=true — uses `is_git_repo = true`).
    const needle = "is_git_repo = false,\n        };";
    const idx = std.mem.indexOf(u8, source, needle) orelse {
        std.debug.print(
            "\n!! could not find `is_git_repo = false` response literal in {s} !!\n" ++
                "   The handler structure may have changed; update this test.\n",
            .{HANDLER_PATH},
        );
        return error.ResponseLiteralNotFound;
    };

    // Look at the immediately following ~300 chars (the `return res.jsonResponse`
    // call that uses this response). It must use `status_code = 200`.
    const end = @min(idx + needle.len + 300, source.len);
    const after = source[idx..end];

    if (std.mem.indexOf(u8, after, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s}: the not-a-git-repo branch does not return 200 !!\n" ++
                "   Expected `.status_code = 200` (a valid answer is not a server error).\n" ++
                "   Sibling handler git_changes.zig:150 returns 200 for the same case.\n",
            .{HANDLER_PATH},
        );
        return error.NotARepoStatusShouldBe200;
    }

    if (std.mem.indexOf(u8, after, ".status_code = 500") != null) {
        std.debug.print(
            "\n!! {s}: the not-a-git-repo branch returns 500 !!\n" ++
                "   This is wrong — \"not a git repo\" is a perfectly valid answer\n" ++
                "   to \"what's the git status of <path>?\" and should return 200\n" ++
                "   with `is_git_repo: false` in the body. Returning 500 triggers\n" ++
                "   the frontend apiFetch error-toast for every non-repo path.\n",
            .{HANDLER_PATH},
        );
        return error.NotARepoStatusShouldNotBe500;
    }
}
