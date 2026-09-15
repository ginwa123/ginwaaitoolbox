const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const pr_provider = nalar_core.pr_provider;

/// Fields requested from `gh pr view --json`. Kept as a single const so
/// the CLI help and the use case never drift apart.
pub const GH_JSON_FIELDS = "number,title,url,state,mergeable,mergeStateStatus,headRefName,baseRefName,createdAt,updatedAt,mergedAt,closedAt,author,additions,deletions,changedFiles";

const PrStatusError = error{ NotARepository, CliMissing, NoAssociatedPr, FetchFailed };

/// Raw shape of `gh pr view --json ...` output. All fields optional with
/// defaults so a future `gh` version adding/removing a key does not break
/// parsing — missing keys surface as empty strings / zeros.
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
    mergedAt: []const u8 = "",
    closedAt: []const u8 = "",
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

/// Run `gh pr view` in `path` and return the raw stdout JSON (owned).
/// `pr_arg` is "" for "current branch's PR", otherwise a number, URL,
/// or branch name passed straight through to `gh`.
fn runGhPrView(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
) ![]u8 {
    // Build argv on the stack: `gh pr view [<pr>] --json <fields>`.
    // When pr_arg is empty we omit it so `gh` resolves the PR for the
    // current branch (the most common CLI usage).
    var argv_buf: [6][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "gh";
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

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.CliMissing;

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
        allocator.free(stdout_buf.items);
        allocator.free(stderr_buf.items);
        return error.FetchFailed;
    };
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                const stderr_trimmed = std.mem.trim(u8, stderr_buf.items, " \n\r");
                const is_no_pr = std.ascii.indexOfIgnoreCase(stderr_trimmed, "no pull request") != null or
                    std.ascii.indexOfIgnoreCase(stderr_trimmed, "no pull requests found") != null or
                    std.ascii.indexOfIgnoreCase(stderr_trimmed, "could not find") != null;
                allocator.free(stdout_buf.items);
                allocator.free(stderr_buf.items);
                if (is_no_pr) return error.NoAssociatedPr;
                return error.FetchFailed;
            }
        },
        else => {
            allocator.free(stdout_buf.items);
            allocator.free(stderr_buf.items);
            return error.FetchFailed;
        },
    }
    allocator.free(stderr_buf.items);
    return stdout_buf.toOwnedSlice(allocator);
}

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_arg: []const u8,
    provider_override: ?[]const u8,
) !http_response.GitPrStatusResponse {
    // 1) Must be a git repo.
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
            const p = pr_provider.PrProvider.fromString(o) orelse return error.FetchFailed;
            if (p != .github) return error.FetchFailed;
        }
    } else if (pr_arg.len > 0 and std.mem.indexOf(u8, pr_arg, "://") != null) {
        const normalized = pr_provider.normalizePrUrl(allocator, pr_arg) catch null;
        if (normalized) |n| {
            defer allocator.free(n);
            if (pr_provider.detectProvider(n) != .github) return error.FetchFailed;
        }
    }

    const raw = try runGhPrView(allocator, io, path, pr_arg);
    defer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \n\r");
    const parsed = std.json.parseFromSliceLeaky(GhPrView, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch return error.FetchFailed;

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
        .merged_at = try allocator.dupe(u8, parsed.mergedAt),
        .closed_at = try allocator.dupe(u8, parsed.closedAt),
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

    const result = useCase(allocator, io, path_param, pr_param, provider_param) catch |err| switch (err) {
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
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, "failed to fetch PR status (check PR number/URL, provider, and gh auth)") });
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
