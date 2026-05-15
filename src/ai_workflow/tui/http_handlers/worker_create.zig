const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;
const config = nalarcore.config;
const session_registry = nalarcore.session.session_registry;
const http_response = nalarcore.http_response;
const WorkflowArgs = @import("mod.zig").WorkflowArgs;
const generateSessionId = @import("mod.zig").generateSessionId;

/// Create a new worker (background task execution unit)
/// Request body (JSON, optional):
///   - session_id: custom worker ID (string, optional, auto-generated if not provided)
///   - initial_message: initial message to process (string, optional)
///   - auto_start: whether to immediately start processing (bool, default: true)
///   - cwd: working directory for the worker (string, optional)
/// Returns JSON with created worker info
pub fn worker_create_handler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Parse request body
    var session_id: ?[]u8 = null;
    var initial_message: ?[]u8 = null;
    var auto_start: bool = true;
    var cwd: ?[]u8 = null;

    const body = req.body;

    if (body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }) });
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract session_id if provided
        if (root.get("session_id")) |val| {
            if (val == .string) {
                session_id = try allocator.dupe(u8, val.string);
            }
        }

        // Extract initial_message if provided
        if (root.get("initial_message")) |val| {
            if (val == .string) {
                initial_message = try allocator.dupe(u8, val.string);
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
                cwd = try allocator.dupe(u8, val.string);
            }
        }
    }

    // Generate session_id if not provided
    if (session_id == null) {
        session_id = try generateSessionId(allocator);
    }

    if (gserverz.global_server) |server| {
        // Register session in session registry
        if (session_registry.get_global_registry()) |registry| {
            registry.register(session_id.?) catch {
                return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to register worker" }) });
            };
        }

        // Start workflow if auto_start is true
        if (auto_start) {
            if (server.ctx) |server_ctx| {
                const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
                const sqlite_db = ctxTui.db;

                // Mark as running in session registry
                if (session_registry.get_global_registry()) |registry| {
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
                    .io = ctxTui.io,
                    .sqlite_db = sqlite_db,
                    .logger = ctxTui.logger,
                    .llm_config = ctxTui.llm_config,
                    .session_id = try server.allocator.dupe(u8, session_id.?),
                    .message = try server.allocator.dupe(u8, initial_message orelse ""),
                    .cwd = try server.allocator.dupe(u8, cwd orelse ""),
                    .environment = server.environment,
                    .active_loops = ctxTui.active_loops,
                };

                const thread = try std.Thread.spawn(.{}, struct {
                    fn run(args: *WorkflowArgs) void {
                        defer {
                            args.allocator.free(args.session_id);
                            args.allocator.free(args.message);
                            args.allocator.free(args.cwd);
                            args.allocator.destroy(args);
                            // Mark as idle when workflow completes
                            if (session_registry.get_global_registry()) |registry| {
                                registry.mark_idle(args.session_id);
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
                        }) catch |err| {
                            args.logger.errFmt("workflow.runAgenticMultiStep failed: {s}", .{@errorName(err)});
                        };
                    }
                }.run, .{workflow_args});
                thread.detach();
            }

            return res.jsonResponse( .{ .status_code = 201, .data = try http_response.makeWorkerResponse(allocator, .{ .id = session_id.?, .status = "running" }) });
        } else {
            // Worker created but not started
            return res.jsonResponse( .{ .status_code = 201, .data = try http_response.makeWorkerResponse(allocator, .{ .id = session_id.?, .status = "idle" }) });
        }
    }

    return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}