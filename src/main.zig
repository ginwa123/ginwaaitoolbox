const std = @import("std");

const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const http_handlers = root_mod.http_handlers;
const httpz = http_server.httpz;
const ai_workflow = root_mod.ai_workflow;
const ai_workflow_mod = root_mod.ai_workflow;
const session_monitor = root_mod.session_monitor;
const cronjob = root_mod.cronjob;
const sqlite = root_mod.sqlite;
const migrations = root_mod.migrations;
const activity_registry = root_mod.session.activity_registry;
const helpers = root_mod.helpers;
const config = root_mod.config;

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

    const HttpRoutes = struct {
        pub fn setup(http_port: u16, router: anytype) !void {
            std.log.info("HTTP server listening on http://127.0.0.1:{d}/", .{http_port});

            // Command endpoint (generic command handler)
            router.post("/api/command", http_handlers.commandHandler, .{});

            // SSE stream endpoint
            router.get("/api/stream/:session_id", http_handlers.streamHandler, .{});

            // Session management endpoints
            router.options("/api/session", http_handlers.corsPreflightHandler, .{});
            router.post("/api/session", http_handlers.session_create_handler, .{});
            router.get("/api/session", http_handlers.session_list_handler, .{});
            router.get("/api/session/:session_id", http_handlers.session_get_handler, .{});
            router.get("/api/session/:session_id/messages", http_handlers.session_message_handler, .{});
            router.get("/api/session/exists/:session_id", http_handlers.session_exist_handler, .{});
            router.get("/api/session/latest", http_handlers.getLatestSessionByDirHandler, .{});

            // Session actions
            router.post("/api/session/:session_id/cancel", http_handlers.sessionCancelHandler, .{});
            router.post("/api/session/:session_id/compact", http_handlers.sessionCompactHandler, .{});

            // LLM workflow endpoint
            router.post("/api/llm/run", http_handlers.llmRunHandler, .{});

            // Ping endpoint - checks if session is connected via SSE
            router.get("/api/ping/:session_id", http_handlers.ping_handler, .{});
        }
    };
    try server.runWithConfig(HttpRoutes.setup);
}
