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

    std.debug.print("HANDLER: req.body.len={}\n", .{req.body.len});

    const user = std.json.parseFromSliceLeaky(User, allocator, req.body, .{}) catch |err| {
        std.debug.print("HANDLER JSON error: {s}\n", .{@errorName(err)});
        if (req.body.len > 0) {
            std.debug.print("HANDLER body[0..50]={s}\n", .{req.body[0..@min(50, req.body.len)]});
        }
        return gserverz.response.badRequest("Invalid user JSON", allocator);
    };

    const json_text = std.fmt.allocPrint(allocator, "{{\"username\":\"{s}\",\"email\":\"{s}\"}}", .{ user.username, user.email }) catch {
        return gserverz.response.internalError("Failed to format", allocator);
    };
    return res.jsonResponse(.{ .status_code = 201, .data = json_text });
}

/// SSE streaming handler - registers client with SSE manager
/// Actual streaming handled by SseManager.runEventLoop()
fn sseStreamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = ctx;
    _ = req;
    _ = res;
    // Client is registered in http_server.zig before this is called
    // The SSE manager event loop handles ongoing messaging and heartbeat
    return error.WouldBlock; // Handler should not complete - connection stays open
}

pub fn run(init: std.process.Init) !void {
    // const arena_allocator = init.arena;
    // defer arena_allocator.deinit();
    // const allocator = arena_allocator.allocator();
    //
    const allocator = init.gpa;
    const io = init.io;

    // Test allocator with a large allocation first
    std.debug.print("DEBUG: Testing allocator with 1MB allocation...\n", .{});
    const test_alloc = allocator.alloc(u8, 1024 * 1024) catch |err| {
        std.debug.print("DEBUG: 1MB alloc failed: {s}\n", .{@errorName(err)});
        return err;
    };
    allocator.free(test_alloc);
    std.debug.print("DEBUG: 1MB alloc succeeded\n", .{});

    const address = try gserverz.Address.init(29590);
    const gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();

    // Start SSE event loop in background thread
    try gs.sse_manager.startEventLoop(15); // 15 second heartbeat
    defer gs.sse_manager.stop();

    std.debug.print("HTTP Server listening on 127.0.0.1:29590...\n", .{});
    std.debug.print("SSE Event loop running with 15s heartbeat...\n", .{});
    std.debug.print("Test with: curl http://127.0.0.1:29590/\n", .{});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    try gs.router.get("/hello", helloHandler);
    try gs.router.get("/health", healthHandler);
    try gs.router.get("/hello/:name", helloNameHandler);
    try gs.router.post("/users", createUserHandler);
    try gs.router.get("/", indexHandler);
    try gs.router.sse("/stream", sseStreamHandler);

    try gs.listen();
}

// curl http://127.0.0.1:29590/       # → "Welcome to GinwaServer!"
// curl http://127.0.0.1:29590/health # → "OK"
// curl http://127.0.0.1:29590/hello   # → "Hello, HTTP!"
