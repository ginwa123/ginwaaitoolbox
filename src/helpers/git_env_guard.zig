//! Ambient git-environment guard for TEST fixtures.
//!
//! `git -C <fixture> ...` obeys GIT_DIR / GIT_WORK_TREE over `-C`. Under a
//! git hook (which exports both), every fixture `git commit` lands in the
//! REAL repository instead of the tmp fixture — on 2026-10-07 the pre-push
//! hook's own `zig build test` sprayed sixteen `init` commits onto a live
//! PR branch this way, and the follow-up push shipped them.
//!
//! Every test fixture that spawns git calls `requireCleanGitEnv()` before
//! its first spawn: under a dirty env the test errors loudly instead of
//! corrupting a real repo. The pre-push hook also unsets these vars, so the
//! suite is safe in both worlds (clean hook = green; dirty env = loud red,
//! never silent corruption).
//!
//! Production git probes (http_handlers/git_pr_status.zig useCase) still
//! inherit the environment — fixing those means passing an explicit
//! `environ_map`, tracked separately. This guard is test-only by design:
//! erroring in production would turn a working endpoint into a broken one.

const std = @import("std");
const builtin = @import("builtin");

/// Env vars that redirect git into a different repository / index / object
/// store than the `-C` path (or cwd) names. Any one of them set is enough
/// to misroute a fixture spawn.
pub const AMBIENT_GIT_ENV_VARS = [_][]const u8{
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_COMMON_DIR",
};

/// The first ambient redirect var that is set AND non-empty, or null when
/// the environment is clean. Empty values are ignored: git treats an empty
/// GIT_DIR the same as unset.
pub fn ambientGitEnvOverride() ?[]const u8 {
    for (AMBIENT_GIT_ENV_VARS) |name| {
        var buf: [64]u8 = undefined;
        if (name.len + 1 > buf.len) continue;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const zname: [*:0]const u8 = buf[0..name.len :0];
        if (std.c.getenv(zname)) |val| {
            if (val[0] != 0) return name;
        }
    }
    return null;
}

/// Refuse to spawn fixture git under a redirecting environment. Call this
/// before the FIRST git spawn in every test fixture; the returned error
/// fails the test loudly instead of committing into a real repository.
pub fn requireCleanGitEnv() error{AmbientGitEnvRedirect}!void {
    if (ambientGitEnvOverride()) |name| {
        std.debug.print("\n!! refusing to spawn fixture git: ambient {s} is set (unset it before running the suite; see helpers/git_env_guard.zig) !!\n", .{name});
        return error.AmbientGitEnvRedirect;
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────

test "AMBIENT_GIT_ENV_VARS names every git redirect variable" {
    // Pin the full set: dropping one re-opens the exact hole this guard
    // exists to close (GIT_DIR and GIT_WORK_TREE are the hook-exported
    // pair; the other three redirect the index / object store the same
    // way and must not be forgotten).
    const want = [_][]const u8{
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_COMMON_DIR",
    };
    try std.testing.expectEqual(want.len, AMBIENT_GIT_ENV_VARS.len);
    for (want) |name| {
        var found = false;
        for (AMBIENT_GIT_ENV_VARS) |have| {
            if (std.mem.eql(u8, have, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "ambientGitEnvOverride is null in a clean environment" {
    // The suite itself runs clean (the pre-push hook unsets these), so a
    // hit here means the runner leaked hook env into the test process —
    // exactly the condition that used to corrupt real repos silently.
    // This test failing LOUDLY is the point, not a flake.
    try std.testing.expect(ambientGitEnvOverride() == null);
}

// POSIX libc declarations for the round-trip test below. Windows UCRT has
// no setenv/unsetenv, so the behavioral test skips there (the guard
// itself is portable: getenv exists everywhere).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "ambientGitEnvOverride trips on a set redirect var and clears after unset" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // GIT_DIR is the hook-exported one and the exact var behind the
    // 2026-10-07 incident, so the round-trip uses it (not a throwaway).
    try std.testing.expect(setenv("GIT_DIR", "/tmp/probe-guard-test", 1) == 0);
    try std.testing.expectEqualStrings("GIT_DIR", ambientGitEnvOverride().?);
    try std.testing.expectError(error.AmbientGitEnvRedirect, requireCleanGitEnv());
    try std.testing.expect(unsetenv("GIT_DIR") == 0);
    try std.testing.expect(ambientGitEnvOverride() == null);
    try requireCleanGitEnv();
}
