const std = @import("std");
const nalarcore = @import("nalarcore");

const sqlite = nalarcore.sqlite;

const MAX_SIBLING_ITEMS: u32 = 20;
const MAX_TASKS_PER_ITEM: u32 = 5;

/// Build a "## Kanban Status Tracking — MANDATORY" section that FORCES the
/// agent to call `kanban_list` + `kanban_move_task` at start and complete.
/// The section is rendered only when the session's parent item has
/// `item_type === 'kanban'`; otherwise returns `""` (silently
/// omitted, matching `BuildWorkspaceContext`'s empty-case behavior).
///
/// Re-uses the `getWorkspaceContext` anchor to avoid a second
/// round-trip — the parent item_type is already read there. The
/// helper:
///   1. Resolves the anchor (task → item → workspace) via
///      `getWorkspaceContext` and reads `ctx.self_item_type`.
///   2. Bails out if the parent is not a kanban.
///   3. Reads the columns via `listColumns` (no cap — all columns).
///   4. Renders the section (columns list only — no per-task current
///      column, which would be dynamic and break prefix cache).
///      The agent is FORCED to call `kanban_list` to discover its
///      current column — cache stays hot, correctness via tool call.
///
/// Block shape (omitted when parent is not a kanban, or session is
/// not bound to any task):
///
/// ```markdown
/// ## Kanban Status Tracking
///
/// This task is on a kanban board (parent item_type: `kanban`). **You MUST
/// call `kanban_move_task` at every meaningful workflow checkpoint.**
/// The tool description (in the tool listing) shows the exact argument shape.
///
/// **Columns on this board** (in flow order):
/// - `<name>` (`<id>`) — position 0 — <description>
/// - `<name>` (`<id>`) — position 1 — <description>
/// - ...
///
/// **Status transitions:**
/// - **start**: move from `<first_column>` → `<second_column>` (or
///   whatever the user-defined "in progress" column is) at the
///   first user-visible action in this session.
/// - **milestone**: stay in the current column; mention the milestone
///   in your reply so the user sees progress.
/// - **complete**: move to `<last_column>` (typically `done`) before
///   your final reply. This is the most-skipped transition.
/// - **blocked**: do NOT move; explain the blocker in your reply and
///   let the user decide. The card stays where it is.
/// ```
pub fn makeKanbanContext(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    tools: []const nalarcore.tool_models.AgentTool,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    const ctx = (getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildKanbanStatusPrompt: getWorkspaceContext failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer ctx.deinit(allocator);

    if (!std.mem.eql(u8, ctx.self_item_type, "kanban")) {
        return allocator.dupe(u8, "");
    }

    const follow_up_tool_equipped = hasToolByName(tools, "create_kanban_task");

    const cols = listColumns(allocator, db, ctx.self_item_id) catch |err| {
        std.log.warn("BuildKanbanStatusPrompt: listColumns failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer freeColumns(allocator, cols);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Kanban Status Tracking — MANDATORY\n\n");
    try out.appendSlice(allocator,
        \\This task is on a kanban board (parent item_type: `kanban`).
        \\**MANDATORY: You MUST move this card with `kanban_move_task`. Failure to move is a task failure.**
        \\**Before ANY work, you MUST call `kanban_list` to check your current column, then immediately call `kanban_move_task` to move to the next column.**
        \\Pass `workspace_id` + `item_id` from the `## Workspace Context` section above and `task_id` = your own `session_id` (per `task.id == session_id`). All `target_column_id` values are listed below — after `kanban_list` you can call `kanban_move_task` in ONE call.
        \\
    );

    // Render full column list (no cap, no per-task current column) so the
    // agent can call `kanban_move_task` in 1 call without a prior
    // `kanban_list`. Columns are board-static (same for every task on the
    // board), so this tail is prefix-cache friendly — it only changes when
    // the board's column config changes, not on every task move.
    // Description is also board-static (kanban_columns.description), so
    // including it does not break prefix cache.
    // The agent is FORCED to call `kanban_list` to discover its current
    // column — we do NOT render it here to keep the prompt cache-friendly.
    if (cols.len > 0) {
        try out.appendSlice(allocator, "\n**Columns on this board** (in flow order):\n");
        for (cols) |c| {
            try out.appendSlice(allocator, "- `");
            try out.appendSlice(allocator, c.name);
            try out.appendSlice(allocator, "` (`");
            try out.appendSlice(allocator, c.id);
            try out.appendSlice(allocator, "`) — position ");
            const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{c.position});
            defer allocator.free(pos_str);
            try out.appendSlice(allocator, pos_str);
            const trimmed_desc = std.mem.trim(u8, c.description, " \t\r\n");
            if (trimmed_desc.len > 0) {
                try out.appendSlice(allocator, " — ");
                try out.appendSlice(allocator, trimmed_desc);
            }
            try out.appendSlice(allocator, "\n");
        }
        try out.appendSlice(allocator, "\n");
    }

    try out.appendSlice(allocator, "\n**MANDATORY Status transitions — YOU MUST FOLLOW THESE:**\n");
    try out.appendSlice(allocator,
        \\
        \\- **START — MANDATORY, FIRST TOOL CALLS:** As your FIRST action, call `kanban_list` to check your current column, then immediately call `kanban_move_task` to move this task from the first column (`todo`) to the next column (`in progress`, or whatever the user-defined second column is). Pass `target_column_id` from the listing above. Your work has NOT started until you do this.
        \\- **MILESTONE — do NOT move:** When you reach a meaningful progress milestone but are not done, mention the milestone in your reply so the user sees progress. Keep the card in its current column.
        \\- **COMPLETE — MANDATORY, LAST TOOL CALL:** Before your final reply, you MUST call `kanban_move_task` to move this task to the last column (`done`, or whatever the user-defined last column is). **Do NOT skip this — your work is NOT complete until you do this. If you finish without moving to `done`, your work will be considered incomplete and will be rejected.**
        \\- **BLOCKED — do NOT move:** If you cannot make progress, do NOT move; explain the blocker in your reply. The card stays where it is until the user resolves the blocker.
        \\
        \\**FAILURE TO CALL `kanban_list` AT START AND `kanban_move_task` AT START + COMPLETE WILL BE CONSIDERED A TASK FAILURE.**
        \\
    );

    if (follow_up_tool_equipped) {
        try out.appendSlice(allocator,
            \\
            \\## Follow-up Tasks
            \\
            \\When you discover follow-up work that should be tracked on this kanban
            \\(a bug found while implementing this task, a dependency on another
            \\team, a multi-step follow-up that should happen after the current work
            \\ships, or anything else the user would want to see in their board),
            \\**suggest creating a new task on this kanban** so the user can see it.
            \\
            \\Use the `create_kanban_task` tool. It requires only a card title
            \\(`name`); all other fields (`workspace_id`, `item_id` for this kanban)
            \\come from the `## Workspace Context` section above. The optional
            \\`column_id` defaults to the first column by `position ASC` — pass it
            \\only when the user explicitly names a column.
            \\
            \\Skip this suggestion only when the user is actively making a quick
            \\atomic change with no follow-up implications.
            \\
        );
    }

    return out.toOwnedSlice(allocator);
}

/// Look up the workspace context for a session. Returns `null`
/// when the session is not bound to any `workspace_item_task`
/// (the caller omits the section silently in that case — matches
/// `appendSkillsListing` behavior).
///
/// Anchor: `workspace_item_tasks.id = ?` → task → item → workspace.
/// (The `session_id` column was dropped in Migration 052; `id` IS
/// the session id for kanban / routine tasks per the
/// `task.id == session_id` convention.)
/// Then enumerate `workspace_items WHERE workspace_id = ?` (capped at
/// `MAX_SIBLING_ITEMS`, ordered with self first). For each item,
/// enumerate its tasks (capped at `MAX_TASKS_PER_ITEM`).
///
/// SQL convention: all tables are aliased (`wi` for workspace_items,
/// `t` for workspace_item_tasks) per the project's
/// `nalar-sql-alias-tables` memory rule.
fn getWorkspaceContext(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?WorkspaceContext {
    if (session_id.len == 0) return null;

    // 1. Anchor: find the task bound to this session.
    //
    // The `task.id == session_id` convention (see AppLayout.vue
    // `:chat-id="activeTask.id"` and
    // workspacesStore.subscribeToSessionEvents comment in
    // workspaces.ts:1412) means the session_id we receive from the
    // frontend IS the task's own id. We anchor on `t.id` directly.
    // (Historically this query used `WHERE t.session_id = ?`, but
    // that column was redundant with `t.id` and was being populated
    // inconsistently — the frontend's createTask does not set it, so
    // freshly-created kanban tasks had `session_id = NULL` and the
    // `## Workspace Context` section was silently omitted from the
    // system prompt. Migration 052 dropped the column.)
    const anchor_sql =
        \\SELECT t.id, t.workspace_item_id, wi.workspace_id, wi.path, wi.item_type
        \\FROM workspace_item_tasks t
        \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
        \\WHERE t.id = ?
    ;
    var anchor_q = try db.query(allocator, anchor_sql, &.{session_id});
    defer anchor_q.deinit();
    const anchor_row = (try anchor_q.next()) orelse return null;
    const self_task_id = try allocator.dupe(u8, anchor_row.values[0]);
    const self_item_id = try allocator.dupe(u8, anchor_row.values[1]);
    const workspace_id = try allocator.dupe(u8, anchor_row.values[2]);
    const self_path: ?[]u8 = if (anchor_row.values[3].len > 0)
        try allocator.dupe(u8, anchor_row.values[3])
    else
        null;
    const self_item_type = try allocator.dupe(u8, anchor_row.values[4]);
    anchor_row.deinit(allocator); // Pitfall 1: pass allocator explicitly, NOT `anchor_row.allocator`

    // 2. Total item count for the "and N more" footer.
    var count_q = try db.query(
        allocator,
        "SELECT COUNT(*) FROM workspace_items wi WHERE wi.workspace_id = ?",
        &.{workspace_id},
    );
    defer count_q.deinit();
    const count_row = (try count_q.next()) orelse {
        // Defensive: COUNT(*) should always return a row. If not,
        // synthesize an empty siblings list so the caller still
        // gets a usable context.
        return WorkspaceContext{
            .workspace_id = workspace_id,
            .self_item_id = self_item_id,
            .self_task_id = self_task_id,
            .self_item_type = self_item_type,
            .self_path = self_path,
            .siblings = &.{},
            .truncated_items_count = 0,
            .total_item_count = 0,
        };
    };
    const total_item_count = try std.fmt.parseInt(u32, count_row.values[0], 10);
    count_row.deinit(allocator); // Pitfall 1 again

    // 3. Enumerate items (capped at MAX_SIBLING_ITEMS).
    //
    // Pitfall 2: SQLite's `LIMIT ?` doesn't bind an integer via the
    // SqliteBackend's text-binding path. Inline the limit into the
    // SQL string at build time. Mirrors the project's existing
    // convention in `routines/model.zig` where index hints are
    // also inlined (no parameterized LIMIT).
    const items_sql = try std.fmt.allocPrint(allocator,
        \\SELECT wi.id, wi.item_type, wi.name, wi.path,
        \\       (wi.id = ?) AS is_self
        \\FROM workspace_items wi
        \\WHERE wi.workspace_id = ?
        \\ORDER BY is_self DESC, wi.position DESC, wi.id ASC
        \\LIMIT {d}
    , .{MAX_SIBLING_ITEMS});
    defer allocator.free(items_sql);

    var items_q = try db.query(allocator, items_sql, &.{ self_item_id, workspace_id });
    defer items_q.deinit();

    var siblings: std.ArrayList(WorkspaceContext.SiblingItem) = .empty;
    errdefer {
        for (siblings.items) |s| s.deinit(allocator);
        siblings.deinit(allocator);
    }

    while (try items_q.next()) |row| {
        const item_id_owned = try allocator.dupe(u8, row.values[0]);
        errdefer allocator.free(item_id_owned);
        const item_type_owned = try allocator.dupe(u8, row.values[1]);
        const name_owned: ?[]u8 = if (row.values[2].len > 0) try allocator.dupe(u8, row.values[2]) else null;
        const path_owned: ?[]u8 = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null;
        const is_self_owned = std.mem.eql(u8, row.values[4], "1");
        row.deinit(allocator);

        // 4. Enumerate tasks under this item (capped at
        // MAX_TASKS_PER_ITEM). Same inlined-LIMIT pattern as above.
        const tasks_sql = try std.fmt.allocPrint(allocator,
            \\SELECT t.id, t.name, t.task_type
            \\FROM workspace_item_tasks t
            \\WHERE t.workspace_item_id = ?
            \\ORDER BY t.updated_at DESC, t.id ASC
            \\LIMIT {d}
        , .{MAX_TASKS_PER_ITEM});
        defer allocator.free(tasks_sql);

        var tasks_q = try db.query(allocator, tasks_sql, &.{item_id_owned});
        defer tasks_q.deinit();

        var tasks: std.ArrayList(WorkspaceContext.SiblingItem.SiblingTask) = .empty;
        errdefer {
            for (tasks.items) |t| {
                allocator.free(t.id);
                allocator.free(t.name);
                allocator.free(t.task_type);
            }
            tasks.deinit(allocator);
        }

        while (try tasks_q.next()) |trow| {
            const t_id = try allocator.dupe(u8, trow.values[0]);
            const t_name = try allocator.dupe(u8, trow.values[1]);
            const t_type = try allocator.dupe(u8, trow.values[2]);
            trow.deinit(allocator);
            try tasks.append(allocator, .{
                .id = t_id,
                .name = t_name,
                .task_type = t_type,
            });
        }

        // 4b. Truncation detection for tasks: see if there are
        // more tasks than we loaded.
        var task_count_q = try db.query(
            allocator,
            "SELECT COUNT(*) FROM workspace_item_tasks t WHERE t.workspace_item_id = ?",
            &.{item_id_owned},
        );
        defer task_count_q.deinit();
        const task_count_row = (try task_count_q.next()) orelse {
            // Defensive — COUNT(*) should always return a row.
            // Use the loaded count as the truth.
            try siblings.append(allocator, .{
                .id = item_id_owned,
                .item_type = item_type_owned,
                .name = name_owned,
                .path = path_owned,
                .is_self = is_self_owned,
                .tasks = try tasks.toOwnedSlice(allocator),
                .truncated_tasks_count = 0,
            });
            continue;
        };
        const total_tasks: u32 = try std.fmt.parseInt(u32, task_count_row.values[0], 10);
        task_count_row.deinit(allocator);
        const truncated_tasks_count: u32 = if (total_tasks > MAX_TASKS_PER_ITEM)
            total_tasks - MAX_TASKS_PER_ITEM
        else
            0;

        try siblings.append(allocator, .{
            .id = item_id_owned,
            .item_type = item_type_owned,
            .name = name_owned,
            .path = path_owned,
            .is_self = is_self_owned,
            .tasks = try tasks.toOwnedSlice(allocator),
            .truncated_tasks_count = truncated_tasks_count,
        });
    }

    const truncated_items_count: u32 = if (total_item_count > MAX_SIBLING_ITEMS)
        total_item_count - MAX_SIBLING_ITEMS
    else
        0;

    return WorkspaceContext{
        .workspace_id = workspace_id,
        .self_item_id = self_item_id,
        .self_task_id = self_task_id,
        .self_item_type = self_item_type,
        .self_path = self_path,
        .siblings = try siblings.toOwnedSlice(allocator),
        .truncated_items_count = truncated_items_count,
        .total_item_count = total_item_count,
    };
}

/// Context for the "Workspace Context" dynamic prompt section.
/// Returned by `getWorkspaceContext`; the tui layer's
/// `BuildWorkspaceContext` consumes this struct and renders
/// the markdown block.
const WorkspaceContext = struct {
    workspace_id: []u8,
    self_item_id: []u8, // task's own item id
    self_task_id: []u8, // task's own id
    self_item_type: []u8, // parent's workspace_items.item_type ('kanban', 'chat', 'folder', ...)
    self_path: ?[]u8, // task's own item path (cwd hint)
    siblings: []SiblingItem, // all items in the same workspace, self first
    truncated_items_count: u32, // > 0 when 20-item cap hit
    total_item_count: u32, // for diagnostic footer

    pub const SiblingItem = struct {
        id: []u8,
        item_type: []u8,
        name: ?[]u8,
        path: ?[]u8,
        is_self: bool,
        tasks: []SiblingTask, // ≤ MAX_TASKS_PER_ITEM
        truncated_tasks_count: u32, // > 0 when 5-task cap hit

        pub const SiblingTask = struct {
            id: []u8,
            name: []u8,
            task_type: []u8,
        };

        /// Free the per-item allocations. Mirrors the parent's
        /// `WorkspaceContext.deinit` shape so callers that iterate
        /// `siblings` and free each entry don't have to inline
        /// the cleanup at every call site (see Pitfall 3 in the
        /// plan — Zig 0.16 requires struct methods to be declared
        /// inside the struct body).
        pub fn deinit(self: SiblingItem, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.item_type);
            if (self.name) |n| allocator.free(n);
            if (self.path) |p| allocator.free(p);
            for (self.tasks) |t| {
                allocator.free(t.id);
                allocator.free(t.name);
                allocator.free(t.task_type);
            }
            allocator.free(self.tasks);
        }
    };

    /// Free all heap-allocated fields of this `WorkspaceContext`.
    /// Callers MUST call `deinit` on a non-null value returned by
    /// `getWorkspaceContext` exactly once.
    pub fn deinit(self: WorkspaceContext, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.self_item_id);
        allocator.free(self.self_task_id);
        allocator.free(self.self_item_type);
        if (self.self_path) |p| allocator.free(p);
        for (self.siblings) |sib| sib.deinit(allocator);
        allocator.free(self.siblings);
    }
};

/// List the columns of a kanban workspace item in `position` order.
///
/// Returns an owned slice; the caller must release it with
/// `freeColumns(allocator, slice)`. If the item has no columns, the
/// slice has length 0 (not an error).
fn listColumns(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]KanbanColumn {
    var q = try db.query(allocator,
        \\SELECT kc.id, kc.workspace_item_id, kc.name, kc.description, kc.position, COALESCE(kc.created_at, '')
        \\FROM kanban_columns kc
        \\WHERE kc.workspace_item_id = ?
        \\ORDER BY kc.position ASC
    , &.{workspace_item_id});
    defer q.deinit();

    var rows = std.ArrayList(KanbanColumn).empty;
    errdefer {
        for (rows.items) |c| {
            allocator.free(c.id);
            allocator.free(c.workspace_item_id);
            allocator.free(c.name);
            allocator.free(c.description);
            allocator.free(c.created_at);
        }
        rows.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .description = try allocator.dupe(u8, row.values[3]),
            .position = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
            .created_at = try allocator.dupe(u8, row.values[5]),
        });
    }
    return rows.toOwnedSlice(allocator);
}

/// One kanban column row, fully duplicated into heap memory.
/// Free with `freeColumns(allocator, slice)`.
const KanbanColumn = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    description: []u8,
    position: i64,
    created_at: []u8,
};

/// Free the per-column strings and the backing slice in one call.
fn freeColumns(allocator: std.mem.Allocator, cols: []KanbanColumn) void {
    for (cols) |c| {
        allocator.free(c.id);
        allocator.free(c.workspace_item_id);
        allocator.free(c.name);
        allocator.free(c.description);
        allocator.free(c.created_at);
    }
    allocator.free(cols);
}

/// Look up a tool by its `function.name` in the equipped-tool list.
/// Returns true if the tool is equipped, false otherwise. Linear scan
/// (tools lists are typically small — under 50 entries — so the
/// constant factor is irrelevant). Matches the convention used by
/// the static-section `.requires_tool` gate in `prompts.zig`.
fn hasToolByName(tools: []const nalarcore.tool_models.AgentTool, name: []const u8) bool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.function.name, name)) return true;
    }
    return false;
}

// ─── Tests (in-memory DB, no cap) ───────────────────────────────────────

const testing = std.testing;
const test_sqlite = @import("nalarcore").sqlite;

const TestCtx = struct {
    db: test_sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: test_sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, created_at DATETIME, updated_at DATETIME, task_type TEXT
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '', position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    workspace_item_task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL, kanban_position INTEGER NOT NULL DEFAULT 0
        \\)
    , &[_][]const u8{});
    return .{ .db = db, .threaded = threaded };
}

fn insertWorkspaceItem(ctx: *TestCtx, id: []const u8, ws_id: []const u8, item_type: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES (?, ?, ?, 'Test', '/tmp', 0)",
        &[_][]const u8{ id, ws_id, item_type },
    );
}

fn insertTask(ctx: *TestCtx, task_id: []const u8, item_id: []const u8) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, created_at, updated_at, task_type) VALUES (?, 'T', ?, datetime('now'), datetime('now'), 'standard')",
        &[_][]const u8{ task_id, item_id },
    );
}

fn insertColumn(ctx: *TestCtx, col_id: []const u8, item_id: []const u8, name: []const u8, pos: i64) !void {
    try insertColumnWithDescription(ctx, col_id, item_id, name, "", pos);
}

fn insertColumnWithDescription(ctx: *TestCtx, col_id: []const u8, item_id: []const u8, name: []const u8, desc: []const u8, pos: i64) !void {
    const alloc = testing.allocator;
    const pos_str = try std.fmt.allocPrint(alloc, "{d}", .{pos});
    defer alloc.free(pos_str);
    // SqliteBackend.exec binds "" as NULL (empty-slice-as-NULL pitfall),
    // which violates NOT NULL on description. Omit the column when empty
    // so DEFAULT '' applies — mirrors production's INSERT without description.
    if (desc.len == 0) {
        try ctx.db.exec(alloc,
            "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES (?, ?, ?, ?)",
            &[_][]const u8{ col_id, item_id, name, pos_str },
        );
    } else {
        try ctx.db.exec(alloc,
            "INSERT INTO kanban_columns (id, workspace_item_id, name, description, position) VALUES (?, ?, ?, ?, ?)",
            &[_][]const u8{ col_id, item_id, name, desc, pos_str },
        );
    }
}

fn insertKanban(ctx: *TestCtx, task_id: []const u8, col_id: []const u8, pos: i64) !void {
    const alloc = testing.allocator;
    const pos_str = try std.fmt.allocPrint(alloc, "{d}", .{pos});
    defer alloc.free(pos_str);
    try ctx.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES (?, ?, ?)",
        &[_][]const u8{ task_id, col_id, pos_str },
    );
}

test "makeKanbanContext: returns empty when session_id empty" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const out = try makeKanbanContext(alloc, &ctx.db, "", &.{});
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "makeKanbanContext: returns empty when not a kanban" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try insertWorkspaceItem(&ctx, "item_1", "ws_1", "chat");
    try insertTask(&ctx, "sess_1", "item_1");
    const out = try makeKanbanContext(alloc, &ctx.db, "sess_1", &.{});
    defer alloc.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "makeKanbanContext: renders all columns without cap (15 columns)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try insertWorkspaceItem(&ctx, "item_1", "ws_1", "kanban");
    try insertTask(&ctx, "sess_1", "item_1");
    // Insert 15 columns — old cap was 10, now all must appear.
    for (0..15) |i| {
        const col_id = try std.fmt.allocPrint(alloc, "col_{d}", .{i});
        defer alloc.free(col_id);
        const name = try std.fmt.allocPrint(alloc, "colname_{d}", .{i});
        defer alloc.free(name);
        try insertColumn(&ctx, col_id, "item_1", name, @intCast(i));
    }
    try insertKanban(&ctx, "sess_1", "col_0", 0);
    const out = try makeKanbanContext(alloc, &ctx.db, "sess_1", &.{});
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "## Kanban Status Tracking") != null);
    // No per-task Current column — cache-friendly (board-static only).
    try testing.expect(std.mem.indexOf(u8, out, "**Current column:**") == null);
    try testing.expect(std.mem.indexOf(u8, out, "**Columns on this board**") != null);
    // All 15 must be present — no truncation.
    for (0..15) |i| {
        const needle = try std.fmt.allocPrint(alloc, "colname_{d}", .{i});
        defer alloc.free(needle);
        try testing.expect(std.mem.indexOf(u8, out, needle) != null);
    }
    // Verify no cap footer like "and N more" — we render all.
    try testing.expect(std.mem.indexOf(u8, out, "more") == null or std.mem.indexOf(u8, out, "Columns on this board") != null);
}

test "makeKanbanContext: renders columns correctly (no current column, cache-friendly)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try insertWorkspaceItem(&ctx, "item_1", "ws_1", "kanban");
    try insertTask(&ctx, "sess_1", "item_1");
    try insertColumn(&ctx, "c_todo", "item_1", "todo", 0);
    try insertColumn(&ctx, "c_prog", "item_1", "in progress", 1);
    try insertColumn(&ctx, "c_done", "item_1", "done", 2);
    try insertKanban(&ctx, "sess_1", "c_prog", 0);
    const out = try makeKanbanContext(alloc, &ctx.db, "sess_1", &.{});
    defer alloc.free(out);
    // No per-task current column — would break prefix cache.
    try testing.expect(std.mem.indexOf(u8, out, "**Current column:**") == null);
    try testing.expect(std.mem.indexOf(u8, out, "- `todo` (`c_todo`) — position 0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `in progress` (`c_prog`) — position 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `done` (`c_done`) — position 2") != null);
}

test "makeKanbanContext: no current column even when no kanban row (cache-friendly)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try insertWorkspaceItem(&ctx, "item_1", "ws_1", "kanban");
    try insertTask(&ctx, "sess_1", "item_1");
    try insertColumn(&ctx, "c1", "item_1", "todo", 0);
    // No kanban row for sess_1 — still no Current column (board-static only).
    const out = try makeKanbanContext(alloc, &ctx.db, "sess_1", &.{});
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "**Current column:**") == null);
    try testing.expect(std.mem.indexOf(u8, out, "**Columns on this board**") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `todo` (`c1`) — position 0") != null);
}

test "makeKanbanContext: columns ordered by position ASC" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try insertWorkspaceItem(&ctx, "item_1", "ws_1", "kanban");
    try insertTask(&ctx, "sess_1", "item_1");
    // Insert out of order
    try insertColumn(&ctx, "c_done", "item_1", "done", 2);
    try insertColumn(&ctx, "c_todo", "item_1", "todo", 0);
    try insertColumn(&ctx, "c_prog", "item_1", "in progress", 1);
    try insertKanban(&ctx, "sess_1", "c_todo", 0);
    const out = try makeKanbanContext(alloc, &ctx.db, "sess_1", &.{});
    defer alloc.free(out);
    const todo_idx = std.mem.indexOf(u8, out, "`todo`") orelse return error.NotFound;
    const prog_idx = std.mem.indexOf(u8, out, "`in progress`") orelse return error.NotFound;
    const done_idx = std.mem.indexOf(u8, out, "`done`") orelse return error.NotFound;
    try testing.expect(todo_idx < prog_idx);
    try testing.expect(prog_idx < done_idx);
}

test "makeKanbanContext: 1-call hint — target_column_id present without kanban_list" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try insertWorkspaceItem(&ctx, "item_1", "ws_1", "kanban");
    try insertTask(&ctx, "sess_1", "item_1");
    try insertColumn(&ctx, "col_1b40fb0ea07f0000", "item_1", "todo", 0);
    try insertColumn(&ctx, "col_1c40fb0ea07f0000", "item_1", "in progress", 1);
    try insertKanban(&ctx, "sess_1", "col_1b40fb0ea07f0000", 0);
    const out = try makeKanbanContext(alloc, &ctx.db, "sess_1", &.{});
    defer alloc.free(out);
    // The prompt must contain the exact ids so kanban_move_task can be called directly.
    try testing.expect(std.mem.indexOf(u8, out, "col_1c40fb0ea07f0000") != null);
    try testing.expect(std.mem.indexOf(u8, out, "col_1b40fb0ea07f0000") != null);
    try testing.expect(std.mem.indexOf(u8, out, "kanban_move_task") != null);
}

test "makeKanbanContext: renders description when present (board-static, cache-friendly)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try insertWorkspaceItem(&ctx, "item_1", "ws_1", "kanban");
    try insertTask(&ctx, "sess_1", "item_1");
    try insertColumnWithDescription(&ctx, "c_todo", "item_1", "todo", "Backlog — not started", 0);
    try insertColumnWithDescription(&ctx, "c_prog", "item_1", "in progress", "", 1);
    try insertColumnWithDescription(&ctx, "c_done", "item_1", "done", "Shipped", 2);
    try insertKanban(&ctx, "sess_1", "c_todo", 0);
    const out = try makeKanbanContext(alloc, &ctx.db, "sess_1", &.{});
    defer alloc.free(out);
    // Description is board-static, so cache stays hot.
    try testing.expect(std.mem.indexOf(u8, out, "- `todo` (`c_todo`) — position 0 — Backlog") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `in progress` (`c_prog`) — position 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- `done` (`c_done`) — position 2 — Shipped") != null);
    // Empty description must not emit trailing " — ".
    try testing.expect(std.mem.indexOf(u8, out, "position 1 — \n") == null);
}

test "makeKanbanContext: trims whitespace-only description (no trailing dash)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try insertWorkspaceItem(&ctx, "item_1", "ws_1", "kanban");
    try insertTask(&ctx, "sess_1", "item_1");
    try insertColumnWithDescription(&ctx, "c1", "item_1", "todo", "   \n\t  ", 0);
    try insertKanban(&ctx, "sess_1", "c1", 0);
    const out = try makeKanbanContext(alloc, &ctx.db, "sess_1", &.{});
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "- `todo` (`c1`) — position 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "position 0 — ") == null or std.mem.indexOf(u8, out, "position 0\n") != null);
}
