const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const pr_provider = nalar_core.pr_provider;
const run_captured = @import("helpers").run_captured;

// ── What this is for ──────────────────────────────────────────────────────
//
// The PR tab knows a PR is `mergeable=CONFLICTING` but nothing about *which*
// files stop it merging, so the user gets a red badge and a link to the
// forge's web editor. Neither forge can fill that gap:
//
//   • GitHub REST `GET /repos/{o}/{r}/pulls/{n}/files` lists every changed
//     file, not the conflicting ones, and GraphQL's `PullRequest` type has no
//     conflicting-files field either.
//   • GitLab's `GET /projects/:id/merge_requests/:iid` exposes `changes` (the
//     diff) and a `detailed_merge_status` string — again no file list.
//
// GitHub's own "Resolve conflicts" tab computes the list server-side with a
// three-way merge. So do we: `git merge-tree` runs the same merge locally, on
// refs the user already has, with no forge CLI, no network and no auth — and
// it behaves identically for GitHub, self-hosted GitLab and the `generic`
// provider.
//
// ## The output contract (verified on git 2.55.0)
//
//     $ git merge-tree -z --write-tree --name-only <base> <head>
//     <tree-OID>\0<path>\0<path>\0\0<informational messages…>
//     exit 0 → clean, exit 1 → conflicts, anything else → failure
//
// Records are NUL-separated, so a path containing a newline cannot desync the
// parser. The conflicted-file section is terminated by an **empty record**;
// everything after it is git's human-readable `Auto-merging …` chatter, which
// [`parseConflictPaths`] stops at.

/// Cap on the returned conflict list. A pathological history (two branches
/// that both rewrote the whole tree) can produce thousands of paths; the
/// payload is a UI list, not a report. `truncated` says so rather than
/// silently dropping paths.
pub const MAX_CONFLICT_FILES: usize = 500;

/// Wall-clock budget per git invocation. `merge-tree` on a large repo is a
/// few hundred milliseconds; anything past this is a wedged child, and
/// `run_captured` kills the process group at the deadline so a worker-pool
/// thread cannot be held hostage.
pub const GIT_TIMEOUT_MS: u32 = 20_000;

/// Per-stream capture cap. The conflicted-file section is bounded by
/// MAX_CONFLICT_FILES; the informational section is the only unbounded part
/// and is discarded during parsing.
const MAX_OUTPUT_BYTES: usize = 256 * 1024;

/// How much of git's stderr rides along in the HTTP 502 `error` field. The
/// real causes are one line (`unknown option --write-tree` on git < 2.38,
/// `fatal: Not a valid object name …`), but a hook stack trace is not.
const MAX_DETAIL_BYTES: usize = 300;

const PrConflictsError = error{
    NotARepository,
    BaseRefNotFound,
    MergeTreeFailed,
};

/// The parseable answer: every path git refused to merge cleanly.
pub const ConflictPaths = struct {
    /// Owned slices into the caller's allocator; safe to free individually.
    files: [][]const u8,
    /// True when git named more than [`MAX_CONFLICT_FILES`] paths.
    truncated: bool,
};

/// Outcome of one git invocation: exit code + both streams. `stdout`/`stderr`
/// stay owned by the caller.
/// Free every buffer [`parseConflictPaths`] allocated. Each path is its own
/// allocation, so the slice array alone is not enough to release the result.
pub fn deinitConflictPaths(allocator: std.mem.Allocator, parsed: ConflictPaths) void {
    for (parsed.files) |f| allocator.free(f);
    allocator.free(parsed.files);
}

const GitRun = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: GitRun, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    fn trimmedStderr(self: GitRun) []const u8 {
        return std.mem.trim(u8, self.stderr, " \n\r\t");
    }
};

/// Run one `git -C <path> …` and hand back its streams.
///
/// Every spawn goes through `helpers.run_captured`: hand-rolling the spawn +
/// wait inside a handler SIGABRTs the whole server on an EBADF pipe close,
/// deadlocks when git writes more than one pipe buffer to stderr, and has no
/// deadline at all (see that module's header for the three production incidents
/// it was extracted from). The static test at the bottom of this file greps for
/// the hand-rolled form, so do not spell it out here or in any comment.
fn runGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    args: []const []const u8,
) !GitRun {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", path });
    try argv.appendSlice(allocator, args);

    var res = run_captured.run(allocator, io, argv.items, .{
        .cwd = path,
        .max_output_bytes = MAX_OUTPUT_BYTES,
        .timeout_ms = GIT_TIMEOUT_MS,
    }) catch return error.MergeTreeFailed;

    if (res.timed_out) {
        res.deinit(allocator);
        return error.MergeTreeFailed;
    }

    // A child killed by a signal reports as `.exited` on some platforms and
    // as a signal term on others; only a self-reported exit code 0/1/other
    // is meaningful to us.
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => {
            res.deinit(allocator);
            return error.MergeTreeFailed;
        },
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

/// Does `<ref>^{commit}` resolve in this repo? `rev-parse --verify --quiet`
/// exits 1 (printing nothing) for a missing ref, so the stderr is irrelevant.
fn refExists(allocator: std.mem.Allocator, io: std.Io, path: []const u8, ref: []const u8) bool {
    const commitish = std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref}) catch return false;
    defer allocator.free(commitish);
    const run = runGit(allocator, io, path, &.{ "rev-parse", "--verify", "--quiet", commitish }) catch return false;
    defer run.deinit(allocator);
    return run.code == 0;
}

/// First candidate base ref that resolves, else `error.BaseRefNotFound`.
///
/// Interleaves remote-tracking and bare names (`origin/main`, `main`,
/// `origin/master`, …) so the remote-tracking ref always wins when both
/// exist: the forge merged against `origin/main`, and a local `main` can be
/// arbitrarily far behind it.
///
/// No `git fetch` here on purpose. A panel that mutates refs, hits the network
/// and can block on a credential prompt is worse than an answer computed from
/// what the user already has — and when the ref really is missing the handler
/// says "run `git fetch`" instead of guessing.
///
/// Returned slice is owned by the caller.
fn resolveBaseRef(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    requested: ?[]const u8,
) ![]u8 {
    var buf: [512]u8 = undefined;

    if (requested) |b| {
        if (b.len == 0) return error.BaseRefNotFound;
        const remote = std.fmt.bufPrint(&buf, "refs/remotes/origin/{s}", .{b}) catch return error.BaseRefNotFound;
        if (refExists(allocator, io, path, remote)) return allocator.dupe(u8, remote) catch error.MergeTreeFailed;
        if (refExists(allocator, io, path, b)) return allocator.dupe(u8, b) catch error.MergeTreeFailed;
        return error.BaseRefNotFound;
    }

    const names = [_][]const u8{ "main", "master", "develop" };
    for (names) |n| {
        const remote = std.fmt.bufPrint(&buf, "refs/remotes/origin/{s}", .{n}) catch continue;
        if (refExists(allocator, io, path, remote)) return allocator.dupe(u8, remote) catch error.MergeTreeFailed;
        if (refExists(allocator, io, path, n)) return allocator.dupe(u8, n) catch error.MergeTreeFailed;
    }
    return error.BaseRefNotFound;
}

/// Short (10-hex) commit a ref points at, for the response's provenance line.
/// Best effort: an empty string is cosmetic, never a failure.
fn revParseShort(allocator: std.mem.Allocator, io: std.Io, path: []const u8, ref: []const u8) ?[]u8 {
    const commitish = std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref}) catch return null;
    defer allocator.free(commitish);
    const run = runGit(allocator, io, path, &.{ "rev-parse", "--short=10", commitish }) catch return null;
    defer run.deinit(allocator);
    if (run.code != 0) return null;
    const out = std.mem.trim(u8, run.stdout, " \n\r\t");
    return allocator.dupe(u8, out) catch null;
}

/// Split `git merge-tree -z --write-tree --name-only` stdout into paths.
///
/// Record 0 is the resulting tree OID and is skipped. Paths run until the
/// first empty record, which is the boundary before git's `Auto-merging …` /
/// `CONFLICT (content): …` informational section — that section must never be
/// rendered as if it were a file name.
pub fn parseConflictPaths(allocator: std.mem.Allocator, stdout: []const u8) !ConflictPaths {
    var files = std.ArrayList([]const u8).empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    var truncated = false;
    var it = std.mem.splitScalar(u8, stdout, 0);
    _ = it.next() orelse ""; // tree OID
    while (it.next()) |rec| {
        // Empty record ⇒ end of the conflicted-file section.
        if (rec.len == 0) break;
        if (files.items.len == MAX_CONFLICT_FILES) {
            truncated = true;
            break;
        }
        try files.append(allocator, try allocator.dupe(u8, rec));
    }
    return .{ .files = try files.toOwnedSlice(allocator), .truncated = truncated };
}

const PrConflictsResult = struct {
    /// Human-facing base label (the resolved ref, e.g. `refs/remotes/origin/main`).
    base_ref: []const u8,
    /// Commit the merge was computed against, or "" when rev-parse failed.
    base_commit: []const u8,
    head: []const u8,
    conflicting_files: [][]const u8,
    count: usize,
    truncated: bool,
};

/// Release every buffer [`useCase`] allocated. The handler has no arena of
/// its own to lean on (the result escapes into the JSON writer), so the
/// ownership rule is stated once here and mirrored by the inline tests.
pub fn deinitResult(allocator: std.mem.Allocator, result: PrConflictsResult) void {
    for (result.conflicting_files) |f| allocator.free(f);
    allocator.free(result.conflicting_files);
    allocator.free(result.base_ref);
    if (result.base_commit.len > 0) allocator.free(result.base_commit);
}

pub fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    base_override: ?[]const u8,
    head_override: ?[]const u8,
    detail: *?[]u8,
) !PrConflictsResult {
    // 1) Must be a git work tree. Probed first so every later failure can be
    // reported as a ref problem rather than a missing-repo 404.
    {
        const check = runGit(allocator, io, path, &.{ "rev-parse", "--git-dir" }) catch return error.NotARepository;
        defer check.deinit(allocator);
        if (check.code != 0) return error.NotARepository;
    }

    // 2) Resolve the two refs the merge runs over.
    const base_ref = try resolveBaseRef(allocator, io, path, base_override);
    // The panel is bound to the PR's own worktree, so the local HEAD is the
    // actionable answer: "what would conflict if I merged what I have right
    // now", which stays correct while the user is mid-resolution.
    const head: []const u8 = if (head_override) |h| (if (h.len > 0) h else "HEAD") else "HEAD";

    // 3) The three-way merge. This is the whole feature.
    const merge = runGit(allocator, io, path, &.{
        "merge-tree",
        "-z",
        "--write-tree",
        "--name-only",
        base_ref,
        head,
    }) catch {
        setDetail(allocator, detail, "git is not available on PATH");
        return error.MergeTreeFailed;
    };
    defer merge.deinit(allocator);

    // exit 0 → clean merge, exit 1 → conflicts. Anything else is a git error
    // (unknown flag on git < 2.38, bad object, unrelated histories refused);
    // its stderr is the only useful thing we can tell the user.
    if (merge.code != 0 and merge.code != 1) {
        const errtext = merge.trimmedStderr();
        setDetail(allocator, detail, if (errtext.len > 0) errtext else "git merge-tree failed");
        return error.MergeTreeFailed;
    }

    const parsed = try parseConflictPaths(allocator, merge.stdout);
    const base_commit = revParseShort(allocator, io, path, base_ref);

    return .{
        .base_ref = base_ref,
        .base_commit = base_commit orelse "",
        .head = head,
        .conflicting_files = parsed.files,
        .count = parsed.files.len,
        .truncated = parsed.truncated,
    };
}

fn setDetail(allocator: std.mem.Allocator, slot: *?[]u8, msg: []const u8) void {
    const trimmed = std.mem.trim(u8, msg, " \n\r\t");
    if (trimmed.len == 0) return;
    const take = @min(trimmed.len, MAX_DETAIL_BYTES);
    slot.* = allocator.dupe(u8, trimmed[0..take]) catch null;
}

/// `GET /api/git/pr/conflicts?path=<cwd>&pr_url=<url>[&provider=][&base=][&head=]`
///
/// Returns the paths a three-way merge of `<base>` into `<head>` refuses to
/// resolve. An empty `conflicting_files` is a legitimate 200 answer ("your
/// local merge of these two refs is clean") — the frontend tells it apart from
/// a failure by the absence of an `error` field, never by an empty list alone.
pub fn gitPrConflictsHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
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
    // `pr_url` identifies the PR for the caller but the computation is purely
    // local. Validating the provider anyway keeps the route contract uniform
    // with its siblings, so a bad value fails loudly instead of being silently
    // ignored.
    if (query.get("provider")) |pv| {
        if (pv.len > 0 and pr_provider.PrProvider.fromString(pv) == null) {
            return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeGitStatusErrorResponse(allocator, "provider must be \"github\", \"gitlab\", or \"generic\"") });
        }
    }

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);

    const result = useCase(allocator, io, path_param, query.get("base"), query.get("head"), &detail) catch |err| switch (err) {
        error.NotARepository => {
            return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeGitStatusErrorResponse(allocator, "not a git repository") });
        },
        error.BaseRefNotFound => {
            const wanted = query.get("base") orelse "main";
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "could not resolve base branch '{s}' locally — run `git fetch` and retry", .{wanted}) catch "could not resolve the base branch locally — run `git fetch` and retry";
            return res.jsonResponse(.{ .status_code = 422, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        error.MergeTreeFailed => {
            var buf: [MAX_DETAIL_BYTES + 96]u8 = undefined;
            const msg = if (detail) |d|
                std.fmt.bufPrint(&buf, "git merge-tree failed: {s}", .{d}) catch "git merge-tree failed"
            else
                "git merge-tree failed";
            return res.jsonResponse(.{ .status_code = 502, .data = try http_response.makeGitStatusErrorResponse(allocator, msg) });
        },
        else => return err,
    };
    defer deinitResult(allocator, result);

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeGitPrConflictsResponse(allocator, .{
        .pr_url = pr_url_param,
        .base_ref = result.base_ref,
        .base_commit = result.base_commit,
        .head = result.head,
        .conflicting_files = result.conflicting_files,
        .count = result.count,
        .truncated = result.truncated,
    }) });
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

test "git_pr_conflicts handler is exported from mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/http_handlers/mod.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "pub const gitPrConflictsHandler") == null) {
        std.debug.print("!! mod.zig does not export gitPrConflictsHandler !!\n", .{});
        return error.NotExported;
    }
}

test "git_pr_conflicts route is registered in main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/main.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "/api/git/pr/conflicts") == null) {
        std.debug.print("!! main.zig does not register /api/git/pr/conflicts !!\n", .{});
        return error.RouteMissing;
    }
}

test "git_pr_conflicts.zig spawns a child by hand — route it through helpers.run_captured !!" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/http_handlers/git_pr_conflicts.zig");
    defer allocator.free(source);
    // Assembled at comptime from fragments so this test does not match its own
    // needle, which would otherwise appear in the comment two lines above.
    const spawn_needle = "std.process." ++ "spawn";
    const child_needle = "std.process." ++ "Child";
    if (std.mem.indexOf(u8, source, spawn_needle) != null or
        std.mem.indexOf(u8, source, child_needle) != null)
    {
        std.debug.print("!! git_pr_conflicts.zig spawns a child by hand — route it through helpers.run_captured !!\n", .{});
        return error.SpawnBypass;
    }
}

// ===== parseConflictPaths unit tests =====

test "parseConflictPaths: clean merge returns an empty list" {
    const allocator = testing.allocator;
    const parsed = try parseConflictPaths(allocator, "3fc9bd1eaaea2fa32b201a318655cb2cfcce085e\x00");
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(@as(usize, 0), parsed.files.len);
    try testing.expect(!parsed.truncated);
}

test "parseConflictPaths: names before the empty record are the conflicting files" {
    const allocator = testing.allocator;
    // One OID record, two paths, the empty terminator, then git's
    // informational section — which must NOT be read as file names.
    const parsed = try parseConflictPaths(
        allocator,
        "aaa\x00src/a.zig\x00src/b b.py\x00\x00Auto-merging src/a.zig\x00CONFLICT (content): Merge conflict in src/a.zig\x00",
    );
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(@as(usize, 2), parsed.files.len);
    try testing.expectEqualStrings("src/a.zig", parsed.files[0]);
    try testing.expectEqualStrings("src/b b.py", parsed.files[1]);
}

test "parseConflictPaths: no terminator still parses (older git / truncated stream)" {
    const allocator = testing.allocator;
    const parsed = try parseConflictPaths(allocator, "aaa\x00src/only.zig\x00");
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
    try testing.expectEqualStrings("src/only.zig", parsed.files[0]);
}

test "parseConflictPaths: caps at MAX_CONFLICT_FILES and flags truncation" {
    const allocator = testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "aaa\x00");
    var name_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_CONFLICT_FILES + 25) : (i += 1) {
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&name_buf, "src/f{d}.zig\x00", .{i}));
    }
    try buf.append(allocator, 0);

    const parsed = try parseConflictPaths(allocator, buf.items);
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(MAX_CONFLICT_FILES, parsed.files.len);
    try testing.expect(parsed.truncated);
}

test "parseConflictPaths: empty stdout is clean, not an error" {
    const allocator = testing.allocator;
    const parsed = try parseConflictPaths(allocator, "");
    defer deinitConflictPaths(allocator, parsed);
    try testing.expectEqual(@as(usize, 0), parsed.files.len);
    try testing.expect(!parsed.truncated);
}

// ===== Synthetic-repo integration tests =====

fn tmpPath(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

fn git(path: []const u8, args: []const []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, &.{ "git", "-C", path });
    try argv.appendSlice(testing.allocator, args);
    var res = run_captured.run(testing.allocator, testing.io, argv.items, .{ .timeout_ms = 15_000 }) catch return error.GitFailed;
    res.deinit(testing.allocator);
}

/// Fresh repo on `main` with one commit. The temp dir has no user identity,
/// so `commit` fails without the three `config` writes first.
fn makeRepo(tmp: *std.testing.TmpDir, path: []const u8) !void {
    try git(path, &.{ "init", "-q", "-b", "main" });
    try git(path, &.{ "config", "user.email", "test@example.invalid" });
    try git(path, &.{ "config", "user.name", "nalar test" });
    try git(path, &.{ "config", "commit.gpgsign", "false" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared.txt", .data = "a\nb\nc\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "base_only.txt", .data = "base\n" });
    try git(path, &.{ "add", "-A" });
    try git(path, &.{ "commit", "-qm", "init" });
}

test "useCase names the file both sides changed" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp, allocator);
    defer allocator.free(path);
    try makeRepo(&tmp, path);

    // main edits line 2 of shared.txt; feature edits the SAME line
    // differently. Non-overlapping edits merge cleanly, so an earlier draft of
    // this fixture (main changing line 2, feature appending a new line at the
    // end) would have "passed" on a broken implementation.
    try git(path, &.{ "checkout", "-q", "-b", "feature" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared.txt", .data = "a\nFEATURE\nc\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "feat.txt", .data = "feature\n" });
    try git(path, &.{ "add", "-A" });
    try git(path, &.{ "commit", "-qm", "feat" });

    try git(path, &.{ "checkout", "-q", "main" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared.txt", .data = "a\nMAIN\nc\n" });
    try git(path, &.{ "commit", "-qam", "mainchange" });
    try git(path, &.{ "checkout", "-q", "feature" });

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);

    const result = try useCase(allocator, testing.io, path, null, null, &detail);
    defer deinitResult(allocator, result);

    try testing.expectEqual(@as(usize, 1), result.count);
    try testing.expectEqualStrings("shared.txt", result.conflicting_files[0]);
    try testing.expect(!result.truncated);
    // Provenance: the response must name the ref it merged against.
    try testing.expectEqualStrings("main", result.base_ref);
    try testing.expect(result.base_commit.len >= 7);
}

test "useCase reports a clean merge as zero files" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp, allocator);
    defer allocator.free(path);
    try makeRepo(&tmp, path);

    try git(path, &.{ "checkout", "-q", "-b", "feature" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "feat.txt", .data = "feature\n" });
    try git(path, &.{ "add", "-A" });
    try git(path, &.{ "commit", "-qm", "feat" });

    try git(path, &.{ "checkout", "-q", "main" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "base_only.txt", .data = "moved on\n" });
    try git(path, &.{ "commit", "-qam", "mainchange" });
    try git(path, &.{ "checkout", "-q", "feature" });

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);

    const result = try useCase(allocator, testing.io, path, null, null, &detail);
    defer deinitResult(allocator, result);
    try testing.expectEqual(@as(usize, 0), result.count);
}

test "useCase honours an explicit base ref" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp, allocator);
    defer allocator.free(path);
    try makeRepo(&tmp, path);

    // `trunk` is the initial commit — an ancestor of feature, so merging it
    // into feature is clean. The default ladder would have picked `main` and
    // reported a conflict, so a zero-file result proves the override is
    // actually used rather than the ladder quietly substituting something else.
    try git(path, &.{ "branch", "trunk" });
    try git(path, &.{ "checkout", "-q", "-b", "feature" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared.txt", .data = "a\nFEATURE\nc\n" });
    try git(path, &.{ "add", "-A" });
    try git(path, &.{ "commit", "-qm", "feat" });
    try git(path, &.{ "checkout", "-q", "main" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared.txt", .data = "a\nMAIN\nc\n" });
    try git(path, &.{ "commit", "-qam", "mainchange" });
    try git(path, &.{ "checkout", "-q", "feature" });

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);

    const overridden = try useCase(allocator, testing.io, path, "trunk", null, &detail);
    defer deinitResult(allocator, overridden);
    try testing.expectEqual(@as(usize, 0), overridden.count);
    try testing.expectEqualStrings("trunk", overridden.base_ref);

    // Same repo, default ladder → the conflict the override skipped.
    const dflt = try useCase(allocator, testing.io, path, null, null, &detail);
    defer deinitResult(allocator, dflt);
    try testing.expectEqual(@as(usize, 1), dflt.count);
    try testing.expectEqualStrings("shared.txt", dflt.conflicting_files[0]);
}

test "useCase reports NotARepository for a directory that is not a work tree" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp, allocator);
    defer allocator.free(path);

    // `testing.tmpDir` lives under `.zig-cache/tmp/`, i.e. INSIDE this repo,
    // so `git rev-parse --git-dir` would happily walk up and succeed — the
    // first draft of this test passed for the wrong reason and then failed.
    // A `.git` FILE pointing at a missing gitdir makes the directory exist and
    // still be a non-repository, which is the case the handler maps to 404.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".git",
        .data = "gitdir: /nalar-test-missing-gitdir",
    });

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);
    try testing.expectError(
        error.NotARepository,
        useCase(allocator, testing.io, path, null, null, &detail),
    );
}

test "useCase reports NotARepository for a path that does not exist" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp, allocator);
    defer allocator.free(path);

    var missing_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const missing = std.fmt.bufPrint(&missing_buf, "{s}/definitely-not-here", .{path}) catch unreachable;

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);
    try testing.expectError(
        error.NotARepository,
        useCase(allocator, testing.io, missing, null, null, &detail),
    );
}

test "useCase reports BaseRefNotFound when the requested base does not exist" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp, allocator);
    defer allocator.free(path);
    try makeRepo(&tmp, path);

    var detail: ?[]u8 = null;
    defer if (detail) |d| allocator.free(d);
    try testing.expectError(
        error.BaseRefNotFound,
        useCase(allocator, testing.io, path, "no-such-branch", null, &detail),
    );
}
