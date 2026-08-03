const std = @import("std");
const http_parser = @import("http_parser.zig");

pub const Self = @This();

/// Handler fn: (ctx, request, response) -> anyerror!HttpResponse
/// `ctx` is `HttpContext` BY VALUE (the per-request execution context:
/// allocator + io + optional SSE client_id). HttpContext is a small
/// value (3 fields) — passing by value avoids a pointer indirection on
/// every handler call and matches the WebSocket handler convention.
/// `req` is `HttpRequest` **BY VALUE** — a shallow snapshot from the
/// post-route-match request. The cross-redirect session lives on
/// `req.session` (set by the listen loop) — handlers call
/// `req.session.set / getString / flushPending`, and the redirect
/// helper `res.redirectWith(req, loc)` reads `req.session.outgoing`
/// after the handler returns.
pub const HandlerFn = *const fn (
    ctx: http_parser.HttpContext,
    req: http_parser.HttpRequest,
    res: http_parser.HttpResponse,
) anyerror!http_parser.HttpResponse;

/// SSE streaming handler — same shape as `HandlerFn` plus the SSE-specific
/// `client_id` lives on `ctx.client_id` (set by the listen loop after
/// `sse_manager.registerClient`).
pub const SseHandlerFn = *const fn (
    ctx: http_parser.HttpContext,
    req: http_parser.HttpRequest,
    res: http_parser.HttpResponse,
) anyerror!http_parser.HttpResponse;

/// WebSocket handler.
///
/// Unlike SSE handlers, the WebSocket handler is invoked AFTER the
/// transport handshake has completed (the 101 response has already been
/// sent). The handler receives the parsed `HttpRequest` (so it can read
/// headers / query / params / session), the GinwaServer pointer (so
/// it can read frames and broadcast via the WsManager), the client fd,
/// and the client's 16-byte id (so it can send targeted messages or
/// remove the client early).
///
/// The handler runs in the same per-connection thread as the read loop
/// (the listen loop spawns the handler on the worker thread). When the
/// handler returns, the WebSocket close handshake is initiated and the
/// client is removed from the WsManager.
pub const WsHandlerFn = *const fn (
    ctx: http_parser.HttpContext,
    req: http_parser.HttpRequest,
    server: *anyopaque,
    client_fd: i32,
    client_id: *[16]u8,
) anyerror!void;

/// Route type to distinguish SSE from regular handlers
pub const RouteType = enum {
    regular,
    sse,
    websocket,
};

pub const Router = Self;

routes: std.ArrayListUnmanaged(Route) = .empty,
arena: std.mem.Allocator,

pub const Route = struct {
    method: []const u8 = "",
    path: []const u8 = "",
    handler: HandlerFn = defaultHandler,
    sse_handler: ?SseHandlerFn = null,
    ws_handler: ?WsHandlerFn = null,
    route_type: RouteType = .regular,
};

pub fn defaultHandler(_: http_parser.HttpContext, _: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
    return res.withBody("");
}

pub fn init(arena: std.mem.Allocator) Self {
    return .{
        .arena = arena,
        .routes = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.routes.deinit(self.arena);
}

/// Add a GET route with generic context support
pub fn get(self: *Self, path: []const u8, handler: anytype) !void {
    return self.addRouteInternal("GET", path, handler);
}

/// Add a POST route with generic context support
pub fn post(self: *Self, path: []const u8, handler: anytype) !void {
    return self.addRouteInternal("POST", path, handler);
}

/// Add a PUT route with generic context support
pub fn put(self: *Self, path: []const u8, handler: anytype) !void {
    return self.addRouteInternal("PUT", path, handler);
}

/// Add a DELETE route with generic context support
pub fn delete(self: *Self, path: []const u8, handler: anytype) !void {
    return self.addRouteInternal("DELETE", path, handler);
}

/// Add a PATCH route with generic context support
pub fn patch(self: *Self, path: []const u8, handler: anytype) !void {
    return self.addRouteInternal("PATCH", path, handler);
}

/// Add an SSE streaming route
pub fn sse(self: *Self, path: []const u8, handler: anytype) !void {
    try self.routes.append(self.arena, Route{
        .method = "GET",
        .path = path,
        .handler = undefined,
        .sse_handler = handler,
        .route_type = .sse,
    });
}

/// Add a WebSocket route. WebSocket routes are always GET (per RFC 6455 §4.1).
pub fn ws(self: *Self, path: []const u8, handler: anytype) !void {
    try self.routes.append(self.arena, Route{
        .method = "GET",
        .path = path,
        .handler = undefined,
        .ws_handler = handler,
        .route_type = .websocket,
    });
}

/// Generic internal route adder
fn addRouteInternal(self: *Self, method: []const u8, path: []const u8, handler: anytype) !void {
    try self.routes.append(self.arena, Route{
        .method = method,
        .path = path,
        .handler = handler,
        .route_type = .regular,
    });
}

/// Route matching result - handler + contexts needed to execute it
pub const RouteResult = union(enum) {
    handler: struct {
        handler: HandlerFn,
        ctx: http_parser.HttpContext,
        req: http_parser.HttpRequest,
        res: http_parser.HttpResponse,
    },
    sse: struct {
        handler: SseHandlerFn,
        ctx: http_parser.HttpContext,
        req: http_parser.HttpRequest,
    },
    websocket: struct {
        handler: WsHandlerFn,
        ctx: http_parser.HttpContext,
        req: http_parser.HttpRequest,
    },
};

/// Route matching and execution - returns handler to execute.
///
/// `req` is `*HttpRequest` (mutated to populate `req.params` from
/// `:name` patterns); the returned `RouteResult` carries a snapshot
/// value-copy of req with the populated params. The session pointer
/// is already inside the request (`req.session`), so no separate
/// session arg is needed. `ctx` is the per-request allocator + io
/// (passed BY VALUE; HttpContext is a small 3-field struct).
pub fn matchRoute(
    self: *Self,
    req_method: []const u8,
    req_path: []const u8,
    req: *http_parser.HttpRequest,
    ctx: http_parser.HttpContext,
) ?RouteResult {
    for (self.routes.items) |route| {
        // Try exact match first
        if (std.mem.eql(u8, req_method, route.method) and std.mem.eql(u8, req_path, route.path)) {
            if (route.ws_handler) |wsHandler| {
                return .{ .websocket = .{ .handler = wsHandler, .ctx = ctx, .req = req.* } };
            }
            if (route.sse_handler) |sseHandler| {
                return .{ .sse = .{ .handler = sseHandler, .ctx = ctx, .req = req.* } };
            }
            const res = http_parser.HttpResponse.init(200, "OK", ctx.allocator);
            return .{ .handler = .{ .handler = route.handler, .ctx = ctx, .req = req.*, .res = res } };
        }

        // Try pattern matching with params (e.g., /hello/:name)
        if (std.mem.eql(u8, req_method, route.method) and matchPathWithParams(route.path, req_path, &req.params)) {
            if (route.ws_handler) |wsHandler| {
                return .{ .websocket = .{ .handler = wsHandler, .ctx = ctx, .req = req.* } };
            }
            if (route.sse_handler) |sseHandler| {
                return .{ .sse = .{ .handler = sseHandler, .ctx = ctx, .req = req.* } };
            }
            const res = http_parser.HttpResponse.init(200, "OK", ctx.allocator);
            return .{ .handler = .{ .handler = route.handler, .ctx = ctx, .req = req.*, .res = res } };
        }
    }
    return null;
}

/// Legacy route handler for backward compatibility
pub fn handleRoute(
    self: *Self,
    req_method: []const u8,
    req_path: []const u8,
    req: *http_parser.HttpRequest,
    ctx: http_parser.HttpContext,
) http_parser.HttpResponse {
    if (matchRoute(self, req_method, req_path, req, ctx)) |result| {
        switch (result) {
            .handler => |res_data| return res_data.res,
            .sse => return http_parser.notFound(std.heap.page_allocator),
            .websocket => return http_parser.notFound(std.heap.page_allocator),
        }
    }
    return http_parser.notFound(std.heap.page_allocator);
}

/// Match a route pattern against a request path and extract params
fn matchPathWithParams(pattern: []const u8, path: []const u8, params: *std.StringHashMap([]const u8)) bool {
    var pattern_parts = std.mem.splitScalar(u8, pattern, '/');
    var path_parts = std.mem.splitScalar(u8, path, '/');

    while (pattern_parts.next()) |pattern_part| {
        const path_part = path_parts.next() orelse return false;

        // If pattern part starts with ':', it's a param
        if (pattern_part.len > 0 and pattern_part[0] == ':') {
            const param_name = pattern_part[1..];
            params.put(param_name, path_part) catch return false;
        } else if (!std.mem.eql(u8, pattern_part, path_part)) {
            return false;
        }
    }

    return path_parts.next() == null;
}
