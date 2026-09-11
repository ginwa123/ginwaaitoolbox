const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// Outcome of running `gh pr create` in a worktree. The use case catches
/// every `gh`-related failure mode (spawn failure, non-zero exit, signal
/// kill, wait failure) and surfaces them via `status == .gh_failed` +
/// `stderr` so the handler does not need to know anything about process
/// plumbing. The use case only propagates the unexpected error union
/// (`std.fmt.AllocPrintError` and similar) for things like OOM.
const GhStatus = enum { success, gh_failed };

const CreatePullRequestResult = struct {
    status: GhStatus,
    /// Populated on success (the PR URL `gh` printed on stdout, trimmed).
    /// Empty on failure.
    pr_url: []const u8,
    /// Populated on failure (the trimmed `gh` stderr, or a synthesized
    /// message like "FileNotFound (is the gh CLI installed and on PATH?)"
    /// when spawn itself failed). Empty on success.
    stderr: []const u8,
};

/// Use case — spawn `gh pr create` in the worktree directory and capture
/// the result. No HTTP types; takes the same `(allocator, io, …)` pair
/// the GinwaServer handler gives us, returns a domain struct.
///
/// On success, `pr_url` holds the trimmed stdout (gh prints the URL).
/// On any `gh`-related failure, `status` is `.gh_failed` and `stderr`
/// holds either the trimmed gh stderr or a synthesized hint. The function
/// does NOT raise any domain-specific errors; the handler maps the
/// status to HTTP 200/500.
fn createPullRequestUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    worktree_path: []const u8,
    base: []const u8,
    title: []const u8,
    body: []const u8,
) !CreatePullRequestResult {
    // Run `gh pr create --base <base> --title <title> --body <body>`.
    const argv = &[_][]const u8{
        "gh", "pr", "create",
        "--base",  base,
        "--title", title,
        "--body",  body,
    };

    var child = std.process.spawn(io, .{
        .argv = argv,
        // Per memory zig-0.16-spawn-cwd-is-not-nullable.md: `.cwd` MUST
        // be a `process.Child.Cwd` tagged-union value, NOT `null`.
        .cwd = .{ .path = worktree_path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        // Spawn-time failure (gh not installed, perm denied, etc).
        // Synthesize a stderr message so the handler can return it verbatim.
        return CreatePullRequestResult{
            .status = .gh_failed,
            .pr_url = "",
            .stderr = std.fmt.allocPrint(allocator, "{s} (is the gh CLI installed and on PATH?)", .{@errorName(err)}) catch "",
        };
    };

    // Read stdout + stderr in parallel, bounded to 64KB each (matches the
    // set_git_worktree.zig:160-190 pattern).
    var stdout_buf: std.ArrayList(u8) = .empty;
    var stderr_buf: std.ArrayList(u8) = .empty;

    var read_buf: [4096]u8 = undefined;
    if (child.stdout) |pipe| {
        while (true) {
            const n = std.Io.File.readStreaming(pipe, io, &.{&read_buf}) catch break;
            if (n == 0) break;
            if (stdout_buf.items.len < 64 * 1024) {
                const take = @min(n, 64 * 1024 - stdout_buf.items.len);
                stdout_buf.appendSlice(allocator, read_buf[0..take]) catch break;
            }
        }
    }
    if (child.stderr) |pipe| {
        while (true) {
            const n = std.Io.File.readStreaming(pipe, io, &.{&read_buf}) catch break;
            if (n == 0) break;
            if (stderr_buf.items.len < 64 * 1024) {
                const take = @min(n, 64 * 1024 - stderr_buf.items.len);
                stderr_buf.appendSlice(allocator, read_buf[0..take]) catch break;
            }
        }
    }

    const term = child.wait(io) catch {
        return CreatePullRequestResult{
            .status = .gh_failed,
            .pr_url = "",
            .stderr = "gh wait failed",
        };
    };
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                // Surface the gh CLI error verbatim so the user can debug
                // (e.g. "no commits between origin/main and worktree/feature-x").
                return CreatePullRequestResult{
                    .status = .gh_failed,
                    .pr_url = "",
                    .stderr = std.mem.trim(u8, stderr_buf.items, " \n\r"),
                };
            }
        },
        .signal => {
            return CreatePullRequestResult{
                .status = .gh_failed,
                .pr_url = "",
                .stderr = "gh killed by signal",
            };
        },
        else => {
            return CreatePullRequestResult{
                .status = .gh_failed,
                .pr_url = "",
                .stderr = "gh terminated abnormally",
            };
        },
    }

    // gh pr create prints the PR URL on stdout.
    return CreatePullRequestResult{
        .status = .success,
        .pr_url = std.mem.trim(u8, stdout_buf.items, " \n\r"),
        .stderr = "",
    };
}

/// HTTP handler for `POST /api/git/pr`.
///
/// Body: { "worktree_path": "...", "base": "main", "title": "...", "body": "..." }
///
/// This handler is a thin wrapper: it parses + validates the request body,
/// delegates to `createPullRequestUseCase`, then maps the domain result to
/// an HTTP response. All `gh` CLI knowledge lives in the use case.
pub fn gitPrCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Parse JSON body using the Leaky variant — see memory
    // nalar-http-handler-thin-wrapper-pattern.md. No `defer parsed.deinit()`
    // because the per-request arena reaps the parsed value (memory
    // custom-http-server-per-request-arena).
    const Body = struct {
        worktree_path: []const u8 = "",
        base: []const u8 = "main",
        title: []const u8 = "",
        body: []const u8 = "",
    };
    const parsed = std.json.parseFromSliceLeaky(Body, allocator, req.body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }) });
    };

    if (parsed.worktree_path.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "worktree_path is required" }) });
    }
    if (parsed.title.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "title is required" }) });
    }

    const result = try createPullRequestUseCase(
        allocator,
        ctx.io,
        parsed.worktree_path,
        parsed.base,
        parsed.title,
        parsed.body,
    );

    const status_code: u16 = switch (result.status) {
        .success => 200,
        .gh_failed => 500,
    };

    return res.jsonResponse(.{ .status_code = status_code, .data = try http_response.makeGitPrCreateResponse(allocator, http_response.GitPrCreateResponse{
        .success = result.status == .success,
        .pr_url = result.pr_url,
        .@"error" = result.stderr,
    }) });
}

// ===== Tests merged from git_pr_create_test.zig (2026-09-11 flatten) =====
// Stub test file - Chunk 3 fills this in.
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/git_pr_create.zig";
const MOD_PATH = "src/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const HTTP_RESP_PATH = "src/http_handlers/http_response.zig";

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

test "git_pr_create handler is exported from mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const gitPrCreateHandler") == null) {
        std.debug.print("!! mod.zig does not export gitPrCreateHandler !!\n", .{});
        return error.GitPrCreateExportMissing;
    }
    if (std.mem.indexOf(u8, source, "@import(\"git_pr_create.zig\")") == null) {
        std.debug.print("!! mod.zig does not @import git_pr_create.zig !!\n", .{});
        return error.GitPrCreateImportMissing;
    }
}

test "git_pr_create route is registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/git/pr") == null) {
        std.debug.print("!! main.zig does not register /api/git/pr !!\n", .{});
        return error.GitPrCreateRouteMissing;
    }
    if (std.mem.indexOf(u8, source, "gitPrCreateHandler") == null) {
        std.debug.print("!! main.zig does not reference gitPrCreateHandler !!\n", .{});
        return error.GitPrCreateHandlerRefMissing;
    }
}

test "http_response.zig defines GitPrCreateResponse struct + helper" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HTTP_RESP_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "GitPrCreateResponse") == null) {
        std.debug.print("!! http_response.zig does not define GitPrCreateResponse !!\n", .{});
        return error.GitPrCreateResponseTypeMissing;
    }
    if (std.mem.indexOf(u8, source, "makeGitPrCreateResponse") == null) {
        std.debug.print("!! http_response.zig does not define makeGitPrCreateResponse helper !!\n", .{});
        return error.GitPrCreateResponseHelperMissing;
    }
}

test "git_pr_create handler body has worktree_path, base, title, body fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "worktree_path: []const u8") == null) {
        std.debug.print("!! git_pr_create.zig Body struct is missing 'worktree_path' field !!\n", .{});
        return error.WorktreePathFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "base: []const u8") == null) {
        std.debug.print("!! git_pr_create.zig Body struct is missing 'base' field !!\n", .{});
        return error.BaseFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "title: []const u8") == null) {
        std.debug.print("!! git_pr_create.zig Body struct is missing 'title' field !!\n", .{});
        return error.TitleFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "body: []const u8") == null) {
        std.debug.print("!! git_pr_create.zig Body struct is missing 'body' field !!\n", .{});
        return error.BodyFieldMissing;
    }
}
