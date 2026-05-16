const std = @import("std");
const linux = std.posix.system;
const gserverz = @import("http_server.zig");

// implementation http server custom
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Server error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

// Handlers - (ctx, req, res) -> !HttpResponse
fn indexHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    const text = std.fmt.allocPrint(ctx.allocator, "ID: {d}", .{100}) catch {
        return gserverz.response.internalError("Failed to format", ctx.allocator);
    };
    return res.withBody(text);
}

fn healthHandler(_: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    return res.withBody("OK");
}

fn helloHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const name = req.query.get("name") orelse "HTTP";
    const greeting = req.query.get("greeting") orelse "hello";
    const mood = req.query.get("mood") orelse "neutral";

    const text = std.fmt.allocPrint(ctx.allocator, "Hello, {s}! (greeting: {s}, mood: {s})", .{ name, greeting, mood }) catch {
        return gserverz.response.internalError("Failed to format", ctx.allocator);
    };
    return res.withBody(text);
}

fn helloNameHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const name = req.query.get("name") orelse req.params.get("name") orelse "unknown";
    const greeting = req.query.get("greeting") orelse "hello";
    const mood = req.query.get("mood") orelse "neutral";


    const text = std.fmt.allocPrint(ctx.allocator, "Hello, {s}! (greeting: {s}, mood: {s})", .{ name, greeting, mood }) catch {
        return gserverz.response.internalError("Failed to format", ctx.allocator);
    };
    return res.withBody(text);
}

const User = struct {
    username: []const u8 = "",
    email: []const u8 = "",
};

fn createUserHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Parse JSON body directly into a struct
    const user = std.json.parseFromSliceLeaky(User, allocator, req.body, .{}) catch {
        return gserverz.response.badRequest("Invalid user JSON", allocator);
    };

    const json_text = std.fmt.allocPrint(allocator, "{{\"username\":\"{s}\",\"email\":\"{s}\"}}", .{ user.username, user.email }) catch {
        return gserverz.response.internalError("Failed to format", allocator);
    };
    return res.jsonResponse(.{ .status_code = 201, .data = json_text });
}

/// SSE streaming handler
fn sseStreamHandler(_: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const messages = [_][]const u8{
        "Hello from SSE!",
        "This is event 2",
        "This is event 3",
        "Goodbye from SSE!",
    };

    for (messages, 0..) |msg, i| {
        const event = std.fmt.allocPrint(std.heap.page_allocator, "data: {s}\nid: {d}\n\n", .{ msg, i }) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(event);
        req.writeSSEEvent(event);
    }
    return res.withBody("");
}

pub fn run(init: std.process.Init) !void {
    const arena_allocator = init.arena;
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    const io = init.io;

    const address = try gserverz.Address.init(29584);
    const gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();

    std.debug.print("HTTP Server listening on 127.0.0.1:29584...\n", .{});
    std.debug.print("Test with: curl http://127.0.0.1:29584/\n", .{});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    try gs.router.get("/hello", helloHandler);
    try gs.router.get("/health", healthHandler);
    try gs.router.get("/hello/:name", helloNameHandler);
    try gs.router.post("/users", createUserHandler);
    try gs.router.get("/", indexHandler);
    try gs.router.sse("/stream", sseStreamHandler);

    try gs.listen();
}

// curl http://127.0.0.1:29584/       # → "Welcome to GinwaServer!"
// curl http://127.0.0.1:29584/health # → "OK"
// curl http://127.0.0.1:29584/hello   # → "Hello, HTTP!"
