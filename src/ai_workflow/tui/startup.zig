const std = @import("std");

const nalar_mod = @import("../../root.zig");
const http_server = nalar_mod.http_server;
const ai_workflow = @import("workflow.zig");
const activity_registry = nalar_mod.session.session_registry;
const llm_history = nalar_mod.llm_history;
const sqlite = nalar_mod.sqlite;
const logger_mod = nalar_mod.logger;

/// Workflow args for spawning startup threads
pub const WorkflowArgs = struct {
    allocator: std.mem.Allocator,
    sqlite_db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []u8,
    message: []u8,
    cwd: []u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
    llm_config: *const nalar_mod.config.LlmConfig,
};

/// Startup handler - queries worker table and starts a thread for each worker
/// Called once during app initialization to bootstrap workers from database
pub fn startup(allocator: std.mem.Allocator, server: *http_server.HttpServer) !void {
    const global_logger_ptr = logger_mod.getGlobal().?;

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
                const workflow_args = try allocator.create(WorkflowArgs);
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
                        var workflow = ai_workflow.TUIWorkflow.init(args.sqlite_db, args.logger);
                        workflow.run(.{
                            .parent_allocator = arena.allocator(),
                            .parent_session_id = args.session_id,
                            .session_id = args.session_id,
                            .message = args.message,
                            .cwd = args.cwd,
                            .api_key = args.api_key,
                            .model = args.model,
                            .base_url = args.base_url,
                            .config = args.llm_config,
                            .body = "",
                            .allowed_tools = "",
                        }) catch |err| {
                            args.logger.errFmt("workflow.run failed: {s}", .{@errorName(err)}) catch {};
                        };
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