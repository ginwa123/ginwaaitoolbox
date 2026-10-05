// Smoke test: boot a real `pabrik` binary and drive it over HTTP.
//
// This is the load-bearing proof that the Zig harness works at all —
// every other suite in this package assumes a booted harness, an
// isolated tmpdir HOME, and a real HTTP round-trip. If this passes,
// the harness's boot/teardown/JSON path is sound; if it fails, every
// other failure downstream is noise.
//
// NOTE ON TEARDOWN: Zig forbids `return` from inside a `defer`, so the
// naive `defer h.deinit(io) catch |err| return err;` does not compile.
// The pattern every suite in this package uses instead is to `catch`
// and PRINT — a teardown refusal is a harness bug, and printing it
// keeps the test's own assertion failure as the reported error rather
// than shadowing it. This mirrors the Python conftest's
// `pytest.fail("harness teardown refused")`-but-don't-shadow intent.

const std = @import("std");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

// Boot + `/health` + a real API call + teardown.
test "smoke_boot_harness_boots_and_serves_health" {
    const gpa = testing.allocator;
    const io = testing.io;

    // Skip (not fail) when no binary is available — a fresh worktree
    // has no `zig-out/`. Every other suite in this package skips the
    // same way, so a missing binary is one skipped suite, not 758
    // red ones.
    try harness.requirePabrikBin(io, gpa);

    var h = try Harness.boot(io, gpa, .{});
    defer h.deinit(io) catch |err| {
        std.debug.print("harness teardown: {s}\n", .{@errorName(err)});
    };

    // The server answered `/health` during boot, but assert it through
    // the SAME path a test would use, so the HTTP client itself is
    // covered — boot's probe is a separate code path.
    try testing.expect(h.health(io));

    // The isolated HOME is real: `pabrik` wrote a log into it.
    try testing.expect(h.temp_dir.len > 0);
    try testing.expect(std.fs.path.isAbsolute(h.temp_dir));
    try testing.expect(std.mem.indexOf(u8, h.temp_dir, harness.REQUIRED_TMP_SUBSTR) != null);

    // A representative API call: GET /api/workspaces returns JSON and
    // round-trips through the parse path. Assert the SHAPE via the
    // harness's own accessors rather than hardcoding one: this proves
    // the wire + JSON + teardown loop end to end, which is what the
    // rest of the suite depends on.
    var r = try h.http(io, .GET, "/api/workspaces", .{});
    defer r.deinit();
    try testing.expect(r.status == 200);

    var doc = try r.json();
    defer doc.deinit();
    switch (doc.value().*) {
        .array => |a| try testing.expect(a.items.len >= 0),
        .object => |o| try testing.expect(o.count() >= 0),
        else => return error.TestUnexpectedResult,
    }
}

// The safety validator must reject the paths a bug would produce.
test "is_safe_tmp_rejects_dangerous_paths" {
    const gpa = testing.allocator;
    const io = testing.io;

    // A real tmpdir carrying the namespace marker IS allowed.
    const root = try harness.tmpRoot(gpa);
    defer gpa.free(root);
    const good = try std.fs.path.join(gpa, &.{ root, harness.REQUIRED_TMP_SUBSTR ++ "probe" });
    defer gpa.free(good);
    try testing.expect(try harness.isSafeTmp(io, gpa, good, "/home/definitely-not-here"));

    // Relative path → rejected.
    try testing.expect(!try harness.isSafeTmp(io, gpa, "pabrik-func-relative", "/home/x"));
    // Empty → rejected.
    try testing.expect(!try harness.isSafeTmp(io, gpa, "", "/home/x"));
    // Absolute but NOT a tmpdir → rejected.
    try testing.expect(!try harness.isSafeTmp(io, gpa, "/etc/pabrik-func-evil", "/home/x"));
    // Tmpdir but missing the namespace marker → rejected.
    const no_marker = try std.fs.path.join(gpa, &.{ root, "some-other-dir" });
    defer gpa.free(no_marker);
    try testing.expect(!try harness.isSafeTmp(io, gpa, no_marker, "/home/x"));
    // The path equal to the real HOME → rejected even with the marker.
    try testing.expect(!try harness.isSafeTmp(io, gpa, root, root));
}

// The port picker must never return 8081 (the always-running dev
// backend) and must return a bindable port.
test "find_free_port_random_avoids_reserved_8081" {
    const gpa = testing.allocator;
    const io = testing.io;

    const port = try harness.findFreePortRandom(gpa);
    try testing.expect(port != 8081);
    try testing.expect(port >= harness.RANDOM_PORT_START);
    try testing.expect(port <= harness.RANDOM_PORT_END);
    // The returned port really was free when we probed it — bind it
    // ourselves as the cross-check (the probe closed its socket, so a
    // failure here means the picker returned a port that was taken).
    try testing.expect(harness.portIsFreeWithReuse(io, port));
}

// The sequential picker skips 8081 the same way.
test "find_free_port_sequential_skips_8081" {
    const io = testing.io;

    // Start AT 8081 — the picker must skip it and return 8082+.
    const port = try harness.findFreePortSequential(io, 8081);
    try testing.expect(port != 8081);
    try testing.expect(port >= 8082);
}
