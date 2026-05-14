const std = @import("std");
const linux = std.posix.system;
const http_parser = @import("http_parser.zig");
const http_server = @import("http_server.zig");
const router_mod = @import("router.zig");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Server error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}


const custom = struct {
    id: u64,
};

// Handlers - receive request, context, return response
fn indexHandler(req: *http_parser.HttpRequest, data: *anyopaque) http_parser.HttpResponse {
    const allocator = req.allocator;
    const ctx: *const custom = @ptrCast(@alignCast(data));

    const text = std.fmt.allocPrint(allocator, "ID: {d}", .{ctx.id}) catch {
        return http_parser.internalError("Failed to format", allocator);
    };
    return http_parser.ok(text, allocator);
}

fn healthHandler(req: *http_parser.HttpRequest, _: *anyopaque) http_parser.HttpResponse {
    _ = req;
    return http_parser.ok("OK", std.heap.page_allocator);
}

fn helloHandler(req: *http_parser.HttpRequest, _: *anyopaque) http_parser.HttpResponse {
    _ = req;
    return http_parser.ok("Hello, HTTP!", std.heap.page_allocator);
}

fn helloNameHandler(req: *http_parser.HttpRequest, _: *anyopaque) http_parser.HttpResponse {
    const allocator = req.allocator;

    const name = req.params.get("name") orelse "unknown";
    const greeting = req.query.get("greeting") orelse "hello";
    const mood = req.query.get("mood") orelse "neutral";

    const text = std.fmt.allocPrint(allocator, "Hello, {s}! (greeting: {s}, mood: {s})", .{ name, greeting, mood }) catch {
        return http_parser.internalError("Failed to format", allocator);
    };
    return http_parser.ok(text, allocator);
}

const User = struct {
    username: []const u8 = "",
    email: []const u8 = "",
};

fn createUserHandler(req: *http_parser.HttpRequest, _: *anyopaque) http_parser.HttpResponse {
    const allocator = req.allocator;

    // Parse JSON body directly into a struct
    const user = std.json.parseFromSliceLeaky(User, allocator, req.body, .{}) catch {
        return http_parser.badRequest("Invalid user JSON", allocator);
    };

    const text = std.fmt.allocPrint(allocator, "Created user: {s} ({s})", .{ user.username, user.email }) catch {
        return http_parser.internalError("Failed to format", allocator);
    };
    return http_parser.created(text, allocator);
}

/// SSE streaming handler - sends events to client
fn sseStreamHandler(req: *http_parser.HttpRequest, _: *anyopaque) void {
    const messages = [_][]const u8{
        "Hello from SSE!",
        "This is event 2",
        "This is event 3",
        "Goodbye from SSE!",
    };

    for (messages, 0..) |msg, i| {
        const event = std.fmt.allocPrint(std.heap.page_allocator, "data: {s}\nid: {d}\n\n", .{ msg, i }) catch return;
        defer std.heap.page_allocator.free(event);
        req.write_sse_event(event);
    }
}

pub fn run(init: std.process.Init) !void {
    const arena_allocator = init.arena;
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    const io = init.io;

    const address = try http_server.Address.init(29584);
    const gs = try http_server.GinwaServer.init(allocator, io, address);
    defer gs.deinit();

    std.debug.print("HTTP Server listening on 127.0.0.1:29584...\n", .{});
    std.debug.print("Test with: curl http://127.0.0.1:29584/\n", .{});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    const custom_ctx = custom{ .id = 100 };

    try gs.router.get("/hello", helloHandler, custom_ctx);
    try gs.router.get("/health", healthHandler, .{});
    try gs.router.get("/hello/:name", helloNameHandler, .{});
    try gs.router.post("/users", createUserHandler, .{});
    try gs.router.get("/", indexHandler, custom_ctx);
    try gs.router.sse("/stream", sseStreamHandler, .{});

    try gs.listen();
}

// curl http://127.0.0.1:29584/       # → "Welcome to GinwaServer!"
// curl http://127.0.0.1:29584/health # → "OK"
// curl http://127.0.0.1:29584/hello   # → "Hello, HTTP!"
