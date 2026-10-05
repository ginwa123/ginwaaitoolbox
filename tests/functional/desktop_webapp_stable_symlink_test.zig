// Functional tests for the stable `--static-dir` alias (`<base>/current`).
//
// Zig port of `tests/functional/desktop_webapp_stable_symlink_test.py`
// (same test names, same order).
//
// The desktop materialises its embedded webapp into content-addressed
// `<base>/<hash>` dirs but hands the daemon a single stable symlink
// `<base>/current -> <hash>`, so `ps` always shows one path no matter how
// many versioned dirs sit behind the link.
//
// Wire behaviour pinned here (real pabrik, real --static-dir, isolated
// HOME):
//
//   Test 1 — serving THROUGH the stable symlink works: boot with
//            `--static-dir <base>/current`, `GET /` serves the app.
//   Test 2 — flipping the link (an upgrade) never 404s the running daemon:
//            it stays pinned to its boot version (the server canonicalizes
//            via realPath at startup), while a fresh boot on the same
//            stable string picks up the new version.
//
// WHERE THE FIXTURE LIVES: pytest's `tmp_path` is a SIBLING of the
// harness tempdir, so this port uses `harness.makeScratchDir` (the
// `pabrik-fix-` namespace) rather than writing versioned webapp dirs
// inside `temp_dir`. Two reasons, both documented on `makeScratchDir`:
// `reapOrphanTestPids` deletes any `pabrik-func-` tree whose pid is dead,
// and the fixture must outlive the SECOND harness boot in test 2 — which
// is exactly the window a reaper would use. The scratch dir is removed
// with `harness.cleanupExtraDir` on the way out.
//
// DEFER ORDER IS LIFO AND LOADS-BEARING, hence the deliberate
// step-by-step registration in each test:
//
//   free(scratch)   must run AFTER cleanupExtraDir(scratch)  → register free FIRST
//   h.deinit        must run BEFORE the fixture is deleted    → register LAST
//
// Registering the free before the reader segfaults inside `isSafeTmp`
// with a dangling pointer. There is deliberately no `errdefer` doing
// cleanup here: `return error.SkipZigTest` (the "this host has no
// symlink support" path) IS an error return, so an `errdefer` that
// freed the same buffers would double-free them alongside the `defer`.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;
const gpa = testing.allocator;
const io = testing.io;

// ============================================================================
// Helpers
// ============================================================================

/// The response body as text (the harness body is always valid UTF-8 —
/// HTTP bodies here are text or base64, never raw binary).
fn text(r: *const harness.Response) []const u8 {
    return r.text();
}

/// Minimal stand-in for one versioned webapp dir.
///
/// Python took `(root, body)` and created `root/assets`, `root/index.html`
/// and `root/assets/app.js`. The Zig version takes the ALREADY-JOINED
/// absolute path so the caller owns (and frees) the path.
fn makeVersion(root: []const u8, body: []const u8) !void {
    const assets = try std.fs.path.join(gpa, &.{ root, "assets" });
    defer gpa.free(assets);
    try std.Io.Dir.cwd().createDirPath(io, assets);

    const index = try std.fs.path.join(gpa, &.{ root, "index.html" });
    defer gpa.free(index);
    {
        const html = try std.fmt.allocPrint(
            gpa,
            "<!DOCTYPE html><html><body>{s}</body></html>",
            .{body},
        );
        defer gpa.free(html);
        var f = try std.Io.Dir.cwd().createFile(io, index, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, html);
    }

    const app_js = try std.fs.path.join(gpa, &.{ assets, "app.js" });
    defer gpa.free(app_js);
    var f = try std.Io.Dir.cwd().createFile(io, app_js, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "console.log('pabrik');");
}

/// Whether this host lets an unprivileged process create a symlink.
///
/// On Windows a symlink needs either Developer Mode or
/// `SeCreateSymbolicLinkPrivilege`. A GitHub `windows-2022` runner runs
/// the agent elevated, so it MAY work — which is exactly why this PROBES
/// instead of skipping on the OS: skipping would turn a platform that CAN
/// run the test into one that doesn't. A host that refuses reports an
/// error from `symLink` and the caller skips with the reason.
fn symlinkSupported(link_path: []const u8, target: []const u8) bool {
    const probe = std.fmt.allocPrint(gpa, "{s}.probe", .{link_path}) catch return false;
    defer gpa.free(probe);
    std.Io.Dir.cwd().symLink(io, target, probe, .{ .is_directory = true }) catch return false;
    std.Io.Dir.cwd().deleteFile(io, probe) catch {};
    return true;
}

/// Create the stable link `<base>/current` pointing at `target_name`
/// (a RELATIVE name, resolved inside `<base>` — the same shape the
/// desktop writes).
fn createLink(link_path: []const u8, target_name: []const u8) !void {
    try std.Io.Dir.cwd().symLink(io, target_name, link_path, .{ .is_directory = true });
}

/// Atomically point `link_path` at `target_name` (same dance as the
/// desktop's `extraction.zig`): create a uniquely-named sibling link,
/// then `rename` it over the stable one, so a reader never observes a
/// moment where `current` does not exist.
fn pointLink(link_path: []const u8, target_name: []const u8) !void {
    const tmp = try std.fmt.allocPrint(
        gpa,
        "{s}.tmp-{d}",
        .{ link_path, std.Thread.getCurrentId() },
    );
    defer gpa.free(tmp);

    std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try std.Io.Dir.cwd().symLink(io, target_name, tmp, .{ .is_directory = true });
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), link_path, io);
}

// ============================================================================
// Test 1
// ============================================================================

// Booting with `--static-dir <base>/current` serves the app.
test "stable_symlink_serves_the_app" {
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const base = try std.fs.path.join(gpa, &.{ scratch, "desktop-webapp" });
    defer gpa.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);

    const v1 = try std.fs.path.join(gpa, &.{ base, "hash-v1" });
    defer gpa.free(v1);
    const stable = try std.fs.path.join(gpa, &.{ base, "current" });
    defer gpa.free(stable);

    try makeVersion(v1, "stable shell v1");

    if (!symlinkSupported(stable, "hash-v1")) {
        std.debug.print(
            "this host cannot create a symlink; the product's stable-webapp layout requires one\n",
            .{},
        );
        return error.SkipZigTest;
    }
    try createLink(stable, "hash-v1");

    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .extra_args = &.{ "--static-dir", stable },
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try h.http(io, .GET, "/", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, text(&r), "stable shell v1") != null);
    }
    {
        var r = try h.http(io, .GET, "/health", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expectEqual(@as(u16, 200), r.status);
    }
}

// ============================================================================
// Test 2
// ============================================================================

// An upgrade flip keeps the old daemon on its boot version (no 404
// window), while a fresh boot on the same stable string gets the new one.
test "flipping_the_stable_link_never_404s_the_running_daemon" {
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const base = try std.fs.path.join(gpa, &.{ scratch, "desktop-webapp" });
    defer gpa.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);

    const v1 = try std.fs.path.join(gpa, &.{ base, "hash-v1" });
    defer gpa.free(v1);
    const v2 = try std.fs.path.join(gpa, &.{ base, "hash-v2" });
    defer gpa.free(v2);
    const stable = try std.fs.path.join(gpa, &.{ base, "current" });
    defer gpa.free(stable);

    try makeVersion(v1, "stable shell v1");
    try makeVersion(v2, "stable shell v2");

    if (!symlinkSupported(stable, "hash-v1")) {
        std.debug.print(
            "this host cannot create a symlink; the product's stable-webapp layout requires one\n",
            .{},
        );
        return error.SkipZigTest;
    }
    try createLink(stable, "hash-v1");

    var first = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .extra_args = &.{ "--static-dir", stable },
    });
    defer first.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try first.http(io, .GET, "/", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, text(&r), "stable shell v1") != null);
    }

    // Upgrade: flip the stable link. The running daemon stays pinned to
    // its boot version — critically, it must NOT 404 in between.
    try pointLink(stable, "hash-v2");
    {
        var r = try first.http(io, .GET, "/", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, text(&r), "stable shell v1") != null);
    }

    // A fresh boot on the SAME stable string picks up the new version.
    {
        var second = try Harness.boot(io, gpa, .{
            .stub_llm_profile = true,
            .extra_args = &.{ "--static-dir", stable },
        });
        defer second.deinit(io) catch |err| {
            std.debug.print("second teardown: {s}\n", .{@errorName(err)});
        };

        var r = try second.http(io, .GET, "/", .{ .expect = &.{200} });
        defer r.deinit();
        try testing.expect(std.mem.indexOf(u8, text(&r), "stable shell v2") != null);
    }
}
