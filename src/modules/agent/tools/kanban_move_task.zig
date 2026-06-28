const std = @import("std");
const schemas = @import("schemas.zig");
const AgentTool = schemas.AgentTool;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// One column found by name in the local kanban. Used by the
/// `target_column_name` resolution path so the LLM can address a
/// column by human-readable name ("done") without first calling
/// `kanban_list`. `id` is null when the column doesn't exist in the
/// board.
pub const ColumnMatch = struct {
    id: []u8,
    name: []u8,
    position: i64,
};

pub fn freeColumnMatches(allocator: std.mem.Allocator, matches: []ColumnMatch) void {
    for (matches) |m| {
        allocator.free(m.id);
        allocator.free(m.name);
    }
    allocator.free(matches);
}

/// Input structure for kanban_move_task tool.
///
/// The agent should pass `workspace_id` + `item_id` from the active
/// chat context (injected by the frontend — see Sub-task 5 of the
/// task plan). `task_id` is found via `kanban_list`. The
/// destination column is given as either `target_column_id` (exact)
/// or `target_column_name` (case-insensitive trimmed match — the
/// tool calls `kanban_list` internally to resolve it).
pub const KanbanMoveTaskInput = struct {
    /// The workspace that owns the kanban item. From chat context.
    workspace_id: []const u8 = "",
    /// The kanban workspace item id. From chat context.
    item_id: []const u8 = "",
    /// The task to move. Found via `kanban_list` (returns each
    /// task's `<id>`).
    task_id: []const u8 = "",
    /// Target column — exact id (preferred when known). The agent
    /// gets this from `kanban_list` output.
    target_column_id: ?[]const u8 = null,
    /// Target column — human-readable name (e.g. "done"). Matched
    /// case-insensitively after trim against the board's columns.
    /// When both `target_column_id` and `target_column_name` are
    /// supplied, the id wins (it's exact).
    target_column_name: ?[]const u8 = null,
    /// 0-based position within the target column. When null, the
    /// task is appended to the end (server picks a high position
    /// that the renumber will compact to last).
    position: ?i64 = null,
};

/// Top-level tool definition for the LLM. The description is the
/// agent's primary signal for WHEN to use this tool — it tells the
/// LLM to call `kanban_list` first (to find the task_id and
/// optionally the column id) and explains the name→id fallback.
pub const kanban_move_task_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "kanban_move_task",
        .description =
            \\Move a task to a different column (and/or position) on a kanban board. Use this when the user says "move the auth task to done", "put X in review", or any other instruction to relocate a task.
            \\
            \\Workflow: (1) call kanban_list first to discover the task id and the target column's id, (2) call kanban_move_task with those ids. If you only have a human-readable column name (no id), pass `target_column_name` instead of `target_column_id` — the tool resolves the name against the board's columns via a case-insensitive trimmed match.
            \\
            \\The workspace_id and item_id must come from the chat context — see the "## Workspace Context" section of the system prompt. Each sibling item is rendered as `- **<name>** (id: <id>, ...)` where the id is a backtick-quoted id (e.g. item_1782313125507292140). The id is the **canonical** lookup key — do NOT pass the human-readable name. The task_id comes from kanban_list's `<id>` field, not the task name.
            \\
            \\On error, recover by: (1) re-call kanban_list to get fresh ids (the user may have just renamed a column or moved the task); (2) if `target_column_name` matched multiple columns (case-insensitive), the move fails with a list of candidates — pass `target_column_id` to disambiguate; (3) if the task isn't on this kanban, the move fails with "TaskNotFound" — verify the task_id is correct.
            ,
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "workspace_id",
                    .type = "string",
                    .description = "The workspace that owns the kanban. From the system prompt's `## Workspace Context` section.",
                },
                .{
                    .name = "item_id",
                    .type = "string",
                    .description = "The kanban workspace item id (NOT the name). Find it next to the literal text `id: ` followed by a backtick-quoted id (e.g. item_1782313125507292140) in the Workspace Context listing — pass the value between the backticks, not the human-readable item name.",
                },
                .{
                    .name = "task_id",
                    .type = "string",
                    .description = "The task to move (id, NOT name). Found via kanban_list's `<id>` field.",
                },
                .{
                    .name = "target_column_id",
                    .type = "string",
                    .description = "Exact id of the target column. Preferred when known. From kanban_list's column `<id>` field.",
                },
                .{
                    .name = "target_column_name",
                    .type = "string",
                    .description = "Human-readable column name (e.g. 'done'). Matched case-insensitively after trim. Use ONLY when you don't have the column id — prefer target_column_id for exactness.",
                },
                .{
                    .name = "position",
                    .type = "integer",
                    .description = "0-based position within the target column. When omitted/null, the task is appended to the end of the column.",
                },
            },
            .required = &.{ "workspace_id", "item_id", "task_id" },
        },
    },
};

/// Resolve a column name to an id via a case-insensitive trimmed
/// match against the board's columns. Returns the FIRST match (or
/// an empty slice when no match). The agent is told in the
/// description to fall back to `target_column_id` when the match
/// is ambiguous (multiple columns share the same name when compared
/// case-insensitively).
///
/// Caller owns the returned slice and must release it with
/// `freeColumnMatches`.
pub fn findColumnsByName(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name_query: []const u8,
) ![]ColumnMatch {
    const cols = nalarcore.ai_mod.kanban_model.listColumns(allocator, db, workspace_item_id) catch {
        return &[_]ColumnMatch{};
    };
    defer nalarcore.ai_mod.kanban_model.freeColumns(allocator, cols);

    const query_trimmed = std.mem.trim(u8, name_query, " \t\r\n");
    var lower_buf: [256]u8 = undefined;
    const query_lower = toLowerInto(allocator, query_trimmed, &lower_buf) catch
        return &[_]ColumnMatch{};
    defer if (query_lower.ptr != lower_buf[0..].ptr) allocator.free(query_lower);

    var matches = std.ArrayList(ColumnMatch).empty;
    errdefer {
        for (matches.items) |m| {
            allocator.free(m.id);
            allocator.free(m.name);
        }
        matches.deinit(allocator);
    }

    for (cols) |c| {
        var col_buf: [256]u8 = undefined;
        const col_lower = toLowerInto(allocator, c.name, &col_buf) catch continue;
        defer if (col_lower.ptr != col_buf[0..].ptr) allocator.free(col_lower);
        if (std.mem.eql(u8, query_lower, col_lower)) {
            try matches.append(allocator, .{
                .id = try allocator.dupe(u8, c.id),
                .name = try allocator.dupe(u8, c.name),
                .position = c.position,
            });
        }
    }
    return try matches.toOwnedSlice(allocator);
}

/// Lowercase a string into a stack buffer when it fits, else heap.
/// The pointer-equality on the returned slice tells the caller
/// whether to free it. Trims nothing — the caller should trim
/// first.
fn toLowerInto(allocator: std.mem.Allocator, s: []const u8, buf: []u8) ![]const u8 {
    if (s.len > buf.len) {
        const out = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            out[i] = std.ascii.toLower(c);
        }
        return out;
    }
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..s.len];
}

/// Read a task's current column id + name from the DB. Used to
/// enrich the success response (so the LLM can confirm "the task
/// moved to column X").
fn readTaskCurrentColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    task_id: []const u8,
) !struct { column_id: []u8, column_name: []u8 } {
    var q = try db.query(allocator,
        \\SELECT COALESCE(t.kanban_column_id, ''), COALESCE(kc.name, '')
        \\FROM workspace_item_tasks t
        \\LEFT JOIN kanban_columns kc ON kc.id = t.kanban_column_id
        \\WHERE t.id = ?
    , &.{task_id});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(allocator);
        return .{
            .column_id = try allocator.dupe(u8, row.values[0]),
            .column_name = try allocator.dupe(u8, row.values[1]),
        };
    }
    return error.TaskNotFound;
}

/// Execute the kanban_move_task tool. Returns an XML string for the
/// LLM.
///
/// Response shape on success:
///   <kanban_move>
///     <success>true</success>
///     <task_id>...</task_id>
///     <task_name>...</task_name>
///     <column_id>...</column_id>
///     <column_name>...</column_name>
///     <position>...</position>
///   </kanban_move>
///
/// Response shape on error:
///   <kanban_move>
///     <success>false</success>
///     <error>...</error>
///   </kanban_move>
///
/// Common error variants (encoded as structured strings so the LLM
/// can recognize them):
///   - "Missing required field: workspace_id" (or item_id / task_id)
///   - "Need at least one of target_column_id or target_column_name"
///   - "Column not found: <name>" (name didn't match any column)
///   - "Ambiguous column name: '<name>' matches N columns — pass target_column_id"
///   - "TaskNotFound: <id>" (no row in workspace_item_tasks for task_id)
///   - "DB: moveTask failed: <error_name>"
pub fn executeKanbanMoveTaskToString(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: KanbanMoveTaskInput,
) ![]u8 {
    if (input.workspace_id.len == 0) return errorXml(allocator, "Missing required field: workspace_id");
    if (input.item_id.len == 0) return errorXml(allocator, "Missing required field: item_id");
    if (input.task_id.len == 0) return errorXml(allocator, "Missing required field: task_id");

    // Matches array (for target_column_name resolution) must outlive
    // the use of `target_column_id` (which borrows from matches[0].id).
    // Allocate it on the outer scope so its `defer free` fires AFTER
    // the slice is done being used.
    var name_matches: ?[]ColumnMatch = null;
    defer if (name_matches) |m| freeColumnMatches(allocator, m);

    const target_column_id: []const u8 = if (input.target_column_id) |cid| cid else blk: {
        const name = input.target_column_name orelse {
            return errorXml(allocator, "Need at least one of target_column_id or target_column_name");
        };
        if (name.len == 0) {
            return errorXml(allocator, "Need at least one of target_column_id or target_column_name");
        }
        const matches = findColumnsByName(allocator, db, input.item_id, name) catch |err| {
            return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: findColumnsByName failed: {s}", .{@errorName(err)}));
        };

        if (matches.len == 0) {
            freeColumnMatches(allocator, matches);
            return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "Column not found: {s}", .{name}));
        }
        if (matches.len > 1) {
            freeColumnMatches(allocator, matches);
            return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator,
                "Ambiguous column name: '{s}' matches {d} columns - pass target_column_id",
                .{ name, matches.len }));
        }
        name_matches = matches;
        break :blk matches[0].id;
    };

    // 1. Look up the task to get its name (for the success response).
    var task_name_buf: [256]u8 = undefined;
    const task_name_slice: []const u8 = blk: {
        var q = try db.query(allocator, "SELECT COALESCE(t.name, '') FROM workspace_item_tasks t WHERE t.id = ?", &.{input.task_id});
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(allocator);
            const name = row.values[0];
            if (name.len <= task_name_buf.len) {
                @memcpy(task_name_buf[0..name.len], name);
                break :blk task_name_buf[0..name.len];
            }
            break :blk try allocator.dupe(u8, name);
        }
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "TaskNotFound: {s}", .{input.task_id}));
    };
    defer if (task_name_slice.ptr != task_name_buf[0..].ptr) allocator.free(task_name_slice);

    // 2. Compute the target position. Null → end-of-column: pick
    //    a high sentinel that moveTask's sibling-shift logic will
    //    compact to last on the next move (or use a high value
    //    directly, since the renumber in step 3 of kanban_model.moveTask
    //    only shifts tasks at position >= target_position up by 1;
    //    a high value means "no siblings shift, the moved task
    //    parks at the high position, and any subsequent move into
    //    this column will re-renumber naturally").
    //
    //    We use a more explicit approach: pick MAX(existing) + 1
    //    so the move is visibly "appended" rather than "parked at
    //    sentinel 1_000_000".
    const position: i64 = input.position orelse blk: {
        var q = try db.query(allocator,
            "SELECT COALESCE(MAX(t.kanban_position), -1) + 1 FROM workspace_item_tasks t WHERE t.kanban_column_id = ?",
            &.{target_column_id},
        );
        defer q.deinit();
        const row = (try q.next()) orelse break :blk @as(i64, 0);
        defer row.deinit(allocator);
        break :blk try std.fmt.parseInt(i64, row.values[0], 10);
    };
    const position_str = try std.fmt.allocPrint(allocator, "{d}", .{position});
    defer allocator.free(position_str);

    // 3. Call kanban_model.moveTask — this handles the sibling
    //    renumber atomically.
    nalarcore.ai_mod.kanban_model.moveTask(
        allocator,
        db,
        input.item_id,
        input.task_id,
        target_column_id,
        position,
    ) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: moveTask failed: {s}", .{@errorName(err)}));
    };

    // 3a. Emit the `kanban_task` SSE event so connected KanbanView
    //     clients refresh their board. Mirrors the emit in
    //     `tasks_move.zig:105-117` (the HTTP drag-and-drop path) —
    //     same payload shape, same non-fatal failure semantics.
    //     The `target_column_id` and `position` here are the
    //     resolved values (after the target_column_name → id
    //     fallback at line 248 and the position-null → MAX+1
    //     fallback at line 303). The frontend's SSE handler
    //     (kanban_events_sse.zig) fans this out to every connected
    //     client; the workspacesStore filters by workspace_id.
    //
    //     Bug history (2026-06-29): this emit was missing on the
    //     LLM tool path. Drag-and-drop worked (HTTP handler
    //     emits), AI-agent moves did not. Adding this single call
    //     closes the gap.
    nalarcore.ai_mod.on_event_sent_kanban.onEventSendKanbanTask(allocator, .{
        .action = "moved",
        .workspace_id = input.workspace_id,
        .item_id = input.item_id,
        .task_id = input.task_id,
        .new_column_id = target_column_id,
        .new_position = position,
    }) catch |err| {
        // Non-fatal: the LLM still gets the success XML; the
        // card auto-refresh just won't fire on sibling tabs.
        // The next kanban mutation will re-emit and catch up.
        std.log.warn("kanban_move_task: SSE emit failed (non-fatal): {s}", .{@errorName(err)});
    };

    // 4. Read the post-move state (column name) for the success
    //    response. The task was just moved to target_column_id, so
    //    we know its new column id — just look up the name.
    const post = readTaskCurrentColumn(allocator, db, input.task_id) catch |err| {
        return errorXmlOwned(allocator, try std.fmt.allocPrint(allocator, "DB: readTaskCurrentColumn failed: {s}", .{@errorName(err)}));
    };
    defer allocator.free(post.column_id);
    defer allocator.free(post.column_name);

    return successXml(allocator, input.task_id, task_name_slice, post.column_id, post.column_name, position);
}

/// Generate the success XML response.
pub fn successXml(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    task_name: []const u8,
    column_id: []const u8,
    column_name: []const u8,
    position: i64,
) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<kanban_move><success>true</success>");

    const eid = try xmlEscape(allocator, task_id);
    defer allocator.free(eid);
    try xml.appendSlice(allocator, "<task_id>");
    try xml.appendSlice(allocator, eid);
    try xml.appendSlice(allocator, "</task_id>");

    const ename = try xmlEscape(allocator, task_name);
    defer allocator.free(ename);
    try xml.appendSlice(allocator, "<task_name>");
    try xml.appendSlice(allocator, ename);
    try xml.appendSlice(allocator, "</task_name>");

    const ecid = try xmlEscape(allocator, column_id);
    defer allocator.free(ecid);
    try xml.appendSlice(allocator, "<column_id>");
    try xml.appendSlice(allocator, ecid);
    try xml.appendSlice(allocator, "</column_id>");

    const ecname = try xmlEscape(allocator, column_name);
    defer allocator.free(ecname);
    try xml.appendSlice(allocator, "<column_name>");
    try xml.appendSlice(allocator, ecname);
    try xml.appendSlice(allocator, "</column_name>");

    var pos_buf: [32]u8 = undefined;
    const pos_str = std.fmt.bufPrint(&pos_buf, "{d}", .{position}) catch "0";
    try xml.appendSlice(allocator, "<position>");
    try xml.appendSlice(allocator, pos_str);
    try xml.appendSlice(allocator, "</position>");

    try xml.appendSlice(allocator, "</kanban_move>");
    return try xml.toOwnedSlice(allocator);
}

/// Generate the error XML response. Mirrors the pattern in
/// `set_git_worktree.zig` / `add_skill.zig`.
pub fn errorXml(allocator: std.mem.Allocator, error_msg: []const u8) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<kanban_move><success>false</success><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></kanban_move>");
    return try xml.toOwnedSlice(allocator);
}

/// Same as `errorXml` but TAKES OWNERSHIP of `error_msg` and frees
/// it after escaping. Used for `errorXml(allocator, try std.fmt.allocPrint(...))`
/// where the caller can't `defer` the allocPrint result across a
/// `return errorXml(...)` expression. Mirrors the pattern from
/// `add_skill.zig`'s `xmlErrorOwned` (not actually called that in
/// add_skill.zig — we use this approach to avoid the leak).
pub fn errorXmlOwned(allocator: std.mem.Allocator, error_msg: []u8) ![]u8 {
    // We always own error_msg — free it on any path. errdefer
    // handles the "this function returned an error" path; the
    // trailing free handles the success path (we're about to
    // return the owned slice).
    defer allocator.free(error_msg);

    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(allocator);

    try xml.appendSlice(allocator, "<kanban_move><success>false</success><error>");
    const escaped = try xmlEscape(allocator, error_msg);
    defer allocator.free(escaped);
    try xml.appendSlice(allocator, escaped);
    try xml.appendSlice(allocator, "</error></kanban_move>");
    return try xml.toOwnedSlice(allocator);
}

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
