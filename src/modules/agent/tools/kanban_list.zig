const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// One column summary row in the kanban tool output. Mirrors
/// `kanban_model.KanbanColumn` field-for-field so the LLM sees the
/// same shape it would see from the HTTP endpoint (minus the
/// `created_at` audit field, which the LLM doesn't need).
pub const ColumnSummary = struct {
    id: []const u8,
    name: []const u8,
    position: i64,
    /// Number of tasks currently in this column. Computed from the
    /// task list (1 query each, joined client-side) so the LLM can
    /// answer "is anything in 'done'?" without a follow-up tool call.
    task_count: u32,
};

/// One task summary row in the kanban tool output. `column_id` and
/// `column_name` are null when the task is unassigned (its column
/// was deleted — see `kanban_model.deleteColumn` which sets
/// `kanban_column_id = NULL`).
pub const TaskSummary = struct {
    id: []const u8,
    name: []const u8,
    column_id: ?[]const u8,
    column_name: ?[]const u8,
    position: i64,
};

/// One task row read directly from the DB. `kanban_column_id` may be
/// an empty string when the task is unassigned (the DB column is
/// nullable). Internal — freed with `freeKanbanTaskRows`.
pub const KanbanTaskRow = struct {
    id: []u8,
    name: []u8,
    kanban_column_id: []u8,
    kanban_position: i64,
};

pub fn freeKanbanTaskRows(allocator: std.mem.Allocator, rows: []KanbanTaskRow) void {
    for (rows) |r| {
        allocator.free(r.id);
        allocator.free(r.name);
        allocator.free(r.kanban_column_id);
    }
    allocator.free(rows);
}

/// Input structure for kanban_list tool.
///
/// The agent should pass `workspace_id` + `item_id` from the active
/// chat context (injected by the frontend into the system prompt —
/// see `BuildWorkspaceContext` in
/// `src/ai_workflow/tui/prompts_build_messages_for_agent_prompt.zig`). The
/// LLM is told in the description that the active kanban is
/// discoverable from the chat's workspace context.
pub const KanbanListInput = struct {
    /// The workspace that owns the kanban item. Injected from chat
    /// context (the "active workspace_id" in the system prompt's
    /// `## Workspace Context` section).
    workspace_id: []const u8 = "",
    /// The kanban workspace item id. Injected from chat context when
    /// the user is viewing a kanban.
    item_id: []const u8 = "",
    /// Optional: when set, only return tasks assigned to this column.
    /// Useful for "list tasks in 'done' column" queries.
    column_id: ?[]const u8 = null,
    /// Optional: max tasks to return. Default 20, max 100. Use with offset for pagination.
    limit: ?u32 = null,
    /// Optional: offset for pagination. Default 0. Use with limit to page through large boards.
    offset: ?u32 = null,
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it explicitly
/// says the workspace_id + item_id come from the active chat's
/// workspace context.
pub const kanban_list_tool_system_prompt =
    \\## Kanban List Tool — Behavior
    \\Use `kanban_list` to list kanban board structure: columns and tasks.
    \\- Call first to discover `task_id` and `column_id` before moving a task.
    \\- Requires `workspace_id` + `item_id` from Workspace Context.
    \\
;

pub const kanban_list_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "kanban_list",
        .description =
            \\List the structure of a kanban board: all columns (with their task counts) and all tasks (with their column assignment + position). Use this tool when the user asks about the state of a kanban board, asks "what's in the done column?", or wants to discover a task's id before calling kanban_move_task.
            \\
            \\The workspace_id and item_id parameters must come from the chat context — see the "## Workspace Context" section of the system prompt. Each sibling item is rendered as `- **<name>** (id: <id>, item_type: <type>, path: <path>)` where the id is a backtick-quoted id (e.g. item_1782313125507292140). The id is the **canonical** lookup key — do NOT pass the human-readable name (e.g. "kanban feature"); the DB columns are indexed by id and a name lookup returns zero rows. The kanban item the user is currently viewing is the one marked with `*(this task)*` (it is the parent of the active chat's task).
            \\
            \\If the system prompt does not include a "## Workspace Context" section, ask the user for the kanban's id (the one they want to list). The optional `column_id` parameter narrows the task list to one column (use kanban_list first to discover column ids, or call without it to get all tasks). Pagination: `limit` (default 20, max 100) and `offset` (default 0) control how many tasks are returned. Large boards are truncated — check `total_count` and `has_more` in the response to paginate.
            ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "workspace_id",
                    .type = "string",
                    .description = "The workspace that owns the kanban. Should match the active workspace_id in the system prompt's `## Workspace Context` section.",
                },
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The kanban workspace item id (NOT the name). Find it next to the literal text `id: ` followed by a backtick-quoted id (e.g. item_1782313125507292140) in the Workspace Context listing — pass the value between the backticks, not the human-readable item name.",
                },
                .{
                    .name = "column_id",
                    .type = "string",
                    .description = "Optional: only return tasks in this specific column. Omit to get all tasks across all columns.",
                },
                .{
                    .name = "limit",
                    .type = "integer",
                    .description = "Optional: max tasks to return. Default 20, max 100. Use with offset for pagination.",
                },
                .{
                    .name = "offset",
                    .type = "integer",
                    .description = "Optional: offset for pagination. Default 0. Use with limit to page through large boards.",
                },
            },
            .required = &.{ "workspace_id", "item_id" },
        },
        .system_prompt = kanban_list_tool_system_prompt,
    },
};

/// Escape XML special characters. Mirrors the helper in
/// list_memory.zig / list_skills.zig (duplicated locally to keep the
/// tool file self-contained).
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

/// Read all tasks for a kanban item from the DB. Includes
/// `kanban_column_id` + `kanban_position` (the HTTP endpoint
/// `GET /tasks` does NOT include these — see project memory
/// `nalar-image-urls-vs-image-url` for the parallel image_url
/// situation). The list is ordered by (column_id, position) so the
/// LLM sees tasks in board-reading order.
///
/// Caller owns the returned slice and must release it with
/// `freeKanbanTaskRows`.
pub fn countKanbanTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: ?[]const u8,
) !u32 {
    if (column_id) |cid| {
        var q = try db.query(allocator,
            \\SELECT COUNT(*)
            \\FROM workspace_item_tasks t
            \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
            \\WHERE t.workspace_item_id = ? AND k.kanban_column_id = ?
        , &.{ workspace_item_id, cid });
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        }
        return 0;
    } else {
        var q = try db.query(allocator,
            \\SELECT COUNT(*)
            \\FROM workspace_item_tasks t
            \\WHERE t.workspace_item_id = ?
        , &.{workspace_item_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            return std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        }
        return 0;
    }
}

pub fn listKanbanTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: ?[]const u8,
    limit: ?u32,
    offset: ?u32,
) ![]KanbanTaskRow {
    // Build query with optional column filter + pagination
    var q = if (column_id) |cid| blk: {
        if (limit) |lim| {
            const off = offset orelse 0;
            var lim_buf: [16]u8 = undefined;
            var off_buf: [16]u8 = undefined;
            const lim_str = std.fmt.bufPrint(&lim_buf, "{d}", .{lim}) catch "20";
            const off_str = std.fmt.bufPrint(&off_buf, "{d}", .{off}) catch "0";
            break :blk try db.query(allocator,
                \\SELECT t.id, t.name, COALESCE(k.kanban_column_id, ''), COALESCE(k.kanban_position, -1)
                \\FROM workspace_item_tasks t
                \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
                \\WHERE t.workspace_item_id = ? AND k.kanban_column_id = ?
                \\ORDER BY k.kanban_column_id ASC, k.kanban_position ASC, t.id ASC
                \\LIMIT ? OFFSET ?
            , &.{ workspace_item_id, cid, lim_str, off_str });
        } else {
            break :blk try db.query(allocator,
                \\SELECT t.id, t.name, COALESCE(k.kanban_column_id, ''), COALESCE(k.kanban_position, -1)
                \\FROM workspace_item_tasks t
                \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
                \\WHERE t.workspace_item_id = ? AND k.kanban_column_id = ?
                \\ORDER BY k.kanban_column_id ASC, k.kanban_position ASC, t.id ASC
            , &.{ workspace_item_id, cid });
        }
    } else blk: {
        if (limit) |lim| {
            const off = offset orelse 0;
            var lim_buf: [16]u8 = undefined;
            var off_buf: [16]u8 = undefined;
            const lim_str = std.fmt.bufPrint(&lim_buf, "{d}", .{lim}) catch "20";
            const off_str = std.fmt.bufPrint(&off_buf, "{d}", .{off}) catch "0";
            break :blk try db.query(allocator,
                \\SELECT t.id, t.name, COALESCE(k.kanban_column_id, ''), COALESCE(k.kanban_position, -1)
                \\FROM workspace_item_tasks t
                \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
                \\WHERE t.workspace_item_id = ?
                \\ORDER BY k.kanban_column_id ASC, k.kanban_position ASC, t.id ASC
                \\LIMIT ? OFFSET ?
            , &.{ workspace_item_id, lim_str, off_str });
        } else {
            break :blk try db.query(allocator,
                \\SELECT t.id, t.name, COALESCE(k.kanban_column_id, ''), COALESCE(k.kanban_position, -1)
                \\FROM workspace_item_tasks t
                \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
                \\WHERE t.workspace_item_id = ?
                \\ORDER BY k.kanban_column_id ASC, k.kanban_position ASC, t.id ASC
            , &.{workspace_item_id});
        }
    };
    defer q.deinit();

    var rows = std.ArrayList(KanbanTaskRow).empty;
    errdefer {
        for (rows.items) |r| {
            allocator.free(r.id);
            allocator.free(r.name);
            allocator.free(r.kanban_column_id);
        }
        rows.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        const pos = std.fmt.parseInt(i64, row.values[3], 10) catch -1;
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .kanban_column_id = try allocator.dupe(u8, row.values[2]),
            .kanban_position = pos,
        });
    }
    return try rows.toOwnedSlice(allocator);
}

/// Resolve a column name to its id via a case-insensitive trimmed
/// match. Returns the first match or null. Used by
/// `execute_kanban_list_to_string` to populate `column_name` in the
/// task summary output.
fn resolveColumnIdToName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
) !?[]u8 {
    var q = try db.query(allocator,
        "SELECT kc.name FROM kanban_columns kc WHERE kc.workspace_item_id = ? AND kc.id = ?",
        &.{ workspace_item_id, column_id },
    );
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

/// Execute the kanban_list tool. Returns an XML string for the LLM.
///
/// Response shape (the `data` field that `wrapToolOutput` puts inside
/// `<tool>...<data>...</data></tool>`):
///   <kanban>
///     <workspace_id>...</workspace_id>
///     <item_id>...</item_id>
///     <columns>
///       <column>
///         <id>...</id>
///         <name>...</name>
///         <position>...</position>
///         <task_count>...</task_count>
///       </column>
///       ...
///     </columns>
///     <tasks>
///       <task>
///         <id>...</id>
///         <name>...</name>
///         <column_id>...</column_id>     (or empty when unassigned)
///         <column_name>...</column_name> (or empty when unassigned)
///         <position>...</position>
///       </task>
///       ...
///     </tasks>
///   </kanban>
///
/// Error cases (encoded as XML so the LLM sees a structured failure):
///   - workspace_id or item_id is empty: <kanban><error>...</error></kanban>
///   - item_id has a known-wrong prefix (task_/col_/ws_): <kanban><error>...</error></kanban>
///     with a self-correcting hint pointing at the Workspace Context listing
///   - item_id is well-formed (starts with "item_") but no matching
///     workspace_item of type 'kanban' exists: <kanban><error>...</error></kanban>
///   - The kanban exists but has 0 columns: a friendly hint (NOT an error)
///     so the LLM can distinguish "wrong item_id" from "empty board"
///   - DB read failure: <kanban><error>DB: ...</error></kanban>
pub fn executeKanbanListToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: KanbanListInput,
) ![]u8 {
    // 1. Validate shape (catches task_id/col_id/ws_id passed as item_id).
    //    Returns either null (shape OK) or an owned error XML slice.
    if (try validateItemIdShape(allocator, input.item_id, input.workspace_id)) |err_xml| {
        return err_xml;
    }

    // 2. Validate the item exists in the DB AND is a kanban. The shape
    //    check above only inspects the prefix; this catches typos and
    //    cross-item-type confusion (e.g., passing a folder's item_id
    //    to kanban_list). When the item doesn't exist, return a clear
    //    error so the LLM can re-fetch the workspace context.
    const exists = itemExists(allocator, db, input.item_id) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: itemExists failed: {s}", .{@errorName(err)}));
    };
    if (!exists) {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' matches no workspace_item (or the item isn't a kanban). Verify the id from the Workspace Context listing — the active kanban (if any) is the one marked `*(this task)*`.
        , .{input.item_id}));
    }

    // 3. Read columns (sorted by position).
    const cols = nalarcore.ai_mod.kanban_model.listColumns(allocator, db, input.item_id) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: listColumns failed: {s}", .{@errorName(err)}));
    };
    defer nalarcore.ai_mod.kanban_model.freeColumns(allocator, cols);

    // 4. If the kanban is well-formed but legitimately has no columns
    //    (user deleted them all), surface that as a structured hint so
    //    the LLM can distinguish from "wrong item_id". Empty XML
    //    without this hint looks identical to the bug we're fixing.
    //    Note: NOT wrapped in <error> — the kanban is valid, just empty.
    const empty_board_hint: ?[]u8 = if (cols.len == 0) blk: {
        const h = try std.fmt.allocPrint(allocator,
            \\This kanban item has no columns (0 columns). The user may have deleted all columns, or the kanban was just created and columns haven't been seeded yet. Ask the user, or call kanban_list with a different item_id.
        , .{});
        break :blk h;
    } else null;
    defer if (empty_board_hint) |h| allocator.free(h);

    // 5. Pagination: clamp limit/offset, fetch total + page
    const effective_limit: u32 = blk: {
        const raw = input.limit orelse 20;
        if (raw == 0) break :blk 20;
        if (raw > 100) break :blk 100;
        break :blk raw;
    };
    const effective_offset: u32 = input.offset orelse 0;

    const total_count = countKanbanTasks(allocator, db, input.item_id, input.column_id) catch 0;

    // 6. Read tasks (paginated, optionally filtered by column_id)
    const task_rows = listKanbanTasks(allocator, db, input.item_id, input.column_id, effective_limit, effective_offset) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: listTasks failed: {s}", .{@errorName(err)}));
    };
    defer freeKanbanTaskRows(allocator, task_rows);

    // 7. Build column summary array (with task_count = total per column)
    var column_summaries = std.ArrayList(ColumnSummary).empty;
    defer column_summaries.deinit(allocator);
    for (cols) |c| {
        const count = countKanbanTasks(allocator, db, input.item_id, c.id) catch 0;
        try column_summaries.append(allocator, .{
            .id = c.id,
            .name = c.name,
            .position = c.position,
            .task_count = count,
        });
    }

    // 8. Build task summary array (already filtered + paginated at DB level)
    const filtered: []const KanbanTaskRow = task_rows;

    var task_summaries = std.ArrayList(TaskSummary).empty;
    defer task_summaries.deinit(allocator);
    // Track every allocated col_name so we can free them all AFTER
    // toXml() reads the task_summaries. The earlier version of this
    // code used `defer if (col_name) |n| allocator.free(n);` INSIDE
    // the for-loop, but Zig's `defer` fires at the end of the
    // iteration block — so the slice was freed BEFORE toXml was
    // called, leaving `task_summaries` with dangling pointers. The
    // AI then read freed memory (Zig debug allocator's 0xAA free-fill
    // pattern shows up in the column_name) and interpreted the
    // garbled output as "empty board". See project memory
    // `zig-slice-headers-across-defer-lifetimes.md`.
    var col_names_owned = std.ArrayList([]u8).empty;
    defer {
        for (col_names_owned.items) |n| allocator.free(n);
        col_names_owned.deinit(allocator);
    }
    for (filtered) |t| {
        const col_id: ?[]const u8 = if (t.kanban_column_id.len > 0) t.kanban_column_id else null;
        const col_name: ?[]const u8 = if (col_id) |cid| blk: {
            const name = resolveColumnIdToName(allocator, db, input.item_id, cid) catch null;
            if (name) |n| {
                col_names_owned.append(allocator, n) catch {
                    allocator.free(n);
                    break :blk @as(?[]const u8, null);
                };
            }
            break :blk if (name) |n| n else null;
        } else null;
        try task_summaries.append(allocator, .{
            .id = t.id,
            .name = t.name,
            .column_id = col_id,
            .column_name = col_name,
            .position = t.kanban_position,
        });
    }

    // 9. Render the XML with pagination metadata
    const has_more = (effective_offset + @as(u32, @intCast(task_summaries.items.len)) < total_count);
    const xml = try toXml(allocator, input.workspace_id, input.item_id, column_summaries.items, task_summaries.items, total_count, effective_limit, effective_offset, has_more);
    if (empty_board_hint) |h| {
        // Splice the hint into the closing </kanban>: insert before
        // the final tag so it lives alongside <columns> and <tasks>.
        const close_tag = "</kanban>";
        const idx = std.mem.indexOf(u8, xml, close_tag) orelse xml.len;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, xml[0..idx]);
        try out.appendSlice(allocator, "<hint>");
        const escaped_hint = try xmlEscape(allocator, h);
        defer allocator.free(escaped_hint);
        try out.appendSlice(allocator, escaped_hint);
        try out.appendSlice(allocator, "</hint>");
        try out.appendSlice(allocator, xml[idx..]);
        allocator.free(xml);
        return try out.toOwnedSlice(allocator);
    }
    return xml;
}

/// Serialize the kanban structure to an XML string for the LLM.
/// Caller owns the returned slice.
pub fn toXml(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    item_id: []const u8,
    columns: []const ColumnSummary,
    tasks: []const TaskSummary,
    total_count: u32,
    limit: u32,
    offset: u32,
    has_more: bool,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<kanban>");

    const escaped_workspace_id = try xmlEscape(allocator, workspace_id);
    defer allocator.free(escaped_workspace_id);
    try xml.appendSlice(allocator, "<workspace_id>");
    try xml.appendSlice(allocator, escaped_workspace_id);
    try xml.appendSlice(allocator, "</workspace_id>");

    const escaped_item_id = try xmlEscape(allocator, item_id);
    defer allocator.free(escaped_item_id);
    try xml.appendSlice(allocator, "<item_id>");
    try xml.appendSlice(allocator, escaped_item_id);
    try xml.appendSlice(allocator, "</item_id>");

    // Columns block
    try xml.appendSlice(allocator, "<columns>");
    for (columns) |c| {
        try xml.appendSlice(allocator, "<column>");

        const eid = try xmlEscape(allocator, c.id);
        defer allocator.free(eid);
        try xml.appendSlice(allocator, "<id>");
        try xml.appendSlice(allocator, eid);
        try xml.appendSlice(allocator, "</id>");

        const ename = try xmlEscape(allocator, c.name);
        defer allocator.free(ename);
        try xml.appendSlice(allocator, "<name>");
        try xml.appendSlice(allocator, ename);
        try xml.appendSlice(allocator, "</name>");

        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{c.position}) catch "0";
        try xml.appendSlice(allocator, "<position>");
        try xml.appendSlice(allocator, pos_str);
        try xml.appendSlice(allocator, "</position>");

        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{c.task_count}) catch "0";
        try xml.appendSlice(allocator, "<task_count>");
        try xml.appendSlice(allocator, count_str);
        try xml.appendSlice(allocator, "</task_count>");

        try xml.appendSlice(allocator, "</column>");
    }
    try xml.appendSlice(allocator, "</columns>");

    // Tasks block
    try xml.appendSlice(allocator, "<tasks>");
    for (tasks) |t| {
        try xml.appendSlice(allocator, "<task>");

        const eid = try xmlEscape(allocator, t.id);
        defer allocator.free(eid);
        try xml.appendSlice(allocator, "<id>");
        try xml.appendSlice(allocator, eid);
        try xml.appendSlice(allocator, "</id>");

        const ename = try xmlEscape(allocator, t.name);
        defer allocator.free(ename);
        try xml.appendSlice(allocator, "<name>");
        try xml.appendSlice(allocator, ename);
        try xml.appendSlice(allocator, "</name>");

        try xml.appendSlice(allocator, "<column_id>");
        if (t.column_id) |cid| {
            const e = try xmlEscape(allocator, cid);
            defer allocator.free(e);
            try xml.appendSlice(allocator, e);
        }
        try xml.appendSlice(allocator, "</column_id>");

        try xml.appendSlice(allocator, "<column_name>");
        if (t.column_name) |cn| {
            const e = try xmlEscape(allocator, cn);
            defer allocator.free(e);
            try xml.appendSlice(allocator, e);
        }
        try xml.appendSlice(allocator, "</column_name>");

        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{t.position}) catch "-1";
        try xml.appendSlice(allocator, "<position>");
        try xml.appendSlice(allocator, pos_str);
        try xml.appendSlice(allocator, "</position>");

        try xml.appendSlice(allocator, "</task>");
    }
    try xml.appendSlice(allocator, "</tasks>");

    // Pagination block
    try xml.appendSlice(allocator, "<pagination>");
    var total_buf: [32]u8 = undefined;
    const total_str = std.fmt.bufPrint(&total_buf, "{d}", .{total_count}) catch "0";
    try xml.appendSlice(allocator, "<total_count>");
    try xml.appendSlice(allocator, total_str);
    try xml.appendSlice(allocator, "</total_count>");
    var limit_buf: [32]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{limit}) catch "0";
    try xml.appendSlice(allocator, "<limit>");
    try xml.appendSlice(allocator, limit_str);
    try xml.appendSlice(allocator, "</limit>");
    var offset_buf: [32]u8 = undefined;
    const offset_str = std.fmt.bufPrint(&offset_buf, "{d}", .{offset}) catch "0";
    try xml.appendSlice(allocator, "<offset>");
    try xml.appendSlice(allocator, offset_str);
    try xml.appendSlice(allocator, "</offset>");
    try xml.appendSlice(allocator, "<has_more>");
    try xml.appendSlice(allocator, if (has_more) "true" else "false");
    try xml.appendSlice(allocator, "</has_more>");
    try xml.appendSlice(allocator, "</pagination>");
    if (has_more) {
        try xml.appendSlice(allocator, "<hint>Showing ");
        var shown_buf: [32]u8 = undefined;
        const shown_str = std.fmt.bufPrint(&shown_buf, "{d}", .{tasks.len}) catch "0";
        try xml.appendSlice(allocator, shown_str);
        try xml.appendSlice(allocator, " of ");
        try xml.appendSlice(allocator, total_str);
        try xml.appendSlice(allocator, " tasks. Call kanban_list with offset=");
        var next_buf: [32]u8 = undefined;
        const next_off = offset + limit;
        const next_str = std.fmt.bufPrint(&next_buf, "{d}", .{next_off}) catch "0";
        try xml.appendSlice(allocator, next_str);
        try xml.appendSlice(allocator, " to see more, or filter by column_id.</hint>");
    }

    try xml.appendSlice(allocator, "</kanban>");
    return try xml.toOwnedSlice(allocator);
}

/// Generate an error XML response. Used when input validation or
/// the DB read fails. Mirrors the `xmlError` pattern in
/// `set_git_worktree.zig` / `add_skill.zig`.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<kanban><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></kanban>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees
/// it on any path. Used to avoid leaks when the caller's message
/// is an `allocPrint` result (can't `defer` across a `return`).
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<kanban><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></kanban>");
    return try xml.toOwnedSlice(allocator);
}

/// Detect the three known LLM id-confusion mistakes (task_id,
/// column_id, workspace_id passed where item_id was expected). Returns
/// null when the shape looks correct, or a structured error XML
/// describing the exact mistake + the canonical id source.
///
/// This runs BEFORE the DB query so the LLM gets a fast, typed
/// error instead of a silent empty board. Empty input is also
/// caught here (mirrors the existing "workspace_id and item_id are
/// required" guard) so the LLM gets one consistent error path.
///
/// The mistake hints deliberately show the canonical id source
/// ("see Workspace Context", "item_id: `item_...`") so the LLM can
/// self-correct on the next call.
pub fn validateItemIdShape(
    allocator: std.mem.Allocator,
    item_id: []const u8,
    workspace_id: []const u8,
) !?[]u8 {
    if (item_id.len == 0 or workspace_id.len == 0) {
        return try errorXml(allocator, "workspace_id and item_id are required");
    }
    // The DB-generated ids use these prefixes (see workspace_items_create.zig's
    // generateItemId, workspace_item_tasks_create.zig, kanban_model.generateColumnId,
    // workspaces_create.zig). Anything with the wrong prefix is a shape mistake.
    if (std.mem.startsWith(u8, item_id, "task_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a TASK id (starts with 'task_'). Pass the KANBAN's item_id instead — find it next to the literal text `item_id: ` (note: NOT `id:`) in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "col_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a COLUMN id (starts with 'col_'). Pass the KANBAN's item_id instead — find it next to the literal text `item_id: ` (note: NOT `id:`) in the Workspace Context listing. The item_id always starts with 'item_'.
        , .{item_id}));
    }
    if (std.mem.startsWith(u8, item_id, "ws_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' looks like a WORKSPACE id (starts with 'ws_'). You probably swapped workspace_id and item_id. The KANBAN's item_id starts with 'item_' — find it next to the literal text `item_id: ` in the Workspace Context listing.
        , .{item_id}));
    }
    if (!std.mem.startsWith(u8, item_id, "item_")) {
        return try errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
            \\item_id '{s}' has an unrecognized prefix (expected 'item_'). Workspace-scoped tools expect a kanban item_id from the Workspace Context listing, not a free-form string.
        , .{item_id}));
    }
    return null;
}

/// Verify the item_id corresponds to a real `workspace_items` row of
/// type 'kanban'. Returns true if the row exists AND is a kanban,
/// false if it doesn't exist OR is a different item_type. Used to
/// distinguish "item_id is well-formed but doesn't exist" from
/// "item_id is well-formed, exists, but has no columns (degenerate
/// empty board)" so the LLM gets a different error message in each
/// case.
///
/// Cheap query (indexed PK lookup). Called only AFTER
/// `validateItemIdShape` passes, so we know the input has the
/// correct `item_` prefix.
fn itemExists(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    item_id: []const u8,
) !bool {
    var q = try db.query(allocator,
        "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban' LIMIT 1",
        &.{item_id});
    defer q.deinit();
    const row = try q.next();
    if (row) |r| {
        defer r.deinit(allocator);
        return true;
    }
    return false;
}

const testing = std.testing;
const kanban_list = @import("kanban_list.zig");
const kanban_model = nalarcore.ai_mod.kanban_model;
const text_normalize = @import("helpers").text_normalize;

const TOOL_PATH = "src/modules/agent/tools/kanban_list.zig";
const TOOL_REGISTRY_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig"; // legacy alias; tool_registry.zig was deleted 2026-08-06 — see plan
/// The exec function was migrated from `tool_registry.zig` to
/// `src/ai_workflow/tui/agentic_loop/tools_exec_kanban_list.zig`
/// (re-exported as `agentic_loop_mod.tools.execKanbanList`).
/// This path is where the static-contract tests now look for
/// `pub fn execKanbanList(`.
const TOOL_EXEC_PATH = "src/ai_workflow/tui/agentic_loop/tools_exec_kanban_list.zig";
/// The comptime tool list moved out of `tool_registry.zig` into
/// `src/ai_workflow/tui/agentic_loop/tools_equipped.zig` (which
/// `agentic_loop.tools.all_agent_tools` re-exports as `equips`).
/// Each entry in that comptime `tools_list` array uses the
/// trailing-comma format (`.tool_name,`) that this test grep matches.
const TOOLS_EQUIPPED_PATH = "src/ai_workflow/tui/agentic_loop/tools_equipped.zig";

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
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── Static source-check tests ────────────────────────────────────────────

test "kanban_list tool definition has correct name" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"kanban_list\"")) {
        std.debug.print("!! kanban_list.zig does not define the tool with .name = \"kanban_list\" !!\n", .{});
        return error.ToolNameMissing;
    }
}

test "kanban_list description mentions workspace context for ids" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must tell the LLM that workspace_id and item_id
    // come from the active chat's workspace context — otherwise the
    // LLM will hallucinate ids or fail to call the tool.
    if (!contains(source, "## Workspace Context") and !contains(source, "workspace_id") and !contains(source, "workspace context")) {
        std.debug.print("!! kanban_list description does not mention the workspace context for id discovery !!\n", .{});
        return error.WorkspaceContextHintMissing;
    }
}

test "kanban_list description explains WHEN to use the tool" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // The description must include a "when to use" sentence so the
    // LLM picks this tool for kanban-related queries. The user's
    // task description suggested phrases like "user mentions a
    // kanban" or "asks about task status".
    if (!contains(source, "Use this tool when")) {
        std.debug.print("!! kanban_list description does not include a 'Use this tool when' signal !!\n", .{});
        return error.WhenToUseMissing;
    }
}

test "kanban_list input struct has workspace_id + item_id fields" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "workspace_id: []const u8")) {
        std.debug.print("!! KanbanListInput is missing the 'workspace_id' field !!\n", .{});
        return error.WorkspaceIdFieldMissing;
    }
    if (!contains(source, "item_id: []const u8")) {
        std.debug.print("!! KanbanListInput is missing the 'item_id' field !!\n", .{});
        return error.ItemIdFieldMissing;
    }
}

test "kanban_list input struct supports optional column_id filter" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    // column_id is optional — used to narrow the task list to one
    // column (e.g. "what's in the done column?"). Must be nullable.
    if (!contains(source, "column_id: ?[]const u8")) {
        std.debug.print("!! KanbanListInput is missing the 'column_id: ?[]const u8' field !!\n", .{});
        return error.ColumnIdFieldMissing;
    }
}

test "kanban_list description explains the column_id filter behavior" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_PATH);
    defer allocator.free(source);
    if (!contains(source, "column_id")) {
        std.debug.print("!! kanban_list description does not mention 'column_id' (LLM won't know to use it) !!\n", .{});
        return error.ColumnIdDescriptionMissing;
    }
}

// ─── Static wiring tests ────────────────────────────────────────────────

test "tools_equipped.zig imports kanban_list module" {
    // After deduplication of `UNIFIED_TOOL_REGISTRY` (2026-08-06), the
    // registry body lives in `tools_equipped.zig` and no longer lives
    // in `tool_registry.zig`. This test now reads the imports from
    // the canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "const kanban_list_mod = nalarcore.kanban_list;")) {
        std.debug.print("!! tools_equipped.zig does not bind kanban_list_mod = nalarcore.kanban_list !!\n", .{});
        return error.KanbanListModBindingMissing;
    }
}

test "agentic_loop defines execKanbanList" {
    // After the migration to `agentic_loop/`, the exec function lives
    // in `tools_exec_kanban_list.zig` (re-exported via
    // `agentic_loop_mod.tools.execKanbanList`). The test points at
    // the new canonical home.
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOL_EXEC_PATH);
    defer allocator.free(source);
    if (!contains(source, "pub fn execKanbanList(")) {
        std.debug.print("!! tools_exec_kanban_list.zig does not define pub fn execKanbanList !!\n", .{});
        return error.ExecKanbanListMissing;
    }
}

test "UNIFIED_TOOL_REGISTRY contains kanban_list entry" {
    // The registry body moved from `tool_registry.zig` (deleted) to
    // `tools_equipped.zig` (canonical home) on 2026-08-06. The test
    // now reads from the canonical file. tools_equipped.zig imports
    // `tools = @import("tools.zig")` directly, so the `.exec` binding
    // is `tools.execKanbanList` (NOT `agentic_loop_mod.tools.execKanbanList`).
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, ".name = \"kanban_list\"")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY is missing the kanban_list name entry !!\n", .{});
        return error.RegistryNameEntryMissing;
    }
    if (!contains(source, ".exec = tools.execKanbanList")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .exec = tools.execKanbanList !!\n", .{});
        return error.RegistryExecBindingMissing;
    }
    if (!contains(source, ".tool_def = kanban_list_mod.kanban_list_tool")) {
        std.debug.print("!! UNIFIED_TOOL_REGISTRY entry is missing .tool_def = kanban_list_mod.kanban_list_tool !!\n", .{});
        return error.RegistryToolDefBindingMissing;
    }
}

test "allAgentTools comptime list contains kanban_list tool def" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TOOLS_EQUIPPED_PATH);
    defer allocator.free(source);
    if (!contains(source, "kanban_list_mod.kanban_list_tool,")) {
        std.debug.print("!! tools_equipped.zig comptime list is missing kanban_list_mod.kanban_list_tool !!\n", .{});
        return error.AllAgentToolsEntryMissing;
    }
}

test "nalarcore root.zig exposes kanban_list module" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, "src/root.zig");
    defer allocator.free(source);
    if (!contains(source, "pub const kanban_list = @import(\"modules/agent/tools/kanban_list.zig\");")) {
        std.debug.print("!! root.zig does not expose kanban_list as a top-level module !!\n", .{});
        return error.NalarcoreExportMissing;
    }
}

// ─── XML serialization behavioral tests (no DB required) ───────────────

test "toXml on empty lists produces <kanban>...</kanban>" {
    const alloc = testing.allocator;
    const cols = &[_]kanban_list.ColumnSummary{};
    const tasks = &[_]kanban_list.TaskSummary{};
    const xml = try kanban_list.toXml(alloc, "ws_1", "item_1", cols, tasks, 0, 20, 0, false);
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<kanban>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</kanban>"));
    // No <column> or <task> blocks for empty lists
    try testing.expect(!contains(xml, "<column>"));
    try testing.expect(!contains(xml, "<task>"));
}

test "toXml renders column summaries with id/name/position/task_count" {
    const alloc = testing.allocator;
    const cols = [_]kanban_list.ColumnSummary{
        .{ .id = "col_todo", .name = "todo", .position = 0, .task_count = 2 },
        .{ .id = "col_done", .name = "done", .position = 1, .task_count = 1 },
    };
    const tasks = &[_]kanban_list.TaskSummary{};
    const xml = try kanban_list.toXml(alloc, "ws_1", "item_1", &cols, tasks, 0, 20, 0, false);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<column>"));
    try testing.expect(contains(xml, "<id>col_todo</id>"));
    try testing.expect(contains(xml, "<name>todo</name>"));
    try testing.expect(contains(xml, "<task_count>2</task_count>"));
    try testing.expect(contains(xml, "<name>done</name>"));
    try testing.expect(contains(xml, "<task_count>1</task_count>"));
}

test "toXml renders task summaries with optional column_id/column_name" {
    const alloc = testing.allocator;
    const cols = &[_]kanban_list.ColumnSummary{};
    const tasks = [_]kanban_list.TaskSummary{
        .{ .id = "t_a", .name = "Task A", .column_id = "col_todo", .column_name = "todo", .position = 0 },
        .{ .id = "t_b", .name = "Task B", .column_id = null, .column_name = null, .position = -1 },
    };
    const xml = try kanban_list.toXml(alloc, "ws_1", "item_1", cols, &tasks, 2, 20, 0, false);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<task>"));
    try testing.expect(contains(xml, "<id>t_a</id>"));
    try testing.expect(contains(xml, "<name>Task A</name>"));
    try testing.expect(contains(xml, "<column_id>col_todo</column_id>"));
    try testing.expect(contains(xml, "<column_name>todo</column_name>"));
    // Unassigned task has empty <column_id>...</column_id> and
    // <column_name>...</column_name> blocks (NOT absent).
    try testing.expect(contains(xml, "<column_id></column_id>"));
    try testing.expect(contains(xml, "<column_name></column_name>"));
}

test "toXml escapes special characters in column + task names" {
    const alloc = testing.allocator;
    const cols = [_]kanban_list.ColumnSummary{
        .{ .id = "col_x", .name = "in <review>", .position = 0, .task_count = 0 },
    };
    const tasks = &[_]kanban_list.TaskSummary{};
    const xml = try kanban_list.toXml(alloc, "ws_1", "item_1", &cols, tasks, 0, 20, 0, false);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "&lt;review&gt;"));
    try testing.expect(!contains(xml, "<review>")); // ensure raw is escaped
}

test "errorXml on missing field returns <kanban><error>...</error></kanban>" {
    const alloc = testing.allocator;
    const xml = try kanban_list.errorXml(alloc, "workspace_id and item_id are required");
    defer alloc.free(xml);
    try testing.expect(std.mem.startsWith(u8, xml, "<kanban>"));
    try testing.expect(std.mem.endsWith(u8, xml, "</kanban>"));
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "workspace_id and item_id are required"));
}

// ─── DB integration behavioral tests (in-memory SQLite) ────────────────

/// Set up an in-memory SQLite with the kanban tables + a kanban
/// workspace item + 3 default columns (todo/in progress/done).
///
/// Returns the db + threaded as a value (not a pointer) so the
/// caller can `var s = try setupDb();` and pass `&s.db` to
/// non-const-`*SqliteBackend` parameters — exactly the pattern from
/// `kanban_model_test.zig`. Returns an unnamed struct so the
/// caller's `var s` infers the fields.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspaces
    try db.exec(alloc,
        \\CREATE TABLE workspaces (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT,
        \\  created_at TEXT,
        \\  updated_at TEXT
        \\)
    , &.{});
    // workspace_items
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT,
        \\  item_type TEXT,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER,
        \\  created_at TEXT,
        \\  updated_at TEXT
        \\)
    , &.{});
    // kanban_columns (mirrors Migration 051)
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  position INTEGER,
        \\  created_at TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    // workspace_item_tasks (post-Migration-072: no kanban_column_id or
    // kanban_position columns — those live in the `kanban` join table)
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_item_id TEXT,
        \\  name TEXT,
        \\  session_id TEXT,
        \\  task_type TEXT
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\  workspace_item_task_id TEXT PRIMARY KEY,
        \\  kanban_column_id TEXT NOT NULL,
        \\  kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});

    // Insert one workspace + one kanban item + 3 columns.
    try db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &.{});
    try db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('item_1', 'ws_1', 'kanban', 'Sprint board')", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_todo', 'item_1', 'todo', 0)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_ip', 'item_1', 'in progress', 1)", &.{});
    try db.exec(alloc, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_done', 'item_1', 'done', 2)", &.{});

    return .{ .db = db, .threaded = threaded };
}

test "listKanbanTasks returns all tasks with column + position" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Two tasks in todo, one in done, one unassigned.
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t1', 'item_1', 'Task 1', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t2', 'item_1', 'Task 2', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t3', 'item_1', 'Task 3', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t4', 'item_1', 'Task 4 unassigned', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'col_todo', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'col_todo', 1)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t3', 'col_done', 0)", &.{});
    // t4 has no kanban row — unassigned (the LEFT JOIN surfaces this as
    // empty kanban_column_id in the JSON output)

    const rows = try kanban_list.listKanbanTasks(alloc, &s.db, "item_1", null, null, null);
    defer kanban_list.freeKanbanTaskRows(alloc, rows);

    try testing.expectEqual(@as(usize, 4), rows.len);
    // Unassigned task has empty kanban_column_id (the COALESCE
    // maps NULL → '').
    var unassigned_found = false;
    for (rows) |r| {
        if (std.mem.eql(u8, r.id, "t4")) {
            try testing.expectEqual(@as(usize, 0), r.kanban_column_id.len);
            try testing.expectEqual(@as(i64, -1), r.kanban_position);
            unassigned_found = true;
        }
    }
    try testing.expect(unassigned_found);
}

test "executeKanbanListToString returns columns with task_count" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // 2 in todo, 1 in done.
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t1', 'item_1', 'Task 1', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t2', 'item_1', 'Task 2', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t3', 'item_1', 'Task 3', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'col_todo', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'col_todo', 1)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t3', 'col_done', 0)", &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);

    // todo has 2 tasks
    try testing.expect(contains(xml, "<id>col_todo</id>"));
    try testing.expect(contains(xml, "<name>todo</name>"));
    try testing.expect(contains(xml, "<task_count>2</task_count>"));
    // done has 1 task
    try testing.expect(contains(xml, "<id>col_done</id>"));
    try testing.expect(contains(xml, "<task_count>1</task_count>"));
    // in progress has 0 tasks
    try testing.expect(contains(xml, "<id>col_ip</id>"));
    try testing.expect(contains(xml, "<task_count>0</task_count>"));
}

test "executeKanbanListToString with column_id filter returns only that column's tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t1', 'item_1', 'Task 1', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t2', 'item_1', 'Task 2', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t3', 'item_1', 'Task 3', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'col_todo', 0)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t2', 'col_todo', 1)", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t3', 'col_done', 0)", &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .column_id = "col_todo",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);

    // Both todo tasks should appear
    try testing.expect(contains(xml, "<name>Task 1</name>"));
    try testing.expect(contains(xml, "<name>Task 2</name>"));
    // Done task should NOT appear
    try testing.expect(!contains(xml, "<name>Task 3</name>"));
}

test "executeKanbanListToString returns error XML when item_id is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "workspace_id and item_id are required"));
}

// Regression test for the use-after-free bug fixed in this branch.
// Before the fix, `defer if (col_name) |n| allocator.free(n);` inside
// the for-loop fired at the end of EACH iteration — so the col_name
// slice was freed BEFORE toXml() was called, leaving task_summaries
// with dangling pointers. The AI then read the freed memory (Zig's
// 0xAA debug-allocator free-fill pattern) and interpreted the garbled
// output as "empty board".
//
// This test inserts a task assigned to a column and asserts the
// rendered XML contains the real column_name, not 0xAA bytes.
test "executeKanbanListToString column_name is real bytes (use-after-free regression)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // setupDb() inserts 3 default columns (todo/in progress/done).
    // Add one task assigned to the "in progress" column.
    try s.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type)
        \\VALUES ('t_uaf', 'item_1', 'Task Under Test', 'standard')
    , &.{});
    try s.db.exec(alloc,
        \\INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position)
        \\VALUES ('t_uaf', 'col_ip', 0)
    , &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);

    // The task's column_name must be the literal string "in progress",
    // not freed/garbled memory. If the use-after-free bug recurs, the
    // slice would point at Zig's 0xAA free-fill pattern.
    try testing.expect(contains(xml, "<column_name>in progress</column_name>"));
    try testing.expect(contains(xml, "<id>col_ip</id>"));

    // Defensive: assert the rendered XML does NOT contain the 0xAA
    // free-fill byte (octal 252 = 0xAA). If it does, the slice
    // header is pointing at freed memory.
    try testing.expect(std.mem.indexOfScalar(u8, xml, 0xAA) == null);
}

// ─── Input validation tests (4 mistake shapes + empty-board hint) ──────

test "executeKanbanListToString returns error XML when item_id looks like a task_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // AI confused task_id (from kanban_move_task input) with item_id.
    // listColumns will silently return 0 rows; we want validation to
    // catch this BEFORE the query runs.
    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "task_1782442569739",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "item_id"));
    try testing.expect(contains(xml, "task_"));
    // Should mention the correct id source so the LLM self-corrects.
    try testing.expect(contains(xml, "item_"));
}

test "executeKanbanListToString returns error XML when item_id looks like a column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "col_1782442554112968570",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "col_"));
}

test "executeKanbanListToString returns error XML when item_id looks like a workspace_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "ws_1",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
}

test "executeKanbanListToString returns error XML when item_id matches no workspace_item" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Valid shape (starts with item_) but the row doesn't exist.
    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_does_not_exist",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<error>"));
    try testing.expect(contains(xml, "no workspace_item"));
}

test "executeKanbanListToString returns empty-board hint (not error) when item_id is valid but has no columns" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert a kanban item with NO columns (degenerate case — user
    // deleted all of them).
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('item_empty', 'ws_1', 'kanban', 'Empty board')",
        &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_empty",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    // NOT an error — the kanban genuinely has no columns. Just an
    // empty <columns> block + a friendly hint.
    try testing.expect(!contains(xml, "<error>"));
    try testing.expect(contains(xml, "<columns></columns>"));
    // Hint: "no columns" so the LLM can distinguish from a wrong-id case.
    try testing.expect(contains(xml, "no columns"));
}

test "executeKanbanListToString default limit caps at 20" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Insert 30 tasks
    for (0..30) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "t{d}", .{i}) catch "t0";
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('{s}', 'item_1', 'Task {d}', 'standard')", .{ id, i }) catch "";
        try s.db.exec(alloc, sql, &.{});
        var ksql_buf: [256]u8 = undefined;
        const ksql = std.fmt.bufPrint(&ksql_buf, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('{s}', 'col_todo', {d})", .{ id, i }) catch "";
        try s.db.exec(alloc, ksql, &.{});
    }

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    // Default limit 20 => only 20 tasks in XML, but total_count 30
    try testing.expect(contains(xml, "<total_count>30</total_count>"));
    try testing.expect(contains(xml, "<limit>20</limit>"));
    try testing.expect(contains(xml, "<has_more>true</has_more>"));
    // Count <task> blocks
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, xml[idx..], "<task>")) |pos| {
        count += 1;
        idx += pos + 6;
    }
    try testing.expectEqual(@as(usize, 20), count);
}

test "executeKanbanListToString limit=5 returns 5 tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    for (0..10) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "t{d}", .{i}) catch "t0";
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('{s}', 'item_1', 'Task {d}', 'standard')", .{ id, i }) catch "";
        try s.db.exec(alloc, sql, &.{});
        var ksql_buf: [256]u8 = undefined;
        const ksql = std.fmt.bufPrint(&ksql_buf, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('{s}', 'col_todo', {d})", .{ id, i }) catch "";
        try s.db.exec(alloc, ksql, &.{});
    }

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .limit = 5,
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<total_count>10</total_count>"));
    try testing.expect(contains(xml, "<limit>5</limit>"));
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, xml[idx..], "<task>")) |pos| {
        count += 1;
        idx += pos + 6;
    }
    try testing.expectEqual(@as(usize, 5), count);
}

test "executeKanbanListToString offset paginates" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    for (0..10) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "t{d}", .{i}) catch "t0";
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('{s}', 'item_1', 'Task {d}', 'standard')", .{ id, i }) catch "";
        try s.db.exec(alloc, sql, &.{});
        var ksql_buf: [256]u8 = undefined;
        const ksql = std.fmt.bufPrint(&ksql_buf, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('{s}', 'col_todo', {d})", .{ id, i }) catch "";
        try s.db.exec(alloc, ksql, &.{});
    }

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .limit = 5,
        .offset = 5,
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<offset>5</offset>"));
    try testing.expect(contains(xml, "<has_more>false</has_more>"));
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOf(u8, xml[idx..], "<task>")) |pos| {
        count += 1;
        idx += pos + 6;
    }
    try testing.expectEqual(@as(usize, 5), count);
}

test "executeKanbanListToString limit >100 clamped to 100" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    for (0..5) |i| {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "t{d}", .{i}) catch "t0";
        var sql_buf: [256]u8 = undefined;
        const sql = std.fmt.bufPrint(&sql_buf, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('{s}', 'item_1', 'Task {d}', 'standard')", .{ id, i }) catch "";
        try s.db.exec(alloc, sql, &.{});
        var ksql_buf: [256]u8 = undefined;
        const ksql = std.fmt.bufPrint(&ksql_buf, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('{s}', 'col_todo', {d})", .{ id, i }) catch "";
        try s.db.exec(alloc, ksql, &.{});
    }

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .limit = 200,
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<limit>100</limit>"));
}

test "executeKanbanListToString offset beyond total returns empty tasks" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc, "INSERT INTO workspace_item_tasks (id, workspace_item_id, name, task_type) VALUES ('t1', 'item_1', 'Task 1', 'standard')", &.{});
    try s.db.exec(alloc, "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('t1', 'col_todo', 0)", &.{});

    const input = kanban_list.KanbanListInput{
        .workspace_id = "ws_1",
        .item_id = "item_1",
        .limit = 10,
        .offset = 100,
    };
    const xml = try kanban_list.executeKanbanListToString(alloc, &s.db, input);
    defer alloc.free(xml);
    try testing.expect(contains(xml, "<total_count>1</total_count>"));
    try testing.expect(!contains(xml, "<task>"));
    try testing.expect(contains(xml, "<has_more>false</has_more>"));
}

