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
const startup = nalar_mod.ai_workflow.startup;

pub fn main(init: std.process.Init) !void {
    const arena_allocator = init.arena;
    defer arena_allocator.deinit();
    const parent_allocator = arena_allocator.allocator();
    const environment = init.environ_map;
    const io = init.io;

    if (init.environ_map.get("HOME")) |home| {
        std.log.info("HOME={s}", .{home});
    }

    var llm_config = nalar_mod.config.LlmConfig.init(parent_allocator, null, environment) catch |err| {
        std.log.err("Failed to load config: {s}", .{@errorName(err)});
        return err;
    };
    defer llm_config.deinit();
    try llm_config.validate();

    const db_path = try helpers.db_path.getDbPath(parent_allocator, io, environment);
    defer parent_allocator.free(db_path);

    var dbSqlite: sqlite.SqliteBackend = .{};
    defer dbSqlite.deinit();
    try dbSqlite.init(db_path);

    var migrationManager = migrations.MigrationManager.init(parent_allocator, &dbSqlite);
    defer migrationManager.deinit();
    try migrations.registerAllMigrations(&migrationManager);
    try migrationManager.runMigrations();

    const tmp_path = environment.get("TMPDIR") orelse
        environment.get("TEMP") orelse
        environment.get("TMP") orelse
        "/tmp";
    const log_file_path = try std.fs.path.join(parent_allocator, &.{ tmp_path, "agentic_coding.log" });
    defer parent_allocator.free(log_file_path);

    nalar_mod.setPanicLogPath(log_file_path);

    nalar_mod.logger.initGlobalColor(parent_allocator, .{
        .min_level = .debug,
        .output_mode = .file,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    defer nalar_mod.logger.deinitGlobal();

    const global_logger_ptr = nalar_mod.logger.getGlobal().?;

    const ctxParent = try parent_allocator.create(ai_workflow_mod.ContextIPCTui);
    defer parent_allocator.destroy(ctxParent);
    ctxParent.* = ai_workflow_mod.ContextIPCTui{
        .db = &dbSqlite,
        .llm_config = &llm_config,
        .logger = global_logger_ptr,
    };

    activity_registry.init_global_registry(parent_allocator);
    defer activity_registry.deinit_global_registry();

    var monitor = session_monitor.SessionMonitor.spawn() catch |err| {
        std.log.err("Failed to spawn session monitor: {s}", .{@errorName(err)});
        return err;
    };
    defer monitor.stop();

    const cronjob_config = cronjob.CronjobConfig{
        .check_interval_ms = 30_000,
        .db_path = db_path,
    };
    var cron = cronjob.cronjob.Cronjob.spawn(parent_allocator, cronjob_config) catch |err| {
        std.log.err("Failed to spawn cronjob: {s}", .{@errorName(err)});
        return err;
    };
    defer cron.stop();

    var port: u16 = 0;

    var args_iter = std.process.argsIterate(init.minimal.args);
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args_iter.next()) |port_arg| {
                port = std.fmt.parseInt(u16, port_arg, 10) catch {
                    std.log.err("Error: invalid port number", .{});
                    return error.InvalidArgs;
                };
            } else {
                std.log.err("Error: --port requires a value", .{});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Usage: nalar [--port PORT]\n", .{});
            std.debug.print("  --port PORT    Port to run the HTTP server on (default: 8080)\n", .{});
            return;
        }
    }

    var server = http_server.HttpServer.init(parent_allocator, ctxParent, port);

    startup(parent_allocator, &server) catch |err| {
        std.log.err("Failed to start startup worker: {s}", .{@errorName(err)});
    };

    const HttpRoutes = struct {
        pub fn setup(http_port: u16, router: anytype) !void {
            std.log.info("HTTP server listening on http://127.0.0.1:{d}/", .{http_port});
            router.post("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
            router.get("/api/stream/:session_id", http_handlers.streamHandler, .{});
            router.options("/api/session", http_handlers.corsPreflightHandler, .{});
            router.post("/api/session", http_handlers.sessionCreateHandler, .{});
            router.get("/api/session", http_handlers.sessionListHandler, .{});
            router.get("/api/session/stream", http_handlers.sessionStreamHandler, .{});
            router.get("/api/session/:session_id", http_handlers.session_get_handler, .{});
            router.get("/api/session/:session_id/messages", http_handlers.session_message_handler, .{});
            router.get("/api/session/exists/:session_id", http_handlers.session_exist_handler, .{});
            router.get("/api/session/latest", http_handlers.getLatestSessionByDirHandler, .{});
            router.post("/api/session/:session_id/cancel", http_handlers.sessionCancelHandler, .{});
            router.post("/api/session/:session_id/compact", http_handlers.sessionCompactHandler, .{});
            router.get("/api/session/:session_id/queue/messages", http_handlers.sessionQueueGetHandler, .{});
            router.delete("/api/session/:session_id/queue/message", http_handlers.sessionQueueDeleteHandler, .{});
            router.get("/api/ping/:session_id", http_handlers.ping_handler, .{});
        }
    };
    try server.runWithConfig(HttpRoutes.setup);
}
