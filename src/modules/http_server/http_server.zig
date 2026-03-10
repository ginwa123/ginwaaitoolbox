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
pub const SseConnectionManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    connections: std.StringHashMap(*std.ArrayList(u8)),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(*std.ArrayList(u8)).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.connections.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.connections.deinit();
    }

    pub fn register(self: *Self, session_id: []const u8, writer: *std.ArrayList(u8)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, session_id);
        
        // Create a new buffer for this connection
        const buf = try self.allocator.create(std.ArrayList(u8));
        buf.* = std.ArrayList(u8).empty;
        
        // Copy initial content if any
        if (writer.items.len > 0) {
            try buf.appendSlice(self.allocator, writer.items);
        }
        
        try self.connections.put(key, buf);
    }

    pub fn get(self: *Self, session_id: []const u8) ?*std.ArrayList(u8) {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connections.get(session_id);
    }

    pub fn remove(self: *Self, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.connections.fetchRemove(session_id)) |entry| {
            self.allocator.free(entry.key);
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry.value);
        }
    }

    pub fn sendEvent(self: *Self, session_id: []const u8, event: SseEvent, allocator: std.mem.Allocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        std.log.info("SSE sendEvent: session_id={s}, event_type={s}, connections_count={d}", .{ session_id, event.event_type, self.connections.count() });
        
        const writer = self.connections.get(session_id) orelse {
            std.log.err("SSE sendEvent: session not found: {s}", .{session_id});
            return error.SessionNotFound;
        };
        
        const formatted = try event.format(allocator);
        defer allocator.free(formatted);
        
        try writer.appendSlice(allocator, formatted);
        std.log.info("SSE sendEvent: SUCCESS, session_id={s}, bytes_written={d}", .{session_id, formatted.len});
    }

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

fn streamHandler(req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const session_id = req.param("session_id");
    
    if (session_id == null) {
        res.status = 400;
        res.body = "Missing session_id";
        return;
    }

    if (global_server) |server| {
        std.log.info("SSE STREAM CONNECTED: session_id={s}", .{session_id.?});

        // Set SSE headers
        res.status = 200;
        res.content_type = .EVENTS;
        res.header("Cache-Control", "no-cache");
        res.header("Connection", "keep-alive");
        res.header("Access-Control-Allow-Origin", "*");

        // Create a buffer to capture SSE events for this session
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(server.allocator);
        
        // Register this connection
        server.sse_manager.register(session_id.?, &buf) catch {
            res.status = 500;
            res.body = "Failed to register session";
            return;
        };

        // Send initial connected event
        const connected_event = SseEvent{
            .event_type = "connected",
            .data = try std.fmt.allocPrint(server.allocator, "{{\"session_id\":\"{s}\"}}", .{session_id.?}),
        };
        defer server.allocator.free(connected_event.data);
        
        try server.sse_manager.sendEvent(session_id.?, connected_event, server.allocator);
        std.log.info("SSE: Connected event sent for session: {s}", .{session_id.?});

        // Send initial event to client
        try res.chunk(buf.items);
        std.log.info("SSE: Initial chunk sent, buf len: {}", .{buf.items.len});
        buf.clearRetainingCapacity();

        // Keep connection open and stream events
        // Poll buffer for new events every 100ms
        var last_len: usize = 0;
        while (true) {
            std.Thread.sleep(100_000_000); // 100ms

            // Check if new data in buffer
            if (buf.items.len > last_len) {
                try res.chunk(buf.items[last_len..]);
                buf.clearRetainingCapacity();
                last_len = 0;
            } else {
                // Send keepalive comment to prevent timeout
                try res.chunk(": keepalive\n\n");
            }

            // Check if session still exists (removed = client disconnected)
            if (!server.sse_manager.hasSession(session_id.?)) {
                std.log.info("SSE client disconnected for session: {s}", .{session_id.?});
                break;
            }
        }
        
        // Cleanup
        server.sse_manager.remove(session_id.?);
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
