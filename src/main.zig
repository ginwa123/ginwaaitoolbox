const std = @import("std");

const nalarcore = @import("nalarcore");

/// Zig calls `root.debug.handleSegfault` before anything else for a
/// hardware fault. Declaring it is what puts nalar's crash reporter at
/// the FRONT of the Windows exception chain — std installs a vectored
/// handler (`RtlAddVectoredExceptionHandler(0, handleSegfaultWindows)`)
/// at process start, and vectored handlers run before the
/// UnhandledExceptionFilter that `installCrashHandlers()` registers.
/// Without this decl, an access violation is swallowed by std and
/// nalar's own Windows report never runs.
///
/// See `crash_handler.root_debug` for the full ordering argument.
pub const debug = nalarcore.crash_handler.root_debug;

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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const environment = init.environ_map;
    const io = init.io;

    // Service subcommand dispatch (Chunk 3 of the decoupled-nalar-service
    // plan): if argv[1] == "service", route the rest of argv to the
    // service module and exit before doing any other init.
    if (try dispatchServiceSubcommand(allocator, io, environment, init)) return;
    if (try dispatchCreateAdmin(allocator, io, environment, init)) return;

    // ─── CLI flags, parsed BEFORE anything with side effects ─────────────────
    // `LlmConfig.init` (below) starts the routine scheduler on a background
    // thread. Anything that returns an error AFTER that point exits the process
    // while the thread is mid-query, which SEGFAULTS (reproduced with a plain
    // `--port abc` on an unmodified build) and buries the real error message in a
    // crash dump. So every flag is parsed — and `--tls` is fully validated — here,
    // where failing is clean, fast and side-effect free.
    var port_opt: ?u16 = null;
    var static_dir_opt: ?[]const u8 = null;
    // HTTP/2 cleartext (h2c). OFF by default; `--http2=h2c` turns it on. There is
    // deliberately no TLS here, so browsers keep using HTTP/1.1 (see docs/http2.md).
    var enable_h2c = false;
    // TLS (opt-in). `--tls <cert.pem> <key.pem>` uses existing PEM files;
    // `--tls-selfsigned` generates (first run) or reuses one in the app data dir.
    // Browsers only speak HTTP/2 over TLS+ALPN, so this is what unlocks browser
    // multiplexing — see docs/http2-tls.md.
    var tls_cert_path: ?[]const u8 = null;
    var tls_key_path: ?[]const u8 = null;
    var tls_selfsigned = false;
    // Opt-in auth. `--auth` enables login enforcement (login page +
    // session cookie + middleware). Off by default so existing
    // single-user setups keep working with zero behavior change.
    var auth_enabled = false;

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

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args_iter.next()) |port_arg| {
                port_opt = std.fmt.parseInt(u16, port_arg, 10) catch {
                    std.log.err("Error: invalid port number", .{});
                    return error.InvalidArgs;
                };
            } else {
                std.log.err("Error: --port requires a value", .{});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--static-dir")) {
            if (args_iter.next()) |static_dir_arg| {
                // Applied once `ctxParent` exists — the flags are parsed before
                // any subsystem is initialised.
                static_dir_opt = try allocator.dupe(u8, static_dir_arg);
            } else {
                std.log.err("Error: --static-dir requires a value", .{});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--http2")) {
            // `--http2` on its own means h2c; an explicit value keeps room for
            // future modes (e.g. `--http2=off`).
            if (args_iter.next()) |h2_arg| {
                if (std.mem.eql(u8, h2_arg, "h2c")) {
                    enable_h2c = true;
                } else if (std.mem.eql(u8, h2_arg, "off")) {
                    enable_h2c = false;
                } else {
                    std.log.err("Error: --http2 expects h2c or off (got {s})", .{h2_arg});
                    return error.InvalidArgs;
                }
            } else {
                enable_h2c = true;
            }
        } else if (std.mem.eql(u8, arg, "--tls")) {
            if (args_iter.next()) |cert_arg| {
                if (args_iter.next()) |key_arg| {
                    tls_cert_path = try allocator.dupe(u8, cert_arg);
                    tls_key_path = try allocator.dupe(u8, key_arg);
                } else {
                    std.log.err("Error: --tls <cert.pem> <key.pem>: no key path given (cert={s})", .{cert_arg});
                    return error.InvalidArgs;
                }
            } else {
                std.log.err("Error: --tls requires <cert.pem> <key.pem> (no cert path given)", .{});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--tls-selfsigned")) {
            tls_selfsigned = true;
        } else if (std.mem.eql(u8, arg, "--auth")) {
            auth_enabled = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Usage: nalar [--port PORT] [--static-dir DIR] [--http2 h2c|off] [--tls CERT KEY | --tls-selfsigned] [--auth]\n", .{});
            std.debug.print("  --port PORT          Port to run the HTTP server on (0 = pick a random free port; default: 8081, or random when web_launch_enabled is on)\n", .{});
            std.debug.print("  --static-dir DIR     Serve files from DIR at HTTP / (e.g. for a webapp)\n", .{});
            std.debug.print("  --http2 h2c|off      Also accept HTTP/2 cleartext (h2c) clients on the same port (default: off)\n", .{});
            std.debug.print("  --auth               Require login (session cookie + middleware). When off, all endpoints are open.\n", .{});
            return;
        }
    }

    // TLS: generate/reuse the self-signed pair if asked, then load it into a
    // context. Doing it here means a typo in a path fails immediately with a
    // message naming the flag and the path — and never silently falls back to
    // plaintext after the user asked for TLS.
    var tls_ctx: ?*gserverz.tls.Ctx = null;
    if (tls_selfsigned) {
        const dir = try tlsDataDir(allocator, init.environ_map);
        const paths = try gserverz.tls_cert.ensureSelfSigned(allocator, dir, "localhost", 365);
        tls_cert_path = paths.cert_pem;
        tls_key_path = paths.key_pem;
    }
    if (tls_cert_path) |cert| {
        const key = tls_key_path orelse unreachable;
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

    // Applied AFTER the struct literal above — assigning before it would be
    // clobbered by the whole-struct initialisation (the field defaults to null).
    if (static_dir_opt) |dir_arg| ctxParent.static_dir_path = dir_arg;
    ctxParent.auth_enabled = auth_enabled;
    if (auth_enabled) {
        std.log.info("--auth on: per-user LLM config comes from users.config_json; config.json is ignored.", .{});
    }

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

    // Plan 2026-09-10-web-launch-toggle: `--port 0` = auto-pick a random
    // free loopback port (browser mode). `port_opt` stays null unless the
    // user passes --port explicitly, so the default can honor the
    // `web_launch_enabled` flag (random when on, 8081 when off).

    // Resolve the listen port: explicit --port wins; otherwise the
    // `web_launch_enabled` flag decides (random when on so the
    // browser-mode URL never clashes, 8081 when off — historical
    // default, unchanged).
    var port: u16 = port_opt orelse (if (llm_config.web_launch_enabled) 0 else 8081);
    if (port == 0) {
        port = nalarcore.web_port.pickFreePort(io) catch |err| {
            std.log.err("web launch: no free port in [{d},{d}]: {s}", .{
                nalarcore.web_port.web_port_range_start,
                nalarcore.web_port.web_port_range_end,
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
        // second nalar, a stale dev server). Letting `try` carry `BindFailed`
        // out of `main` sends the process down the runtime's error path,
        // where it dies with SIGSEGV (exit code -11) and a bare stack trace —
        // which reads like a memory-safety bug and, in the functional suite,
        // masks a plain port collision as an apparent crash of the binary
        // itself. Report it and exit non-zero instead.
        error.BindFailed => {
            std.log.err("cannot bind 127.0.0.1:{d} - address already in use (is another nalar already running on this port?)", .{port});
            std.process.exit(1);
        },
        else => return err,
    };
    const gs = try gserverz.GinwaServer.init(allocator, io, address);
    defer gs.deinit();
    gs.enable_h2c = enable_h2c;

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
    nalarcore.signal_handlers.installShutdownHandlers(handleShutdownSignal);

    // TLS context built during flag parsing (validated there, adopted here).
    if (tls_ctx) |ctx| gs.setTlsCtx(ctx);

    if (enable_h2c) std.debug.print("HTTP/2 (h2c) enabled on this port (HTTP/1.1 clients unaffected)\n", .{});

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
    // Opt-in `--auth`: all `/api` routes registered via `authed` run
    // `authMiddleware` (401 when no valid `nalar_session` cookie).
    // Auth endpoints themselves stay on `gs.router` (unprotected) and
    // are registered BEFORE any `:param` routes to avoid matchRoute
    // shadowing (`/api/auth/login` is a literal that must precede
    // `/api/session/:session_id`-style params).
    var authed = gs.router.group("");
    try authed.use(ai_mod.http_handlers.authMiddleware);
    try gs.router.post("/api/auth/login", ai_mod.http_handlers.authLoginHandler);
    try gs.router.post("/api/auth/logout", ai_mod.http_handlers.authLogoutHandler);
    try gs.router.get("/api/auth/me", ai_mod.http_handlers.authMeHandler);
    // // try authed.get("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
    // // try authed.post("/api/stream/:session_id/disconnect", http_handlers.sseDisconnectHandler, .{});
    // // try authed.get("/api/stream/:session_id", http_handlers.streamHandler, .{});
    // // try gs.router.options("/api/session", http_handlers.corsPreflightHandler, .{});
    try authed.post("/api/session", ai_mod.http_handlers.sessionCreateHandler);
    try authed.put("/api/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler);
    // Mark-as-seen (yellow stale-dot fix): stamping
    // `sessions.last_human_touched_at_nano` when the user opens a chat.
    // POST differs in method from the sibling PUT/GET on the overlapping
    // prefix, and the literal `touched` tail differs from `messages` —
    // no shadowing risk.
    try authed.post("/api/session/:session_id/touched", ai_mod.http_handlers.sessionMarkTouchedHandler);
    try authed.get("/api/session", ai_mod.http_handlers.sessionListHandler);
    //
    // // try authed.get("/api/session/stream", http_handlers.sessionStreamHandler, ctxParent);
    try authed.get("/api/session/:session_id/messages", ai_mod.http_handlers.sessionMessagesHandler);
    // try authed.get("/api/session/exists/:session_id", http_handlers.sessionExistHandler, ctxParent);
    // try authed.get("/api/session/latest", http_handlers.sessionLatestHandler, ctxParent);
    // try authed.post("/api/session/:session_id/cancel", http_handlers.sessionCancelHandler, ctxParent);
    // try authed.post("/api/session/:session_id/compact", http_handlers.sessionCompactHandler, ctxParent);
    // try authed.get("/api/session/:session_id/queue/messages", http_handlers.sessionQueueGetHandler, ctxParent);
    // try authed.delete("/api/session/:session_id/queue/message", http_handlers.sessionQueueDeleteHandler, ctxParent);
    // try authed.get("/api/ping/:session_id", http_handlers.pingHandler, ctxParent);
    //
    // // Worker API
    try authed.get("/api/workers", ai_mod.http_handlers.workerListHandler);
    //
    // // LLM API aliases (desktop app uses /api/llm/*)
    try authed.post("/api/llm/session", ai_mod.http_handlers.sessionCreateHandler);
    try authed.put("/api/llm/session/:session_id", ai_mod.http_handlers.sessionUpdateHandler);
    // LLM-alias prefix of the mark-as-seen endpoint above (desktop app
    // uses /api/llm/*). Same no-shadowing argument as above.
    try authed.post("/api/llm/session/:session_id/touched", ai_mod.http_handlers.sessionMarkTouchedHandler);
    try authed.post("/api/llm/session/:session/stop", ai_mod.http_handlers.sessionStopHandler);
    // `ask_user` answer route. Route order: the literal `answer` tail differs
    // from every sibling tail (messages, queue_messages, stream, stop,
    // touched), so there is no `matchRoute` shadowing risk — and it is
    // registered after the `/messages` + `/queue_messages` siblings anyway,
    // per the "longer, more-specific paths after their prefix sibling" rule.
    try authed.post("/api/llm/session/:session_id/answer", ai_mod.http_handlers.askUserAnswerHandler);

    // try authed.post("/api/llm/session", ai_mod.http_handlers.sessionCreateHandler);

    try authed.get("/api/llm/session", ai_mod.http_handlers.sessionListHandler);
    // Session detail incl. `workspace_id` (workspace-scoped sessions).
    // `:session_id` matches exactly ONE path segment, so this route can
    // neither shadow nor be shadowed by the sibling `/messages`,
    // `/queue_messages`, `/background_processes`, `/stream` routes —
    // matchPathWithParams requires the path to be exhausted after the
    // pattern, regardless of registration order.
    try authed.get("/api/llm/session/:session_id", ai_mod.http_handlers.sessionGetHandler);
    try authed.get("/api/llm/session/:session_id/messages", ai_mod.http_handlers.sessionMessagesHandler);
    try authed.get("/api/llm/session/:session_id/queue_messages", ai_mod.http_handlers.queueMessagesGetHandler);
    // Session background-process endpoints (bg-completion): list + log
    // tail for `command background=true` rows. Registered next to
    // queue_messages. No shadowing risk: the `background_processes`
    // literal segment differs from every sibling (`messages`,
    // `queue_messages`, `stream`), and the longer `:pid/log` route is
    // registered AFTER the list route (route-order rule — longer,
    // more-specific paths after their prefix sibling).
    try authed.get("/api/llm/session/:session_id/background_processes", ai_mod.http_handlers.backgroundProcessesListHandler);
    try authed.get("/api/llm/session/:session_id/background_processes/:pid/log", ai_mod.http_handlers.backgroundProcessLogGetHandler);
    // Right-sidebar terminal (PTY over REST + poll). Fresh
    // `/api/terminal/` prefix — no `:param` siblings exist under it,
    // so no matchRoute shadowing risk (router walks registration
    // order). Literal `sessions` is registered before the `:id`
    // routes (route-order rule).
    try authed.post("/api/terminal/sessions", ai_mod.http_handlers.terminalCreateHandler);
    try authed.post("/api/terminal/sessions/:id/input", ai_mod.http_handlers.terminalInputHandler);
    try authed.get("/api/terminal/sessions/:id/output", ai_mod.http_handlers.terminalOutputHandler);
    try authed.post("/api/terminal/sessions/:id/resize", ai_mod.http_handlers.terminalResizeHandler);
    try authed.delete("/api/terminal/sessions/:id", ai_mod.http_handlers.terminalDeleteHandler);
    // Duplex PTY socket — attaches to a live session id (?id=) for
    // binary output frames + JSON control frames. First (and only) WS
    // route: fresh `/api/terminal/` prefix, literal `ws` segment, so
    // no matchRoute shadowing risk. HTTP/1.1 only (browsers use h1).
    try gs.router.ws("/api/terminal/ws", ai_mod.http_handlers.terminalWsHandler);
    // In-flight stream snapshot (task_1787673548905_0 stream-resume-on-
    // reselect) — serves `{ active, content }` from the in-memory
    // stream_snapshot registry so a re-mounted ChatView can resume a
    // mid-stream session. Registered AFTER the sibling /messages +
    // /queue_messages routes (route-order rule).
    try authed.get("/api/llm/session/:session_id/stream", ai_mod.http_handlers.streamGetHandler);
    // Live spawn-batch snapshot (task_1788505292766_1
    // spawn-subagent-refresh-persist) — serves `{ tool_call_id,
    // progress[] }` from the in-memory subagent_progress registry so a
    // refreshed ChatView can rehydrate running rows for placeholder
    // spawn cards. Fresh `/api/subagent/...` prefix: no sibling
    // `:param` routes exist under it, so no shadowing risk.
    try authed.get("/api/subagent/progress/:tool_call_id", ai_mod.http_handlers.subAgentProgressGetHandler);
    // Unified SSE endpoint — single EventSource for all event families
    // (workers, sessions, kanban_column, kanban_task, per-session llm +
    // queue_messages). Replaces the 5 dedicated routes that previously
    // registered one EventSource per family. See
    // src/http_handlers/unified_events_sse.zig.
    try gs.router.sse("/api/events", ai_mod.http_handlers.unifiedEventsStreamHandler);
    // Test-only SSE emit (dev_sse_emit.zig) — gated by NALAR_TEST_SSE_EMIT=1,
    // 404 when off. Functional UI tests use it to drive the chatview's
    // SSE streaming path without a real LLM.
    try authed.post("/api/dev/sse/emit_llm", ai_mod.http_handlers.devSseEmitLlmHandler);
    // try authed.post("/api/llm/session/:session_id/cancel", http_handlers.sessionCancelHandler, ctxParent);
    //
    // // Desktop app routes (system, health, workspaces)
    try gs.router.get("/health", ai_mod.http_handlers.healthHandler);
    try authed.get("/api/skills", ai_mod.http_handlers.skillsListHandler);
    try authed.get("/api/skills/:name", ai_mod.http_handlers.skillDetailHandler);
    try authed.delete("/api/skills", ai_mod.http_handlers.skillDeleteHandler);

    // Skill Evals — the READ surface for the eval the agent runs on itself.
    // A SIBLING prefix, not `/api/skills/evals`: `matchRoute` walks routes in
    // registration order and returns on first hit, so a literal registered
    // after `/api/skills/:name` above would be captured as name="evals". Both
    // routes here are literals with query parameters, so there is no ordering
    // hazard to remember. Plan: docs/plans/2026-09-27-skill-evals.md §4.10.
    try authed.get("/api/skill-evals/runs", ai_mod.http_handlers.skillEvalsRunsHandler);
    try authed.get("/api/skill-evals/summary", ai_mod.http_handlers.skillEvalsSummaryHandler);
    // The apply endpoint. `result_id` is a QUERY parameter, not a path segment,
    // so this stays a literal and there is still no `:param` under this prefix
    // to shadow a later route.
    try authed.post("/api/skill-evals/results/apply", ai_mod.http_handlers.skillEvalsApplyHandler);

    // Memories routes
    try authed.get("/api/memories", ai_mod.http_handlers.memoriesListHandler);
    try authed.get("/api/memories/:name", ai_mod.http_handlers.memoryDetailHandler);
    try authed.post("/api/memories", ai_mod.http_handlers.memoryCreateHandler);
    try authed.put("/api/memories/:name", ai_mod.http_handlers.memoryUpdateHandler);
    try authed.delete("/api/memories/:name", ai_mod.http_handlers.memoryDeleteHandler);

    // Local Memories routes — scoped to <cwd>/.nalar/memories/. The
    // `cwd` is provided in the request body (POST/PUT) or query
    // string (GET/DELETE); handlers fall back to the nalar server's
    // own CWD via `io.realPath` when no explicit cwd is provided.
    try authed.get("/api/local-memories", ai_mod.http_handlers.localMemoriesListHandler);
    try authed.get("/api/local-memories/:name", ai_mod.http_handlers.localMemoryDetailHandler);
    try authed.post("/api/local-memories", ai_mod.http_handlers.localMemoryCreateHandler);
    try authed.put("/api/local-memories/:name", ai_mod.http_handlers.localMemoryUpdateHandler);
    try authed.delete("/api/local-memories/:name", ai_mod.http_handlers.localMemoryDeleteHandler);

    // Nalar config routes (reads/writes config.json as nalar.json mapping)
    try authed.get("/api/config/nalar", ai_mod.http_handlers.nalarConfigGetHandler);
    try authed.put("/api/config/nalar", ai_mod.http_handlers.nalarConfigPutHandler);
    try authed.delete("/api/config/nalar/profiles/:name", ai_mod.http_handlers.nalarConfigProfileDeleteHandler);

    // OS notification test endpoint — fires a real OS notification so
    // the user can verify their system can display them.
    try authed.post("/api/notify/test", ai_mod.http_handlers.notifyTestHandler);

    // Browser-mode (web launch) status — read-only: reports the
    // `web_launch_enabled` flag + live bound port/URL for the settings
    // General tab pill. Literal path, no `:param` siblings — no
    // matchRoute shadowing risk (router.zig walks registration order).
    // Plan 2026-09-10-web-launch-toggle.
    try authed.get("/api/web/status", ai_mod.http_handlers.webStatusHandler);

    // MCP server "Test" probe — fires a tools/list request against a
    // candidate config without persisting anything. Used by the
    // Add/Edit MCP server modal's "Test" button so the user can
    // verify command + args + env + cwd (or URL + headers) actually
    // work before clicking Save.
    try authed.post("/api/mcp/test", ai_mod.http_handlers.mcpTestHandler);

    // LLM profile "Test" probe — fires one minimal non-streaming chat
    // call against a candidate profile without persisting anything.
    // Used by the Add/Edit profile modal's "Test" button so the user
    // can verify model + base_url + api_key + url_style actually work
    // before clicking Save. Literal path with no `:param` siblings —
    // no matchRoute shadowing risk (router.zig walks registration order).
    try authed.post("/api/llm/test", ai_mod.http_handlers.llmTestHandler);

    // Frontend error log endpoints — capture unhandled JS exceptions,
    // unhandled promise rejections, and existing console.error / console.warn
    // calls from the nalar-desktop webapp. See
    // docs/plans/2026-07-17-frontend-error-logs-design.md.
    try authed.post("/api/logs", ai_mod.http_handlers.frontendLogPostHandler);
    try authed.get("/api/logs", ai_mod.http_handlers.frontendLogGetHandler);

    try authed.get("/api/git/status", ai_mod.http_handlers.gitStatusHandler);
    try authed.get("/api/git/changes", ai_mod.http_handlers.gitChangesHandler);
    try authed.get("/api/git/file/diff", ai_mod.http_handlers.gitFileDiffHandler);
    try authed.post("/api/git/file/diffs", ai_mod.http_handlers.gitFileDiffsHandler);
    try authed.get("/api/git/file/read", ai_mod.http_handlers.gitFileReadHandler);
    try authed.post("/api/git/stage", ai_mod.http_handlers.gitStageHandler);
    try authed.post("/api/git/unstage", ai_mod.http_handlers.gitUnstageHandler);
    try authed.get("/api/git/worktree/info", ai_mod.http_handlers.gitWorktreeInfoHandler);
    try authed.get("/api/git/branches", ai_mod.http_handlers.gitBranchesListHandler);
    try authed.get("/api/git/commits", ai_mod.http_handlers.gitCommitsListHandler);
    try authed.get("/api/git/commit", ai_mod.http_handlers.gitCommitDetailHandler);
    try authed.get("/api/git/commit/file", ai_mod.http_handlers.gitCommitFileDiffHandler);
    try authed.post("/api/git/pr", ai_mod.http_handlers.gitPrCreateHandler);
    try authed.get("/api/git/pr/status", ai_mod.http_handlers.gitPrStatusHandler);
    try authed.get("/api/git/pr/diff", ai_mod.http_handlers.gitPrDiffHandler);
    try authed.get("/api/git/pr/conflicts", ai_mod.http_handlers.gitPrConflictsHandler);
    try authed.get("/api/system/folder", ai_mod.http_handlers.systemFolderHandler);
    // File download for the `present_files` agent tool card
    // (PresentFiles.vue). Literal path under a fresh `/api/files/`
    // prefix — no `:param` siblings exist under it, so no matchRoute
    // shadowing risk (router walks registration order). Plan:
    // docs/plans/2026-09-14-agent-tool-present-files.md
    try authed.get("/api/files/download", ai_mod.http_handlers.filesDownloadHandler);
    try authed.get("/api/workspaces", ai_mod.http_handlers.workspacesListHandler);
    try authed.post("/api/workspaces", ai_mod.http_handlers.workspacesCreateHandler);
    try authed.post("/api/workspaces/reorder", ai_mod.http_handlers.workspacesReorderHandler);
    try authed.get("/api/workspaces/:id", ai_mod.http_handlers.workspaceGetHandler);
    try authed.put("/api/workspaces/:id", ai_mod.http_handlers.workspaceUpdateHandler);
    try authed.delete("/api/workspaces/:id", ai_mod.http_handlers.workspaceDeleteHandler);
    // Id-only task PUT — MUST stay ABOVE every `:workspace_id` route below.
    //
    // It is deliberately id-only: a chat rename must not have to carry a
    // workspace/item scope (task.id IS the session id, Migration 052), and
    // `api.updateTaskSimple` sends only `{"name": ...}`. The `tasks` segment
    // here is a LITERAL, so the route cannot shadow or be shadowed by the
    // `:workspace_id/items/...` family — both agree on that segment.
    //
    // Registration order is load-bearing for a second reason that has nothing
    // to do with matching: `matchRoute` walks the table top-down and
    // kabelweb's `matchPathWithParams` writes each `:param` into the shared
    // `req.params` map as it walks, WITHOUT unwinding when a later literal
    // segment fails to match. So a request to
    // `/api/workspaces/tasks/<id>` first tried
    // `PUT /api/workspaces/:workspace_id/items/:item_id` and left
    // `workspace_id = "tasks"` behind in `req.params`. authMiddleware's
    // per-user choke point then read that leftover, `canSeeWorkspace("tasks")`
    // was false, and the rename 404'd with `{"error": "Workspace not found"}`
    // before the handler ever ran — only when `--auth` was on.
    //
    // Static assertions for this ordering live in
    // `http_handlers/task_update.zig`; the behavioural one is
    // `tests/functional/task_rename_id_route_auth_test.py`.
    try authed.put("/api/workspaces/tasks/:task_id", ai_mod.http_handlers.tasksUpdateByIdHandler);
    // Idempotent: returns the workspace's default project, creating it
    // (item_type='agent', path=$HOME) when there is none.
    //
    // This is the COLD-START FALLBACK. GET /api/workspaces/:ws/items
    // already ensures the default on the normal path, so most clients never
    // call this. It exists for the one case the list cannot cover: the app
    // was open when Migration 094 ran, so its loaded list predates the
    // is_default column and a "New Chat" tap would otherwise be a no-op
    // until a manual refetch.
    //
    // Route order: 3 segments, with a LITERAL `default-project` in position
    // 4. Every other 3+ segment route under /api/workspaces starts with a
    // literal `items` in that same position, and no
    // `POST /api/workspaces/:workspace_id/:param` route exists, so a param
    // sibling cannot shadow this. The inline tests at the bottom of
    // `workspace_items_default.zig` assert both facts statically so a future
    // sibling cannot.
    try authed.post("/api/workspaces/:workspace_id/default-project", ai_mod.http_handlers.workspaceDefaultProjectHandler);
    try authed.post("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/items", ai_mod.http_handlers.workspaceItemsListHandler);
    try authed.post("/api/workspaces/:workspace_id/items/reorder", ai_mod.http_handlers.workspaceItemsReorderHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsGetHandler);
    try authed.put("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id", ai_mod.http_handlers.workspaceItemsDeleteHandler);

    // Kanban workspace-item endpoints (item_type='kanban').
    //   POST   /items/kanban                       — create a kanban + seed 3 default columns
    //   GET    /items/:item_id/kanban/columns      — list columns
    //   POST   /items/:item_id/kanban/columns      — add a column
    //   PATCH  /items/:item_id/kanban/columns/:cid — rename and/or reorder a column
    //   DELETE /items/:item_id/kanban/columns/:cid — delete a column
    //   PATCH  /items/:item_id/tasks/:task_id/move — move a task across columns
    // See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 3).
    try authed.post("/api/workspaces/:workspace_id/items/kanban", ai_mod.http_handlers.workspaceItemsCreateKanbanHandler);
    // Design workspace-item endpoint (item_type='design').
    //   POST   /items/design                       — create a design (path is required;
    //                                              see design_items_create.zig)
    // See docs/superpowers/plans/2026-07-08-design-mode-redesign.md
    //   Chunk 8 (AppLayout + Sidebar Wiring).
    try authed.post("/api/workspaces/:workspace_id/items/design", ai_mod.http_handlers.workspaceItemsCreateDesignHandler);
    // Agent Mode workspace-item endpoint (item_type='agent') + sub-resources.
    // Plan: docs/superpowers/plans/2026-08-15-agent-mode.md
    // Task: task_1786962724740_0
    try authed.post("/api/workspaces/:workspace_id/items/agent", ai_mod.http_handlers.workspaceItemsCreateAgentHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/agent", ai_mod.http_handlers.agentsUpdateHandler);
    try authed.post("/api/agents/:agent_id/knowledge", ai_mod.http_handlers.agentKnowledgeCreateHandler);
    // ORDER MATTERS: the literal `/knowledge/reorder` route MUST be
    // registered BEFORE `/knowledge/:knowledge_id` — matchRoute walks
    // routes in registration order, so the param route would otherwise
    // capture PATCH /knowledge/reorder with knowledge_id="reorder".
    try authed.patch("/api/agents/:agent_id/knowledge/reorder", ai_mod.http_handlers.agentKnowledgeReorderHandler);
    try authed.patch("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeUpdateHandler);
    try authed.delete("/api/agents/:agent_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKnowledgeDeleteHandler);
    // Agent system-prompt CRUD (Migration 080). NOTE: `reorder` literal
    // MUST be registered BEFORE `:prompt_id` — the router walks routes in
    // registration order and `:prompt_id` would otherwise capture the
    // literal "reorder" segment (same shadowing trap as knowledge above).
    try authed.post("/api/agents/:agent_id/system_prompt", ai_mod.http_handlers.agentSystemPromptCreateHandler);
    try authed.patch("/api/agents/:agent_id/system_prompt/reorder", ai_mod.http_handlers.agentSystemPromptReorderHandler);
    try authed.patch("/api/agents/:agent_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentSystemPromptUpdateHandler);
    try authed.delete("/api/agents/:agent_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentSystemPromptDeleteHandler);
    try authed.get("/api/agent-tools/registry", ai_mod.http_handlers.agentToolsRegistryHandler);
    try authed.get("/api/agents/:agent_id/tools", ai_mod.http_handlers.agentToolsListHandler);
    try authed.post("/api/agents/:agent_id/tools", ai_mod.http_handlers.agentToolsCreateHandler);
    try authed.delete("/api/agents/:agent_id/tools/:tool_name", ai_mod.http_handlers.agentToolsDeleteHandler);
    // Agent-Kanbans mirror CRUD (Migration 081) — mirrors the agent block
    // above onto kanban boards. Plan:
    // docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md
    // Task: task_1787597624259_2.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/agent_kanban", ai_mod.http_handlers.agentKanbansGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/agent_kanban", ai_mod.http_handlers.agentKanbansUpdateHandler);
    try authed.post("/api/agent-kanbans/:kanban_id/knowledge", ai_mod.http_handlers.agentKanbanKnowledgeCreateHandler);
    // ORDER MATTERS: the literal `/knowledge/reorder` route MUST be
    // registered BEFORE `/knowledge/:knowledge_id` — matchRoute walks
    // routes in registration order (same shadowing trap as the agent
    // knowledge routes above).
    try authed.patch("/api/agent-kanbans/:kanban_id/knowledge/reorder", ai_mod.http_handlers.agentKanbanKnowledgeReorderHandler);
    try authed.patch("/api/agent-kanbans/:kanban_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKanbanKnowledgeUpdateHandler);
    try authed.delete("/api/agent-kanbans/:kanban_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentKanbanKnowledgeDeleteHandler);
    // NOTE: `reorder` literal MUST be registered BEFORE `:prompt_id`
    // (same shadowing trap as knowledge above).
    try authed.post("/api/agent-kanbans/:kanban_id/system_prompt", ai_mod.http_handlers.agentKanbanSystemPromptCreateHandler);
    try authed.patch("/api/agent-kanbans/:kanban_id/system_prompt/reorder", ai_mod.http_handlers.agentKanbanSystemPromptReorderHandler);
    try authed.patch("/api/agent-kanbans/:kanban_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentKanbanSystemPromptUpdateHandler);
    try authed.delete("/api/agent-kanbans/:kanban_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentKanbanSystemPromptDeleteHandler);
    try authed.get("/api/agent-kanbans/:kanban_id/tools", ai_mod.http_handlers.agentKanbanToolsListHandler);
    try authed.post("/api/agent-kanbans/:kanban_id/tools", ai_mod.http_handlers.agentKanbanToolsCreateHandler);
    try authed.delete("/api/agent-kanbans/:kanban_id/tools/:tool_name", ai_mod.http_handlers.agentKanbanToolsDeleteHandler);
    // Agent-Routines mirror CRUD (Migration 087) — mirrors the agent-kanbans
    // block above onto routines. Routine mode task_1789505553300_1.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/agent_routine", ai_mod.http_handlers.agentRoutinesGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/agent_routine", ai_mod.http_handlers.agentRoutinesUpdateHandler);
    try authed.post("/api/agent-routines/:routine_id/knowledge", ai_mod.http_handlers.agentRoutineKnowledgeCreateHandler);
    // ORDER MATTERS: literal `/knowledge/reorder` BEFORE
    // `/knowledge/:knowledge_id` (route-order shadowing — see kanban block).
    try authed.patch("/api/agent-routines/:routine_id/knowledge/reorder", ai_mod.http_handlers.agentRoutineKnowledgeReorderHandler);
    try authed.patch("/api/agent-routines/:routine_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentRoutineKnowledgeUpdateHandler);
    try authed.delete("/api/agent-routines/:routine_id/knowledge/:knowledge_id", ai_mod.http_handlers.agentRoutineKnowledgeDeleteHandler);
    // NOTE: `reorder` literal MUST be registered BEFORE `:prompt_id`.
    try authed.post("/api/agent-routines/:routine_id/system_prompt", ai_mod.http_handlers.agentRoutineSystemPromptCreateHandler);
    try authed.patch("/api/agent-routines/:routine_id/system_prompt/reorder", ai_mod.http_handlers.agentRoutineSystemPromptReorderHandler);
    try authed.patch("/api/agent-routines/:routine_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentRoutineSystemPromptUpdateHandler);
    try authed.delete("/api/agent-routines/:routine_id/system_prompt/:prompt_id", ai_mod.http_handlers.agentRoutineSystemPromptDeleteHandler);
    try authed.get("/api/agent-routines/:routine_id/tools", ai_mod.http_handlers.agentRoutineToolsListHandler);
    try authed.post("/api/agent-routines/:routine_id/tools", ai_mod.http_handlers.agentRoutineToolsCreateHandler);
    try authed.delete("/api/agent-routines/:routine_id/tools/:tool_name", ai_mod.http_handlers.agentRoutineToolsDeleteHandler);
    // Workspace-level routines (Migration 084, plan
    // 2026-09-10-workspace-items-routines) — first-class
    // `item_type='routine'`. Replaces the deleted per-task routes
    // (`POST .../tasks/:task_id/run`, `GET /api/routines`).
    try authed.post("/api/workspaces/:workspace_id/items/routine", ai_mod.http_handlers.workspaceItemsCreateRoutineHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/routine", ai_mod.http_handlers.workspaceRoutinesGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/routine", ai_mod.http_handlers.workspaceRoutinesUpdateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/routines/:routine_id/run", ai_mod.http_handlers.workspaceRoutinesRunHandler);
    // Workspace-scoped documents (Migration 098). NOT a `workspace_items`
    // child: a document belongs to the workspace directly and surfaces in
    // its own sidebar section below Projects, never in the project tree.
    //
    // Route order: no `GET /api/workspaces/:workspace_id/:param` route
    // exists (the only sibling with a literal 4th segment is
    // `POST .../default-project`, a different verb), so `documents`
    // cannot be captured as a workspace id or vice-versa. The
    // `:document_id` routes are registered last in the group for the
    // usual reason: matchRoute walks routes in registration order, and
    // a param route registered before a literal sibling would swallow it.
    try authed.get("/api/workspaces/:workspace_id/documents", ai_mod.http_handlers.documentsListHandler);
    try authed.post("/api/workspaces/:workspace_id/documents", ai_mod.http_handlers.documentsCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/documents/:document_id", ai_mod.http_handlers.documentsGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/documents/:document_id", ai_mod.http_handlers.documentsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/documents/:document_id", ai_mod.http_handlers.documentsDeleteHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/kanban/columns", ai_mod.http_handlers.kanbanColumnsListHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/columns", ai_mod.http_handlers.kanbanColumnsCreateHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id", ai_mod.http_handlers.kanbanColumnsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id", ai_mod.http_handlers.kanbanColumnsDeleteHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/run_all_agents", ai_mod.http_handlers.runAllAgentsHandler);
    // Copy a kanban spec (column structure) from one kanban to another
    // (Chunk 2 of copy-kanban plan). Body: `{mode: "replace" | "append"}`.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/copy_spec_from/:source_item_id", ai_mod.http_handlers.kanbanCopySpecHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/move", ai_mod.http_handlers.tasksMoveHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksListHandler);
    // Single-task GET for the kanban Task details dialog (plan:
    // docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md).
    // Registered AFTER the list route — matchRoute walks routes in
    // registration order (router.zig route-order rule).
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksGetHandler);
    // Lazy media fetch (media-flags change) — full `image_urls` / `video_urls`
    // only when `is_have_image` / `is_have_video` is true. Longer path
    // (extra `/media` segment) so no shadowing vs the `:task_id` route.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/media", ai_mod.http_handlers.tasksMediaHandler);
    // Kanban task tag autocomplete (Chunk 1 of plan
    // docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md).
    // Paginated suggestions for the kanban task detail dialog's tag chip
    // input. Ordered by frequency DESC, then last_used_at DESC. Query
    // params: ?limit=N (default 8, max 50) &offset=K. Response:
    // { tags: [{name,count,last_used_at}], has_more }.
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/kanban/tags", ai_mod.http_handlers.kanbanTagsListHandler);
    // Kanban-scoped task create endpoint with mode='create' | mode='create_and_run' discriminator.
    // Mirrors the generic /tasks POST but rejects 404 when the parent item is not a kanban.
    // Plan: docs/superpowers/plans/2026-08-14-kanban-task-create-endpoints.md
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/kanban/tasks", ai_mod.http_handlers.kanbanTasksCreateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks", ai_mod.http_handlers.tasksCreateHandler);
    // Migration 069 (2026-08-06) removed the filesystem-backed
    // kanban-task attachment endpoints (POST + GET wildcard). Task
    // images now live inline on `workspace_item_tasks.image_urls` as
    // `||`-delimited base64 data URLs — no upload path, no broken
    // `*` wildcard GET route, no `<path>/.nalar/attachments/<task>/`
    // clutter on disk. The frontend reads each image via
    // `<img :src="task.imageUrls[i]">`.
    try authed.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id", ai_mod.http_handlers.tasksDeleteHandler);
    // NOTE: the per-task routine fire route (`POST .../tasks/:task_id/run`)
    // was deleted with the per-task `routines` table (Migration 084, plan
    // 2026-09-10-workspace-items-routines). Workspace-level routines fire
    // via `POST .../items/:item_id/routines/:routine_id/run` (registered
    // with the routine block above).
    // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Trigger
    // an LLM worker on an existing task's session WITHOUT queueing a
    // new user message. Distinct from POST /api/llm/session (always
    // queues a message). See
    // http_handlers/start_agent.zig for the full contract.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent", ai_mod.http_handlers.startAgentHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/pin", ai_mod.http_handlers.taskPinHandler);
    // Chunk 3 of kanban-task-notification-icon: stamp the
    // `last_human_touched_at` column so the kanban card UI flips the
    // "AI finished — awaiting review" dot to the green "reviewed"
    // checkmark the moment a user opens the task. PUT (idempotent
    // re-stamp is harmless — see plan docs/plans/2026-07-26-kanban-task-notification-icon.md).
    try authed.put("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/touched", ai_mod.http_handlers.taskMarkHumanTouchedHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/tasks/reorder_pinned", ai_mod.http_handlers.tasksReorderPinnedHandler);
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
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesListHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages", ai_mod.http_handlers.designPagesCreateHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id", ai_mod.http_handlers.designPagesDeleteHandler); // 2026-07-25-design-page-delete-button (Chunk 1)
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements", ai_mod.http_handlers.designElementsCreateHandler);
    // Group 2+ elements into a new group/frame parent. Single
    // transactional endpoint that creates the parent + reparents
    // the children atomically. See docs/superpowers/plans/
    // 2026-07-28-grouped-layers.md (Chunk 3).
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/group", ai_mod.http_handlers.designElementsGroupHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reorder", ai_mod.http_handlers.designElementsReorderHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/reparent-batch", ai_mod.http_handlers.designElementsReparentBatchHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/ungroup", ai_mod.http_handlers.designElementsUngroupHandler);
    try authed.put("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id", ai_mod.http_handlers.designElementsUpdateHandler);
    try authed.delete("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id", ai_mod.http_handlers.designElementsDeleteHandler);
    try authed.get("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html", ai_mod.http_handlers.designElementsHtmlGetHandler);
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/html", ai_mod.http_handlers.designElementsHtmlUpdateHandler);
    // DEPRECATED — see design_elements_translate.zig + design_elements_resize.zig.
    try authed.patch("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/geometry", ai_mod.http_handlers.designElementsGeometryUpdateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/geometry-batch", ai_mod.http_handlers.designElementsGeometryBatchHandler);
    // NEW (2026-08-06) — replaces /geometry with two distinct endpoints:
    // /translate (move) and /resize.
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/translate", ai_mod.http_handlers.designElementsTranslateHandler);
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/resize", ai_mod.http_handlers.designElementsResizeHandler);
    // Server-side cascade move. Each item's (dx, dy) recursively applies
    // to every transitive descendant of that item's element in one
    // SQL transaction. See
    // docs/superpowers/plans/2026-08-06-move-element-with-descendants.md (Chunk 2, Task 2.2).
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/move-batch", ai_mod.http_handlers.designElementsMoveBatchHandler);
    // Cross-page element relocate. Changes the element's `page_id` from
    // `:page_id` (path) to a target page in the body. Cascades to
    // transitive descendants when `apply_to_children=true` (default).
    // Plan: docs/superpowers/plans/2026-08-06-move-element-to-page.md (Chunk 2).
    try authed.post("/api/workspaces/:workspace_id/items/:item_id/design/pages/:page_id/elements/:element_id/move-to-page", ai_mod.http_handlers.designElementsMoveToPageHandler);

    // testing debug (gated by auth middleware when `--auth` is on)
    try authed.post("/test/shutdown", ai_mod.http_handlers.shutdownHandler);
    try authed.get("/test/sessions/client_ids", ai_mod.http_handlers.sessionToClientIdsHandler);
    try authed.get("/test/system-prompt/:session_id", ai_mod.http_handlers.systemPromptGetHandler);

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

/// Dispatch `nalar create-admin --email E [--password P] [--name N] [--force]`.
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
            std.debug.print("Usage: nalar create-admin --email E [--password P] [--name N] [--force]\n", .{});
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
    try database.open(&dbSqlite, io, .{ .sqlite_path = db_path });
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
/// Where a generated certificate lives: `$XDG_DATA_HOME/nalar/tls`, falling back
/// to `~/.local/share/nalar/tls` (POSIX) or `%LOCALAPPDATA%\nalar\tls` (Windows).
/// Deliberately NOT the config dir: it is state, not configuration.
fn tlsDataDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (comptime @import("builtin").os.tag == .windows) {
        const base = env.get("LOCALAPPDATA") orelse return error.NoDataDir;
        return std.fs.path.join(allocator, &.{ base, "nalar", "tls" });
    }
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "nalar", "tls" });
    }
    const home = env.get("HOME") orelse return error.NoDataDir;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "nalar", "tls" });
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
