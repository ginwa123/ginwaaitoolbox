const std = @import("std");
const nalarcore = @import("nalarcore");
const http_response = @import("http_response.zig");
const helpers = nalarcore.helpers;
const gserverz = nalarcore.gserverz;
const ai_workflow = nalarcore.ai_mod;
const sqlite_db_mod = nalarcore.sqlite;

/// Create a sandbox directory in data/apps and return the path
fn createSandbox(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map, session_id: []const u8) ![]u8 {
    const env = environment orelse return error.HomeNotFound;
    const data_apps_dir = try helpers.dir.getDataAppsDir(allocator, io, env);
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

pub const RequestSession = struct {
    session_id: []const u8 = "",
    session_name: []const u8 = "",
    queue_message: []const u8 = "",
    cwd_session: []const u8 = "",
    allowed_tools: []const u8 = "",
    body_message: []const u8 = "",
    image_urls: []const u8 = "",
    selected_profile_model: []const u8 = "", // NEW: name of profile in LlmConfig.profiles_models
};

pub const ResponseSession = struct {
    id: []const u8,
    name: []const u8,
    status: []const u8,
};

/// Create a new session
/// Request body (JSON, optional):
///   - name: session name (string, defaults to "New Session")
///   - session_id: custom session ID (string, optional, auto-generated if not provided)
///   - queue_message: initial message to add to session queue (string, optional)
///   - cwd_session: working directory (string, optional)
/// Returns JSON with created session info
pub fn sessionCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;
    const di = try nalarcore.getSingleton();

    std.debug.print("DEBUG_HANDLER: req.body.len={}, body_start_20={}\n", .{req.body.len, req.body.len});

    const parsed = std.json.parseFromSliceLeaky(RequestSession, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };

    const usecase = useCase(allocator, io, di, parsed) catch |err| {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };

    const data = try http_response.makeSessionCreateResponse(allocator, .{
        .id = usecase.id,
        .name = usecase.name,
        .status = "send",
    });

    return res.jsonResponse(.{
        .status_code = 201,
        .data = data,
    });
}

fn useCase(_: std.mem.Allocator, io: std.Io, di: *nalarcore.ContextIPCTui, parsed: RequestSession) !ResponseSession {
    const sqlite_db = di.db;
    const environment = di.environment orelse return error.EnvironmentNotInitialized;

    // Arena is ONLY for local computation in this function
    var arena_allocator = std.heap.ArenaAllocator.init(di.allocator);
    defer arena_allocator.deinit();
    const local = arena_allocator.allocator();

    // --- Resolve all values locally using arena ---
    var session_id: []u8 = undefined;
    var session_name: []const u8 = "New Session";
    var queue_message: []const u8 = "";
    var cwd_session: []const u8 = "";
    var allowed_tools: []const u8 = "";
    var body_message: []const u8 = "";

    if (parsed.session_id.len > 0) {
        session_id = try local.dupe(u8, parsed.session_id);
    } else {
        session_id = try helpers.random.generateSessionId(local, io);
    }
    if (parsed.session_name.len > 0) session_name = parsed.session_name;
    if (parsed.queue_message.len > 0) queue_message = parsed.queue_message;
    if (parsed.cwd_session.len > 0) cwd_session = parsed.cwd_session;
    if (parsed.body_message.len > 0) body_message = parsed.body_message;
    if (parsed.allowed_tools.len > 0) allowed_tools = parsed.allowed_tools;

    var effective_cwd: []const u8 = "";
    if (cwd_session.len > 0) {
        effective_cwd = try local.dupe(u8, cwd_session);
    } else {
        effective_cwd = createSandbox(local, io, environment, session_id) catch
            environment.get("TMPDIR") orelse "/tmp";
    }

    var image_urls: []const u8 = "";
    if (parsed.image_urls.len > 0) image_urls = parsed.image_urls;

    var selected_profile_model: []const u8 = "";
    if (parsed.selected_profile_model.len > 0) selected_profile_model = parsed.selected_profile_model;

    try insertWorker(local, sqlite_db, parsed, image_urls);

    // --- Heap-allocate data for the async task (task owns these, frees them) ---
    const thread_session_id = try di.allocator.dupe(u8, session_id);
    const thread_queue_message = try di.allocator.dupe(u8, queue_message);
    const thread_effective_cwd = try di.allocator.dupe(u8, effective_cwd);
    const thread_body_message = try di.allocator.dupe(u8, body_message);
    const thread_allowed_tools = try di.allocator.dupe(u8, allowed_tools);
    const thread_image_urls = try di.allocator.dupe(u8, image_urls);
    const thread_selected_profile_model = try di.allocator.dupe(u8, selected_profile_model);

    // If concurrent() fails, we must free the heap data ourselves
    errdefer {
        di.allocator.free(thread_session_id);
        di.allocator.free(thread_queue_message);
        di.allocator.free(thread_effective_cwd);
        di.allocator.free(thread_body_message);
        di.allocator.free(thread_allowed_tools);
        di.allocator.free(thread_image_urls);
        di.allocator.free(thread_selected_profile_model);
    }

    try di.group_emit_session_create.concurrent(
        io,
        struct {
            fn run(
                di_inner: *nalarcore.ContextIPCTui,
                sid: []u8,
                qmsg: []u8,
                cwd: []u8,
                bmsg: []u8,
                atools: []u8,
                iurls: []u8,
                spm: []u8, // NEW: selected_profile_model
            ) void {
                // Task owns these slices — free them when done
                defer di_inner.allocator.free(sid);
                defer di_inner.allocator.free(qmsg);
                defer di_inner.allocator.free(cwd);
                defer di_inner.allocator.free(bmsg);
                defer di_inner.allocator.free(atools);
                defer di_inner.allocator.free(iurls);
                defer di_inner.allocator.free(spm); // NEW

                const event_bus = di_inner.event_bus;
                event_bus.emit(ai_workflow.ai_workflow.RunParamsNew, "ai_worker_flow", .{
                    .parent_session_id = sid,
                    .session_id = sid,
                    .message = qmsg,
                    .cwd = cwd,
                    .body = bmsg,
                    .allowed_tools = atools,
                    .is_sub_agent = false,
                    .image_urls = iurls,
                    .selected_profile_model = spm, // NEW
                });
            }
        }.run,
        .{ di, thread_session_id, thread_queue_message, thread_effective_cwd, thread_body_message, thread_allowed_tools, thread_image_urls, thread_selected_profile_model },
    );

    // ResponseSession.id must also outlive this function (caller may hold it)
    // If the caller is also short-lived, adjust accordingly
    const response_id = try di.allocator.dupe(u8, session_id);

    return ResponseSession{
        .id = response_id,
        .name = session_name,
        .status = "send",
    };
}

fn insertWorker(allocator: std.mem.Allocator, sqlite_db: *sqlite_db_mod.SqliteBackend, parsed: RequestSession, image_urls: []const u8) !void {

    _ = image_urls;
    const session_id = parsed.session_id;
    const session_name = parsed.session_name;
    const effective_cwd = parsed.cwd_session;
    const effective_profile = parsed.selected_profile_model;

    const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model) VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?)";
    const copy_session_name = try allocator.dupe(u8, session_name);
    defer allocator.free(copy_session_name);
    const copy_cwd = try allocator.dupe(u8, effective_cwd);
    defer allocator.free(copy_cwd);
    const copy_session_id = try allocator.dupe(u8, session_id);
    defer allocator.free(copy_session_id);
    const copy_profile = if (effective_profile.len > 0) try allocator.dupe(u8, effective_profile) else "";
    defer if (copy_profile.len > 0) allocator.free(copy_profile);
    try sqlite_db.exec(allocator, session_sql, &.{ session_id, copy_session_name, copy_cwd, copy_profile });

    // Broadcast session created event
    ai_workflow.on_event_sent.onEventSendSessions(allocator, .{
        .action = "created",
        .id = session_id,
        .name = session_name,
        .status = "active",
        .cwd = effective_cwd,
        .created_at = "",
        .updated_at = "",
        .selected_profile_model = effective_profile,
    }) catch {};
}
