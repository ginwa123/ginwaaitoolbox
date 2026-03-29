const std = @import("std");

const root_mod = @import("nalarcore");
const agentMod = root_mod.agent;
const http_server = root_mod.http_server;
const http_handlers = root_mod.http_handlers;
const httpz = http_server.httpz;
const agent = root_mod.agent;
const ai_workflow = root_mod.ai_workflow;
const session_monitor = root_mod.session_monitor;
const cronjob = root_mod.cronjob;
const tui_workflow = root_mod.ai_workflow;
const ai_workflow_mod = root_mod.ai_workflow;
const sqlite = root_mod.sqlite;
const migrations = root_mod.migrations;
const cancellation_registry = root_mod.session.cancellation_registry;
const activity_registry = root_mod.session.activity_registry;
const helpers = root_mod.helpers;
const config = root_mod.config;
const LlmConfig = config.LlmConfig;
const kerjabot_get_session = root_mod.kerjabot_get_session;

pub const CommandMessage = struct {
    command_type: []const u8 = "",
    session_id: []const u8 = "",
    message: []const u8 = "",
    cwd_session: []const u8 = "",
};

/// Parse message (JSON or XML) into CommandMessage struct
pub fn parseMessage(allocator: std.mem.Allocator, data: []const u8) !CommandMessage {
    // Try JSON first (HTTP format)
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        // Fall back to XML parsing (IPC format)
        var msg: CommandMessage = .{};

        if (helpers.xml.extractTag(data, "command_type", allocator)) |val| {
            msg.command_type = try helpers.xml.decodeXmlEntities(allocator, val);
        }
        if (helpers.xml.extractTag(data, "session_id", allocator)) |val| {
            msg.session_id = try helpers.xml.decodeXmlEntities(allocator, val);
        }
        if (helpers.xml.extractTag(data, "content", allocator)) |val| {
            msg.message = try helpers.xml.decodeXmlEntities(allocator, val);
        }
        if (helpers.xml.extractTag(data, "cwd_session", allocator)) |val| {
            msg.cwd_session = try helpers.xml.decodeXmlEntities(allocator, val);
        }

        return msg;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    var msg: CommandMessage = .{};

    if (root.get("command_type")) |v| {
        msg.command_type = try allocator.dupe(u8, v.string);
    }
    if (root.get("session_id")) |v| {
        msg.session_id = try allocator.dupe(u8, v.string);
    }
    if (root.get("content")) |v| {
        msg.message = try allocator.dupe(u8, v.string);
    }
    if (root.get("cwd_session")) |v| {
        msg.cwd_session = try allocator.dupe(u8, v.string);
    }

    // MUST deinit parsed AFTER we've dupe'd all needed strings
    parsed.deinit();

    return msg;
}

/// Get the database path following XDG standards: ~/.config/nalar/agent.db
/// Creates the config directory if it doesn't exist.
/// Caller owns the returned memory.
fn getDbPath(allocator: std.mem.Allocator) ![:0]const u8 {
    const home = std.posix.getenv("HOME") orelse {
        std.log.err("HOME environment variable not set", .{});
        return error.HomeNotFound;
    };

    // Build the config directory path: ~/.config/nalar
    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        "nalar",
    });
    defer allocator.free(config_dir);

    // Create the directory if it doesn't exist (makePath creates all parent directories too)
    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.err("Failed to create config directory: {s}", .{config_dir});
            return err;
        }
    };

    // Build the full database path
    const db_path = try std.fs.path.join(allocator, &[_][]const u8{
        config_dir,
        "agent.db",
    });
    defer allocator.free(db_path);

    // Return as null-terminated string (required by sqlite init)
    return try allocator.dupeZ(u8, db_path);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const parentAllocator = gpa.allocator();

    // Load LLM config from JSON file
    var llm_config = root_mod.config.LlmConfig.init(parentAllocator, null) catch |err| {
        std.log.err("Failed to load config: {s}", .{@errorName(err)});
        return err;
    };
    defer llm_config.deinit();
    try llm_config.validate();

    // Get database path following XDG standards: ~/.config/nalar/agent.db
    const db_path = try getDbPath(parentAllocator);
    defer parentAllocator.free(db_path);

    var dbSqlite: sqlite.SqliteBackend = .{};
    defer dbSqlite.deinit();
    try dbSqlite.init(db_path);

    var migrationManager = migrations.MigrationManager.init(parentAllocator, &dbSqlite);
    defer migrationManager.deinit();
    try migrations.registerAllMigrations(&migrationManager);
    try migrationManager.runMigrations();

    // Get platform-appropriate temp directory
    // Use /tmp as fallback (more predictable than HOME)
    const tmp_path = std.posix.getenv("TMPDIR") orelse
        std.posix.getenv("TEMP") orelse
        std.posix.getenv("TMP") orelse
        "/tmp";
    const log_file_path = try std.fs.path.join(parentAllocator, &.{ tmp_path, "agentic_coding.log" });
    defer parentAllocator.free(log_file_path);

    // SET PANIC LOG PATH EARLY - before any code that could panic
    root_mod.setPanicLogPath(log_file_path);

    // Initialize global logger
    root_mod.logger.initGlobalColor(parentAllocator, .{
        .min_level = .debug,
        .output_mode = .file,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    defer root_mod.logger.deinitGlobal();

    const global_logger_ptr = root_mod.logger.getGlobal().?;

    const ctxParent = try parentAllocator.create(ai_workflow_mod.ContextIPCTui);
    defer parentAllocator.destroy(ctxParent);
    ctxParent.* = ai_workflow_mod.ContextIPCTui{
        .db = &dbSqlite,
        .llm_config = &llm_config,
        .logger = global_logger_ptr,
    };

    // Initialize global cancellation registry
    ai_workflow.cancellation_registry.initGlobalRegistry(parentAllocator);
    defer ai_workflow.cancellation_registry.deinitGlobalRegistry();

    // Initialize global activity registry
    activity_registry.initGlobalRegistry(parentAllocator);
    defer activity_registry.deinitGlobalRegistry();

    // Spawn session monitor to exit if no active sessions
    var monitor = session_monitor.SessionMonitor.spawn() catch |err| {
        std.log.err("Failed to spawn session monitor: {s}", .{@errorName(err)});
        return err;
    };
    defer monitor.stop();

    // Spawn cronjob to periodically check background process status
    const cronjob_config = cronjob.CronjobConfig{
        .check_interval_ms = 30_000, // Check every 30 seconds
        .db_path = db_path, // Use same database as the rest of the app
    };
    var cron = cronjob.cronjob.Cronjob.spawn(parentAllocator, cronjob_config) catch |err| {
        std.log.err("Failed to spawn cronjob: {s}", .{@errorName(err)});
        return err;
    };
    defer cron.stop();

    // Default port (0 means auto-select, HttpServer will use 8080)
    var port: u16 = 0;

    // Parse command line arguments
    const args = try std.process.argsAlloc(parentAllocator);
    defer std.process.argsFree(parentAllocator, args);

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 >= args.len) {
                std.log.err("Error: --port requires a value\n", .{});
                return error.InvalidArgs;
            }
            port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 2;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Usage: nalar [--port PORT]\n", .{});
            std.debug.print("  --port PORT    Port to run the HTTP server on (default: 8080)\n", .{});
            return;
        }
    }

    var server = http_server.HttpServer.init(parentAllocator, ctxParent, port);
    server.setDb(@ptrCast(&dbSqlite));

    // this is for tui only
    server.setTUIHandler(struct {
        fn handler(allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque) void {
            std.debug.print("message incoming {s}\n", .{data});
            const ctxTui = @as(*ai_workflow_mod.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const t = parseMessage(allocator, data) catch |err| {
                std.debug.print("parse error: {}\n", .{err});
                return;
            };

            var workflowAsk = ai_workflow.TUIWorkflow.init(ctxTui.db, ctxTui.logger);
            if (std.mem.eql(u8, t.command_type, "run_llm")) {
                _ = workflowAsk.run(allocator, t.session_id, t.message, t.cwd_session, ctxTui.llm_config.api_key, ctxTui.llm_config.model, ctxTui.llm_config.base_url, ctxTui.llm_config);
            }
            if (std.mem.eql(u8, t.command_type, "get_sessions")) {}

            if (std.mem.eql(u8, t.command_type, "double_escape")) {
                const sessionId = t.session_id;
                if (cancellation_registry.get_global_registry()) |registry| {
                    registry.cancel(sessionId);
                }
            }

            if (std.mem.eql(u8, t.command_type, "create_session")) {
                var session_id_buf: [64]u8 = undefined;
                const session_id = std.fmt.bufPrint(&session_id_buf, "session_{}", .{std.time.timestamp()}) catch "session_error";
                var response_buf: [256]u8 = undefined;
                const response = std.fmt.bufPrint(&response_buf, "{{\"sessionId\":\"{s}\"}}", .{session_id}) catch unreachable;
                if (http_server.getGlobalSseManager()) |sse_manager| {
                    const event = http_server.SseEvent{
                        .data = response,
                    };
                    sse_manager.sendEvent(session_id, event) catch |err| {
                        std.debug.print("Failed to send session_created response: {s}\n", .{@errorName(err)});
                    };
                }
            }
            if (std.mem.eql(u8, t.command_type, "ping")) {
                var response_buf: [256]u8 = undefined;
                var response: []const u8 = undefined;
                if (http_server.getGlobalSseManager()) |sse_manager| {
                    if (sse_manager.hasSession(t.session_id)) {
                        response = std.fmt.bufPrint(&response_buf, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"connected\":true}}", .{t.session_id}) catch unreachable;
                    } else {
                        response = std.fmt.bufPrint(&response_buf, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"reconnect\":true}}", .{t.session_id}) catch unreachable;
                    }
                } else {
                    response = std.fmt.bufPrint(&response_buf, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"reconnect\":true}}", .{t.session_id}) catch unreachable;
                }
                // Send the response back to the TUI via SSE event
                if (http_server.getGlobalSseManager()) |sse_manager| {
                    const event = http_server.SseEvent{
                        .data = response,
                    };
                    sse_manager.sendEvent(t.session_id, event) catch |err| {
                        std.debug.print("Failed to send pong response: {s}\n", .{@errorName(err)});
                    };
                }
            }

            if (std.mem.eql(u8, t.command_type, "compact")) {
                // Manually trigger compaction for the session
                var response_buf: [256]u8 = undefined;
                const response = std.fmt.bufPrint(&response_buf, "{{\"app_type\":\"tui\",\"command_type\":\"compact_ack\",\"session_id\":\"{s}\",\"status\":\"processing\"}}", .{t.session_id}) catch unreachable;
                if (http_server.getGlobalSseManager()) |sse_manager| {
                    const event = http_server.SseEvent{
                        .data = response,
                    };
                    sse_manager.sendEvent(t.session_id, event) catch |err| {
                        std.debug.print("Failed to send compact_ack response: {s}\n", .{@errorName(err)});
                    };
                }
                // Run the compaction workflow in a separate task
                std.debug.print("[COMPACTION] Manual compaction triggered for session {s}\n", .{t.session_id});
                var workflow_compact = ai_workflow.TUIWorkflow.init(ctxTui.db, ctxTui.logger);
                // Run compaction asynchronously - this will send results via SSE
                // Use the llm_config already loaded in ctxTui
                _ = std.Thread.spawn(.{}, struct {
                    fn run(workflow: *ai_workflow.TUIWorkflow, db: *sqlite.SqliteBackend, session_id: []const u8, api_key: []const u8, model: []const u8, base_url: []const u8, compaction_kb: usize) void {
                        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                        defer arena.deinit();
                        const alloc = arena.allocator();
                        // Get cwd from session
                        var cwd_buf: [4096]u8 = undefined;
                        const cwd = blk: {
                            const result = kerjabot_get_session.getSession(alloc, db, session_id) catch null;
                            if (result) |session| {
                                defer session.deinit(alloc);
                                if (session.session_dir.len > 0) {
                                    break :blk std.fmt.bufPrint(&cwd_buf, "{s}", .{session.session_dir}) catch ".";
                                }
                            }
                            break :blk std.fmt.bufPrint(&cwd_buf, ".", .{}) catch ".";
                        };
                        // Create a minimal LlmConfig for the workflow
                        var llm_cfg = LlmConfig{
                            .allocator = alloc,
                            .api_key = api_key,
                            .model = model,
                            .base_url = base_url,
                            .model_compaction_size_kb = compaction_kb,
                            .mcpServers = null,
                        };
                        workflow.run(alloc, session_id, "", cwd, api_key, model, base_url, &llm_cfg);
                    }
                }.run, .{ &workflow_compact, ctxTui.db, t.session_id, ctxTui.llm_config.api_key, ctxTui.llm_config.model, ctxTui.llm_config.base_url, ctxTui.llm_config.model_compaction_size_kb }) catch |err| {
                    std.debug.print("[COMPACTION] Failed to spawn thread: {s}\n", .{@errorName(err)});
                };
            }
        }
    }.handler);

    // Set session handler for synchronous session operations (create/get sessions)
    server.setSessionHandler(struct {
        fn handler(allocator: std.mem.Allocator, data: []const u8, ctx: ?*anyopaque, res: *httpz.Response) void {
            std.debug.print("session handler called with: {s}\n", .{data});

            // Note: ctx can be used for database access if needed later
            _ = ctx;

            // Parse the request body as JSON
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
                res.status = 400;
                res.body = "{\"error\":\"Invalid JSON\"}";
                return;
            };
            defer parsed.deinit();

            const root = parsed.value.object;

            // Get optional agent_type from request
            var agent_type: []const u8 = "general";
            if (root.get("agent_type")) |v| {
                agent_type = v.string;
            }

            // Generate session ID
            var session_id_buf: [64]u8 = undefined;
            const session_id = std.fmt.bufPrint(&session_id_buf, "session_{}", .{std.time.timestamp()}) catch "session_error";

            // Return JSON response
            var response_buf: [256]u8 = undefined;
            const response = std.fmt.bufPrint(&response_buf, "{{\"sessionId\":\"{s}\",\"agentType\":\"{s}\"}}", .{ session_id, agent_type }) catch unreachable;

            res.status = 200;
            res.body = response;

            std.debug.print("Created session: {s} with agentType: {s}\n", .{ session_id, agent_type });
        }
    }.handler);

    const HttpRoutes = struct {
        pub fn setup(http_port: u16, router: anytype) !void {
            std.log.info("HTTP server listening on http://127.0.0.1:{d}/", .{http_port});

            // Command endpoint
            router.post("/api/command", http_handlers.commandHandler, .{});

            // SSE stream endpoint
            router.get("/api/stream/:session_id", http_handlers.streamHandler, .{});

            // Session management endpoints (synchronous - returns response directly)
            router.post("/api/session/create", http_handlers.session_create_handler, .{});
            router.get("/api/session", http_handlers.session_list_handler, .{});
            router.get("/api/session/:session_id", http_handlers.session_get_handler, .{});
            router.get("/api/session/:session_id/messages", http_handlers.session_message_handler, .{});
            router.get("/api/session/exists/:session_id", http_handlers.session_exist_handler, .{});
            router.get("/api/session/latest", http_handlers.getLatestSessionByDirHandler, .{});

            // Ping endpoint - checks if session is connected via SSE
            router.get("/api/ping/:session_id", http_handlers.ping_handler, .{});
        }
    };
    try server.runWithConfig(HttpRoutes.setup);
}
