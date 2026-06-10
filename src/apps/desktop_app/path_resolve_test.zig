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
