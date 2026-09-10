const std = @import("std");

const nalarcore = @import("nalarcore");
const ai_mod = nalarcore.ai_mod;
const sqlite = nalarcore.sqlite;
const database = nalarcore.database;
// `helpers` is now its own Zig module (see `src/helpers/build.zig`);
// promoted out of `nalarcore` so multiple sub-packages can share a
// single module instance. The root build.zig wires it via
// `mod.addImport("helpers", helpers_mod)` — consumers reference it
// directly via `@import("helpers")`.
const helpers = @import("helpers");
const gserverz = nalarcore.gserverz;
const startup = nalarcore.startup;
const static_files = nalarcore.static_files;
const migration = nalarcore.migrations_mod.migration;
// cleanup_stale_worker is re-exported via nalarcore (root.zig) so the
// exe module doesn't directly @import the file — that would put it
// in both modules and trigger Zig's "file exists in two modules"
// error. See root.zig's `pub const cleanup_stale_worker = ...`.
const cleanup_stale_worker = nalarcore.cleanup_stale_worker;
// cleanup_stale_background_process: same routing as above — re-exported
// via nalarcore so the exe module doesn't directly @import the file.
const cleanup_stale_background_process = nalarcore.cleanup_stale_background_process;

// state_file and main_service are re-exported from nalarcore (see src/root.zig).
// Access them via nalarcore.* to avoid duplicating the module symbol
// across both root files.
const state_file = nalarcore.state_file;
const main_service = nalarcore.main_service;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const environment = init.environ_map;
    const io = init.io;

    // Service subcommand dispatch (Chunk 3 of the decoupled-nalar-service
    // plan): if argv[1] == "service", route the rest of argv to the
    // service module and exit before doing any other init.
    if (try dispatchServiceSubcommand(allocator, io, environment, init)) return;

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
    // Was: try llm_config.validate();
    //
    // Now: log warnings but don't block startup. An empty/placeholder
    // config (e.g. auto-created on first run when no config.json
    // exists) is allowed to start the server. The server is reachable
    // for non-LLM endpoints (workspaces, kanban, memories, etc.); LLM
    // calls will fail naturally with a clear "empty api_key" error
    // until the user fills in config.json.
    //
    // The PUT handler (`nalar_config_put.zig:234`) keeps the strict
    // behavior — when the user actively edits their config via the UI,
    // an empty api_key is still rejected with a 200 + error body so
    // they can correct it.
    if (llm_config.validate()) |_| {
        // OK — config has all required fields.
    } else |err| {
        std.log.warn(
            "Config validation: {s}. LLM calls will fail until api_key/model/base_url are populated in ~/.config/nalar/config.json.",
            .{@errorName(err)},
        );
    }

    // Move the initial LlmConfig onto the heap so the `LlmConfigHolder`
    // can later swap pointers without owning stack memory of `main`.
    const initial_llm_config_ptr = try allocator.create(nalarcore.config.LlmConfig);
    errdefer allocator.destroy(initial_llm_config_ptr);
    initial_llm_config_ptr.* = llm_config;

    const db_path = try helpers.db_path.getDbPath(allocator, io, environment);
    defer allocator.free(db_path);

    var dbSqlite: database.Db = .{};
    defer dbSqlite.deinit();
    try database.open(&dbSqlite, io, .{ .sqlite_path = db_path });

    var migrationManager = migration.MigrationManager.init(allocator, &dbSqlite);
    defer migrationManager.deinit();
    try migration.registerAllMigrations(&migrationManager);
    try migrationManager.runMigrations();

    const tmp_path = environment.get("TMPDIR") orelse
        environment.get("TEMP") orelse
        environment.get("TMP") orelse
        "/tmp";
    const log_file_path = try std.fs.path.join(allocator, &.{ tmp_path, "agentic_coding.log" });
    defer allocator.free(log_file_path);

    nalarcore.setPanicLogPath(log_file_path);
    // Install OS-level crash handlers (SIGSEGV / SIGBUS / SIGABRT /
    // SIGILL / SIGFPE on POSIX; EXCEPTION_ACCESS_VIOLATION / etc on
    // Windows) BEFORE we start the HTTP server. The handler writes a
    // backtrace to the same log_file_path that panicHandler uses.
    // See src/service/crash_handler.zig for the contract.
    nalarcore.crash_handler.setCrashLogPath(log_file_path);
    nalarcore.crash_handler.installCrashHandlers();

    nalarcore.loggermod.initGlobalColor(allocator, io, .{
        .min_level = .debug,
        .output_mode = .file,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    defer nalarcore.loggermod.deinitGlobal(io);

    const global_logger_ptr = nalarcore.loggermod.getGlobal().?;

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
        .group_bg_watchers = .init,
    };

    _ = try nalarcore.setSingleton(ctxParent);

    // Eagerly init the process-global MCP registries on the process-lifetime
    // allocator and cache the pointers on the singleton struct, so every
    // call site goes through `di.mcp_stdio_registry` (via
    // `nalarcore.mcpStdioRegistry`) instead of lazy-init on first MCP use.
    // Shutdown hooks below kill spawned children + free registry arenas.
    ctxParent.mcp_stdio_registry = nalarcore.mcp_stdio.StdioRegistry.global(allocator);
    ctxParent.mcp_http_registry = nalarcore.mcp_http.HttpRegistry.global(allocator);
    defer nalarcore.mcp_stdio.StdioRegistry.deinitGlobal();
    defer nalarcore.mcp_http.HttpRegistry.deinitGlobal();

    const event_bus_mod = nalarcore.event_bus;
    var event_bus = event_bus_mod.EventBus.init("my-bus", allocator, io);
    defer event_bus.deinit();
    ctxParent.event_bus = &event_bus;

    // Submit the routine scheduler as a concurrent Io task. Runs
    // forever in the background, processing due routines every 5s.
    // Mirrors the project's async I/O pattern (the same one
    // session_create.zig:161 uses for per-session LLM work); no
    // thread is spawned. MUST run after setSingleton (so `di` is
    // available) and after the event bus is wired (so the
    // scheduler's fire path can emit ai_workflow.RunParamsNew
    // events).
    ai_mod.startup.start(allocator, &dbSqlite, ctxParent, io) catch |err| {
        std.log.err("Failed to submit routine scheduler: {s}", .{@errorName(err)});
    };

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

    var port: u16 = 8081;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
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
        } else if (std.mem.eql(u8, arg, "--static-dir")) {
            if (args_iter.next()) |static_dir_arg| {
                ctxParent.static_dir_path = try allocator.dupe(u8, static_dir_arg);
            } else {
                std.log.err("Error: --static-dir requires a value", .{});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Usage: nalar [--port PORT] [--static-dir DIR]\n", .{});
            std.debug.print("  --port PORT          Port to run the HTTP server on (default: 8081)\n", .{});
            std.debug.print("  --static-dir DIR     Serve files from DIR at HTTP / (e.g. for a webapp)\n", .{});
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

    // startup.startup(allocator, ctxParent) catch |err| {
    //     std.log.err("Failed to start startup worker: {s}", .{@errorName(err)});
    // };
    //

    const address = try gserverz.Address.init("127.0.0.1", port);
    const gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();

    // === Static file serving (--static-dir) ===
    // If the user passed `--static-dir DIR`, set up the static-files config
    // and wire a fallback handler into the server. The handler is invoked by
    // the listen loop whenever a request doesn't match any registered API
    // route — it writes a complete HTTP response (status + headers + body)
    // directly to the socket fd and returns. The handler signature takes
    // an opaque cfg pointer (the gserverz is feature-agnostic), so we
    // declare a top-level function that casts it back to a StaticDirConfig.
    var static_dir_cfg: ?*static_files.StaticDirConfig = null;
    defer if (static_dir_cfg) |cfg| {
        allocator.free(cfg.root_dir);
        allocator.destroy(cfg);
    };

    if (ctxParent.static_dir_path) |dir| {
        // Open + canonicalize the dir. openDirAbsolute surfaces "not a
        // directory" / "not found" as concrete errors which we forward to
        // the user via std.log + main's error return.
        const root_dir = std.Io.Dir.openDirAbsolute(io, dir, .{}) catch |err| {
            std.log.err("--static-dir '{s}' cannot be opened: {s}", .{ dir, @errorName(err) });
            return err;
        };
        defer root_dir.close(io);

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try root_dir.realPath(io, &path_buf);
        const abs_dir = try allocator.dupe(u8, path_buf[0..path_len]);

        const cfg = try allocator.create(static_files.StaticDirConfig);
        cfg.* = .{
            .root_dir = abs_dir,
            .allocator = allocator,
            // SPA fallback: reloads at Vue routes like /app/settings
            // would otherwise 404 (the build only produces index.html
            // + assets/, no /app/ directories). With this prefix, the
            // server serves index.html for missing paths under /app
            // (no extension) so Vue Router takes over client-side.
            // Matches the desktop app's router:
            // src/apps/desktop/src/router/index.ts — `path: '/app'`
            // and descendants. Must stay in sync if the SPA moves.
            .spa_fallback_prefix = "/app",
        };
        static_dir_cfg = cfg;

        // Register the top-level staticDirHandler (defined below main())
        // with the server. Pass `cfg` as the opaque user pointer; the
        // handler casts it back to *const StaticDirConfig and calls
        // static_files.serve().
        gs.setStaticDirHandler(
            staticDirHandler,
            @ptrCast(cfg),
        );
    }

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
    try gs.router.get("/api/session/:session_id/messages", ai_mod.http_handlers.sessionMessagesHandler);
    // try gs.router.get("/api/session/exists/:session_id", http_handlers.sessionExistHandler, ctxParent);
    // try gs.router.get("/api/session/latest", http_handlers.sessionLatestHandler, ctxParent);
    // try gs.router.post("/api/session/:session_id/cancel", http_handlers.sessionCancelHandler, ctxParent);
    // try gs.router.post("/api/session/:session_id/compact", http_handlers.sessionCompactHandler, ctxParent);
    // try gs.router.get("/api/session/:session_id/queue/messages", http_handlers.sessionQueueGetHandler, ctxParent);
    // try gs.router.delete("/api/session/:session_id/queue/message", http_handlers.sessionQueueDeleteHandler, ctxParent);
    // try gs.router.get("/api/ping/:session_id", http_handlers.pingHandler, ctxParent);
    //
    // // Worker API
    try gs.router.get("/api/workers", ai_mod.http_handlers.workerListHandler);
    //
    // // LLM API aliases (desktop app uses /api/llm/*)
    try gs.router.post("/api/llm/session", ai_mod.http_handlers.sessionCreateHandler);
    try gs.router.put("/api/llm/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler);
    try gs.router.post("/api/llm/session/:session/stop", ai_mod.http_handlers.sessionStopHandler);

    // try gs.router.post("/api/llm/session", ai_mod.http_handlers.sessionCreateHandler);

    try gs.router.get("/api/llm/session", ai_mod.http_handlers.sessionListHandler);
    try gs.router.get("/api/llm/session/:session_id/messages", ai_mod.http_handlers.sessionMessagesHandler);
    try gs.router.get("/api/llm/session/:session_id/queue_messages", ai_mod.http_handlers.queueMessagesGetHandler);
    // Session background-process endpoints (bg-completion): list + log
    // tail for `command background=true` rows. Registered next to
    // queue_messages. No shadowing risk: the `background_processes`
    // literal segment differs from every sibling (`messages`,
    // `queue_messages`, `stream`), and the longer `:pid/log` route is
    // registered AFTER the list route (route-order rule — longer,
    // more-specific paths after their prefix sibling).
    try gs.router.get("/api/llm/session/:session_id/background_processes", ai_mod.http_handlers.backgroundProcessesListHandler);
    try gs.router.get("/api/llm/session/:session_id/background_processes/:pid/log", ai_mod.http_handlers.backgroundProcessLogGetHandler);
    // In-flight stream snapshot (task_1787673548905_0 stream-resume-on-
    // reselect) — serves `{ active, content }` from the in-memory
    // stream_snapshot registry so a re-mounted ChatView can resume a
    // mid-stream session. Registered AFTER the sibling /messages +
    // /queue_messages routes (route-order rule).
    try gs.router.get("/api/llm/session/:session_id/stream", ai_mod.http_handlers.streamGetHandler);
    // Live spawn-batch snapshot (task_1788505292766_1
    // spawn-subagent-refresh-persist) — serves `{ tool_call_id,
    // progress[] }` from the in-memory subagent_progress registry so a
    // refreshed ChatView can rehydrate running rows for placeholder
    // spawn cards. Fresh `/api/subagent/...` prefix: no sibling
    // `:param` routes exist under it, so no shadowing risk.
    try gs.router.get("/api/subagent/progress/:tool_call_id", ai_mod.http_handlers.subAgentProgressGetHandler);
    // Unified SSE endpoint — single EventSource for all event families
    // (workers, sessions, kanban_column, kanban_task, per-session llm +
    // queue_messages). Replaces the 5 dedicated routes that previously
    // registered one EventSource per family. See
    // src/ai_workflow/tui/http_handlers/unified_events_sse.zig.
    try gs.router.sse("/api/events", ai_mod.http_handlers.unifiedEventsStreamHandler);
    // Test-only SSE emit (dev_sse_emit.zig) — gated by NALAR_TEST_SSE_EMIT=1,
    // 404 when off. Functional UI tests use it to drive the chatview's
    // SSE streaming path without a real LLM.
    try gs.router.post("/api/dev/sse/emit_llm", ai_mod.http_handlers.devSseEmitLlmHandler);
    // try gs.router.post("/api/llm/session/:session_id/cancel", http_handlers.sessionCancelHandler, ctxParent);
    //
    // // Desktop app routes (system, health, workspaces)
    try gs.router.get("/health", ai_mod.http_handlers.healthHandler);
    try gs.router.get("/api/skills", ai_mod.http_handlers.skillsListHandler);
    try gs.router.get("/api/skills/:name", ai_mod.http_handlers.skillDetailHandler);
    try gs.router.delete("/api/skills", ai_mod.http_handlers.skillDeleteHandler);

    // Memories routes
    try gs.router.get("/api/memories", ai_mod.http_handlers.memoriesListHandler);
    try gs.router.get("/api/memories/:name", ai_mod.http_handlers.memoryDetailHandler);
    try gs.router.post("/api/memories", ai_mod.http_handlers.memoryCreateHandler);
    try gs.router.put("/api/memories/:name", ai_mod.http_handlers.memoryUpdateHandler);
    try gs.router.delete("/api/memories/:name", ai_mod.http_handlers.memoryDeleteHandler);

    // Local Memories routes — scoped to <cwd>/.nalar/memories/. The
    // `cwd` is provided in the request body (POST/PUT) or query
    // string (GET/DELETE); handlers fall back to the nalar server's
    // own CWD via `io.realPath` when no explicit cwd is provided.
    try gs.router.get("/api/local-memories", ai_mod.http_handlers.localMemoriesListHandler);
    try gs.router.get("/api/local-memories/:name", ai_mod.http_handlers.localMemoryDetailHandler);
    try gs.router.post("/api/local-memories", ai_mod.http_handlers.localMemoryCreateHandler);
    try gs.router.put("/api/local-memories/:name", ai_mod.http_handlers.localMemoryUpdateHandler);
    try gs.router.delete("/api/local-memories/:name", ai_mod.http_handlers.localMemoryDeleteHandler);

    // Nalar config routes (reads/writes config.json as nalar.json mapping)
    try gs.router.get("/api/config/nalar", ai_mod.http_handlers.nalarConfigGetHandler);
    try gs.router.put("/api/config/nalar", ai_mod.http_handlers.nalarConfigPutHandler);
    try gs.router.delete("/api/config/nalar/profiles/:name", ai_mod.http_handlers.nalarConfigProfileDeleteHandler);

    // OS notification test endpoint — fires a real OS notification so
    // the user can verify their system can display them.
    try gs.router.post("/api/notify/test", ai_mod.http_handlers.notifyTestHandler);

    // MCP server "Test" probe — fires a tools/list request against a
    // candidate config without persisting anything. Used by the
    // Add/Edit MCP server modal's "Test" button so the user can
    // verify command + args + env + cwd (or URL + headers) actually
    // work before clicking Save.
    try gs.router.post("/api/mcp/test", ai_mod.http_handlers.mcpTestHandler);

    // Frontend error log endpoints — capture unhandled JS exceptions,
    // unhandled promise rejections, and existing console.error / console.warn
    // calls from the nalar-desktop webapp. See
    // docs/plans/2026-07-17-frontend-error-logs-design.md.
    try gs.router.post("/api/logs", ai_mod.http_handlers.frontendLogPostHandler);
    try gs.router.get("/api/logs", ai_mod.http_handlers.frontendLogGetHandler);

    try gs.router.get("/api/git/status", ai_mod.http_handlers.gitStatusHandler);
    try gs.router.get("/api/git/changes", ai_mod.http_handlers.gitChangesHandler);
    try gs.router.get("/api/git/file/diff", ai_mod.http_handlers.gitFileDiffHandler);
    try gs.router.get("/api/git/file/read", ai_mod.http_handlers.gitFileReadHandler);
    try gs.router.post("/api/git/stage", ai_mod.http_handlers.gitStageHandler);
    try gs.router.post("/api/git/unstage", ai_mod.http_handlers.gitUnstageHandler);
    try gs.router.get("/api/git/worktree/info", ai_mod.http_handlers.gitWorktreeInfoHandler);
    try gs.router.post("/api/git/pr", ai_mod.http_handlers.gitPrCreateHandler);
    try gs.router.get("/api/system/folder", ai_mod.http_handlers.systemFolderHandler);
    try gs.router.get("/api/workspaces", ai_mod.http_handlers.workspacesListHandler);
    try gs.router.post("/api/workspaces", ai_mod.http_handlers.workspacesCreateHandler);
    try gs.router.post("/api/workspaces/reorder", ai_mod.http_handlers.workspacesReorderHandler);
    try gs.router.get("/api/workspaces/:id", ai_mod.http_handlers.workspaceGetHandler);
    try gs.router.put("/api/workspaces/:id", ai_mod.http_handlers.workspaceUpdateHandler);
    try gs.router.delete("/api/workspaces/:id", ai_mod.http_handlers.workspaceDeleteHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsCreateHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsListHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/reorder", ai_mod.http_handlers.workspaceItemsReorderHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsGetHandler);
    try gs.router.put("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsUpdateHandler);
    try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsDeleteHandler);

    // Kanban workspace-item endpoints (item_type='kanban').
    //   POST   /items/kanban                       — create a kanban + seed 3 default columns
    //   GET    /items/:item_id/kanban/columns      — list columns
    //   POST   /items/:item_id/kanban/columns      — add a column
    //   PATCH  /items/:item_id/kanban/columns/:cid — rename and/or reorder a column
    //   DELETE /items/:item_id/kanban/columns/:cid — delete a column
    //   PATCH  /items/:item_id/tasks/:task_id/move — move a task across columns
    // See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 3).
    try gs.router.post("/api/workspaces/:workspace_id/items/kanban", ai_mod.http_handlers.workspaceItemsCreateKanbanHandler);
    // Design workspace-item endpoint (item_type='design').
    //   POST   /items/design                       — create a design (path is required;
    //                                              see design_items_create.zig)
    // See docs/superpowers/plans/2026-07-08-design-mode-redesign.md
    //   Chunk 8 (AppLayout + Sidebar Wiring).
    try gs.router.post("/api/workspaces/:workspace_id/items/design", ai_mod.http_handlers.workspaceItemsCreateDesignHandler);
    // Agent Mode workspace-item endpoint (item_type='agent') + sub-resources.
    // Plan: docs/superpowers/plans/2026-08-15-agent-mode.md
    // Task: task_1786962724740_0
    try gs.router.post("/api/workspaces/:workspace_id/items/agent", ai_mod.http_handlers.workspaceItemsCreateAgentHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsGetHandler);
    try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsUpdateHandler);
    try gs.router.post("/api/agents/:agent_id/knowledge", ai_mod.http_handlers.agentKnowledgeCreateHandler);
    // ORDER MATTERS: the literal `/knowledge/reorder` route MUST be
    // registered BEFORE `/knowledge/:knowledge_id` — matchRoute walks
    // routes in registration order, so the param route would otherwise
    // capture PATCH /knowledge/reorder with knowledge_id="reorder".
    try gs.router.patch("/api/agents/:agent_id/knowledge/reorder", ai_mod.http_handlers.agentKnowledgeReorderHandler);
    try gs.router.patch("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeUpdateHandler);
    try gs.router.delete("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeDeleteHandler);
    // Agent system-prompt CRUD (Migration 080). NOTE: `reorder` literal
    // MUST be registered BEFORE `:prompt_id` — the router walks routes in
    // registration order and `:prompt_id` would otherwise capture the
    // literal "reorder" segment (same shadowing trap as knowledge above).
    try gs.router.post("/api/agents/:agent_id/system_prompt", ai_mod.http_handlers.agentSystemPromptCreateHandler);
    try gs.router.patch("/api/agents/:agent_id/system_prompt/reorder", ai_mod.http_handlers.agentSystemPromptReorderHandler);
    try gs.router.patch("/api/agents/:agent_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentSystemPromptUpdateHandler);
    try gs.router.delete("/api/agents/:agent_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentSystemPromptDeleteHandler);
    try gs.router.get("/api/agent-tools/registry", ai_mod.http_handlers.agentToolsRegistryHandler);
    try gs.router.get("/api/agents/:agent_id/tools", ai_mod.http_handlers.agentToolsListHandler);
    try gs.router.post("/api/agents/:agent_id/tools", ai_mod.http_handlers.agentToolsCreateHandler);
    try gs.router.delete("/api/agents/:agent_id/tools/:tool_name", ai_mod.http_handlers.agentToolsDeleteHandler);
    // Agent-Kanbans mirror CRUD (Migration 081) — mirrors the agent block
    // above onto kanban boards. Plan:
    // docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md
    // Task: task_1787597624259_2.
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/agent_kanban", ai_mod.http_handlers.agentKanbansGetHandler);
    try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/agent_kanban", ai_mod.http_handlers.agentKanbansUpdateHandler);
    try gs.router.post("/api/agent-kanbans/:kanban_id/knowledge", ai_mod.http_handlers.agentKanbanKnowledgeCreateHandler);
    // ORDER MATTERS: the literal `/knowledge/reorder` route MUST be
    // registered BEFORE `/knowledge/:knowledge_id` — matchRoute walks
    // routes in registration order (same shadowing trap as the agent
    // knowledge routes above).
    try gs.router.patch("/api/agent-kanbans/:kanban_id/knowledge/reorder", ai_mod.http_handlers.agentKanbanKnowledgeReorderHandler);
    try gs.router.patch("/api/agent-kanbans/:kanban_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKanbanKnowledgeUpdateHandler);
    try gs.router.delete("/api/agent-kanbans/:kanban_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKanbanKnowledgeDeleteHandler);
    // NOTE: `reorder` literal MUST be registered BEFORE `:prompt_id`
    // (same shadowing trap as knowledge above).
    try gs.router.post("/api/agent-kanbans/:kanban_id/system_prompt", ai_mod.http_handlers.agentKanbanSystemPromptCreateHandler);
    try gs.router.patch("/api/agent-kanbans/:kanban_id/system_prompt/reorder", ai_mod.http_handlers.agentKanbanSystemPromptReorderHandler);
    try gs.router.patch("/api/agent-kanbans/:kanban_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentKanbanSystemPromptUpdateHandler);
    try gs.router.delete("/api/agent-kanbans/:kanban_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentKanbanSystemPromptDeleteHandler);
    try gs.router.get("/api/agent-kanbans/:kanban_id/tools", ai_mod.http_handlers.agentKanbanToolsListHandler);
    try gs.router.post("/api/agent-kanbans/:kanban_id/tools", ai_mod.http_handlers.agentKanbanToolsCreateHandler);
    try gs.router.delete("/api/agent-kanbans/:kanban_id/tools/:tool_name", ai_mod.http_handlers.agentKanbanToolsDeleteHandler);
    // Workspace-level routines (Migration 084, plan
    // 2026-09-10-workspace-items-routines) — first-class
    // `item_type='routine'`. Replaces the deleted per-task routes
    // (`POST .../tasks/:task_id/run`, `GET /api/routines`).
    try gs.router.post("/api/workspaces/:workspace_id/items/routine", ai_mod.http_handlers.workspaceItemsCreateRoutineHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/routine", ai_mod.http_handlers.workspaceRoutinesGetHandler);
    try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/routine", ai_mod.http_handlers.workspaceRoutinesUpdateHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/kanban/columns", ai_mod.http_handlers.kanbanColumnsListHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/kanban/columns", ai_mod.http_handlers.kanbanColumnsCreateHandler);
    try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id", ai_mod.http_handlers.kanbanColumnsUpdateHandler);
    try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id", ai_mod.http_handlers.kanbanColumnsDeleteHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/run_all_agents", ai_mod.http_handlers.runAllAgentsHandler);
    // Copy a kanban spec (column structure) from one kanban to another
    // (Chunk 2 of copy-kanban plan). Body: `{mode: "replace" | "append"}`.
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id", ai_mod.http_handlers.kanbanCopySpecHandler);
    try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/move", ai_mod.http_handlers.tasksMoveHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksListHandler);
    // Single-task GET for the kanban Task details dialog (plan:
    // docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md).
    // Registered AFTER the list route — matchRoute walks routes in
    // registration order (router.zig route-order rule).
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksGetHandler);
    // Kanban task tag autocomplete (Chunk 1 of plan
    // docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md).
    // Paginated suggestions for the kanban task detail dialog's tag chip
    // input. Ordered by frequency DESC, then last_used_at DESC. Query
    // params: ?limit=N (default 8, max 50) &offset=K. Response:
    // { tags: [{name,count,last_used_at}], has_more }.
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/kanban/tags", ai_mod.http_handlers.kanbanTagsListHandler);
    // Kanban-scoped task create endpoint with mode='create' | mode='create_and_run' discriminator.
    // Mirrors the generic /tasks POST but rejects 404 when the parent item is not a kanban.
    // Plan: docs/superpowers/plans/2026-08-14-kanban-task-create-endpoints.md
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/kanban/tasks", ai_mod.http_handlers.kanbanTasksCreateHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksCreateHandler);
    try gs.router.put("/api/workspaces/tasks/:task_id", ai_mod.http_handlers.tasksUpdateByIdHandler);
    // Migration 069 (2026-08-06) removed the filesystem-backed
    // kanban-task attachment endpoints (POST + GET wildcard). Task
    // images now live inline on `workspace_item_tasks.image_urls` as
    // `||`-delimited base64 data URLs — no upload path, no broken
    // `*` wildcard GET route, no `<path>/.nalar/attachments/<task>/`
    // clutter on disk. The frontend reads each image via
    // `<img :src="task.imageUrls[i]">`.
    try gs.router.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksUpdateHandler);
    try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksDeleteHandler);
    // NOTE: the per-task routine fire route (`POST .../tasks/:task_id/run`)
    // was deleted with the per-task `routines` table (Migration 084, plan
    // 2026-09-10-workspace-items-routines). Workspace-level routines fire
    // via `POST .../items/:item_id/routines/:routine_id/run` (Task 3).
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Trigger
    // an LLM worker on an existing task's session WITHOUT queueing a
    // new user message. Distinct from POST /api/llm/session (always
    // queues a message). See
    // http_handlers/start_agent.zig for the full contract.
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent", ai_mod.http_handlers.startAgentHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/pin", ai_mod.http_handlers.taskPinHandler);
    // Chunk 3 of kanban-task-notification-icon: stamp the
    // `last_human_touched_at` column so the kanban card UI flips the
    // "AI finished — awaiting review" dot to the green "reviewed"
    // checkmark the moment a user opens the task. PUT (idempotent
    // re-stamp is harmless — see plan docs/plans/2026-07-26-kanban-task-notification-icon.md).
    try gs.router.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/touched", ai_mod.http_handlers.taskMarkHumanTouchedHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks/reorder_pinned", ai_mod.http_handlers.tasksReorderPinnedHandler);
    // NOTE: `GET /api/routines` (per-task global listing) was deleted with
    // the per-task `routines` table (Migration 084, plan
    // 2026-09-10-workspace-items-routines). It now 404s.

    // Design workspace-item endpoints (item_type='design') — v6
    //   GET    /design/pages                                — list pages
    //   POST   /design/pages                                — create page
    //   GET    /design/pages/:pid                           — get page + elements
    //   PATCH  /design/pages/:pid                           — update page (resize)
    //   DELETE /design/pages/:pid                           — delete page + on-disk folder
    //   POST   /design/pages/:pid/elements                  — add element
    //   PUT    /design/pages/:pid/elements/:eid             — update element
    //   DELETE /design/pages/:pid/elements/:eid             — delete element
    //   GET    /design/pages/:pid/elements/:eid/html        — get HTML body
    //   PATCH  /design/pages/:pid/elements/:eid/html        — update HTML body
    //   PATCH  /design/pages/:pid/elements/:eid/geometry    — DEPRECATED, use /translate or /resize
    //   POST   /design/pages/:pid/elements/:eid/translate   — single-element move (cascades for groups)
    //   POST   /design/pages/:pid/elements/:eid/resize     — single-element resize (no cascade)
    // See docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Chunk 3.5)
    // and docs/superpowers/plans/2026-08-06-split-move-resize.md.
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesListHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesCreateHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesGetHandler);
    try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesUpdateHandler);
    try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesDeleteHandler); // 2026-07-25-design-page-delete-button (Chunk 1)
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements", ai_mod.http_handlers.designElementsCreateHandler);
    // Group 2+ elements into a new group/frame parent. Single
    // transactional endpoint that creates the parent + reparents
    // the children atomically. See docs/superpowers/plans/
    // 2026-07-28-grouped-layers.md (Chunk 3).
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/group", ai_mod.http_handlers.designElementsGroupHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reorder", ai_mod.http_handlers.designElementsReorderHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reparent-batch", ai_mod.http_handlers.designElementsReparentBatchHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/ungroup", ai_mod.http_handlers.designElementsUngroupHandler);
    try gs.router.put("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id", ai_mod.http_handlers.designElementsUpdateHandler);
    try gs.router.delete("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id", ai_mod.http_handlers.designElementsDeleteHandler);
    try gs.router.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html", ai_mod.http_handlers.designElementsHtmlGetHandler);
    try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html", ai_mod.http_handlers.designElementsHtmlUpdateHandler);
    // DEPRECATED — see design_elements_translate.zig + design_elements_resize.zig.
    try gs.router.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/geometry", ai_mod.http_handlers.designElementsGeometryUpdateHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/geometry-batch", ai_mod.http_handlers.designElementsGeometryBatchHandler);
    // NEW (2026-08-06) — replaces /geometry with two distinct endpoints:
    // /translate (move) and /resize.
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/translate", ai_mod.http_handlers.designElementsTranslateHandler);
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/resize", ai_mod.http_handlers.designElementsResizeHandler);
    // Server-side cascade move. Each item's (dx, dy) recursively applies
    // to every transitive descendant of that item's element in one
    // SQL transaction. See
    // docs/superpowers/plans/2026-08-06-move-element-with-descendants.md (Chunk 2, Task 2.2).
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/move-batch", ai_mod.http_handlers.designElementsMoveBatchHandler);
    // Cross-page element relocate. Changes the element's `page_id` from
    // `:page_id` (path) to a target page in the body. Cascades to
    // transitive descendants when `apply_to_children=true` (default).
    // Plan: docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 2).
    try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/move-to-page", ai_mod.http_handlers.designElementsMoveToPageHandler);

    // testing debug
    try gs.router.post("/test/shutdown", ai_mod.http_handlers.shutdownHandler);
    try gs.router.get("/test/sessions/client_ids", ai_mod.http_handlers.sessionToClientIdsHandler);
    try gs.router.get("/test/system-prompt/:session_id", ai_mod.http_handlers.systemPromptGetHandler);

    _ = try event_bus.subscribe(ai_mod.ai_workflow.RunParamsNew, "ai_worker_flow", ai_mod.ai_workflow.CallbackAiWorkerFlow.callback);
    ctxParent.server.sse_manager.on_disconnect = ai_mod.handleClientDisconnect;

    std.debug.print("Agent is ready to serve!\n", .{});

    const boot_unix = std.Io.Clock.now(.real, io).toSeconds();
    _ = gs.cronjob_manager.register(
        "* * * * *", // every minute, on the minute
        "cleanup_stale_worker",
        cleanup_stale_worker.handle,
        null,
        boot_unix,
    ) catch |err| {
        std.debug.print("Failed to register heartbeat cron: {s}\n", .{@errorName(err)});
    };
    // Delete rows from `session_background_process` whose PID is no
    // longer alive — see plan 2026-08-19-cleanup-stale-background-process.
    // Ignores the `status` column entirely (the only criterion is
    // "is the process actually running right now?" via
    // `helpers.process_status.isProcessRunning`).
    _ = gs.cronjob_manager.register(
        "* * * * *", // every minute, on the minute
        "cleanup_stale_background_process",
        cleanup_stale_background_process.handle,
        null,
        boot_unix,
    ) catch |err| {
        std.debug.print("Failed to register cleanup_stale_background_process cron: {s}\n", .{@errorName(err)});
    };

    try gs.listen(); // blocks until the server is stopped

    // Clean shutdown after listen() returns (after shutdown endpoint is called).
    //
    // Order matters: the cronjob manager started in listen() runs a
    // background thread that ticks every 1s and dereferences context
    // (the running LlmConfig, the SQLite WAL). The defers at the top of
    // main() free that context on the way out, so the cronjob thread
    // MUST be joined BEFORE the defers run — otherwise the thread
    // outlives the freed memory and segfaults ~10s later (rc=-11).
    // Before this fix, the binary segfaulted after /test/shutdown
    // returned 200, leaving the test harness waiting full SIGTERM +
    // SIGKILL deadlines (10s per test × 64 tests = ~10 min of CI waste).
    gs.cronjob_manager.stop();
    gs.sse_manager.stop();
}

/// Dispatch the `nalar service {start,stop,status,restart}` subcommand.
/// Returns true if the subcommand was handled (main should exit); false
/// if no subcommand matched (main should continue with the regular flow).
///
/// The "service" verb is detected by peeking at argv[1]. For `service
/// start`, we currently DO NOT actually start the server — we only
/// daemonize + write the state file. The full server handoff (the
/// remaining Task 3.11 of the plan) is a follow-up; without it the
/// daemon writes state.json and exits, which is the right skeleton for
/// now and lets `service stop` / `service status` be exercised end-to-end.
fn dispatchServiceSubcommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    init: std.process.Init,
) !bool {
    _ = environment;
    const args = init.minimal.args;
    // Zig 0.16: `std.process.Args.Iterator.init` is `compileError`-blocked
    // on Windows (`@compileError("In Windows, use initAllocator instead.")`).
    // Use `initAllocator(args, allocator)` instead — it works on every
    // host (POSIX uses a no-op allocator-style init; Windows uses the
    // custom-MultiByteToWideChar-based parser). Caller MUST call
    // `it.deinit()` to free the buffer Windows internally allocates.
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // skip argv[0]
    const arg1 = it.next() orelse return false;
    if (!std.mem.eql(u8, arg1, "service")) return false;

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(allocator);
    while (it.next()) |a| try rest.append(allocator, a);

    const state_path = state_file.defaultStatePath(allocator) catch |err| {
        std.log.err("service: failed to resolve state path: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(state_path);

    const log_path = blk: {
        const home_z = std.c.getenv("HOME") orelse "/tmp";
        const home = std.mem.sliceTo(home_z, 0);
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "nalar", "service.log" });
    };
    defer allocator.free(log_path);

    const cmd = main_service.parseServiceSubcommand(rest.items) catch |err| switch (err) {
        error.UnknownSubcommand => {
            std.log.err("unknown subcommand: {s}", .{if (rest.items.len > 0) rest.items[0] else "(none)"});
            std.log.err("usage: nalar service {{start|stop|status|restart}} [flags]", .{});
            std.log.err("  start    [--port PORT] [--static-dir DIR] [--no-static-dir]", .{});
            std.log.err("  stop     [--graceful-timeout-ms MS]", .{});
            std.log.err("  status", .{});
            std.log.err("  restart  [--port PORT] [--graceful-timeout-ms MS] [--static-dir DIR]", .{});
            return err;
        },
        error.MissingValue => {
            // The parser reports MissingValue at the *current* position;
            // we don't track that here — point the user at the previous
            // argument (almost always a flag without a value).
            const prev_arg = if (rest.items.len > 1) rest.items[rest.items.len - 2] else "(none)";
            std.log.err("flag '{s}' requires a value", .{prev_arg});
            return err;
        },
        error.InvalidPort => {
            // The port parser catches both InvalidPort and InvalidGracefulMs;
            // name the flag explicitly so the user knows what to fix.
            std.log.err("--port value is not a valid u16 number: {s}", .{
                if (rest.items.len > 2) rest.items[rest.items.len - 1] else "(missing)",
            });
            return err;
        },
        else => {
            std.log.err("service: {s}", .{@errorName(err)});
            return err;
        },
    };

    switch (cmd) {
        .start => |s| {
            const dummy_shutdown = struct {
                fn cb() void {}
            }.cb;
            main_service.serviceStart(allocator, io, .{
                .port = s.port,
                .no_static_dir = s.no_static_dir,
                .state_path = state_path,
                .log_path = log_path,
                .on_shutdown = dummy_shutdown,
            }) catch |err| {
                std.log.err("service start: {s}", .{@errorName(err)});
                return err;
            };
        },
        .stop => |s| main_service.serviceStop(allocator, io, .{
            .graceful_timeout_ms = s.graceful_timeout_ms,
            .state_path = state_path,
        }) catch |err| {
            std.log.err("service stop: {s}", .{@errorName(err)});
            return err;
        },
        .status => main_service.serviceStatus(allocator, io, state_path) catch |err| {
            std.log.err("service status: {s}", .{@errorName(err)});
            return err;
        },
        .restart => |s| {
            main_service.serviceStop(allocator, io, .{
                .graceful_timeout_ms = s.graceful_timeout_ms,
                .state_path = state_path,
            }) catch |err| {
                std.log.err("service restart (stop): {s}", .{@errorName(err)});
                return err;
            };
            const dummy_shutdown2 = struct {
                fn cb() void {}
            }.cb;
            main_service.serviceStart(allocator, io, .{
                .port = s.port,
                .no_static_dir = false,
                .state_path = state_path,
                .log_path = log_path,
                .on_shutdown = dummy_shutdown2,
            }) catch |err| {
                std.log.err("service restart (start): {s}", .{@errorName(err)});
                return err;
            };
        },
    }
    return true;
}

/// Top-level static-files fallback handler. Wired into GinwaServer via
/// `setStaticDirHandler` when `--static-dir` is passed. The signature
/// matches what `GinwaServer.static_dir_handler` expects: an opaque cfg
/// pointer first, then the per-request allocator / io / request info /
/// socket fd. We cast the opaque cfg back to `*const StaticDirConfig`
/// here.
///
/// The handler buffers the full HTTP response (status line, headers, body)
/// in memory, then writes it to the socket. The buffer is allocated from
/// the per-request arena allocator, so it is freed automatically when
/// the arena is deinit'd by the listen loop after the handler returns.
///
/// **Why this is hand-rolled instead of calling `static_files.serve()`**:
/// `static_files.serve()` has a bug in its signature — it takes
/// `writer: std.Io.Writer` by value, but its body calls non-const
/// methods on it (which require a `*Writer`). Calling it produces:
///   "expected type '*Io.Writer', found '*const Io.Writer'"
/// The spec for Task 4 explicitly forbids changes to static_files.zig,
/// so we use the parts of the public API that *do* work
/// (`static_files.resolve` + `static_files.parseRange`) and write the
/// HTTP response ourselves. Once the upstream `serve()` bug is fixed
/// (one-character change: `Writer` → `*Writer`), this duplication can
/// be removed and the call can be replaced with a single
/// `static_files.serve(...)` call.
fn staticDirHandler(
    cfg: *const anyopaque,
    handler_allocator: std.mem.Allocator,
    handler_io: std.Io,
    request_path: []const u8,
    range_header: ?[]const u8,
    fd: i32,
) anyerror!void {
    const typed_cfg: *const static_files.StaticDirConfig = @ptrCast(@alignCast(cfg));

    var aw: std.Io.Writer.Allocating = .init(handler_allocator);
    defer aw.deinit();

    writeStaticFileResponse(typed_cfg, handler_io, request_path, range_header, &aw.writer) catch {
        // Reset the writer buffer, then write a minimal 500 response.
        aw.writer.end = 0;
        const err_body = "Internal Server Error";
        try aw.writer.writeAll("HTTP/1.1 500 Internal Server Error\r\n");
        try aw.writer.print("Content-Length: {d}\r\n", .{err_body.len});
        try aw.writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
        try aw.writer.writeAll("Connection: close\r\n");
        try aw.writer.writeAll("\r\n");
        try aw.writer.writeAll(err_body);
    };

    const out = aw.writer.buffered();
    if (out.len > 0) {
        _ = gserverz.GinwaServer.sendToClient(undefined, fd, out) catch {};
    }
}

/// Build a static-file HTTP response in `writer`. See `staticDirHandler`
/// for why this lives in main.zig instead of being a thin wrapper over
/// `static_files.serve()`.
///
/// Mirrors the algorithm `static_files.serve()` was supposed to
/// implement: resolve the request to a file, emit headers (Content-Type,
/// Content-Length, ETag, optional Content-Range / 206), then stream the
/// file body (full or sliced). 404 / 403 are returned for the
/// corresponding `LookupResult` variants.
fn writeStaticFileResponse(
    cfg: *const static_files.StaticDirConfig,
    io: std.Io,
    request_path: []const u8,
    range_header: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    const lookup = try static_files.resolve(cfg, io, request_path);
    switch (lookup) {
        .not_found, .not_a_file => {
            const body = "Not Found";
            try writer.writeAll("HTTP/1.1 404 Not Found\r\n");
            try writer.print("Content-Length: {d}\r\n", .{body.len});
            try writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
            try writer.writeAll("Connection: close\r\n");
            try writer.writeAll("\r\n");
            try writer.writeAll(body);
        },
        .forbidden => {
            const body = "Forbidden";
            try writer.writeAll("HTTP/1.1 403 Forbidden\r\n");
            try writer.print("Content-Length: {d}\r\n", .{body.len});
            try writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
            try writer.writeAll("Connection: close\r\n");
            try writer.writeAll("\r\n");
            try writer.writeAll(body);
        },
        .file => |f| {
            defer cfg.allocator.free(f.abs_path);

            // Content-derived ETag: combines file size and mtime so two
            // same-size files (common with minified JS/CSS) get distinct
            // ETags and don't trigger browser cache poisoning on size
            // collision. Allocates from cfg.allocator because etag is a
            // tiny string built per-request.
            const etag = try std.fmt.allocPrint(cfg.allocator, "\"x-{x}-{x}\"", .{ f.size, f.mtime.nanoseconds });
            defer cfg.allocator.free(etag);

            // Optional range response.
            if (range_header) |rh| {
                if (try static_files.parseRange(rh, f.size)) |range| {
                    try writer.writeAll("HTTP/1.1 206 Partial Content\r\n");
                    try writer.print("Content-Range: bytes {d}-{d}/{d}\r\n", .{ range.start, range.end, f.size });
                    const content_length: u64 = range.end - range.start + 1;
                    try writer.print("Content-Length: {d}\r\n", .{content_length});
                    try writer.print("Content-Type: {s}\r\n", .{f.mime});
                    try writer.print("ETag: {s}\r\n", .{etag});
                    try writer.writeAll("Cache-Control: public, max-age=3600\r\n");
                    try writer.writeAll("\r\n");
                    try writeFileRange(io, f.abs_path, range.start, range.end, writer);
                    return;
                }
            }

            try writer.writeAll("HTTP/1.1 200 OK\r\n");
            try writer.print("Content-Length: {d}\r\n", .{f.size});
            try writer.print("Content-Type: {s}\r\n", .{f.mime});
            try writer.print("ETag: {s}\r\n", .{etag});
            try writer.writeAll("Cache-Control: public, max-age=3600\r\n");
            try writer.writeAll("\r\n");
            try writeFileFull(io, f.abs_path, writer);
        },
    }
}

/// Stream the entire file at `abs_path` to `writer` in 64 KB chunks.
/// Uses `readPositionalAll` (not seek + read) — the Zig 0.16 idiom for
/// positional reads and the path that's safe in Io.Threaded's blocking
/// recv model.
fn writeFileFull(io: std.Io, abs_path: []const u8, writer: *std.Io.Writer) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        try writer.writeAll(buf[0..n]);
        offset += n;
    }
}

/// Stream the byte range `[start, end]` (inclusive) of the file at
/// `abs_path` to `writer`. Caller is responsible for ensuring
/// `start <= end < file_size`.
fn writeFileRange(
    io: std.Io,
    abs_path: []const u8,
    start: u64,
    end: u64,
    writer: *std.Io.Writer,
) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer file.close(io);
    var remaining: u64 = end - start + 1;
    var offset: u64 = start;
    var buf: [64 * 1024]u8 = undefined;
    while (remaining > 0) {
        const to_read: usize = @intCast(@min(remaining, buf.len));
        const n = try file.readPositionalAll(io, buf[0..to_read], offset);
        if (n == 0) break;
        try writer.writeAll(buf[0..n]);
        offset += n;
        remaining -= n;
    }
}
