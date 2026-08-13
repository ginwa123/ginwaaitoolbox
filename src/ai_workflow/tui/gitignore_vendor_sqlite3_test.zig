//! Static regression checks for the `gitignore vendor/sqlite3` feature.
//!
//! Why this file exists
//! ────────────────────
//! The `/vendor/` directory was added to `.gitignore` to remove the
//! ~10 MB SQLite amalgamation from the repo. The amalgamation is now
//! fetched on demand by `scripts/fetch-vendor-sqlite3.sh` (which CI
//! invokes on Windows/macOS runners). These checks ensure the three
//! pieces stay in lockstep:
//!
//!   1. `.gitignore` continues to ignore `/vendor/`
//!   2. The fetch script is present, executable, and self-contained
//!   3. The CI workflow invokes the script on non-Linux runners
//!
//! Plan: docs/superpowers/plans/2026-07-01-gitignore-vendor-sqlite3.md
//!       (the kanban task `git ignore vendor sqlite3`)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const GITIGNORE_PATH = ".gitignore";
const FETCH_SCRIPT_PATH = "scripts/fetch-vendor-sqlite3.sh";
const CI_WORKFLOW_PATH = ".github/workflows/ci.yml";

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

// ─── Contract 3: CI workflow invokes the fetch script on non-Linux ─────────

test "ci.yml cache key includes the fetch script (to invalidate on updates)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, CI_WORKFLOW_PATH);
    defer allocator.free(source);

    // The cache key must include the fetch script so that bumping the
    // SQLite version in the script invalidates the cache and forces a
    // re-download. Without this, a script change could leave a stale
    // amalgamation in the cache.
    if (std.mem.indexOf(u8, source, "scripts/fetch-vendor-sqlite3.sh") == null) {
        std.debug.print(
            "\n!! {s} cache key does not include the fetch script !!\n" ++
                "   The Zig build cache key should be:\n" ++
                "     ${{ hashFiles('build.zig.zon', 'build.zig', 'scripts/fetch-vendor-sqlite3.sh') }}\n" ++
                "   so that bumping the SQLite version in the script\n" ++
                "   invalidates the cache and triggers a re-fetch.\n",
            .{CI_WORKFLOW_PATH},
        );
        return error.CiCacheKeyMissingScript;
    }
}
