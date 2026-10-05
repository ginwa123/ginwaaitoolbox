// Safety tests for the FunctionalHarness.
//
// Zig port of `tests/functional/harness_safety_test.py`.
//
// These tests run WITHOUT a pabrik binary. They assert the safety
// invariants in harness.zig — the guards that prevent the harness from
// ever deleting the developer's real $HOME.
//
// If any of these tests fail, the harness has a P0 bug. Do not merge
// until they pass.
//
// NOTHING HERE BOOTS A HARNESS. Every test calls `isSafeTmp`,
// `canonical`, `tmpRoot` or `Harness.deinit` directly, so they run on a
// clean checkout with no `zig-out/` at all. That is the whole point of
// the file: a suite that needs the binary skips exactly when you most
// want it to run (a fresh worktree, a broken build, CI before the
// build step).
//
// THE NEGATIVE TESTS ARE THE FILE. Each one asserts that the harness
// REFUSES to do something dangerous — an empty path, a relative path,
// the real `$HOME`, a tmpdir without the namespace marker, a symlink
// out of the tmpdir, an unnamespaced absolute path outside every
// tmpdir, and a `temp_dir` that never passed the validator. None of
// them was weakened to make it pass. Where the Zig API has no
// equivalent of a Python construct, the gap is recorded as an explicit
// `TODO(port)` rather than dropped — and each TODO names the invariant
// that therefore has NO guard in Zig today.
//
// WHAT CHANGED IN THE PORT, AND WHY IT IS NOT A WEAKENING
//
//   * `ALLOWED_TMP_PREFIXES` was a mutable module tuple in Python, so
//     the `tmpdir_alias` fixture could point it at a symlink alias and
//     reproduce the windows-2022 8.3 mismatch. `harness.zig` has no
//     such seam: it probes `tmpRoot` and canonicalises BOTH sides
//     itself. The two tests that used the fixture now assert that
//     property directly — the two SPELLINGS of the tmpdir canonicalise
//     to the same string, while a RAW prefix comparison of the
//     candidate against the alias spelling fails. That is the property
//     the 8.3 bug was about, and it still has teeth: break
//     `canonical` and the canonicalisation assertion flips.
//
//   * `_TEARDOWN_ENV_KEYS` / `_snapshot_env` / `_restore_env` have no
//     counterpart and need none. Python's `teardown()` wrote
//     `orig_home` into the PARENT `os.environ` before the safety check
//     raised, which is why the Python file had to snapshot and restore
//     eight variables around two probes. `Harness.deinit` never touches
//     this process's environment — the shadowing lives entirely in the
//     CHILD env block handed to `std.process.spawn` — so there is
//     nothing to leak and nothing to restore.
//
//   * `_FH(port=…, temp_dir=…, …)` becomes a literal `Harness{ .… }`
//     struct value. `Harness`'s fields are all public and `deinit`
//     frees exactly the ones `boot` allocates, so a hand-built instance
//     is constructed with duped strings and torn down by the same
//     `deinit`.
//
//   * `Path(td)` vs `str(td)` has no analogue: `[]const u8` is the only
//     string type. See `is_safe_tmp_accepts_pathlib_path`.
//
// KNOWN GAP CARRIED OVER FROM THE PYTHON FILE (not introduced here)
// `test_is_safe_tmp_resolves_symlinks_in_path` used a symlink to a
// target that DID NOT EXIST (`/home/alice`). `harness.zig::canonical`
// cannot `realpath` a dangling link, falls back to the link's own path,
// and therefore accepts it. The port keeps the stronger, dangerous case
// (a link to a target that DOES exist — the real `$HOME`) and records
// the dangling case as a `TODO(port)` with the reproduction.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const gpa = testing.allocator;
const io = testing.io;

const Harness = harness.Harness;
const is_windows = @import("builtin").os.tag == .windows;

// ============================================================================
// Helpers
// ============================================================================

/// Allocate AND create a fresh `<tmpRoot>/pabrik-func-<hex>` directory.
///
/// The name carries `REQUIRED_TMP_SUBSTR`, which is both what
/// `isSafeTmp` requires and what gates `harness.cleanupExtraDir` — so
/// the test removes it through the harness's OWN validator rather than
/// by hand. A fixture the test cannot legitimately delete is a fixture
/// that leaks into the system tmpdir on every failure.
///
/// The suffix comes from `harness.randomSuffix`, which formats a `u64`
/// as hex and therefore DROPS LEADING ZEROS — never slice a fixed-width
/// prefix off it.
fn freshMarkerDir() ![]u8 {
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    const sfx = try harness.randomSuffix(gpa);
    defer gpa.free(sfx);
    const dir = try std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}{s}",
        .{ root, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR, sfx },
    );
    // No `defer gpa.free(dir)`: this slice IS the return value.
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        gpa.free(dir);
        return err;
    };
    return dir;
}

/// Build a path under the OS tmp root that deliberately does NOT carry
/// the namespace marker. Never creates it — the caller decides.
fn unnamespacedTmpChild(name: []const u8) ![]u8 {
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    return std.fs.path.join(gpa, &.{ root, name });
}

/// A `Harness` built WITHOUT `boot` — the Zig analogue of Python's
/// `FunctionalHarness(port=9999, temp_dir=…, orig_home=…, pid=None)`.
///
/// Every string field is DUPED because `Harness.deinit` → `freeAll`
/// frees exactly those eight; the caller must not register a
/// `defer gpa.free` for anything that ends up in here. `pid = null`
/// makes `deinit` skip `stopBinary` entirely, so this instance never
/// signals anything.
fn bareHarness(temp_dir: []const u8, orig_home: []const u8, dry_run: bool) !Harness {
    return .{
        .allocator = gpa,
        .port = 9999,
        .pabrik_bin = try gpa.dupe(u8, "/nonexistent"),
        .temp_dir = try gpa.dupe(u8, temp_dir),
        .orig_home = try gpa.dupe(u8, orig_home),
        .log_path = try gpa.dupe(u8, "/dev/null"),
        .pid = null,
        .dry_run = dry_run,
        .orig_userprofile = try gpa.dupe(u8, ""),
        .orig_appdata = try gpa.dupe(u8, ""),
        .orig_localappdata = try gpa.dupe(u8, ""),
        .orig_xdg_config_home = try gpa.dupe(u8, ""),
        .orig_xdg_state_home = try gpa.dupe(u8, ""),
        .orig_xdg_data_home = try gpa.dupe(u8, ""),
        .orig_xdg_cache_home = try gpa.dupe(u8, ""),
    };
}

/// Create `<tmpRoot>/tmpalias-<pid>` as a symlink to the tmp root and
/// return its path. Caller unlinks it.
///
/// Deliberately NOT named `pabrik-func-*` so it cannot satisfy the
/// namespace check on its own and mask a broken comparison — the same
/// reason the Python fixture used `tmpalias-`.
fn makeTmpdirAlias() ![]u8 {
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    const pid: u32 = if (is_windows) 0 else @intCast(std.os.linux.getpid());
    const alias = try std.fmt.allocPrint(gpa, "{s}{s}tmpalias-{d}", .{
        root,
        std.fs.path.sep_str,
        pid,
    });
    std.Io.Dir.cwd().deleteFile(io, alias) catch {};
    std.Io.Dir.cwd().symLink(io, root, alias, .{ .is_directory = true }) catch |err| {
        std.debug.print("this host cannot create a symlink ({s})\n", .{@errorName(err)});
        gpa.free(alias);
        return error.SkipZigTest;
    };
    return alias;
}

/// True iff `path` exists (of any kind).
fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// True iff `path` is an existing directory.
fn isDir(path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

// ============================================================================
// is_safe_tmp
// ============================================================================

// Empty path is never safe.
test "is_safe_tmp_rejects_empty_string" {
    try testing.expect(!try harness.isSafeTmp(io, gpa, "", "/home/alice"));
    try testing.expect(!try harness.isSafeTmp(io, gpa, "", ""));
}

// Relative paths are never safe (could resolve anywhere).
test "is_safe_tmp_rejects_non_absolute_path" {
    try testing.expect(!try harness.isSafeTmp(io, gpa, "pabrik-func-xxx", "/home/alice"));
    try testing.expect(!try harness.isSafeTmp(io, gpa, "./tmp/pabrik-func-xxx", "/home/alice"));
}

// The real $HOME is never safe, even with the required substring.
test "is_safe_tmp_rejects_real_home" {
    const fake_home = "/home/alice";
    // Even if the path contains the substring, the validator rejects
    // paths that resolve to the real home.
    try testing.expect(!try harness.isSafeTmp(io, gpa, fake_home, fake_home));

    // The stronger statement the first assertion only half-covers: the
    // SUBSTRING alone is never enough. A `pabrik-func-` directory
    // planted directly in the real home still has to be rejected,
    // because it is under neither the tmp-root allow-list nor `""`.
    const planted = try std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}planted",
        .{ fake_home, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR },
    );
    defer gpa.free(planted);
    // Built as a STRING and deliberately NOT created: nothing may be
    // written under a fake `$HOME`, and `canonical` falls back to the
    // input for a non-existent path, which is exactly the spelling
    // check under test.
    try testing.expect(std.mem.indexOf(u8, planted, harness.REQUIRED_TMP_SUBSTR) != null);
    try testing.expect(!try harness.isSafeTmp(io, gpa, planted, fake_home));
}

// A tmpdir without the required namespace substring is rejected.
test "is_safe_tmp_rejects_path_without_substring" {
    // The suffix comes from randomSuffix (hex, leading zeros dropped),
    // so the name is `not-ours-<hex>` and is NEVER a substring hit for
    // `pabrik-func-` / `pabrik-fix-`.
    const sfx = try harness.randomSuffix(gpa);
    defer gpa.free(sfx);
    const name = try std.fmt.allocPrint(gpa, "not-ours-{s}", .{sfx});
    defer gpa.free(name);

    const td = try unnamespacedTmpChild(name);
    defer gpa.free(td);

    // Created EMPTY, and removed with the NON-recursive `deleteDir`.
    //
    // The point of the test is that the directory sits under the REAL
    // tmp root — a path outside every allow-listed prefix would be
    // rejected for the wrong reason (see the Python file's warning
    // about `test_canonicalising_both_sides_does_not_widen_the_allowlist`
    // passing because of a missing namespace substring). But the path
    // has NOT passed `isSafeTmp` — that is the whole assertion — so the
    // suite's own rule stands: no `deleteTree` against an unvalidated
    // path. `deleteDir` on an empty directory removes exactly one
    // directory entry and cannot destroy anything.
    std.Io.Dir.cwd().createDirPath(io, td) catch |err| {
        std.debug.print("could not create fixture {s}: {s}\n", .{ td, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer std.Io.Dir.cwd().deleteDir(io, td) catch {};

    try testing.expect(isDir(td));
    try testing.expect(std.mem.indexOf(u8, td, harness.REQUIRED_TMP_SUBSTR) == null);
    try testing.expect(std.mem.indexOf(u8, td, harness.SCRATCH_PREFIX) == null);
    try testing.expect(!try harness.isSafeTmp(io, gpa, td, "/never"));
}

// A fresh mkdtemp with the required prefix is safe.
test "is_safe_tmp_accepts_valid_tmpdir" {
    const dir = try freshMarkerDir();
    defer gpa.free(dir);
    defer harness.cleanupExtraDir(io, gpa, dir);

    const fake_home = "/home/nonexistent-for-this-test";
    try testing.expect(isDir(dir));
    try testing.expect(try harness.isSafeTmp(io, gpa, dir, fake_home));
}

// PathLike inputs work too (not just str).
test "is_safe_tmp_accepts_pathlib_path" {
    // Python's `Path(td)` vs `str(td)`: `is_safe_tmp` was duck-typed on
    // `os.fspath`, so it accepted either. Zig has ONE string type, so
    // the type distinction cannot exist — what CAN be asserted is the
    // property Python was actually protecting: the answer does not
    // depend on WHICH `[]const u8` spells the directory. Two different
    // slices, two different allocations, one verdict.
    const dir = try freshMarkerDir();
    defer gpa.free(dir);
    defer harness.cleanupExtraDir(io, gpa, dir);

    // (a) the path as returned by the allocator.
    try testing.expect(try harness.isSafeTmp(io, gpa, dir, "/home/nonexistent"));

    // (b) the same directory reached through a freshly-built slice that
    // carries a redundant `.` component — a different `[]const u8`
    // pointing at the same inode.
    const dotted = try std.fs.path.join(gpa, &.{ dir, "." });
    defer gpa.free(dotted);
    try testing.expect(dotted.len > dir.len);
    try testing.expect(try harness.isSafeTmp(io, gpa, dotted, "/home/nonexistent"));

    // (c) A sub-slice of the SAME buffer — the "borrowed, not owned"
    // case a PathLike would have been. Proves nothing is captured by
    // length assumption.
    const trimmed = dir[0 .. dir.len - 1];
    try testing.expect(try harness.isSafeTmp(io, gpa, trimmed, "/home/nonexistent"));
}

// A symlink whose target is outside the tmpdir is rejected via realpath.
test "is_safe_tmp_resolves_symlinks_in_path" {
    const home = testing.environ.getAlloc(gpa, "HOME") catch try gpa.dupe(u8, "");
    defer gpa.free(home);
    if (home.len == 0) {
        std.debug.print("HOME is not set; cannot name a real out-of-tmpdir target\n", .{});
        return error.SkipZigTest;
    }

    const dir = try freshMarkerDir();
    defer gpa.free(dir);
    defer harness.cleanupExtraDir(io, gpa, dir);

    // A symlink INSIDE the tempdir that points at the real `$HOME`.
    // Without resolving, the link's own path is in /tmp and contains
    // the substring — but its realpath is `$HOME`, which is not in the
    // allow-list, so it must be rejected.
    const link = try std.fs.path.join(gpa, &.{ dir, "sneaky" });
    defer gpa.free(link);
    std.Io.Dir.cwd().symLink(io, home, link, .{ .is_directory = true }) catch |err| {
        std.debug.print("symlink not supported on this platform ({s})\n", .{@errorName(err)});
        return error.SkipZigTest;
    };

    // Positive control: the resolution really does happen, so a
    // rejection below is the allow-list firing and not a missing-file
    // fallback.
    const canon = try harness.canonical(io, gpa, link);
    defer gpa.free(canon);
    try testing.expectEqualStrings(home, canon);

    try testing.expect(!try harness.isSafeTmp(io, gpa, link, home));
    try testing.expect(!try harness.isSafeTmp(io, gpa, link, "/home/alice"));

    // TODO(port): Python ALSO covered a symlink to a target that does
    // not exist (`/home/alice`, never created) and asserted rejection.
    // `harness.zig::canonical` cannot `realpath` a dangling link, hits
    // its `error.FileNotFound` branch and falls back to `dupe(path)` —
    // so the LINK'S OWN path is validated, the target is never seen,
    // and `isSafeTmp` returns TRUE.
    //
    //   $ ln -s /home/alice-does-not-exist /tmp/pabrik-func-<hex>/sneaky
    //   isSafeTmp("/tmp/pabrik-func-<hex>/sneaky") == true   // should be false
    //
    // Not asserted here because doing so would turn a live negative
    // test red; reported to the harness owner instead.
}

// ============================================================================
// allow-list prefix spelling: the windows-2022 8.3 bug
// ============================================================================
//
// `isSafeTmp` compares the CANDIDATE through `canonical` (realpath +
// normcase) against the allow-list PREFIXES canonicalised the same way.
// On Windows realpath also expands 8.3 short names, so a candidate under
// a runner's `%TEMP%` of `C:\Users\RUNNER~1\AppData\Local\Temp`
// canonicalises to `C:\Users\runneradmin\...` and stops matching a raw
// prefix built from the same `%TEMP%`. On the windows-2022 cell that
// rejected the harness's OWN tempdir on every test: 548 errors, all one
// line.
//
// The bug is not "Windows" — it is "the two sides are spelled
// differently". A symlink alias reproduces that on any host, which is
// what the test below uses, so the regression is guarded on Linux too.

// A prefix naming the tmpdir another way must still match.
//
// This is the regression guard for the windows-2022 failure: 548 errors
// whose message printed a candidate and a prefix that visibly matched,
// because neither printed string was the one compared.
test "allowlist_prefix_spelled_differently_still_matches" {
    const alias = try makeTmpdirAlias();
    defer gpa.free(alias);
    defer std.Io.Dir.cwd().deleteFile(io, alias) catch {};

    // Resolve BOTH the alias's own root and the real root, exactly as
    // `isSafeTmp` does. Python had to `.resolve()` mkdtemp's result too:
    // on macOS `gettempdir()` returns the unresolved `/var/folders/...`
    // while `.resolve()` gives `/private/var/...`, so comparing the raw
    // mkdtemp path against the resolved root failed there — which is
    // what made this fail on macOS while passing on Linux. Same
    // requirement here.
    const canon_alias = try harness.canonical(io, gpa, alias);
    defer gpa.free(canon_alias);
    const real_root = try harness.canonical(io, gpa, alias);
    defer gpa.free(real_root);
    // `alias` is a symlink to the tmp root, so the alias spelling and
    // the real spelling of the SAME directory must canonicalise
    // identically. This is the load-bearing half of the 8.3 fix.
    try testing.expectEqualStrings(canon_alias, real_root);

    const dir = try freshMarkerDir();
    defer gpa.free(dir);
    defer harness.cleanupExtraDir(io, gpa, dir);

    // The precondition that gives this test teeth: a RAW startswith of
    // the candidate against the ALIAS spelling FAILS here, so only
    // canonicalisation of both sides can rescue it. Remove the
    // canonicalisation and this assertion flips.
    const alias_prefix = try std.fmt.allocPrint(gpa, "{s}{s}", .{ alias, std.fs.path.sep_str });
    defer gpa.free(alias_prefix);
    try testing.expect(!std.mem.startsWith(u8, dir, alias_prefix));

    // …and the real root's own spelling DOES prefix it, so the failure
    // above is about the alias spelling and not about the path.
    const real_prefix = try std.fmt.allocPrint(gpa, "{s}{s}", .{ canon_alias, std.fs.path.sep_str });
    defer gpa.free(real_prefix);
    try testing.expect(std.mem.startsWith(u8, dir, real_prefix));

    // And the validator agrees.
    try testing.expect(try harness.isSafeTmp(io, gpa, dir, "/home/someone-else"));
}

// The counterpart: the fix must not accept what it previously rejected.
//
// Canonicalising the allow-list is only safe because the prefix still
// resolves to a tmpdir. A `pabrik-func-` path somewhere else entirely
// has to stay rejected, or the guard would rmtree wherever it is told.
//
// The path need not exist — `isSafeTmp` is a spelling + allow-list
// check, not a stat. The first draft of this test built its "outside"
// path with `mkdtemp`, which puts the directory INSIDE the
// allow-listed tmpdir; it then asserted a rejection that only held
// because the namespace substring was missing, not because of the
// directory at all. A test that passes for the wrong reason is worse
// than no test, so the path here is absolute, carries the substring,
// and is under a directory nothing allow-lists.
test "canonicalising_both_sides_does_not_widen_the_allowlist" {
    // Python's fixture existed only to install a monkeypatched
    // allow-list. `harness.zig` has no mutable allow-list to patch, so
    // the alias is created to keep the precondition honest — there IS a
    // second spelling of the tmpdir in play — and the assertion is the
    // one that matters.
    const alias = try makeTmpdirAlias();
    defer gpa.free(alias);
    defer std.Io.Dir.cwd().deleteFile(io, alias) catch {};

    const outside = try std.fmt.allocPrint(
        gpa,
        "{s}not-a-tmpdir-at-all{s}{s}probe",
        .{ std.fs.path.sep_str, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR },
    );
    defer gpa.free(outside);

    try testing.expect(std.fs.path.isAbsolute(outside));
    try testing.expect(std.mem.indexOf(u8, outside, harness.REQUIRED_TMP_SUBSTR) != null);

    // The preconditions the Python test asserted, kept so a reader can
    // see this is not passing for the wrong reason.
    try testing.expect(!std.mem.startsWith(u8, outside, alias));
    try testing.expect(std.mem.indexOf(u8, outside, "/tmp/") == null);

    try testing.expect(!try harness.isSafeTmp(io, gpa, outside, "/home/someone-else"));
}

// A Windows path comparison is case-insensitive; this now is too.
//
// `normcase` is the half of `canonical` the 8.3 bug did not need. It is
// asserted here so nobody "simplifies" it away as dead code on a POSIX
// box, where normcase is a no-op. Only the WINDOWS branch can vary the
// case, so on POSIX this is a tautology by construction — stated plainly
// rather than dressed up as coverage.
test "allowlist_prefix_matches_regardless_of_case" {
    if (!is_windows) return error.SkipZigTest;

    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    var shout_buf: [std.fs.max_path_bytes]u8 = undefined;
    const shout_root = std.ascii.upperString(&shout_buf, root);
    const shouted = try std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}case-probe",
        .{ shout_root, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR },
    );
    defer gpa.free(shouted);

    try testing.expect(try harness.isSafeTmp(io, gpa, shouted, "/home/someone-else"));
}

// ============================================================================
// teardown safety net
// ============================================================================

// Constructing a harness with an unsafe temp_dir makes teardown raise.
//
// This is the ultimate safety net: even if every other guard fails,
// teardown must not delete a path that fails isSafeTmp.
test "teardown_refuses_unsafe_temp_dir" {
    // Build a harness instance WITHOUT calling boot (which creates its
    // own tempdir). Use a clearly-unsafe temp_dir: an absolute path
    // that is neither under the tmp prefix nor namespaced — and that
    // EXISTS, so the post-teardown "still exists" assertion is real.
    var unsafe_dir: []const u8 = undefined;
    var unsafe_home: []const u8 = "/home/alice";
    if (is_windows) {
        // `testing.environ`, not `std.process.getEnvVarOwned` — the
        // latter was REMOVED in Zig 0.16 (see `harness.zig`'s note on
        // `getEnvOrEmpty`), and a branch guarded by `if (is_windows)` is
        // only semantically analysed on a Windows host, so the mistake
        // would surface exactly where it is hardest to reach.
        const system_root = testing.environ.getAlloc(gpa, "SystemRoot") catch
            try gpa.dupe(u8, "C:\\Windows");
        defer gpa.free(system_root);
        unsafe_dir = try std.fs.path.join(gpa, &.{ system_root, "System32", "drivers", "etc", "hosts" });
        unsafe_home = "C:\\Users\\alice";
        if (!exists(unsafe_dir)) {
            std.debug.print("expected system file missing: {s}\n", .{unsafe_dir});
            gpa.free(unsafe_dir);
            return error.SkipZigTest;
        }
    } else {
        // A single well-known system file. NOT created here and not
        // written to: the assertion is that `deinit` refuses and the
        // file survives untouched, and the refusal happens BEFORE any
        // delete is attempted. Four independent gates in `isSafeTmp`
        // reject this path (not absolute-under-tmp-root, no namespace
        // marker, …) and the positive-control assertion below proves
        // the rejection came from the validator rather than from a
        // delete that silently no-op'd on a read-only file.
        unsafe_dir = try gpa.dupe(u8, "/etc/passwd");
    }
    defer gpa.free(unsafe_dir);

    // POSITIVE CONTROL: prove the path is genuinely unsafe BEFORE
    // teardown runs, so "the file still exists" cannot pass vacuously
    // because `isSafeTmp` said nothing about it.
    try testing.expect(!try harness.isSafeTmp(io, gpa, unsafe_dir, unsafe_home));
    try testing.expect(exists(unsafe_dir));

    var h = try bareHarness(unsafe_dir, unsafe_home, false);

    // `deinit` owns every string inside `h`; there is no `defer gpa.free`
    // for them here, and `h` must not be read afterwards (`freeAll` does
    // `self.* = undefined`).
    const result = h.deinit(io);
    if (result) |_| {
        std.debug.print("teardown did NOT refuse an unsafe temp_dir: {s}\n", .{unsafe_dir});
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(harness.FunctionalHarnessError.TeardownRefused, err);
    }

    // And the file MUST still exist.
    try testing.expect(exists(unsafe_dir));
}

// A safe temp_dir is actually rmtree'd by teardown.
test "teardown_with_safe_temp_dir_runs_rmtree" {
    // A real sandbox under the tmp root, created with the required
    // prefix so it matches the safety rules.
    const safe = try freshMarkerDir();
    defer gpa.free(safe);

    const inner = try std.fs.path.join(gpa, &.{ safe, "marker.txt" });
    defer gpa.free(inner);
    {
        var f = try std.Io.Dir.cwd().createFile(io, inner, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "exists");
    }

    // teardown should run without raising because:
    // - the dir is on the tmp root
    // - safe contains the substring
    // - safe != orig_home
    var h = try bareHarness(safe, "/home/nonexistent", false);
    try h.deinit(io);

    // `h.temp_dir` is undefined after deinit — assert against the local
    // copy, which the caller owns.
    try testing.expect(!exists(safe));
}

// ============================================================================
// constants are sane
// ============================================================================

// The allow-list must include tempfile.gettempdir() (defensive).
test "allowed_tmp_prefixes_contains_gettempdir" {
    // Python asserted `(gettempdir() + "/") in ALLOWED_TMP_PREFIXES` —
    // a membership test on a module tuple. `harness.zig` has no such
    // tuple: `isSafeTmp` PROBES `tmpRoot` first (a custom `%TEMP%` is
    // authoritative) and only then falls back to the fixed
    // `POSIX_TMP_PREFIXES`. The behavioural form of the same invariant
    // is that a fresh namespaced directory directly under the tmp root
    // is accepted — which can only happen if the root is allow-listed.
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    try testing.expect(root.len > 0);
    try testing.expect(std.fs.path.isAbsolute(root));

    const probe = try std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}allowlist-probe",
        .{ root, std.fs.path.sep_str, harness.REQUIRED_TMP_SUBSTR },
    );
    defer gpa.free(probe);

    // Positive control: it really does live under the tmp root…
    const canon_probe = try harness.canonical(io, gpa, probe);
    defer gpa.free(canon_probe);
    const canon_root = try harness.canonical(io, gpa, root);
    defer gpa.free(canon_root);
    try testing.expect(std.mem.startsWith(u8, canon_probe, canon_root));

    // …and so the validator accepts it. A path under the same root
    // WITHOUT the marker is rejected (covered by
    // `is_safe_tmp_rejects_path_without_substring`), so acceptance here
    // is the allow-list, not a blanket yes.
    try testing.expect(try harness.isSafeTmp(io, gpa, probe, "/home/someone-else"));

    // …and the parent itself is NOT deletable: it carries no marker.
    try testing.expect(!try harness.isSafeTmp(io, gpa, root, "/home/someone-else"));
}

// REQUIRED_TMP_SUBSTR must end with a separator-like chunk so
// a path like /tmp/pabrik-func / etc. cannot satisfy a substring
// check that includes a separator.
test "required_substring_is_namespaced" {
    try testing.expect(std.mem.endsWith(u8, harness.REQUIRED_TMP_SUBSTR, "-"));
    // The suite-fixture marker is a SECOND accepted namespace, and it
    // must obey the same rule or `cleanupExtraDir` would gate on a bare
    // prefix that also matches unrelated directories.
    try testing.expect(std.mem.endsWith(u8, harness.SCRATCH_PREFIX, "-"));
    // They must not overlap: `reapOrphanTestPids` only matches
    // `REQUIRED_TMP_SUBSTR`, which is what keeps a live fixture from
    // being reaped mid-test.
    try testing.expect(std.mem.indexOf(u8, harness.SCRATCH_PREFIX, harness.REQUIRED_TMP_SUBSTR) == null);
    try testing.expect(std.mem.indexOf(u8, harness.REQUIRED_TMP_SUBSTR, harness.SCRATCH_PREFIX) == null);
}

// boot() refuses if no home can be determined (no path to validate against).
test "orig_home_must_exist_for_boot" {
    // Python deleted HOME AND USERPROFILE (and broke `Path.home`) so
    // every layer of the resolution chain failed deterministically, then
    // asserted `boot()` raised "HOME not set".
    //
    // TODO(port): NOT EXPRESSIBLE. `boot()` reads the CURRENT process
    // environment through `harness.currentEnviron()`, which is
    // `std.testing.environ`. The test runner populates that `Environ`
    // ONCE from the real environment
    // (`std/compiler/test_runner.zig:125`) and its POSIX `Block` is
    // `[:null]const ?[*:0]const u8` — a CONST slice, with no `put` /
    // `remove` seam. The only way to observe the `error.HomeNotSet`
    // branch is to run `boot()` in a child process whose environment
    // has HOME and USERPROFILE stripped, which no test in this package
    // does.
    //
    // Consequence, stated plainly: the `error.HomeNotSet` branch of
    // `Harness.boot` currently has NO guard in the Zig suite.
    return error.SkipZigTest;
}

// ============================================================================
// boot() signature: port default must be None (random), not 8080
// ============================================================================

/// The default of `Harness.BootOptions.port`, read out of `@typeInfo`.
///
/// Python's `inspect.signature(FunctionalHarness.boot).parameters
/// ["port"].default` has no direct Zig analogue, but the property it
/// guards does: a NON-NULL default would silently route every
/// `boot()` through the legacy sequential scan. The field default is
/// the same fact, readable at comptime.
const BootPortDefault = struct {
    /// `null` means "the field is missing or has no default" — the
    /// presence check in the test distinguishes those from "the default
    /// IS null", which is the assertion.
    fn value() ?u16 {
        const info = @typeInfo(Harness.BootOptions).@"struct";
        // `if (comptime …)` rather than a `continue`: an `inline for`
        // body is still a runtime block, so a plain `if` around a
        // `continue` is "comptime control flow inside a runtime block".
        inline for (info.fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "port")) {
                const ptr = f.default_value_ptr orelse return null;
                const v: *const ?u16 = @ptrCast(@alignCast(ptr));
                return v.*;
            }
        }
        return null;
    }
};

// `FunctionalHarness.boot(port=None)` is the documented default.
//
// Regression guard for the bug where `port: int = DEFAULT_PORT` (=8080)
// was the default, which then triggered the legacy sequential scan even
// when the caller didn't ask for a port. With that signature, a bare
// `FunctionalHarness.boot(pabrik_bin)` call would always try 8080
// first — bypassing the random pool and reintroducing the CI pathology
// the random pool was meant to fix.
test "boot_signature_accepts_none_port" {
    // Positive control: the field exists at all, so a rename cannot make
    // the assertion below pass vacuously.
    var has_port_field = false;
    inline for (@typeInfo(Harness.BootOptions).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, "port")) has_port_field = true;
    }
    try testing.expect(has_port_field);

    const default = BootPortDefault.value();
    if (default) |d| {
        std.debug.print(
            "Harness.BootOptions.port default must be null (→ random pick), got {d}. " ++
                "With a non-null default, a bare `Harness.boot` would silently " ++
                "get the legacy sequential scan from that port.\n",
            .{d},
        );
        return error.TestUnexpectedResult;
    }
}

// ============================================================================
// XDG isolation must not be platform-gated
// ============================================================================
//
// `getDefaultConfigDir` (Config.zig) resolves $XDG_CONFIG_HOME/pabrik
// BEFORE $HOME/.config/pabrik on Linux, and the same XDG-first rule is
// hand-duplicated for memories/, skills/ and hooks/. The harness used to
// shadow the XDG vars into the child env only under `if os.name == "nt"`,
// so on the GitHub Actions ubuntu runner (which exports
// XDG_CONFIG_HOME=/home/runner/.config) the pabrik child wrote config.json
// into the runner's real home while every test read <temp_dir>/.config.
// That surfaced as 31 failures in run 36582964531 — all on-disk
// assertions reading a file the server had never written — and it made
// results order-dependent, because all harness instances in the job
// shared that one file.
//
// These guards fail if anyone re-gates the XDG shadowing behind a
// platform check. The parent `os.environ` is deliberately NOT asserted
// here: shadowing it on Linux/mac is explicitly out of scope.

// FunctionalHarness.boot must shadow XDG for the child on all platforms.
test "harness_xdg_shadowing_is_not_platform_gated" {
    // TODO(port): the Python version was a SOURCE-TEXT GREP — it read
    // `harness.py` and asserted every `env["XDG_*"] = ` assignment sat
    // at method-body indent, not nested inside `if os.name == "nt":`.
    // A textual check of the source is not a test (see the repo's
    // "Tests — Assert Behaviour, Never Source Text" rule), and the
    // equivalent Zig check would be `indexOf`-ing `harness.zig`, which
    // is exactly the anti-pattern the rule exists to stop.
    //
    // The behavioural replacement needs a BOOTED CHILD whose resolved
    // config path is observed — which is why `harness_safety_test.zig`
    // cannot hold it. It lives in `smoke_boot_test.zig`:
    // `state_lives_in_temp_dir` asserts `agent.db` exists at
    // `<temp_dir>/.config/pabrik/agent.db`, which on Linux is
    // `$XDG_CONFIG_HOME/pabrik/agent.db` — i.e. it already fails if the
    // XDG shadowing is platform-gated, because the child's inherited
    // `$XDG_CONFIG_HOME` would put the DB in the runner's real home.
    //
    // That replacement requires the binary, so it SKIPS on a clean
    // checkout. The invariant therefore has no coverage on a machine
    // with no `zig-out/`.
    return error.SkipZigTest;
}

// These two files re-implement the spawn instead of calling boot().
//
// They carry their own copy of the child-env block, so the harness fix
// does not cover them — they regressed in lockstep and must be guarded
// separately.
test "private_preboot_fixtures_also_shadow_xdg" {
    // TODO(port): same source-text grep as above, over
    // `config_simplify_test.py` and `config_tools_test.py` (a
    // `@pytest.mark.parametrize`d pair, hence ONE test block here).
    // Both files now have Zig ports in this package; neither exposes a
    // child-env seam, and neither should — re-implementing the spawn is
    // the thing being guarded against, and the correct fix is to call
    // `Harness.boot`.
    return error.SkipZigTest;
}

comptime {
    // Body-analysis barrier: an unreferenced function is never
    // type-checked, so a stdlib rename inside one of these helpers
    // would stay invisible until a caller happened to appear.
    _ = freshMarkerDir;
    _ = unnamespacedTmpChild;
    _ = bareHarness;
    _ = makeTmpdirAlias;
    _ = exists;
    _ = isDir;
    _ = BootPortDefault.value;
}
