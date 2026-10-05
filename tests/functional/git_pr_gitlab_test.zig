// Functional wire tests for GitLab support on the git PR/MR endpoints.
//
// Zig port of `tests/functional/git_pr_gitlab_test.py` (same test names,
// same order).
//
// Python docstring, preserved verbatim:
//
//   """Functional wire tests for GitLab support on the git PR/MR endpoints.
//
//   The Zig unit tests drive `runView` / `createPullRequestUseCaseWith` against
//   fixture scripts, which proves the argv and the JSON parsing. They cannot see
//   three things that only exist on the wire, and all three were GitHub-only in a
//   way a GitLab user hits immediately:
//
//     1. `GET /api/git/pr/status?provider=gitlab` was a hard 400 ("only the github
//        provider is supported for PR status in v1").
//     2. `GitPrStatusResponse` had no `provider` field, so the frontend could not
//        tell a merge request from a pull request and labelled it "PR".
//     3. `POST /api/git/pr` took no `provider`, so it always ran `gh pr create`.
//
//   That third one was a bug this file found and the unit tests structurally
//   could not: `createPullRequestUseCase` passed the `gh` program for EVERY
//   provider, so `provider: "gitlab"` spawned `gh mr create` and gh replied
//   `unknown command "mr"`. Only running the real handler surfaces it.
//
//   ## Why the fake CLIs are installed by an autouse fixture
//
//   The harness snapshots `os.environ` when it boots the server, and pytest
//   instantiates the function-scoped `harness` fixture BEFORE the fixtures a test
//   lists as arguments. Setting PATH inside a per-test fixture therefore lands too
//   late — the server has already captured the old PATH, silently runs whatever
//   real `gh` the host has (possibly making authenticated network calls), and
//   reports "glab CLI not found".
//
//   An `autouse` fixture is instantiated before explicitly-requested fixtures of
//   the same scope, so this one always wins the race. Each fake reads its stdout
//   from a sibling `.payload` file, which lets a test choose the CLI's output
//   after the server is already up.
//   """
//
// THE AUTOUSE FIXTURE BECOMES AN EXPLICIT STEP IN EVERY TEST. Zig has no
// fixture ordering, so the ordering guarantee the Python docstring
// describes has to be written down in the sequence instead: every test
// builds the fakes, writes its payload, installs the PATH shadow, and only
// THEN boots. `PathShadow` below is the same trick as
// `git_pr_status_test.zig`'s — a scratch bindir prepended to
// `std.testing.environ`, which is the exact block `Harness.boot` copies
// into the child env.
//
// The `pabrik-fake-forge-` prefix the Python `mkdtemp` used becomes
// `harness.makeScratchDir`'s `pabrik-fix-`: same "outside the harness's
// tempdir namespace" requirement, and the only prefix `isSafeTmp` accepts
// for a suite-owned directory without `reapOrphanTestPids` claiming it.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Payloads
// ============================================================================

/// `json.dumps(..., separators=(",", ":"))` of the open merge request.
///
/// `changes_count` is a numeric STRING on the wire — that is GitLab's REST
/// API shape and the coercion to an integer is part of what this pins.
const OPEN_MR_JSON =
    \\{"id":11463,"iid":7,"title":"Add GitLab support","description":"body","state":"opened","created_at":"2026-09-28T10:00:00.000Z","updated_at":"2026-09-29T11:30:00.000Z","merged_at":null,"closed_at":null,"author":{"id":42,"name":"Ginwa","username":"ginwa123"},"source_branch":"worktree/gitlab-support","target_branch":"main","web_url":"https://gitlab.com/group/sub/repo/-/merge_requests/7","merge_status":"can_be_merged","detailed_merge_status":"mergeable","changes_count":"4"}
;

const OPEN_PR_JSON =
    \\{"number":42,"title":"Add GitLab support","url":"https://github.com/acme/app/pull/42","state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"worktree/gitlab-support","baseRefName":"main","author":{"login":"ginwa123"},"additions":10,"deletions":2,"changedFiles":3}
;

const MR_URL = "https://gitlab.com/group/sub/repo/-/merge_requests/7";
const PR_URL = "https://github.com/acme/app/pull/42";

// ============================================================================
// Fixtures
// ============================================================================

/// The suite's own scratch directory (the git repo + the fake bin),
/// outside the harness's tempdir namespace.
const Scratch = struct {
    root: []u8,

    fn init() !Scratch {
        return .{ .root = try harness.makeScratchDir(gpa) };
    }

    /// LIFO note: `cleanupExtraDir` READS `root`, so the free is
    /// registered first — a defer that freed the slice before the
    /// cleaner read it is a use-after-free that happens to read as a
    /// plausible path.
    fn deinit(self: *Scratch) void {
        harness.cleanupExtraDir(io, gpa, self.root);
        gpa.free(self.root);
    }

    fn path(self: *Scratch, parts: []const []const u8) ![]u8 {
        return harness.harnessPath(gpa, self.root, parts);
    }
};

/// The fake CLI body: prints whatever the test wrote into
/// `<bindir>/<name>.payload`, so the same installed binary serves every
/// test's payload. `$0`-relative, so it needs no env cooperation with
/// the already-booted server.
///
/// `name` is substituted by `FakeForge.init`, which writes one script per
/// CLI — the Python did this with `_FAKE_CLI.format(name=name)`.
fn fakeCliScript(name: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        \\#!/bin/sh
        \\d=$(dirname "$0")
        \\if [ -f "$d/{s}.payload" ]; then cat "$d/{s}.payload"; fi
        \\
    ,
        .{ name, name },
    );
}

/// Write an executable `/bin/sh` script at `path`.
fn writeExecScript(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
    // The portable spelling of Python's `chmod(st_mode | stat.S_IEXEC |
    // stat.S_IXGRP | stat.S_IXOTH)`, and it also makes the file READABLE,
    // which OR-ing the exec bit into a fresh file's mode does not
    // guarantee.
    try std.Io.Dir.cwd().setFilePermissions(io, path, .executable_file, .{});
}

/// The fake forge CLIs: a bindir holding an executable `gh` and `glab`,
/// installed on PATH BEFORE the harness boots.
///
/// This is the Python `fake_forge_clis` autouse fixture, made explicit.
const FakeForge = struct {
    scratch: Scratch,
    bindir: []u8,

    /// Create the scratch dir, the bindir, and both fake CLIs. The
    /// caller still has to install the PATH shadow — this only builds
    /// the files.
    fn init() !FakeForge {
        var scratch = try Scratch.init();
        errdefer scratch.deinit();

        const bindir = try scratch.path(&.{"bin"});
        errdefer gpa.free(bindir);
        try std.Io.Dir.cwd().createDirPath(io, bindir);

        for ([_][]const u8{ "gh", "glab" }) |name| {
            const script = try fakeCliScript(name);
            defer gpa.free(script);
            const p = try std.fs.path.join(gpa, &.{ bindir, name });
            defer gpa.free(p);
            try writeExecScript(p, script);
        }

        return .{ .scratch = scratch, .bindir = bindir };
    }

    /// LIFO note: `bindir` and `scratch.root` are read by the cleaner
    /// and by the payload writers, so both frees are registered after
    /// it (i.e. run before it).
    fn deinit(self: *FakeForge) void {
        harness.cleanupExtraDir(io, gpa, self.scratch.root);
        gpa.free(self.bindir);
        gpa.free(self.scratch.root);
    }

    /// Python's `_write_payload`: choose what a fake CLI prints,
    /// possibly after the server is already up.
    ///
    /// `std.fs.path.SEP`, not `std.fs.path.delimiter` — the latter is
    /// the PATH-LIST separator (`:` on POSIX), so joining with it built
    /// `/tmp/pabrik-fix-abc:glab.payload`, the fake printed nothing, and
    /// every request failed downstream with "0 bytes stdout" from a
    /// cause three layers away from the mistake.
    fn writePayload(self: *FakeForge, name: []const u8, payload: []const u8) !void {
        const file = try std.fmt.allocPrint(gpa, "{s}{c}{s}.payload", .{
            self.bindir, std.fs.path.sep, name,
        });
        defer gpa.free(file);
        var f = try std.Io.Dir.cwd().createFile(io, file, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, payload);
    }

    /// Remove a fake CLI from the bindir. Used by the "missing glab"
    /// test, which Python performed by `unlink()`-ing both files after
    /// the harness had already booted.
    fn removeCli(self: *FakeForge, name: []const u8) !void {
        const p = try std.fs.path.join(gpa, &.{ self.bindir, name });
        defer gpa.free(p);
        try std.Io.Dir.cwd().deleteFile(io, p);
    }

    /// Build the fixture git repo. Python's `_make_repo(tmp_path, remote)`;
    /// `remote` may be null for the "no origin" case.
    fn makeRepo(self: *FakeForge, remote: ?[]const u8) ![]u8 {
        const cwd = try self.scratch.path(&.{"forge-proj"});
        errdefer gpa.free(cwd);
        try std.Io.Dir.cwd().createDirPath(io, cwd);

        try git(self.scratch.root, &.{ "init", "--initial-branch=main", "--quiet", cwd });
        if (remote) |r| {
            try git(cwd, &.{ "remote", "add", "origin", r });
        }

        {
            const p = try std.fs.path.join(gpa, &.{ cwd, "a.txt" });
            defer gpa.free(p);
            var f = try std.Io.Dir.cwd().createFile(io, p, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, "hi\n");
        }
        try git(cwd, &.{ "add", "-A" });
        try git(cwd, &.{ "commit", "--quiet", "-m", "base" });

        return cwd;
    }
};

/// Python's `_git`: `git` in `cwd` with the fixture identity baked in.
///
/// `-c commit.gpgsign=false` is an addition, not a port artifact: it
/// stops a developer's global signing config from failing the commit on a
/// box that has one. It is the `git -c` spelling of the
/// `GIT_AUTHOR_*` / `GIT_COMMITTER_*` env the Python passed.
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

/// Prepend `prefix` to `PATH` in `std.testing.environ` — the exact block
/// `Harness.boot` copies into the child env.
///
/// Scoped by `restore`: the shadow must not outlive the test, or every
/// later suite in the same process would spawn the fake `gh`/`glab`.
const PathShadow = struct {
    gpa: std.mem.Allocator,
    saved: std.process.Environ,
    entries: [:null]const ?[*:0]const u8,

    fn install(alloc: std.mem.Allocator, prefix: []const u8) !PathShadow {
        // `Environ`'s block is a raw `KEY=VALUE` slice on POSIX. On
        // Windows it is a PEB pointer read through `GlobalBlock`, which
        // Zig offers no way to shadow — and the fake CLIs are `/bin/sh`
        // scripts anyway, so this suite is POSIX-only.
        if (comptime @import("builtin").os.tag != .windows) {
            const saved = std.testing.environ;
            const orig = saved.block.slice;

            const entries = try alloc.allocSentinel(?[*:0]const u8, orig.len, null);
            errdefer alloc.free(entries);

            var owned: std.ArrayList([:0]u8) = .empty;
            defer owned.deinit(alloc);
            errdefer for (owned.items) |o| alloc.free(o);

            for (orig, 0..) |maybe, i| {
                const s = std.mem.span(maybe.?);
                if (std.mem.startsWith(u8, s, "PATH=")) {
                    try owned.append(alloc, try std.fmt.allocPrintSentinel(alloc, "PATH={s}{c}{s}", .{
                        prefix,
                        std.fs.path.delimiter,
                        s["PATH=".len..],
                    }, 0));
                } else {
                    try owned.append(alloc, try alloc.dupeZ(u8, s));
                }
                entries[i] = owned.items[owned.items.len - 1].ptr;
            }

            std.testing.environ = .{ .block = .{ .slice = entries } };
            return .{ .gpa = alloc, .saved = saved, .entries = entries };
        } else {
            return error.SkipZigTest;
        }
    }

    fn restore(self: PathShadow) void {
        std.testing.environ = self.saved;
        for (self.entries) |e| self.gpa.free(std.mem.span(e.?));
        self.gpa.free(self.entries);
    }
};

/// Is a `glab` binary resolvable on the AMBIENT PATH (i.e. one this
/// suite did not install)?
///
/// Probed with `std.process.run`, which inherits the real process
/// environment — NOT the `std.testing.environ` shadow — so the answer is
/// "would the server's `execLookPath` find a REAL glab if the fakes were
/// removed". See the call site for why that decides whether an assertion
/// is meaningful at all.
fn hasRealGlab() bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "command -v glab >/dev/null 2>&1" },
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

// ============================================================================
// Assertion helpers
// ============================================================================

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

fn expectEqualInt(doc: *const harness.Json, key: []const u8, want: i64) !void {
    const got = doc.int(key) orelse {
        std.debug.print("response has no integer `{s}`\n", .{key});
        return error.TestUnexpectedResult;
    };
    if (got != want) {
        std.debug.print("`{s}` = {d}, expected {d}\n", .{ key, got, want });
        return error.TestUnexpectedResult;
    }
}

/// The POST /api/git/pr body, built from the fixture repo path.
fn createPrBody(repo: []const u8, title: []const u8, body: []const u8, provider: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"worktree_path\":\"{s}\",\"base\":\"main\",\"title\":\"{s}\",\"body\":\"{s}\",\"provider\":\"{s}\"}}",
        .{ repo, title, body, provider },
    );
}

// ============================================================================
// GET /api/git/pr/status
// ============================================================================

// THE regression: provider=gitlab used to be a hard 400.
test "gitlab_provider_is_no_longer_rejected" {
    try harness.requirePabrikBin(io, gpa);

    var ff = try FakeForge.init();
    defer ff.deinit();
    const repo = try ff.makeRepo("git@gitlab.com:group/sub/repo.git");
    defer gpa.free(repo);
    try ff.writePayload("glab", OPEN_MR_JSON);

    var shadow = try PathShadow.install(gpa, ff.bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "provider", .value = "gitlab" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualStr(&doc, "provider", "gitlab");
    try expectEqualInt(&doc, "number", 7); // iid, not id=11463
    try expectEqualStr(&doc, "status", "open"); // gitlab "opened" normalizes
    try expectEqualStr(&doc, "state", "opened"); // raw forge state passes through
    try expectEqualStr(&doc, "pr_url", MR_URL); // web_url -> pr_url
    try expectEqualStr(&doc, "head_ref", "worktree/gitlab-support");
    try expectEqualStr(&doc, "base_ref", "main");
    try expectEqualStr(&doc, "author", "ginwa123");
    try expectEqualStr(&doc, "mergeable", "mergeable");
    try expectEqualStr(&doc, "merged_at", ""); // JSON null -> empty string
    try expectEqualInt(&doc, "changed_files", 4); // string counter coerces
}

// The frontend passes the MR URL; detection must pick glab.
test "a_gitlab_mr_url_routes_to_glab_with_no_provider_param" {
    try harness.requirePabrikBin(io, gpa);

    var ff = try FakeForge.init();
    defer ff.deinit();
    const repo = try ff.makeRepo("git@gitlab.com:group/sub/repo.git");
    defer gpa.free(repo);
    try ff.writePayload("glab", OPEN_MR_JSON);

    var shadow = try PathShadow.install(gpa, ff.bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr", .value = MR_URL },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualStr(&doc, "provider", "gitlab");
    try expectEqualStr(&doc, "title", "Add GitLab support");
}

// The board-badge path calls this with only `path` + a branch name.
test "the_origin_remote_selects_glab_with_no_params_at_all" {
    try harness.requirePabrikBin(io, gpa);

    var ff = try FakeForge.init();
    defer ff.deinit();
    // scp-style remote: the shape a real GitLab clone has.
    const repo = try ff.makeRepo("git@gitlab.com:group/sub/repo.git");
    defer gpa.free(repo);
    try ff.writePayload("glab", OPEN_MR_JSON);

    var shadow = try PathShadow.install(gpa, ff.bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "pr", .value = "worktree/gitlab-support" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualStr(&doc, "provider", "gitlab");
}

// GitLab support must not regress GitHub.
test "github_status_still_reports_provider_github" {
    try harness.requirePabrikBin(io, gpa);

    var ff = try FakeForge.init();
    defer ff.deinit();
    const repo = try ff.makeRepo("git@github.com:acme/app.git");
    defer gpa.free(repo);
    try ff.writePayload("gh", OPEN_PR_JSON);

    var shadow = try PathShadow.install(gpa, ff.bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "provider", .value = "github" },
        },
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    try expectEqualStr(&doc, "provider", "github");
    try expectEqualStr(&doc, "status", "open");
    try expectEqualInt(&doc, "number", 42);
    try expectEqualStr(&doc, "pr_url", PR_URL);
}

// `generic` has no forge CLI, so status cannot answer — and must say so.
test "generic_provider_is_rejected_with_a_reason" {
    try harness.requirePabrikBin(io, gpa);

    var ff = try FakeForge.init();
    defer ff.deinit();
    const repo = try ff.makeRepo(null);
    defer gpa.free(repo);

    var shadow = try PathShadow.install(gpa, ff.bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "provider", .value = "generic" },
        },
        .expect = &.{502},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const message = doc.str("error") orelse {
        std.debug.print("502 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, message, "forge CLI") == null) {
        std.debug.print("502 error does not say `forge CLI`: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

// A GitLab user with no glab must not be told to install gh.
//
// HOST-DEPENDENT, AND THE PYTHON ORIGINAL IS TOO. The test removes both
// fakes from the bindir, but the bindir is only the FIRST entry on PATH —
// the server's `execLookPath` keeps scanning the rest of the inherited
// PATH. On a machine with a real `glab` installed downstream, the CLI is
// found and RUNS, so the handler takes the `FetchFailed` arm and answers
// 502 instead of 422; the Python fails here with exactly that body.
//
// Following the precedent set by `gitlab_provider_is_not_rejected_up_front`
// in `git_pr_status_test.zig`, this port SKIPS with a printed reason when
// a real `glab` is on PATH rather than widening the assertion to accept
// whichever message comes back. Widening would change the contract this
// test exists to pin — "name the CLI the user is actually missing" — to
// accommodate one developer's machine.
test "a_missing_glab_is_reported_as_glab_not_gh" {
    try harness.requirePabrikBin(io, gpa);

    if (hasRealGlab()) {
        std.debug.print(
            "skipping: a real `glab` is installed downstream of the fake bindir, so " ++
                "removing the fakes would not make the CLI missing (the server would " ++
                "run it and answer 502, not 422)\n",
            .{},
        );
        return error.SkipZigTest;
    }

    var ff = try FakeForge.init();
    defer ff.deinit();
    const repo = try ff.makeRepo("git@gitlab.com:group/sub/repo.git");
    defer gpa.free(repo);

    var shadow = try PathShadow.install(gpa, ff.bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Remove the fake glab for this test only, keeping gh on PATH —
    // the Python removed BOTH; see the note below.
    try ff.removeCli("gh");
    try ff.removeCli("glab");

    var r = try h.http(io, .GET, "/api/git/pr/status", .{
        .params = &.{
            .{ .name = "path", .value = repo },
            .{ .name = "provider", .value = "gitlab" },
        },
        .expect = &.{422},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const message = doc.str("error") orelse {
        std.debug.print("422 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, message, "glab") == null) {
        std.debug.print("422 error does not name glab: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, message, "gh CLI") != null) {
        std.debug.print("422 error blames gh instead of glab: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// POST /api/git/pr
// ============================================================================

// POST /api/git/pr must honour `provider` and echo it back.
//
// This is the test that caught the real bug: with `gh` hardcoded as the
// program for every provider, this returned
// `unknown command "mr" for "gh"`.
test "create_accepts_a_provider_and_returns_it" {
    try harness.requirePabrikBin(io, gpa);

    var ff = try FakeForge.init();
    defer ff.deinit();
    const repo = try ff.makeRepo("git@gitlab.com:group/sub/repo.git");
    defer gpa.free(repo);

    // glab prints a banner before the link, exactly like the real CLI.
    try ff.writePayload("glab", "Creating merge request for worktree/gitlab-support on gitlab.com\n\n" ++ MR_URL ++ "\n");

    var shadow = try PathShadow.install(gpa, ff.bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try createPrBody(repo, "Add GitLab support", "body", "gitlab");
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/pr", .{
        .json_body = body,
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    // Python: `assert r["success"] is True`. An absent key is a
    // failure, so `.boolean(...) orelse` rather than a default.
    if (doc.boolean("success") != true) {
        std.debug.print("create did not report success: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    try expectEqualStr(&doc, "provider", "gitlab");
    // The banner must not leak into pr_url, or the frontend hands a
    // non-URL to set_pull_request, which rejects it as unparseable.
    try expectEqualStr(&doc, "pr_url", MR_URL);
}

test "create_rejects_an_unknown_provider" {
    try harness.requirePabrikBin(io, gpa);

    var ff = try FakeForge.init();
    defer ff.deinit();
    const repo = try ff.makeRepo(null);
    defer gpa.free(repo);

    var shadow = try PathShadow.install(gpa, ff.bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try createPrBody(repo, "T", "", "bitbucket");
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/pr", .{
        .json_body = body,
        .expect = &.{400},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const message = doc.str("error") orelse {
        std.debug.print("400 body carries no `error` field: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, message, "provider") == null) {
        std.debug.print("400 error does not name `provider`: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

// The pre-existing GitHub create path must not regress.
test "github_create_is_unchanged" {
    try harness.requirePabrikBin(io, gpa);

    var ff = try FakeForge.init();
    defer ff.deinit();
    const repo = try ff.makeRepo("git@github.com:acme/app.git");
    defer gpa.free(repo);
    try ff.writePayload("gh", PR_URL ++ "\n");

    var shadow = try PathShadow.install(gpa, ff.bindir);
    defer shadow.restore();

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    const body = try createPrBody(repo, "T", "B", "github");
    defer gpa.free(body);

    var r = try h.http(io, .POST, "/api/git/pr", .{
        .json_body = body,
        .expect = &.{200},
        .timeout_s = 15.0,
    });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    if (doc.boolean("success") != true) {
        std.debug.print("create did not report success: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
    try expectEqualStr(&doc, "provider", "github");
    try expectEqualStr(&doc, "pr_url", PR_URL);
}

// Body-analysis barrier. An unreferenced helper is never type-checked, so
// a stdlib rename inside one stays invisible until a caller appears.
comptime {
    _ = OPEN_MR_JSON;
    _ = OPEN_PR_JSON;
    _ = MR_URL;
    _ = PR_URL;
    _ = Scratch.init;
    _ = Scratch.deinit;
    _ = Scratch.path;
    _ = fakeCliScript;
    _ = writeExecScript;
    _ = FakeForge.init;
    _ = FakeForge.deinit;
    _ = FakeForge.writePayload;
    _ = FakeForge.removeCli;
    _ = FakeForge.makeRepo;
    _ = git;
    _ = PathShadow.install;
    _ = PathShadow.restore;
    _ = hasRealGlab;
    _ = expectEqualStr;
    _ = expectEqualInt;
    _ = createPrBody;
}
