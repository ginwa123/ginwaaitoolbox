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
    /// Migration 063 — "1" to opt into unattended mode (workflow keeps
    /// retrying past the 10-attempt TooManyRetries bail). Empty string
    /// OR anything other than "1" = off (matches the session's default).
    is_auto_retry_until_stop: []const u8 = "",
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

    std.debug.print("DEBUG_HANDLER: req.body.len={}, body_start_20={}\n", .{ req.body.len, req.body.len });

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

fn useCase(alloc: std.mem.Allocator, io: std.Io, di: *nalarcore.ContextIPCTui, parsed: RequestSession) !ResponseSession {
    const environment = di.environment orelse return error.EnvironmentNotInitialized;

    // --- Resolve all values locally using arena ---
    var session_id: []u8 = undefined;
    var session_name: []const u8 = "New Session";
    var queue_message: []const u8 = "";
    var cwd_session: []const u8 = "";
    var allowed_tools: []const u8 = "";
    var body_message: []const u8 = "";

    if (parsed.session_id.len > 0) {
        session_id = try alloc.dupe(u8, parsed.session_id);
    } else {
        session_id = try helpers.random.generateSessionId(alloc, io);
    }
    if (parsed.session_name.len > 0) session_name = parsed.session_name;
    if (parsed.queue_message.len > 0) queue_message = parsed.queue_message;
    if (parsed.cwd_session.len > 0) cwd_session = parsed.cwd_session;
    if (parsed.body_message.len > 0) body_message = parsed.body_message;
    if (parsed.allowed_tools.len > 0) allowed_tools = parsed.allowed_tools;

    var effective_cwd: []const u8 = "";
    if (cwd_session.len > 0) {
        // Explicit per-call override wins (the frontend's
        // KanbanView threads the resolved cwd through to
        // runAgentOnNewTask → api.sendChatMessage's cwdSession
        // param. The frontend's resolution chain already covers
        // per-task cwd → kanban path → '' — so an explicit value
        // here means "the frontend already chose").
        effective_cwd = try alloc.dupe(u8, cwd_session);
    } else {
        // Server-side fallback (defense-in-depth). If the frontend
        // sent cwd_session = '' but session_id matches an
        // existing task, derive the cwd from the 3-level chain:
        //   1. workspace_item_tasks.cwd     (Migration 070, per-task)
        //   2. workspace_items.path         (kanban-level cwd)
        //   3. createSandbox(...)             (per-session TMPDIR fallback)
        // Used when the frontend is older / buggy / a non-Vue
        // client (e.g. curl, LLM tool emit_run_agent). For the
        // Vue path the frontend always sends cwd_session explicitly
        // (potentially ''), so this branch mostly handles non-Vue
        // call sites + re-emit safety.
        if (parsed.session_id.len > 0) {
            effective_cwd = resolveCwdFromTaskOrItem(
                alloc,
                di,
                parsed.session_id,
            ) catch |err| blk: {
                std.log.warn(
                    "session_create: cwd fallback lookup failed (non-fatal, falling back to sandbox): {s}",
                    .{@errorName(err)},
                );
                break :blk createSandbox(alloc, io, environment, session_id) catch
                    environment.get("TMPDIR") orelse "/tmp";
            };
            if (effective_cwd.len == 0) {
                effective_cwd = createSandbox(alloc, io, environment, session_id) catch
                    environment.get("TMPDIR") orelse "/tmp";
            }
        } else {
            effective_cwd = createSandbox(alloc, io, environment, session_id) catch
                environment.get("TMPDIR") orelse "/tmp";
        }
    }

    var image_urls: []const u8 = "";
    if (parsed.image_urls.len > 0) image_urls = parsed.image_urls;

    var selected_profile_model: []const u8 = "";
    if (parsed.selected_profile_model.len > 0) selected_profile_model = parsed.selected_profile_model;

    // Migration 063 — opt into unattended mode. Empty / anything other
    // than "1" stays off (matches the production SQL default '0').
    var is_auto_retry_until_stop: []const u8 = "";
    if (parsed.is_auto_retry_until_stop.len > 0) is_auto_retry_until_stop = parsed.is_auto_retry_until_stop;

    try di.emit_run_agent(.{
        .session_id = session_id,
        .session_name = session_name,
        .queue_message = queue_message,
        .cwd = effective_cwd,
        .body_message = body_message,
        .allowed_tools = allowed_tools,
        .image_urls = image_urls,
        .selected_profile_model = selected_profile_model,
        .is_auto_retry_until_stop = is_auto_retry_until_stop,
    });

    ai_workflow.llm_history.updateTaskLastHumanTouchedAt(
        alloc,
        di.db,
        session_id,
        null,
    ) catch |stamp_err| {
        std.log.warn(
            "session_create: stamp last_human_touched_at failed (non-fatal): {s}",
            .{@errorName(stamp_err)},
        );
    };

    return ResponseSession{
        .id = session_id,
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
    const effective_auto_retry: []const u8 = blk: {
        if (std.mem.eql(u8, parsed.is_auto_retry_until_stop, "1")) break :blk "1";
        break :blk "0";
    };

    const session_sql = "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop) " ++
        "VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?)";
    const copy_session_name = try allocator.dupe(u8, session_name);
    defer allocator.free(copy_session_name);
    const copy_cwd = try allocator.dupe(u8, effective_cwd);
    defer allocator.free(copy_cwd);
    const copy_session_id = try allocator.dupe(u8, session_id);
    defer allocator.free(copy_session_id);
    const copy_profile = if (effective_profile.len > 0) try allocator.dupe(u8, effective_profile) else "";
    defer if (copy_profile.len > 0) allocator.free(copy_profile);
    try sqlite_db.exec(
        allocator,
        session_sql,
        &.{ session_id, copy_session_name, copy_cwd, copy_profile, effective_auto_retry },
    );

    // Broadcast session created event
    try ai_workflow.on_event_sent.onEventSendSessions(allocator, .{
        .action = "created",
        .id = session_id,
        .name = session_name,
        .status = "active",
        .cwd = effective_cwd,
        .created_at = "",
        .updated_at = "",
        .selected_profile_model = effective_profile,
        .is_auto_retry_until_stop = effective_auto_retry,
        .last_finish_reason = "",
    });
}

/// Server-side cwd fallback chain (Migration 070). Returns the
/// first non-empty path in the chain:
///   1. `workspace_item_tasks.cwd` (per-task override)
///   2. `workspace_items.path` (kanban-level cwd)
///   3. `""` (caller falls back to createSandbox)
///
/// Borrows slices from the per-request arena; safe to return because
/// the arena reaps everything on request teardown. The returned slice
/// is one of the SQL row values — the caller MUST NOT free it.
///
/// Returns `""` when the session_id has no matching task row
/// (e.g. legacy sessions created before Migration 070) — caller is
/// responsible for falling back to `createSandbox(...)` on empty.
fn resolveCwdFromTaskOrItem(
    alloc: std.mem.Allocator,
    di: *nalarcore.ContextIPCTui,
    session_id: []const u8,
) ![]const u8 {
    // Single JOIN'd query — cheaper than two separate SELECTs and
    // avoids any race where the task exists but the parent item
    // is gone (extremely unlikely; both columns have FK semantics).
    var q = di.db.query(alloc,
        \\SELECT t.cwd, wi.path
        \\FROM workspace_item_tasks t
        \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
        \\WHERE t.id = ?
    , &.{session_id}) catch return "";
    defer q.deinit();

    const row = (q.next() catch return "") orelse return "";
    defer row.deinit(alloc);

    // The row has exactly 2 values: t.cwd (Migration 070), wi.path.
    // Migration 070 made `t.cwd` NOT NULL DEFAULT '' so this is
    // always a valid slice (possibly empty). `wi.path` is nullable
    // in legacy schemas (Migration 033 added it as nullable; later
    // migrations tightened it for kanban / design but NOT for
    // other workspace_item subtypes) — guard with len > 0.
    const task_cwd = row.values[0];
    if (task_cwd.len > 0) return task_cwd;

    const item_path = row.values[1];
    if (item_path.len > 0) return item_path;

    return "";
}
