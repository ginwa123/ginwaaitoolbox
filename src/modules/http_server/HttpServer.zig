const std = @import("std");
const httpz_import = @import("httpz");

pub const httpz = httpz_import;

// Re-export types from sub-modules
pub const SseEvent = @import("./SseManager.zig").SseEvent;
pub const SseConnectionManager = @import("./SseManager.zig").SseConnectionManager;
pub const SseQueueItem = @import("./SseManager.zig").SseQueueItem;

// Note: HTTP handlers are exported directly from nalarcore.http_handlers
// (stored at ai_workflow/tui/http_handlers.zig to avoid circular imports)

/// Message handler callback type (for TUI async message handling)
pub const MessageHandler = *const fn (allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque) void;

/// Session handler callback type (for sync session operations)
pub const SessionHandler = *const fn (allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque, res: *httpz.Response) void;

// Global server instance for handlers to access
pub var global_server: ?*HttpServer = null;

/// Get the global SSE connection manager for sending events to clients
pub fn getGlobalSseManager() ?*SseConnectionManager {
    if (global_server) |server| {
        return &server.sse_manager;
    }
    return null;
}

/// Broadcast a panic event to all connected SSE clients
pub fn broadcastPanic(panic_info: []const u8) void {
    if (global_server) |server| {
        const event = SseEvent{
            .data = panic_info,
        };
        server.sse_manager.broadcast(event);
    }
}

pub const HttpServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    message_handler: ?MessageHandler = null,
    session_handler: ?SessionHandler = null,
    ctx: ?*anyopaque = null, // Contains ContextIPCTui which has .db inside
    sse_manager: SseConnectionManager,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, ctx: ?*anyopaque, port: u16) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .port = if (port == 0) 8080 else port,
            .ctx = ctx,
            .sse_manager = SseConnectionManager.init(allocator, io),
        };
    }

    pub fn deinit(self: *Self) void {
        self.sse_manager.deinit();
    }

    pub fn setTUIHandler(self: *Self, handler: MessageHandler) void {
        self.message_handler = handler;
    }

    /// Set the session handler for synchronous session operations (create/get/delete)
    pub fn setSessionHandler(self: *Self, handler: SessionHandler) void {
        self.session_handler = handler;
    }

    /// Run server with custom route configuration
    pub fn runWithConfig(self: *Self, comptime custom_routes: fn (port: u16, router: anytype) anyerror!void) !void {
        global_server = self;
        defer global_server = null;

        // Use a handler struct to enable middleware support
        var handler = ServerHandler{
            .server = self,
        };
        var server = try httpz.Server(*ServerHandler).init(self.io, self.allocator, .{
            .address = .localhost(self.port),
        }, &handler);
        defer server.deinit();

        const router = try server.router(.{});

        // Call custom setup function to add routes
        try custom_routes(self.port, router);

        try server.listen();
    }

    /// Handler struct for httpz server - enables middleware support
    pub const ServerHandler = struct {
        server: *Self,

        /// Custom dispatch to add CORS headers to every response
        pub fn dispatch(self: *ServerHandler, action: httpz.Action(*ServerHandler), req: *httpz.Request, res: *httpz.Response) !void {
            // Add CORS headers to all responses - allow webview origin and any other origin
            const origin = req.header("origin") orelse "*";
            res.header("Access-Control-Allow-Origin", origin);
            res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
            res.header("Access-Control-Allow-Headers", "Content-Type, Authorization, Accept, Origin");
            res.header("Access-Control-Allow-Credentials", "true");

            // Handle preflight OPTIONS requests
            if (req.method == .OPTIONS) {
                res.status = 204;
                return;
            }

            // Call the actual action
            try action(self, req, res);
        }
    };
};

test {
    _ = @import("SseManager.zig");
}
