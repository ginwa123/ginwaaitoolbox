const std = @import("std");

const nalar_mod = @import("../../root.zig");
const http_server = nalar_mod.http_server;
const ai_workflow = @import("workflow.zig");
const activity_registry = nalar_mod.session.session_registry;
const llm_history = nalar_mod.llm_history;
const sqlite = nalar_mod.sqlite;
const logger_mod = nalar_mod.logger;
const config_mod = nalar_mod.config;

/// Workflow args for spawning startup threads
pub const WorkflowArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sqlite_db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    llm_config: *const nalar_mod.config.LlmConfig,
    session_id: []u8,
    message: []u8,
    cwd: []u8,
    is_sub_agent: bool,
    environment: ?*const std.process.Environ.Map,
    active_loops: *ai_workflow.ActiveLoops,
};

/// Startup handler - queries worker table and starts a thread for each worker
/// Called once during app initialization to bootstrap workers from database
pub fn startup(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    sqlite_db: sqlite.SqliteBackend,
    config: *const config_mod.LlmConfig,
    ctxTui: *ai_workflow.ContextIPCTui,
) !void {
    const logger = logger_mod.getGlobal().?;

    // Get session registry
    const registry = activity_registry.get_global_registry() orelse {
        std.log.err("Global session registry not initialized", .{});
        return error.RegistryNotInitialized;
    };

    // delete all workers this is temporrary
    llm_history.deleteAllWorkers(allocator, sqlite_db) catch |err| {
        logger.errFmt("Failed to delete all workers: {s}", .{@errorName(err)});
        return err;
    };

    llm_history.deleteAllQueuedMessages(allocator, sqlite_db) catch |err| {
        logger.errFmt("Failed to delete all queued messages: {s}", .{@errorName(err)});
        return err;
    };

    // Query all workers from the database
    const workers = llm_history.getActiveWorker(allocator, sqlite_db) catch |err| {
        logger.errFmt("Failed to query workers: {s}", .{@errorName(err)});
        return err;
    };
    defer {
        for (workers) |w| w.deinit(allocator);
        allocator.free(workers);
    }

    if (workers.len == 0) {
        logger.infoFmt("No workers found in database, skipping startup", .{});
        return;
    }

    logger.infoFmt("Found {d} workers in database, starting workflows...", .{workers.len});

    // Spawn a workflow thread for each worker
    for (workers) |worker| {
        // Register session in session registry
        registry.register(worker.session_id) catch |err| {
            logger.warnFmt("Failed to register worker {s}: {s}", .{ worker.session_id, @errorName(err) });
            continue;
        };

        // Mark as running
        registry.mark_running(worker.session_id);

        // Prepare workflow args on heap
        const workflow_args = try allocator.create(WorkflowArgs);
        workflow_args.* = .{
            .allocator = allocator,
            .io = io,
            .sqlite_db = sqlite_db,
            .logger = logger,
            .llm_config = config,
            .session_id = try allocator.dupe(u8, worker.session_id),
            .message = try allocator.dupe(u8, ""),
            .cwd = try allocator.dupe(u8, worker.working_directory),
            .is_sub_agent = worker.isSubAgent(),
            .environment = env,
            .active_loops = ctxTui.active_loops,
        };

        // Spawn thread to run workflow
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(args: *WorkflowArgs) void {
                defer {
                    args.allocator.free(args.session_id);
                    args.allocator.free(args.message);
                    args.allocator.free(args.cwd);
                    args.allocator.destroy(args);
                    // Mark as idle when workflow completes
                    if (activity_registry.get_global_registry()) |reg| {
                        reg.markIdle(args.session_id);
                    }
                }
                var arena = std.heap.ArenaAllocator.init(args.allocator);
                defer arena.deinit();
                var workflow = ai_workflow.TUIWorkflow.init(args.io, args.sqlite_db, args.llm_config, args.logger, args.environment, args.active_loops);
                workflow.runAgenticMultiStep(.{
                    .parent_allocator = arena.allocator(),
                    .parent_session_id = args.session_id,
                    .session_id = args.session_id,
                    .message = args.message,
                    .cwd = args.cwd,
                    .body = "",
                    .allowed_tools = "",
                    .is_sub_agent = args.is_sub_agent,
                }) catch |err| {
                    args.logger.errFmt("workflow.runAgenticMultiStep failed: {s}", .{@errorName(err)});
                };
            }
        }.run, .{workflow_args});
        thread.detach();

        logger.infoFmt("Startup worker started: {s} (cwd: {s})", .{ worker.session_id, worker.working_directory });

        return;
    }

    std.log.err("Server not initialized for startup", .{});
    return error.ServerNotInitialized;
}
