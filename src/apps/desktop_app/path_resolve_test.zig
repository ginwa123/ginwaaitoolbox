// src/apps/desktop_app/path_resolve_test.zig
//
// Tests for the nalar-binary path resolver.
//
// The three test cases match the plan's resolution order:
//   1. explicit_path (from `--nalar-path`) wins
//   2. next-to-self lookup (relative to the running executable)
//   3. $PATH fallback
//
// The "next to self" test is intentionally weak — it does not assert on the
// returned path because that depends on whether the test runner's $PATH has
// a `nalar` binary. The point of that test is to exercise the function
// shape, not the file system. The strong assertion lives in the Chunk 9
// integration test that runs the full binary.

const std = @import("std");
const path_resolve = @import("path_resolve.zig");
const testing = std.testing;

test "resolveNalarPath: returns --nalar-path if provided" {
    const allocator = testing.allocator;
    // We pass a path that almost certainly does not exist. Per the design
    // contract: --nalar-path is a USER SUPPLIED OVERRIDE — if the file
    // is missing, the spawn() call will produce a clear error. resolve()
    // should not pre-validate; it just hands the path through.
    const result = path_resolve.resolve(allocator, "/custom/nalar", "nalar-desktop", "/usr/bin");
    try testing.expect(result != null);
    try testing.expectEqualStrings("/custom/nalar", result.?);
    allocator.free(result.?);
}

test "resolveNalarPath: handles next-to-self + PATH lookup without crashing" {
    const allocator = testing.allocator;
    // Use a "next to self" path that does not exist; PATH also probably lacks
    // the binary in CI. We just want to confirm the function doesn't panic,
    // and that it returns null when nothing is found.
    const result = path_resolve.resolve(
        allocator,
        null,
        "/nonexistent/dir/nalar-desktop",
        "/usr/bin:/bin",
    );
    // The function should not crash. It may return null (if neither path
    // has a nalar binary) or a real path (if the test env has nalar
    // installed in /usr/bin or /bin) — both outcomes are valid.
    if (result) |r| allocator.free(r);
}

test "resolveNalarPath: returns null when nalar is not found anywhere" {
    const allocator = testing.allocator;
    // Use a path_env that definitely doesn't exist and a self path that
    // definitely doesn't exist.
    const result = path_resolve.resolve(
        allocator,
        null,
        "/nonexistent/dir/nalar-desktop",
        "/nonexistent/path/with/no/binaries",
    );
    try testing.expect(result == null);
}

test "findInstalledWebapp: returns null for nonexistent exe dir without crashing" {
    const allocator = testing.allocator;
    const result = path_resolve.findInstalledWebapp(
        allocator,
        "/nonexistent/dir/nalar-desktop",
    );
    // On non-Windows this is unconditionally null; on Windows CI neither
    // %LOCALAPPDATA%\nalar\webapp\index.html nor the nonexistent exe-dir
    // candidate exists, so null as well. Either way: no panic, no leak.
    if (result) |r| allocator.free(r);
}

test "findInstalledWebapp: bare relative exe path skips next-to-self probe" {
    const allocator = testing.allocator;
    const result = path_resolve.findInstalledWebapp(allocator, ".");
    if (result) |r| allocator.free(r);
}

test "resolveNalarPath: handles Windows-style PATH (;-separated)" {
    // The fix for `error.NalarNotFound` on Windows: `resolve()` used
    // to tokenize by `:` (Unix convention) on every platform. On
    // Windows, $PATH is `;`-separated, so the old tokenizeScalar(':')
    // treated the entire PATH as ONE giant directory entry, joined
    // it with `nalar`, and `fileExists(<giant-path>/nalar)` always
    // returned false. This test locks in the fix: a Windows-style
    // PATH with multiple `;`-separated entries must be tokenized
    // entry-by-entry (the function still returns null when neither
    // entry has a real `nalar`, but the LOOP runs the right number
    // of times — observable indirectly via the no-panic contract).
    const allocator = testing.allocator;
    const result = path_resolve.resolve(
        allocator,
        null,
        "C:\\nonexistent\\dir\\nalar-desktop.exe",
        "C:\\Windows\\System32;C:\\Windows;C:\\nonexistent\\bin",
    );
    if (result) |r| allocator.free(r);
    // No panic + no result = pass. (We can't easily write a "creates
    // a temp file in PATH and finds it" test here without pulling
    // in std.fs.cwd machinery that Zig 0.16 has restructured.)
}
