const std = @import("std");

const nalarcore = @import("nalarcore");
const ai_mod = nalarcore.ai_mod;
const sqlite = nalarcore.sqlite;
const helpers = nalarcore.helpers;
const gserverz = nalarcore.gserverz;
const startup = nalarcore.startup;

pub fn main(init: std.process.Init) !void {
    // const arena_allocator = init.arena;
    // defer arena_allocator.deinit();
    // const allocator = arena_allocator.allocator();

    const allocator = init.gpa;
    const environment = init.environ_map;
    const io = init.io;

    if (init.environ_map.get("HOME")) |home| {
        std.log.info("HOME={s}", .{home});
    }

    var llm_config = nalarcore.config.LlmConfig.init(allocator, io, null, environment) catch |err| {
        std.log.err("Failed to load config: {s}", .{@errorName(err)});
        return err;
    };
    // NOTE: do NOT `defer llm_config.deinit()` here — the value is moved
    // into the heap-allocated `initial_llm_config_ptr` below. Shutdown
    // cleanup runs via `nalarcore.freeAllLlmConfigs(ctxParent)` at the end
    // of `main`.
    try llm_config.validate();

    // Move the initial LlmConfig onto the heap so the `LlmConfigHolder`
    // can later swap pointers without owning stack memory of `main`.
    const initial_llm_config_ptr = try allocator.create(nalarcore.config.LlmConfig);
    errdefer allocator.destroy(initial_llm_config_ptr);
    initial_llm_config_ptr.* = llm_config;

    const db_path = try helpers.db_path.getDbPath(allocator, io, environment);
    defer allocator.free(db_path);

    var dbSqlite: sqlite.SqliteBackend = .{};
    defer dbSqlite.deinit();
    try dbSqlite.init(io, db_path);

    var migrationManager = ai_mod.migration.MigrationManager.init(allocator, &dbSqlite);
    defer migrationManager.deinit();
    try ai_mod.migration.registerAllMigrations(&migrationManager);
    try migrationManager.runMigrations();

    const tmp_path = environment.get("TMPDIR") orelse
        environment.get("TEMP") orelse
        environment.get("TMP") orelse
        "/tmp";
    const log_file_path = try std.fs.path.join(allocator, &.{ tmp_path, "agentic_coding.log" });
    defer allocator.free(log_file_path);

    nalarcore.setPanicLogPath(log_file_path);

    nalarcore.logger.initGlobalColor(allocator, io, .{
        .min_level = .debug,
        .output_mode = .file,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    defer nalarcore.logger.deinitGlobal(io);

    const global_logger_ptr = nalarcore.logger.getGlobal().?;

    const ctxParent = try allocator.create(nalarcore.ContextIPCTui);
    defer allocator.destroy(ctxParent);
    ctxParent.* = nalarcore.ContextIPCTui{
        .allocator = allocator,
        .io = io,
        .db = &dbSqlite,
        .llm_config_holder = .{ .current = initial_llm_config_ptr },
        .logger = global_logger_ptr,
        .environment = environment,
        .active_loops = undefined, // Will be set below after initialization
        .event_bus = undefined, // Will be set below after initialization
        .server = undefined, // Will be set below after initialization
        .group_emit_session_create = .init,
    };

    _ = try nalarcore.setSingleton(ctxParent);

    const event_bus_mod = nalarcore.event_bus;
    var event_bus = event_bus_mod.EventBus.init("my-bus", allocator, io);
    defer event_bus.deinit();
    ctxParent.event_bus = &event_bus;

    var active_loops = ai_mod.models.ActiveLoops.init(allocator);
    defer active_loops.deinit(allocator);
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

    startup.startup(allocator, ctxParent) catch |err| {
        std.log.err("Failed to start startup worker: {s}", .{@errorName(err)});
    };
    //

    const address = try gserverz.Address.init(port);
    const gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    try group.concurrent(
        io,
        struct {
            fn run(gss: *gserverz.GinwaServer) void {
                gss.sse_manager.startEventLoop(5) catch {};
            }
        }.run,
        .{gs},
    );

    ctxParent.server = gs;
    // // try gs.router.get("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
    // // try gs.router.post("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
    // // try gs.router.get("/api/stream/:session_id", http_handlers.streamHandler, .{});
    // // try gs.router.options("/api/session", http_handlers.corsPreflightHandler, .{});
    try gs.router.post("/api/session", ai_mod.http_handlers.sessionCreateHandler);
    try gs.router.put("/api/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler);
    try gs.router.get("/api/session", ai_mod.http_handlers.sessionListHandler);
    //
    // // try gs.router.get("/api/session/stream", http_handlers.sessionStreamHandler, ctxParent);
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
    try gs.router.get("/api/workers", ai_mod.http_handlers.worker_list_handler);
    try gs.router.sse("/api/workers/stream", ai_mod.http_handlers.workersStreamHandler);
    //
    // // LLM API aliases (desktop app uses /api/llm/*)
    try gs.router.post("/api/llm/session", ai_mod.http_handlers.sessionCreateHandler);
    try gs.router.put("/api/llm/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler);
    try gs.router.post("/api/llm/session/:session/stop", ai_mod.http_handlers.sessionStopHandler);

    // try gs.router.post("/api/llm/session", ai_mod.http_handlers.sessionCreateHandler);

    try gs.router.get("/api/llm/session", ai_mod.http_handlers.sessionListHandler);
    try gs.router.get("/api/llm/session/:session_id/messages", ai_mod.http_handlers.session_message_handler);
    try gs.router.get("/api/llm/session/:session_id/queue_messages", ai_mod.http_handlers.queueMessagesGetHandler);
    try gs.router.sse("/api/llm/session/:session_id/queue_messages/stream", ai_mod.http_handlers.queueMessagesStreamHandler);
    try gs.router.sse("/api/llm/stream/:session_id", ai_mod.http_handlers.llmHistorySSE);
    try gs.router.sse("/api/sessions/stream", ai_mod.http_handlers.sessionsStreamHandler);
    // try gs.router.post("/api/llm/session/:session_id/cancel", http_handlers.sessionCancelHandler, ctxParent);
    //
    // // Desktop app routes (system, health, workspaces)
    try gs.router.get("/health", ai_mod.http_handlers.healthHandler);
    try gs.router.get("/api/skills", ai_mod.http_handlers.skillsListHandler);
    try gs.router.get("/api/skills/:name", ai_mod.http_handlers.skillDetailHandler);
    try gs.router.delete("/api/skills", ai_mod.http_handlers.skillDeleteHandler);

    // Memories routes
    try gs.router.get("/api/memories", ai_mod.http_handlers.memoriesListHandler);

    // Nalar config routes (reads/writes config.json as nalar.json mapping)
    try gs.router.get("/api/config/nalar", ai_mod.http_handlers.nalarConfigGetHandler);
    try gs.router.put("/api/config/nalar", ai_mod.http_handlers.nalarConfigPutHandler);

    try gs.router.get("/api/git/status", ai_mod.http_handlers.gitStatusHandler);
    try gs.router.get("/api/git/changes", ai_mod.http_handlers.gitChangesHandler);
    try gs.router.get("/api/git/file/diff", ai_mod.http_handlers.gitFileDiffHandler);
    try gs.router.get("/api/git/file/read", ai_mod.http_handlers.gitFileReadHandler);
    try gs.router.post("/api/git/stage", ai_mod.http_handlers.gitStageHandler);
    try gs.router.post("/api/git/unstage", ai_mod.http_handlers.gitUnstageHandler);
    try gs.router.get("/api/system/folder", ai_mod.http_handlers.systemFolderHandler);
    try gs.router.get("/api/workspaces", ai_mod.http_handlers.workspacesListHandler);
    try gs.router.post("/api/workspaces", ai_mod.http_handlers.workspacesCreateHandler);
    try gs.router.get("/api/workspaces/:id", ai_mod.http_handlers.workspaceGetHandler);
    try gs.router.put("/api/workspaces/:id", ai_mod.http_handlers.workspaceUpdateHandler);
    try gs.router.delete("/api/workspaces/:id", ai_mod.http_handlers.workspaceDeleteHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsCreateHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsListHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsGetHandler);
    try gs.router.put("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsUpdateHandler);
    try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsDeleteHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksListHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksCreateHandler);
    try gs.router.put("/api/workspaces/tasks/:task_id", ai_mod.http_handlers.tasksUpdateByIdHandler);
    try gs.router.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksUpdateHandler);
    try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksDeleteHandler);

    // testing debug
    try gs.router.post("/test/shutdown", ai_mod.http_handlers.shutdownHandler);
    try gs.router.get("/test/sessions/client_ids", ai_mod.http_handlers.sessionToClientIdsHandler);

    _ = try event_bus.subscribe(ai_mod.ai_workflow.RunParamsNew, "ai_worker_flow", ai_mod.ai_workflow.CallbackAiWorkerFlow.callback);
    ctxParent.server.sse_manager.on_disconnect = ai_mod.handleClientDisconnect;

    try gs.listen();

    // Clean shutdown after listen() returns (after shutdown endpoint is called)
    gs.sse_manager.stop();

    // Free the live LlmConfig (and any "previous" pointer from a swap that
    // happened during this session). Must run AFTER `gs.sse_manager.stop()`
    // and BEFORE `ctxParent` is destroyed, so no reader is still in flight.
    nalarcore.freeAllLlmConfigs(ctxParent);

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
