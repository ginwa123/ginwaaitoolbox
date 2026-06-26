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
/// `src/ai_workflow/tui/build_messages_for_agent_prompt.zig`). The
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
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it explicitly
/// says the workspace_id + item_id come from the active chat's
/// workspace context.
pub const kanban_list_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "kanban_list",
        .description =
            \\List the structure of a kanban board: all columns (with their task counts) and all tasks (with their column assignment + position). Use this tool when the user asks about the state of a kanban board, asks "what's in the done column?", or wants to discover a task's id before calling kanban_move_task.
            \\
            \\The workspace_id and item_id parameters must come from the chat context — see the "## Workspace Context" section of the system prompt. Each sibling item is rendered as `- **<name>** (id: <id>, item_type: <type>, path: <path>)` where the id is a backtick-quoted id (e.g. item_1782313125507292140). The id is the **canonical** lookup key — do NOT pass the human-readable name (e.g. "kanban feature"); the DB columns are indexed by id and a name lookup returns zero rows. The kanban item the user is currently viewing is the one marked with `*(this task)*` (it is the parent of the active chat's task).
            \\
            \\If the system prompt does not include a "## Workspace Context" section, ask the user for the kanban's id (the one they want to list). The optional `column_id` parameter narrows the task list to one column (use kanban_list first to discover column ids, or call without it to get all tasks).
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
            },
            .required = &.{ "workspace_id", "item_id" },
        },
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
pub fn listKanbanTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]KanbanTaskRow {
    var q = try db.query(allocator,
        \\SELECT t.id, t.name, COALESCE(t.kanban_column_id, ''), COALESCE(t.kanban_position, -1)
        \\FROM workspace_item_tasks t
        \\WHERE t.workspace_item_id = ?
        \\ORDER BY t.kanban_column_id ASC, t.kanban_position ASC, t.id ASC
    , &.{workspace_item_id});
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

    // 5. Read tasks (sorted by (column_id, position)).
    const task_rows = listKanbanTasks(allocator, db, input.item_id) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: listTasks failed: {s}", .{@errorName(err)}));
    };
    defer freeKanbanTaskRows(allocator, task_rows);

    // 6. Build column summary array (with task_count computed from
    //    the task rows we just read — no second DB roundtrip).
    var column_summaries = std.ArrayList(ColumnSummary).empty;
    defer column_summaries.deinit(allocator);
    for (cols) |c| {
        var count: u32 = 0;
        for (task_rows) |t| {
            if (t.kanban_column_id.len > 0 and std.mem.eql(u8, t.kanban_column_id, c.id)) {
                count += 1;
            }
        }
        try column_summaries.append(allocator, .{
            .id = c.id,
            .name = c.name,
            .position = c.position,
            .task_count = count,
        });
    }

    // 7. Build task summary array. Filter to the requested column_id
    //    when input.column_id is non-null. Each task gets
    //    column_id + column_name (or both null when unassigned).
    //
    // We allocate a fresh `filtered_list` (when filtering) OR pass
    // through `task_rows` (when not). Track the filtered_list
    // separately so the defer can free it WITHOUT touching
    // task_rows (which has its own defer that frees the
    // underlying rows + slice).
    var filtered_list: ?[]KanbanTaskRow = null;
    defer if (filtered_list) |fl| allocator.free(fl);

    const filtered: []const KanbanTaskRow = if (input.column_id) |cid| blk: {
        const fl = try allocator.alloc(KanbanTaskRow, task_rows.len);
        var n: usize = 0;
        for (task_rows) |t| {
            if (t.kanban_column_id.len > 0 and std.mem.eql(u8, t.kanban_column_id, cid)) {
                fl[n] = t;
                n += 1;
            }
        }
        filtered_list = fl;
        break :blk fl[0..n];
    } else task_rows;

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

    // 8. Render the XML. When the kanban has no columns, append the
    //    friendly hint inside the root <kanban>...</kanban> wrapper
    //    (NOT as <error>) so the LLM can distinguish "wrong item_id"
    //    from "empty board".
    const xml = try toXml(allocator, input.workspace_id, input.item_id, column_summaries.items, task_summaries.items);
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
