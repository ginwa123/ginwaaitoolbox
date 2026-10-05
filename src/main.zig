const std = @import("std");

const pabrikcore = @import("pabrikcore");

/// Zig calls `root.debug.handleSegfault` before anything else for a
/// hardware fault. Declaring it is what puts pabrik's crash reporter at
/// the FRONT of the Windows exception chain — std installs a vectored
/// handler (`RtlAddVectoredExceptionHandler(0, handleSegfaultWindows)`)
/// at process start, and vectored handlers run before the
/// UnhandledExceptionFilter that `installCrashHandlers()` registers.
/// Without this decl, an access violation is swallowed by std and
/// pabrik's own Windows report never runs.
///
/// See `crash_handler.root_debug` for the full ordering argument.
pub const debug = pabrikcore.crash_handler.root_debug;

const ai_mod = pabrikcore.ai_mod;
const sqlite = pabrikcore.sqlite;
const database = pabrikcore.database;
// `helpers` is now its own Zig module (see `src/helpers/build.zig`);
// promoted out of `pabrikcore` so multiple sub-packages can share a
// single module instance. The root build.zig wires it via
// `mod.addImport("helpers", helpers_mod)` — consumers reference it
// directly via `@import("helpers")`.
const helpers = @import("helpers");
const gserverz = pabrikcore.gserverz;
const cli_args = pabrikcore.cli_args;
const http_routes = pabrikcore.http_routes;
const startup = pabrikcore.startup;
const static_files = pabrikcore.static_files;
const migration = pabrikcore.migrations_mod.migration;
// cleanup_stale_worker is re-exported via pabrikcore (root.zig) so the
// exe module doesn't directly @import the file — that would put it
// in both modules and trigger Zig's "file exists in two modules"
// error. See root.zig's `pub const cleanup_stale_worker = ...`.
const cleanup_stale_worker = pabrikcore.cleanup_stale_worker;
// cleanup_stale_background_process: same routing as above — re-exported
// via pabrikcore so the exe module doesn't directly @import the file.
const cleanup_stale_background_process = pabrikcore.cleanup_stale_background_process;

// state_file and main_service are re-exported from pabrikcore (see src/root.zig).
// Access them via pabrikcore.* to avoid duplicating the module symbol
// across both root files.
const state_file = pabrikcore.state_file;
const main_service = pabrikcore.main_service;

// Graceful shutdown (Ctrl+C / SIGTERM): the live server pointer the
// signal handler closes. Set once after `GinwaServer.init`, cleared
// never — the handler is process-lifetime. The callback runs IN SIGNAL
// CONTEXT so it only calls `shutdown()` (bool store + shutdown(2) /
// close(2), both async-signal-safe): no logging, no allocation.
var shutdown_server: ?*gserverz.GinwaServer = null;
var shutdown_requested: std.atomic.Value(bool) = .init(false);

fn handleShutdownSignal() void {
    shutdown_requested.store(true, .seq_cst);
    if (shutdown_server) |gs| gs.shutdown();
}

/// Print the live SQLite connection's settings at boot.
///
/// A future "database is locked" report then carries the connection's
/// ACTUAL configuration instead of a guess — including whether the
/// writer-slot wait is really 15 s and whether the WAL file is bounded.
/// No-op on a postgres build (`-Ddb_used=sqlite,postgres`): that backend
/// has no pragmas and no `readConfig`.
fn logSqliteConfig(allocator: std.mem.Allocator, db: *database.Db) void {
    if (database.backend_is_postgres) return;
    const applied = db.readConfig(allocator) catch |err| {
        std.log.warn("sqlite: could not read back connection config ({s})", .{@errorName(err)});
        return;
    };
    std.log.info("sqlite: journal_mode={s} busy_timeout={d}ms synchronous={d} wal_autocheckpoint={d} journal_size_limit={d}", .{
        applied.journalMode(),
        applied.busy_timeout_ms,
        applied.synchronous,
        applied.wal_autocheckpoint_pages,
        applied.journal_size_limit_bytes,
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const environment = init.environ_map;
    const io = init.io;

    // Service subcommand dispatch (Chunk 3 of the decoupled-pabrik-service
    // plan): if argv[1] == "service", route the rest of argv to the
    // service module and exit before doing any other init.
    if (try dispatchServiceSubcommand(allocator, io, environment, init)) return;
    if (try dispatchCreateAdmin(allocator, io, environment, init)) return;

    // A peer that vanishes mid-write must not kill the process: OpenSSL writes
    // through plain write(2) (no MSG_NOSIGNAL available), so EPIPE becomes
    // SIGPIPE. Every server ignores it and handles the write error instead.
    if (comptime @import("builtin").os.tag != .windows) {
        var sa = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &sa, null);
    }

    // ─── CLI flags, parsed BEFORE anything with side effects ─────────────────
    // `LlmConfig.init` (below) starts the routine scheduler on a background
    // thread. Anything that returns an error AFTER that point exits the process
    // while the thread is mid-query, which SEGFAULTS (reproduced with a plain
    // `--port abc` on an unmodified build) and buries the real error message in a
    // crash dump. So every flag is parsed — and `--tls` is fully validated —
    // here, where failing is clean, fast and side-effect free.
    //
    // The parser itself lives in `cli_args.zig` as a pure function over the
    // argument list so it can be unit-tested without booting a server; this
    // block only flattens argv (the iterator's buffers are freed on Windows,
    // so the parser dupes what it keeps) and applies the result.
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    var argv_flat: std.ArrayList([]const u8) = .empty;
    defer argv_flat.deinit(allocator);
    while (args_iter.next()) |arg| try argv_flat.append(allocator, arg);

    // `var` because the --tls-selfsigned branch below overwrites the parsed
    // cert/key paths with the generated pair.
    var cli: cli_args.CliArgs = .{};
    if (cli_args.parse(allocator, argv_flat.items, &cli) catch |err| return err) |failure| {
        cli_args.reportFailure(failure);
        return error.InvalidArgs;
    }
    if (cli.help_requested) return;

    // TLS: generate/reuse the self-signed pair if asked, then load it into a
    // context. Doing it here means a typo in a path fails immediately with a
    // message naming the flag and the path — and never silently falls back to
    // plaintext after the user asked for TLS.
    var tls_ctx: ?*gserverz.tls.Ctx = null;
    if (cli.tls_selfsigned) {
        const dir = try tlsDataDir(allocator, init.environ_map);
        const paths = try gserverz.tls_cert.ensureSelfSigned(allocator, dir, "localhost", 365);
        cli.tls_cert_path = paths.cert_pem;
        cli.tls_key_path = paths.key_pem;
    }
    if (cli.tls_cert_path) |cert| {
        const key = cli.tls_key_path orelse unreachable;
        tls_ctx = gserverz.tls.Ctx.init(allocator, cert, key, &.{ gserverz.tls.alpn_h2, gserverz.tls.alpn_http1 }) catch |err| {
            std.log.err("Error: --tls cannot load cert={s} key={s}: {s}", .{ cert, key, @errorName(err) });
            return error.InvalidArgs;
        };
        // The functional tests parse this line for the certificate path.
        std.debug.print("TLS enabled (ALPN: h2, http/1.1) cert={s}\n", .{cert});
    }

    if (init.environ_map.get("HOME")) |home| {
        std.log.info("HOME={s}", .{home});
    }

    var llm_config = pabrikcore.config.LlmConfig.init(allocator, io, null, environment) catch |err| {
        std.log.err("Failed to load config: {s}", .{@errorName(err)});
        return err;
    };
    // NOTE: do NOT `defer llm_config.deinit()` here — the value is moved
    // into the heap-allocated `initial_llm_config_ptr` below. Shutdown
    // cleanup runs via `pabrikcore.freeAllLlmConfigs(ctxParent)` at the end
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
    // The PUT handler (`pabrik_config_put.zig:234`) keeps the strict
    // behavior — when the user actively edits their config via the UI,
    // an empty api_key is still rejected with a 200 + error body so
    // they can correct it.
    if (llm_config.validate()) |_| {
        // OK — config has all required fields.
    } else |err| {
        std.log.warn(
            "Config validation: {s}. LLM calls will fail until api_key/model/base_url are populated in ~/.config/pabrik/config.json.",
            .{@errorName(err)},
        );
    }

    // Move the initial LlmConfig onto the heap so the `LlmConfigHolder`
    // can later swap pointers without owning stack memory of `main`.
    const initial_llm_config_ptr = try allocator.create(pabrikcore.config.LlmConfig);
    errdefer allocator.destroy(initial_llm_config_ptr);
    initial_llm_config_ptr.* = llm_config;

    const db_path = try helpers.db_path.getDbPath(allocator, io, environment);
    defer allocator.free(db_path);

    var dbSqlite: database.Db = .{};
    defer dbSqlite.deinit();
    // `.synchronous = .normal` is the ONLY knob this app sets; everything
    // else (15 s busy_timeout, journal_size_limit, wal_autocheckpoint, and
    // BEGIN IMMEDIATE in `begin()`) is the databases package's own default.
    // Rationale is in `ruangsql`'s `Sqlite.Config` doc comment — the short
    // version: in WAL mode a contended write that cannot take the single
    // writer slot is LOST, not delayed, and `synchronous=FULL` fsyncs the
    // WAL on every commit.
    try database.openWithConfig(&dbSqlite, io, .{ .sqlite_path = db_path }, .{ .synchronous = .normal });
    logSqliteConfig(allocator, &dbSqlite);

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

    pabrikcore.setPanicLogPath(log_file_path);
    // Install OS-level crash handlers (SIGSEGV / SIGBUS / SIGABRT /
    // SIGILL / SIGFPE on POSIX; EXCEPTION_ACCESS_VIOLATION / etc on
    // Windows) BEFORE we start the HTTP server. The handler writes a
    // backtrace to the same log_file_path that panicHandler uses.
    // See src/service/crash_handler.zig for the contract.
    pabrikcore.crash_handler.setCrashLogPath(log_file_path);
    pabrikcore.crash_handler.installCrashHandlers();

    pabrikcore.loggermod.initGlobalColor(allocator, io, .{
        .min_level = .debug,
        .output_mode = .file,
        .log_file_path = log_file_path,
        .include_location = true,
        .include_request_id = true,
        .include_timestamp = true,
    });
    defer pabrikcore.loggermod.deinitGlobal(io);

    const global_logger_ptr = pabrikcore.loggermod.getGlobal().?;

    const ctxParent = try allocator.create(pabrikcore.App);
    defer allocator.destroy(ctxParent);
    ctxParent.* = pabrikcore.App{
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

    // Applied AFTER the struct literal above — assigning before it would be
    // clobbered by the whole-struct initialisation (the field defaults to null).
    if (cli.static_dir) |dir_arg| ctxParent.static_dir_path = dir_arg;
    ctxParent.auth_enabled = cli.auth_enabled;
    if (cli.auth_enabled) {
        std.log.info("--auth on: per-user LLM config comes from users.config_json; config.json is ignored.", .{});
    }

    _ = try pabrikcore.setSingleton(ctxParent);

    // Eagerly init the process-global MCP registries on the process-lifetime
    // allocator and cache the pointers on the singleton struct, so every
    // call site goes through `di.mcp_stdio_registry` (via
    // `pabrikcore.mcpStdioRegistry`) instead of lazy-init on first MCP use.
    // Shutdown hooks below kill spawned children + free registry arenas.
    ctxParent.mcp_stdio_registry = pabrikcore.mcp_stdio.StdioRegistry.global(allocator);
    ctxParent.mcp_http_registry = pabrikcore.mcp_http.HttpRegistry.global(allocator);
    defer pabrikcore.mcp_stdio.StdioRegistry.deinitGlobal();
    defer pabrikcore.mcp_http.HttpRegistry.deinitGlobal();

    const event_bus_mod = pabrikcore.event_bus;
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

    // Plan 2026-09-10-web-launch-toggle: `--port 0` = auto-pick a random
    // free loopback port (browser mode). `cli.port` stays null unless the
    // user passes --port explicitly, so the default can honor the
    // `web_launch_enabled` flag (random when on, 8081 when off).

    // Resolve the listen port: explicit --port wins; otherwise the
    // `web_launch_enabled` flag decides (random when on so the
    // browser-mode URL never clashes, 8081 when off — historical
    // default, unchanged).
    var port: u16 = cli.port orelse (if (llm_config.web_launch_enabled) 0 else 8081);
    if (port == 0) {
        port = pabrikcore.web_port.pickFreePort(io) catch |err| {
            std.log.err("web launch: no free port in [{d},{d}]: {s}", .{
                pabrikcore.web_port.web_port_range_start,
                pabrikcore.web_port.web_port_range_end,
                @errorName(err),
            });
            return err;
        };
        std.log.info("web launch: browser mode on http://127.0.0.1:{d}/", .{port});
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

    const address = gserverz.Address.init("127.0.0.1", port) catch |err| switch (err) {
        // A port already in use is an ordinary, expected operator error (a
        // second pabrik, a stale dev server). Letting `try` carry `BindFailed`
        // out of `main` sends the process down the runtime's error path,
        // where it dies with SIGSEGV (exit code -11) and a bare stack trace —
        // which reads like a memory-safety bug and, in the functional suite,
        // masks a plain port collision as an apparent crash of the binary
        // itself. Report it and exit non-zero instead.
        error.BindFailed => {
            std.log.err("cannot bind 127.0.0.1:{d} - address already in use (is another pabrik already running on this port?)", .{port});
            std.process.exit(1);
        },
        else => return err,
    };
    const gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();
    gs.enable_h2c = cli.enable_h2c;

    // Graceful shutdown: Ctrl+C (SIGINT) and SIGTERM close the listener
    // via `GinwaServer.shutdown()`, which unblocks `listen()` so the
    // post-listen shutdown below runs. Without this, SIGINT kills the
    // process with the default disposition and no cleanup runs at all
    // (truncated responses, unjoined threads, uncheckpointed WAL).
    // Second signal force-exits (130) via signal_handlers' two-hit
    // guard. See the post-listen block for why the signal path exits
    // instead of unwinding the `defer` chain.
    shutdown_server = gs;
    shutdown_requested.store(false, .seq_cst);
    pabrikcore.signal_handlers.installShutdownHandlers(handleShutdownSignal);

    // TLS context built during flag parsing (validated there, adopted here).
    if (tls_ctx) |ctx| gs.setTlsCtx(ctx);

    if (cli.enable_h2c) std.debug.print("HTTP/2 (h2c) enabled on this port (HTTP/1.1 clients unaffected)\n", .{});

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
        // Make the value absolute BEFORE the absolute-only open below:
        // `openDirAbsolute` asserts `path.isAbsolute(...)`, and a failed
        // assertion ABORTS the process instead of returning an error. A relative
        // `--static-dir` (or a relative XDG_DATA_HOME/HOME-derived value that
        // the desktop launcher passes through) must not be able to do that.
        const abs_static_dir = if (std.fs.path.isAbsolute(dir))
            try allocator.dupe(u8, dir)
        else
            try std.Io.Dir.cwd().realPathFileAlloc(io, dir, allocator);
        defer allocator.free(abs_static_dir);

        // Open + canonicalize the dir. openDirAbsolute surfaces "not a
        // directory" / "not found" as concrete errors which we forward to
        // the user via std.log + main's error return.
        const root_dir = std.Io.Dir.openDirAbsolute(io, abs_static_dir, .{}) catch |err| {
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
            // Second fallback for the standalone login page (`/login`
            // renders outside the app shell but from the same
            // index.html). Without it, refreshing at
            // /login?redirect=/app 404s.
            .spa_fallback_prefix2 = "/login",
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
    try http_routes.registerAll(gs);

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

    try gs.listenEventLoop(.{ .dispatch_mode = .worker_pool });

    // Clean shutdown after listen() returns (shutdown endpoint, SIGINT
    // Ctrl+C, or SIGTERM). The signal path sets `shutdown_requested`
    // in the handler above, so log here (signal-safe code can't log
    // itself).
    if (shutdown_requested.load(.seq_cst)) {
        std.log.info("shutdown signal received — listener closed, flushing in-flight requests", .{});
        // Signal path exits here instead of running the stops + `defer`
        // chain below. Two measured reasons:
        //
        // 1. Full unwind segfaults: returning normally runs `defer
        //    group.cancel(io)` + `dbSqlite.deinit()` + registry
        //    teardowns while Io worker threads are still draining —
        //    Zig 0.16's Threaded Io then panics
        //    (`assert(old_status.num_running > 0)` in
        //    `Io/Threaded.zig:start`, reproduced as an instant SIGSEGV
        //    after SIGINT on an idle server).
        //
        // 2. The stops themselves race signal-interrupted workers:
        //    calling `cronjob_manager.stop() / sse_manager.stop()` here
        //    reproduced `thread N panic: reached unreachable code` in
        //    5 of 6 runs, while skipping them is panic-free in 6 of 6
        //    (same binary, same idle server). The joins are unnecessary
        //    on this path anyway — nothing is freed afterwards, so no
        //    thread can outlive its context; `exit(0)` reaps everything.
        //
        // So: the listener is already closed (no new connections),
        // in-flight requests keep running on the live Io runtime
        // during a short flush, then `exit(0)` — the same shape as the
        // `/test/shutdown` endpoint (which exits 50ms after its own
        // `shutdown()` call). SQLite runs in WAL mode so
        // uncheckpointed frames replay safely on next boot — the same
        // crash-consistency guarantee the test endpoint relies on. A
        // second signal during the flush force-exits (130) straight
        // from the handler.
        helpers.sleepMillis(50);
        std.process.exit(0);
    }

    // Normal return (only the `/test/shutdown` endpoint reaches here —
    // the signal path exits above).
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

/// Dispatch the `pabrik service {start,stop,status,restart}` subcommand.
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
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "pabrik", "service.log" });
    };
    defer allocator.free(log_path);

    const cmd = main_service.parseServiceSubcommand(rest.items) catch |err| switch (err) {
        error.UnknownSubcommand => {
            std.log.err("unknown subcommand: {s}", .{if (rest.items.len > 0) rest.items[0] else "(none)"});
            std.log.err("usage: pabrik service {{start|stop|status|restart}} [flags]", .{});
            std.log.err("  start    [--port PORT] [--static-dir DIR] [--no-static-dir]  (PORT 0 = random free port)", .{});
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
                .static_dir = s.static_dir,
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
                .static_dir = s.static_dir,
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

/// Dispatch `pabrik create-admin --email E [--password P] [--name N] [--force]`.
/// Bootstraps the first admin for opt-in `--auth` mode. Opens the same
/// SQLite DB + runs migrations (so it works on fresh installs), refuses
/// when an active admin already exists unless `--force`.
/// Returns true when handled (main should exit).
fn dispatchCreateAdmin(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,
    init: std.process.Init,
) !bool {
    const args = init.minimal.args;
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]
    const arg1 = it.next() orelse return false;
    if (!std.mem.eql(u8, arg1, "create-admin")) return false;

    var email: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var name: []const u8 = "";
    var force = false;
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--email")) {
            email = it.next() orelse {
                std.log.err("create-admin: --email requires a value", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, a, "--password")) {
            password = it.next() orelse {
                std.log.err("create-admin: --password requires a value", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, a, "--name")) {
            name = it.next() orelse {
                std.log.err("create-admin: --name requires a value", .{});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("Usage: pabrik create-admin --email E [--password P] [--name N] [--force]\n", .{});
            return true;
        } else {
            std.log.err("create-admin: unknown flag '{s}'", .{a});
            return error.InvalidArgs;
        }
    }
    const email_v = email orelse {
        std.log.err("create-admin: --email is required", .{});
        return error.InvalidArgs;
    };
    if (std.mem.indexOfScalar(u8, email_v, '@') == null) {
        std.log.err("create-admin: --email must contain '@'", .{});
        return error.InvalidArgs;
    }
    const password_v = password orelse {
        std.log.err("create-admin: --password is required (pass via env in scripts)", .{});
        return error.InvalidArgs;
    };
    if (password_v.len < 8) {
        std.log.err("create-admin: password must be at least 8 characters", .{});
        return error.InvalidArgs;
    }

    const db_path = try helpers.db_path.getDbPath(allocator, io, @constCast(environment));
    defer allocator.free(db_path);
    var dbSqlite: database.Db = .{};
    defer dbSqlite.deinit();
    try database.openWithConfig(&dbSqlite, io, .{ .sqlite_path = db_path }, .{ .synchronous = .normal });
    var mm = migration.MigrationManager.init(allocator, &dbSqlite);
    defer mm.deinit();
    try migration.registerAllMigrations(&mm);
    try mm.runMigrations();

    if (!force) {
        var q = try dbSqlite.query(allocator, "SELECT 1 FROM users WHERE role = 'admin' AND is_active = 1 LIMIT 1", &.{});
        defer q.deinit();
        if ((try q.next()) != null) {
            std.log.err("create-admin: an active admin already exists (use --force to add another)", .{});
            return error.InvalidArgs;
        }
    }

    var hash_buf: [256]u8 = undefined;
    const hash_slice = std.crypto.pwhash.bcrypt.strHash(password_v, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = true },
        .encoding = .crypt,
    }, &hash_buf, io) catch {
        std.log.err("create-admin: password hashing failed", .{});
        return error.InvalidArgs;
    };
    const ts = std.Io.Timestamp.now(io, .real);
    const id = try std.fmt.allocPrint(allocator, "user_{d}", .{@divTrunc(ts.nanoseconds, 1_000_000)});
    defer allocator.free(id);
    dbSqlite.exec(
        allocator,
        "INSERT INTO users (id, email, name, password_hash, role, is_active) VALUES (?, ?, COALESCE(?, ''), ?, 'admin', 1)",
        &[_][]const u8{ id, email_v, name, hash_slice },
    ) catch {
        std.log.err("create-admin: insert failed (email may already exist)", .{});
        return error.InvalidArgs;
    };
    std.debug.print("create-admin: admin '{s}' created\n", .{email_v});

    // Give the account its "Default" workspace at creation time rather than
    // making the first login do it: a brand-new admin who runs this command
    // should find the workspace already there. `auth_login.zig` runs the same
    // idempotent ensure, which covers accounts created before this and any
    // future signup path.
    const provisioned = ai_mod.http_handlers.workspace_provisioning.ensureDefaultWorkspace(
        allocator,
        &dbSqlite,
        io,
        id,
        environment,
    ) catch |err| {
        // The account exists and can log in; a missing workspace is
        // recoverable from the sidebar, and the first login retries. Failing
        // the command here would report a created admin that is unusable.
        std.log.warn("create-admin: could not provision the default workspace (non-fatal, the first login retries): {s}", .{@errorName(err)});
        return true;
    };
    // `null` here means the user already had workspaces — nothing to report.
    if (provisioned) |workspace| {
        defer workspace.deinit(allocator);
        std.debug.print("create-admin: workspace '{s}' ({s}) provisioned\n", .{ workspace.name, workspace.id });
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
/// Where a generated certificate lives: `$XDG_DATA_HOME/pabrik/tls`, falling back
/// to `~/.local/share/pabrik/tls` (POSIX) or `%LOCALAPPDATA%\pabrik\tls` (Windows).
/// Deliberately NOT the config dir: it is state, not configuration.
fn tlsDataDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const app_name = "pabrik";
    if (comptime @import("builtin").os.tag == .windows) {
        const base = env.get("LOCALAPPDATA") orelse return error.NoDataDir;
        return std.fs.path.join(allocator, &.{ base, app_name, "tls" });
    }
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, app_name, "tls" });
    }
    const home = env.get("HOME") orelse return error.NoDataDir;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", app_name, "tls" });
}

fn staticDirHandler(
    cfg: *const anyopaque,
    handler_allocator: std.mem.Allocator,
    handler_io: std.Io,
    request_path: []const u8,
    range_header: ?[]const u8,
    stream: gserverz.Stream,
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
        stream.writeAll(out) catch {};
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
