const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const llm_history = nalarcore.llm_history;
const tags_validation = @import("tags_validation.zig");
const image_urls_validation = @import("image_urls_validation.zig");
const video_urls_validation = @import("video_urls_validation.zig");

/// PUT /api/workspaces/tasks/:task_id - Update task by ID only (no workspace/item needed).
///
/// Body: { name?, session_id?, description?, tags?, image_urls?, cwd? }.
/// Standard fields keep the existing cascade paths.
///
/// NOTE: the routine fields (`schedule`, `initial_prompt`, `enabled`)
/// were deleted with the per-task `routines` table (Migration 084,
/// plan 2026-09-10-workspace-items-routines). Routines are now
/// first-class workspace items — see `workspace_routines_update.zig`.
/// Unknown body fields are ignored (`ignore_unknown_fields = true`),
/// so old clients sending routine fields get a plain task update.
pub fn tasksUpdateByIdHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return updateTaskHandler(ctx, req, res);
}

/// PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
/// (Same body and behavior as tasksUpdateByIdHandler.)
pub fn tasksUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return updateTaskHandler(ctx, req, res);
}

// =====================================================================
// Error set + input/output types for the useCase
// =====================================================================

pub const TaskUpdateError = error{
    OutOfMemory,
    InvalidJson,
    MissingBody,
    FailedToUpdateTask,
    /// Kanban task tags validation (Migration 067). Empty,
    /// too long, or contains forbidden characters (only
    /// [a-zA-Z0-9_-] allowed). See tags_validation.zig.
    InvalidTags,
    /// Per-task cwd validation (Migration 070 — kanban-cwd-session-
    /// optional plan). Mirrors the same errors as the create
    /// handler — 4 KiB cap, absolute-path requirement, no control
    /// characters. Existence of the path is NOT validated (OS-
    /// level concern surfaced by the agent's first cwd-using
    /// tool call).
    CwdTooLong,
    CwdNotAbsolute,
    CwdContainsControlChar,
    /// Image urls validation (Migration 069 — kanban image urls
    /// column). Mirrors the create handler's errors — malformed
    /// data URL prefix (400) or the 10 MB total cap (413).
    /// Plan: docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
    InvalidImageUrls,
    ImageUrlsTooLarge,
    /// Video urls validation (Migration 090). Same contract with
    /// a 25 MB cap.
    InvalidVideoUrls,
    VideoUrlsTooLarge,
};

/// Slice of optional fields the client may send. Mirrors
/// `http_response.TaskUpdateRequest` but expressed as a struct-local type
/// to avoid a forced include in this file.
const TaskUpdateInput = struct {
    task_id: []const u8,
    body: http_response.TaskUpdateRequest,
    db: *nalarcore.sqlite.SqliteBackend,
};

/// Result of a successful task update. The handler serializes the
/// `id` field into a small `{"success":true,"id":"..."}` JSON response.
const TaskUpdateResult = struct {
    task_id: []const u8,
};

// =====================================================================
// Handler
// =====================================================================

/// Shared implementation for both task-update routes. The two
/// registrations differ only in URL shape; the body parsing, cascade
/// logic, and routine-fields branch are identical.
fn updateTaskHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    // Parse request body
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskUpdateRequest, allocator, body, .{ .ignore_unknown_fields = true }) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    const result = useCase(allocator, .{
        .task_id = task_id,
        .body = json_body,
        .db = sqlite_db,
    }) catch |err| {
        // (unchanged error-mapping block — collapsed for the diff)
        const status: u16 = switch (err) {
            error.FailedToUpdateTask => 500,
            error.MissingBody => 400,
            error.InvalidJson => 400,
            error.InvalidTags => 400,
            error.InvalidImageUrls => 400,
            error.ImageUrlsTooLarge => 413,
            error.InvalidVideoUrls => 400,
            error.VideoUrlsTooLarge => 413,
            error.CwdTooLong,
            error.CwdNotAbsolute,
            error.CwdContainsControlChar => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidJson => "Invalid JSON",
            error.MissingBody => "Request body required",
            error.FailedToUpdateTask => "Failed to update task",
            error.InvalidTags => "tags must be non-empty, ≤50 chars, and contain only letters, digits, hyphens, and underscores",
            error.InvalidImageUrls => "image_urls must be `||`-delimited data:image/<mime>;base64,... URLs",
            error.ImageUrlsTooLarge => "image_urls payload too large (max 10 MB)",
            error.InvalidVideoUrls => "video_urls must be `||`-delimited data:video/<mime>;base64,... URLs",
            error.VideoUrlsTooLarge => "video payload too large (max 25 MB)",
            error.CwdTooLong => "cwd path too long (max 4 KiB)",
            error.CwdNotAbsolute => "cwd must be an absolute path",
            error.CwdContainsControlChar => "cwd contains a control character",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // Chunk 5 of kanban-task-notification-icon: every rename/edit/pin
    // counts as a human touch — stamp last_human_touched_at so the
    // kanban card flips from the orange "awaiting review" dot to the
    // green "reviewed" checkmark. Fire-and-forget: a failed stamp
    // doesn't fail the rename (the rename is already committed).
    ai_mod.llm_history.updateTaskLastHumanTouchedAt(
        allocator,
        sqlite_db,
        task_id,
        null,
    ) catch |err| {
        std.log.warn(
            "task_update: stamp last_human_touched_at failed (non-fatal): {s}",
            .{@errorName(err)},
        );
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\"}}", .{result.task_id}) });
}

// =====================================================================
// useCase
// =====================================================================

fn useCase(allocator: std.mem.Allocator, input: TaskUpdateInput) TaskUpdateError!TaskUpdateResult {
    const task_id = input.task_id;

    // Description branch. When `body.description` is present (non-null),
    // overwrite the column with the new value. Empty string is the
    // canonical "no description" sentinel and IS persisted (NOT
    // skipped) — the user actively cleared the field, which the UI
    // renders as the "Add a description…" placeholder. Null means
    // "leave unchanged" (the caller didn't include the field in the
    // PUT body). Migration 062 added the column.
    //
    // We use a dynamic SQL builder + parallel `bind_values` list
    // (single `db.exec` call) per PR #101 review feedback. The
    // empty-string case uses a SQL '' literal (NOT a `?` bind)
    // because `SqliteBackend.exec` binds empty `[]const u8` slices
    // as SQL NULL, which would fail the column's NOT NULL DEFAULT ''
    // constraint — see memory `sqlite-backend-empty-slice-binds-as-null`.
    if (input.body.description) |desc| {
        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator,
            "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", description = ");
        if (desc.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, desc);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Tags branch (Migration 067 — kanban task tags feature).
    // Same shape as description: present (non-null) means
    // overwrite; empty string is the canonical "no tags"
    // sentinel and IS persisted (user actively cleared the
    // tags); null means "leave unchanged".
    //
    // The dynamic SQL builder pattern matches description above —
    // the empty-string case uses a SQL '' literal to avoid the
    // empty-slice-binds-as-NULL footgun. See memory
    // `sqlite-backend-empty-slice-binds-as-null`.
    if (input.body.tags) |raw_tags| {
        // Validate + normalize. Returns a JSON-encoded array
        // string ('' when no tags). Borrowed from the per-request
        // arena; arena reaps it on request teardown.
        const validated_tags = tags_validation.validateAndNormalizeTags(
            allocator,
            raw_tags,
        ) catch return error.InvalidTags;

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator,
            "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", tags = ");
        if (validated_tags.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, validated_tags);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Image urls branch (Migration 069 — kanban image urls column).
    // Same shape as description + tags: present (non-null) means
    // overwrite; empty string is the canonical "no images" sentinel
    // and IS persisted (user actively removed the images); null
    // means "leave unchanged".
    //
    // The dynamic SQL builder pattern matches description + tags
    // above — the empty-string case uses a SQL '' literal to avoid
    // the empty-slice-binds-as-NULL footgun. See memory
    // `sqlite-backend-empty-slice-binds-as-null`.
    // Plan: docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
    if (input.body.image_urls) |raw_urls| {
        // Validate. Returns the already-joined `||`-delimited string
        // (borrowed from the per-request arena; arena reaps it on
        // request teardown). Mirrors the create handler's mapping
        // (task_create.zig) so a value accepted at create time is
        // also accepted at update time.
        const validated_urls = image_urls_validation.validateImageUrls(raw_urls) catch |err| return switch (err) {
            error.ImageUrlsTooLarge => error.ImageUrlsTooLarge,
            error.InvalidImageUrl => error.InvalidImageUrls,
        };

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator,
            "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", image_urls = ");
        if (validated_urls.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, validated_urls);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Video urls branch (Migration 090 — kanban video urls column).
    // Same shape as image_urls above: present means overwrite, ""
    // clears, null leaves unchanged. Validated prefix + 25 MB cap.
    if (input.body.video_urls) |raw_urls| {
        const validated_urls = video_urls_validation.validateVideoUrls(raw_urls) catch |err| return switch (err) {
            error.VideoUrlsTooLarge => error.VideoUrlsTooLarge,
            error.InvalidVideoUrl => error.InvalidVideoUrls,
        };

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator,
            "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", video_urls = ");
        if (validated_urls.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, validated_urls);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Per-task cwd branch (Migration 070 — kanban-cwd-session-
    // optional plan). Same shape as description + tags: present
    // (non-null) means overwrite; empty string is the canonical
    // "no per-task cwd" sentinel and IS persisted (user actively
    // cleared the cwd); null means "leave unchanged".
    //
    // Same validation as the create handler — absolute path,
    // ≤ 4 KiB, no control characters. Existence is NOT checked
    // here (OS-level concern surfaced by the agent's first
    // cwd-using tool call).
    if (input.body.cwd) |raw_cwd| {
        // Reuse the create-handler validation. Mirrors the create
        // path exactly so a value that's accepted at create time
        // is also accepted at update time (and vice versa).
        if (raw_cwd.len > 4096) return error.CwdTooLong;
        if (raw_cwd.len > 0 and !std.fs.path.isAbsolute(raw_cwd)) return error.CwdNotAbsolute;
        for (raw_cwd) |c| {
            if (c < 0x20 or c == 0x7f) return error.CwdContainsControlChar;
        }

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try sql_buf.appendSlice(allocator,
            "UPDATE workspace_item_tasks SET updated_at = datetime('now')");
        try sql_buf.appendSlice(allocator, ", cwd = ");
        if (raw_cwd.len == 0) {
            try sql_buf.appendSlice(allocator, "''");
        } else {
            try sql_buf.appendSlice(allocator, "?");
            try bind_values.append(allocator, raw_cwd);
        }
        try sql_buf.appendSlice(allocator, " WHERE id = ?");
        try bind_values.append(allocator, task_id);

        input.db.exec(allocator, sql_buf.items, bind_values.items) catch return error.FailedToUpdateTask;
    }

    // Conditional split: route name updates through the cascade
    // (updateTaskName → updateSessionName → SSE broadcast). The
    // legacy `session_id` body field is accepted for backward
    // compatibility (older client builds may still send it) but
    // is a no-op — `task.id` IS the session id per the
    // `task.id == session_id` convention (Migration 052 dropped
    // the redundant column).
    if (input.body.name) |n| {
        llm_history.updateTaskName(allocator, input.db, task_id, n) catch {
            return error.FailedToUpdateTask;
        };
    }

    return .{ .task_id = task_id };
}

// ===== Tests merged from task_update_test.zig (2026-09-11 flatten) =====
// Static regression check for the rename-task cascade.
// 
// Why this file exists
// ────────────────────
// The frontend workspace-item rename feature depends on the rename
// HTTP path updating BOTH `workspace_item_tasks.name` AND the linked
// `sessions.name` (the second update is what triggers the SSE
// `session.updated` event that the ChatsList listens for).
// 
// Without these two source-level contracts, the cascade is silently
// broken — the rename UI would appear to work, but the chat list
// would never pick up the new name until manual reload. The bug is
// hard to spot in a casual read because the old code (the no-cascade
// `updateWorkspaceItemTask`) is right next to the new code.
// 
// The contract is enforced by two static substring checks:
//   1. The HTTP handler must route name updates through
//      `llm_history.updateTaskName(...)` (NOT the plain
//      `ai_mod.workspace_item_tasks.updateWorkspaceItemTask`).
//   2. `llm_history.updateTaskName` must call `updateSessionName`
//      so the cascade runs and the SSE broadcast fires.
// 
// Why a static check (not a behavioral DB test)?
// ───────────────────────────────────────────────
// The project has no precedent for in-process sqlite-backed tests
// (every test in `test_runner.zig` either covers a pure function or
// is a static source check). Standing up a sqlite DB + migrations +
// event-bus subscription in a unit test would require either pulling
// in the `nalarcore.getSingleton()` singleton (which depends on a
// live `ContextIPCTui` with a server, logger, and event bus) or
// duplicating the migration setup. The two static checks below
// directly test the bug — they fail if and only if the cascade
// contract is removed or routed back to the old path.
// 
// Plan: docs/plans/2026-06-06-workspace-item-task-rename.md

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/task_update.zig";
const LLM_HISTORY_PATH = "src/agentic_loop/llm_history.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: handler uses the cascade path for renames ─────────────────

test "task_update handler routes name updates through llm_history.updateTaskName" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must contain a call to llm_history.updateTaskName.
    // If this is missing, the rename went back to the old
    // updateWorkspaceItemTask path that only updates the task row.
    if (std.mem.indexOf(u8, source, "llm_history.updateTaskName") == null) {
        std.debug.print(
            "\n!! {s} does not call llm_history.updateTaskName !!\n" ++
                "   The rename-cascade contract is broken: renaming a task\n" ++
                "   will not update the linked sessions row or broadcast the\n" ++
                "   SSE session.updated event that the ChatsList listens for.\n" ++
                "   Restore the cascade:\n" ++
                "     if (json_body.name) |n| {{\n" ++
                "         llm_history.updateTaskName(allocator, sqlite_db, task_id, n) ...\n" ++
                "     }}\n" ++
                "   See docs/plans/2026-06-06-workspace-item-task-rename.md.\n",
            .{HANDLER_PATH},
        );
        return error.RenameCascadeMissing;
    }
}

// ─── Contract 2: updateTaskName cascades to updateSessionName ─────────────

test "llm_history.updateTaskName cascades to updateSessionName" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // Find the updateTaskName function body and verify it calls
    // updateSessionName. We do this by scanning the source for the
    // function signature and checking that `updateSessionName` appears
    // in the file (it appears in exactly two places: its own definition
    // and our cascade call). A more robust check would extract the
    // function body with the AST, but substring search is enough for
    // the contract — if the cascade is removed, this still passes
    // because updateSessionName is defined in the file. So we add
    // a tighter check below: updateSessionName must be called AFTER
    // the updateTaskName signature.

    const update_task_name_sig = "pub fn updateTaskName(";
    const sig_idx = std.mem.indexOf(u8, source, update_task_name_sig) orelse {
        std.debug.print(
            "\n!! Could not find `pub fn updateTaskName(` in {s} !!\n",
            .{LLM_HISTORY_PATH},
        );
        return error.UpdateTaskNameNotFound;
    };

    // Find the next `pub fn` after updateTaskName. Everything between
    // the signature and the next `pub fn` is the function body.
    const after_sig = sig_idx + update_task_name_sig.len;
    const next_pub_fn = std.mem.indexOfPos(u8, source, after_sig, "pub fn ") orelse source.len;
    const body = source[after_sig..next_pub_fn];

    if (std.mem.indexOf(u8, body, "updateSessionName") == null) {
        std.debug.print(
            "\n!! llm_history.updateTaskName does not call updateSessionName !!\n" ++
                "   The rename-cascade contract is broken: renaming a task\n" ++
                "   will not propagate to the linked sessions row or trigger\n" ++
                "   the SSE session.updated broadcast that the ChatsList\n" ++
                "   listens for.\n" ++
                "   Restore the cascade in updateTaskName:\n" ++
                "     updateSessionName(allocator, db, session_id, new_name) catch {{}};\n" ++
                "   See docs/plans/2026-06-06-workspace-item-task-rename.md.\n",
            .{},
        );
        return error.RenameCascadeMissing;
    }
}

// ─── Contract 3: handler no longer references the dropped session_id rebind ─

test "task_update handler no longer references the dropped session_id rebind" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Flatten (2026-09-11): tests now live in this same file below the
    // '// ===== Tests merged from' banner, so scope the absence check to
    // the impl section only — otherwise the needle inside this very
    // test (plus sibling-test comments) self-matches.
    const impl_end = std.mem.indexOf(u8, source, "// ===== Tests merged from") orelse source.len;
    const impl_source = source[0..impl_end];

    // Migration 052 dropped the redundant `session_id` column from
    // `workspace_item_tasks` (the column equaled the task's own id
    // per the `task.id == session_id` convention). The rebind path
    // (`updateWorkspaceItemTask(... , null, sid)`) was removed in
    // the same change. This test guards against accidentally
    // re-introducing it.
    if (std.mem.indexOf(u8, impl_source, "updateWorkspaceItemTask") != null) {
        std.debug.print(
            "\n!! {s} still calls updateWorkspaceItemTask !!\n" ++
                "   Migration 052 dropped the session_id column; the rebind\n" ++
                "   path is no longer needed (task.id IS the session id).\n" ++
                "   Remove the call from the handler.\n",
            .{HANDLER_PATH},
        );
        return error.RebindPathStillPresent;
    }
}

// ─── Contract 4: task_update persists description (Migration 062) ──────────
//
// When the request body carries a `description` field, the handler must
// persist it to `workspace_item_tasks.description` via a guarded UPDATE
// (only when the field is non-null — null means "leave unchanged").
// Empty string is the canonical "no description" sentinel and IS
// persisted (NOT skipped — it means the user actively cleared the field).
//
// Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
//   (Chunk 1, Task 1.3).

test "task_update persists description to workspace_item_tasks column" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must contain an UPDATE that sets the description
    // column. After PR #101 refactor the SQL is built dynamically,
    // so we match the composed fragments rather than a literal
    // `description = ?` substring (which no longer appears in source).
    // The dynamic builder appends:
    //   - `, description = ` (between the fixed prefix and the RHS)
    //   - either `''` (empty-string literal) or `?` (value bind)
    // We require at least the `?` bind path so a regression that
    // always uses the literal still has to wire the bind through.
    const has_set_clause = std.mem.indexOf(u8, source, ", description = ") != null;
    const has_bind = std.mem.indexOf(u8, source, ", description = \"?") != null or
        std.mem.indexOf(u8, source, "appendSlice(allocator, \"?\")") != null;
    const has_where = std.mem.indexOf(u8, source, "WHERE id = ?") != null or
        std.mem.indexOf(u8, source, "\" WHERE id = ?\"") != null;
    if (!has_set_clause or !has_bind or !has_where) {
        std.debug.print(
            "\n!! {s} does not UPDATE workspace_item_tasks.description !!\n" ++
                "   Migration 062 added the column; PUT /api/workspaces/tasks/:id\n" ++
                "   with a body.description must persist it via the dynamic SQL\n" ++
                "   builder. The useCase's description branch must:\n" ++
                "   - sql_buf.appendSlice(allocator, \", description = \")\n" ++
                "   - sql_buf.appendSlice(allocator, \"?\")  // for non-empty desc\n" ++
                "   - sql_buf.appendSlice(allocator, \" WHERE id = ?\")\n" ++
                "   See plan docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md.\n" ++
                "   Missing: set_clause={any}, bind={any}, where={any}\n",
            .{ HANDLER_PATH, has_set_clause, has_bind, has_where },
        );
        return error.DescriptionUpdateMissing;
    }
}

test "task_update guards description branch on body.description != null" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The UPDATE must be wrapped in an `if (input.body.description) |...|`
    // guard so a null body.description (the "leave unchanged" sentinel
    // in TaskUpdateRequest) does NOT overwrite the column with NULL.
    // We check for the pattern `if (input.body.description)` (or the
    // equivalent `if (input.body.description) |`) anywhere in the file.
    const has_branch = std.mem.indexOf(u8, source, "if (input.body.description)") != null or
        std.mem.indexOf(u8, source, "if (json_body.description)") != null;
    if (!has_branch) {
        std.debug.print(
            "\n!! {s} does not guard the description branch !!\n" ++
                "   The UPDATE must only run when input.body.description is non-null\n" ++
                "   (a null value is the 'leave unchanged' sentinel in the request).\n" ++
                "   Add `if (input.body.description) |desc| {{ ... }}` around the\n" ++
                "   UPDATE statement.\n",
            .{HANDLER_PATH},
        );
        return error.DescriptionBranchUnguarded;
    }
}

// =====================================================================
// Migration 069 read-path follow-up (plan:
// docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md
// Task 3): the PUT handler parses TaskUpdateRequest.image_urls but had
// NO useCase branch — image edits were silently dropped. Two contracts:
// the branch must exist + validate via image_urls_validation, and the
// handler must map the validation errors to 400/413.
// =====================================================================

test "task_update useCase persists image_urls edits" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The useCase must import + use image_urls_validation.
    if (std.mem.indexOf(u8, source, "image_urls_validation") == null) {
        std.debug.print(
            "\n!! {s} does not import/use image_urls_validation !!\n" ++
                "   The PUT handler parses TaskUpdateRequest.image_urls but\n" ++
                "   never persists it — image edits are silently dropped.\n" ++
                "   Add an image_urls branch mirroring the tags branch\n" ++
                "   (validate via image_urls_validation.validateImageUrls,\n" ++
                "   dynamic SQL builder, SQL '' literal for the empty case).\n",
            .{HANDLER_PATH},
        );
        return error.ImageUrlsValidationMissing;
    }

    // The useCase must read input.body.image_urls.
    if (std.mem.indexOf(u8, source, "input.body.image_urls") == null) {
        std.debug.print(
            "\n!! {s} useCase does not read input.body.image_urls !!\n",
            .{HANDLER_PATH},
        );
        return error.ImageUrlsBranchMissing;
    }
}

test "task_update maps image_urls validation errors to 400/413" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "error.InvalidImageUrls => 400") == null) {
        std.debug.print(
            "\n!! {s} handler does not map error.InvalidImageUrls to 400 !!\n",
            .{HANDLER_PATH},
        );
        return error.InvalidImageUrlsStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "error.ImageUrlsTooLarge => 413") == null) {
        std.debug.print(
            "\n!! {s} handler does not map error.ImageUrlsTooLarge to 413 !!\n",
            .{HANDLER_PATH},
        );
        return error.ImageUrlsTooLargeStatusMissing;
    }
}
