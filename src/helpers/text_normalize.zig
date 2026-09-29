//! Cross-platform source-text normalization for static-contract tests.
//!
//! ## Why this file exists
//!
//! The `*_test.zig` files in `http_handlers/` and `tools/` are
//! **static-contract tests**: they read the production source as
//! bytes and grep for literal substrings (e.g. a function signature,
//! a response struct field, etc.) to lock in the shape of the code.
//!
//! These needles are constructed as Zig string literals like
//! `"pub fn classifyPath(\n    allocator: std.mem.Allocator,\n"`,
//! where every `\n` is a single LF byte.
//!
//! On Windows, Git's default `core.autocrlf=true` checks out text
//! files with CRLF line endings. So the source file actually has
//! `\r\n` between every line, and the needle `"\n    allocator"`
//! will NEVER match — even though the source clearly contains
//! `"    allocator"` after a newline.
//!
//! ## Symptom of the bug
//!
//! On a fresh Windows checkout (CI runner, contributor's clone with
//! autocrlf=true):
//!
//! ```
//! error: 'src.ai_workflow.tui.http_handlers.git_status_test...
//!     test.git_status.zig: not-a-git-repo branch returns 200, not 500'
//!     failed:
//!        !! could not find `is_git_repo = false` response literal
//!        in src/http_handlers/git_status.zig !!
//! ```
//!
//! The literal IS in the file — but only with CRLF endings, so the
//! `"\n        };"` needle doesn't match.
//!
//! ## Fix
//!
//! The [`normalizeLineEndings`] helper replaces every `\r\n` with
//! `\n` in the source bytes before the test does its `indexOf`
//! matching. Tests call this in their `readSource` helper:
//!
//! ```zig
//! fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
//!     const raw = try std.Io.Dir.cwd().readFileAlloc(
//!         std.testing.io, path, allocator, .limited(256 * 1024),
//!     );
//!     return normalizeLineEndings(allocator, raw);
//! }
//! ```
//!
//! The returned buffer is always owned by the caller (allocated by
//! the helper) and must be freed by the caller. The input buffer is
//! not modified in place — pass `const`.
//!
//! ## Belt-and-suspenders
//!
//! This helper is the *runtime* fix. The *checkout-time* fix lives
//! in `.gitattributes` (which forces LF for every text file). Both
//! are needed:
//!
//!   - `.gitattributes` prevents the CRLF from appearing on fresh
//!     checkouts, but a contributor's editor or an existing CI
//!     cache can still produce CRLF.
//!   - The normalize helper makes the test work regardless.
//!
//! ## Performance
//!
//! Allocates a fresh buffer (no in-place edit) because the input
//! slice may have arbitrary contents (including no trailing NUL) and
//! in-place would require making the buffer larger than the input.
//! For 256 KB source files this is sub-millisecond.
//!
//! ## Where it's used
//!
//! Every static-contract test that does multi-line literal matching.
//! Examples that MUST use this helper:
//!
//!   - the inline tests at the bottom of `src/http_handlers/git_status.zig`
//!   - the inline tests in `src/modules/agent/tools/set_git_worktree.zig`
//!   - the inline tests in `src/http_handlers/kanban_*.zig`
//!   - any other static-contract test that uses `indexOf` on a multi-line
//!     literal against source bytes.
//!
//! ## When this bites
//!
//! Adding a new static-contract test that uses a multi-line needle.
//! The test passes on Linux/macOS (LF) and fails on Windows (CRLF)
//! with a misleading "literal not found" diagnostic. The fix is
//! one line: wrap the source bytes in `normalizeLineEndings` before
//! matching.
//!
//! Single-line needles are unaffected by this bug — `\n` is never
//! present in single-line literals.

const std = @import("std");

/// Replace every `\r\n` in `source` with `\n`. The returned buffer is
/// heap-allocated and owned by the caller; `source` is read-only.
///
/// Always returns the same length or shorter (CRLF → LF shrinks by
/// the number of `\r\n` pairs stripped; bare `\r` at EOF is preserved
/// as-is). If `source` has no `\r` bytes at all, returns a fresh
/// `dupe` (still owned by caller) so the caller's
/// `defer allocator.free(...)` pattern works uniformly.
pub fn normalizeLineEndings(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    // Count the `\r\n` pairs so we know exactly how much to allocate.
    // Bare `\r` (not followed by `\n`) is preserved — Mac Classic-era
    // files use bare `\r` as a line ending and we should not corrupt
    // them.
    var crlf_count: usize = 0;
    var i: usize = 0;
    while (i + 1 < source.len) {
        if (source[i] == '\r' and source[i + 1] == '\n') {
            crlf_count += 1;
            i += 2;
        } else {
            i += 1;
        }
    }

    // Fast path: no CRLF → just dupe. Caller still owns the result.
    if (crlf_count == 0) {
        return try allocator.dupe(u8, source);
    }

    // Output is shorter by `crlf_count` bytes (one `\r` removed per
    // CRLF pair; the `\n` stays). Bare `\r` adds back its own byte.
    const out = try allocator.alloc(u8, source.len - crlf_count);
    errdefer allocator.free(out);

    var dst: usize = 0;
    var j: usize = 0;
    while (j < source.len) {
        if (j + 1 < source.len and source[j] == '\r' and source[j + 1] == '\n') {
            out[dst] = '\n';
            j += 2;
            dst += 1;
        } else {
            out[dst] = source[j];
            j += 1;
            dst += 1;
        }
    }

    return out[0..dst];
}

// ─── The impl/tests boundary ───────────────────────────────────────────────

/// The first marker a test suite carries once it is merged into its
/// implementation file. Must stay byte-identical to the marker the 2026-09-29
/// flatten writes (`// ===== Tests merged from <file> (YYYY-MM-DD flatten) =====`).
pub const merged_tests_marker = "// ===== Tests merged from";

/// Slice a source file down to its IMPLEMENTATION half: everything before the
/// first `merged_tests_marker`.
///
/// A static-contract test greps its own file's source for a needle. Before the
/// tests moved inline that was safe, because the needles lived only in the
/// impl. After the merge the test is physically inside the file it greps, so
/// every "this must NOT appear" / "this must appear exactly once" assertion
/// finds its own source and passes or fails for the wrong reason. Slicing at
/// the marker restores "the impl, without its tests".
///
/// The returned buffer is heap-allocated and owned by the caller; `source` is
/// read-only. A file with no marker comes back as a plain dupe, so callers can
/// use this unconditionally on any source file.
pub fn implementationOnly(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const end = std.mem.indexOf(u8, source, merged_tests_marker) orelse source.len;
    return try allocator.dupe(u8, source[0..end]);
}


// ─── Tests for the helper itself ────────────────────────────────────────────

test "normalizeLineEndings: LF input unchanged" {
    const allocator = std.testing.allocator;
    const input = "line one\nline two\nline three\n";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "normalizeLineEndings: CRLF input → LF output" {
    const allocator = std.testing.allocator;
    const input = "line one\r\nline two\r\nline three\r\n";
    const expected = "line one\nline two\nline three\n";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
    // Length must shrink by exactly 3 (one \r per CRLF).
    try std.testing.expectEqual(@as(usize, expected.len), result.len);
}

test "normalizeLineEndings: mixed endings" {
    const allocator = std.testing.allocator;
    // 2 CRLF + 1 LF + 1 bare CR + 1 LF
    const input = "a\r\nb\nc\rd\n";
    const expected = "a\nb\nc\rd\n";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "normalizeLineEndings: empty input" {
    const allocator = std.testing.allocator;
    const result = try normalizeLineEndings(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "normalizeLineEndings: trailing \\r without following \\n" {
    // Stray \r at end of file (some Mac Classic-era files have this).
    // Should be preserved as-is.
    const allocator = std.testing.allocator;
    const input = "hello\r";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello\r", result);
    try std.testing.expectEqual(@as(usize, 6), result.len);
}

test "normalizeLineEndings: lone \\n (Unix) and \\r\\n (Windows) coexist" {
    const allocator = std.testing.allocator;
    const input = "before\r\nmiddle\nafter\r\n";
    const expected = "before\nmiddle\nafter\n";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "implementationOnly: file with no marker is returned whole" {
    const allocator = std.testing.allocator;
    const input = "pub fn a() void {}\n";
    const result = try implementationOnly(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "implementationOnly: truncates at the first merged-tests marker" {
    const allocator = std.testing.allocator;
    const input =
        "pub fn a() void {}\n" ++
        merged_tests_marker ++
        " x_test.zig (2026-09-29 flatten) =====\n" ++
        "test \"a still calls a\" { _ = a; }\n" ++
        merged_tests_marker ++
        " y_test.zig (2026-09-29 flatten) =====\n" ++
        "test \"b\" {}\n";
    const result = try implementationOnly(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("pub fn a() void {}\n", result);
}

test "implementationOnly: the test half is what it removes" {
    const allocator = std.testing.allocator;
    const input =
        "pub fn a() void {}\n" ++
        merged_tests_marker ++
        " x_test.zig (2026-09-29 flatten) =====\n" ++
        "const needle = \"needle\";\n";
    const result = try implementationOnly(allocator, input);
    defer allocator.free(result);
    // The point of the helper: a needle that only appears in the test half
    // must NOT be findable in the sliced result.
    try std.testing.expect(std.mem.indexOf(u8, result, "needle") == null);
}
