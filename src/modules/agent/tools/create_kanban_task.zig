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
/// Required fields: `workspace_id`, `item_id`, `name`, `description`,
/// `cwd`. The agent must pass `workspace_id` and `item_id` from the
/// active chat context (see the "## Workspace Context" section of
/// the system prompt). `name` is the card title. `description` is
/// the card tooltip text (promoted from optional to required on
/// 2026-08-18 so every card has enough context for human triage).
/// `cwd` is the absolute path to the project's working directory
/// (also promoted to required on 2026-08-18 — a cwd-less LLM session
/// is useless because the agent has nothing to `bash` into).
///
/// `column_id` is optional — when omitted, the task is auto-assigned
/// to the first column at `MAX(kanban_position) + 1` (append-to-bottom
/// semantics matching the HTTP handler).
///
/// The four remaining trailing optional fields mirror the user-facing
/// `KanbanTaskDetailDialog` form so the agent can set everything the
/// human user can set when adding a card from the UI:
///   - `tags` (JSON-encoded array string like `"[\"bug\",\"urgent\"]"`)
///   - `image_urls` (`||`-delimited `data:image/...;base64,...` URLs)
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
    /// Required card description (tooltip text in the kanban UI).
    /// Must be non-empty after trim of leading/trailing whitespace —
    /// same rule as `name`. Promoted from optional to required on
    /// 2026-08-18 so the agent always records what the task is about
    /// when it creates a card (was previously allowed empty, which
    /// made the kanban card list unhelpful for human triage).
    description: []const u8 = "",
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
    /// Required per-task project root — absolute path. Must start
    /// with `/`, ≤4 KiB, no control chars. Promoted from optional
    /// to required on 2026-08-18 so the agent always has a concrete
    /// working directory to launch into (was previously allowed
    /// empty = cwd-less task; that case is still supported by the
    /// UI form `KanbanTaskDetailDialog` but the LLM tool now
    /// requires it because a cwd-less LLM session is not useful —
    /// the agent would have nothing to `bash` into).
    /// Matches the wire shape `TaskCreateRequest.cwd`.
    cwd: []const u8 = "",
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
            \\REQUIRED fields (must be non-empty): name (card title shown on the board), description (card tooltip text — promoted to required on 2026-08-18 so the kanban view always has enough context for human triage), and cwd (absolute path to the task's project root — also promoted to required on 2026-08-18; a cwd-less LLM session is useless because the agent has nothing to `bash` into). column_id is OPTIONAL — when omitted, the task is auto-assigned to the first kanban column at MAX(kanban_position)+1; when supplied, the column must belong to the same kanban item. To set a specific position, call kanban_move_task after this tool returns.
            \\
            \\Optional fields (mirror the user-facing KanbanTaskDetailDialog form, Migration 062 / 067 / 069 / 071 — all four are persisted on create, not just on chat-spawn):
            \\  - tags: JSON-encoded array string like "[\"bug\",\"urgent\"]". Letters/digits/`_`/`-` only, ≤50 chars per tag, case-insensitive dedupe. Null/empty = no tags.
            \\  - image_urls: `||`-delimited `data:image/<mime>;base64,<payload>` URLs. Null/empty = no images. 10 MB cap.
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
                    .description = "Card description / tooltip text shown in the kanban UI. REQUIRED (non-empty after trim — same rule as `name`). Promoted to required on 2026-08-18; pass a one-to-three-sentence summary of what the task is about.",
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
                    .description = "REQUIRED per-task project root as an absolute path (must start with `/`, ≤4 KiB, no control chars). Promoted to required on 2026-08-18 — the UI form (`KanbanTaskDetailDialog`) still supports cwd-less tasks, but the LLM tool now requires it because a cwd-less LLM session has no working directory for `bash`.",
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
            // Five required fields (description + cwd promoted from
            // optional on 2026-08-18). column_id, tags, image_urls,
            // is_auto_retry_until_stop, selected_profile_model remain
            // optional.
            .required = &.{ "workspace_id", "item_id", "name", "description", "cwd" },
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
    // description + cwd were promoted from optional to required on
    // 2026-08-18. Both are validated here (right after `name`) so the
    // LLM sees a structured `<error>` mentioning the missing field
    // before any DB work happens. description follows the same
    // "non-empty after trim" rule as name; cwd is checked below in
    // the existing absolute-path block (the empty-string short-
    // circuit there was removed in the same change).
    const trimmed_description = std.mem.trim(u8, input.description, " \t\n\r");
    if (trimmed_description.len == 0) {
        return errorXml(allocator, "description is required and must be non-empty after trim (one-to-three sentences about what this task is about)");
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

    // 6. Validate cwd (Migration 070, promoted to required on
    //    2026-08-18) — absolute path string, ≤4 KiB, no control
    //    chars. Matches the HTTP handler's inline block at
    //    `task_create.zig:421-435`. Pre-2026-08-18, empty/null
    //    meant cwd-less (DEFAULT '' applies) — that escape hatch
    //    was removed because a cwd-less LLM session has no
    //    working directory to launch into. The UI form
    //    (`KanbanTaskDetailDialog`) still supports cwd-less tasks;
    //    only the LLM tool requires it.
    const validated_cwd = blk: {
        const raw = input.cwd;
        if (raw.len == 0) return errorXml(allocator, "cwd is required (pass the absolute path to this task's project root — the UI form supports cwd-less tasks, but the LLM tool requires it because a cwd-less session has nothing to bash into)");
        if (raw.len > 4096) return errorXml(allocator, "cwd path too long (max 4 KiB)");
        if (raw[0] != '/') return errorXml(allocator, "cwd must be an absolute path (start with `/`)");
        for (raw) |c| {
            if (c < 0x20 or c == 0x7f) return errorXml(allocator, "cwd contains a control character");
        }
        break :blk raw;
    };

    // 7. Generate task id.
    const timestamp_ns = @import("helpers").unixTimestampNanos();
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
        // Pass `trimmed_description` (validated non-empty above) so
        // any leading/trailing whitespace the LLM accidentally added
        // doesn't leak into the stored tooltip text.
        trimmed_description,
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

const testing = std.testing;
const create_kanban_task = @import("create_kanban_task.zig");
const text_normalize = @import("helpers").text_normalize;

const TOOL_PATH = "src/modules/agent/tools/create_kanban_task.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig"; // legacy alias; tool_registry.zig was deleted 2026-08-06 — see plan
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";
const TOOL_EXEC_PATH = "src/ai_workflow/tui/agentic_loop/tools_exec_create_kanban_task.zig";

/// Read a source file from disk, relative to the project root.
/// Normalizes CRLF → LF so multi-line literal needles match even when
/// the file was checked out on Windows with autocrlf=true (see
/// `.gitattributes` + `src/helpers/text_normalize.zig` for context).
/// The returned buffer is owned by the caller (freed with `allocator.free`).
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

// ─── Static source-check tests (RED — file does not exist yet) ────────────

test "create_kanban_task tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"create_kanban_task\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig does not define the tool with .name = \"create_kanban_task\" !!\n" ++
                "   The LLM dispatch will fail to find the tool by its schema name.\n", .{},
        );
        return error.ToolNameMissing;
    }
}

test "create_kanban_task description mentions kanban + task/card" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Both substrings are required — "kanban" so the LLM scopes the
    // tool to kanban operations (matches the kanban_* prefix), and
    // "task" so the LLM recognizes the tool creates a card.
    if (!contains(source, "kanban")) {
        std.debug.print(
            "\n!! create_kanban_task description does not contain 'kanban' !!\n" ++
                "   LLM can't scope the tool to kanban contexts.\n", .{},
        );
        return error.KanbanKeywordMissing;
    }
    if (!contains(source, "task")) {
        std.debug.print(
            "\n!! create_kanban_task description does not contain 'task' !!\n" ++
                "   LLM can't recognize this as a card-creation tool.\n", .{},
        );
        return error.TaskKeywordMissing;
    }
}

test "create_kanban_task required fields are workspace_id + item_id + name + description + cwd" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The .required field MUST contain all five. Order matters
    // only for the LLM's UX hint — we match the substring regardless.
    // (description + cwd became mandatory on 2026-08-18 so the agent
    // always has enough context to actually work the task.)
    if (!contains(source, ".required = &.{ \"workspace_id\", \"item_id\", \"name\", \"description\", \"cwd\" }")) {
        std.debug.print(
            "\n!! create_kanban_task .required field is missing one of workspace_id / item_id / name / description / cwd !!\n" ++
                "   The tool must require all five; missing any one returns an undefined slice.\n", .{},
        );
        return error.RequiredFieldsMissing;
    }
}

test "create_kanban_task input struct has workspace_id + item_id + name fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The Zig struct must declare each field with the documented type.
    if (!contains(source, "workspace_id: []const u8")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'workspace_id' field !!\n",
        .{},
        );
        return error.WorkspaceIdFieldMissing;
    }
    if (!contains(source, "item_id: []const u8")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'item_id' field !!\n",
        .{},
        );
        return error.ItemIdFieldMissing;
    }
    if (!contains(source, "name: []const u8")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'name' field !!\n",
        .{},
        );
        return error.NameFieldMissing;
    }
}

test "create_kanban_task description marks column_id as optional" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must explicitly tell the LLM that column_id
    // is optional (so it knows to omit the field for auto-assign).
    if (!contains(source, "column_id")) {
        std.debug.print(
            "\n!! create_kanban_task description does not mention 'column_id' !!\n" ++
                "   LLM won't know it can omit the field for auto-assign.\n", .{},
        );
        return error.ColumnIdMentionMissing;
    }
}

test "create_kanban_task description tells LLM ids come from Workspace Context" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // Without this hint, the LLM will hallucinate ids. Matches the
    // convention in kanban_list / kanban_move_task / set_design_page.
    if (!contains(source, "## Workspace Context") and
        !contains(source, "Workspace Context") and
        !contains(source, "workspace context"))
    {
        std.debug.print(
            "\n!! create_kanban_task description does not mention Workspace Context !!\n" ++
                "   LLM will hallucinate workspace_id / item_id without this hint.\n", .{},
        );
        return error.WorkspaceContextHintMissing;
    }
}
// ─── DB integration behavioral tests (in-memory SQLite) ────────────────────
//
// These tests exercise `executeCreateKanbanTaskToString` end-to-end:
// they seed a workspace + kanban item + columns + (optionally) tasks,
// call the tool with crafted inputs, and assert on the returned XML
// + the DB state.
//
// Mirrors the pattern from `kanban_move_task_test.zig::setupDb`.
// See plan Task 3.

/// Open a fresh in-memory SQLite DB. Caller owns the returned
/// `db` + `threaded` and must `defer s.threaded.deinit();
/// defer s.db.deinit();`.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  position INTEGER,
        \\  created_at TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  task_type TEXT,
        \\  last_human_touched_at_nano INTEGER,
        \\  -- Migrations 067 / 069 / 071: the agent tool now writes
        \\  -- these columns via the new optional `tags` / `image_urls`
        \\  -- / `cwd` input fields. The schema here mirrors the
        \\  -- post-migration shape so the createWorkspaceItemTask
        \\  -- INSERT path can bind them (the dynamic-SQL builder
        \\  -- at llm_history.zig:4047-4056 emits `''` literals when
        \\  -- the caller passes `""` — which fails fast without
        \\  -- these columns present).
        \\  tags TEXT NOT NULL DEFAULT '',
        \\  image_urls TEXT NOT NULL DEFAULT '',
        \\  cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &[_][]const u8{});
    // sessions table — required for the is_auto_retry_until_stop /
    // selected_profile_model path. The agent tool does INSERT OR
    // IGNORE INTO sessions keyed by the new task's id when either
    // field is supplied (mirrors task_create.zig:587-605).
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  status TEXT,
        \\  is_auto_retry_until_stop TEXT,
        \\  selected_profile_model TEXT
        \\)
    , &[_][]const u8{});
    // Post-Migration-072: task→column mapping lives in `kanban` join table
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\  workspace_item_task_id TEXT PRIMARY KEY,
        \\  kanban_column_id TEXT NOT NULL,
        \\  kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &[_][]const u8{});

    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &[_][]const u8{});
    // Default seeded item — a kanban named 'Sprint' with 3 columns.
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) " ++
            "VALUES ('item_k1', 'ws_1', 'kanban', 'Sprint')",
        &[_][]const u8{},
    );
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_todo', 'item_k1', 'todo', 0)",
        &[_][]const u8{},
    );
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_ip', 'item_k1', 'in progress', 1)",
        &[_][]const u8{},
    );
    try db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_done', 'item_k1', 'done', 2)",
        &[_][]const u8{},
    );

    return .{ .db = db, .threaded = threaded };
}

/// Count rows in `workspace_item_tasks` matching `WHERE id = ?`.
/// Used to assert the tool inserted exactly one row.
fn taskRowExists(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, task_id: []const u8) !bool {
    var q = try db.query(alloc,
        "SELECT 1 FROM workspace_item_tasks WHERE id = ?",
        &.{task_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return false;
    defer row.deinit(alloc);
    return true;
}

/// Read the first column of the first row returned by `sql`.
/// Returns a heap-owned slice; caller frees with `alloc.free`.
/// Returns an empty slice when no row matches (NOT an error) so
/// callers can do `readColumn(...) == ""` for "row absent" assertions.
fn readColumn(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    const row = (try q.next()) orelse return try alloc.dupe(u8, "");
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

/// Extract the task_id from the success XML returned by the tool.
/// Returns the borrowed slice (no allocation).
fn extractTaskId(xml: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, xml, "<task_id>") orelse return error.MissingTaskIdTag;
    const task_id_start = start + "<task_id>".len;
    const end = std.mem.indexOf(u8, xml[task_id_start..], "</task_id>") orelse return error.MissingTaskIdCloseTag;
    return xml[task_id_start .. task_id_start + end];
}

test "executeCreateKanbanTaskToString returns success XML on happy path" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "new task",
        .description = "happy path task",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<kanban_task>"));
    try testing.expect(contains(xml, "<success>true</success>"));
    try testing.expect(contains(xml, "<task_id>"));
    try testing.expect(contains(xml, "<column_id>col_todo</column_id>"));
    try testing.expect(contains(xml, "<position>0</position>"));
    try testing.expect(!contains(xml, "<error>"));
}

test "executeCreateKanbanTaskToString inserts a row into workspace_item_tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "insert me",
        .description = "insert me desc",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    // Extract the task_id from the XML (between <task_id> and </task_id>).
    const start = std.mem.indexOf(u8, xml, "<task_id>") orelse return error.MissingTaskIdTag;
    const task_id_start = start + "<task_id>".len;
    const end = std.mem.indexOf(u8, xml[task_id_start..], "</task_id>") orelse return error.MissingTaskIdCloseTag;
    const task_id = xml[task_id_start .. task_id_start + end];

    try testing.expect(try taskRowExists(alloc, &s.db, task_id));
}

test "executeCreateKanbanTaskToString appends at MAX(kanban_position)+1 when column has existing tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Seed 2 existing tasks in the todo column at positions 0 and 1.
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) " ++
            "VALUES ('t_existing_1', 'item_k1', 'first', 'standard')",
        &[_][]const u8{},
    );
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) " ++
            "VALUES ('t_existing_2', 'item_k1', 'second', 'standard')",
        &[_][]const u8{},
    );
    try s.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) " ++
            "VALUES ('t_existing_1', 'col_todo', 0), ('t_existing_2', 'col_todo', 1)",
        &[_][]const u8{},
    );

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "third",
        .description = "third desc",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    // The first column is col_todo — position 2 should be appended.
    try testing.expect(contains(xml, "<column_id>col_todo</column_id>"));
    try testing.expect(contains(xml, "<position>2</position>"));
}

test "executeCreateKanbanTaskToString returns error when workspace_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "",
        .item_id = "item_k1",
        .name = "x",
        .description = "test desc",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "workspace_id"));
}

test "executeCreateKanbanTaskToString returns error when item_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "",
        .name = "x",
        .description = "test desc",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "item_id"));
}

test "executeCreateKanbanTaskToString returns error when name is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "",
        .description = "test desc",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "name"));
}

test "executeCreateKanbanTaskToString returns error when name is whitespace-only" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "   \t\n  ",
        .description = "test desc",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "name"));
}

// ─── description + cwd became required on 2026-08-18 ──────────────────
//
// description: must be non-empty after trim of leading/trailing whitespace.
// cwd: must be non-empty (and an absolute path — see the "rejects relative
//      cwd" test below for the format check).
//
// We add these validation tests right after the matching "name" tests so
// the three required-text-field tests live together. The order matters for
// the test runner's narrative — name first because it has been required
// longest, then description + cwd because they were promoted together.

test "executeCreateKanbanTaskToString returns error when description is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "no desc",
        .description = "",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "description"));
}

test "executeCreateKanbanTaskToString returns error when description is whitespace-only" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "whitespace desc",
        .description = "   \t\n  ",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "description"));
}

test "executeCreateKanbanTaskToString returns error when cwd is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "no cwd",
        .description = "test desc",
        .cwd = "",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "cwd"));
}

test "executeCreateKanbanTaskToString returns error when parent item_type is not kanban" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Replace the kanban item with a chat item.
    try s.db.exec(alloc,
        "UPDATE workspace_items SET item_type = 'chat' WHERE id = 'item_k1'",
        &[_][]const u8{},
    );

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "x",
        .description = "test desc",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    // The error must mention the parent type so the LLM can self-correct.
    try testing.expect(contains(xml, "kanban") or contains(xml, "item_type"));
}

test "executeCreateKanbanTaskToString returns error when kanban has zero columns" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Delete all 3 seeded columns — the kanban is now column-less.
    try s.db.exec(alloc, "DELETE FROM kanban_columns WHERE workspace_item_id = 'item_k1'", &[_][]const u8{});

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "x",
        .description = "test desc",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "column") or contains(xml, "Column"));
}

test "executeCreateKanbanTaskToString honors explicit column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "explicit placement",
        .description = "explicit placement desc",
        .cwd = "/test",
        .column_id = "col_ip",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>true</success>"));
    try testing.expect(contains(xml, "<column_id>col_ip</column_id>"));
    try testing.expect(contains(xml, "<position>0</position>"));
}

test "executeCreateKanbanTaskToString rejects column_id that does not belong to the item" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Add a column under a DIFFERENT kanban item.
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) " ++
            "VALUES ('item_k2', 'ws_1', 'kanban', 'Other Sprint')",
        &[_][]const u8{},
    );
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
            "VALUES ('col_other', 'item_k2', 'todo', 0)",
        &[_][]const u8{},
    );

    // Try to place the new task in 'col_other' while item_id points
    // to 'item_k1'. The tool must reject this — the column does not
    // belong to the item.
    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "x",
        .description = "test desc",
        .cwd = "/test",
        .column_id = "col_other",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "column") or contains(xml, "Column"));
}

// ─── New optional fields: tags / image_urls / cwd / unattended / profile ──
//
// These tests exercise the 5 new optional input fields that were added
// to mirror the user-facing KanbanTaskDetailDialog form (Migrations
// 067 / 069 / 070-071 + 063 + 040). They follow the same static + DB
// pattern as the existing tests.

test "create_kanban_task parameters include tags property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"tags\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"tags\" property !!\n" ++
                "   The LLM won't see tags in the tool schema.\n",
            .{},
        );
        return error.TagsPropertyMissing;
    }
}

test "create_kanban_task parameters include image_urls property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"image_urls\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"image_urls\" property !!\n" ++
                "   The LLM won't see image_urls in the tool schema.\n",
            .{},
        );
        return error.ImageUrlsPropertyMissing;
    }
}

test "create_kanban_task parameters include cwd property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"cwd\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"cwd\" property !!\n" ++
                "   The LLM won't see cwd in the tool schema.\n",
            .{},
        );
        return error.CwdPropertyMissing;
    }
}

test "create_kanban_task parameters include is_auto_retry_until_stop property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"is_auto_retry_until_stop\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"is_auto_retry_until_stop\" property !!\n" ++
                "   The LLM won't see the unattended flag in the tool schema.\n",
            .{},
        );
        return error.UnattendedPropertyMissing;
    }
}

test "create_kanban_task parameters include selected_profile_model property" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"selected_profile_model\"")) {
        std.debug.print(
            "\n!! create_kanban_task.zig is missing .name = \"selected_profile_model\" property !!\n" ++
                "   The LLM won't see the profile field in the tool schema.\n",
            .{},
        );
        return error.SelectedProfilePropertyMissing;
    }
}

test "create_kanban_task input struct has tags field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "tags: ?[]const u8 = null,")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'tags' field !!\n",
            .{},
        );
        return error.TagsFieldMissing;
    }
}

test "create_kanban_task input struct has image_urls field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "image_urls: ?[]const u8 = null,")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'image_urls' field !!\n",
            .{},
        );
        return error.ImageUrlsFieldMissing;
    }
}

test "create_kanban_task input struct has cwd field as required non-optional string" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "cwd: []const u8 = \"\",")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput.cwd is not a required (non-optional) string !!\n",
            .{},
        );
        return error.CwdFieldMissing;
    }
}

test "create_kanban_task input struct has is_auto_retry_until_stop field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "is_auto_retry_until_stop: ?[]const u8 = null,")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'is_auto_retry_until_stop' field !!\n",
            .{},
        );
        return error.UnattendedFieldMissing;
    }
}

test "create_kanban_task input struct has selected_profile_model field" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "selected_profile_model: ?[]const u8 = null,")) {
        std.debug.print(
            "\n!! CreateKanbanTaskInput is missing the 'selected_profile_model' field !!\n",
            .{},
        );
        return error.SelectedProfileFieldMissing;
    }
}

test "create_kanban_task source mentions tags_validation and image_urls_validation" {
    // The validators live in http_handlers/ and are imported by the
    // tool. If a refactor moves them, this test catches it.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "validateAndNormalizeTags")) {
        std.debug.print(
            "\n!! create_kanban_task.zig does not call validateAndNormalizeTags !!\n" ++
                "   Tags are not being validated.\n",
            .{},
        );
        return error.TagsValidatorCallMissing;
    }
    if (!contains(source, "validateImageUrls")) {
        std.debug.print(
            "\n!! create_kanban_task.zig does not call validateImageUrls !!\n" ++
                "   image_urls are not being validated.\n",
            .{},
        );
        return error.ImageUrlsValidatorCallMissing;
    }
    if (!contains(source, "updateTaskLastHumanTouchedAt")) {
        std.debug.print(
            "\n!! create_kanban_task.zig does not stamp last_human_touched_at !!\n" ++
                "   New cards will show 'awaiting review' until the user touches them.\n",
            .{},
        );
        return error.LastHumanTouchedStampMissing;
    }
}

// ─── DB behavior tests for new optional fields ──────────────────────────

test "executeCreateKanbanTaskToString persists tags when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "tagged",
        .description = "tagged desc",
        .cwd = "/test",
        .tags = "[\"bug\",\"urgent\"]",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT tags FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("[\"bug\",\"urgent\"]", stored);
}

test "executeCreateKanbanTaskToString persists image_urls when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "with images",
        .description = "with images desc",
        .cwd = "/test",
        .image_urls = "data:image/png;base64,abc||data:image/jpeg;base64,def",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT image_urls FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("data:image/png;base64,abc||data:image/jpeg;base64,def", stored);
}

test "executeCreateKanbanTaskToString persists cwd when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "with cwd",
        .description = "with cwd desc",
        .cwd = "/home/me/proj",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT cwd FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("/home/me/proj", stored);
}

test "executeCreateKanbanTaskToString stamps last_human_touched_at on happy path" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "stamped",
        .description = "stamped desc",
        .cwd = "/test",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT COALESCE(last_human_touched_at_nano, '') FROM workspace_item_tasks WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    // The stamp must be non-empty (a unix-ms integer string). The
    // pre-stamp default is NULL → COALESCE returns ''. After the
    // stamp it's a non-empty digit string.
    try testing.expect(stored.len > 0);
    try testing.expect(stored.len > 0 and stored[0] >= '0' and stored[0] <= '9');
}

test "executeCreateKanbanTaskToString creates sessions row when is_auto_retry_until_stop=1" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "unattended",
        .description = "unattended desc",
        .cwd = "/test",
        .is_auto_retry_until_stop = "1",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("1", stored);
}

test "executeCreateKanbanTaskToString persists selected_profile_model when supplied" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "with profile",
        .description = "with profile desc",
        .cwd = "/test",
        .selected_profile_model = "fast-model",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT selected_profile_model FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("fast-model", stored);
}

test "executeCreateKanbanTaskToString writes both unattended and profile in single sessions row" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "combined",
        .description = "combined desc",
        .cwd = "/test",
        .is_auto_retry_until_stop = "1",
        .selected_profile_model = "my-profile",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const flag = try readColumn(alloc, &s.db,
        "SELECT is_auto_retry_until_stop FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(flag);
    try testing.expectEqualStrings("1", flag);

    const profile = try readColumn(alloc, &s.db,
        "SELECT selected_profile_model FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(profile);
    try testing.expectEqualStrings("my-profile", profile);
}

// ─── Kanban task name = session name (plan: 2026-08-13-kanban-task-session-name-match.md) ──
//
// Pre-fix, the tool INSERT OR IGNORE INTO sessions keyed by task_id
// bound `name = task_id` (the literal id like "task_1786626864861"),
// while the kanban card showed the user-facing title. The sidebar
// (ChatsList / session_name) and the chat header (ChatView.chatName)
// read sessions.name and therefore displayed a different string than
// the kanban card. Post-fix the bind is `trimmed_name` so all three
// views show the same string the user typed.
//
// Behavioural regression: assert SELECT name FROM sessions WHERE id = task_id
// returns the trimmed user-facing title in both the unattended-only
// and profile-only code paths.

test "executeCreateKanbanTaskToString persists sessions.name == trimmed task name (unattended)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "workspace item task nama and session name",
        .description = "sessions.name == trimmed desc",
        .cwd = "/test",
        .is_auto_retry_until_stop = "1",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT name FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    // Pre-fix this returned task_id (the literal task id). Post-fix it
    // must equal the trimmed user-facing title.
    try testing.expectEqualStrings("workspace item task nama and session name", stored);
}

test "executeCreateKanbanTaskToString persists sessions.name == trimmed task name (profile)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        // Leading/trailing whitespace; the tool trims before INSERT
        // (see executeCreateKanbanTaskToString line 463-466), so the
        // sessions.name must be the trimmed value.
        .name = "   my chatty task   ",
        .description = "sessions.name == trimmed profile desc",
        .cwd = "/test",
        .selected_profile_model = "fast-model",
    });
    defer alloc.free(xml);

    const task_id = try extractTaskId(xml);
    const stored = try readColumn(alloc, &s.db,
        "SELECT name FROM sessions WHERE id = ?",
        &.{task_id});
    defer alloc.free(stored);
    try testing.expectEqualStrings("my chatty task", stored);
}

test "executeCreateKanbanTaskToString rejects malformed tags" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "bad tags",
        .description = "bad tags desc",
        .cwd = "/test",
        .tags = "not-a-json-array",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "tags"));
}

test "executeCreateKanbanTaskToString rejects invalid image_urls" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "bad images",
        .description = "bad images desc",
        .cwd = "/test",
        .image_urls = "not-a-data-url",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "image_urls"));
}

test "executeCreateKanbanTaskToString rejects relative cwd" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const xml = try create_kanban_task.executeCreateKanbanTaskToString(alloc, &s.db, .{
        .workspace_id = "ws_1",
        .item_id = "item_k1",
        .name = "relative",
        .description = "relative path desc",
        .cwd = "relative/path",
    });
    defer alloc.free(xml);

    try testing.expect(contains(xml, "<success>false</success>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "absolute"));
}

// ─── Registration static-contract tests (Task 7) ────────────────────────
//
// Pin the registration contract: a future refactor that drops
// `create_kanban_task` from any of the registry / re-export /
// tools_equipped surfaces would silently disable the tool. These
// tests catch that.

test "tools_equipped imports create_kanban_task module" {
    // After deduplication of `UNIFIED_TOOL_REGISTRY` (2026-08-06), the
    // registry body lives in `tools_equipped.zig` and no longer lives
    // in `tool_registry.zig`. This test now reads the imports from
    // the canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "const kanban_create_task_tool = nalarcore.create_kanban_task;")) {
        std.debug.print(
            "\n!! tools_equipped.zig does not bind create_kanban_task module !!\n",
            .{},
        );
        return error.CreateKanbanTaskModBindingMissing;
    }
}

test "agentic_loop defines execCreateKanbanTask" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execCreateKanbanTask(")) {
        std.debug.print(
            "\n!! tools_exec_create_kanban_task.zig does not define pub fn execCreateKanbanTask !!\n",
            .{},
        );
        return error.ExecCreateKanbanTaskMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains create_kanban_task entry" {
    // The registry body moved from `tool_registry.zig` (deleted) to
    // `tools_equipped.zig` (canonical home) on 2026-08-06. The test
    // now reads from the canonical file. tools_equipped.zig imports
    // `tools = @import("tools.zig")` directly, so the `.exec` binding
    // is `tools.execCreateKanbanTask` (NOT `agentic_loop_mod.tools.execCreateKanbanTask`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"create_kanban_task\"")) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY is missing the create_kanban_task name entry !!\n",
            .{},
        );
        return error.RegistryNameEntryMissing;
    }
    if (!contains(source, ".exec = tools.execCreateKanbanTask")) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execCreateKanbanTask !!\n",
            .{},
        );
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = kanban_create_task_tool.create_kanban_task_tool")) {
        std.debug.print(
            "\n!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = kanban_create_task_tool.create_kanban_task_tool !!\n",
            .{},
        );
        return error.RegistryToolDefBindingMissing;
    }
}

test "nalarcore root.zig exposes create_kanban_task module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/root.zig");
    defer allocator.free(source);
    if (!contains(source, "pub const create_kanban_task = @import(\"modules/agent/tools/create_kanban_task.zig\");")) {
        std.debug.print(
            "\n!! root.zig does not expose create_kanban_task as a top-level module !!\n",
            .{},
        );
        return error.NalarcoreExportMissing;
    }
}

test "agentic_loop tools.zig re-exports execCreateKanbanTask" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/ai_workflow/tui/agentic_loop/tools.zig");
    defer allocator.free(source);
    if (!contains(source, "execCreateKanbanTask")) {
        std.debug.print(
            "\n!! agentic_loop/tools.zig does not re-export execCreateKanbanTask !!\n",
            .{},
        );
        return error.ToolsReexportMissing;
    }
}
