const std = @import("std");
const http_parser = @import("http_parser.zig");

pub const Self = @This();

pub const HandlerFn = *const fn (req: http_parser.HttpRequest, ctx: *anyopaque) http_parser.HttpResponse;

pub const Router = Self;

routes: std.ArrayListUnmanaged(Route) = .empty,
arena: std.mem.Allocator,

pub const Route = struct {
    method: []const u8 = "",
    path: []const u8 = "",
    handler: HandlerFn = defaultHandler,
    context: *anyopaque = undefined,
};

pub fn defaultHandler(_: http_parser.HttpRequest, _: *anyopaque) http_parser.HttpResponse {
    return http_parser.ok("", std.heap.page_allocator);
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
pub fn get(self: *Self, path: []const u8, handler: anytype, context: anytype) !void {
    return self.addRouteInternal("GET", path, handler, context);
}

/// Add a POST route with generic context support
pub fn post(self: *Self, path: []const u8, handler: anytype, context: anytype) !void {
    return self.addRouteInternal("POST", path, handler, context);
}

/// Add a PUT route with generic context support
pub fn put(self: *Self, path: []const u8, handler: anytype, context: anytype) !void {
    return self.addRouteInternal("PUT", path, handler, context);
}

/// Add a DELETE route with generic context support
pub fn delete(self: *Self, path: []const u8, handler: anytype, context: anytype) !void {
    return self.addRouteInternal("DELETE", path, handler, context);
}

/// Add a PATCH route with generic context support
pub fn patch(self: *Self, path: []const u8, handler: anytype, context: anytype) !void {
    return self.addRouteInternal("PATCH", path, handler, context);
}

/// Generic internal route adder - boxes context and creates typed handler wrapper
fn addRouteInternal(self: *Self, method: []const u8, path: []const u8, handler: anytype, context: anytype) !void {
    const ContextType = @TypeOf(context);

    // Box the context - store it on the heap/arena
    const boxed_ctx = try self.arena.create(ContextType);
    boxed_ctx.* = context;

    // Create a typed handler wrapper that passes context correctly
    const WrappedHandler = struct {
        fn wrapped(req: http_parser.HttpRequest, ctx_ptr: *anyopaque) http_parser.HttpResponse {
            const typed_ctx: *ContextType = @ptrCast(@alignCast(ctx_ptr));
            // Call the original handler with request and typed context
            return @call(.auto, handler, .{ req, typed_ctx });
        }
    };

    try self.routes.append(self.arena, Route{
        .method = method,
        .path = path,
        .handler = WrappedHandler.wrapped,
        .context = @ptrCast(boxed_ctx),
    });
}

/// Route matching and execution - returns HttpResponse
pub fn handleRoute(self: *Self, req_method: []const u8, req_path: []const u8, req: http_parser.HttpRequest) http_parser.HttpResponse {
    for (self.routes.items) |route| {
        // Match method and path
        if (std.mem.eql(u8, req_method, route.method) and std.mem.eql(u8, req_path, route.path)) {
            // Execute handler with request and context
            return route.handler(req, route.context);
        }
    }
    return http_parser.notFound(std.heap.page_allocator);
}

test "basic route matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var router = init(arena.allocator());

    const MyContext = struct {
        message: []const u8 = "hello",
    };

    const my_ctx = MyContext{ .message = "world" };
    const test_allocator = arena.allocator();

    try router.get("/hello", struct {
        fn handle(req: http_parser.HttpRequest, ctx: *const MyContext) http_parser.HttpResponse {
            _ = req;
            try std.testing.expectEqualStrings("world", ctx.message);
            return http_parser.ok("OK", test_allocator);
        }
    }.handle, my_ctx);

    // Create a mock request
    const mock_req = http_parser.HttpRequest{
        .method = "GET",
        .path = "/hello",
        .version = "HTTP/1.1",
        .headers = std.StringHashMap([]const u8).init(test_allocator),
        .body = "",
        .raw = "",
    };

    const res = router.handleRoute("GET", "/hello", mock_req);
    try std.testing.expectEqual(@as(u16, 200), res.status_code);
}
