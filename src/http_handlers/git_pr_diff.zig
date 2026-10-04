const std = @import("std");
const http_response = @import("http_response.zig");
const pabrik_core = @import("pabrikcore");
const gserverz = pabrik_core.gserverz;
const pr_provider = pabrik_core.pr_provider;

/// Cap for the returned unified diff (1MB). Larger PRs truncate with
/// `truncated=true` — the panel renders what fits and notes the cut.
pub const MAX_DIFF_BYTES: usize = 1024 * 1024;

/// Which backend produces the diff. Resolved purely from
/// (provider, cli_available) so it is unit-testable without IO.
pub const DiffStrategy = enum {
    gh_cli,
    glab_cli,
    git_fetch_pr_ref,
    git_fetch_mr_ref,
    git_local_range,
};

/// Pick the diff strategy. `cli_available` = whether the provider's
/// CLI (`gh` / `glab`) is on PATH. `generic` never has a CLI and
/// always diffs locally. When the CLI is missing for github/gitlab we
/// fall back to fetching the forge's well-known refspec over the
/// repo's existing remote credentials (`pull/N/head`,
/// `merge-requests/IID/head`).
pub fn resolveStrategy(provider: pr_provider.PrProvider, cli_available: bool) DiffStrategy {
    return switch (provider) {
        .github => if (cli_available) .gh_cli else .git_fetch_pr_ref,
        .gitlab => if (cli_available) .glab_cli else .git_fetch_mr_ref,
        .generic => .git_local_range,
    };
}

const PrDiffError = error{ NotARepository, CliMissing, FetchFailed, DiffFailed };

const PrDiffResult = struct {
    diff_content: []const u8,
    truncated: bool,
    base: []const u8,
    head: []const u8,
};

/// Check whether a CLI binary resolves on PATH (`gh` / `glab`).
/// Pure spawn probe: `cmd --version`, output discarded.
fn cliAvailable(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8) bool {
    const res = std.process.run(allocator, io, .{ .argv = &.{ cmd, "--version" } }) catch return false;
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }
    return res.term.exited == 0;
}

/// Run argv, return trimmed stdout on exit 0/1 (git diff uses exit 1
/// when differences exist), else the mapped error.
fn runGit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = std.process.run(allocator, io, .{ .argv = argv }) catch return error.DiffFailed;
    defer allocator.free(res.stderr);
    errdefer allocator.free(res.stdout);
    if (res.term.exited != 0 and res.term.exited != 1) return error.DiffFailed;
    return res.stdout;
}

/// Auto-detect the base branch: origin/main → origin/master →
/// origin/develop → "main" fallback. Same probe order as
/// git_worktree_info.zig (duplicated: that helper is not exported).
fn detectBase(allocator: std.mem.Allocator, io: std.Io, path: []const u8) []const u8 {
    const bases = [_][]const u8{ "main", "master", "develop" };
    for (bases) |b| {
        var buf: [64]u8 = undefined;
        const origin_b = std.fmt.bufPrint(&buf, "origin/{s}", .{b}) catch continue;
        const probe = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "rev-parse", "--verify", origin_b } }) catch continue;
        defer {
            allocator.free(probe.stdout);
            allocator.free(probe.stderr);
        }
        if (probe.term.exited == 0) return allocator.dupe(u8, b) catch "main";
    }
    return "main";
}

/// Current branch ("" when detached).
fn currentBranch(allocator: std.mem.Allocator, io: std.Io, path: []const u8) []const u8 {
    const res = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "branch", "--show-current" } }) catch return "";
    defer allocator.free(res.stderr);
    if (res.term.exited != 0) {
        allocator.free(res.stdout);
        return "";
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \n\r");
    if (trimmed.len == res.stdout.len) return res.stdout;
    defer allocator.free(res.stdout);
    return allocator.dupe(u8, trimmed) catch "";
}

/// Cap diff output at MAX_DIFF_BYTES. Consumes `owned`: returns it
/// whole when small, otherwise a duped prefix (original freed).
fn capDiff(allocator: std.mem.Allocator, owned: []u8) !struct { text: []const u8, truncated: bool } {
    if (owned.len <= MAX_DIFF_BYTES) return .{ .text = owned, .truncated = false };
    const prefix = try allocator.dupe(u8, owned[0..MAX_DIFF_BYTES]);
    allocator.free(owned);
    return .{ .text = prefix, .truncated = true };
}

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pr_url: []const u8,
    provider_override: ?[]const u8,
    base_override: ?[]const u8,
    head_override: ?[]const u8,
) !PrDiffResult {
    // 1) Must be a git repo.
    {
        const check = std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", path, "rev-parse", "--git-dir" } }) catch return error.NotARepository;
        defer {
            allocator.free(check.stdout);
            allocator.free(check.stderr);
        }
        if (check.term.exited != 0) return error.NotARepository;
    }

    const normalized = try pr_provider.normalizePrUrl(allocator, pr_url);
    defer allocator.free(normalized);

    const provider: pr_provider.PrProvider = if (provider_override) |o|
        pr_provider.PrProvider.fromString(o) orelse return error.DiffFailed
    else
        pr_provider.detectProvider(normalized);

    // github/gitlab need a parseable ref (number/IID).
    var number: []const u8 = "";
    if (provider != .generic) {
        const ref = pr_provider.parsePrRef(normalized, provider) orelse return error.DiffFailed;
        number = ref.number orelse return error.DiffFailed;
    }

    const strategy: DiffStrategy = switch (provider) {
        .github => resolveStrategy(.github, cliAvailable(allocator, io, "gh")),
        .gitlab => resolveStrategy(.gitlab, cliAvailable(allocator, io, "glab")),
        .generic => .git_local_range,
    };

    switch (strategy) {
        .gh_cli => {
            const ref = pr_provider.parsePrRef(normalized, .github).?;
            const argv: [6][]const u8 = .{ "gh", "pr", "diff", ref.number.?, "--repo", ref.repo_path };
            const res = std.process.run(allocator, io, .{ .argv = &argv }) catch return error.CliMissing;
            defer allocator.free(res.stderr);
            errdefer allocator.free(res.stdout);
            if (res.term.exited != 0) return error.FetchFailed;
            const capped = try capDiff(allocator, res.stdout);
            return .{ .diff_content = capped.text, .truncated = capped.truncated, .base = "", .head = "" };
        },
        .glab_cli => {
            const ref = pr_provider.parsePrRef(normalized, .gitlab).?;
            const argv: [6][]const u8 = .{ "glab", "mr", "diff", ref.number.?, "-R", ref.repo_path };
            const res = std.process.run(allocator, io, .{ .argv = &argv }) catch return error.CliMissing;
            defer allocator.free(res.stderr);
            errdefer allocator.free(res.stdout);
            if (res.term.exited != 0) return error.FetchFailed;
            const capped = try capDiff(allocator, res.stdout);
            return .{ .diff_content = capped.text, .truncated = capped.truncated, .base = "", .head = "" };
        },
        .git_fetch_pr_ref, .git_fetch_mr_ref => {
            const refspec = if (strategy == .git_fetch_pr_ref)
                try std.fmt.allocPrint(allocator, "pull/{s}/head:refs/pabrik-pr/{s}", .{ number, number })
            else
                try std.fmt.allocPrint(allocator, "merge-requests/{s}/head:refs/pabrik-mr/{s}", .{ number, number });
            defer allocator.free(refspec);
            const local_ref = if (strategy == .git_fetch_pr_ref)
                try std.fmt.allocPrint(allocator, "refs/pabrik-pr/{s}", .{number})
            else
                try std.fmt.allocPrint(allocator, "refs/pabrik-mr/{s}", .{number});
            defer allocator.free(local_ref);
            const fetch_argv: [6][]const u8 = .{ "git", "-C", path, "fetch", "origin", refspec };
            const fetch = std.process.run(allocator, io, .{ .argv = &fetch_argv }) catch return error.FetchFailed;
            defer {
                allocator.free(fetch.stdout);
                allocator.free(fetch.stderr);
            }
            if (fetch.term.exited != 0) return error.FetchFailed;
            const base = if (base_override) |b| b else detectBase(allocator, io, path);
            const range = try std.fmt.allocPrint(allocator, "{s}...{s}", .{ base, local_ref });
            defer allocator.free(range);
            const diff_argv: [5][]const u8 = .{ "git", "-C", path, "diff", range };
            const diff = try runGit(allocator, io, &diff_argv);
            const capped = try capDiff(allocator, diff);
            return .{ .diff_content = capped.text, .truncated = capped.truncated, .base = base, .head = local_ref };
        },
        .git_local_range => {
            const base: []const u8 = if (base_override) |b| b else detectBase(allocator, io, path);
            var head: []const u8 = if (head_override) |h| h else currentBranch(allocator, io, path);
            var head_owned = false;
            if (head.len == 0) {
                head = allocator.dupe(u8, "HEAD") catch "HEAD";
                head_owned = true;
            }
            defer if (head_owned) allocator.free(head);
            const range = try std.fmt.allocPrint(allocator, "{s}...{s}", .{ base, head });
            defer allocator.free(range);
            const diff_argv: [5][]const u8 = .{ "git", "-C", path, "diff", range };
            const diff = runGit(allocator, io, &diff_argv) catch return error.DiffFailed;
            const capped = try capDiff(allocator, diff);
            return .{ .diff_content = capped.text, .truncated = capped.truncated, .base = base, .head = head };
        },
    }
}

/// GET /api/git/pr/diff?path=<cwd>&pr_url=<url>[&provider=][&base=][&head=]
/// Returns the PR's full unified diff (1MB cap) for the right panel.
pub fn gitPrDiffHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const query = req.query;
    const path_param = query.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing path parameter") });
    };
    const pr_url_param = query.get("pr_url") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "Missing pr_url parameter") });
    };
    if (pr_url_param.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "pr_url cannot be empty") });
    }
    const provider_param = query.get("provider");
    if (provider_param) |pv| {
        if (pv.len > 0 and pr_provider.PrProvider.fromString(pv) == null) {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "provider must be \"github\", \"gitlab\", or \"generic\"") });
        }
    }
    const base_param = query.get("base");
    const head_param = query.get("head");

    const result = useCase(allocator, io, path_param, pr_url_param, provider_param, base_param, head_param) catch |err| switch (err) {
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, "not a git repository") });
        },
        error.CliMissing => {
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeGitStatusErrorResponse(allocator, "forge CLI not found on PATH (install gh for GitHub, glab for GitLab) and remote fetch failed") });
        },
        error.FetchFailed => {
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, "failed to fetch PR diff (check PR URL, provider, and auth)") });
        },
        error.DiffFailed => {
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, "failed to compute PR diff (check base/head refs)") });
        },
        else => return err,
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try makeGitPrDiffResponse(allocator, pr_url_param, result) });
}

pub const GitPrDiffResponse = struct {
    pr_url: []const u8,
    base: []const u8,
    head: []const u8,
    diff_content: []const u8,
    truncated: bool,
};

fn makeGitPrDiffResponse(allocator: std.mem.Allocator, pr_url: []const u8, result: PrDiffResult) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const escapeString = struct {
        fn escape(a: std.mem.Allocator, s: []const u8) ![]u8 {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(a);
            for (s) |c| {
                switch (c) {
                    '"' => try out.appendSlice(a, "\\\""),
                    '\\' => try out.appendSlice(a, "\\\\"),
                    '\n' => try out.appendSlice(a, "\\n"),
                    '\r' => try out.appendSlice(a, "\\r"),
                    '\t' => try out.appendSlice(a, "\\t"),
                    else => try out.append(a, c),
                }
            }
            return try out.toOwnedSlice(a);
        }
    }.escape;

    try buf.appendSlice(allocator, "{\"pr_url\":\"");
    const e_url = try escapeString(allocator, pr_url);
    defer allocator.free(e_url);
    try buf.appendSlice(allocator, e_url);
    try buf.appendSlice(allocator, "\", \"base\":\"");
    const e_base = try escapeString(allocator, result.base);
    defer allocator.free(e_base);
    try buf.appendSlice(allocator, e_base);
    try buf.appendSlice(allocator, "\", \"head\":\"");
    const e_head = try escapeString(allocator, result.head);
    defer allocator.free(e_head);
    try buf.appendSlice(allocator, e_head);
    try buf.appendSlice(allocator, "\", \"diff_content\":\"");
    const e_diff = try escapeString(allocator, result.diff_content);
    defer allocator.free(e_diff);
    try buf.appendSlice(allocator, e_diff);
    try buf.appendSlice(allocator, "\", \"truncated\":");
    try buf.appendSlice(allocator, if (result.truncated) "true" else "false");
    try buf.appendSlice(allocator, "}");

    return try buf.toOwnedSlice(allocator);
}

// ===== Static wiring tests (git_worktree_info.zig pattern) =====
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

test "git_pr_diff handler is exported from mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/http_handlers/mod.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const gitPrDiffHandler") == null) {
        std.debug.print("!! mod.zig does not export gitPrDiffHandler !!\n", .{});
        return error.NotExported;
    }
}

test "git_pr_diff route is registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/http_routes.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/git/pr/diff") == null) {
        std.debug.print("!! http_routes.zig does not register /api/git/pr/diff !!\n", .{});
        return error.NotRegistered;
    }
}

test "resolveStrategy picks CLI when present, fetch fallback otherwise" {
    try testing.expectEqual(DiffStrategy.gh_cli, resolveStrategy(.github, true));
    try testing.expectEqual(DiffStrategy.git_fetch_pr_ref, resolveStrategy(.github, false));
    try testing.expectEqual(DiffStrategy.glab_cli, resolveStrategy(.gitlab, true));
    try testing.expectEqual(DiffStrategy.git_fetch_mr_ref, resolveStrategy(.gitlab, false));
    try testing.expectEqual(DiffStrategy.git_local_range, resolveStrategy(.generic, true));
    try testing.expectEqual(DiffStrategy.git_local_range, resolveStrategy(.generic, false));
}
