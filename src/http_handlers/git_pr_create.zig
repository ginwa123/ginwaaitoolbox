const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const run_captured = @import("helpers").run_captured;

/// The `gh` binary. See `git_pr_status.zig` for the shared constants.
const GH_PROGRAM = "gh";

/// Wall-clock budget for one `gh pr create`. Creating a PR uploads a
/// branch, so this is more generous than the read-only `pr view` budget
/// — but still bounded, so a credential prompt can't wedge a worker.
const GH_TIMEOUT_MS: u32 = 60_000;

/// Per-stream capture cap for the PR URL / gh error text.
const MAX_CAPTURE_BYTES: usize = 64 * 1024;

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
/// `gh` is invoked through `helpers.run_captured` rather than a
/// hand-rolled `spawn` → drain-stdout → drain-stderr → `Child.wait`.
/// The hand-rolled shape is what killed the server in
/// `git_pr_status.zig`: `Child.wait` runs `childCleanupPosix`, which
/// `closeFd`s every pipe still attached to the `Child`, and Zig 0.16
/// turns EBADF there into `unreachable` in Debug builds — a
/// process-wide SIGABRT. Draining stdout before stderr also deadlocks
/// as soon as `gh` writes more than one 64 KiB pipe buffer to stderr.
/// See `src/helpers/run_captured.zig`.
///
/// On success, `pr_url` holds the trimmed stdout (gh prints the URL).
/// On any `gh`-related failure, `status` is `.gh_failed` and `stderr`
/// holds either the trimmed gh stderr, or a synthesized hint. The
/// function does NOT raise any domain-specific errors; the handler maps
/// the status to HTTP 200/500.
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
        GH_PROGRAM, "pr",     "create",
        "--base",   base,     "--title",
        title,      "--body", body,
    };

    // stdout + stderr are captured concurrently and capped; the child
    // is killed + reaped if it outlives the deadline, so a `gh` stuck
    // on a credential prompt can't wedge a worker-pool thread forever.
    var res = run_captured.run(allocator, io, argv, .{
        .cwd = worktree_path,
        .max_output_bytes = MAX_CAPTURE_BYTES,
        .timeout_ms = GH_TIMEOUT_MS,
    }) catch |err| {
        // Spawn-time failure (gh not installed, perm denied, etc).
        // Synthesize a stderr message so the handler can return it verbatim.
        return ghFailed(allocator, std.fmt.allocPrint(allocator, "{s} (is the gh CLI installed and on PATH?)", .{@errorName(err)}) catch "");
    };
    defer res.deinit(allocator);

    if (res.timed_out) {
        return ghFailed(allocator, "gh pr create timed out");
    }

    switch (res.term) {
        .exited => |code| {
            if (code != 0) {
                // Surface the gh CLI error verbatim so the user can debug
                // (e.g. "no commits between origin/main and worktree/feature-x").
                return ghFailed(allocator, std.mem.trim(u8, res.stderr, " \n\r"));
            }
        },
        .signal => return ghFailed(allocator, "gh killed by signal"),
        else => return ghFailed(allocator, "gh terminated abnormally"),
    }

    // gh pr create prints the PR URL on stdout. `res` is freed by the
    // defer above, so the URL must be copied into the request arena
    // before returning.
    return .{
        .status = .success,
        .pr_url = allocator.dupe(u8, std.mem.trim(u8, res.stdout, " \n\r")) catch "",
        .stderr = "",
    };
}

/// `.gh_failed` result whose `stderr` is a copy of `msg` in the request
/// arena, so the caller can free `msg` (or pass a borrowed literal)
/// without a use-after-free in the HTTP response.
fn ghFailed(allocator: std.mem.Allocator, msg: []const u8) CreatePullRequestResult {
    return .{
        .status = .gh_failed,
        .pr_url = "",
        .stderr = allocator.dupe(u8, msg) catch "gh pr create failed",
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
