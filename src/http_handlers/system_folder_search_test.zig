//! Static-contract tests for `action=search` on GET /api/system/folder
//! (plan: docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md,
//! Task 1).
//!
//! Why this file exists
//! ────────────────────
//! The ChatView `@` picker used to walk the tree with N sequential
//! `action=list` fetches (one per directory). The fix adds a single
//! server-side recursive search branch (`action=search` with `q`,
//! `limit`, `max_depth` params) backed by
//! `SystemFolder.searchFiles`, serialized in the SAME
//! `{name, path, is_directory, is_symlink}` shape as list.
//!
//! Standing up a real server + singleton + Io to exercise the HTTP path
//! is too much integration infra for one branch (same rationale as
//! `frontend_log_post_test.zig`), so these contracts grep the handler
//! source for the substrings a future refactor must preserve. The
//! search behaviour itself is covered behaviourally by the `searchFiles`
//! + `parseSearchLimit/parseSearchMaxDepth` tests in
//! `src/modules/system_folder/system_folder_test.zig`; the wire
//! behaviour lands in `tests/functional/system_folder_search_test.py`
//! (Task 4 of the same plan).

const std = @import("std");
const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/system_folder.zig";
const MAIN_PATH = "src/main.zig";
const TEST_RUNNER_PATH = "src/ai_workflow/tui/test_runner.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOf(u8, haystack[from..], needle)) |idx| {
        n += 1;
        from += idx + needle.len;
    }
    return n;
}

// ─── Contract 1: handler branches on action=search ───────────────────────

test "system_folder handler branches on action=search" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Without this branch the `@` picker falls back to N sequential
    // action=list walks (the perf bug this plan fixes).
    if (std.mem.indexOf(u8, source, "\"search\"") == null) {
        std.debug.print(
            "\n!! {s} has no action=search branch !!\n" ++
                "   The ChatView `@` picker needs a single server-side\n" ++
                "   recursive search; without it the frontend walks the\n" ++
                "   tree with one action=list fetch per directory.\n" ++
                "   See docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md Task 1.\n",
            .{HANDLER_PATH},
        );
        return error.SearchActionBranchMissing;
    }
}

// ─── Contract 2: handler parses the q param ─────────────────────────────

test "system_folder search parses q param" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.query.get(\"q\")") == null) {
        std.debug.print(
            "\n!! {s} does not parse the q param !!\n" ++
                "   action=search must read `q` (default \"\" = top-N\n" ++
                "   listing) and pass it to SystemFolder.searchFiles.\n",
            .{HANDLER_PATH},
        );
        return error.SearchQueryParamMissing;
    }
}

// ─── Contract 3: handler clamps limit via parseSearchLimit ───────────────

test "system_folder search clamps limit via parseSearchLimit" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // parseSearchLimit = default 50, clamp 1..200 (hard cap). Going
    // through the shared helper keeps the handler and the unit tests
    // on the same clamp semantics.
    if (std.mem.indexOf(u8, source, "parseSearchLimit") == null) {
        std.debug.print(
            "\n!! {s} does not use parseSearchLimit !!\n" ++
                "   action=search must clamp `limit` (default 50, hard\n" ++
                "   cap 200) via SystemFolder.parseSearchLimit so a\n" ++
                "   `limit=5000` query cannot blow up the response.\n",
            .{HANDLER_PATH},
        );
        return error.SearchLimitClampMissing;
    }
}

// ─── Contract 4: handler clamps max_depth via parseSearchMaxDepth ────────

test "system_folder search clamps max_depth via parseSearchMaxDepth" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parseSearchMaxDepth") == null) {
        std.debug.print(
            "\n!! {s} does not use parseSearchMaxDepth !!\n" ++
                "   action=search must clamp `max_depth` (default 8,\n" ++
                "   clamp 1..16) via SystemFolder.parseSearchMaxDepth.\n",
            .{HANDLER_PATH},
        );
        return error.SearchMaxDepthClampMissing;
    }
}

// ─── Contract 5: handler delegates to SystemFolder.searchFiles ───────────

test "system_folder search delegates to SystemFolder.searchFiles" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "searchFiles") == null) {
        std.debug.print(
            "\n!! {s} does not call searchFiles !!\n" ++
                "   action=search must delegate the walk to\n" ++
                "   SystemFolder.searchFiles (skip-list + limit +\n" ++
                "   ranking live there, unit-tested in\n" ++
                "   system_folder_test.zig).\n",
            .{HANDLER_PATH},
        );
        return error.SearchFilesNotCalled;
    }
}

// ─── Contract 6: empty path is rejected with 400 ─────────────────────────

test "system_folder search guards empty path with 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // SqliteBackend-style empty-slice-as-NULL rule: an explicitly empty
    // `path=` must 400 with a greppable message, not fall through to
    // home (missing param) or to a 403 InvalidPath.
    if (std.mem.indexOf(u8, source, "path required") == null) {
        std.debug.print(
            "\n!! {s} does not guard empty path !!\n" ++
                "   action=search with an explicitly empty `path=` must\n" ++
                "   return 400 with the substring `path required`.\n",
            .{HANDLER_PATH},
        );
        return error.SearchEmptyPathGuardMissing;
    }
}

// ─── Contract 7 (guard): action=list branch is unchanged ─────────────────

test "system_folder action=list branch is unchanged" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The old single-level list contract must keep working (Task 4
    // replays it as a regression guard); the search branch is additive.
    if (std.mem.indexOf(u8, source, "\"list\"") == null) {
        std.debug.print(
            "\n!! {s} lost the action=list branch !!\n" ++
                "   The search branch is additive — action=list must\n" ++
                "   keep serving single-level listings.\n",
            .{HANDLER_PATH},
        );
        return error.ListActionBranchMissing;
    }
}

// ─── Contract 8 (guard): entries serialize snake_case is_directory ───────

test "system_folder entries serialize snake_case is_directory" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The kanban picker already mis-reads camelCase `isDirectory`
    // (always undefined → all rows treated as files). The search
    // branch must reuse the SAME snake_case shape as list.
    if (std.mem.indexOf(u8, source, "is_directory") == null) {
        std.debug.print(
            "\n!! {s} does not serialize is_directory !!\n" ++
                "   Both list and search entries must use snake_case\n" ++
                "   `is_directory` on the wire.\n",
            .{HANDLER_PATH},
        );
        return error.SnakeCaseFieldMissing;
    }
}

// ─── Contract 9 (guard): same route, no new route in main.zig ───────────

test "system_folder search reuses the same route (no new main.zig route)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    // action=search rides on the existing GET /api/system/folder route
    // (route-order shadowing guard: a second literal route registered
    // after a param route would be captured).
    const n = countOccurrences(source, "/api/system/folder");
    if (n != 1) {
        std.debug.print(
            "\n!! {s} has {d} /api/system/folder routes (want 1) !!\n" ++
                "   action=search must reuse the existing route — do NOT\n" ++
                "   register a new one in main.zig.\n",
            .{ MAIN_PATH, n },
        );
        return error.UnexpectedRouteCount;
    }
}

// ─── Contract 10 (guard): tui test_runner registers this file ───────────

test "tui test_runner registers system_folder_search_test" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TEST_RUNNER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "system_folder_search_test.zig") == null) {
        std.debug.print(
            "\n!! {s} does not import system_folder_search_test.zig !!\n" ++
                "   Register the file so `zig build test` runs these contracts.\n",
            .{TEST_RUNNER_PATH},
        );
        return error.TestRunnerRegistrationMissing;
    }
}
