const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;
const config = nalarcore.config;
const activity_registry = nalarcore.session.activity_registry;

const httpz = http_server.httpz;
const WorkflowArgs = @import("mod.zig").WorkflowArgs;
const generateSessionId = @import("mod.zig").generateSessionId;

/// Create a new worker (background task execution unit)
/// Request body (JSON, optional):
///   - session_id: custom worker ID (string, optional, auto-generated if not provided)
///   - initial_message: initial message to process (string, optional)
///   - auto_start: whether to immediately start processing (bool, default: true)
///   - cwd: working directory for the worker (string, optional)
/// Returns JSON with created worker info
pub fn worker_create_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    // Parse request body
    var session_id: ?[]u8 = null;
    var initial_message: ?[]u8 = null;
    var auto_start: bool = true;
    var cwd: ?[]u8 = null;

    const body = req.body() orelse "";

    if (body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
            res.status = 400;
            res.body = "{\"error\":\"Invalid JSON body\"}";
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract session_id if provided
        if (root.get("session_id")) |val| {
            if (val == .string) {
                session_id = try alloc.dupe(u8, val.string);
            }
        }

        // Extract initial_message if provided
        if (root.get("initial_message")) |val| {
            if (val == .string) {
                initial_message = try alloc.dupe(u8, val.string);
            }
        }

        // Extract auto_start if provided
        if (root.get("auto_start")) |val| {
            if (val == .bool) {
                auto_start = val.bool;
            }
        }

        // Extract cwd if provided
        if (root.get("cwd")) |val| {
            if (val == .string) {
                cwd = try alloc.dupe(u8, val.string);
            }
        }
    }

    // Generate session_id if not provided
    if (session_id == null) {
        session_id = try generateSessionId(alloc);
    }

    if (http_server.global_server) |server| {
        // Register session in activity registry
        if (activity_registry.get_global_registry()) |registry| {
            registry.register(session_id.?) catch {
                res.status = 500;
                res.body = "{\"error\":\"Failed to register worker\"}";
                return;
            };
        }

        // Start workflow if auto_start is true
        if (auto_start) {
            if (server.db) |db| {
                const sqlite_db = @as(*sqlite.SqliteBackend, @ptrCast(@alignCast(db)));
                if (server.ctx) |ctx| {
                    const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));

                    // Mark as running in activity registry
                    if (activity_registry.get_global_registry()) |registry| {
                        registry.mark_running(session_id.?);
                        // Queue initial message if provided
                        if (initial_message) |msg| {
                            registry.queue_message(session_id.?, msg);
                        }
                    }

                    // Spawn workflow in detached thread (fire-and-forget)
                    const workflow_args = try server.allocator.create(WorkflowArgs);
                    workflow_args.* = .{
                        .allocator = server.allocator,
                        .sqlite_db = sqlite_db,
                        .logger = ctxTui.logger,
                        .session_id = try server.allocator.dupe(u8, session_id.?),
                        .message = try server.allocator.dupe(u8, initial_message orelse ""),
                        .cwd = try server.allocator.dupe(u8, cwd orelse ""),
                        .api_key = ctxTui.llm_config.api_key,
                        .model = ctxTui.llm_config.model,
                        .base_url = ctxTui.llm_config.base_url,
                        .llm_config = ctxTui.llm_config,
                    };

                    const thread = try std.Thread.spawn(.{}, struct {
                        fn run(args: *WorkflowArgs) void {
                            defer {
                                args.allocator.free(args.session_id);
                                args.allocator.free(args.message);
                                args.allocator.free(args.cwd);
                                args.allocator.destroy(args);
                                // Mark as idle when workflow completes
                                if (activity_registry.get_global_registry()) |registry| {
                                    registry.mark_idle(args.session_id);
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
                }
            }

            res.status = 201;
            res.body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"status\":\"running\"}}", .{session_id.?});
        } else {
            // Worker created but not started
            res.status = 201;
            res.body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"status\":\"idle\"}}", .{session_id.?});
        }
        return;
    }

    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
