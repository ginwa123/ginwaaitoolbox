//! `GET /api/web/status` — browser-mode (web launch) status.
//!
//! Plan: docs/superpowers/plans/2026-09-10-web-launch-toggle.md
//! Task: task_1789052626064_0
//!
//! Lifecycle A: the server keeps running regardless of the flag. The
//! `web_launch_enabled` flag only controls whether the settings UI
//! advertises + auto-opens the browser URL — there is no server-side
//! start/stop action, so this endpoint is read-only (no body, no
//! mutation). The reported port is the LIVE bound port
//! (`di.server.address.port`), which is the explicit `--port`, the
//! 8081 default, or a random pick from `--port 0` resolution.
//!
//! Response: 200 `{"enabled":bool,"running":true,
//!             "url":"http://127.0.0.1:<port>/","port":<port>}`
//! Loopback-only by construction — the server never binds 0.0.0.0 in
//! production, so the URL is only reachable from this machine.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;

/// Build the browser-mode URL for `port`. Pure (no singleton) so it is
/// unit-testable without a live server.
pub fn buildWebUrl(allocator: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/", .{port});
}

pub fn webStatusHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    const cfg = pabrikcore.getLlmConfig(di);
    const port: u16 = di.server.address.port;

    const url = try buildWebUrl(allocator, port);
    const data = try std.fmt.allocPrint(
        allocator,
        "{{\"enabled\":{s},\"running\":true,\"url\":\"{s}\",\"port\":{d}}}",
        .{ if (cfg.web_launch_enabled) "true" else "false", url, port },
    );
    return res.jsonResponse(.{ .status_code = 200, .data = data });
}

test "web_status: buildWebUrl formats the loopback URL" {
    const allocator = std.testing.allocator;
    const url = try buildWebUrl(allocator, 8081);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:8081/", url);
}

test "web_status: buildWebUrl works for a random-range port" {
    const allocator = std.testing.allocator;
    const url = try buildWebUrl(allocator, 51234);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:51234/", url);
}

// ---------------------------------------------------------------------------
// Static contracts (repo convention: lock registration + wire shape by
// grepping source — see pabrik_config_put_test.zig "registered in
// test_runner.zig").
// ---------------------------------------------------------------------------

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(std.testing.io, &buf);
    return reader.interface.allocRemaining(allocator, .limited(128 * 1024));
}

test "web_status: handler is registered in test_runner.zig" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, "src/ai_workflow/tui/test_runner.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "http_handlers/web_status.zig") == null) {
        std.debug.print("!! test_runner.zig does not import http_handlers/web_status.zig !!\n", .{});
        return error.TestRunnerMissingWebStatus;
    }
}

test "web_status: GET /api/web/status route is registered in main.zig" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, "src/http_routes.zig");
    defer allocator.free(source);
    if (std.mem.indexOf(u8, source, "\"/api/web/status\"") == null) {
        std.debug.print("!! http_routes.zig does not register GET /api/web/status !!\n", .{});
        return error.RouteMissingWebStatus;
    }
    if (std.mem.indexOf(u8, source, "webStatusHandler") == null) {
        std.debug.print("!! http_routes.zig does not wire webStatusHandler !!\n", .{});
        return error.HandlerMissingWebStatus;
    }
}
