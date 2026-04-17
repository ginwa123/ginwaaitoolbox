const std = @import("std");

const nalar_mod = @import("nalarcore");
const http_server = nalar_mod.http_server;
const http_handlers = nalar_mod.http_handlers;
const httpz = http_server.httpz;
const ai_workflow = nalar_mod.ai_workflow;
const ai_workflow_mod = nalar_mod.ai_workflow;
const session_monitor = nalar_mod.session_monitor;
const cronjob = nalar_mod.cronjob;
const sqlite = nalar_mod.sqlite;
const migrations = nalar_mod.migrations;
const activity_registry = nalar_mod.session.session_registry;
const helpers = nalar_mod.helpers;
const config = nalar_mod.config;
const llm_history = nalar_mod.llm_history;

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

/// Startup handler - queries worker table and starts a thread for each worker
/// Called once during app initialization to bootstrap workers from database
pub fn startup(allocator: std.mem.Allocator, server: *http_server.HttpServer) !void {
    const global_logger_ptr = nalar_mod.logger.getGlobal().?;

    // Get session registry
    const registry = activity_registry.get_global_registry() orelse {
        std.log.err("Global session registry not initialized", .{});
        return error.RegistryNotInitialized;
    };

    // Get server context
    if (server.db) |db| {
        const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));

            // Query all workers from the database
            const workers = llm_history.get_active_workers(allocator, sqlite_db) catch |err| {
                global_logger_ptr.errFmt("Failed to query workers: {s}", .{@errorName(err)}) catch {};
                return err;
            };
            defer {
                for (workers) |w| w.deinit(allocator);
                allocator.free(workers);
            }

            if (workers.len == 0) {
                global_logger_ptr.info("No workers found in database, skipping startup") catch {};
                return;
            }

            global_logger_ptr.infoFmt("Found {d} workers in database, starting workflows...", .{workers.len}) catch {};

            // Spawn a workflow thread for each worker
            for (workers) |worker| {
                // Register session in session registry
                registry.register(worker.session_id) catch |err| {
                    global_logger_ptr.warnFmt("Failed to register worker {s}: {s}", .{ worker.session_id, @errorName(err) }) catch {};
                    continue;
                };

                // Mark as running
                registry.mark_running(worker.session_id);

                // Prepare workflow args on heap
                const workflow_args = try allocator.create(http_handlers.WorkflowArgs);
                workflow_args.* = .{
                    .allocator = allocator,
                    .sqlite_db = sqlite_db,
                    .logger = ctxTui.logger,
                    .session_id = try allocator.dupe(u8, worker.session_id),
                    .message = try allocator.dupe(u8, ""),
                    .cwd = try allocator.dupe(u8, worker.working_directory),
                    .api_key = ctxTui.llm_config.api_key,
                    .model = ctxTui.llm_config.model,
                    .base_url = ctxTui.llm_config.base_url,
                    .llm_config = ctxTui.llm_config,
                };

                // Spawn thread to run workflow
                const thread = try std.Thread.spawn(.{}, struct {
                    fn run(args: *http_handlers.WorkflowArgs) void {
                        defer {
                            args.allocator.free(args.session_id);
                            args.allocator.free(args.message);
                            args.allocator.free(args.cwd);
                            args.allocator.destroy(args);
                            // Mark as idle when workflow completes
                            if (activity_registry.get_global_registry()) |reg| {
                                reg.mark_idle(args.session_id);
                            }
                        }
                        var arena = std.heap.ArenaAllocator.init(args.allocator);
                        defer arena.deinit();
                        var workflow = ai_workflow.TUIWorkflow.init(args.sqlite_db, args.logger);
                        workflow.run(
                            arena.allocator(),
                            args.session_id,
                            args.message,
                            args.cwd,
                            args.api_key,
                            args.model,
                            args.base_url,
                            args.llm_config,
                        );
                    }
                }.run, .{workflow_args});
                thread.detach();

                global_logger_ptr.infoFmt("Startup worker started: {s} (cwd: {s})", .{ worker.session_id, worker.working_directory }) catch {};
            }

            return;
        }
    }

    std.log.err("Server not initialized for startup", .{});
    return error.ServerNotInitialized;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const parentAllocator = gpa.allocator();

    // Load LLM config from JSON file
    var llm_config = nalar_mod.config.LlmConfig.init(parentAllocator, null) catch |err| {
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
    nalar_mod.setPanicLogPath(log_file_path);

    // Initialize global logger
    nalar_mod.logger.initGlobalColor(parentAllocator, .{
        .min_level = .debug,
        .output_mode = .file,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    defer nalar_mod.logger.deinitGlobal();

    const global_logger_ptr = nalar_mod.logger.getGlobal().?;

    const ctxParent = try parentAllocator.create(ai_workflow_mod.ContextIPCTui);
    defer parentAllocator.destroy(ctxParent);
    ctxParent.* = ai_workflow_mod.ContextIPCTui{
        .db = &dbSqlite,
        .llm_config = &llm_config,
        .logger = global_logger_ptr,
    };

    // Initialize global session registry (combines cancellation + activity tracking)
    activity_registry.init_global_registry(parentAllocator);
    defer activity_registry.deinit_global_registry();

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

    // Start the startup worker (get worker and run TUIWorkflow in thread)
    startup(parentAllocator, &server) catch |err| {
        std.log.err("Failed to start startup worker: {s}", .{@errorName(err)});
        // Continue anyway - server can still handle HTTP requests
    };

    const HttpRoutes = struct {
        pub fn setup(http_port: u16, router: anytype) !void {
            std.log.info("HTTP server listening on http://127.0.0.1:{d}/", .{http_port});

            // SSE stream endpoint - specific routes BEFORE wildcard!
            router.post("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
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

            // Queue message operations
            router.get("/api/session/:session_id/queue/messages", http_handlers.sessionQueueGetHandler, .{});
            router.delete("/api/session/:session_id/queue/message", http_handlers.sessionQueueDeleteHandler, .{});

            // Ping endpoint - checks if session is connected via SSE
            router.get("/api/ping/:session_id", http_handlers.ping_handler, .{});
        }
    };
    try server.runWithConfig(HttpRoutes.setup);
}
