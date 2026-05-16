const std = @import("std");
const http_parser = @import("http_parser.zig");

pub const Self = @This();

/// Handler fn: (server_ctx, request, response) -> anyerror!void
pub const HandlerFn = *const fn (ctx: http_parser.HttpContext, req: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse;

/// SSE streaming handler
pub const SseHandlerFn = *const fn (ctx: http_parser.HttpContext, req: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse;

/// Route type to distinguish SSE from regular handlers
pub const RouteType = enum {
    regular,
    sse,
};

pub const Router = Self;

routes: std.ArrayListUnmanaged(Route) = .empty,
arena: std.mem.Allocator,

pub const Route = struct {
    method: []const u8 = "",
    path: []const u8 = "",
    handler: HandlerFn = defaultHandler,
    sse_handler: ?SseHandlerFn = null,
    route_type: RouteType = .regular,
};

pub fn defaultHandler(_: http_parser.HttpContext, req: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
    _ = req;
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
    // For SSE, we use a wrapper that receives the client_fd
    const WrappedSseHandler = struct {
        fn wrapped(ctx: http_parser.HttpContext, req: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return try @call(.auto, handler, .{ ctx, req, res });
        }
    };

    try self.routes.append(self.arena, Route{
        .method = "GET",
        .path = path,
        .handler = undefined, // SSE routes don't use regular handler
        .sse_handler = WrappedSseHandler.wrapped,
        .route_type = .sse,
    });
}

/// Generic internal route adder - boxes context and creates typed handler wrapper
fn addRouteInternal(self: *Self, method: []const u8, path: []const u8, handler: anytype) !void {
    // Create a typed handler wrapper
    const WrappedHandler = struct {
        fn wrapped(ctx: http_parser.HttpContext, req: http_parser.HttpRequest, res: http_parser.HttpResponse) anyerror!http_parser.HttpResponse {
            return try @call(.auto, handler, .{ ctx, req, res });
        }
    };

    try self.routes.append(self.arena, Route{
        .method = method,
        .path = path,
        .handler = WrappedHandler.wrapped,
        .route_type = .regular,
    });
}

/// Route matching result - handler + contexts needed to execute it
pub const RouteResult = union(enum) {
    handler: struct {
        handler: HandlerFn,
        ctx: http_parser.HttpContext,
        res: http_parser.HttpResponse,
    },
    sse: struct {
        handler: SseHandlerFn,
        ctx: http_parser.HttpContext,
    },
};

/// Route matching and execution - returns handler to execute
pub fn matchRoute(self: *Self, req_method: []const u8, req_path: []const u8, req: *http_parser.HttpRequest, ctx: http_parser.HttpContext) ?RouteResult {
    for (self.routes.items) |route| {
        // Try exact match first
        if (std.mem.eql(u8, req_method, route.method) and std.mem.eql(u8, req_path, route.path)) {
            if (route.sse_handler) |sseHandler| {
                return .{ .sse = .{ .handler = sseHandler, .ctx = ctx } };
            }
            const res = http_parser.HttpResponse.init(200, "OK", ctx.allocator);
            return .{ .handler = .{ .handler = route.handler, .ctx = ctx, .res = res } };
        }

        // Try pattern matching with params (e.g., /hello/:name)
        if (std.mem.eql(u8, req_method, route.method) and matchPathWithParams(route.path, req_path, &req.params)) {
            if (route.sse_handler) |sseHandler| {
                return .{ .sse = .{ .handler = sseHandler, .ctx = ctx } };
            }
            const res = http_parser.HttpResponse.init(200, "OK", ctx.allocator);
            return .{ .handler = .{ .handler = route.handler, .ctx = ctx, .res = res } };
        }
    }
    return null;
}

/// Legacy route handler for backward compatibility
pub fn handleRoute(self: *Self, req_method: []const u8, req_path: []const u8, req: *http_parser.HttpRequest) http_parser.HttpResponse {
    if (matchRoute(self, req_method, req_path, req)) |result| {
        switch (result) {
            .response => |res| return res,
            .sse => return http_parser.notFound(std.heap.page_allocator), // SSE should be handled separately
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
