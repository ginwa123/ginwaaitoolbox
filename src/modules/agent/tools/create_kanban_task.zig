//! LLM tool: `create_kanban_task` — creates a new `workspace_item_tasks`
//! row under an existing kanban `workspace_item`.
//!
//! Flow (mirrors `task_create.zig::createStandardTask` exactly):
//!   1. Validate `workspace_id`, `item_id`, `name` (non-empty after trim).
//!   2. Verify the parent `workspace_items.id = item_id` has
//!      `item_type = 'kanban'`. Reject otherwise.
//!   3. INSERT into `workspace_item_tasks` via
//!      `nalarcore.ai_mod.llm_history.createWorkspaceItemTask` with
//!      `task_type = 'standard'` (every kanban task is a standard task
//!      whose PARENT has `item_type='kanban'`; the schema has no
//!      `task_type='kanban'`).
//!   4. Resolve the target column id. When `column_id` is null, pick
//!      the first column by `position ASC`. When supplied, verify the
//!      column belongs to the same `workspace_item_id`.
//!   5. INSERT OR REPLACE INTO the `kanban` join table (post-
//!      Migration 072) with `kanban_column_id` and `kanban_position`
//!      (set to MAX(position)+1 within the target column).
//!   6. Emit a `kanban_task` SSE event with `action="created"` for
//!      multi-tab sync (fire-and-forget; log + continue on error).
//!   7. Return the success XML to the LLM.
//!
//! Plan: docs/superpowers/plans/2026-07-29-create-kanban-task-tool.md
//! Parallel HTTP handler: `src/ai_workflow/tui/http_handlers/task_create.zig`
//!   ::createStandardTask (lines 337-503).

const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const tags_validation = @import("../../../ai_workflow/tui/http_handlers/tags_validation.zig");
const image_urls_validation = @import("../../../ai_workflow/tui/http_handlers/image_urls_validation.zig");

/// Input structure for `create_kanban_task` tool.
///
/// The agent should pass `workspace_id` and `item_id` from the active
/// chat context (see the "## Workspace Context" section of the system
/// prompt). `name` is the card title. `description` is optional (the
/// task's tooltip text in the kanban UI). `column_id` is optional —
/// when omitted, the task is auto-assigned to the first column at
/// `MAX(kanban_position) + 1` (append-to-bottom semantics matching
/// the HTTP handler).
///
/// The five trailing optional fields mirror the user-facing
/// `KanbanTaskDetailDialog` form so the agent can set everything the
/// human user can set when adding a card from the UI:
///   - `tags` (JSON-encoded array string like `"[\"bug\",\"urgent\"]"`)
///   - `image_urls` (`||`-delimited `data:image/...;base64,...` URLs)
///   - `cwd` (absolute path for the per-task project root)
///   - `is_auto_retry_until_stop` (`"1"` to enable unattended mode)
///   - `selected_profile_model` (name of the profile to bind on the
///      created sessions row — see Path A in the
///      `2026-08-06-kanban-task-profile-selector` plan)
pub const CreateKanbanTaskInput = struct {
    /// The workspace that owns the kanban item. From chat context.
    workspace_id: []const u8 = "",
    /// The kanban workspace item id. From chat context. Must have
    /// `item_type='kanban'` (validated up front).
    item_id: []const u8 = "",
    /// Card title shown on the kanban board. Required, must be
    /// non-empty after trim of leading/trailing whitespace.
    name: []const u8 = "",
    /// Optional card description (tooltip text in the kanban UI).
    description: ?[]const u8 = null,
    /// Optional target column id. When omitted, the task is
    /// auto-assigned to the first column by `position ASC` at
    /// `MAX(kanban_position) + 1`. When supplied, the tool verifies
    /// the column belongs to the same kanban item.
    column_id: ?[]const u8 = null,
    /// Optional tags — JSON-encoded array string like
    /// `"[\"bug\",\"urgent\"]"`. Validated + normalized by
    /// `tags_validation.validateAndNormalizeTags` (≤50 chars,
    /// `[a-zA-Z0-9_-]` only, case-insensitive dedupe). Null/empty
    /// = no tags. Matches the wire shape `TaskCreateRequest.tags`.
    tags: ?[]const u8 = null,
    /// Optional image attachments — `||`-delimited
    /// `data:image/<mime>;base64,<payload>` URLs (10 MB cap, enforced
    /// by `image_urls_validation.validateImageUrls`). Null/empty =
    /// no images. Matches the wire shape `TaskCreateRequest.image_urls`.
    image_urls: ?[]const u8 = null,
    /// Optional per-task project root — absolute path. Must start
    /// with `/`, ≤4 KiB, no control chars. Empty/null = cwd-less
    /// task (defaults to the kanban's path at session-create time).
    /// Matches the wire shape `TaskCreateRequest.cwd`.
    cwd: ?[]const u8 = null,
    /// Optional unattended-mode flag. `"1"` enables the agent to
    /// retry past the 10-error TooManyRetries bail (overnight runs);
    /// any other value normalizes to `"0"`. When set, an INSERT OR
    /// IGNORE INTO `sessions` row is created keyed by the new
    /// task's id (task.id == session.id convention). Matches the
    /// wire shape `TaskCreateRequest.is_auto_retry_until_stop`.
    is_auto_retry_until_stop: ?[]const u8 = null,
    /// Optional profile name to bind on the new sessions row. When
    /// set, the INSERT OR IGNORE INTO `sessions` includes
    /// `selected_profile_model`. Null/empty = backend default
    /// (`""` = top-level config). Matches the wire shape used by
    /// `RequestSession.selected_profile_model` (Path A — the
    /// frontend's plain-create path also does not persist this on
    /// the task itself, only on the chat session it spawns later).
    selected_profile_model: ?[]const u8 = null,
};

/// Top-level tool definition for the LLM.
///
/// The description is the LLM's primary signal for WHEN to use this
/// tool — it tells the LLM:
///   1. The tool creates a NEW card on a kanban board (use this when
///      the user says "add a task to the kanban", "create a card
///      for X", etc.).
///   2. `workspace_id` and `item_id` come from the active chat's
///      "## Workspace Context" section (no hallucinated ids).
///   3. `column_id` is OPTIONAL — omit it to auto-assign to the
///      first column (append-to-bottom). Pass it only when the user
///      explicitly names a column.
pub const create_kanban_task_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "create_kanban_task",
        .description =
            \\Create a new task/card on a kanban board. Use this tool when the user asks to add a new task to a kanban, "create a card for X", "add 'do the thing' to the sprint", or any other instruction that means "make a new card". The task is auto-assigned to the first column at MAX(kanban_position)+1 unless column_id is supplied.
            \\
            \\The workspace_id and item_id must come from the chat context — see the "## Workspace Context" section of the system prompt. Each sibling item is rendered as `- **<name>** (id: <id>, item_type: <type>, path: <path>)` where the id is a backtick-quoted id (e.g. item_1782313125507292140). The id is the **canonical** lookup key — do NOT pass the human-readable name (e.g. "sprint 1"); the DB columns are indexed by id and a name lookup returns zero rows. The kanban item is the one with `item_type='kanban'` marked with `*(this task)*` in the Workspace Context.
            \\
            \\name is required (card title shown on the board). description is optional (tooltip text). column_id is optional — when omitted, the task is auto-assigned to the first kanban column at MAX(kanban_position)+1; when supplied, the column must belong to the same kanban item. To set a specific position, call kanban_move_task after this tool returns.
            \\
            \\Optional fields (mirror the user-facing KanbanTaskDetailDialog form, Migration 062 / 067 / 069 / 070/071 — all five are persisted on create, not just on chat-spawn):
            \\  - tags: JSON-encoded array string like "[\"bug\",\"urgent\"]". Letters/digits/`_`/`-` only, ≤50 chars per tag, case-insensitive dedupe. Null/empty = no tags.
            \\  - image_urls: `||`-delimited `data:image/<mime>;base64,<payload>` URLs. Null/empty = no images. 10 MB cap.
            \\  - cwd: absolute path for the per-task project root (must start with `/`, ≤4 KiB, no control chars). Null/empty = cwd-less (inherits the kanban's path at session-create time).
            \\  - is_auto_retry_until_stop: "1" enables unattended mode (agent keeps retrying past the 10-error TooManyRetries bail). Anything else normalizes to "0". When set, an INSERT OR IGNORE INTO sessions row is created keyed by the new task's id.
            \\  - selected_profile_model: name of the profile in `LlmConfig.profiles` to bind on the new sessions row (Path A — persisted on the chat session, not on the task). Null/empty = backend default.
            \\
            \\Workflow: (1) call kanban_list first to discover the kanban item id and (optionally) the column id if the user named one, (2) call create_kanban_task with those ids, (3) use kanban_move_task if the task needs to land in a non-default position. On error, recover by: (1) verify item_id from the Workspace Context listing; (2) if the parent item is not a kanban, the tool returns a structured error — pick the item marked `*(this task)*` instead; (3) if column_id was rejected, omit it and let auto-assign place the card.
        ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "workspace_id",
                    .type = "string",
                    .description = "The workspace that owns the kanban item. From chat context. Always starts with `ws_`.",
                },
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The kanban workspace item id (NOT the name). From chat context. The item has `item_type='kanban'`. Always starts with `item_`.",
                },
                .{
                    .name = "name",
                    .type = "string",
                    .description = "Card title shown on the kanban board. Required, non-empty after trim. Used as the chat session's name when the user later opens the card.",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "Optional card description (tooltip text in the kanban UI). Omit when no description is needed.",
                },
                .{
                    .name = "column_id",
                    .type = "string",
                    .description = "Optional target column id (NOT name). When omitted, the task is auto-assigned to the first column at MAX(kanban_position)+1. Use kanban_list to discover column ids — never pass the human-readable name.",
                },
                .{
                    .name = "tags",
                    .type = "string",
                    .description = "Optional tags as a JSON-encoded array string, e.g. \"[\"bug\",\"urgent\"]\". Letters/digits/`_`/`-` only, ≤50 chars per tag, case-insensitive dedupe (validated by tags_validation). Null or empty = no tags.",
                },
                .{
                    .name = "image_urls",
                    .type = "string",
                    .description = "Optional image attachments as a `||`-delimited string of `data:image/<mime>;base64,<payload>` URLs (10 MB cap, validated by image_urls_validation). Null or empty = no images.",
                },
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Optional per-task project root as an absolute path (must start with `/`, ≤4 KiB, no control chars). Null or empty = cwd-less (inherits the kanban's path at session-create time).",
                },
                .{
                    .name = "is_auto_retry_until_stop",
                    .type = "string",
                    .description = "Optional unattended-mode flag. `\"1\"` enables retrying past the 10-error TooManyRetries bail (overnight runs); any other value normalizes to `\"0\"`. When set, a sessions row is created keyed by the new task's id.",
                },
                .{
                    .name = "selected_profile_model",
                    .type = "string",
                    .description = "Optional profile name from `LlmConfig.profiles` to bind on the new sessions row. Null or empty = backend default (top-level config).",
                },
            },
            .required = &.{ "workspace_id", "item_id", "name" },
        },
    },
};

// =====================================================================
// Implementation (Task 4)
// =====================================================================
//
// Mirrors `task_create.zig::createStandardTask` (HTTP handler) but
// runs directly in the agent tool process — no HTTP round-trip. Reads
// and writes DB directly via the `nalarcore.ai_mod.*` helpers, the
// same pattern used by `kanban_list` / `kanban_move_task`.

/// Escape XML special characters. Mirrors the helper in
/// `kanban_list.zig:115-131` / `kanban_move_task.zig:456-471`.
fn xmlEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Generate an error XML response. The error body is wrapped in
/// `<kanban_task><error>...</error></kanban_task>` so the
/// `tools_exec_create_kanban_task.zig` wrapper can detect it via
/// `<error>` substring search and surface the structured error to
/// the LLM as `success=false`. The function DUPs the input so callers
/// don't need to free it (avoids a leak when the input is the
/// result of `std.fmt.allocPrint(...)`).
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    const owned = try allocator.dupe(u8, error_msg);
    defer allocator.free(owned);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<kanban_task><success>false</success><error>");
    const escaped = try xmlEscape(allocator, owned);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></kanban_task>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees it
/// on return. Use this when the caller already has a heap-allocated
/// message that they want to free (e.g. via defer). Errors from
/// allocPrint can be passed here without an extra dup.
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<kanban_task><success>false</success><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></kanban_task>");
    return try xml.toOwnedSlice(allocator);
}

/// Generate the success XML response.
fn successXml(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    column_id: []const u8,
    position: i64,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<kanban_task><success>true</success>");

    try xml.appendSlice(allocator, "<task_id>");
    const eid = try xmlEscape(allocator, task_id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "</task_id>");

    try xml.appendSlice(allocator, "<column_id>");
    const ecid = try xmlEscape(allocator, column_id);
    defer allocator.free(ecid);
    try xml.appendSlice(allocator, ecid);
    try xml.appendSlice(allocator, "</column_id>");

    var pos_buf: [32]u8 = undefined;
    const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{position}) catch "0";
    try xml.appendSlice(allocator, "<position>");
    try xml.appendSlice(allocator, pos_str);
    try xml.appendSlice(allocator, "</position>");

    try xml.appendSlice(allocator, "</kanban_task>");
    return try xml.toOwnedSlice(allocator);
}

/// Verify the parent `workspace_items` row exists and has
/// `item_type='kanban'`. Returns null on success, or an error XML
/// string when the parent isn't a kanban (or doesn't exist).
fn validateItemTypeIsKanban(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) !?[]u8 {
    var q = db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &[_][]const u8{item_id},
    ) catch {
        const msg = try std.fmt.allocPrint(allocator,
            "item_id '{s}' does not exist in workspace_items",
            .{item_id},
        );
        defer allocator.free(msg);
        return try errorXml(allocator, msg);
    };
    defer q.deinit();

    const row_opt = q.next() catch null;
    if (row_opt) |row| {
        defer row.deinit(allocator);
        const item_type = row.values[0];
        if (std.mem.eql(u8, item_type, "kanban")) return null;
        const msg = try std.fmt.allocPrint(allocator,
            "item_id '{s}' has item_type='{s}', not 'kanban'. create_kanban_task only works on kanban items — pick the kanban item marked *(this task)* in the Workspace Context.",
            .{ item_id, item_type },
        );
        defer allocator.free(msg);
        return try errorXml(allocator, msg);
    }

    const msg = try std.fmt.allocPrint(allocator,
        "item_id '{s}' does not exist in workspace_items",
        .{item_id},
    );
    defer allocator.free(msg);
    return try errorXml(allocator, msg);
}

/// Validate that a target column exists. Returns null on success, or an
/// XML error message (matches the `validateItemTypeIsKanban` convention)
/// on failure. Caller uses `if (try resolveTargetColumnId(...)) |err| return err;`.
fn resolveTargetColumnId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
    input_column_id: ?[]const u8,
) !?[]u8 {
    if (input_column_id) |cid| {
        var q = db.query(allocator,
            "SELECT 1 FROM kanban_columns WHERE id = ? AND workspace_item_id = ?",
            &.{ cid, item_id },
        ) catch {
            const msg = try std.fmt.allocPrint(allocator,
                "DB query failed while resolving column_id '{s}'",
                .{cid},
            );
            defer allocator.free(msg);
            return try errorXml(allocator, msg);
        };
        defer q.deinit();

        const row_opt = q.next() catch null;
        if (row_opt) |row| {
            row.deinit(allocator);
            return null;
        }

        const msg = try std.fmt.allocPrint(allocator,
            "column_id '{s}' does not exist in this kanban item. Call kanban_list first to discover the column ids, or omit column_id to auto-assign.",
            .{cid},
        );
        defer allocator.free(msg);
        return try errorXml(allocator, msg);
    }

    // No explicit column — pick the first by position ASC.
    var q = db.query(allocator,
        "SELECT 1 FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1",
        &[_][]const u8{item_id},
    ) catch {
        const msg = try std.fmt.allocPrint(allocator,
            "DB query failed while looking up first column for item '{s}'",
            .{item_id},
        );
        defer allocator.free(msg);
        return try errorXml(allocator, msg);
    };
    defer q.deinit();

    const row_opt = q.next() catch null;
    if (row_opt) |row| {
        row.deinit(allocator);
        return null;
    }

    const msg = try std.fmt.allocPrint(allocator,
        "kanban item '{s}' has zero columns — cannot auto-assign. The kanban may be in an inconsistent state (create_kanban requires at least one column).",
        .{item_id},
    );
    defer allocator.free(msg);
    return try errorXml(allocator, msg);
}

/// Fetch the actual column id (assumes `resolveTargetColumnId` returned
/// null). Heap-owned; caller frees via `defer allocator.free`.
fn fetchTargetColumnId(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
    input_column_id: ?[]const u8,
) ![]u8 {
    if (input_column_id) |cid| {
        return try allocator.dupe(u8, cid);
    }

    var q = try db.query(allocator,
        "SELECT id FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1",
        &[_][]const u8{item_id},
    );
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

/// Compute the next position for a column = `MAX(kanban_position) + 1`.
/// Returns 0 when the column is empty. Falls back to 0 on DB error.
fn computeNextPosition(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    column_id: []const u8,
) i64 {
    var q = db.query(allocator,
        "SELECT COALESCE(MAX(k.kanban_position), -1) + 1 FROM kanban k WHERE k.kanban_column_id = ?",
        &[_][]const u8{column_id},
    ) catch return 0;
    defer q.deinit();

    const row_opt = q.next() catch null;
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return std.fmt.parseInt(i64, row.values[0], 10) catch 0;
    }
    return 0;
}

/// Execute the tool. Returns an XML string for the LLM.
pub fn executeCreateKanbanTaskToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: CreateKanbanTaskInput,
) ![]u8 {
    // 1. Validate required fields.
    if (input.workspace_id.len == 0) {
        return errorXml(allocator, "workspace_id is required (pass it from the Workspace Context listing)");
    }
    if (input.item_id.len == 0) {
        return errorXml(allocator, "item_id is required (pass the kanban item's id from the Workspace Context listing)");
    }
    const trimmed_name = std.mem.trim(u8, input.name, " \t\n\r");
    if (trimmed_name.len == 0) {
        return errorXml(allocator, "name is required and must be non-empty after trim");
    }

    // 2. Validate parent item_type='kanban'.
    if (try validateItemTypeIsKanban(allocator, db, input.item_id)) |err_xml| {
        return err_xml;
    }

    // 3. Resolve target column BEFORE inserting — if invalid, we
    //    must not have created the task row yet.
    if (try resolveTargetColumnId(allocator, db, input.item_id, input.column_id)) |err_xml| {
        return err_xml;
    }
    const target_column_id = try fetchTargetColumnId(allocator, db, input.item_id, input.column_id);
    defer allocator.free(target_column_id);

    // 4. Validate tags (Migration 067) — JSON-encoded array string.
    //    The validator returns a heap-allocated, normalized
    //    JSON-encoded array string (or "" for "no tags"). On any
    //    validation failure (non-array, empty tag, illegal chars,
    //    >50 chars, etc.) we surface a structured error to the LLM.
    const validated_tags = tags_validation.validateAndNormalizeTags(
        allocator,
        input.tags,
    ) catch |err| {
        // errorXmlOwned takes ownership of `msg` — do NOT also
        // `defer allocator.free(msg)` (would be a double-free).
        const msg = std.fmt.allocPrint(allocator,
            "tags validation failed: {s}. tags must be a JSON-encoded array of strings — letters/digits/`_`/`-` only, ≤50 chars per tag, e.g. \"[\\\"bug\\\",\\\"urgent\\\"]\".",
            .{@errorName(err)},
        ) catch return errorXml(allocator, "Out of memory while formatting tags validation error");
        return try errorXmlOwned(allocator, msg);
    };
    defer allocator.free(validated_tags);

    // 5. Validate image_urls (Migration 069) — `||`-delimited
    //    data:image/<mime>;base64,... URLs. The validator returns
    //    the input borrowed (no allocation); we just check it.
    const validated_image_urls = image_urls_validation.validateImageUrls(
        input.image_urls orelse "",
    ) catch |err| switch (err) {
        error.ImageUrlsTooLarge => {
            return errorXml(allocator, "image_urls payload too large (max 10 MB)");
        },
        error.InvalidImageUrl => {
            return errorXml(allocator, "image_urls must be `||`-delimited data:image/<mime>;base64,... URLs");
        },
    };

    // 6. Validate cwd (Migration 070) — absolute path string,
    //    ≤4 KiB, no control chars. Matches the HTTP handler's
    //    inline block at `task_create.zig:421-435`. Empty/null
    //    means cwd-less (DEFAULT '' applies).
    const validated_cwd = blk: {
        const raw = input.cwd orelse "";
        if (raw.len == 0) break :blk raw;
        if (raw.len > 4096) return errorXml(allocator, "cwd path too long (max 4 KiB)");
        if (raw[0] != '/') return errorXml(allocator, "cwd must be an absolute path (start with `/`)");
        for (raw) |c| {
            if (c < 0x20 or c == 0x7f) return errorXml(allocator, "cwd contains a control character");
        }
        break :blk raw;
    };

    // 7. Generate task id.
    const timestamp_ns = nalarcore.helpers.unixTimestampNanos();
    const task_id = std.fmt.allocPrint(allocator, "task_{d}", .{timestamp_ns}) catch {
        return errorXml(allocator, "Out of memory while generating task id");
    };
    defer allocator.free(task_id);

    // 8. INSERT task row.
    const task = nalarcore.ai_mod.llm_history.createWorkspaceItemTask(
        allocator,
        db,
        task_id,
        trimmed_name,
        input.item_id,
        "standard",
        input.description,
        // Migration 067 — tags. Pass `""` (not null) when no tags
        // so the SQL `''` literal is bound (the dynamic-SQL builder
        // at `llm_history.zig:4047-4056` maps null → omitted
        // (DEFAULT ''), "" → SQL '' literal (canonical sentinel),
        // and a non-empty validated JSON array string → bound `?`.
        // Both null and "" produce the same on-disk value (`''`),
        // so passing `""` here is unambiguous.
        if (validated_tags.len == 0) "" else validated_tags,
        // Migration 069 — image_urls. Same pattern: "" sentinel for
        // no images; validated `||`-joined string when supplied.
        if (validated_image_urls.len == 0) "" else validated_image_urls,
        // Migration 070 — per-task cwd override. Borrowed from the
        // validated block above; empty string stays empty.
        validated_cwd,
    ) catch {
        // NOTE: do NOT `defer allocator.free(msg)` here — `errorXmlOwned`
        // takes ownership of `msg` and frees it on success. The previous
        // `defer free` before `errorXmlOwned` was a latent double-free
        // that fired only when the INSERT actually failed; my changes to
        // pass `""` instead of `null` for tags/image_urls/cwd made this
        // path reachable from the happy-path tests (the test schema was
        // missing the new columns). Ownership now lives entirely with
        // `errorXmlOwned`.
        const msg = std.fmt.allocPrint(allocator,
            "Failed to INSERT task row into workspace_item_tasks",
            .{},
        ) catch return errorXml(allocator, "Out of memory");
        return try errorXmlOwned(allocator, msg);
    };
    defer task.deinit(allocator);

    // 9. Compute position + UPDATE kanban fields.
    const position = computeNextPosition(allocator, db, target_column_id);
    const position_str = std.fmt.allocPrint(allocator, "{d}", .{position}) catch "0";
    defer allocator.free(position_str);
    db.exec(allocator,
        "INSERT OR REPLACE INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (?, ?, ?)",
        &[_][]const u8{ task_id, target_column_id, position_str },
    ) catch |err| {
        std.log.warn("create_kanban_task: kanban auto-assign failed (non-fatal): {s}", .{@errorName(err)});
    };

    // 10. Stamp last_human_touched_at (Migration 065) — mirrors
    //     `task_create.zig:467-469`. Fire-and-forget; without it
    //     the new card would show "awaiting review" until the user
    //     manually interacts with it.
    nalarcore.ai_mod.llm_history.updateTaskLastHumanTouchedAt(
        allocator,
        db,
        task_id,
        null,
    ) catch |err| {
        std.log.warn("create_kanban_task: stamp last_human_touched_at failed (non-fatal): {s}", .{@errorName(err)});
    };

    // 11. INSERT OR IGNORE INTO `sessions` when unattended mode
    //     and/or profile are set (Migrations 063 + 040). Uses the
    //     same `task.id == session.id` convention as the HTTP
    //     handler at `task_create.zig:587-605` so downstream SELECTs
    //     that join `sessions` see a consistent id pair.
    //     Dynamic SQL builder: include only the columns that have
    //     a value so an empty `is_auto_retry_until_stop` + empty
    //     `selected_profile_model` produces a minimal row that
    //     still satisfies the (id, name) uniqueness on concurrent
    //     chat-spawn INSERTs.
    //
    //     NEW (plan: docs/superpowers/plans/2026-08-13-kanban-task-
    //     session-name-match.md): `sessions.name` is bound to
    //     `trimmed_name` (NOT `task_id`), so the sidebar / chat
    //     header / kanban card all show the user-facing title the
    //     user typed. The `task.id == session.id` convention still
    //     holds for the id column; only the name differs. trimmed_name
    //     is already non-empty after the step-1 validation, so this
    //     is safe.
    if (input.is_auto_retry_until_stop != null or (input.selected_profile_model != null and input.selected_profile_model.?.len > 0)) {
        var cols_buf: std.ArrayList(u8) = .empty;
        defer cols_buf.deinit(allocator);
        var vals_buf: std.ArrayList(u8) = .empty;
        defer vals_buf.deinit(allocator);
        var bind_values: std.ArrayList([]const u8) = .empty;
        defer bind_values.deinit(allocator);

        try cols_buf.appendSlice(allocator, "(id, name, status");
        try vals_buf.appendSlice(allocator, "(?, ?, 'active'");
        try bind_values.append(allocator, task_id); // id
        try bind_values.append(allocator, trimmed_name); // name = user-facing title

        if (input.is_auto_retry_until_stop) |flag| {
            const normalized: []const u8 = if (std.mem.eql(u8, flag, "1")) "1" else "0";
            try cols_buf.appendSlice(allocator, ", is_auto_retry_until_stop");
            try vals_buf.appendSlice(allocator, ", ?");
            try bind_values.append(allocator, normalized);
        }

        if (input.selected_profile_model) |profile| {
            if (profile.len > 0) {
                try cols_buf.appendSlice(allocator, ", selected_profile_model");
                try vals_buf.appendSlice(allocator, ", ?");
                try bind_values.append(allocator, profile);
            }
        }

        try cols_buf.appendSlice(allocator, ")");
        try vals_buf.appendSlice(allocator, ")");

        const sql = std.fmt.allocPrint(allocator, "INSERT OR IGNORE INTO sessions {s} VALUES {s}", .{
            cols_buf.items,
            vals_buf.items,
        }) catch {
            std.log.warn("create_kanban_task: allocPrint session SQL failed (non-fatal)", .{});
            return successXml(allocator, task_id, target_column_id, position);
        };
        defer allocator.free(sql);

        db.exec(allocator, sql, bind_values.items) catch |err| {
            std.log.warn("create_kanban_task: session INSERT for unattended/profile failed (non-fatal): {s}", .{@errorName(err)});
        };
    }

    // 12. Emit SSE event.
    nalarcore.ai_mod.on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "created",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .task_id = task_id,
        .new_column_id = target_column_id,
        .new_position = position,
    }) catch |err| {
        std.log.warn("create_kanban_task: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
    };

    // 13. Return success XML.
    return successXml(allocator, task_id, target_column_id, position);
}