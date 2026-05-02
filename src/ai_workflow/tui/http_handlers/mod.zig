//! HTTP Handlers module - one file per endpoint for better organization
//!
//! This module exports all HTTP handlers used by the TUI HTTP server.
//! Each handler is in its own file for maintainability.

const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;

const config = nalarcore.config;
const session_helpers = nalarcore.session_helpers;


const httpz = http_server.httpz;

// =============================================================================
// Re-exports
// =============================================================================

pub const MessageHandler = http_server.MessageHandler;
pub const SessionHandler = http_server.SessionHandler;

// Re-export all handlers
pub const corsPreflightHandler = @import("cors.zig").corsPreflightHandler;
pub const streamHandler = @import("stream.zig").streamHandler;
pub const sessionCreateHandler = @import("session_create.zig").session_create_handler;
pub const sessionListHandler = @import("session_list.zig").session_list_handler;
pub const session_get_handler = @import("session_get.zig").session_get_handler;
pub const session_exist_handler = @import("session_exist.zig").session_exist_handler;
pub const session_message_handler = @import("session_message.zig").session_message_handler;
pub const getLatestSessionByDirHandler = @import("session_latest.zig").session_latest_handler;
pub const sseDisconnectHandler = @import("sse_disconnect.zig").sseDisconnectHandler;
pub const ping_handler = @import("ping.zig").ping_handler;
pub const llmRunHandler = @import("llm_run.zig").llmRunHandler;
pub const sessionCancelHandler = @import("session_cancel.zig").sessionCancelHandler;
pub const sessionCompactHandler = @import("session_compact.zig").sessionCompactHandler;
pub const sessionQueueDeleteHandler = @import("session_queue_delete.zig").sessionQueueDeleteHandler;
pub const sessionQueueGetHandler = @import("session_queue_get.zig").sessionQueueGetHandler;

// Worker API handlers
pub const worker_create_handler = @import("worker_create.zig").worker_create_handler;
pub const worker_status_handler = @import("worker_status.zig").worker_status_handler;
pub const worker_list_handler = @import("worker_list.zig").worker_list_handler;
pub const worker_cancel_handler = @import("worker_cancel.zig").worker_cancel_handler;

// Session stream handler
pub const sessionStreamHandler = @import("session_stream.zig").sessionStreamHandler;
pub const broadcastSessionCreated = @import("session_stream.zig").broadcastSessionCreated;

// =============================================================================
// Shared Types & Helpers
// =============================================================================

/// Response format types
pub const ResponseFormat = enum { json, xml };

/// Workflow arguments for async LLM execution
pub const WorkflowArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sqlite_db: *sqlite.SqliteBackend,
    logger: *logger.Logger,
    llm_config: *const config.LlmConfig,
    session_id: []u8,
    message: []u8,
    cwd: []u8,
    body: []const u8 = "",
    allowed_tools: []const u8 = "", // empty string = no tools allowed, "all" = all tools allowed, comma-separated list = specific tools
};

/// Handler arguments for async message handling
pub const HandlerArgs = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    handler: MessageHandler,
    ctx: ?*anyopaque,
};

/// Hex digits for session ID generation
const hexDigits = "0123456789abcdef";

/// Generate a unique session ID using timestamp and random suffix
pub fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const timestamp = ts.sec;
    var random_bytes: [8]u8 = undefined;
    std.c.arc4random_buf(&random_bytes, random_bytes.len);

    // Convert random bytes to hex string
    var hex_chars: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_chars[i * 2] = hexDigits[b >> 4];
        hex_chars[i * 2 + 1] = hexDigits[b & 0xF];
    }

    return std.fmt.allocPrint(allocator, "sess_{d}_{s}", .{ timestamp, hex_chars });
}

/// Determine response format from Accept header or query param
pub fn getResponseFormat(req: *httpz.Request) ResponseFormat {
    // First check Accept header (higher priority)
    if (req.header("accept")) |accept| {
        if (std.mem.indexOf(u8, accept, "text/xml") != null or
            std.mem.indexOf(u8, accept, "application/xml") != null)
        {
            return .xml;
        }
        if (std.mem.indexOf(u8, accept, "application/json") != null) {
            return .json;
        }
    }

    // Fallback to query parameter
    const query = req.query() catch return .json;
    const format_param = query.get("format") orelse return .json;

    if (std.mem.eql(u8, format_param, "xml")) {
        return .xml;
    }
    return .json;
}

/// Build error response based on format
pub fn buildErrorResponse(allocator: std.mem.Allocator, format: ResponseFormat, error_msg: []const u8) ![]u8 {
    if (format == .xml) {
        return std.fmt.allocPrint(allocator, "<error>{s}</error>", .{error_msg});
    } else {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{error_msg});
    }
}

/// SSE stream context for persistent connections
pub const SseStreamCtx = struct {
    server: *http_server.HttpServer,
    session_id: []const u8,
};
