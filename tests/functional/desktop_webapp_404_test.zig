// Functional tests for the desktop `--static-dir` 404 bug.
//
// Zig port of `tests/functional/desktop_webapp_404_test.py` (same test
// names, same order).
//
// Task: task_1789144501374_7 — "first time open desktop app work but,
// after a while use and close and open again its 404".
//
// Reported symptoms were a blank window showing a bare `404 Not Found`
// page.
//
// Root cause (reproduced live): the desktop extracted its embedded
// webapp into a PER-PID temp dir, spawned a DETACHED pabrik with
// `--static-dir <that dir>`, and then deleted the dir when the window
// closed (`extraction.cleanup`). The daemon outlives the desktop by
// design, so from then on it served nothing: `GET /health` was still 200
// (an API route, independent of the static dir) while `GET /` was `404
// Not Found`. The next desktop launch probed `/health`, saw 200,
// attached to that daemon, and opened the webview onto the 404.
//
// These tests pin the wire behaviour that made the bug invisible to a
// health-only check, using a real pabrik process against a real
// --static-dir:
//
//   Test 1 — `--static-dir` serves the app; deleting the dir behind
//           pabrik's back turns `GET /` into 404 while `/health` stays
//           200 (this IS the bug), and restoring the dir makes `/`
//           serve again.
//   Test 2 — the fix's invariant: a PERSISTENT static dir survives a
//            pabrik restart, so close-and-reopen keeps serving the app.
//   Test 3 — a pabrik started with NO `--static-dir` has the same shape
//            (health 200, `/` 404) — the shape the desktop must refuse to
//            attach to.
//
// The desktop-side counterpart (never attach to a server that 404s `/`)
// is locked down in `src/apps/desktop_app/attach_test.zig`; the
// persistence of the webapp dir itself in
// `src/apps/desktop_app/extraction_test.zig`.
//
// WHERE THE WEBAPP FIXTURE LIVES — `makeScratchDir`, NOT
// `std.testing.tmpDir`:
//
// pytest used `tmp_path`. `std.testing.tmpDir` is not its equivalent:
// it allocates under `<cwd>/.zig-cache/tmp/`, which for this package is
// INSIDE the git worktree. `harness.makeScratchDir` allocates under
// `<tmp>/pabrik-fix-…` instead — still under the OS temp root (so the
// harness's `isSafeTmp` gate still governs the delete), but carrying a
// prefix `reapOrphanTestPids` does NOT match, so the NEXT test's boot
// cannot delete this fixture mid-test.
//
// LIFO note on the defers: `gpa.free(scratch)` is registered FIRST so
// it runs LAST, after `cleanupExtraDir(scratch)` has finished reading
// the slice.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The stand-in app shell the desktop would have extracted.
const HTML = "<!DOCTYPE html><html><body>pabrik app shell</body></html>";

/// Write `contents` to the absolute `path`, creating/truncating it.
fn writeFileAt(path: []const u8, contents: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, contents);
}

/// Minimal stand-in for the extracted webapp dir.
///
/// `_make_webapp` in Python: create `assets/`, write `index.html`, the
/// `.pabrik-webapp-complete` marker that always sits next to the
/// assets, and `assets/app.js`. Called TWICE in Test 1 — once to build
/// the fixture, once to restore it after the deliberate delete — which
/// is why it must be idempotent about an existing directory
/// (`createDirPath` on an existing dir is not an error).
fn makeWebapp(root: []const u8) !void {
    const assets = try std.fs.path.join(gpa, &.{ root, "assets" });
    defer gpa.free(assets);
    try std.Io.Dir.cwd().createDirPath(io, assets);

    {
        const p = try std.fs.path.join(gpa, &.{ root, "index.html" });
        defer gpa.free(p);
        try writeFileAt(p, HTML);
    }
    {
        const p = try std.fs.path.join(gpa, &.{ root, ".pabrik-webapp-complete" });
        defer gpa.free(p);
        try writeFileAt(p, "test-hash");
    }
    {
        const p = try std.fs.path.join(gpa, &.{ assets, "app.js" });
        defer gpa.free(p);
        try writeFileAt(p, "console.log('pabrik');");
    }
}

/// True when `/` returns the SPA shell — the desktop's readiness test.
///
/// Python `h_serves_app`: `GET /` accepting `(200, 404)`, then
/// `status == 200 and "<" in body`. The `expect` set must include 404
/// because the assertion is "it answered at all, and the answer was the
/// app", not "it answered 200".
fn servesApp(h: *Harness) !bool {
    var r = try h.http(io, .GET, "/", .{ .expect = &.{ 200, 404 } });
    defer r.deinit();
    return r.status == 200 and std.mem.indexOf(u8, r.text(), "<") != null;
}

// The bug, at the wire level.
//
// A daemon whose --static-dir was removed keeps answering /health with
// 200 while answering / with 404. That asymmetry is why the old
// health-only attach probe let the desktop open a 404 window.
test "static_dir_404s_when_the_dir_is_deleted_health_stays_200" {
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    // DEFER ORDER IS LIFO: `free` is registered first so it runs LAST.
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const webapp_dir = try std.fs.path.join(gpa, &.{ scratch, "desktop-webapp" });
    defer gpa.free(webapp_dir);
    try makeWebapp(webapp_dir);

    // `extra_args` borrows, so the argv slice must outlive the boot.
    const args = [_][]const u8{ "--static-dir", webapp_dir };

    var h = try Harness.boot(io, gpa, .{
        .stub_llm_profile = true,
        .extra_args = &args,
    });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // 1. Healthy and serving the app.
    {
        var r = try h.http(io, .GET, "/", .{});
        defer r.deinit();
        if (std.mem.indexOf(u8, r.text(), "pabrik app shell") == null) {
            std.debug.print("GET / did not serve the app shell: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try h.http(io, .GET, "/index.html", .{});
        defer r.deinit();
    }
    {
        var r = try h.http(io, .GET, "/assets/app.js", .{});
        defer r.deinit();
    }
    {
        var r = try h.http(io, .GET, "/health", .{});
        defer r.deinit();
    }

    // 2. Delete the directory out from under the running daemon. This
    //    is exactly what the old desktop did at window close.
    std.Io.Dir.cwd().deleteTree(io, webapp_dir) catch |err| {
        std.debug.print("could not delete the static dir: {s}\n", .{@errorName(err)});
        return err;
    };

    // 3. The app is gone...
    {
        var r = try h.http(io, .GET, "/", .{ .expect = &.{404} });
        defer r.deinit();
        if (std.mem.indexOf(u8, r.text(), "Not Found") == null) {
            std.debug.print("expected a Not Found body, got: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
    {
        var r = try h.http(io, .GET, "/index.html", .{ .expect = &.{404} });
        defer r.deinit();
    }

    // ...but health still says everything is fine. This is the trap.
    {
        var r = try h.http(io, .GET, "/health", .{});
        defer r.deinit();
    }

    // 4. Restoring the dir restores the app (proving the daemon itself
    //    never died — only its static dir went away).
    try makeWebapp(webapp_dir);
    {
        var r = try h.http(io, .GET, "/", .{});
        defer r.deinit();
        if (std.mem.indexOf(u8, r.text(), "pabrik app shell") == null) {
            std.debug.print("GET / after restore did not serve the app shell: {s}\n", .{r.body});
            return error.TestUnexpectedResult;
        }
    }
}

// The fix's invariant: reopening the app keeps serving it.
//
// Models two desktop launches against the same persistent webapp dir —
// the dir is never deleted, so the second launch's webview gets the app
// instead of `404 Not Found`.
test "persistent_static_dir_survives_a_restart" {
    try harness.requirePabrikBin(io, gpa);

    const scratch = try harness.makeScratchDir(gpa);
    defer gpa.free(scratch);
    defer harness.cleanupExtraDir(io, gpa, scratch);

    const webapp_dir = try std.fs.path.join(gpa, &.{ scratch, "desktop-webapp" });
    defer gpa.free(webapp_dir);
    try makeWebapp(webapp_dir);

    const args = [_][]const u8{ "--static-dir", webapp_dir };

    // Each launch gets its OWN block so its `defer` tears the harness
    // down before the next one boots — two live `pabrik` children would
    // otherwise be racing for the same tempdir.
    {
        var first = try Harness.boot(io, gpa, .{
            .stub_llm_profile = true,
            .extra_args = &args,
        });
        defer first.deinit(io) catch |err| {
            std.debug.print("teardown: {s}\n", .{@errorName(err)});
        };
        if (!try servesApp(&first)) return error.TestUnexpectedResult;
    }

    // Close/reopen: the dir must still be there, untouched.
    {
        const index = try std.fs.path.join(gpa, &.{ webapp_dir, "index.html" });
        defer gpa.free(index);
        std.Io.Dir.cwd().access(io, index, .{}) catch {
            std.debug.print("index.html vanished across the restart: {s}\n", .{index});
            return error.TestUnexpectedResult;
        };
    }

    {
        var second = try Harness.boot(io, gpa, .{
            .stub_llm_profile = true,
            .extra_args = &args,
        });
        defer second.deinit(io) catch |err| {
            std.debug.print("teardown: {s}\n", .{@errorName(err)});
        };
        if (!try servesApp(&second)) return error.TestUnexpectedResult;
    }
}

// A pabrik with no --static-dir looks identical to the broken daemon.
//
// Nothing about `/health` distinguishes it, so an attach decision based
// on health alone cannot tell a usable server from a useless one.
test "without_static_dir_health_is_200_but_root_is_404" {
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    {
        var r = try h.http(io, .GET, "/health", .{});
        defer r.deinit();
    }
    var r = try h.http(io, .GET, "/", .{ .expect = &.{404} });
    defer r.deinit();
    if (std.mem.indexOf(u8, r.text(), "Not Found") == null) {
        std.debug.print("expected a Not Found body, got: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    }
}
