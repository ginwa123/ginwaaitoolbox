// Functional tests for the web-launch toggle (browser mode, random port).
//
// Zig port of `tests/functional/web_launch_toggle_test.py` (same test
// names, same order).
//
// Plan: docs/superpowers/plans/2026-09-10-web-launch-toggle.md
// Task: task_1789052626064_0
//
// Lifecycle A: the server keeps running regardless of the flag — the
// flag only drives the settings UI (URL pill + auto-open) and the
// startup port default (random when on, 8081 when off). Covered here:
//
//   Test 1 — GET defaults `web_launch_enabled=false` on a fresh install.
//   Test 2 — PUT true round-trips through GET + on-disk config.json.
//   Test 3 — PUT false flips an existing true.
//   Test 4 — Omitting the key on PUT preserves the on-disk value
//            (the `?bool = null` "don't touch" sentinel).
//   Test 5 — GET /api/web/status reports the live bound port + URL and
//            reflects the flag (false → true across a PUT).
//   Test 6 — Status URL is reachable (same origin serves the SPA).
//
// The harness boots pabrik on a random free port (never 8081), so Test 5
// locks in that the status endpoint reports the LIVE port, not a
// hardcoded default.
//
// WHY THE `config.json` READ IS PLATFORM-BRANCHED: the server resolves
// its config directory per-OS (Config.zig `getDefaultConfigDir`):
// `$XDG_CONFIG_HOME/pabrik` on Linux, `$HOME/Library/Application
// Support/pabrik` on macOS, `$APPDATA/pabrik` on Windows. The harness
// shadows all three inside its tempdir, so every branch resolves under
// `h.temp_dir` and the delete stays inside the gate.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const harness = @import("harness.zig");
const Harness = harness.Harness;

const gpa = testing.allocator;
const io = testing.io;

/// The config directory the running child will read and write, derived
/// from `h.temp_dir`. Owned; caller frees.
fn platformConfigDir(h: *Harness) ![]u8 {
    return switch (builtin.os.tag) {
        .macos => harness.harnessPath(gpa, h.temp_dir, &.{ "Library", "Application Support", "pabrik" }),
        .windows => harness.harnessPath(gpa, h.temp_dir, &.{ "AppData", "Roaming", "pabrik" }),
        else => harness.harnessPath(gpa, h.temp_dir, &.{ ".config", "pabrik" }),
    };
}

/// The owned, parsed `config.json` the server wrote on disk.
///
/// Python `_on_disk_config` returned `json.loads(path.read_text())`, so
/// the analogue is a `harness.Json` the caller must `deinit`.
fn onDiskConfig(h: *Harness) !harness.Json {
    const dir = try platformConfigDir(h);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "config.json" });
    defer gpa.free(path);

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        std.debug.print("could not read on-disk config at {s}: {s}\n", .{ path, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    defer gpa.free(raw);

    return harness.Json{
        .parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch |err| {
            std.debug.print("on-disk config is not JSON: {s}\n", .{@errorName(err)});
            return error.TestUnexpectedResult;
        },
    };
}

/// `PUT /api/config/pabrik` with the profiles scaffolding the backend
/// expects.
///
/// `web_launch_enabled == null` OMITS the key — that omission is the
/// assertion in Test 4, so it must stay an omission on the wire rather
/// than becoming an explicit `false` (which is a different request).
fn putWebLaunch(h: *Harness, web_launch_enabled: ?bool) !void {
    // A COMPILE-TIME literal, not a formatted string: `null` must put
    // NOTHING on the wire, and an empty string here is exactly that.
    const flag: []const u8 = if (web_launch_enabled) |b| switch (b) {
        true => ",\"web_launch_enabled\":true",
        false => ",\"web_launch_enabled\":false",
    } else "";

    const body = try std.fmt.allocPrint(
        gpa,
        "{{\"profiles\":{{\"stub\":{{\"model\":\"stub-model\",\"base_url\":\"http://127.0.0.1:1\",\"api_key\":\"stub-key-not-real\"}}}},\"active_profile\":\"stub\"{s}}}",
        .{flag},
    );
    defer gpa.free(body);

    var r = try h.http(io, .PUT, "/api/config/pabrik", .{ .json_body = body, .expect = &.{200} });
    defer r.deinit();
}

/// `GET /api/config/pabrik` + assert `web_launch_enabled == want`.
///
/// The Zig analogue of `assert r.get("web_launch_enabled") is False`
/// — identity against the JSON boolean, so a missing key or a string
/// `"false"` both FAIL rather than silently coercing.
fn expectWebLaunchFlag(h: *Harness, want: bool, context: []const u8) !void {
    var r = try h.http(io, .GET, "/api/config/pabrik", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const got = doc.boolean("web_launch_enabled") orelse {
        std.debug.print("{s}: no boolean `web_launch_enabled` in {s}\n", .{ context, r.body });
        return error.TestUnexpectedResult;
    };
    if (got != want) {
        std.debug.print("{s}: web_launch_enabled = {s}, expected {s}\n", .{
            context,
            if (got) "true" else "false",
            if (want) "true" else "false",
        });
        return error.TestUnexpectedResult;
    }
}

/// Boot the `web_harness` fixture: a harness with a stub LLM profile so
/// the binary starts without a real API key.
///
/// The macOS arm of the Python fixture copied `.config/pabrik/config.json`
/// to the macOS location when only the former existed, so the server
/// found a config where `getDefaultConfigDir` looks. `writeStubLlmProfile`
/// already writes all three locations, so the copy is belt-and-braces;
/// it is kept because removing it would silently change what the macOS
/// path is exercised against.
fn bootWebHarness() !Harness {
    var h = try Harness.boot(io, gpa, .{ .stub_llm_profile = true });
    errdefer h.deinit(io) catch {};

    if (builtin.os.tag == .macos) {
        const linux_cfg = try harness.harnessPath(gpa, h.temp_dir, &.{ ".config", "pabrik", "config.json" });
        defer gpa.free(linux_cfg);
        const linux_cfg_exists = blk: {
            std.Io.Dir.cwd().access(io, linux_cfg, .{}) catch break :blk false;
            break :blk true;
        };
        if (linux_cfg_exists) {
            const mac_dir = try harness.harnessPath(gpa, h.temp_dir, &.{ "Library", "Application Support", "pabrik" });
            defer gpa.free(mac_dir);
            std.Io.Dir.cwd().createDirPath(io, mac_dir) catch {};
            const mac_cfg = try std.fs.path.join(gpa, &.{ mac_dir, "config.json" });
            defer gpa.free(mac_cfg);
            const raw = std.Io.Dir.cwd().readFileAlloc(io, linux_cfg, gpa, .limited(1 << 20)) catch "";
            defer if (raw.len > 0) gpa.free(raw);
            if (raw.len > 0) {
                var f = std.Io.Dir.cwd().createFile(io, mac_cfg, .{}) catch {
                    return error.TestUnexpectedResult;
                };
                defer f.close(io);
                f.writeStreamingAll(io, raw) catch {
                    return error.TestUnexpectedResult;
                };
            }
        }
    }

    return h;
}

// GET returns web_launch_enabled=false on a fresh install.
test "get_returns_web_launch_disabled_on_fresh_install" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootWebHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try expectWebLaunchFlag(&h, false, "fresh install");
}

// PUT true round-trips through GET and through the on-disk config.
test "put_web_launch_true_round_trips_through_get_and_disk" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootWebHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try putWebLaunch(&h, true);
    try expectWebLaunchFlag(&h, true, "after PUT true");

    var disk = try onDiskConfig(&h);
    defer disk.deinit();
    const on_disk = disk.boolean("web_launch_enabled") orelse {
        std.debug.print("on-disk config has no boolean `web_launch_enabled`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (!on_disk) {
        std.debug.print("on-disk web_launch_enabled = false after PUT true\n", .{});
        return error.TestUnexpectedResult;
    }
}

// PUT false flips an existing true.
test "put_web_launch_false_flips_an_existing_true" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootWebHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try putWebLaunch(&h, true);
    try expectWebLaunchFlag(&h, true, "after PUT true");

    try putWebLaunch(&h, false);
    try expectWebLaunchFlag(&h, false, "after PUT false");

    var disk = try onDiskConfig(&h);
    defer disk.deinit();
    const on_disk = disk.boolean("web_launch_enabled") orelse {
        std.debug.print("on-disk config has no boolean `web_launch_enabled`\n", .{});
        return error.TestUnexpectedResult;
    };
    if (on_disk) {
        std.debug.print("on-disk web_launch_enabled = true after PUT false\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Omitting web_launch_enabled on PUT preserves the on-disk value.
test "omitting_web_launch_does_not_reset_it" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootWebHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    try putWebLaunch(&h, true);
    {
        var disk = try onDiskConfig(&h);
        defer disk.deinit();
        const on_disk = disk.boolean("web_launch_enabled") orelse {
            std.debug.print("on-disk config has no boolean `web_launch_enabled`\n", .{});
            return error.TestUnexpectedResult;
        };
        if (!on_disk) {
            std.debug.print("on-disk web_launch_enabled = false after PUT true\n", .{});
            return error.TestUnexpectedResult;
        }
    }

    // No flag at all — the key is absent from the request body.
    try putWebLaunch(&h, null);
    try expectWebLaunchFlag(&h, true, "after a PUT that omitted the flag");
}

// GET /api/web/status returns the harness's live random port (not a
// hardcoded 8081) and tracks the flag across a PUT.
test "web_status_reports_live_port_and_reflects_flag" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootWebHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    // Called twice — once before the PUT, once after — so it is a
    // function rather than an inline block.
    try expectWebStatus(&h, false);

    try putWebLaunch(&h, true);
    try expectWebStatus(&h, true);
}

/// Assert the four fields `GET /api/web/status` reports: running, the
/// flag, the LIVE port, and the URL derived from that same port.
fn expectWebStatus(h: *Harness, want_enabled: bool) !void {
    var r = try h.http(io, .GET, "/api/web/status", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const running = doc.boolean("running") orelse {
        std.debug.print("web/status has no boolean `running`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!running) {
        std.debug.print("web/status reported running=false\n", .{});
        return error.TestUnexpectedResult;
    }

    const enabled = doc.boolean("enabled") orelse {
        std.debug.print("web/status has no boolean `enabled`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (enabled != want_enabled) {
        std.debug.print("web/status enabled = {s}, expected {s}\n", .{
            if (enabled) "true" else "false",
            if (want_enabled) "true" else "false",
        });
        return error.TestUnexpectedResult;
    }

    const port = doc.int("port") orelse {
        std.debug.print("web/status has no integer `port`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (port != h.port) {
        std.debug.print("status port = {d}, expected the live bound port {d}\n", .{ port, h.port });
        return error.TestUnexpectedResult;
    }

    const want_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{h.port});
    defer gpa.free(want_url);
    const url = doc.str("url") orelse {
        std.debug.print("web/status has no `url`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, url, want_url)) {
        std.debug.print("status url = \"{s}\", expected \"{s}\"\n", .{ url, want_url });
        return error.TestUnexpectedResult;
    }
}

// The advertised URL origin is actually reachable (lifecycle A: the
// same server serves the UI — no second listener needed). Note: `/`
// itself 404s without `--static-dir` (the harness boots API-only), so we
// assert on `/health`, which proves the origin is live.
test "web_status_url_serves_http" {
    try harness.requirePabrikBin(io, gpa);

    var h = try bootWebHarness();
    defer h.deinit(io) catch |err| {
        std.debug.print("teardown: {s}\n", .{@errorName(err)});
    };

    var r = try h.http(io, .GET, "/api/web/status", .{ .expect = &.{200} });
    defer r.deinit();
    var doc = try r.json();
    defer doc.deinit();

    const url = doc.str("url") orelse {
        std.debug.print("web/status has no `url`: {s}\n", .{r.body});
        return error.TestUnexpectedResult;
    };
    // `urllib.parse.urljoin(url, "/health")` — the status url always
    // ends in `/`, so trimming it and re-appending `"/health"` is the
    // same string. Dropping the separator instead would yield
    // `http://127.0.0.1:23456health`, which `std.Uri.parse` rejects with
    // `InvalidPort` (the port becomes `23456health`).
    const health_url = try std.fmt.allocPrint(gpa, "{s}/health", .{std.mem.trimEnd(u8, url, "/")});
    defer gpa.free(health_url);

    // A FRESH `std.http.Client`, not the harness's pooled one: Python
    // used `urllib.request.urlopen`, i.e. a new connection, so that the
    // origin is proven live independently of whatever the harness
    // client already has open.
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = try client.request(.GET, try std.Uri.parse(health_url), .{
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();
    try req.sendBodiless();
    var resp = try req.receiveHead(&.{});

    // Headers FIRST — `resp.reader()` invalidates them.
    const status: u16 = @intFromEnum(resp.head.status);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    _ = resp.reader(&.{}).streamRemaining(&sink.writer) catch {};

    if (status != 200) {
        std.debug.print("{s} returned {d}\n", .{ health_url, status });
        return error.TestUnexpectedResult;
    }
}
