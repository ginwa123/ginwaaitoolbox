const std = @import("std");
const httpz = @import("httpz");

pub const Command = struct {
    command_type: []const u8,
    session_id: []const u8,
    content: []const u8,
    cwd_session: []const u8,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        allocator.free(self.command_type);
        allocator.free(self.session_id);
        allocator.free(self.content);
        allocator.free(self.cwd_session);
    }
};

pub const SseEvent = struct {
    event_type: []const u8,
    data: []const u8,

    pub fn format(self: SseEvent, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        try result.writer(allocator).print("event: {s}\n", .{self.event_type});

        // Split data by newlines and prefix each with "data: "
        var iter = std.mem.splitScalar(u8, self.data, '\n');
        while (iter.next()) |line| {
            try result.writer(allocator).print("data: {s}\n", .{line});
        }
        try result.appendSlice(allocator, "\n");

        return result.toOwnedSlice(allocator);
    }
};

/// Thread-safe manager for SSE connections
/// Thread-safe manager for SSE connections using direct stream writing
pub const SseConnectionManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Map from session_id to stream - stream is owned by httpz's startEventStream
    connections: std.StringHashMap(std.net.Stream),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(std.net.Stream).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Note: we don't close the stream here - httpz manages that
        }
        self.connections.deinit();
    }

    /// Register a new SSE connection
    pub fn register(self: *Self, session_id: []const u8, stream: std.net.Stream) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(key);

        try self.connections.put(key, stream);
        std.log.info("SSE registered: session_id={s}", .{session_id});
    }

    /// Remove a connection (called when client disconnects)
    pub fn remove(self: *Self, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.connections.fetchRemove(session_id)) |entry| {
            self.allocator.free(entry.key);
            std.log.info("SSE removed: session_id={s}", .{session_id});
        }
    }

    /// Send an event to a specific session
    pub fn sendEvent(self: *Self, session_id: []const u8, event: SseEvent, allocator: std.mem.Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.log.info("SSE sendEvent: session_id={s}, event_type={s}, connections_count={d}", .{ session_id, event.event_type, self.connections.count() });

        const stream = self.connections.get(session_id) orelse {
            std.log.err("SSE sendEvent: session not found: {s}", .{session_id});
            return error.SessionNotFound;
        };

        const formatted = try event.format(allocator);
        defer allocator.free(formatted);

        // Write directly to stream - this is the key fix
        stream.writeAll(formatted) catch |err| {
            std.log.err("SSE sendEvent: write failed: {s}", .{@errorName(err)});
            return error.WriteFailed;
        };

        std.log.info("SSE sendEvent: SUCCESS, session_id={s}, bytes_written={d}", .{session_id, formatted.len});
    }

    /// Check if a session exists
    pub fn hasSession(self: *Self, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connections.contains(session_id);
    }
};

pub const MessageHandler = *const fn (allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque) void;

// Global server instance for handlers to access
var global_server: ?*HttpServer = null;

/// Get the global SSE connection manager for sending events to clients
pub fn getGlobalSseManager() ?*SseConnectionManager {
    if (global_server) |server| {
        return &server.sse_manager;
    }
    return null;
}

pub const HttpServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    port: u16,
    message_handler: ?MessageHandler = null,
    ctx: ?*anyopaque = null,
    sse_manager: SseConnectionManager,

    pub fn init(allocator: std.mem.Allocator, ctx: ?*anyopaque, port: u16) Self {
        return .{
            .allocator = allocator,
            .port = if (port == 0) 8080 else port,
            .ctx = ctx,
            .sse_manager = SseConnectionManager.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.sse_manager.deinit();
    }

    pub fn setMessageHandler(self: *Self, handler: MessageHandler) void {
        self.message_handler = handler;
    }

    pub fn run(self: *Self) !void {
        // Store global reference for handlers
        global_server = self;
        defer global_server = null;

        var server = try httpz.Server(void).init(self.allocator, .{
            .address = .localhost(self.port),
        }, {});
        defer server.deinit();

        std.log.info("HTTP server listening on http://127.0.0.1:{d}/", .{self.port});

        var router = try server.router(.{});

        // Command endpoint
        router.post("/api/command", commandHandler, .{});

        // SSE stream endpoint
        router.get("/api/stream/:session_id", streamHandler, .{});

        try server.listen();
    }
};

fn commandHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const body = req.body() orelse "";

    if (global_server) |server| {
        if (server.message_handler) |msg_handler| {
            var arena = std.heap.ArenaAllocator.init(server.allocator);
            defer arena.deinit();
            msg_handler(arena.allocator(), body, server.ctx);
        }
    }

    res.status = 200;
    res.body = "ok";
}

/// Context for SSE stream handler
const SseStreamCtx = struct {
    server: *HttpServer,
    session_id: []const u8,
};

/// SSE stream handler - called by httpz on a dedicated thread
fn sseStreamHandler(ctx: SseStreamCtx, stream: std.net.Stream) void {
    std.log.info("SSE stream handler started: session_id={s}", .{ctx.session_id});

    // Register this connection with the stream
    ctx.server.sse_manager.register(ctx.session_id, stream) catch {
        std.log.err("SSE: Failed to register stream for session: {s}", .{ctx.session_id});
        return;
    };

    // Send initial connected event directly
    const connected_data = std.fmt.allocPrint(ctx.server.allocator, "event: connected\ndata: {{\"session_id\":\"{s}\"}}\n\n", .{ctx.session_id}) catch {
        std.log.err("SSE: Failed to format connected event", .{});
        ctx.server.sse_manager.remove(ctx.session_id);
        return;
    };
    defer ctx.server.allocator.free(connected_data);

    stream.writeAll(connected_data) catch |err| {
        std.log.err("SSE: Failed to write connected event: {s}", .{@errorName(err)});
        ctx.server.sse_manager.remove(ctx.session_id);
        return;
    };

    std.log.info("SSE: Connected event sent for session: {s}", .{ctx.session_id});

    // Keep connection alive with periodic keepalives
    // The actual events are sent via sendEvent which writes directly to the stream
    while (ctx.server.sse_manager.hasSession(ctx.session_id)) {
        // Send keepalive comment every 30 seconds to prevent timeouts
        stream.writeAll(": keepalive\n\n") catch |err| {
            std.log.warn("SSE keepalive failed for session {s}: {s}", .{ ctx.session_id, @errorName(err) });
            break;
        };

        // Check every 100ms if session still exists
        var i: usize = 0;
        while (i < 300 and ctx.server.sse_manager.hasSession(ctx.session_id)) : (i += 1) {
            std.Thread.sleep(100_000_000); // 100ms
        }
    }

    std.log.info("SSE stream handler ending: session_id={s}", .{ctx.session_id});
    ctx.server.sse_manager.remove(ctx.session_id);
    // Free the session_id that was allocated in streamHandler
    ctx.server.allocator.free(ctx.session_id);
}

fn streamHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const session_id_param = req.param("session_id");

    if (session_id_param == null) {
        res.status = 400;
        res.body = "Missing session_id";
        return;
    }

    if (global_server) |server| {
        const session_id = session_id_param.?;
        std.log.info("SSE STREAM CONNECTED: session_id={s}", .{session_id});

        // Duplicate session_id for the context (it must outlive this function)
        const session_id_copy = try server.allocator.dupe(u8, session_id);
        errdefer server.allocator.free(session_id_copy);

        const ctx = SseStreamCtx{
            .server = server,
            .session_id = session_id_copy,
        };

        // startEventStream sets SSE headers and spawns a thread calling sseStreamHandler
        // Note: session_id_copy is now owned by the spawned thread and will be freed in sseStreamHandler
        try res.startEventStream(ctx, sseStreamHandler);
    } else {
        res.status = 500;
        res.body = "Server not available";
    }
}

pub fn parseCommand(allocator: std.mem.Allocator, json: []const u8) !Command {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const command_type = if (root.get("command_type")) |v|
        try allocator.dupe(u8, v.string)
    else
        try allocator.dupe(u8, "");

    const session_id = if (root.get("session_id")) |v|
        try allocator.dupe(u8, v.string)
    else
        try allocator.dupe(u8, "");

    const content = if (root.get("content")) |v|
        try allocator.dupe(u8, v.string)
    else
        try allocator.dupe(u8, "");

    const cwd_session = if (root.get("cwd_session")) |v|
        try allocator.dupe(u8, v.string)
    else
        try allocator.dupe(u8, "");

    return Command{
        .command_type = command_type,
        .session_id = session_id,
        .content = content,
        .cwd_session = cwd_session,
    };
}

test {
    _ = @import("http_server_test.zig");
}
