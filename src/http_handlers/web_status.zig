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
const auth_common = @import("auth_common.zig");
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
    const allocator = ctx.allocator;

    const di = try pabrikcore.getSingleton();
    // `web_launch_enabled` is a per-user setting under `--auth`; resolve it
    // through the one config-resolution module and fall back to the
    // singleton when the database is not authoritative.
    const cfg = auth_common.requestUserConfig(allocator, di.db, di.auth_enabled, req.headers) orelse
        pabrikcore.getLlmConfig(di);
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
