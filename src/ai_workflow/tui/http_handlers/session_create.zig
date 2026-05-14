const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const sqlite = nalarcore.sqlite;
const ai_workflow = nalarcore.ai_workflow;
const logger = nalarcore.logger;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;
const WorkflowArgs = @import("mod.zig").WorkflowArgs;
const generateSessionId = @import("mod.zig").generateSessionId;
const broadcastSessionCreated = @import("mod.zig").broadcastSessionCreated;

/// Helper to get nalar data directory (~/local/share/nalar/data/apps)
fn getDataAppsDir(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map) ![]u8 {
    _ = io;
    const home = environment.get("HOME") orelse {
        return error.HomeNotFound;
    };
    return std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".local",
        "share",
        "nalar",
        "data",
        "apps",
    });
}

/// Create a sandbox directory in data/apps and return the path
fn createSandbox(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map, session_id: []const u8) ![]u8 {
    const env = environment orelse return error.HomeNotFound;
    const data_apps_dir = try getDataAppsDir(allocator, io, env);
    defer allocator.free(data_apps_dir);

    // Create the data/apps directory and all parent directories if they don't exist
    try std.Io.Dir.cwd().createDirPath(io, data_apps_dir);

    // Generate a unique folder name using session_id
    const sandbox_name = try allocator.dupe(u8, session_id);
    errdefer allocator.free(sandbox_name);

    const sandbox_path = try std.fs.path.join(allocator, &[_][]const u8{
        data_apps_dir,
        sandbox_name,
    });
    errdefer allocator.free(sandbox_path);

    // Create the sandbox directory (ignore if already exists)
    std.Io.Dir.createDirAbsolute(io, sandbox_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    return sandbox_path;
}

/// Thread arguments for session creation workflow
const SessionCreateThreadArgs = struct {
    allocator: std.mem.Allocator,
    ctxTui: *ai_workflow.ContextIPCTui,
    session_id: []u8,
    session_name: []u8,
    queue_message: []u8,
    cwd_session: []u8,
    body_message: []u8,
    allowed_tools: []u8,
    environment: *const std.process.Environ.Map,
};

/// Create a new session
/// Request body (JSON, optional):
///   - name: session name (string, defaults to "New Session")
///   - session_id: custom session ID (string, optional, auto-generated if not provided)
///   - queue_message: initial message to add to session queue (string, optional)
///   - cwd_session: working directory (string, optional)
/// Returns JSON with created session info
pub fn session_create_handler(self: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    // Generate or parse session ID
    var session_id: []u8 = undefined;
    var session_name: []const u8 = "New Session";
    var queue_message: ?[]const u8 = null;
    var cwd_session: ?[]const u8 = null;
    var allowed_tools: []const u8 = ""; // empty string = no tools allowed, "all" = all tools allowed, comma-separated list = specific tools
    var body_message: []const u8 = ""; // initial message from body field

    const body = req.body() orelse "";
    std.debug.print("BODY: {s}\n", .{body});

    if (body.len > 0) {
        // Parse JSON body for optional parameters
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
            res.status = 400;
            res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Invalid JSON body" });
            return;
        };

        const root = parsed.value.object;

        // Extract session_id if provided
        if (root.get("session_id")) |val| {
            if (val == .string) {
                session_id = try alloc.dupe(u8, val.string);
            } else {
                res.status = 400;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "session_id must be a string" });
                return;
            }
        } else {
            // Generate unique session ID
            session_id = try generateSessionId(self, alloc);
        }

        // Extract name if provided
        if (root.get("name")) |val| {
            if (val == .string) {
                session_name = val.string;
            }
        }

        // Extract queue_message if provided
        if (root.get("queue_message")) |val| {
            if (val == .string) {
                queue_message = val.string;
            }
        }

        // Extract cwd_session if provided
        if (root.get("cwd_session")) |val| {
            if (val == .string) {
                cwd_session = val.string;
            }
        }

        // Extract body field (initial message from body field)
        if (root.get("body")) |val| {
            if (val == .string) {
                body_message = val.string;
            }
        }

        // Extract allowed_tools field (comma-separated list or "all")
        if (root.get("allowed_tools")) |val| {
            if (val == .string) {
                allowed_tools = val.string;
            }
        }
    } else {
        // No body provided, generate session ID
        session_id = try generateSessionId(self, alloc);
    }

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));

            // Spawn workflow in detached thread (fire-and-forget)
            // First allocate all strings, then create struct (to handle partial failures)
            const session_id_alloc = try server.allocator.dupe(u8, session_id);
            errdefer server.allocator.free(session_id_alloc);
            const session_name_alloc = try server.allocator.dupe(u8, session_name);
            errdefer server.allocator.free(session_name_alloc);
            const queue_message_alloc = if (queue_message) |m| try server.allocator.dupe(u8, m) else try server.allocator.dupe(u8, "");
            errdefer server.allocator.free(queue_message_alloc);
            const cwd_session_alloc = if (cwd_session) |c| try server.allocator.dupe(u8, c) else try server.allocator.dupe(u8, "");
            errdefer server.allocator.free(cwd_session_alloc);
            const body_message_alloc = try server.allocator.dupe(u8, body_message);
            errdefer server.allocator.free(body_message_alloc);
            const allowed_tools_alloc = try server.allocator.dupe(u8, allowed_tools);
            errdefer server.allocator.free(allowed_tools_alloc);

            const thread_args = try server.allocator.create(SessionCreateThreadArgs);
            errdefer server.allocator.destroy(thread_args);

            thread_args.* = .{
                .allocator = server.allocator,
                .ctxTui = ctxTui,
                .session_id = session_id_alloc,
                .session_name = session_name_alloc,
                .queue_message = queue_message_alloc,
                .cwd_session = cwd_session_alloc,
                .body_message = body_message_alloc,
                .allowed_tools = allowed_tools_alloc,
                .environment = server.environment,
            };

            const thread = try std.Thread.spawn(.{}, struct {
                fn run(args: *SessionCreateThreadArgs) void {
                    var thread_arena = std.heap.ArenaAllocator.init(args.allocator);
                    defer thread_arena.deinit();
                    const thread_alloc = thread_arena.allocator();

                    const sqlite_db = args.ctxTui.db;

                    // Ensure session exists in sessions table (for JOIN queries)
                    // If cwd_session is empty, create a sandbox in data/apps
                    var effective_cwd: []u8 = "";
                    if (args.cwd_session.len > 0) {
                        effective_cwd = args.cwd_session;
                    } else {
                        // Create sandbox in data/apps with session_id as folder name
                        effective_cwd = createSandbox(thread_alloc, args.ctxTui.io, args.environment, args.session_id) catch blk: {
                            // Fallback: use tmp directory if sandbox creation fails
                            const tmp_dir = args.environment.get("TMPDIR") orelse "/tmp";
                            break :blk (thread_alloc.dupe(u8, tmp_dir) catch return);
                        };
                    }

                    // effective_cwd is now set - use it for session and workflow

                    if (effective_cwd.len > 0) {
                        const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at) VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)";
                        const copy_session_name = thread_alloc.dupe(u8, args.session_name) catch return;
                        const copy_cwd = thread_alloc.dupe(u8, effective_cwd) catch return;
                        sqlite_db.exec(thread_alloc, session_sql, &.{ args.session_id, copy_session_name, copy_cwd }) catch {
                            // Non-fatal error, continue anyway
                        };
                    } else {
                        const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, created_at, updated_at) VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)";
                        const copy_session_name = thread_alloc.dupe(u8, args.session_name) catch return;
                        sqlite_db.exec(thread_alloc, session_sql, &.{ args.session_id, copy_session_name }) catch {
                            // Non-fatal error, continue anyway
                        };
                    }

                    // Broadcast session_created event to all connected session stream clients
                    broadcastSessionCreated(thread_alloc, args.session_id, args.session_name);

                    // Create workflow args
                    const workflow_args = thread_alloc.create(WorkflowArgs) catch return;

                    workflow_args.* = .{
                        .allocator = thread_alloc,
                        .io = args.ctxTui.io,
                        .sqlite_db = sqlite_db,
                        .logger = args.ctxTui.logger,
                        .llm_config = args.ctxTui.llm_config,
                        .session_id = args.session_id,
                        .message = args.queue_message,
                        .cwd = effective_cwd,
                        .body = args.body_message,
                        .allowed_tools = args.allowed_tools,
                        .environment = args.environment,
                        .active_loops = args.ctxTui.active_loops,
                    };

                    var workflow = ai_workflow.TUIWorkflow.init(workflow_args.io, workflow_args.sqlite_db, workflow_args.llm_config, workflow_args.logger, workflow_args.environment, workflow_args.active_loops);
                    workflow.runAgenticMultiStep(.{
                        .parent_allocator = thread_alloc,
                        .parent_session_id = workflow_args.session_id,
                        .session_id = workflow_args.session_id,
                        .message = workflow_args.message,
                        .cwd = workflow_args.cwd,
                        .body = workflow_args.body,
                        .allowed_tools = workflow_args.allowed_tools,
                    }) catch |err| {
                        workflow_args.logger.errFmt("workflow.runAgenticMultiStep failed: {s}", .{@errorName(err)});
                    };

                    // Clean up thread_args allocations (allocated before thread started)
                    const server_alloc = args.allocator;
                    server_alloc.free(args.session_id);
                    server_alloc.free(args.session_name);
                    server_alloc.free(args.queue_message);
                    server_alloc.free(args.cwd_session);
                    server_alloc.free(args.body_message);
                    server_alloc.free(args.allowed_tools);
                    server_alloc.destroy(args);
                }
            }.run, .{thread_args});
            thread.detach();

            res.status = 201;
            res.body = try http_response.makeSessionCreateResponse(alloc, .{ .id = session_id, .name = session_name, .status = "send" });
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
