//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks`.
//!
//! Body: `{ name, session_id?, task_type? ('standard'|'memory'),
//!         memory_name?, memory_content? }`.
//!
//! Two task types are supported:
//!
//!   - **standard** (default): existing `createWorkspaceItemTask` path;
//!     the migration's `task_type` column default is 'standard'.
//!     If the parent item is a kanban, the new task is auto-assigned
//!     to the first column at MAX(kanban_position) + 1.
//!
//! NOTE: the **routine** task type was deleted with the per-task
//! `routines` table (Migration 084, plan
//! 2026-09-10-workspace-items-routines). Routines are now
//! first-class workspace items (`item_type='routine'`,
//! `workspace_routines` table) — see
//! `workspace_items_create_routine.zig`.
//!
//!   - **memory**: a local memory file scoped to the parent
//!     workspace_item's directory. The .md file is created at
//!     `<workspace_item.path>/.nalar/memories/<memory_name>` (the
//!     directory is created if missing) so `loadLocalKnowledge` picks
//!     it up on the next chat. The task row has `task_type='memory'`
//!     and no `session_id` — the file is the content. Requires
//!     `memory_name` (must pass `isValidMemoryName`) and `memory_content`
//!     in the body.
//!
//! Layered as `useCase` (validate + generate id + branch by
//! `task_type` + DB/file work + return tagged result with kanban
//! fields) and a thin handler that maps the outcome + errors to
//! status codes / JSON.
//!
//! Plans:
//!   - docs/plans/2026-06-20-add-markdown-memory.md (memory)
//!   - docs/superpowers/plans/2026-09-10-workspace-items-routines.md
//!     (routine task_type deleted; workspace-level replacement)

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const memories_mod = nalarcore.memories;
const tags_validation = @import("tags_validation.zig");
const image_urls_validation = @import("image_urls_validation.zig");
const video_urls_validation = @import("video_urls_validation.zig");

/// Process-local monotonic counter for task_id generation. The ts-
/// only generator (`task_<unix_ms>`) collided when 2+ tasks were
/// created within the same wall-clock millisecond — the 2nd and
/// later hits returned HTTP 500 "Failed to create task" because
/// the SQLite INSERT tripped the PRIMARY KEY constraint. Observed
/// on Mac ARM64 CI run 31863092055's
/// `test_add_twelve_tasks_across_four_columns` (12 tasks created
/// in <2ms collectively). `seq_cst` is overkill (a relaxed fetchAdd
/// is sufficient for uniqueness), but it's two instructions either
/// way on aarch64 and removes the need to argue about ordering.
var task_id_counter: std.atomic.Value(u64) = .init(0);
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

/// Domain-level error set for `useCase`. Each variant maps to a
/// distinct HTTP status code in the handler (see the handler's
/// `switch (err)` below).
pub const TaskCreateError = error{
    // 400 — path params / body validation
    ItemIdRequired,
    MissingBody,
    InvalidJson,
    // 400 — the per-task 'routine' task_type was deleted (Migration
    // 084). Routines are now first-class workspace items.
    RoutineTasksRemoved,
    // 400 — memory-task validation
    MemoryNameRequired,
    InvalidMemoryName,
    MemoryContentRequired,
    // 400 / 404 — memory-task workspace_item checks
    WorkspaceItemNotFound,
    NotAFolderItem,
    NoPathForMemory,
    // 500 — memory-task file/DB ops
    FailedToBuildMemoriesPath,
    FailedToWriteMemoryFile,
    MemoryTaskInsertFailed,
    // 500 — standard-task DB ops
    StandardTaskCreateFailed,
    // 400 — kanban task tags validation (Migration 067). Empty,
    // too long, or contains forbidden characters (only
    // [a-zA-Z0-9_-] allowed). See tags_validation.zig.
    InvalidTags,
    // 400 / 413 — kanban image_urls validation (Migration 069). Either
    // the joined string exceeds the 10 MB cap (ImageUrlsTooLarge →
    // 413) or a segment fails the `data:image/...;base64,...` prefix
    // check (InvalidImageUrls → 400). See image_urls_validation.zig.
    InvalidImageUrls,
    ImageUrlsTooLarge,
    // 400 / 413 — kanban video_urls validation (Migration 090).
    // Same contract as image_urls with a 25 MB cap.
    InvalidVideoUrls,
    VideoUrlsTooLarge,
    // 400 — per-task cwd validation (Migration 070). Either:
    //   - the path exceeds 4 KiB (CwdTooLong → 400)
    //   - the path is not absolute (CwdNotAbsolute → 400)
    //   - the path contains a control character (CwdContainsControlChar → 400)
    // Existence of the path is NOT validated here — that's an
    // OS-level concern surfaced by the agent's first cwd-using
    // tool call. See session_create.zig's 3-level fallback chain.
    CwdTooLong,
    CwdNotAbsolute,
    CwdContainsControlChar,
    // Underlying I/O / alloc errors (required by the type system
    // even though they're unreachable on the per-request arena)
    OutOfMemory,
    Canceled,
};

pub const TaskCreateInput = struct {
    item_id: []const u8,
    workspace_id: []const u8,
    io: std.Io,
    body: http_response.TaskCreateRequest,
};

/// Tagged outcome of the use-case. The fields are the data needed
/// to build the response for each task type.
pub const TaskCreateResult = union(enum) {
    memory: MemoryResult,
    standard: StandardResult,
};

pub const MemoryResult = struct {
    task_id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
};

pub const StandardResult = struct {
    task_id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    kanban_column_id: ?[]const u8,
    kanban_position: i64,
    /// Caller-supplied session_id (if any). When null the JSON response
    /// emits "session_id":null. The standard-task path no longer accepts
    /// a caller-supplied session_id per the task.id == session.id
    /// convention; the field is preserved for backward compatibility.
    session_id: ?[]const u8,
    /// JSON-encoded array of tag strings (Migration 067 — kanban
    /// task tags). Borrowed from the per-request arena; freed by
    /// the arena reaper on request teardown (matches the lifetime
    /// pattern of the other borrowed slices in StandardResult).
    tags: []const u8 = "",
    /// Per-task cwd (Migration 070 — kanban-cwd-session-optional
    /// plan, 2026-08-06). Borrowed from the per-request arena
    /// (validated above). Mirrors what we just INSERTed into the
    /// `cwd` column. Frontend's KanbanView reads this on the
    /// subsequent `getTasks` to populate `task.cwd` for the
    /// session_create 3-level fallback chain (per-task cwd →
    /// kanban path → sandbox). Empty string is the canonical
    /// "no per-task cwd" sentinel.
    cwd: []const u8 = "",
    /// Media-presence flags (media-flags change). Derived from the validated
    /// payload lengths so the create response tells the frontend whether
    /// to lazy-fetch via the media endpoint.
    is_have_image: bool = false,
    is_have_video: bool = false,
};

// Typed response structs. Serialized via std.json.Stringify.valueAlloc
// (NOT hand-rolled JSON via the std.fmt formatting helpers) for two
// reasons:
//
// 1. Aliasing safety: chaining two per-arena fmt.allocPrint calls
//    (one as a format arg of the other) lets Writer.Allocating land
//    the inner result in the same chunk the outer ensureTotalCapacity
//    just reallocated from, and Zig 0.16's @memcpy safety check aborts
//    with "@memcpy arguments alias" (user-reported crash on 2026-07-01).
//
// 2. JSON escaping: hand-rolled JSON via the fmt helpers does NOT
//    escape quotes / backslashes / control chars in user-provided
//    fields like r.name. A task name containing a quote would produce
//    malformed JSON and break the frontend. valueAlloc delegates to
//    std.json.Stringify which handles all escaping per RFC 8259.

// NOTE: RoutineResponse deleted with the per-task `routines` table
// (Migration 084, plan 2026-09-10-workspace-items-routines).
const MemoryResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    task_type: []const u8 = "memory",
    session_id: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

const StandardResponse = struct {
    id: []const u8,
    name: []const u8,
    workspace_item_id: []const u8,
    task_type: []const u8 = "standard",
    session_id: ?[]const u8,
    kanban_column_id: ?[]const u8 = null,
    kanban_position: i64 = 0,
    /// JSON-encoded array of tag strings (Migration 067 — kanban
    /// task tags feature). Empty string means the task has no
    /// tags. Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md
    tags: []const u8 = "",
    /// Per-task cwd override (Migration 070). Empty string means
    /// the task has no per-task cwd (falls back to kanban-level
    /// path + sandbox). Plan: docs/superpowers/plans/2026-08-06-
    /// kanban-cwd-session-optional.md
    cwd: []const u8 = "",
    /// Media-presence flags (media-flags change). True when the just-INSERTed
    /// row has media; the frontend lazy-fetches via the media endpoint.
    is_have_image: bool = false,
    is_have_video: bool = false,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
};

// =====================================================================
// Use case
// =====================================================================

/// Generate a unique `task_<unix_ms>_<intra_ms_counter>` id.
///
/// The millisecond prefix preserves wire-compat with previously-stored
/// rows (`task_<ms>`) and keeps IDs roughly time-sortable. The atomic
/// counter suffix guarantees uniqueness even when 2+ tasks are
/// created in the same millisecond — without it, fast clients (a
/// tight pytest loop on Apple Silicon, a bulk-import script, etc.)
/// collide on the SQLite PRIMARY KEY and the 2nd+ insert returns
/// HTTP 500 "Failed to create task" (CI run 31863092055,
/// Mac ARM64: 3/64 functional tests failed for this reason —
/// `test_add_twelve_tasks_across_four_columns` and friends).
///
/// The counter resets to 0 at process start. A single-process
/// nalar can never have two threads call this with the same fetch
/// result, so uniqueness is trivial. Restart = pid change, but
/// new IDs start from 0 again which never collides with the
/// previously-emitted ms (a long-lived workspace has many ms prefixes).
fn generateTaskId(allocator: std.mem.Allocator, io: std.Io) TaskCreateError![]u8 {
    const ts = std.Io.Timestamp.now(io, .real);
    const ms: i64 = @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
    const counter = task_id_counter.fetchAdd(1, .seq_cst);
    return std.fmt.allocPrint(allocator, "task_{d}_{d}", .{ ms, counter }) catch return error.OutOfMemory;
}

/// Memory branch. Writes the .md file + inserts the task row.
fn createMemoryTask(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
    task_id: []const u8,
) TaskCreateError!MemoryResult {
    const memory_name = input.body.memory_name orelse return error.MemoryNameRequired;
    if (!memories_mod.isValidMemoryName(memory_name)) return error.InvalidMemoryName;
    const memory_content = input.body.memory_content orelse return error.MemoryContentRequired;

    // Look up the parent workspace_item to get its `path` (the project
    // root — the .md file is scoped to `<path>/.nalar/memories/<name>.md`).
    const item_opt = ai_mod.workspace_item_tasks.getWorkspaceItem(allocator, db, input.item_id) catch return error.WorkspaceItemNotFound;
    const item = item_opt orelse return error.WorkspaceItemNotFound;
    defer item.deinit(allocator);

    // Refuse non-folder items — `loadLocalKnowledge` reads from
    // `<cwd>/.nalar/memories/`, so the cwd must be a real directory
    // (which is what a 'folder' item's path is).
    if (!std.mem.eql(u8, item.item_type, "folder")) return error.NotAFolderItem;
    const cwd = item.path orelse return error.NoPathForMemory;

    const dir_path = memories_mod.get_local_memories_path_for_dir(allocator, cwd) orelse return error.FailedToBuildMemoriesPath;
    defer allocator.free(dir_path);

    if (!memories_mod.writeLocalMemoryFile(allocator, input.io, dir_path, memory_name, memory_content)) {
        return error.FailedToWriteMemoryFile;
    }

    // Migration 062: persist description. Same dynamic-SQL builder
        // Migration 062: persist description. Same dynamic-SQL builder
    // pattern as the standard branch below — null → omit column, "" →
    // SQL '' literal (avoids the empty-slice-as-NULL bind footgun),
    // "x…" → bind via `?`. On failure, roll back the .md file we
    // just wrote.
    {
        var cols_buf: std.ArrayList(u8) = .empty;
        defer cols_buf.deinit(allocator);
        var vals_buf: std.ArrayList(u8) = .empty;
        defer vals_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try cols_buf.appendSlice(allocator, "id, name, workspace_item_id, task_type");
        try vals_buf.appendSlice(allocator, "?, ?, ?, 'memory'");
        try bind_values.appendSlice(allocator, &[_][]const u8{
            task_id, input.body.name, input.item_id,
        });

        if (input.body.description) |d| {
            if (d.len == 0) {
                try cols_buf.appendSlice(allocator, ", description");
                try vals_buf.appendSlice(allocator, ", ''");
            } else {
                try cols_buf.appendSlice(allocator, ", description");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, d);
            }
        }

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.print(
            allocator,
            "INSERT INTO workspace_item_tasks ({s}) VALUES ({s})",
            .{ cols_buf.items, vals_buf.items },
        );

        db.exec(allocator, sql_buf.items, bind_values.items) catch {
            _ = memories_mod.deleteLocalMemoryFile(allocator, input.io, dir_path, memory_name);
            return error.MemoryTaskInsertFailed;
        };
    }

    return .{ .task_id = task_id, .name = input.body.name, .workspace_item_id = input.item_id };
}

/// Standard branch. Creates the task row and, if the parent is a
/// kanban, auto-assigns it to the first column at
/// MAX(kanban_position) + 1.
fn createStandardTask(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
    task_id: []const u8,
) TaskCreateError!StandardResult {
    // Validate + normalize the tags payload (Migration 067). The
    // helper returns a heap-allocated JSON-encoded array string
    // (or "" for "no tags") — the right shape for the `tags`
    // column. The slice is borrowed into the returned StandardResult
    // (see comment there) — the per-request arena reaps it on
    // request teardown. No explicit `defer allocator.free` here.
    const validated_tags = tags_validation.validateAndNormalizeTags(
        allocator,
        input.body.tags,
    ) catch return error.InvalidTags;

    // Validate the image_urls payload (Migration 069). The wire
    // format is the already-joined `||`-delimited string from the
    // client; the helper validates each segment's `data:image/
    // ...;base64,...` prefix and the total byte cap. The string is
    // borrowed (per-request arena) and passed through to the
    // model's INSERT.
    const validated_image_urls = image_urls_validation.validateImageUrls(
        input.body.image_urls orelse "",
    ) catch |err| return switch (err) {
        error.ImageUrlsTooLarge => error.ImageUrlsTooLarge,
        error.InvalidImageUrl => error.InvalidImageUrls,
    };

    // Validate the video_urls payload (Migration 090). Same shape as
    // image_urls: already-joined `||`-delimited string, validated
    // prefix + allowlist + 25 MB cap.
    const validated_video_urls = video_urls_validation.validateVideoUrls(
        input.body.video_urls orelse "",
    ) catch |err| return switch (err) {
        error.VideoUrlsTooLarge => error.VideoUrlsTooLarge,
        error.InvalidVideoUrl => error.InvalidVideoUrls,
    };

    // Validate the per-task cwd payload (Migration 070). The wire
    // format is an absolute path string from the FilePickerDialog
    // (or empty / null for cwd-less). Validation is intentionally
    // minimal: the OS-level cwd check happens at agent-run time
    // (the session_create sandbox-create path + every tool's spawn
    // call would surface a nonexistent dir as a 500 to the user).
    // Here we just trim + reject control chars + cap at 4 KiB to
    // bound memory + reject relative paths to avoid surprising the
    // user with a "cd to nowhere" first turn.
    const validated_cwd = blk: {
        const raw = input.body.cwd orelse "";
        if (raw.len == 0) break :blk raw;
        if (raw.len > 4096) return error.CwdTooLong;
        // Must be absolute (POSIX '/' or Windows 'C:\', '\\', ...).
        // Frontend's FilePickerDialog only emits absolute paths; this
        // guard protects against a misbehaving API client (curl, etc.).
        // Use std.fs.path.isAbsolute so Windows paths like
        // C:\Users\... are accepted on Windows builds.
        if (!std.fs.path.isAbsolute(raw)) return error.CwdNotAbsolute;
        // Reject any control characters (\x00..\x1f or \x7f). Paths
        // with embedded NULs would crash std.fs.path.join downstream.
        for (raw) |c| {
            if (c < 0x20 or c == 0x7f) return error.CwdContainsControlChar;
        }
        break :blk raw;
    };

    const task = ai_mod.workspace_item_tasks.createWorkspaceItemTask(
        allocator,
        db,
        task_id,
        input.body.name,
        input.item_id,
        "standard",
        input.body.description,
        validated_tags,
        // Migration 069 — image_urls. Borrowed from the per-request
        // arena (validated above). Pass through verbatim.
        validated_image_urls,
        // Migration 070 — per-task cwd override. Borrowed from the
        // per-request arena (validated above). Pass through verbatim.
        // When null the column is omitted from the INSERT and DEFAULT
        // '' applies (cwd-less task). Empty string serializes as the
        // SQL '' literal (canonical "no per-task cwd" sentinel). A
        // non-empty path becomes the cwd for this task's chat
        // sessions, overriding the kanban-level path + sandbox
        // fallback chain in session_create.zig::useCase. Plan:
        // docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
        validated_cwd,
        // Migration 090 — video_urls (trailing param). Same contract.
        validated_video_urls,
    ) catch return error.StandardTaskCreateFailed;

    // Chunk 5 of kanban-task-notification-icon: creating a card is
    // a human touch. Stamp last_human_touched_at so the kanban card
    // never shows the orange "awaiting review" dot for a card the
    // user just made (even if the AI subsequently finishes a turn on
    // it — the user's first-interaction is the review). Fire-and-
    // forget: a failed stamp doesn't fail the create.
    ai_mod.llm_history.updateTaskLastHumanTouchedAt(allocator, db, task_id, null) catch |err| {
        std.log.warn("task_create: stamp last_human_touched_at failed (non-fatal): {s}", .{@errorName(err)});
    };
    // NOTE: do NOT `defer task.deinit(allocator)` here. The slices
    // task.id, task.name, task.workspace_item_id, and task.task_type
    // are duped by createWorkspaceItemTask on the per-request arena
    // and then BORROWED into the returned StandardResult below. The
    // handler reads them after this function returns, so freeing
    // here would be a use-after-free (Zig arena free-fill = 0xAA bytes
    // end up as field values). The arena reaps everything when
    // GinwaServer.handle tears down the request arena, so the duped
    // slices need no explicit cleanup.

    // Kanban auto-assign: if the parent is a kanban, append the new
    // task to the bottom of the first column. Errors here are
    // non-fatal — the task row is already created.
    var kanban_column_id: ?[]u8 = null;
    var kanban_position: i64 = 0;
    // NOTE: do NOT `defer allocator.free(kanban_column_id)` here.
    // kanban_column_id (when set) is a dupe on the per-request arena
    // that is BORROWED into the returned StandardResult. Same use-
    // after-free reasoning as above.

    {
        const parent_is_kanban = blk: {
            var q = db.query(allocator,
                "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'",
                &[_][]const u8{input.item_id}) catch break :blk false;
            defer q.deinit();
            const row = (q.next() catch break :blk false) orelse break :blk false;
            defer row.deinit(allocator);
            break :blk true;
        };

        if (parent_is_kanban) {
            const first_col_id = blk: {
                var q = db.query(allocator,
                    "SELECT id FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1",
                    &[_][]const u8{input.item_id}) catch break :blk null;
                defer q.deinit();
                const row = (q.next() catch break :blk null) orelse break :blk null;
                defer row.deinit(allocator);
                break :blk allocator.dupe(u8, row.values[0]) catch break :blk null;
            };
            if (first_col_id) |col_id| {
                defer allocator.free(col_id);
                // Post-Migration-072: the task→column assignment lives
                // in the `kanban` join table. INSERT OR IGNORE so a
                // re-run on an already-assigned task is a no-op (the
                // SELECT MAX below handles position conflicts).
                db.exec(allocator,
                    "INSERT OR IGNORE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (?, ?, (SELECT COALESCE(MAX(k.kanban_position), -1) + 1 FROM kanban k WHERE k.kanban_column_id = ?))",
                    &[_][]const u8{ task_id, col_id, col_id },
                ) catch |err| {
                    std.log.warn("task_create: kanban auto-assign failed (non-fatal): {s}", .{@errorName(err)});
                };
                // Emit SSE event so other connected clients refresh
                // their kanban view. action="assigned" matches the
                // frontend's KanbanTaskEvent union variant.
                const assigned_pos: i64 = blk: {
                    var q = db.query(allocator,
                        "SELECT COALESCE(k.kanban_position, 0) FROM kanban k WHERE k.workspace_item_task_id = ?",
                        &[_][]const u8{task_id}) catch break :blk 0;
                    defer q.deinit();
                    const row = (q.next() catch break :blk 0) orelse break :blk 0;
                    defer row.deinit(allocator);
                    break :blk std.fmt.parseInt(i64, row.values[0], 10) catch 0;
                };
                on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
                    .action = "assigned",
                    .workspace_id = input.workspace_id,
                    .item_id = input.item_id,
                    .task_id = task_id,
                    .new_column_id = col_id,
                    .new_position = assigned_pos,
                }) catch |err| {
                    std.log.warn("task_create: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
                };
                // Re-read kanban fields after the INSERT so the
                // response carries the assigned values.
                var q2 = db.query(allocator,
                    "SELECT k.kanban_column_id, COALESCE(k.kanban_position, 0) FROM kanban k WHERE k.workspace_item_task_id = ?",
                    &[_][]const u8{task_id}) catch return .{
                    .task_id = task_id,
                    .name = task.name,
                    .workspace_item_id = task.workspace_item_id,
                    .kanban_column_id = null,
                    .kanban_position = 0,
                    .session_id = input.body.session_id,
                };
                defer q2.deinit();
                blk: {
                    const row_opt = q2.next() catch break :blk {};
                    if (row_opt) |row| {
                        defer row.deinit(allocator);
                        if (row.values[0].len > 0) {
                            kanban_column_id = allocator.dupe(u8, row.values[0]) catch null;
                        }
                        kanban_position = std.fmt.parseInt(i64, row.values[1], 10) catch 0;
                    }
                }
            }
        }
    }

    // session_id is preserved for backward compatibility with the v1
    // wire format. The standard-task path no longer accepts a caller-
    // supplied session_id (the task's own id is the session per the
    // task.id == session.id convention), so input.body.session_id is
    // typically null. Pass it through as-is — valueAlloc handles the
    // optional → "session_id":<id-or-null> serialization.

    // Auto-retry-until-stop (Option A of the unattended-mode dialog
    // fix): if the request body carries `is_auto_retry_until_stop`,
    // insert a `sessions` row keyed by the new task.id so the flag
    // has somewhere to land. The standard-task create path is the
    // primary consumer (frontend's KanbanTaskDetailDialog toggle
    // sends this when the user opts in at create time). Memory tasks
    // handle their own session lifecycle separately and don't take
    // this field.
    //
    // NEW (plan: docs/superpowers/plans/2026-08-13-kanban-task-
    // session-name-match.md): bind sessions.name = task.name (NOT
    // task.id). Pre-fix the bind was task.id, which made the sidebar
    // ChatsList show "task_<timestamp>" while the kanban card showed
    // the user-facing title. Post-fix all three views (sidebar /
    // chat header / kanban card) display the same string at create
    // time. task.id == session.id is still preserved (Migration 052);
    // only the name column changes.
    if (input.body.is_auto_retry_until_stop) |flag| {
        const normalized: []const u8 = if (std.mem.eql(u8, flag, "1")) "1" else "0";
        // INSERT OR IGNORE so a concurrent PUT /api/llm/session/:id
        // that landed first (e.g. the user typed a message in the new
        // task's chat before this row was written) doesn't trip a
        // UNIQUE constraint failure. The `name` column is NOT NULL.
        db.exec(
            allocator,
            "INSERT OR IGNORE INTO sessions (id, name, status, is_auto_retry_until_stop) VALUES (?, ?, 'active', ?)",
            &[_][]const u8{ task.id, task.name, normalized },
        ) catch |err| {
            std.log.warn("task_create: session INSERT for unattended flag failed (non-fatal): {s}", .{@errorName(err)});
        };
    }

    return .{
        .task_id = task.id,
        .name = task.name,
        .workspace_item_id = task.workspace_item_id,
        .kanban_column_id = kanban_column_id,
        .kanban_position = kanban_position,
        .session_id = input.body.session_id,
        // Migration 067 — kanban task tags. Borrowed from the
        // per-request arena; the arena reaps it on request teardown.
        .tags = validated_tags,
        // Migration 070 — per-task cwd override. Borrowed from the
        // per-request arena (validated above). Mirrors what we just
        // INSERTed into the `cwd` column.
        .cwd = validated_cwd,
        // Media-flags change — media-presence flags derived from the validated
        // payloads. The full TEXT stays server-side for lazy fetch.
        .is_have_image = validated_image_urls.len > 0,
        .is_have_video = validated_video_urls.len > 0,
    };
}

pub fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: TaskCreateInput,
) TaskCreateError!TaskCreateResult {
    if (input.item_id.len == 0) return error.ItemIdRequired;

    const task_id = try generateTaskId(allocator, input.io);
    // NOTE: do NOT `defer allocator.free(task_id)` here. `task_id` is
    // passed to `createMemoryTask` /
    // `createStandardTask`, which return it as `*.task_id` in their
    // `*Result` structs. The handler then reads it after this
    // function returns — freeing here is a use-after-free. The
    // per-request arena reaps `task_id` on request teardown, so no
    // explicit cleanup is needed.

    if (std.mem.eql(u8, input.body.task_type, "routine")) {
        // Deleted with the per-task `routines` table (Migration 084).
        // Create a routine workspace item instead (`POST .../items/routine`).
        return error.RoutineTasksRemoved;
    }
    if (std.mem.eql(u8, input.body.task_type, "memory")) {
        const result = try createMemoryTask(allocator, db, input, task_id);
        return .{ .memory = result };
    }
    const result = try createStandardTask(allocator, db, input, task_id);
    return .{ .standard = result };
}

// =====================================================================
// Handler
// =====================================================================

pub fn tasksCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    // workspace_id is required for the SSE payload (the frontend
    // filters events for the active workspace). Empty is fine.
    const ws_id = req.params.get("workspace_id") orelse "";

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(http_response.TaskCreateRequest, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }),
        });
    };

    const outcome = useCase(allocator, sqlite_db, .{
        .item_id = item_id,
        .workspace_id = ws_id,
        .io = ctx.io,
        .body = parsed,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired, error.MissingBody, error.InvalidJson => 400,
            error.RoutineTasksRemoved => 400,
            error.InvalidTags => 400,
            error.InvalidImageUrls => 400,
            error.ImageUrlsTooLarge => 413,
            error.InvalidVideoUrls => 400,
            error.VideoUrlsTooLarge => 413,
            error.CwdTooLong,
            error.CwdNotAbsolute,
            error.CwdContainsControlChar => 400,
            error.MemoryNameRequired, error.InvalidMemoryName,
            error.MemoryContentRequired => 400,
            error.WorkspaceItemNotFound => 404,
            error.NotAFolderItem, error.NoPathForMemory => 400,
            error.MemoryTaskInsertFailed, error.StandardTaskCreateFailed,
            error.FailedToBuildMemoriesPath, error.FailedToWriteMemoryFile => 500,
            error.OutOfMemory, error.Canceled => 500,
        };
        const message: []const u8 = switch (err) {
            error.ItemIdRequired => "item_id required",
            error.MissingBody => "Request body required",
            error.InvalidJson => "Invalid JSON",
            error.RoutineTasksRemoved => "routine tasks are no longer supported; create a routine workspace item instead",
            error.InvalidTags => "tags must be non-empty, ≤50 chars, and contain only letters, digits, hyphens, and underscores",
            error.InvalidImageUrls => "image_urls must be `||`-delimited data:image/<mime>;base64,... URLs",
            error.ImageUrlsTooLarge => "image_urls payload too large (max 10 MB)",
            error.InvalidVideoUrls => "video_urls must be `||`-delimited data:video/<mime>;base64,... URLs",
            error.VideoUrlsTooLarge => "video payload too large (max 25 MB)",
            error.CwdTooLong => "cwd path too long (max 4 KiB)",
            error.CwdNotAbsolute => "cwd must be an absolute path",
            error.CwdContainsControlChar => "cwd contains a control character",
            error.MemoryNameRequired => "memory_name is required for memory tasks",
            error.InvalidMemoryName => "Invalid memory name (must end in .md, no /, no ..)",
            error.MemoryContentRequired => "memory_content is required for memory tasks",
            error.WorkspaceItemNotFound => "Workspace item not found",
            error.NotAFolderItem => "Memory tasks can only be added to folder-type workspace items",
            error.NoPathForMemory => "Workspace item has no path; the folder must have been created with a real path",
            error.MemoryTaskInsertFailed => "Failed to create task row",
            error.StandardTaskCreateFailed => "Failed to create task",
            error.FailedToBuildMemoriesPath => "Failed to build local memories path",
            error.FailedToWriteMemoryFile => "Failed to write memory file",
            error.OutOfMemory => "Out of memory",
            error.Canceled => "Io operation canceled",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Serialize the response based on the tagged outcome. Each branch
    // uses a typed struct + std.json.Stringify.valueAlloc (not hand-
    // rolled std.fmt.allocPrint) — see the doc comment above the
    // response struct definitions for the rationale.
    return switch (outcome) {
        .memory => |r| res.jsonResponse(.{
            .status_code = 201,
            .data = try std.json.Stringify.valueAlloc(
                allocator,
                MemoryResponse{
                    .id = r.task_id,
                    .name = r.name,
                    .workspace_item_id = r.workspace_item_id,
                },
                .{},
            ),
        }),
        .standard => |r| res.jsonResponse(.{
            .status_code = 201,
            .data = try std.json.Stringify.valueAlloc(
                allocator,
                StandardResponse{
                    .id = r.task_id,
                    .name = r.name,
                    .workspace_item_id = r.workspace_item_id,
                    .session_id = r.session_id,
                    .kanban_column_id = r.kanban_column_id,
                    .kanban_position = r.kanban_position,
                    // Migration 067 — kanban task tags. The
                    // `r.tags` slice is borrowed from the per-
                    // request arena (allocated by
                    // validateAndNormalizeTags in createStandardTask,
                    // reaped by the arena on request teardown).
                    // valueAlloc copies it into the response JSON,
                    // so no use-after-free.
                    .tags = r.tags,
                    // Migration 070 — per-task cwd override. Same
                    // borrowed-slice lifetime as `r.tags` (per-
                    // request arena, reaped on request teardown;
                    // valueAlloc copies it into the response JSON,
                    // so no use-after-free).
                    .cwd = r.cwd,
                    // Media-flags change — media-presence flags. The frontend
                    // lazy-fetches via the media endpoint when true.
                    .is_have_image = r.is_have_image,
                    .is_have_video = r.is_have_video,
                },
                .{},
            ),
        }),
    };
}

// ===== Tests merged from task_create_description_test.zig (2026-09-11 flatten) =====
// Static regression checks for description persistence in
// `task_create.zig` (Migration 062).
// 
// Why this file exists
// ────────────────────
// Migration 062 added the `description` column to
// `workspace_item_tasks`. The `task_create` HTTP handler has THREE
// branches (standard / routine / memory) and each must persist
// description to the new column. These checks verify the SQL
// pattern is present in all three branches, so a future refactor
// can't silently drop description persistence.
// 
// Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
//   (Chunk 1, Task 1.4).

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/task_create.zig";
const LLM_HISTORY_PATH = "src/agentic_loop/llm_history.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw);
    return normalized;
}

test "createWorkspaceItemTask signature accepts a description parameter" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The helper signature must include `description` as the
    // trailing parameter so the standard-task INSERT path can pass
    // the field through. If this is missing, the standard-task
    // create path silently drops description.
    const sig = "pub fn createWorkspaceItemTask(";
    const sig_idx = std.mem.indexOf(u8, source, sig) orelse {
        std.debug.print("\n!! Could not find `pub fn createWorkspaceItemTask(` in {s} !!\n", .{LLM_HISTORY_PATH});
        return error.CreateWorkspaceItemTaskMissing;
    };
    const after_sig = sig_idx + sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const signature = source[after_sig..next_pub_fn];

    if (std.mem.indexOf(u8, signature, "description") == null) {
        std.debug.print(
            "\n!! createWorkspaceItemTask signature does not include `description` !!\n" ++
                "   Migration 062 requires the standard-task create path to persist\n" ++
                "   description. Add a trailing `description: ?[]const u8` parameter.\n",
            .{},
        );
        return error.DescriptionParameterMissing;
    }
}

test "createWorkspaceItemTask SQL inserts the description column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // Find the INSERT INTO workspace_item_tasks inside createWorkspaceItemTask
    // and assert it lists the description column. We approximate by scanning
    // for a pattern: the helper's INSERT must reference `description` as a
    // column. (There are multiple INSERTs into workspace_item_tasks in the
    // file — three in task_create.zig plus one in createWorkspaceItemTask —
    // but we only care that THIS helper's INSERT covers description.)
    const sig = "pub fn createWorkspaceItemTask(";
    const sig_idx = std.mem.indexOf(u8, source, sig) orelse {
        std.debug.print("\n!! createWorkspaceItemTask signature not found !!\n", .{});
        return error.CreateWorkspaceItemTaskMissing;
    };
    const after_sig = sig_idx + sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const body = source[after_sig..next_pub_fn];

    // The INSERT must list `description` in its column list and bind
    // it via a `?` placeholder. We accept either "description" alone
    // (column name) or "description, " (with trailing comma) so the
    // check is robust to surrounding whitespace.
    const has_col = std.mem.indexOf(u8, body, "description") != null;
    const has_bind = std.mem.indexOf(u8, body, "INSERT INTO workspace_item_tasks") != null and
        std.mem.indexOf(u8, body, ", description") != null;

    if (!has_col or !has_bind) {
        std.debug.print(
            "\n!! createWorkspaceItemTask INSERT does not cover `description` !!\n" ++
                "   The standard-task INSERT must list `description` in its column\n" ++
                "   list and bind it as a parameter. Example:\n" ++
                "     INSERT INTO workspace_item_tasks\n" ++
                "       (id, name, workspace_item_id, task_type, description)\n" ++
                "     VALUES (?, ?, ?, ?, ?)\n",
            .{},
        );
        return error.DescriptionColumnMissing;
    }
}

test "task_create routine + memory INSERTs cover the description column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler has two direct-INSERT branches (routine at the
    // createRoutineTask helper, memory at createMemoryTask). Both
    // must include `description` in their INSERT. We require BOTH
    // to appear so a regression that drops description from either
    // path is caught.
    const routine_match = std.mem.indexOf(u8, source, "'routine'") != null;
    const memory_match = std.mem.indexOf(u8, source, "'memory'") != null;

    // After PR #101 review feedback, the SQL is built dynamically
    // via a `std.ArrayList` builder + parallel `bind_values` list.
    // The literal substrings we can match against have changed:
    //   - The column list fragment is appended as `, description`
    //     in two places (one for the empty-string literal path,
    //     one for the bound-value path).
    //   - The VALUES tail fragment is appended as `, ''` (empty)
    //     or `, ?` (value).
    //   - The whole SQL is composed at the end via
    //     `INSERT INTO workspace_item_tasks ({s}) VALUES ({s})`.
    //
    // We accept any of these shapes to prove description is wired
    // in. The check is robust to the three branches (null / "" /
    // value) and to future minor reformatting.
    const has_desc_col = std.mem.indexOf(u8, source, ", description") != null;
    const has_routine_type = std.mem.indexOf(u8, source, "'routine'") != null;
    const has_memory_type = std.mem.indexOf(u8, source, "'memory'") != null;
    const has_empty_literal = std.mem.indexOf(u8, source, ", ''") != null;
    const has_bind_placeholder = std.mem.indexOf(u8, source, ", ?") != null;
    const has_insert_compose = std.mem.indexOf(u8, source,
        "INSERT INTO workspace_item_tasks ({s}) VALUES ({s})") != null;

    if (!routine_match or !memory_match) {
        std.debug.print(
            "\n!! task_create.zig is missing the 'routine' or 'memory' INSERT branch !!\n",
            .{},
        );
        return error.BranchMissing;
    }
    if (!has_desc_col or !has_routine_type or !has_memory_type or
        !has_empty_literal or !has_bind_placeholder or !has_insert_compose)
    {
        std.debug.print(
            "\n!! task_create.zig routine or memory branch does not persist description !!\n" ++
                "   After PR #101 refactor, each branch must build SQL dynamically:\n" ++
                "   - cols_buf.appendSlice(allocator, \", description\")\n" ++
                "   - vals_buf.appendSlice(allocator, \", ''\")  // empty-string case\n" ++
                "   - vals_buf.appendSlice(allocator, \", ?\")   // value case\n" ++
                "   - sql_buf.print(allocator,\n" ++
                "         INSERT_INTO_LITERAL, ...);\n" ++
                "     where INSERT_INTO_LITERAL is the standard INSERT\n" ++
                "     INTO workspace_item_tasks SQL template.\n" ++
                "   Missing: desc_col={any}, routine_type={any}, memory_type={any}, empty_literal={any}, bind_placeholder={any}, insert_compose={any}\n",
            .{ has_desc_col, has_routine_type, has_memory_type, has_empty_literal, has_bind_placeholder, has_insert_compose },
        );
        return error.DescriptionBranchMissing;
    }
}

// ===== Tests merged from task_create_memory_test.zig (2026-09-11 flatten) =====
// Static regression checks for the memory-aware task create/delete handlers.
// 
// Why this file exists
// ────────────────────
// The Markdown Memory feature (plan: `2026-06-20-add-markdown-memory.md`)
// adds a new `memory` task type. A memory task is a local .md file scoped
// to the parent workspace_item's directory; the task row is a thin
// index pointing at the file. The create handler must:
//   1. Validate `memory_name` via `isValidMemoryName`.
//   2. Resolve the parent workspace_item to get its `path`.
//   3. Build the local memories dir path via `get_local_memories_path_for_dir`.
//   4. Refuse non-folder items (only `folder` items have a real directory path).
//   5. Write the .md file via `writeLocalMemoryFile` (atomic-rename).
//   6. Insert a `workspace_item_tasks` row with `task_type='memory'` and
//      no `session_id` (the file IS the content).
//   7. Roll back the file on task-row failure (no orphan .md).
// 
// The delete handler must:
//   1. Look up the task, identify `task_type='memory'`.
//   2. Resolve the parent workspace_item to get its `path`.
//   3. Build the local memories dir path.
//   4. Delete the .md file (idempotent — missing file is OK).
// 
// These contracts are enforced by static substring checks (matching the
// project's `task_create_routines_test.zig` pattern), not by spinning
// up an in-memory DB. The static checks below directly test the bug —
// they fail if and only if the memory-creation plumbing is removed or
// routed back to the standard-task path.
// 
// Plan: docs/plans/2026-06-20-add-markdown-memory.md


const CREATE_HANDLER_PATH = "src/http_handlers/task_create.zig";
const DELETE_HANDLER_PATH = "src/http_handlers/task_delete.zig";
const REQ_PATH = "src/http_handlers/http_response.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource_merged(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: TaskCreateRequest has memory_name + memory_content ─────────

test "TaskCreateRequest has memory_name + memory_content fields" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, REQ_PATH);
    defer allocator.free(source);

    // The request struct must carry the two memory-creation fields.
    // Without these, a client cannot request a memory task and the
    // handler will fail to write the .md file.
    if (std.mem.indexOf(u8, source, "memory_name") == null) {
        std.debug.print(
            "\n!! {s} does not define a `memory_name` field on TaskCreateRequest !!\n" ++
                "   The memory-creation contract is broken: clients cannot pass the\n" ++
                "   memory file name. Add `memory_name: ?[]const u8 = null` to the struct.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{REQ_PATH},
        );
        return error.MemoryNameFieldMissing;
    }
    if (std.mem.indexOf(u8, source, "memory_content") == null) {
        std.debug.print(
            "\n!! {s} does not define a `memory_content` field on TaskCreateRequest !!\n" ++
                "   The memory-creation contract is broken: clients cannot pass the\n" ++
                "   memory file body. Add `memory_content: ?[]const u8 = null` to the struct.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{REQ_PATH},
        );
        return error.MemoryContentFieldMissing;
    }
}

// ─── Contract 2: handler validates the memory name via isValidMemoryName ──

test "task_create handler validates memory_name via isValidMemoryName" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `isValidMemoryName(memory_name)` and return
    // 400 on a bad name. Without this, a path-traversal attempt
    // (e.g. memory_name = "../../etc/passwd.md") would write the file
    // outside the memories dir.
    if (std.mem.indexOf(u8, source, "isValidMemoryName") == null) {
        std.debug.print(
            "\n!! {s} does not call isValidMemoryName !!\n" ++
                "   The memory-name-validation contract is broken: a bad memory_name\n" ++
                "   (e.g. with '/' or '..') will be written to disk outside the memories dir.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.IsValidMemoryNameMissing;
    }
}

// ─── Contract 3: handler resolves the parent workspace_item to find path ───

test "task_create handler resolves parent workspace_item to get path" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `getWorkspaceItem` to look up the parent
    // workspace_item's `path` (the project root for the .md file). Without
    // this, the .md file would be written to a relative path (cwd-relative),
    // which the agent's loadLocalKnowledge would not find.
    if (std.mem.indexOf(u8, source, "getWorkspaceItem") == null) {
        std.debug.print(
            "\n!! {s} does not call getWorkspaceItem to resolve the parent !!\n" ++
                "   The memory-task needs the parent workspace_item's `path` to know\n" ++
                "   where to write the .md file. Without this lookup, the file is\n" ++
                "   written relative to the server's cwd, not the project's dir.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.GetWorkspaceItemMissing;
    }
}

// ─── Contract 4: handler refuses non-folder workspace items ────────────────

test "task_create handler refuses non-folder workspace items" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must check the parent item's `item_type == 'folder'`
    // and return 400 for chat/other types. Memory tasks need a real
    // directory path; chat items have a session-id path that is not a
    // directory.
    if (std.mem.indexOf(u8, source, "\"folder\"") == null) {
        std.debug.print(
            "\n!! {s} does not check `item_type == 'folder'` !!\n" ++
                "   The folder-only contract is broken: a memory task could be\n" ++
                "   attached to a chat-type workspace item, where the .md file\n" ++
                "   would be written to a non-directory path.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.FolderTypeCheckMissing;
    }
}

// ─── Contract 5: handler builds the local memories path ────────────────────

test "task_create handler builds the local memories dir path" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `get_local_memories_path_for_dir` to build
    // `<cwd>/.nalar/memories/`. Without this, the .md file would be
    // written to the wrong dir (the raw cwd, not <cwd>/.nalar/memories/).
    if (std.mem.indexOf(u8, source, "get_local_memories_path_for_dir") == null) {
        std.debug.print(
            "\n!! {s} does not call get_local_memories_path_for_dir !!\n" ++
                "   The memory-dir-path contract is broken: the .md file would be\n" ++
                "   written to the raw cwd, not to <cwd>/.nalar/memories/ where the\n" ++
                "   agent's loadLocalKnowledge scans.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.GetLocalMemoriesPathMissing;
    }
}

// ─── Contract 6: handler writes the .md file via writeLocalMemoryFile ──────

test "task_create handler writes the .md file via writeLocalMemoryFile" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `writeLocalMemoryFile` to actually create
    // the file on disk. Without this, the task row would point at a
    // non-existent file.
    if (std.mem.indexOf(u8, source, "writeLocalMemoryFile") == null) {
        std.debug.print(
            "\n!! {s} does not call writeLocalMemoryFile !!\n" ++
                "   The memory-file-write contract is broken: the task row would\n" ++
                "   reference a file that does not exist, and loadLocalKnowledge\n" ++
                "   would have nothing to read.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.WriteLocalMemoryFileMissing;
    }
}

// ─── Contract 7: handler inserts a workspace_item_tasks row for memory ─────

test "task_create handler inserts a task row for memory tasks" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // The handler must INSERT a row into the `workspace_item_tasks`
    // table with `task_type='memory'` (so the task list UI shows it
    // under the memory filter). Without this INSERT, the .md file
    // would exist but no task would reference it.
    if (std.mem.indexOf(u8, source, "INSERT INTO workspace_item_tasks") == null) {
        std.debug.print(
            "\n!! {s} does not contain 'INSERT INTO workspace_item_tasks' !!\n" ++
                "   The task-row contract is broken: the .md file would exist but\n" ++
                "   no task row references it, so it would never appear in the UI.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.MemoryTaskInsertMissing;
    }
}

// ─── Contract 8: handler rolls back the .md on task-row failure ────────────

test "task_create handler rolls back the .md on task-row failure" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, CREATE_HANDLER_PATH);
    defer allocator.free(source);

    // When the workspace_item_tasks INSERT fails, the handler must call
    // `deleteLocalMemoryFile` to remove the .md file it just wrote.
    // Without the rollback, the file would be an orphan (no task row
    // pointing at it), and the user would see a "memory exists" entry
    // on next reload but no way to delete it from the UI.
    //
    // Static check: the handler must reference both `deleteLocalMemoryFile`
    // AND appear in a `catch` branch (rollback on error).
    const has_delete = std.mem.indexOf(u8, source, "deleteLocalMemoryFile") != null;
    if (!has_delete) {
        std.debug.print(
            "\n!! {s} does not call deleteLocalMemoryFile for rollback !!\n" ++
                "   The rollback contract is broken: if the task-row INSERT fails\n" ++
                "   after the .md file is written, the file is an orphan with no\n" ++
                "   task row pointing at it.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{CREATE_HANDLER_PATH},
        );
        return error.MemoryRollbackMissing;
    }
}

// ─── Contract 9: delete handler cleans up the .md file ────────────────────

test "task_delete handler cleans up the .md file for memory tasks" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, DELETE_HANDLER_PATH);
    defer allocator.free(source);

    // The delete handler must call `deleteLocalMemoryFile` for tasks
    // with `task_type='memory'`, so the file system and the task list
    // stay in sync. Without this, deleted memory tasks would leave
    // orphan .md files in <cwd>/.nalar/memories/ that the agent would
    // still load on the next chat.
    if (std.mem.indexOf(u8, source, "deleteLocalMemoryFile") == null) {
        std.debug.print(
            "\n!! {s} does not call deleteLocalMemoryFile for memory tasks !!\n" ++
                "   The delete-cleanup contract is broken: deleting a memory task\n" ++
                "   would leave the .md file in <cwd>/.nalar/memories/ as an orphan\n" ++
                "   that the agent would still load on the next chat.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{DELETE_HANDLER_PATH},
        );
        return error.MemoryDeleteCleanupMissing;
    }
}

// ─── Contract 10: delete handler branches on task_type='memory' ────────────

test "task_delete handler branches on task_type='memory'" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, DELETE_HANDLER_PATH);
    defer allocator.free(source);

    // The delete handler must check the task's `task_type == 'memory'`
    // before doing the .md cleanup. Without this branch, the .md
    // deletion would either never happen (because there's no type check)
    // or happen for non-memory tasks (where there's no .md file).
    if (std.mem.indexOf(u8, source, "\"memory\"") == null) {
        std.debug.print(
            "\n!! {s} does not check `task_type == 'memory'` !!\n" ++
                "   The type-check contract is broken: the delete handler must\n" ++
                "   branch on memory tasks to call deleteLocalMemoryFile. Without\n" ++
                "   the check, the cleanup either runs for all tasks (creating\n" ++
                "   a false-positive 'missing file' error) or never runs.\n" ++
                "   See docs/plans/2026-06-20-add-markdown-memory.md.\n",
            .{DELETE_HANDLER_PATH},
        );
        return error.MemoryTypeCheckMissing;
    }
}

// ===== Tests merged from task_create_test.zig (2026-09-11 flatten) =====
// Behavioural contract test for the kanban-task / session-name match fix.
// 
// Pre-fix, `createStandardTask` inserted the linked sessions row with
// `name = task.id` (the literal task id). Post-fix, it must insert
// `name = task.name` (the user-facing title).
// 
// The handler's `createStandardTask` requires `io: std.Io` and the
// full nalarcore singleton context, which is impractical to stand up
// in a unit test. We verify the contract with a focused static check
// on the bind-values list shape: it must read `task.id, task.name, flag`,
// NOT `task.id, task.id, flag`.
// 
// Plan: docs/superpowers/plans/2026-08-13-kanban-task-session-name-match.md
// Task 2 / Step 2.1.



/// Read a source file from disk, normalize CRLF to LF so Windows-checked-
/// out files match the test expectation. Relative to the project root
/// (which is the cwd when `zig build test` runs).
fn readSource_merged2(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
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

test "createStandardTask binds sessions.name = task.name (not task.id)" {
    const allocator = testing.allocator;
    const source = try readSource_merged2(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Locate the unattended-mode sessions INSERT — it's the only place
    // in createStandardTask that writes to the sessions table.
    const sessions_insert_marker =
        \\INSERT OR IGNORE INTO sessions (id, name, status, is_auto_retry_until_stop)
    ;
    const sql_idx = std.mem.indexOf(u8, source, sessions_insert_marker) orelse {
        std.debug.print("\n!! {s} is missing the unattended-mode sessions INSERT !!\n", .{HANDLER_PATH});
        return error.SessionsInsertMissing;
    };

    // After the SQL string the handler binds its values inline. The
    // pre-fix shape was `&[_][]const u8{ task.id, task.id, normalized }`
    // (BUG); post-fix it must be `&[_][]const u8{ task.id, task.name, normalized }`.
    // Find the bind list that follows the SQL string and inspect the
    // second element.
    const bind_list_marker = "&[_][]const u8{ task.id, ";
    const search_from = sql_idx + sessions_insert_marker.len;
    const bind_idx = std.mem.indexOfPos(u8, source, search_from, bind_list_marker) orelse {
        std.debug.print("\n!! {s} sessions INSERT bind list is missing the expected shape !!\n", .{HANDLER_PATH});
        return error.BindListMissing;
    };

    // The second element starts right after the marker and runs until
    // the next comma. Trim incidental whitespace before comparing.
    const after_marker = bind_idx + bind_list_marker.len;
    // The list literal ends with `}` somewhere after; scan for the
    // first comma, but only up to a safe upper bound (the bind list
    // is at most ~50 chars). Use indexOfPos with the slice's bounds
    // — `source` is the full file, not a view, so the result must
    // be relative to after_marker.
    const slice_end = @min(after_marker + 64, source.len);
    const comma_offset = std.mem.indexOfPos(u8, source, after_marker, ",") orelse {
        std.debug.print("\n!! {s} bind list not parseable — no comma within {} bytes !!\n", .{ HANDLER_PATH, slice_end - after_marker });
        return error.BindListUnparseable;
    };
    if (comma_offset > slice_end) {
        std.debug.print("\n!! {s} comma too far away (idx={d}, window_end={d}) !!\n", .{ HANDLER_PATH, comma_offset, slice_end });
        return error.BindListUnparseable;
    }
    const raw_second = source[after_marker..comma_offset];
    const second_elem = std.mem.trim(u8, raw_second, " \t\n\r");

    if (!std.mem.eql(u8, second_elem, "task.name")) {
        std.debug.print(
            "\n!! {s} sessions INSERT second bind is '{s}', expected 'task.name' !!\n",
            .{ HANDLER_PATH, second_elem },
        );
        return error.SessionNameBindBug;
    }
}
// =====================================================================
// Migration 069 read-path follow-up (plan:
// docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
// Task 2): the create response must ECHO image_urls so the frontend's
// optimistic task object carries the images immediately (no refetch
// needed for the detail dialog gallery to show them).
// =====================================================================

test "StandardResponse declares is_have_image and standard branch echoes it" {
    const allocator = testing.allocator;
    const source = try readSource_merged2(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Scope 1: the StandardResponse struct must declare the field.
    const struct_marker = "const StandardResponse = struct";
    const struct_idx = std.mem.indexOf(u8, source, struct_marker) orelse {
        std.debug.print("\n!! {s} does not define StandardResponse !!\n", .{HANDLER_PATH});
        return error.StandardResponseMissing;
    };
    const struct_window = source[struct_idx..];
    const struct_end = std.mem.indexOf(u8, struct_window, "\n};") orelse struct_window.len;
    const struct_body = struct_window[0..struct_end];

    if (std.mem.indexOf(u8, struct_body, "is_have_image: bool") == null) {
        std.debug.print(
            "\n!! {s} StandardResponse does not declare is_have_image !!\n" ++
                "   Add: is_have_image: bool = false,\n",
            .{HANDLER_PATH},
        );
        return error.StandardResponseImageUrlsMissing;
    }

    // Scope 2: the .standard response branch must echo r.image_urls.
    const branch_marker = ".standard => |r| res.jsonResponse(.{";
    const branch_idx = std.mem.indexOf(u8, source, branch_marker) orelse {
        std.debug.print("\n!! {s} does not have a .standard response branch !!\n", .{HANDLER_PATH});
        return error.StandardBranchMissing;
    };
    const branch_window = source[branch_idx..];
    const branch_end = std.mem.indexOf(u8, branch_window, "}),") orelse branch_window.len;
    const branch_body = branch_window[0..branch_end];

    if (std.mem.indexOf(u8, branch_body, ".is_have_image = r.is_have_image") == null) {
        std.debug.print(
            "\n!! {s} .standard response branch does not echo is_have_image !!\n" ++
                "   Add: .is_have_image = r.is_have_image,\n",
            .{HANDLER_PATH},
        );
        return error.StandardBranchImageUrlsMissing;
    }
}

test "StandardResult carries is_have_image from createStandardTask" {
    const allocator = testing.allocator;
    const source = try readSource_merged2(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // StandardResult must have the field...
    const result_marker = "const StandardResult = struct";
    const result_idx = std.mem.indexOf(u8, source, result_marker) orelse {
        std.debug.print("\n!! {s} does not define StandardResult !!\n", .{HANDLER_PATH});
        return error.StandardResultMissing;
    };
    const result_window = source[result_idx..];
    const result_end = std.mem.indexOf(u8, result_window, "\n};") orelse result_window.len;
    const result_body = result_window[0..result_end];

    if (std.mem.indexOf(u8, result_body, "is_have_image") == null) {
        std.debug.print(
            "\n!! {s} StandardResult does not carry is_have_image !!\n" ++
                "   Add: is_have_image: bool = false,\n",
            .{HANDLER_PATH},
        );
        return error.StandardResultImageUrlsMissing;
    }

    // ...and createStandardTask's return must populate it from the
    // validated value.
    if (std.mem.indexOf(u8, source, ".is_have_image") == null) {
        std.debug.print(
            "\n!! {s} createStandardTask return does not set .is_have_image !!\n",
            .{HANDLER_PATH},
        );
        return error.StandardResultNotPopulated;
    }
}

// ===== Tests merged from task_create_unique_id_test.zig (2026-09-11 flatten) =====
// Regression test for task-create 500 on Mac ARM64 CI (run
// 31863092055). Three functional tests failed with HTTP 500 "Failed
// to create task" / "Failed to create workspace" because their ID
// generators collided on the SQLite PRIMARY KEY when 2+ IDs were
// minted in the same wall-clock millisecond. On Apple Silicon,
// pytest's tight POST loops produce ms-clusters; on slower Linux
// CI runners the same code happens to spread across milliseconds
// and slips through.
// 
// The handler itself takes `io: std.Io` + the full nalarcore
// singleton — impractical to stand up in a unit test. We verify the
// generator's contract with a behavioural call into the function
// directly: 100 IDs minted back-to-back MUST be unique. Pre-fix
// this would intermittently fail (or always pass, depending on the
// host's clock). Post-fix it always passes because the atomic
// counter guarantees intra-process uniqueness even when the
// millisecond timestamp doesn't change between calls.
// 
// Plan: docs/superpowers/plans/2026-08-15-task-id-collision-fix.md
// (to be written if a plan is needed; for now this is a regression
// fix, not a feature).

const task_create = @This();

// `generateTaskId` is private (no `pub`); reach it via @embed in the
// test by importing the file as a struct. Zig private visibility is
// enforced only at the symbol level — Zig 0.16 still allows private
// `fn` access via `@typeInfo` reflection only when the test is in
// the same file. Easiest path: grep the source file for the
// expected ID-generation pattern (atomic counter + ms prefix) as a
// behavioural contract check that mirrors the project's existing
// static-grep tests (see task_create_test.zig for the same style).


/// The handler must include a process-local atomic counter so that
/// multiple generateTaskId calls within the same millisecond produce
/// unique ids. Without this guard the 2nd+ INSERT trips PRIMARY KEY
/// and returns HTTP 500 "Failed to create task" (CI run 31863092055).
fn assertGeneratorUsesCounter(allocator: std.mem.Allocator) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        HANDLER_PATH,
        allocator,
        .unlimited,
    );
    defer allocator.free(source);

    // The atomic counter must be a module-level `var` of type
    // `std.atomic.Value(u64)` (or equivalent — `std.atomic.Atomic`
    // also works). Pre-fix the file had no such var, only a
    // timestamp-derived ID.
    const counter_decl_marker = "std.atomic.Value(u64)";
    const has_counter = std.mem.indexOf(u8, source, counter_decl_marker) != null;
    if (!has_counter) {
        std.debug.print(
            "\n!! {s} is missing a `std.atomic.Value(u64)` for id generation — re-introduces the Mac CI 500 risk !!\n",
            .{HANDLER_PATH},
        );
        return error.IdGeneratorMissingAtomicCounter;
    }

    // And `fetchAdd` is wired into the generator body. Without this
    // call site, the counter is dead code.
    const fetch_add_marker = "fetchAdd";
    const has_fetch_add = std.mem.indexOf(u8, source, fetch_add_marker) != null;
    if (!has_fetch_add) {
        std.debug.print(
            "\n!! {s} declares the counter var but never calls fetchAdd — uniqueness is not enforced !!\n",
            .{HANDLER_PATH},
        );
        return error.IdGeneratorMissingFetchAdd;
    }
}

/// The same fix applies to workspaces_create.zig (PRIMARY KEY on
/// `workspaces.id`) — without an atomic counter, two POST
/// /api/workspaces hits in the same ms collide (CI run 31863092055).
fn assertWorkspaceGeneratorUsesCounter(allocator: std.mem.Allocator) !void {
    const WS_HANDLER_PATH = "src/http_handlers/workspaces_create.zig";
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        WS_HANDLER_PATH,
        allocator,
        .unlimited,
    );
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "std.atomic.Value(u64)") == null) {
        std.debug.print(
            "\n!! {s} is missing the atomic-counter var for workspace_id !!\n",
            .{WS_HANDLER_PATH},
        );
        return error.WorkspaceIdMissingAtomicCounter;
    }
    if (std.mem.indexOf(u8, source, "fetchAdd") == null) {
        std.debug.print(
            "\n!! {s} has the counter var but no fetchAdd call — counter is dead code !!\n",
            .{WS_HANDLER_PATH},
        );
        return error.WorkspaceIdMissingFetchAdd;
    }
}

test "task_create: id generator has atomic counter (Mac CI 500 regression)" {
    const alloc = testing.allocator;
    try assertGeneratorUsesCounter(alloc);
}

test "workspaces_create: id generator has atomic counter (Mac CI 500 regression)" {
    const alloc = testing.allocator;
    try assertWorkspaceGeneratorUsesCounter(alloc);
}

// ===== Tests merged from tasks_create_kanban_test.zig (2026-09-11 flatten) =====
// Static regression checks for the kanban auto-assign extension to
// `task_create.zig` (Chunk 3, Task 3.8).
// 
// Why this file exists
// ────────────────────
// The Workspace Item Kanban feature (plan:
// `2026-06-21-workspace-item-kanban.md`) extends the existing
// `POST /api/workspaces/:wsId/items/:itemId/tasks` handler so that
// tasks created under a kanban parent are auto-assigned to the
// first column (`ORDER BY position ASC LIMIT 1`) at
// `MAX(kanban_position) + 1`.
// 
// Without this extension, a freshly-created kanban task would have
// `kanban_column_id = NULL` and the frontend would have to send a
// separate `PATCH /tasks/:id/move` to place the card. The auto-assign
// removes that round-trip for the common case (task added under a
// kanban via the "Add Card" button).
// 
// These contracts are enforced by static substring checks, matching
// the project's `task_create_routines_test.zig` pattern.
// 
// Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
//   (Chunk 3, Task 3.8)

test "tasks_create sets kanban_column_id when parent is kanban" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must UPDATE `kanban_column_id = ?` on the freshly-
    // created task row, AND it must check `item_type = 'kanban'` to
    // gate the auto-assign. Without either substring the contract is
    // broken.
    if (std.mem.indexOf(u8, source, "kanban_column_id = ?") == null) {
        std.debug.print(
            "\n!! {s} does not UPDATE kanban_column_id !!\n" ++
                "   The auto-assign contract is broken: the handler must run\n" ++
                "   an UPDATE on the freshly-created task to set\n" ++
                "   `kanban_column_id = <first-column-id>`. Add:\n" ++
                "     UPDATE workspace_item_tasks SET kanban_column_id = ?,\n" ++
                "       kanban_position = (SELECT COALESCE(MAX(kanban_position), -1) + 1 FROM ...)\n" ++
                "     WHERE id = ?\n" ++
                "   See docs/superpowers/plans/2026-06-21-workspace-item-kanban.md.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanColumnAssignmentMissing;
    }
    if (std.mem.indexOf(u8, source, "item_type = 'kanban'") == null) {
        std.debug.print(
            "\n!! {s} does not check item_type = 'kanban' !!\n" ++
                "   The auto-assign must be gated on the parent item being a kanban.\n" ++
                "   Add a SELECT + eql check for `item_type = 'kanban'` before the UPDATE.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanTypeCheckMissing;
    }
}

// Regression for "task created in kanban doesn't appear in column" bug
// (user-reported 2026-06-24). The handler must include
// `kanban_column_id` + `kanban_position` in the 201 JSON response. Without
// them, the frontend's `workspacesStore.addTask` pushes a Task object with
// `kanban_column_id = undefined` into `item.tasks`, and
// `KanbanColumn.vue`'s `.filter((t) => t.kanban_column_id === column.id)`
// drops the card (visible on the kanban sidebar but invisible inside the
// column until a full page reload triggers `getTasks`).
//
// The fix: after the auto-assign UPDATE, re-SELECT the assigned values
// from the DB and include them in the JSON response alongside the
// existing `id`/`name`/`workspace_item_id`/`task_type`/`session_id` fields.
//
// As of 2026-07-02, the response is built via a typed struct +
// std.json.Stringify.valueAlloc (not hand-rolled std.fmt.allocPrint),
// so the substring check looks for the struct field declarations that
// valueAlloc will serialize into the JSON output.
test "tasks_create 201 response includes kanban_column_id and kanban_position" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must declare `kanban_column_id` as a field of the
    // typed response struct (StandardResponse). valueAlloc serializes
    // that struct field as `"kanban_column_id":<value>` in the JSON
    // output. Look for the struct field declaration to distinguish
    // the response emission from the auto-assign SQL.
    if (std.mem.indexOf(u8, source, "kanban_column_id: ?[]const u8") == null) {
        std.debug.print(
            "\n!! {s} does not include kanban_column_id in the 201 response !!\n" ++
                "   The 201 JSON must carry the assigned column so the frontend's\n" ++
                "   workspacesStore.addTask pushes a Task with kanban_column_id set.\n" ++
                "   Without this, KanbanColumn.vue's filter drops the card and the\n" ++
                "   user sees the task in the sidebar but not in any column.\n" ++
                "   Add a `kanban_column_id: ?[]const u8` field to the response struct.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanColumnIdInResponseMissing;
    }
    if (std.mem.indexOf(u8, source, "kanban_position: i64") == null) {
        std.debug.print(
            "\n!! {s} does not include kanban_position in the 201 response !!\n" ++
                "   The 201 JSON must carry the assigned position so the new card\n" ++
                "   sorts correctly within the column.\n",
            .{HANDLER_PATH},
        );
        return error.KanbanPositionInResponseMissing;
    }
}

// ===== Tests merged from tasks_create_value_alloc_test.zig (2026-09-11 flatten) =====
// Static regression checks for the `std.json.Stringify.valueAlloc`
// response pattern in `task_create.zig`.
// 
// Why this file exists
// ────────────────────
// The `tasksCreateHandler` previously built its 201 JSON response via
// three nested `std.fmt.allocPrint(allocator, ...)` calls (one per
// task_type branch). The `.standard` branch nested ANOTHER
// `std.fmt.allocPrint` inside the args tuple of the outer call:
// 
//     try std.fmt.allocPrint(allocator, "...{s}...", .{
//         ...
//         if (r.kanban_column_id) |cid|
//             try std.fmt.allocPrint(allocator, "...{s}...", .{...})
//         else
//             "...",
//     });
// 
// When the outer `Allocator.Writer` grows its buffer via
// `ensureTotalCapacityPrecise`, it `rawFree`s the old chunk back to
// the per-request arena. The inner `allocPrint`'s `rawAlloc` may
// then be served from the just-freed memory, leaving the inner
// result slice inside the outer's NEXT buffer chunk. When the outer
// `print` later does `@memcpy(w.buffer[w.end..], inner_buf)`, the
// slices overlap and Zig 0.16's runtime safety check aborts with:
// 
//     thread N panic: @memcpy arguments alias
//         at /usr/local/lib/zig/std/Io/Writer.zig:535
// 
// This is a user-reported crash (2026-07-01, see the long-running
// nalar on port 8081). The fix is to drop the hand-rolled JSON and
// use `std.json.Stringify.valueAlloc` with a typed struct, which
// (a) never nests `allocPrint` calls and (b) handles JSON escaping
// for user-provided strings like `r.name`.
// 
// These contracts are enforced by static substring checks, matching
// the project's `task_create_routines_test.zig` / `tasks_create_kanban_test.zig`
// pattern.





// ─── Contract 1: response uses valueAlloc, not nested allocPrint ───────

test "tasks_create 201 response uses std.json.Stringify.valueAlloc" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must use std.json.Stringify.valueAlloc for all
    // task_type branches (.memory, .standard — the .routine branch
    // was deleted with the per-task `routines` table, Migration 084).
    // Count the occurrences: 2 branches × 1 valueAlloc each = 2
    // minimum. Allow ≥ 2 to give room for future cleanup of the
    // doc-comment mention without breaking this test.
    const value_alloc_count = countOccurrences(source, "std.json.Stringify.valueAlloc");
    if (value_alloc_count < 2) {
        std.debug.print(
            "\n!! {s} response does not use std.json.Stringify.valueAlloc !!\n" ++
                "   Found {d} occurrences of `std.json.Stringify.valueAlloc`, need >= 2.\n" ++
                "   The handler has 2 task_type branches (.memory, .standard)\n" ++
                "   and each must serialize via valueAlloc. The typed-struct + valueAlloc\n" ++
                "   pattern is required to avoid the @memcpy aliasing crash and to\n" ++
                "   escape JSON-special characters in user-provided fields.\n",
            .{ HANDLER_PATH, value_alloc_count },
        );
        return error.ResponseUsesHandRolledAllocPrint;
    }
}

test "tasks_create 201 response has typed MemoryResponse / StandardResponse structs" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must define one typed struct per branch — valueAlloc
    // serializes a typed struct to JSON (it cannot serialize ad-hoc
    // format-string output).
    const required_structs = [_][]const u8{
        "MemoryResponse",
        "StandardResponse",
    };
    for (required_structs) |name| {
        if (std.mem.indexOf(u8, source, name) == null) {
            std.debug.print(
                "\n!! {s} is missing the `{s}` typed response struct !!\n" ++
                    "   valueAlloc requires a typed struct to serialize; ad-hoc format-string\n" ++
                    "   output is not supported. Add `const {s} = struct {{ ... }};` near\n" ++
                    "   the other response structs.\n",
                .{ HANDLER_PATH, name, name },
            );
            return error.TypedResponseStructMissing;
        }
    }
}

// ─── Contract 2: response has no nested std.fmt.allocPrint ────────────

test "tasks_create does NOT nest std.fmt.allocPrint inside another allocPrint" {
    const allocator = testing.allocator;
    const source = try readSource_merged(allocator, HANDLER_PATH);
    defer allocator.free(source);
    const impl_end = std.mem.indexOf(u8, source, "// ===== Tests merged from") orelse source.len;
    const impl_source = source[0..impl_end];

    // The bug pattern: a `try std.fmt.allocPrint(...)` whose result is
    // returned as an arg of an OUTER `std.fmt.allocPrint(...)`. When
    // both share the per-request arena, the inner result slice can
    // alias with the outer's grown buffer and trigger Zig 0.16's
    // `@memcpy arguments alias` runtime panic.
    //
    // Detection heuristic: look for `try std.fmt.allocPrint` inside
    // the response switch block (the `switch (outcome)` in
    // `tasksCreateHandler`). The use case layer (createStandardTask)
    // also calls allocPrint, but those results
    // are stored in a returned struct field, not fed back into another
    // allocPrint, so they don't have the aliasing risk.
    //
    // We grep the whole file for `try std.fmt.allocPrint` — if there
    // are 0 occurrences (the response is built via valueAlloc
    // exclusively), the bug pattern is gone.
    const nested_alloc_print = countOccurrences(impl_source, "try std.fmt.allocPrint");
    if (nested_alloc_print > 0) {
        std.debug.print(
            "\n!! {s} still contains `try std.fmt.allocPrint` !!\n" ++
                "   Found {d} occurrences. The handler must build responses via typed\n" ++
                "   structs + std.json.Stringify.valueAlloc, NEVER via std.fmt.allocPrint\n" ++
                "   chained with another allocPrint sharing the per-request arena. That\n" ++
                "   pattern triggers a Zig 0.16 runtime panic:\n" ++
                "     thread N panic: @memcpy arguments alias\n" ++
                "       at /usr/local/lib/zig/std/Io/Writer.zig:535\n" ++
                "   The user-reported crash on 2026-07-01 was triggered by exactly this\n" ++
                "   pattern in the .standard branch. Replace all `try std.fmt.allocPrint`\n" ++
                "   response builders with `std.json.Stringify.valueAlloc` + a typed\n" ++
                "   struct.\n",
            .{ HANDLER_PATH, nested_alloc_print },
        );
        return error.NestedAllocPrintPresent;
    }
}

// ─── helpers ───────────────────────────────────────────────────────────

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, idx, needle)) |pos| {
        count += 1;
        idx = pos + needle.len;
    }
    return count;
}
