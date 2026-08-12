//! Static regression checks for the `gitignore vendor/sqlite3` feature.
//!
//! Why this file exists
//! ────────────────────
//! The `/vendor/` directory was added to `.gitignore` to remove the
//! ~10 MB SQLite amalgamation from the repo. The amalgamation is now
//! fetched on demand by `src/modules/databases/scripts/fetch-vendor-sqlite3.sh`,
//! which CI no longer invokes via a dedicated step — instead,
//! build.zig's `vendor_sqlite3_step` (wired into `test_step` and
//! every `install:*` step) is the single source of truth, and the
//! fetch runs automatically on a fresh checkout. These checks keep
//! the three pieces in lockstep:
//!
//!   1. `.gitignore` continues to ignore `/vendor/`
//!   2. The fetch script is present, executable, and self-contained
//!   3. build.zig wires `vendor_sqlite3_step` into `test_step` and
//!      every `install:*` step (so CI doesn't need a separate step)
//!   4. ci.yml's Zig build cache key hashes the fetch script (so a
//!      version bump invalidates the cache and forces a re-fetch)
//!
//! Plan: docs/superpowers/plans/2026-07-01-gitignore-vendor-sqlite3.md
//!       (the kanban task `git ignore vendor sqlite3`)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const GITIGNORE_PATH = ".gitignore";
// The script moved out of the repo-root `scripts/` directory in the
// self-contained-package refactor (PR #211) so the `databases` module
// owns its own fetch script co-located with its build glue. CI no
// longer has an explicit `if: runner.os != 'Linux'` step — instead
// build.zig's `vendor_sqlite3_step` (wired into `test_step` and every
// `install:*` step) is the single source of truth.
const FETCH_SCRIPT_PATH = "src/modules/databases/scripts/fetch-vendor-sqlite3.sh";
const CI_WORKFLOW_PATH = ".github/workflows/ci.yml";
const BUILD_ZIG_PATH = "build.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
/// Mirrors the `readSource` helper in routines_run_test.zig — kept
/// local here to avoid coupling this file to a sibling test module.
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

// ─── Contract 1: .gitignore ignores /vendor/ ────────────────────────────────

test ".gitignore contains the /vendor/ rule" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, GITIGNORE_PATH);
    defer allocator.free(source);

    // We must look for the rule as a complete LINE, not just a substring
    // — a comment line like `# /vendor/` should NOT count, because
    // git only treats lines starting (after optional leading
    // whitespace) with a non-`#` character as active rules.
    var has_active_rule = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, "/vendor/")) {
            has_active_rule = true;
            break;
        }
    }

    if (!has_active_rule) {
        std.debug.print(
            "\n!! {s} has no active `/vendor/` ignore rule !!\n" ++
                "   The amalgamation (~10 MB of binary-like content) must be\n" ++
                "   gitignored so it does not bloat every clone. Add a line\n" ++
                "   that EXACTLY matches `/vendor/` (anchored to repo root).\n" ++
                "   Comment lines (`# /vendor/`) do NOT count.\n" ++
                "   See plan: docs/superpowers/plans/2026-07-01-gitignore-vendor-sqlite3.md.\n",
            .{GITIGNORE_PATH},
        );
        return error.VendorIgnoreRuleMissing;
    }
}

test ".gitignore rule is anchored to repo root (so it does not match nested vendor/ dirs)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, GITIGNORE_PATH);
    defer allocator.free(source);

    // The rule must start with `/` so it ONLY matches `vendor/` at the
    // repo root. Without the leading slash, the pattern would also
    // match `src/.../vendor/` directories (e.g. third-party code that
    // vendors dependencies inside subdirs) — possibly hiding real
    // source files from `git status`.
    //
    // We accept either `/vendor/` (just the directory) or `/vendor/...`
    // (with content filters like `/vendor/*.h`) as long as it starts
    // with `/vendor/`. A bare `vendor/` (no leading slash) is rejected
    // because it would also match `src/.../vendor/`.
    var has_anchored_rule = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "/vendor/")) {
            has_anchored_rule = true;
            break;
        }
    }

    if (!has_anchored_rule) {
        std.debug.print(
            "\n!! {s} has no anchored /vendor/ rule !!\n" ++
                "   The rule must be anchored to the repo root with a leading\n" ++
                "   slash (e.g. `/vendor/` or `/vendor/*.h`). Without it, a\n" ++
                "   bare `vendor/` pattern would also hide any nested\n" ++
                "   vendor/ subdirectories of third-party code.\n",
            .{GITIGNORE_PATH},
        );
        return error.VendorIgnoreRuleNotAnchored;
    }
}

// ─── Contract 2: fetch script exists and has the right shape ───────────────

test "scripts/fetch-vendor-sqlite3.sh exists" {
    const allocator = testing.allocator;
    const source = readSource(allocator, FETCH_SCRIPT_PATH) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print(
                "\n!! {s} is missing !!\n" ++
                    "   The amalgamation is gitignored but build.zig's\n" ++
                    "   `vendor_sqlite3_step` still references this script\n" ++
                    "   to populate vendor/sqlite3/. Without the script,\n" ++
                    "   fresh clones on Windows/macOS cannot build.\n" ++
                    "   Restore src/modules/databases/scripts/fetch-vendor-sqlite3.sh from git.\n",
                .{FETCH_SCRIPT_PATH},
            );
            return error.FetchScriptMissing;
        }
        return err;
    };
    defer allocator.free(source);

    // The file must be a bash script (starts with shebang).
    if (source.len < 2 or source[0] != '#' or source[1] != '!') {
        std.debug.print(
            "\n!! {s} does not start with a shebang !!\n" ++
                "   The script must be a valid bash script for CI runners.\n" ++
                "   Restore the `#!/usr/bin/env bash` shebang line.\n",
            .{FETCH_SCRIPT_PATH},
        );
        return error.FetchScriptShebangMissing;
    }
}

test "fetch-vendor-sqlite3.sh declares the SQLite 3.53.3 URL + SHA3-256 constants" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FETCH_SCRIPT_PATH);
    defer allocator.free(source);

    // The script must pin to a specific SQLite version. The current
    // version is 3.53.3 (the version that was committed before the
    // gitignore change). If a future bump forgets to update both the
    // constant AND the docs/tests, the SHA3 will mismatch on download
    // and the build will fail.
    if (std.mem.indexOf(u8, source, "SQLITE_VERSION=\"3.53.3\"") == null) {
        std.debug.print(
            "\n!! {s} does not pin SQLITE_VERSION to 3.53.3 !!\n" ++
                "   The script must declare the SQLite amalgamation version\n" ++
                "   it downloads. If you intentionally bumped SQLite, update\n" ++
                "   this test to match the new version constant AND the\n" ++
                "   SHA3-256 below.\n",
            .{FETCH_SCRIPT_PATH},
        );
        return error.SqliteVersionConstantMissing;
    }

    // The URL must point at sqlite.org's amalgamation. The version
    // number 3530300 = 3*1_000_000 + 53*1_000 + 3 (SQLite's encoding).
    // The script builds the URL from SQLITE_YEAR + SQLITE_VERSION_NUMBER
    // so we check the constituent constants individually.
    const required_url_parts = [_][]const u8{
        "https://sqlite.org/",
        "SQLITE_YEAR=\"2026\"",
        "SQLITE_VERSION_NUMBER=\"3530300\"",
        "sqlite-amalgamation-${SQLITE_VERSION_NUMBER}.zip",
    };
    for (required_url_parts) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print(
                "\n!! {s} is missing URL component: {s} !!\n" ++
                    "   The script must build the URL as:\n" ++
                    "     https://sqlite.org/${{SQLITE_YEAR}}/sqlite-amalgamation-${{SQLITE_VERSION_NUMBER}}.zip\n" ++
                    "   with SQLITE_YEAR matching the release year and\n" ++
                    "   SQLITE_VERSION_NUMBER matching the SQLite encoding\n" ++
                    "   of 3.53.3 (= 3_530_300).\n" ++
                    "   If you bumped SQLite, update the constants AND the\n" ++
                    "   SHA3-256 in the script (download page has both).\n",
                .{FETCH_SCRIPT_PATH, needle},
            );
            return error.SqliteUrlMissing;
        }
    }

    // The expected SHA3-256 (cross-checked against the SQLite download
    // page on 2026-07-01: d45c688a8cb23f68611a894a756a12d7eb6ab6e9e2468ca70adbeab3808b5ab9).
    const expected_sha = "d45c688a8cb23f68611a894a756a12d7eb6ab6e9e2468ca70adbeab3808b5ab9";
    if (std.mem.indexOf(u8, source, expected_sha) == null) {
        std.debug.print(
            "\n!! {s} does not pin the expected SHA3-256 !!\n" ++
                "   Expected: {s}\n" ++
                "   If you bumped SQLite, fetch the new SHA3-256 from\n" ++
                "   https://sqlite.org/download.html and update the script.\n",
            .{FETCH_SCRIPT_PATH, expected_sha},
        );
        return error.SqliteSha256Missing;
    }
}

test "fetch-vendor-sqlite3.sh is idempotent (skips when files exist)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FETCH_SCRIPT_PATH);
    defer allocator.free(source);

    // The script must have a short-circuit: if all 3 amalgamation
    // files exist, print a "skipping fetch" message and exit 0.
    // Without this, every CI run would re-download the zip even
    // when the cache step restored the files.
    const required = [_][]const u8{
        "skipping fetch",
        "already populated",
        "REQUIRED_FILES",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print(
                "\n!! {s} does not contain expected idempotency marker {s} !!\n" ++
                    "   The script must short-circuit when all 3 amalgamation\n" ++
                    "   files are already on disk. Without this, CI will\n" ++
                    "   re-download the 2.8 MiB zip on every run.\n",
                .{FETCH_SCRIPT_PATH, needle},
            );
            return error.IdempotencyMarkerMissing;
        }
    }
}

test "fetch-vendor-sqlite3.sh has a python3 extraction fallback" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, FETCH_SCRIPT_PATH);
    defer allocator.free(source);

    // The script must support both python3 AND unzip for extraction.
    // python3 is the primary path (handles zip cleanly across versions
    // and also runs the SHA3-256 verification). unzip is the fallback
    // for minimal CI images that lack python3.
    if (std.mem.indexOf(u8, source, "python3") == null) {
        std.debug.print(
            "\n!! {s} has no python3 extraction path !!\n" ++
                "   The primary extraction path is python3 (cross-platform,\n" ++
                "   handles zip paths cleanly). Restore the `python3 -` block.\n",
            .{FETCH_SCRIPT_PATH},
        );
        return error.Python3ExtractionMissing;
    }
    if (std.mem.indexOf(u8, source, "unzip") == null) {
        std.debug.print(
            "\n!! {s} has no unzip fallback !!\n" ++
                "   Some CI images ship without python3 but with unzip.\n" ++
                "   Without an unzip fallback, those images will fail to\n" ++
                "   extract the amalgamation. Restore the `unzip -j` line.\n",
            .{FETCH_SCRIPT_PATH},
        );
        return error.UnzipFallbackMissing;
    }
}

// ─── Contract 3: build.zig wires the fetch into test + install:* steps ─────
//
// History: when this file was first written, CI had an explicit
//   - name: Fetch vendored SQLite amalgamation (Windows / macOS)
//     if: runner.os != 'Linux'
//     run: ./scripts/fetch-vendor-sqlite3.sh
// step, and the test enforced that step. After the self-contained-
// package refactor (PR #211), the script moved into
// src/modules/databases/scripts/ AND build.zig grew a
// `vendor_sqlite3_step` (run via addSystemCommand) that the test
// step and every install:* step depend on. The script is idempotent
// (skips when files exist), so the fetch is a no-op on cached/second
// runs. This means CI no longer needs a separate script-invocation
// step — `zig build test` and `zig build nalar-desktop` Just Work on
// a fresh checkout.

test "build.zig wires vendor_sqlite3_step into test + install:* steps" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, BUILD_ZIG_PATH);
    defer allocator.free(source);

    // 1. The fetch step must reference the script at its (new)
    //    src/modules/databases/scripts/ location. The script moved out
    //    of the repo-root `scripts/` directory when the `databases`
    //    module was made self-contained.
    if (std.mem.indexOf(
        u8,
        source,
        "src/modules/databases/scripts/fetch-vendor-sqlite3.sh",
    ) == null) {
        std.debug.print(
            "\n!! {s} does not invoke the fetch script at its new path !!\n" ++
                "   build.zig's `vendor_sqlite3_step` must run:\n" ++
                "     bash src/modules/databases/scripts/fetch-vendor-sqlite3.sh\n" ++
                "   (the old repo-root `scripts/fetch-vendor-sqlite3.sh`\n" ++
                "    path was removed in the self-contained-package refactor).\n",
            .{BUILD_ZIG_PATH},
        );
        return error.BuildZigFetchStepMissing;
    }

    // 2. The fetch must be exposed as a named build step so it can be
    //    wired into other steps. We accept either the constant name
    //    `vendor_sqlite3_step` or the public step name
    //    `fetch-vendor-sqlite3` (the addSystemCommand's name).
    if (std.mem.indexOf(u8, source, "vendor_sqlite3_step") == null and
        std.mem.indexOf(u8, source, "fetch-vendor-sqlite3") == null)
    {
        std.debug.print(
            "\n!! {s} does not define a fetch-vendor-sqlite3 step !!\n" ++
                "   The fetch must be exposed as a build step (named\n" ++
                "   `vendor_sqlite3_step` or `fetch-vendor-sqlite3`) so it\n" ++
                "   can be depended on by `test_step` and every `install:*` step.\n",
            .{BUILD_ZIG_PATH},
        );
        return error.VendorSqlite3StepMissing;
    }

    // 3. test_step must depend on the fetch so `zig build test` (run
    //    by CI) triggers the fetch on a fresh checkout. Without this
    //    wiring, the test step would fail with
    //    "unable to find file 'vendor/sqlite3/sqlite3.c'".
    if (std.mem.indexOf(u8, source, "test_step.dependOn(vendor_sqlite3_step)") == null) {
        std.debug.print(
            "\n!! {s} does not wire vendor_sqlite3_step into test_step !!\n" ++
                "   The test step must depend on the fetch so `zig build test`\n" ++
                "   populates src/modules/databases/vendor/sqlite3/ on a fresh\n" ++
                "   checkout (otherwise the first compile fails with\n" ++
                "   \"unable to find file 'vendor/sqlite3/sqlite3.c'\").\n",
            .{BUILD_ZIG_PATH},
        );
        return error.TestStepNotDependingOnVendorFetch;
    }

    // 4. At least one install:* step must depend on the fetch so
    //    `zig build nalar-desktop` (also run by CI) triggers it. The
    //    Linux native install step (linux_system_step) is the one the
    //    CI matrix actually exercises on the self-hosted Linux runner.
    if (std.mem.indexOf(u8, source, "linux_system_step.dependOn(vendor_sqlite3_step)") == null) {
        std.debug.print(
            "\n!! {s} does not wire vendor_sqlite3_step into linux_system_step !!\n" ++
                "   The install:linux:system step must depend on vendor_sqlite3_step\n" ++
                "   so `zig build nalar-desktop` populates the amalgamation on a\n" ++
                "   fresh checkout. (Other install:* steps — windows, macos,\n" ++
                "   macos-arm — should also depend on it for cross-compile builds.)\n",
            .{BUILD_ZIG_PATH},
        );
        return error.InstallStepNotDependingOnVendorFetch;
    }
}

test "ci.yml cache key includes the fetch script (to invalidate on updates)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CI_WORKFLOW_PATH);
    defer allocator.free(source);

    // The cache key must include the fetch script (at its NEW path
    // under src/modules/databases/scripts/) so that bumping the
    // SQLite version in the script invalidates the cache and forces a
    // re-download. Without this, a script change could leave a stale
    // amalgamation in the cache.
    //
    // Note: we check for the explicit new path rather than just
    // `fetch-vendor-sqlite3.sh` because the new path contains the
    // old path as a substring (the old `scripts/...` is a suffix of
    // the new `src/modules/databases/scripts/...`), so a substring
    // needle would pass for either location and wouldn't catch a
    // regression where the cache key was reverted to the old path.
    if (std.mem.indexOf(
        u8,
        source,
        "src/modules/databases/scripts/fetch-vendor-sqlite3.sh",
    ) == null) {
        std.debug.print(
            "\n!! {s} cache key does not include the fetch script at its new path !!\n" ++
                "   The Zig build cache key should be:\n" ++
                "     ${{ hashFiles('build.zig', 'build.zig.zon', 'src/apps/desktop_app/main.zig', 'src/apps/desktop/bun.lock', 'src/modules/databases/scripts/fetch-vendor-sqlite3.sh') }}\n" ++
                "   so that bumping the SQLite version in the script\n" ++
                "   invalidates the cache and triggers a re-fetch.\n",
            .{CI_WORKFLOW_PATH},
        );
        return error.CiCacheKeyMissingScript;
    }
}
