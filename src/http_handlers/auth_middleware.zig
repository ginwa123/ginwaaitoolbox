//! Auth enforcement middleware for opt-in `--auth` mode.
//!
//! Wired via `router.group("/api")` + `use()` in main.zig (see the
//! kabelweb `MiddlewareFn` / `MiddlewareChain` docs in
//! `src/server/router.zig`). Short-circuits with 401 when the request
//! has no valid `nalar_session` cookie; otherwise calls `chain.next`.
//!
//! Gaps covered elsewhere (kabelweb `sse()`/`ws()` do not run
//! middleware, static fallback bypasses the router):
//!   - ws/sse handlers call `auth_common.lookupSession` directly.
//!   - `staticDirHandler` in main.zig serves index.html for `/app/*`
//!     when unauthenticated so the Vue router can show `/login`.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const auth_common = @import("auth_common.zig");

/// Shared gate used by both the middleware and the manual ws/sse/static
/// checks. Returns true when the request may proceed.
pub fn isAuthorized(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    auth_enabled: bool,
    path: []const u8,
    headers: anytype,
) bool {
    if (!auth_enabled) return true;
    if (auth_common.isAuthExempt(path)) return true;
    const tok = auth_common.parseSessionToken(headers) orelse return false;
    const sess = auth_common.lookupSession(allocator, db, tok) orelse return false;
    auth_common.freeSessionLookup(allocator, sess);
    return true;
}

pub fn authMiddleware(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    chain: *gserverz.Router.MiddlewareChain,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = nalarcore.getSingleton() catch {
        // No singleton in unit tests — fail open so handler tests
        // that construct their own ctx keep working.
        return chain.next(ctx, req, res);
    };
    if (!di.auth_enabled) return chain.next(ctx, req, res);
    if (auth_common.isAuthExempt(req.path)) return chain.next(ctx, req, res);
    const tok = auth_common.parseSessionToken(req.headers) orelse {
        return res.jsonResponse(.{
            .status_code = 401,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unauthenticated" }),
        });
    };
    const sess = auth_common.lookupSession(allocator, di.db, tok) orelse {
        return res.jsonResponse(.{
            .status_code = 401,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unauthenticated" }),
        });
    };
    auth_common.freeSessionLookup(allocator, sess);
    return chain.next(ctx, req, res);
}

test "isAuthorized passes through when auth disabled" {
    // No DB needed: disabled short-circuits before any lookup.
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(isAuthorized(std.testing.allocator, undefined, false, "/api/workspaces", m));
}

test "isAuthorized exempts login/health when enabled" {
    var m = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(isAuthorized(std.testing.allocator, undefined, true, "/api/auth/login", m));
    try std.testing.expect(isAuthorized(std.testing.allocator, undefined, true, "/health", m));
    try std.testing.expect(!isAuthorized(std.testing.allocator, undefined, true, "/api/workspaces", m));
}
