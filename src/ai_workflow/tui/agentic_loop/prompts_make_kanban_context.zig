const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite = nalarcore.sqlite;

const MAX_SIBLING_ITEMS: u32 = 20;
const MAX_TASKS_PER_ITEM: u32 = 5;
const MAX_KANBAN_COLUMNS: u32 = 10;

/// Build a "## Kanban Status Tracking" section that instructs the
/// agent to call `kanban_move_task` at every meaningful workflow
/// checkpoint (start, milestone, complete, blocked). The section is
/// rendered only when the session's parent item has
/// `item_type === 'kanban'`; otherwise returns `""` (silently
/// omitted, matching `BuildWorkspaceContext`'s empty-case behavior).
///
/// Re-uses the `getWorkspaceContext` anchor to avoid a second
/// round-trip — the parent item_type is already read there. The
/// helper:
///   1. Resolves the anchor (task → item → workspace) via
///      `getWorkspaceContext` and reads `ctx.self_item_type`.
///   2. Bails out if the parent is not a kanban.
///   3. Reads the columns via `kanban_model.listColumns` (cap: 10).
///   4. Reads the task's current `kanban_column_id` via a single
///      `SELECT` (the column id may be NULL when unassigned).
///   5. Renders the section.
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
/// **Current column:** `<col_name>` (`<col_id>`)
///
/// **Columns on this board** (in flow order):
/// - `<name>` (`<id>`) — position 0
/// - `<name>` (`<id>`) — position 1
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
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    // 1. Re-use the workspace-context anchor to read the parent's
    //    item_type without a second JOIN. Bail out when the parent
    //    isn't a kanban.
    const ctx = (getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildKanbanStatusPrompt: getWorkspaceContext failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer ctx.deinit(allocator);

    if (!std.mem.eql(u8, ctx.self_item_type, "kanban")) {
        return allocator.dupe(u8, "");
    }

    // 2. Read the columns. Same graceful-skip pattern as
    //    BuildWorkspaceContext — any DB failure returns "".
    const cols = listColumns(allocator, db, ctx.self_item_id) catch |err| {
        std.log.warn("BuildKanbanStatusPrompt: listColumns failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer freeColumns(allocator, cols);

    // 3. Read the task's current kanban_column_id (may be NULL when
    //    unassigned). One-row query — task.id == session_id per the
    //    workspace-context convention.
    const current_column_id: ?[]const u8 = blk: {
        var q = try db.query(allocator,
            \\SELECT COALESCE(kanban_column_id, '')
            \\FROM workspace_item_tasks t
            \\WHERE t.id = ?
        , &.{session_id});
        defer q.deinit();
        const row = (try q.next()) orelse break :blk null;
        defer row.deinit(allocator);
        const cid = row.values[0];
        if (cid.len == 0) break :blk null;
        break :blk try allocator.dupe(u8, cid);
    };
    defer if (current_column_id) |c| allocator.free(c);

    // 4. Render the markdown block.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Kanban Status Tracking\n\n");
    try out.appendSlice(allocator,
        \\This task is on a kanban board (parent item_type: `kanban`).
        \\**You MUST call the `kanban_move_task` tool at every meaningful
        \\workflow checkpoint** below. The tool's argument shape is
        \\documented in the tool listing — pass `workspace_id` + `item_id`
        \\from the `## Workspace Context` section above, and `task_id` is
        \\your own session_id (per the `task.id == session_id` convention).
        \\
    );

    // 4a. Current column line.
    if (current_column_id) |cid| {
        const col_name = blk: {
            for (cols) |c| {
                if (std.mem.eql(u8, c.id, cid)) break :blk c.name;
            }
            break :blk "<unknown>";
        };
        try out.appendSlice(allocator, "**Current column:** `");
        try out.appendSlice(allocator, col_name);
        try out.appendSlice(allocator, "` (`");
        try out.appendSlice(allocator, cid);
        try out.appendSlice(allocator, "`)\n\n");
    } else {
        try out.appendSlice(allocator,
            \\**Current column:** _unassigned_ — the task has no column yet.
            \\Your first move will assign it.
            \\
        );
    }

    // 4b. Column listing (cap: 10, with footer).
    try out.appendSlice(allocator, "**Columns on this board** (in flow order):\n");
    if (cols.len == 0) {
        try out.appendSlice(allocator,
            \\_No columns configured yet._ Ask the user to add columns before
            \\moving the task.
            \\
        );
    } else {
        const shown = @min(cols.len, MAX_KANBAN_COLUMNS);
        for (cols[0..shown]) |c| {
            try out.appendSlice(allocator, "- `");
            try out.appendSlice(allocator, c.name);
            try out.appendSlice(allocator, "` (`");
            try out.appendSlice(allocator, c.id);
            const pos_str = try std.fmt.allocPrint(allocator, "`, position {d})\n", .{c.position});
            defer allocator.free(pos_str);
            try out.appendSlice(allocator, pos_str);

            // Inject the column's free-text description (Migration 053)
            // as an indented sub-line. Skip when empty so the prompt
            // stays quiet for un-described columns.
            if (c.description.len > 0) {
                try out.appendSlice(allocator, "  Description: ");
                try out.appendSlice(allocator, c.description);
                try out.appendSlice(allocator, "\n");
            }
        }
        if (cols.len > MAX_KANBAN_COLUMNS) {
            const footer = try std.fmt.allocPrint(
                allocator,
                "… and {d} more columns (cap: {d} shown).\n",
                .{ cols.len - MAX_KANBAN_COLUMNS, MAX_KANBAN_COLUMNS },
            );
            defer allocator.free(footer);
            try out.appendSlice(allocator, footer);
        }
    }

    // 4c. Status transitions.
    try out.appendSlice(allocator, "\n**Status transitions** (call `kanban_move_task`):\n");
    try out.appendSlice(allocator,
        \\
        \\- **start** — at the first user-visible action of this session, move the
        \\  task from the first column (`todo`) to the next column (`in progress`,
        \\  or whatever the user-defined "in progress" column is). Pass the
        \\  `target_column_id` from the listing above.
        \\- **milestone** — when you reach a meaningful progress milestone but are
        \\  not done, do NOT move; instead, mention the milestone in your reply
        \\  so the user sees progress without you skipping the "done" transition.
        \\- **complete** — before your final reply, move the task to the last
        \\  column (`done`, or whatever the user-defined "done" column is). This
        \\  is the most-skipped transition; do not skip it.
        \\- **blocked** — if you cannot make progress, do NOT move; explain the
        \\  blocker in your reply. The card stays where it is until the user
        \\  resolves the blocker or you find a way forward.
        \\
    );

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
