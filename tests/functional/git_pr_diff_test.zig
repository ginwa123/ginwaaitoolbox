// Functional wire tests for GET /api/git/pr/diff (generic provider).
//
// Zig port of `tests/functional/git_pr_diff_test.py` (same test names,
// same order).
//
// Python docstring, preserved verbatim:
//
//   """Functional wire tests for GET /api/git/pr/diff (generic provider).
//
//   Exercises the endpoint the ChatView right panel will call in PR mode,
//   using pure-git base...head diffs on a fixture repo (no network, no
//   forge CLI):
//
//     1. Generic diff between main and a feature branch returns hunks.
//     2. Unknown head ref -> clean 502 JSON (not a crash).
//     3. Missing pr_url -> 400.
//
//   Plus the GitHub-provider path against a fixture whose `origin` publishes
//   `refs/pull/1/head`: when the forge CLI cannot answer, the handler must fall
//   back to that ref instead of returning 502.
//   """
//
// WHERE THE FIXTURE LIVES: `harness.makeScratchDir`, never
// `std.testing.tmpDir` and never the harness's own tempdir. The
// `pabrik-func-` namespace is what `reapOrphanTestPids` deletes on every
// boot, and `<cwd>/.zig-cache/tmp/` is INSIDE the git worktree — where
// `git symbolic-ref` walks UP and the fixture repo resolves to the
// worktree's branch. See `git_pr_status_test.zig` for the long form.
//
// NO FAKE CLI IS INSTALLED HERE, AND THAT IS THE POINT for the GitHub
// tests. The harness gives the child an isolated HOME, so a real `gh` on
// the box is unauthenticated and exits nonzero for ANY pr_url — the same
// failure mode as the 406 ("CLI present, cannot answer"), so those tests
// exercise the refspec fallback rather than the happy CLI path. They stay
// meaningful when `gh` is not installed at all: the refspec path is then
// the primary strategy. See the long note in the Python original, carried
// forward here.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

/// The PR under test for the generic-provider cases. Never fetched — the
/// computation is purely local; the URL only proves it round-trips
/// through the query string.
const PR_URL = "https://git.example.com/o/r/pull/1";

/// The GitHub-provider URL for the refspec-fallback cases. The number
/// after `/pull/` is what the handler turns into `refs/pabrik-pr/<n>`.
const GH_PR_URL = "https://github.com/acme/widgets/pull/1";

// ============================================================================
// Fixtures
// ============================================================================

/// The suite's own scratch directory, outside the harness's tempdir
/// namespace.
const Scratch = struct {
    root: []u8,

    fn init() !Scratch {
        return .{ .root = try harness.makeScratchDir(gpa) };
    }

    /// LIFO note: `cleanupExtraDir` READS `root`, so the free is
    /// registered first.
    fn deinit(self: *Scratch) void {
        harness.cleanupExtraDir(io, gpa, self.root);
        gpa.free(self.root);
    }

    fn path(self: *Scratch, parts: []const []const u8) ![]u8 {
        return harness.harnessPath(gpa, self.root, parts);
    }
};

/// Python's `_git`: `git` in `cwd` with the fixture identity baked in,
/// so the fixture never depends on the machine's global git config.
///
/// `-c commit.gpgsign=false` is an addition, not a port artifact: it
/// stops a developer's global signing config from failing the commit on
/// a box that has one.
fn git(cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "git",                  "-c",          "user.email=t@t",
        "-c",                   "user.name=t", "-c",
        "commit.gpgsign=false",
    });
    try argv.appendSlice(gpa, args);

    var child = try std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = cwd } });
    const term = child.wait(io) catch |err| {
        std.debug.print("git {s} did not wait: {s}\n", .{ args[0], @errorName(err) });
        return error.SkipZigTest;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} exited {d}\n", .{ args[0], code });
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("git {s} died by signal\n", .{args[0]});
            return error.TestUnexpectedResult;
        },
    }
}

fn writeFileAt(dir: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Python's `pr_cwd` fixture: a two-branch repo where `feature` rewrites
/// one line of `base.txt` and adds `added.txt`.
fn buildPrRepo(s: *Scratch) ![]u8 {
    const cwd = try s.path(&.{"pr-diff-proj"});
    errdefer gpa.free(cwd);

    try std.Io.Dir.cwd().createDirPath(io, cwd);
    try git(s.root, &.{ "init", "--initial-branch=main", "--quiet", cwd });

    var dir = try std.Io.Dir.cwd().openDir(io, cwd, .{});
    defer dir.close(io);

    try writeFileAt(dir, "base.txt", "keep\nold\n");
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "base" });
    try git(cwd, &.{ "checkout", "--quiet", "-b", "feature" });
    try writeFileAt(dir, "base.txt", "keep\nnew\n");
    try writeFileAt(dir, "added.txt", "hello\n");
    try git(cwd, &.{ "add", "-A" });
    try git(cwd, &.{ "commit", "--quiet", "-m", "feature work" });

    return cwd;
}

/// Python's `_build_forge_repo`: a clone whose `origin` publishes
/// `refs/pull/1/head`, like GitHub does.
///
/// `pr_files` / `lines_per_file` inflate the PR diff past the 1MB
/// response cap so the oversized-PR path is covered without a network or
/// a real PR. Returns the owned clone path.
fn buildForgeRepo(s: *Scratch, dir_name: []const u8, pr_files: usize, lines_per_file: usize) ![]u8 {
    // `defer`, not `errdefer`: `root` is NOT the return value (only
    // `work` is), so it has to be freed on the success path too.
    const root = try s.path(&.{dir_name});
    defer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    const origin = try std.fs.path.join(gpa, &.{ root, "origin.git" });
    defer gpa.free(origin);
    const seed = try std.fs.path.join(gpa, &.{ root, "seed" });
    defer gpa.free(seed);
    // NO `defer gpa.free(work)`: this slice IS the return value, and a
    // defer frees it before the caller ever reads it. That is not a leak
    // report, it is a USE-AFTER-FREE — the handler received a pointer to
    // recycled memory, `openat` failed, and the endpoint answered 404
    // "not a git repository" for a repo that plainly existed.
    const work = try std.fs.path.join(gpa, &.{ root, "work" });

    try git(root, &.{ "init", "--quiet", "--bare", origin });
    try git(root, &.{ "init", "--quiet", "--initial-branch=main", seed });

    {
        var dir = try std.Io.Dir.cwd().openDir(io, seed, .{});
        defer dir.close(io);
        try writeFileAt(dir, "base.txt", "keep\nold\n");
    }
    try git(seed, &.{ "add", "-A" });
    try git(seed, &.{ "commit", "--quiet", "-m", "base" });
    try git(seed, &.{ "checkout", "--quiet", "-b", "feature" });

    {
        var dir = try std.Io.Dir.cwd().openDir(io, seed, .{});
        defer dir.close(io);

        try writeFileAt(dir, "base.txt", "keep\nnew\n");
        try writeFileAt(dir, "added.txt", "hello\n");

        if (pr_files > 0) {
            // `"payload line with some length to it\n" * lines_per_file`.
            const line = "payload line with some length to it\n";
            var filler: std.Io.Writer.Allocating = .init(gpa);
            defer filler.deinit();
            for (0..lines_per_file) |_| try filler.writer.writeAll(line);
            const payload = filler.written();

            for (0..pr_files) |i| {
                const name = try std.fmt.allocPrint(gpa, "bulk_{d:0>4}.txt", .{i});
                defer gpa.free(name);
                try writeFileAt(dir, name, payload);
            }
        }
    }
    try git(seed, &.{ "add", "-A" });
    try git(seed, &.{ "commit", "--quiet", "-m", "feature work" });
    try git(seed, &.{ "remote", "add", "origin", origin });
    try git(seed, &.{ "push", "--quiet", "origin", "main", "feature" });
    // GitHub's well-known PR ref — the thing `fetchRefRange` asks origin for.
    try git(seed, &.{ "push", "--quiet", "origin", "feature:refs/pull/1/head" });

    // `-b main`: the handler diffs `main...refs/pabrik-pr/1`, so the clone
    // must carry a LOCAL main. Cloning the default branch (feature) would
    // leave the range unresolvable.
    try git(root, &.{ "clone", "--quiet", "-b", "main", origin, work });

    return work;
}

/// Assert `hay` CONTAINS `needle`, naming both on failure.
fn expectContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("expected to find \"{s}\" in the diff:\n{s}\n", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

/// The decoded `diff_content` field, or a named failure.
fn diffContent(doc: *const harness.Json, body: []const u8) ![]const u8 {
    return doc.str("diff_content") orelse {
        std.debug.print("response carries no `diff_content`: {s}\n", .{body});
        return error.TestUnexpectedResult;
    };
}

fn expectEqualStr(doc: *const harness.Json, key: []const u8, want: []const u8) !void {
    const got = doc.str(key) orelse {
        std.debug.print("response has no string `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("`{s}` = \"{s}\", expected \"{s}\"\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

fn expectEqualBool(doc: *const harness.Json, key: []const u8, want: bool) !void {
    const got = doc.boolean(key) orelse {
        std.debug.print("response has no boolean `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (got != want) {
        std.debug.print("`{s}` = {}, expected {}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// Tests
// ============================================================================

// 1. base...head diff surfaces both the modified and the new file.
test "generic_pr_diff_returns_hunks" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const pr_cwd = try buildPrRepo(&s);
    defer gpa.free(pr_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = pr_cwd },
            .{ .name = "pr_url", .value = PR_URL },
            .{ .name = "provider", .value = "generic" },
            .{ .name = "base", .value = "main" },
            .{ .name = "head", .value = "feature" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualBool(&doc, "truncated", false);
    try expectEqualStr(&doc, "base", "main");
    try expectEqualStr(&doc, "head", "feature");

    const diff = try diffContent(&doc, r.body);
    try expectContains(diff, "diff --git a/base.txt b/base.txt");
    try expectContains(diff, "-old");
    try expectContains(diff, "+new");
    try expectContains(diff, "diff --git a/added.txt b/added.txt");
}

// 2. Unknown head ref → clean 502 JSON (covers the DiffFailed wire mode).
test "generic_pr_diff_unknown_head_is_clean_502" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const pr_cwd = try buildPrRepo(&s);
    defer gpa.free(pr_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = pr_cwd },
            .{ .name = "pr_url", .value = PR_URL },
            .{ .name = "provider", .value = "generic" },
            .{ .name = "base", .value = "main" },
            .{ .name = "head", .value = "no-such-branch" },
        },
        .expect = &.{502},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("502 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 3. Missing pr_url → 400 (covers the validator wire mode).
test "pr_diff_missing_pr_url_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const pr_cwd = try buildPrRepo(&s);
    defer gpa.free(pr_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = pr_cwd },
        },
        .expect = &.{400},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("400 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 4. Unknown provider → 400 (covers the strict-validator wire mode).
test "pr_diff_unknown_provider_is_400" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const pr_cwd = try buildPrRepo(&s);
    defer gpa.free(pr_cwd);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = pr_cwd },
            .{ .name = "pr_url", .value = PR_URL },
            .{ .name = "provider", .value = "bitbucket" },
        },
        .expect = &.{400},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.get("error") == null) {
        std.debug.print("400 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}

// 5. `gh pr diff` unavailable/oversized → 200 from origin's pull ref.
//
// Before the fix this returned 502 "failed to fetch PR diff (check PR
// URL, provider, and auth)".
//
// The handler prefers `gh pr diff` whenever `gh` resolves on PATH, and
// used to map ANY nonzero exit to a 502. GitHub refuses to serve
// `/pulls/{n}` beyond `FORGE_MAX_DIFF_FILES` (300) files — a repo-wide
// rename PR (1285 files, PR #797) makes the installed CLI exit 1 with
// `too_large` and the whole PR panel went dead.
//
// This suite deliberately installs NO fake `gh`: see the header note.
test "github_pr_diff_falls_back_to_refspec_when_cli_cannot_answer" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    const work = try buildForgeRepo(&s, "forge", 0, 0);
    defer gpa.free(work);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = work },
            .{ .name = "pr_url", .value = GH_PR_URL },
            .{ .name = "provider", .value = "github" },
        },
        .expect = &.{200},
        .timeout_s = 30.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // Only the refspec path reports base/head — the CLI path leaves them "".
    try expectEqualStr(&doc, "head", "refs/pabrik-pr/1");
    try expectEqualStr(&doc, "base", "main");
    try expectEqualBool(&doc, "truncated", false);

    const diff = try diffContent(&doc, r.body);
    try expectContains(diff, "diff --git a/base.txt b/base.txt");
    try expectContains(diff, "-old");
    try expectContains(diff, "+new");
    try expectContains(diff, "diff --git a/added.txt b/added.txt");
}

// 6. A PR past the 1MB response cap truncates instead of erroring.
//
// PR #797's local diff is 3.5MB, so this is the exact shape the user
// hit: the forge cannot serve it, and the refspec fallback must still
// answer.
test "oversized_pr_returns_truncated_diff_not_502" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();
    // 60 files x 2000 lines of ~34 bytes ≈ 4.1MB of added content.
    const work = try buildForgeRepo(&s, "big", 60, 2000);
    defer gpa.free(work);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = work },
            .{ .name = "pr_url", .value = GH_PR_URL },
            .{ .name = "provider", .value = "github" },
        },
        .expect = &.{200},
        .timeout_s = 60.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualBool(&doc, "truncated", true);

    const diff = try diffContent(&doc, r.body);
    // `len(r["diff_content"].encode("utf-8")) <= 1024 * 1024`.
    if (diff.len > 1024 * 1024) {
        std.debug.print("diff_content is {d} bytes, past the 1MB cap\n", .{diff.len});
        return error.TestUnexpectedResult;
    }
    try expectEqualStr(&doc, "head", "refs/pabrik-pr/1");
    try expectContains(diff, "diff --git");
}

// 7. No usable pull ref anywhere → 502 naming both strategies.
test "github_pr_diff_502_when_both_strategies_fail" {
    try harness.requirePabrikBin(io, gpa);

    var s = try Scratch.init();
    defer s.deinit();

    const plain = try s.path(&.{"plain"});
    defer gpa.free(plain);
    try std.Io.Dir.cwd().createDirPath(io, plain);
    try git(s.root, &.{ "init", "--quiet", "--initial-branch=main", plain });
    {
        var dir = try std.Io.Dir.cwd().openDir(io, plain, .{});
        defer dir.close(io);
        try writeFileAt(dir, "a.txt", "x\n");
    }
    try git(plain, &.{ "add", "-A" });
    try git(plain, &.{ "commit", "--quiet", "-m", "base" });
    // `origin` does not exist at all, so the refspec fetch cannot succeed.

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/diff", .{
        .params = &.{
            .{ .name = "path", .value = plain },
            .{ .name = "pr_url", .value = GH_PR_URL },
            .{ .name = "provider", .value = "github" },
        },
        .expect = &.{502},
        .timeout_s = 30.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const message = doc.str("error") orelse {
        std.debug.print("502 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    // The message should name the fallback strategy.
    try expectContains(message, "origin");
}

comptime {
    // Body-analysis barrier: an unreferenced helper is never
    // type-checked, so a stdlib rename inside one is invisible until a
    // caller appears.
    _ = Scratch.init;
    _ = Scratch.deinit;
    _ = Scratch.path;
    _ = git;
    _ = writeFileAt;
    _ = buildPrRepo;
    _ = buildForgeRepo;
    _ = expectContains;
    _ = diffContent;
    _ = expectEqualStr;
    _ = expectEqualBool;
}
