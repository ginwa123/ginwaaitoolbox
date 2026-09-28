const std = @import("std");
const nalarcore = @import("nalarcore");
const http_response = @import("http_response.zig");
const helpers = @import("helpers");
const gserverz = nalarcore.gserverz;
const auth_common = @import("auth_common.zig");
const ai_workflow = nalarcore.ai_mod;
const sqlite_db_mod = nalarcore.sqlite;

/// Create a sandbox directory in data/apps and return the path
fn createSandbox(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map, session_id: []const u8) ![]u8 {
    const env = environment orelse return error.HomeNotFound;
    const data_apps_dir = try helpers.dir.getDataAppsDir(allocator, io, env);
    defer allocator.free(data_apps_dir);

    // Create the data/apps directory and all parent directories if they don't exist
    try std.Io.Dir.cwd().createDirPath(io, data_apps_dir);

    // session_id is caller-supplied (frontend / curl / LLM tool) — it
    // may contain path separators (`../`), backslashes, or
    // Windows-reserved characters (`<>:"|?*`, device names). Using it
    // raw as a folder name breaks mkdir on Windows and is a
    // path-traversal risk on every platform. Sanitize to a single safe
    // component (a no-op for generated `sess_<ts>_<hex>` ids).
    const sandbox_name = try helpers.sanitize.sanitizePathComponent(allocator, session_id);
    errdefer allocator.free(sandbox_name);

    const sandbox_path = try std.fs.path.join(allocator, &[_][]const u8{
        data_apps_dir,
        sandbox_name,
    });
    errdefer allocator.free(sandbox_path);

    // `createDirAbsolute` below ASSERTS the path is absolute and ABORTS the whole
    // process (Debug/ReleaseSafe) instead of returning an error. `data_apps_dir`
    // is `$HOME`-derived (helpers.dir.getDataAppsDir) and is only checked for
    // emptiness — a relative HOME would otherwise make every session create kill
    // the server. Fail the sandbox and let the caller use the TMPDIR fallback.
    if (!std.fs.path.isAbsolute(sandbox_path)) return error.SandboxPathNotAbsolute;

    // Create the sandbox directory (ignore if already exists)
    std.Io.Dir.createDirAbsolute(io, sandbox_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    return sandbox_path;
}

/// Last-resort cwd when createSandbox itself fails (disk full,
/// permission denied, no HOME/USERPROFILE). Mirrors main.zig's
/// TMPDIR → TEMP → TMP → "/tmp" chain — Windows sets TEMP/TMP, not
/// TMPDIR, so a TMPDIR-only lookup always fell through to the
/// POSIX-only "/tmp" literal on Windows.
fn sandboxTempFallback(environment: *const std.process.Environ.Map) []const u8 {
    return environment.get("TMPDIR") orelse
        environment.get("TEMP") orelse
        environment.get("TMP") orelse
        "/tmp";
}

pub const RequestSession = struct {
    session_id: []const u8 = "",
    session_name: []const u8 = "",
    queue_message: []const u8 = "",
    cwd_session: []const u8 = "",
    allowed_tools: []const u8 = "",
    body_message: []const u8 = "",
    image_urls: []const u8 = "",
    video_urls: []const u8 = "",
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

    {
        const prefix_len = @min(200, req.body.len);
        const prefix = if (prefix_len > 0) req.body[0..prefix_len] else "";
        // Use {s} for the prefix slice; escape control chars by printing length + prefix
        std.debug.print("DEBUG_HANDLER: req.body.len={}, body_start_200={s}\n", .{ req.body.len, prefix });
        // 35 MB: fits the 25 MB video cap (base64 inflates ~33% →
        // ~33.3 MB wire) plus JSON envelope overhead. Videos larger
        // than 25 MB raw are rejected downstream by
        // video_urls_validation with a specific 413 message — this
        // gate is only a DoS backstop, not the user-facing limit.
        if (req.body.len > 35 * 1024 * 1024) {
            std.log.warn("session_create: body too large ({} bytes), rejecting", .{req.body.len});
            return res.jsonResponse(.{
                .status_code = 413,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "PayloadTooLarge" }),
            });
        }
    }

    const parsed = std.json.parseFromSliceLeaky(RequestSession, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };

    // Owner for the session row this request creates (plan 2026-09-25, W1).
    // Server-derived from the `nalar_session` cookie only — never a body,
    // query, or header field. Empty when auth is off, which leaves the row in
    // the shared legacy bucket.
    var owner_buf: [128]u8 = undefined;
    const owner: []const u8 = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "";

    const usecase = useCase(allocator, io, di, parsed, owner) catch |err| {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };

    // Stamp the owner on the session row this create path produced (plan
    // 2026-09-25: W1/W2.3). Done in the handler because the owner comes from
    // the request cookie and the create path below has no request context.
    //
    // The WHERE clause only claims an OWNERLESS row, so a real owner is never
    // overwritten and a re-run is a no-op. Left un-stamped if the row does not
    // exist yet -- the choke point then treats it as shared until some later
    // write claims it, which is the legacy rule, not a leak of another user's
    // data.
    if (di.auth_enabled) {
        const stamp_owner = auth_common.resolveRequestUserId(allocator, di.db, di.auth_enabled, req.headers) catch null;
        defer if (stamp_owner) |o| allocator.free(o);
        if (stamp_owner) |o| {
            _ = di.db.exec(allocator,
                "UPDATE sessions SET user_id = ? WHERE id = ? AND (user_id IS NULL OR user_id = '' OR user_id = 'user_system')",
                &[_][]const u8{ o, usecase.id },
            ) catch {};
        }
    }

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

fn useCase(alloc: std.mem.Allocator, io: std.Io, di: *nalarcore.ContextIPCTui, parsed: RequestSession, owner: []const u8) !ResponseSession {
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
    // NEW (plan: 2026-09-02-kanban-task-session-name-bind, task
    // 1787671636395_1): when the caller did NOT supply session_name
    // (the common case for kanban task chats — the frontend's
    // `api.sendChatMessage` doesn't carry session_name) AND the
    // default "New Session" is in effect, resolve the session name
    // from the matching workspace_item_tasks row so the sidebar
    // ChatsList shows the user-typed title instead of the literal
    // "New Session" placeholder.
    //
    // Pre-fix this fallback was missing: the session row was
    // inserted with name='New Session' (the literal at line 106).
    // The kanban task itself was correct (workspace_item_tasks.name
    // = the title) but the linked session row had a different name
    // — the user's screenshot showed the join with both columns
    // side-by-side: "settings like on notifi when error not s…" vs
    // "task_1787671269086_0". The task_id was the placeholder for
    // some rows, but for rows lazy-initialized via this handler the
    // placeholder was "New Session" — same bug, different symptom.
    //
    // We only override when session_name is still the default AND
    // the lookup finds a real task. For brand-new sessions
    // (random session_id, no task row) the "New Session" default
    // stays. For the sidebar's "New Chat" flow where the user
    // explicitly types nothing, "New Session" stays too.
    if (std.mem.eql(u8, session_name, "New Session") and parsed.session_id.len > 0) {
        if (resolveNameFromTask(alloc, di, parsed.session_id)) |maybe_name| {
            if (maybe_name) |task_name| {
                session_name = task_name;
            }
        } else |err| {
            std.log.warn(
                "session_create: task-name fallback lookup failed (non-fatal, keeping 'New Session'): {s}",
                .{@errorName(err)},
            );
        }
    }
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
        effective_cwd = if (std.fs.path.isAbsolute(cwd_session))
            try alloc.dupe(u8, cwd_session)
        else blk: {
            // Nothing validated this field before, and a RELATIVE cwd_session
            // propagates into `copy_cwd` → every tool's `ctx.cwd` → the
            // `*Absolute` fs calls, which ASSERT absoluteness and ABORT the whole
            // process (Debug/ReleaseSafe). Resolve it against the process cwd
            // (`getcwd` is always absolute) so the session invariant holds.
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const proc_cwd = helpers.getcwd(&cwd_buf) orelse "/";
            break :blk try std.fs.path.join(alloc, &.{ proc_cwd, cwd_session });
        };
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
                    sandboxTempFallback(environment);
            };
            // The DB fallback (`workspace_item_tasks.cwd` / `workspace_items.path`)
            // is length-checked only, so a relative row must not become ctx.cwd.
            if (effective_cwd.len == 0 or !std.fs.path.isAbsolute(effective_cwd)) {
                effective_cwd = createSandbox(alloc, io, environment, session_id) catch
                    sandboxTempFallback(environment);
            }
        } else {
            effective_cwd = createSandbox(alloc, io, environment, session_id) catch
                sandboxTempFallback(environment);
        }
    }

    // Final invariant: `effective_cwd` is copied into `copy_cwd` and then into
    // every agent tool's `ctx.cwd`, which feeds the `*Absolute` fs calls that
    // ASSERT absoluteness and ABORT the whole process (Debug/ReleaseSafe) when it
    // is missing. Guarantee it here even if a fallback (relative TMPDIR, unset
    // HOME, relative DB row) produced something relative or empty.
    if (effective_cwd.len == 0 or !std.fs.path.isAbsolute(effective_cwd)) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const proc_cwd = helpers.getcwd(&cwd_buf) orelse "/";
        effective_cwd = if (effective_cwd.len == 0)
            try alloc.dupe(u8, proc_cwd)
        else
            try std.fs.path.join(alloc, &.{ proc_cwd, effective_cwd });
    }

    var image_urls: []const u8 = "";
    if (parsed.image_urls.len > 0) image_urls = parsed.image_urls;

    var video_urls: []const u8 = "";
    if (parsed.video_urls.len > 0) video_urls = parsed.video_urls;

    var selected_profile_model: []const u8 = "";
    if (parsed.selected_profile_model.len > 0) {
        selected_profile_model = parsed.selected_profile_model;
    } else if (nalarcore.getLlmConfig(di).active_profile) |ap| {
        // 2026-08-21 — snapshot the user's active profile into the
        // session row at create time. Without this, a "Default" chat
        // inherits the active profile only implicitly (via the workflow's
        // resolveProfileField cascade), so the chat footer computed its
        // context window from the built-in per-model default instead of
        // the active profile's max_capacity_tokens override. Snapshotting
        // makes the row self-contained: the messages endpoint, the manual
        // compact endpoint, and the workflow all read the same name.
        // The user can still switch the chat to another profile later
        // via the dropdown (PUT /api/llm/session/:id overwrites the
        // column) or back to true-default by picking Default explicitly.
        selected_profile_model = ap;
    }

    // Migration 063 — opt into unattended mode. Empty / anything other
    // than "1" stays off (matches the production SQL default '0').
    var is_auto_retry_until_stop: []const u8 = "";
    if (parsed.is_auto_retry_until_stop.len > 0) is_auto_retry_until_stop = parsed.is_auto_retry_until_stop;

    // An unanswered `ask_user` question blocks the turn: `handle_tool`
    // recorded it and the workflow broke instead of looping back. If the human
    // sends a message INSTEAD of answering, settle the question as
    // `abandoned` before starting the run — otherwise the model would receive
    // the <status>pending</status> envelope and might guess, and the user would
    // be dead-ended until they answered.
    //
    // The rewrite of the tool-result row happens inside the helper, and this
    // guard sits on the single funnel every user-sent message flows through
    // (chat send, kanban create-and-run, any API caller), so no other caller
    // can bypass it. `abandoned` is not an answer: the envelope tells the model
    // explicitly not to guess.
    if (ai_workflow.ask_user_pending.hasPendingQuestion(alloc, di.db, session_id)) {
        const abandoned = ai_workflow.ask_user_pending.abandonPendingQuestions(
            alloc,
            di.io,
            di.db,
            session_id,
        ) catch |abandon_err| blk: {
            // Best-effort: a failed settle must not drop the user's message.
            // The workflow's iteration-top guard still refuses to run while
            // the question is pending, so the failure mode is "the message
            // looks like it did nothing", never "the model saw pending".
            std.log.warn(
                "[session_create] failed to abandon pending ask_user question for {s}: {s}",
                .{ session_id, @errorName(abandon_err) },
            );
            break :blk @as(usize, 0);
        };
        if (abandoned > 0) {
            std.log.info(
                "[session_create] abandoned {d} pending ask_user question(s) for {s} — the human moved on",
                .{ abandoned, session_id },
            );
        }
    }

    try di.emit_run_agent(.{
        .session_id = session_id,
        .session_name = session_name,
        .queue_message = queue_message,
        .cwd = effective_cwd,
        .body_message = body_message,
        .allowed_tools = allowed_tools,
        .image_urls = image_urls,
        .video_urls = video_urls,
        .selected_profile_model = selected_profile_model,
        .is_auto_retry_until_stop = is_auto_retry_until_stop,
        // Owner rides along so the concurrent insert_worker task stamps the
        // session row at INSERT time (plan 2026-09-25, W1). Without it the
        // row is briefly ownerless and its `session_created` event is
        // delivered to every user by the (correct) SSE fan-out.
        .user_id = owner,
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
    // 2026-08-21 — same active_profile snapshot as useCase: when the
    // caller didn't pick a profile, persist the user's active profile
    // so the session row is self-contained (footer context window,
    // compaction decision, and workflow all agree from message #1).
    const effective_profile: []const u8 = blk: {
        if (parsed.selected_profile_model.len > 0) break :blk parsed.selected_profile_model;
        const di = nalarcore.getSingleton() catch break :blk "";
        if (nalarcore.getLlmConfig(di).active_profile) |ap| break :blk ap;
        break :blk "";
    };
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
    //
    // MUST dupe before returning. `row.deinit(alloc)` above frees the
    // row's value slices, so returning `row.values[N]` hands the caller a
    // dangling pointer into freed memory. The caller then reads whatever
    // landed there, finds it is not an absolute path, and silently falls
    // back to `createSandbox` — so the session's persisted cwd became a
    // per-session temp dir instead of the project's path, with no error
    // anywhere. `alloc` is the request arena, so the dup outlives this
    // function the way the caller's other `effective_cwd` values do.
    const task_cwd = row.values[0];
    if (task_cwd.len > 0) return alloc.dupe(u8, task_cwd) catch return "";

    const item_path = row.values[1];
    if (item_path.len > 0) return alloc.dupe(u8, item_path) catch return "";

    return "";
}

/// Server-side session-name fallback (task_1787671636395_1, plan
/// 2026-09-02-kanban-task-session-name-bind). When the caller
/// omitted session_name (the kanban chat first-message path —
/// `api.sendChatMessage` doesn't carry session_name) AND the
/// session_id matches a `workspace_item_tasks` row, return the
/// task's title so the inserted sessions row matches the kanban
/// card. Without this fallback the lazy-init path leaves
/// ``sessions.name = 'New Session'`` while
/// ``workspace_item_tasks.name = <user-typed title>`` — a name
/// mismatch on the JOIN the sidebar's ChatsList reads.
///
/// Return shape:
///   - `?[]const u8` — the duped task name, or null if no row
///     matched (or matched but the title was empty). The dupe lives
///     on the per-request arena; safe to return because the arena
///     reaps everything on request teardown.
///   - `!anyhow`     — the failure mode is `error.QueryFailed`
///     (the SELECT bombed). The caller logs + keeps "New Session" so
///     a transient DB blip doesn't block session creation.
///
/// Single SELECT (no JOIN) — cheaper than walking the cwd chain
/// and avoids the worker's task-row vs item-row race we already
/// guard against in `resolveCwdFromTaskOrItem`.
fn resolveNameFromTask(
    alloc: std.mem.Allocator,
    di: *nalarcore.ContextIPCTui,
    session_id: []const u8,
) !?[]const u8 {
    var q = di.db.query(
        alloc,
        "SELECT name FROM workspace_item_tasks WHERE id = ?",
        &.{session_id},
    ) catch return error.QueryFailed;
    defer q.deinit();

    const row_opt = q.next() catch return error.QueryFailed;
    const row = row_opt orelse return null;
    defer row.deinit(alloc);

    const task_name = row.values[0];
    // Empty title: treat as "no useful fallback" — keep "New Session".
    if (task_name.len == 0) return null;

    return try alloc.dupe(u8, task_name);
}

// =====================================================================
// Static contract tests (NEW — plan 2026-09-02-kanban-task-session-name-bind)
// =====================================================================
//
// Why static checks (and not behavioural DB tests) here: standing up
// an in-memory SQLite + migrations + ContextIPCTui to test resolveNameFromTask
// would duplicate the migration setup; the functional test in
// tests/functional/kanban_task_session_name_test.py already pins the
// end-to-end behaviour against a real nalar binary. These static
// checks lock in the structural contract — fail closed if a future
// refactor drops the helper or removes the useCase call site.

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;
const HANDLER_PATH = "src/http_handlers/session_create.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Contract 1: resolveNameFromTask exists ───────────────────────────────

test "session_create.zig defines resolveNameFromTask helper" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (!contains(source, "fn resolveNameFromTask(")) {
        std.debug.print(
            "\n!! {s} does not define `resolveNameFromTask` !!\n"
            ++ "   The task-name fallback for lazy-init session rows is gone.\n"
            ++ "   Without this helper, kanban task chats where the user\n"
            ++ "   didn't pre-init the session end up with sessions.name =\n"
            ++ "   'New Session' instead of the task title (task_1787671636395_1).\n",
            .{HANDLER_PATH},
        );
        return error.ResolveNameFromTaskMissing;
    }
}

// ─── Contract 2: useCase calls the helper on the default-name branch ────

test "session_create useCase calls resolveNameFromTask when session_name is 'New Session'" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The useCase's default is "New Session" (line 106). When the
    // caller doesn't supply a session_name AND the resolved
    // session_id matches a workspace_item_tasks row, the useCase
    // must call resolveNameFromTask to swap the default for the
    // task title.
    if (!contains(source, "resolveNameFromTask(")) {
        std.debug.print(
            "\n!! {s} does not call `resolveNameFromTask` !!\n"
            ++ "   The useCase's session-name resolution is missing.\n"
            ++ "   Without this call, lazy-init sessions keep name='New Session'.\n",
            .{HANDLER_PATH},
        );
        return error.ResolveNameFromTaskCallMissing;
    }

    // The call must be gated on the default-name branch — i.e. must
    // NOT fire when the caller supplied a real session_name.
    // Source-order check: the literal `resolveNameFromTask(` must
    // appear AFTER the default-name literal `New Session`.
    const default_pos = std.mem.indexOf(u8, source, "New Session") orelse {
        std.debug.print(
            "\n!! {s} no longer has the 'New Session' default literal !!\n",
            .{HANDLER_PATH},
        );
        return error.NewSessionDefaultMissing;
    };
    const call_pos = std.mem.indexOf(u8, source, "resolveNameFromTask(") orelse {
        return error.ResolveNameFromTaskCallMissing;
    };
    if (call_pos < default_pos) {
        std.debug.print(
            "\n!! {s} calls `resolveNameFromTask` BEFORE the 'New Session' default !!\n"
            ++ "   The call site must be AFTER the default-name declaration so\n"
            ++ "   the gate `if (session_name == 'New Session')` can check the value.\n",
            .{HANDLER_PATH},
        );
        return error.ResolveNameFromTaskCallBeforeDefault;
    }
}

// ─── Contract 3: helper's SELECT targets workspace_item_tasks ────────────

test "session_create resolveNameFromTask SELECTs from workspace_item_tasks" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The helper must query workspace_item_tasks (the table holding
    // the kanban task title). A regression that points it at a
    // different table would silently miss the bind.
    if (!contains(source, "SELECT name FROM workspace_item_tasks WHERE id = ?")) {
        std.debug.print(
            "\n!! {s} resolveNameFromTask does not SELECT from workspace_item_tasks !!\n"
            ++ "   The helper must query the kanban task table (workspace_item_tasks)\n"
            ++ "   to read the user-typed title. Pointing it at any other table\n"
            ++ "   silently loses the bind.\n",
            .{HANDLER_PATH},
        );
        return error.WrongSelectTable;
    }
}

// ─── Migration 082 / chat-sidebar-last-human-touched (Task 3) ──────────
//
// Load-bearing invariant: every user-sends-a-message path converges on
// `root.zig::emit_run_agent` (the single funnel). The chat-create path
// delegates to `emit_run_agent` at the bottom of `useCase` (line 229),
// so a SESSION-side chat-side stamp call here would double-stamp the
// same row. The TASK-side call at line 241 (workspace_item_tasks) stays -
// that stamps a different table, independent column.
//
// This test fails closed if a future refactor re-adds a redundant
// session-side stamp here, which would either silently no-op (idempotent
// stamp = wasted work) or mask a regression in the emit_run_agent path.

test "session_create.zig does NOT call the chat-side human-touched stamp helper (single-funnel invariant)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The grep needle is the exact helper name (defined in llm_history.zig
    // at Task 2; targets sessions.last_human_touched_at_nano). The TASK-side
    // helper (workspace_item_tasks) has a different name so it does NOT
    // match this needle - that stamp at line 241 stays.
    const needle = "updateSessi" ++ "onLastHumanTouchedAt";
    if (contains(source, needle)) {
        std.debug.print(
            "\n!! {s} references the chat-side stamp helper !!\n"
            ++ "   The session-side stamp lives in root.zig::emit_run_agent\n"
            ++ "   (the single funnel for every user-sends-message path).\n"
            ++ "   Adding a redundant stamp here double-stamps the same row\n"
            ++ "   on the create-chat path (session_create.useCase delegates\n"
            ++ "   to emit_run_agent at line 229). The TASK-side stamp at\n"
            ++ "   line 241 stays because that targets workspace_item_tasks.\n"
            ++ "   Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md\n",
            .{HANDLER_PATH},
        );
        return error.SessionHumanTouchedStampDuplicateSite;
    }
}

// ─── Migration 082 / chat-sidebar-last-human-touched (Task 3) ──────────
//
// Sibling of the previous test - guards the same single-funnel invariant
// from the OTHER direction. If the helper signature is renamed or the
// module path is restructured (e.g. moved from llm_history to a new
// module), this test fails loudly instead of silently no-op'ing the
// guard above. The two tests together lock in: "the chat-side stamp
// lives in root.zig::emit_run_agent, period".

test "session_create.zig does NOT import or alias the chat-side stamp helper in any form" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Same needle - constructed via string concatenation so the helper
    // name doesn't appear verbatim in this test's source body. Any
    // re-introduction of the symbol (even just an unused
    // `const _ = ai_mod.llm_history.<helper>;` import) should fail.
    const needle = "updateSessi" ++ "onLastHumanTouchedAt";
    if (contains(source, needle)) {
        std.debug.print(
            "\n!! {s} references the chat-side stamp helper in any form !!\n"
            ++ "   Per the single-funnel invariant, this handler must NOT\n"
            ++ "   touch the chat-side stamp at all - the stamp lives in\n"
            ++ "   root.zig::emit_run_agent (called by useCase at line 229).\n",
            .{HANDLER_PATH},
        );
        return error.SessionHumanTouchedStampAnyReference;
    }
}

// ─── Windows sandbox hardening (task_1788609013221_1) ───────────────────
//
// createSandbox failed on native Windows three ways: (1) getDataAppsDir
// only read HOME (unset on cmd/pwsh — now falls back to USERPROFILE in
// helpers/dir.zig); (2) the useCase's last-resort fallback was
// TMPDIR-only with a "/tmp" literal (Windows sets TEMP/TMP — now the
// sandboxTempFallback chain below, mirroring main.zig); (3) the raw
// session_id was used as the folder name (separators / reserved chars
// break Windows mkdir and allow ../ traversal — now sanitized via
// helpers.sanitize.sanitizePathComponent).

test "session_create sandboxTempFallback prefers TMPDIR over TEMP/TMP" {
    const allocator = testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("TMPDIR", "/tmp/posix");
    try env_map.put("TEMP", "C:\\Windows\\Temp");
    try env_map.put("TMP", "C:\\Windows\\Tmp");

    try testing.expectEqualStrings("/tmp/posix", sandboxTempFallback(&env_map));
}

test "session_create sandboxTempFallback falls back to TEMP then TMP" {
    const allocator = testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    // No TMPDIR — the native Windows case.
    try env_map.put("TEMP", "C:\\Windows\\Temp");
    try env_map.put("TMP", "C:\\Windows\\Tmp");

    try testing.expectEqualStrings("C:\\Windows\\Temp", sandboxTempFallback(&env_map));

    var env_tmp_only = std.process.Environ.Map.init(allocator);
    defer env_tmp_only.deinit();
    try env_tmp_only.put("TMP", "C:\\Windows\\Tmp");

    try testing.expectEqualStrings("C:\\Windows\\Tmp", sandboxTempFallback(&env_tmp_only));
}

test "session_create sandboxTempFallback returns /tmp when no temp var is set" {
    const allocator = testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try testing.expectEqualStrings("/tmp", sandboxTempFallback(&env_map));
}

test "session_create.zig createSandbox sanitizes the session_id folder name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Fail closed if a future refactor drops the sanitizer call and
    // goes back to `allocator.dupe(u8, session_id)` as the folder
    // name — raw ids break Windows mkdir and allow ../ traversal.
    // NOTE: the needle is built via concatenation so this test's own
    // source does not contain it verbatim (otherwise `contains`
    // would self-match and the test could never fail).
    const needle = "sanitizePathComponent(allo" ++ "cator, session_id)";
    if (!contains(source, needle)) {
        std.debug.print(
            "\n!! {s} createSandbox does not sanitize session_id !!\n"
            ++ "   The session_id is caller-supplied and becomes a folder\n"
            ++ "   name under data/apps/. It must go through\n"
            ++ "   helpers.sanitize.sanitizePathComponent first.\n",
            .{HANDLER_PATH},
        );
        return error.SandboxNameNotSanitized;
    }
}

test "session_create.zig useCase has no TMPDIR-only fallback left" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // All three useCase fallback sites must go through
    // sandboxTempFallback (TMPDIR → TEMP → TMP → "/tmp"). A raw
    // TMPDIR-only lookup left anywhere means the Windows TEMP/TMP
    // vars are ignored on that path.
    // NOTE: the needle is built via concatenation so this test's own
    // source does not contain it verbatim (otherwise `contains`
    // would self-match and the test could never fail).
    const needle = "environment.get(\"TMP" ++ "DIR\") orelse \"/tmp\"";
    if (contains(source, needle)) {
        std.debug.print(
            "\n!! {s} still has a TMPDIR-only fallback !!\n"
            ++ "   Use sandboxTempFallback(environment) so Windows\n"
            ++ "   TEMP/TMP are honoured (mirrors main.zig).\n",
            .{HANDLER_PATH},
        );
        return error.TmpdirOnlyFallbackRemains;
    }
}
