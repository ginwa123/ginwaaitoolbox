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
//!   5. UPDATE the task's `kanban_column_id` and `kanban_position`
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

/// Input structure for `create_kanban_task` tool.
///
/// The agent should pass `workspace_id` and `item_id` from the active
/// chat context (see the "## Workspace Context" section of the system
/// prompt). `name` is the card title. `description` is optional (the
/// task's tooltip text in the kanban UI). `column_id` is optional —
/// when omitted, the task is auto-assigned to the first column at
/// `MAX(kanban_position) + 1` (append-to-bottom semantics matching
/// the HTTP handler).
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
        "SELECT COALESCE(MAX(kanban_position), -1) + 1 FROM workspace_item_tasks WHERE kanban_column_id = ?",
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

    // 4. Generate task id.
    const timestamp_ns = nalarcore.helpers.unixTimestampNanos();
    const task_id = std.fmt.allocPrint(allocator, "task_{d}", .{timestamp_ns}) catch {
        return errorXml(allocator, "Out of memory while generating task id");
    };
    defer allocator.free(task_id);

    // 5. INSERT task row.
    const task = nalarcore.ai_mod.llm_history.createWorkspaceItemTask(
        allocator,
        db,
        task_id,
        trimmed_name,
        input.item_id,
        "standard",
        input.description,
        // tags — the agent tool does not yet accept tags. Pass null
        // until tags support is added to the tool surface (out of
        // scope for the kanban-tags v1 plan; the user-facing wire
        // path is the primary entry point).
        null,
        // image_urls (Migration 069) — the agent tool does not yet
        // accept images. Pass null until the tool surface grows
        // (the user-facing KanbanDetailDialog is the primary entry
        // point per the kanban-image-urls-column plan).
        null,
        // cwd (Migration 070 — kanban-cwd-session-optional plan) —
        // the agent tool does not accept per-task cwd yet. Pass
        // null (column omitted from INSERT, DEFAULT '' applies —
        // cwd-less task). Future work: surface `cwd` on the tool
        // schema so the agent can explicitly target a different
        // folder than the kanban's default. The user-facing
        // KanbanDetailDialog is the primary entry point for now.
        null,
    ) catch {
        const msg = std.fmt.allocPrint(allocator,
            "Failed to INSERT task row into workspace_item_tasks",
            .{},
        ) catch return errorXml(allocator, "Out of memory");
        defer allocator.free(msg);
        return try errorXmlOwned(allocator, msg);
    };
    defer task.deinit(allocator);

    // 6. Compute position + UPDATE kanban fields.
    const position = computeNextPosition(allocator, db, target_column_id);
    const position_str = std.fmt.allocPrint(allocator, "{d}", .{position}) catch "0";
    defer allocator.free(position_str);
    db.exec(allocator,
        "UPDATE workspace_item_tasks SET kanban_column_id = ?, kanban_position = ? WHERE id = ?",
        &[_][]const u8{ target_column_id, position_str, task_id },
    ) catch |err| {
        std.log.warn("create_kanban_task: kanban auto-assign failed (non-fatal): {s}", .{@errorName(err)});
    };

    // 7. Emit SSE event.
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

    // 8. Return success XML.
    return successXml(allocator, task_id, target_column_id, position);
}