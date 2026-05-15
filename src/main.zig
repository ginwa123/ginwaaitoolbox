const std = @import("std");

const nalar_mod = @import("nalarcore");
const ai_mod = nalar_mod.ai_mod;
// const http_server = nalar_mod.http_server;
// const http_handlers = nalar_mod.http_handlers;
// const httpz = http_server.httpz;
// const ai_workflow = nalar_mod.ai_workflow;
// const session_monitor = nalar_mod.session_monitor;
// const cronjob = nalar_mod.cronjob;
const sqlite = nalar_mod.sqlite;
// const migrations = nalar_mod.migrations;
// const activity_registry = nalar_mod.session.session_registry;
const helpers = nalar_mod.helpers;
// const config = nalar_mod.config;
// const llm_history = nalar_mod.llm_history;
// const startup = nalar_mod.ai_workflow.startup;
const gserverz = nalar_mod.gserverz;


pub fn main(init: std.process.Init) !void {
    const arena_allocator = init.arena;
    defer _ = arena_allocator.reset(.free_all);
    const parent_allocator = arena_allocator.allocator();
    const environment = init.environ_map;
    const io = init.io;

    if (init.environ_map.get("HOME")) |home| {
        std.log.info("HOME={s}", .{home});
    }

    var llm_config = nalar_mod.config.LlmConfig.init(parent_allocator, io, null, environment) catch |err| {
        std.log.err("Failed to load config: {s}", .{@errorName(err)});
        return err;
    };
    defer llm_config.deinit();
    try llm_config.validate();

    const db_path = try helpers.db_path.getDbPath(parent_allocator, io, environment);
    defer parent_allocator.free(db_path);

    var dbSqlite: sqlite.SqliteBackend = .{};
    defer dbSqlite.deinit();
    try dbSqlite.init(io, db_path);

    var migrationManager = ai_mod.migration.MigrationManager.init(parent_allocator, &dbSqlite);
    defer migrationManager.deinit();
    try ai_mod.migration.registerAllMigrations(&migrationManager);
    try migrationManager.runMigrations();

    const tmp_path = environment.get("TMPDIR") orelse
        environment.get("TEMP") orelse
        environment.get("TMP") orelse
        "/tmp";
    const log_file_path = try std.fs.path.join(parent_allocator, &.{ tmp_path, "agentic_coding.log" });
    defer parent_allocator.free(log_file_path);

    nalar_mod.setPanicLogPath(log_file_path);

    nalar_mod.logger.initGlobalColor(parent_allocator, io, .{
        .min_level = .debug,
        .output_mode = .file,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    defer nalar_mod.logger.deinitGlobal(io);

    const global_logger_ptr = nalar_mod.logger.getGlobal().?;

    const ctxParent = try parent_allocator.create(ai_mod.models.ContextIPCTui);
    defer parent_allocator.destroy(ctxParent);
    ctxParent.* = ai_mod.models.ContextIPCTui{
        .allocator = parent_allocator,
        .io = io,
        .db = &dbSqlite,
        .llm_config = &llm_config,
        .logger = global_logger_ptr,
        .environment = environment,
        .active_loops = undefined, // Will be set below after initialization
    };

    _ = try ai_mod.models.setSingleton(ctxParent);

    var active_loops = ai_mod.models.ActiveLoops.init(parent_allocator);
    defer active_loops.deinit(parent_allocator);
    ctxParent.active_loops = &active_loops;

    // activity_registry.init_global_registry(parent_allocator, io);
    // defer activity_registry.deinit_global_registry();

    // var monitor = session_monitor.SessionMonitor.spawn(io) catch |err| {
    //     std.log.err("Failed to spawn session monitor: {s}", .{@errorName(err)});
    //     return err;
    // };
    // defer monitor.stop();

    // const cronjob_config = cronjob.CronjobConfig{
    //     .check_interval_ms = 30_000,
    //     .db_path = db_path,
    // };
    // var cron = cronjob.cronjob.Cronjob.spawn(parent_allocator, cronjob_config) catch |err| {
    //     std.log.err("Failed to spawn cronjob: {s}", .{@errorName(err)});
    //     return err;
    // };
    // defer cron.stop();

    var port: u16 = 0;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
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

    // var server = http_server.HttpServer.init(parent_allocator, io, ctxParent, port, environment);
    //
    // // Start the SSE cleanup background thread
    // server.startSseCleanupThread() catch |err| {
    //     std.log.err("Failed to start SSE cleanup thread: {s}", .{@errorName(err)});
    //     // Non-fatal - server can still run without cleanup
    // };

    // startup(parent_allocator, io, environment, &dbSqlite, &llm_config, ctxParent) catch |err| {
    //     std.log.err("Failed to start startup worker: {s}", .{@errorName(err)});
    // };

    const address = try gserverz.Address.init(port);
    const gs = try gserverz.GinwaServer.init(parent_allocator, io, address);
    defer gs.deinit();
    //
    // std.debug.print("HTTP Server listening on 127.0.0.1:29584...\n", .{});
    // std.debug.print("Test with: curl http://127.0.0.1:29584/\n", .{});
    // std.debug.print("Press Ctrl+C to stop\n\n", .{});
    //
    // // try gs.router.get("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
    // // try gs.router.post("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
    // // try gs.router.get("/api/stream/:session_id", http_handlers.streamHandler, .{});
    // // try gs.router.options("/api/session", http_handlers.corsPreflightHandler, .{});
    try gs.router.post("/api/session", ai_mod.http_handlers.sessionCreateHandler);
    try gs.router.get("/api/session", ai_mod.http_handlers.sessionListHandler);
    //
    // // try gs.router.get("/api/session/stream", http_handlers.sessionStreamHandler, ctxParent);
    try gs.router.get("/api/session/:session_id", ai_mod.http_handlers.session_get_handler);
    try gs.router.get("/api/session/:session_id/messages", ai_mod.http_handlers.session_message_handler);
    // try gs.router.get("/api/session/exists/:session_id", http_handlers.session_exist_handler, ctxParent);
    // try gs.router.get("/api/session/latest", http_handlers.getLatestSessionByDirHandler, ctxParent);
    // try gs.router.post("/api/session/:session_id/cancel", http_handlers.sessionCancelHandler, ctxParent);
    // try gs.router.post("/api/session/:session_id/compact", http_handlers.sessionCompactHandler, ctxParent);
    // try gs.router.get("/api/session/:session_id/queue/messages", http_handlers.sessionQueueGetHandler, ctxParent);
    // try gs.router.delete("/api/session/:session_id/queue/message", http_handlers.sessionQueueDeleteHandler, ctxParent);
    // try gs.router.get("/api/ping/:session_id", http_handlers.ping_handler, ctxParent);
    //
    // // Worker API
    // try gs.router.get("/api/workers", http_handlers.worker_list_handler, ctxParent);
    //
    // // LLM API aliases (desktop app uses /api/llm/*)
    // try gs.router.post("/api/llm/session", http_handlers.sessionCreateHandler, ctxParent);
    try gs.router.get("/api/llm/session", ai_mod.http_handlers.sessionListHandler);
    try gs.router.get("/api/llm/session/:session_id/messages", ai_mod.http_handlers.session_message_handler);
    // try gs.router.get("/api/llm/stream/:session_id", http_handlers.streamHandler, ctxParent);
    // try gs.router.post("/api/llm/session/:session_id/cancel", http_handlers.sessionCancelHandler, ctxParent);
    //
    // // Desktop app routes (system, health, workspaces)
    try gs.router.get("/health", ai_mod.http_handlers.healthHandler);
    try gs.router.get("/api/skills", ai_mod.http_handlers.skillsListHandler);
    try gs.router.get("/api/skills/:name", ai_mod.http_handlers.skillDetailHandler);
    try gs.router.delete("/api/skills", ai_mod.http_handlers.skillDeleteHandler);
    try gs.router.get("/api/git/status", ai_mod.http_handlers.gitStatusHandler);
    // try gs.router.get("/api/system/folder", http_handlers.systemFolderHandler, ctxParent);
    // try gs.router.get("/api/workspaces", http_handlers.workspacesListHandler, ctxParent);
    // try gs.router.post("/api/workspaces", http_handlers.workspacesCreateHandler, ctxParent);
    // try gs.router.get("/api/workspaces/:id", http_handlers.workspaceGetHandler, ctxParent);
    // try gs.router.put("/api/workspaces/:id", http_handlers.workspaceUpdateHandler, ctxParent);
    // try gs.router.delete("/api/workspaces/:id", http_handlers.workspaceDeleteHandler, ctxParent);
    // try gs.router.post("/api/workspaces/:workspace_id/items", http_handlers.workspaceItemsCreateHandler, ctxParent);
    // try gs.router.get("/api/workspaces/:workspace_id/items", http_handlers.workspaceItemsListHandler, ctxParent);
    // try gs.router.get("/api/workspaces/:workspace_id/items/:item_id", http_handlers.workspaceItemsGetHandler, ctxParent);
    // try gs.router.put("/api/workspaces/:workspace_id/items/:item_id", http_handlers.workspaceItemsUpdateHandler, ctxParent);
    // try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id", http_handlers.workspaceItemsDeleteHandler, ctxParent);
    // try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/tasks", http_handlers.tasksListHandler, ctxParent);
    // try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks", http_handlers.tasksCreateHandler, ctxParent);
    // try gs.router.put("/api/workspaces/tasks/:task_id", http_handlers.tasksUpdateByIdHandler, ctxParent);
    // try gs.router.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", http_handlers.tasksUpdateHandler, ctxParent);
    // try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", http_handlers.tasksDeleteHandler, ctxParent);
    //
    try gs.listen();

    // const HttpRoutes = struct {
    //     pub fn setup(http_port: u16, router: anytype) !void {
    //         std.log.info("HTTP server listening on http://127.0.0.1:{d}/", .{http_port});
    //         router.post("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
    //         router.get("/api/stream/:session_id", http_handlers.streamHandler, .{});
    //         router.options("/api/session", http_handlers.corsPreflightHandler, .{});
    //         router.post("/api/session", http_handlers.sessionCreateHandler, .{});
    //         router.get("/api/session", http_handlers.sessionListHandler, .{});
    //         router.get("/api/session/stream", http_handlers.sessionStreamHandler, .{});
    //         router.get("/api/session/:session_id", http_handlers.session_get_handler, .{});
    //         router.get("/api/session/:session_id/messages", http_handlers.session_message_handler, .{});
    //         router.get("/api/session/exists/:session_id", http_handlers.session_exist_handler, .{});
    //         router.get("/api/session/latest", http_handlers.getLatestSessionByDirHandler, .{});
    //         router.post("/api/session/:session_id/cancel", http_handlers.sessionCancelHandler, .{});
    //         router.post("/api/session/:session_id/compact", http_handlers.sessionCompactHandler, .{});
    //         router.get("/api/session/:session_id/queue/messages", http_handlers.sessionQueueGetHandler, .{});
    //         router.delete("/api/session/:session_id/queue/message", http_handlers.sessionQueueDeleteHandler, .{});
    //         router.get("/api/ping/:session_id", http_handlers.ping_handler, .{});
    //
    //         // Worker API
    //         router.get("/api/workers", http_handlers.worker_list_handler, .{});
    //
    //         // LLM API aliases (desktop app uses /api/llm/*)
    //         router.post("/api/llm/session", http_handlers.sessionCreateHandler, .{});
    //         router.get("/api/llm/session", http_handlers.sessionListHandler, .{});
    //         router.get("/api/llm/session/:session_id/messages", http_handlers.session_message_handler, .{});
    //         router.get("/api/llm/stream/:session_id", http_handlers.streamHandler, .{});
    //         router.post("/api/llm/session/:session_id/cancel", http_handlers.sessionCancelHandler, .{});
    //
    //         // Desktop app routes (system, health, workspaces)
    //         router.get("/health", http_handlers.healthHandler, .{});
    //         router.get("/api/health", http_handlers.healthHandler, .{});
    //         router.get("/api/skills", http_handlers.skillsListHandler, .{});
    //         router.get("/api/skills/:name", http_handlers.skillDetailHandler, .{});
    //         router.delete("/api/skills", http_handlers.skillDeleteHandler, .{});
    //         // router.get("/api/git/status", http_handlers.gitStatusHandler, .{});
    //         router.get("/api/system/folder", http_handlers.systemFolderHandler, .{});
    //         router.get("/api/workspaces", http_handlers.workspacesListHandler, .{});
    //         router.post("/api/workspaces", http_handlers.workspacesCreateHandler, .{});
    //         router.get("/api/workspaces/:id", http_handlers.workspaceGetHandler, .{});
    //         router.put("/api/workspaces/:id", http_handlers.workspaceUpdateHandler, .{});
    //         router.delete("/api/workspaces/:id", http_handlers.workspaceDeleteHandler, .{});
    //         router.post("/api/workspaces/:workspace_id/items", http_handlers.workspaceItemsCreateHandler, .{});
    //         router.get("/api/workspaces/:workspace_id/items", http_handlers.workspaceItemsListHandler, .{});
    //         router.get("/api/workspaces/:workspace_id/items/:item_id", http_handlers.workspaceItemsGetHandler, .{});
    //         router.put("/api/workspaces/:workspace_id/items/:item_id", http_handlers.workspaceItemsUpdateHandler, .{});
    //         router.delete("/api/workspaces/:workspace_id/items/:item_id", http_handlers.workspaceItemsDeleteHandler, .{});
    //         router.get("/api/workspaces/:workspace_id/items/:item_id/tasks", http_handlers.tasksListHandler, .{});
    //         router.post("/api/workspaces/:workspace_id/items/:item_id/tasks", http_handlers.tasksCreateHandler, .{});
    //         router.put("/api/workspaces/tasks/:task_id", http_handlers.tasksUpdateByIdHandler, .{});
    //         router.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", http_handlers.tasksUpdateHandler, .{});
    //         router.delete("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", http_handlers.tasksDeleteHandler, .{});
    //     }
    // };
    // try server.runWithConfig(HttpRoutes.setup);
}
