const std = @import("std");
const httpz_import = @import("httpz");

pub const httpz = httpz_import;

// Re-export types from sub-modules
pub const SseEvent = @import("./sse_manager.zig").SseEvent;
pub const SseConnectionManager = @import("./sse_manager.zig").SseConnectionManager;

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
            .event_type = "panic",
            .data = panic_info,
        };
        server.sse_manager.broadcast(event);
    }
}

pub const HttpServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    port: u16,
    message_handler: ?MessageHandler = null,
    session_handler: ?SessionHandler = null,
    ctx: ?*anyopaque = null,
    sse_manager: SseConnectionManager,
    db: ?*anyopaque = null, // Opaque database handle for handlers

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

    /// Set the database handle for handlers
    pub fn setDb(self: *Self, db: *anyopaque) void {
        self.db = db;
    }

    pub fn setTUIHandler(self: *Self, handler: MessageHandler) void {
        self.message_handler = handler;
    }

    /// Set the session handler for synchronous session operations (create/get/delete)
    pub fn setSessionHandler(self: *Self, handler: SessionHandler) void {
        self.session_handler = handler;
    }

    /// Run server with custom route configuration
    pub fn runWithConfig(self: *Self, custom_routes: *const fn (port: u16, router: anytype) anyerror!void) !void {
        global_server = self;
        defer global_server = null;

        var server = try httpz.Server(void).init(self.allocator, .{
            .address = .localhost(self.port),
        }, {});
        defer server.deinit();

        const router = try server.router(.{});

        // Call custom setup function to add routes
        try custom_routes(self.port, router);

        try server.listen();
    }
};

test {
    _ = @import("sse_manager.zig");
}
