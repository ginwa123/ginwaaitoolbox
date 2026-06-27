# Kanban Status Tracking in System Prompt — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the agent's session is bound to a `workspace_item_task` whose parent `workspace_item.item_type = 'kanban'`, inject a `## Kanban Status Tracking` section into the system prompt that **instructs the agent to call `kanban_move_task`** at every meaningful workflow checkpoint (start, progress milestone, completion, blocker). The section also exposes the board's columns by name and id so the LLM can call `kanban_move_task` without first calling `kanban_list` for the common "move to 'in progress'" case.

**Why this matters:** Without the prompt instruction, the agent finishes its work (or hits a blocker) without ever calling `kanban_move_task`. The kanban board stays stale — the card sits in `todo` after the agent finished, or the user can't tell the agent is blocked. The existing `BuildWorkspaceContext` already injects the parent item's `item_type` into the system prompt (visible as `item_type: \`kanban\`` next to the self item marker), but the LLM has no rule binding `item_type === 'kanban'` → `MUST call kanban_move_task`.

**Architecture:** Add a new dynamic helper `BuildKanbanStatusPrompt(allocator, db, session_id)` next to `BuildWorkspaceContext` in `src/ai_workflow/tui/build_messages_for_agent_prompt.zig`. The helper:
1. Reuses the `task.id == session_id` anchor already proven by `getWorkspaceContext` to find the session's parent `workspace_item`.
2. If `item_type !== 'kanban'`, returns `""` (silently omitted — matches `BuildWorkspaceContext`'s empty-case behavior).
3. Otherwise reads the board's columns via `kanban_model.listColumns` and the task's current column id via a single `SELECT ... FROM workspace_item_tasks` query.
4. Renders a `## Kanban Status Tracking` markdown block that:
   - States the MANDATORY rule (one line, in the imperative voice).
   - Lists the columns by id + name so the LLM can call `kanban_move_task` with `target_column_id` directly.
   - Defines the 4 status-transition checkpoints (start → in-progress, milestone → still-in-progress, complete → done, blocked → stay in current column + explain).
   - References the `kanban_move_task` tool description for the exact argument shape (don't duplicate the contract — link instead).

**Tech Stack:** Zig 0.16, `std.Io.Threaded`, `SqliteBackend`. Reuses `kanban_model.listColumns` and `getWorkspaceContext`'s anchor pattern. No new dependencies, no frontend changes, no new migrations, no new tools.

---

## Decisions locked during brainstorming

1. **Section scope = single self-kanban only.** When the session's parent item is a kanban, render one `## Kanban Status Tracking` block scoped to THAT board. Do NOT render the section for other kanbans in the same workspace (the user could have a 5-kanban workspace; we'd flood the prompt). The agent can still discover sibling kanbans via the existing `## Workspace Context` listing and call `kanban_move_task` against them — the instruction is just one section.

2. **Use a NEW dynamic helper, not a static `PROMPT_SECTIONS` entry.** The section content depends on per-session DB state (parent item_type + column ids + names). Static sections are content-only; dynamic helpers are the existing pattern for DB-dependent content (see `BuildSkillContent`, `BuildSubAgentsListing`, `BuildWorkspaceContext`). The helper is gated on `item_type === 'kanban'` so non-kanban sessions never see the section.

3. **Anchor via `task.id == session_id`, not a fresh query.** Reuse `getWorkspaceContext`'s anchor result instead of running the lookup twice. The workspace-context lookup already returns `self_item_id` and the parent's `item_type` (via `SiblingItem.item_type`); we add a sibling struct field (`self_item_type: []u8`) so the kanban renderer doesn't have to JOIN again. **Trade-off:** this couples the new helper to `getWorkspaceContext`'s data shape — but that coupling is already implicit (every dynamic helper that needs the parent item's id reads the same anchor).

4. **Mandatory rule wording = imperative, single sentence.** The prompt should say `"When this task's parent is a kanban (item_type === 'kanban'), you MUST call kanban_move_task at every status transition."` NOT soft language like "consider calling" or "you should also". Soft language is the failure mode we're solving.

5. **Status-transition checkpoints are ENUMERATED, not narrated.** Four bullets, one sentence each: start (move to first non-todo column), milestone (no move, but emit a progress note), complete (move to last column), blocked (don't move, explain the blocker in the message). The four-bullet shape matches the existing `## Active Workers` / `## Running Background Processes` style.

6. **Column listing uses `id` + `name` + `position`.** Three columns per row in the markdown table. The id is backtick-quoted (matches `kanban_list` tool output format) so the LLM can copy-paste it directly into the `target_column_id` argument. Position is included so the LLM can describe the flow ("col 1 = todo, col 2 = in progress, col 3 = done").

7. **Column cap = 10.** A kanban with 10 columns is already exotic; if the board has more, render the first 10 by `position ASC` and add a `… and N more columns` footer. Same pattern as `BuildWorkspaceContext`'s 20-item cap.

8. **Empty columns / current-column-not-found = graceful skip.** If `kanban_model.listColumns` returns 0 rows (board has no columns yet — race condition at kanban creation), the section still renders the rule but with a one-line note: "this kanban has no columns yet; ask the user to add columns before moving tasks". If the task's `kanban_column_id` is NULL (unassigned), the section notes that the task starts unassigned and the agent's first move is required.

9. **No new tool. No frontend change. No migration.** The `kanban_move_task` tool already exists (verified at `src/modules/agent/tools/kanban_move_task.zig:60`); the kanban column table already exists (Migration 051); the workspace-item `item_type` field already accepts `'kanban'` (Migration 048). The feature is purely a system-prompt change.

10. **Sub-agent parity is out of scope.** Sub-agents spawned by a parent that sees the section do NOT inherit it via `inherited_context` (same carve-out as `## Workspace Context`). A sub-agent that needs to move the task should call `kanban_move_task` based on its own system-prompt context, not the parent's. A follow-up plan can decide whether to forward.

---

## File structure

### Modified files

```
src/ai_workflow/tui/
├── llm_history.zig
│     (1) Extend `WorkspaceContext.SiblingItem` with `item_type: []u8`
│         (already exists; verify the field is public-readable)
│     (2) Extend the anchor SQL in `getWorkspaceContext` to also
│         SELECT `wi.item_type` so we don't need a second query
│     (3) Add `self_item_type: []u8` to `WorkspaceContext`
│     (4) Update `WorkspaceContext.deinit` to free the new field
│
├── build_messages_for_agent_prompt.zig
│     (5) Add `BuildKanbanStatusPrompt(allocator, db, session_id)`
│         that returns the rendered markdown block (or "")
│     (6) Add a new `kanbanStatusContent: []const u8` param to
│         `buildMessages` and thread it from the new helper
│
src/modules/agent/
├── prompts.zig
│     (7) Add `kanbanStatusContent: []const u8` param to
│         `build_agent_prompt`
│     (8) Inject the `## Kanban Status Tracking` block right after
│         the `## Workspace Context` section (between Workspace Context
│         and OS info — same "dynamic state, then environment" framing
│         as cwd → workspace siblings → OS info)
│
├── prompts_test.zig
│     (9) Add 3 tests for the new section: rendered when self is
│         kanban, omitted when self is non-kanban, omitted when empty
```

### Not modified (intentional)

- **No frontend changes.** The section is in the system prompt only. Surfacing the column ids/names in the UI is a follow-up (analogous to the workspace-context UI plan).
- **No new tools.** `kanban_move_task` already exists.
- **No new migrations.** Schema is complete (kanban_columns, kanban_column_id, item_type).
- **No new `PROMPT_SECTIONS` entry.** Section is dynamic, gated on item_type === 'kanban'.

---

## Architecture diagram

```
buildMessages(cwd, session_id, ...) in build_messages_for_agent_prompt.zig
        │
        ├─► BuildSkillContent                (existing)
        ├─► BuildMemoryForAgent              (existing)
        ├─► BuildBackgroundProcessPrompt     (existing)
        ├─► BuildDynamicAgentContent         (existing)
        ├─► BuildSubAgentsListing            (existing)
        ├─► BuildWorkspaceContext            (existing — extended with self_item_type)
        │
        └─► BuildKanbanStatusPrompt(allocator, db, session_id) ◄── NEW
                │
                │ 1. ctx.self_item_type === "kanban"?
                │    no  → return ""  (silent skip)
                │    yes → continue
                │
                │ 2. kanban_model.listColumns(ctx.self_item_id)
                │    → KanbanColumn[]
                │
                │ 3. SELECT kanban_column_id FROM workspace_item_tasks
                │      WHERE id = session_id (the task's current column)
                │
                │ 4. Render as:
                │    "## Kanban Status Tracking\n\n"
                │    "<one-line MANDATORY rule>\n\n"
                │    "Current column: <col_name> (`<col_id>`)\n"
                │    "Columns on this board (in flow order):\n"
                │    "  0. todo (`col_abc`)\n"
                │    "  1. in progress (`col_def`)\n"
                │    "  2. done (`col_ghi`)\n\n"
                │    "Status transitions (call kanban_move_task):\n"
                │    "- **start**: move from `todo` → `in progress`"
                │    "- **milestone**: stay in current column; mention"
                │    "- **complete**: move to `done` (last column)"
                │    "- **blocked**: stay in current column; explain"
                │
                ▼
        kanbanStatusContent: []const u8
                │
                ▼
        prompt.build_agent_prompt(..., kanbanStatusContent)
                │
                └─► injects "## Kanban Status Tracking" block after Workspace Context
```

---

## Chunk 1: Extend `WorkspaceContext` with `self_item_type` (file 1 of 4)

**Files:** `src/ai_workflow/tui/llm_history.zig`

### Task 1.1: Add `self_item_type` to the struct + extend the anchor SQL

The current `getWorkspaceContext` reads `t.workspace_item_id` + `wi.workspace_id` + `wi.path` in the anchor query. We extend it to also read `wi.item_type`, store it on `WorkspaceContext` as `self_item_type`, and free it in `deinit`.

**Why:** The kanban-status renderer needs to know "is the parent item a kanban?" before doing anything else. Re-using the existing anchor saves a round-trip and keeps the data shape consistent.

- [ ] **Step 1.1.1:** Modify the anchor SQL at `llm_history.zig:2644-2649` from:

```zig
const anchor_sql =
    \\SELECT t.id, t.workspace_item_id, wi.workspace_id, wi.path
    \\FROM workspace_item_tasks t
    \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
    \\WHERE t.id = ?
;
```

to:

```zig
const anchor_sql =
    \\SELECT t.id, t.workspace_item_id, wi.workspace_id, wi.path, wi.item_type
    \\FROM workspace_item_tasks t
    \\JOIN workspace_items wi ON wi.id = t.workspace_item_id
    \\WHERE t.id = ?
;
```

- [ ] **Step 1.1.2:** Read the new column right after `self_path` (around line 2656-2660). Add:

```zig
const self_item_type = try allocator.dupe(u8, anchor_row.values[4]);
```

The `anchor_row.deinit(allocator)` call that follows still fires — we already duplicated the bytes we need.

- [ ] **Step 1.1.3:** Add `self_item_type: []u8` to the `WorkspaceContext` struct (at `llm_history.zig:2551-2606`, between `self_path` and `siblings`):

```zig
pub const WorkspaceContext = struct {
    workspace_id: []u8,
    self_item_id: []u8,
    self_task_id: []u8,
    self_item_type: []u8, // NEW — parent's workspace_items.item_type ('kanban', 'chat', 'folder', ...)
    self_path: ?[]u8,
    siblings: []SiblingItem,
    truncated_items_count: u32,
    total_item_count: u32,
    // ... rest unchanged ...
};
```

- [ ] **Step 1.1.4:** Update `WorkspaceContext.deinit` (around line 2598-2605) to free the new field:

```zig
pub fn deinit(self: WorkspaceContext, allocator: std.mem.Allocator) void {
    allocator.free(self.workspace_id);
    allocator.free(self.self_item_id);
    allocator.free(self.self_task_id);
    allocator.free(self.self_item_type); // NEW
    if (self.self_path) |p| allocator.free(p);
    // ... rest unchanged ...
}
```

- [ ] **Step 1.1.5:** Update the defensive "no rows from COUNT(*)" early-return at line 2672-2680 to also populate `self_item_type`:

```zig
return WorkspaceContext{
    .workspace_id = workspace_id,
    .self_item_id = self_item_id,
    .self_task_id = self_task_id,
    .self_item_type = self_item_type, // NEW
    .self_path = self_path,
    .siblings = &.{},
    .truncated_items_count = 0,
    .total_item_count = 0,
};
```

- [ ] **Step 1.1.6:** Update the final return at line 2800-2808 to include the new field:

```zig
return WorkspaceContext{
    .workspace_id = workspace_id,
    .self_item_id = self_item_id,
    .self_task_id = self_task_id,
    .self_item_type = self_item_type, // NEW
    .self_path = self_path,
    .siblings = try siblings.toOwnedSlice(allocator),
    .truncated_items_count = truncated_items_count,
    .total_item_count = total_item_count,
};
```

- [ ] **Step 1.1.7:** Run `timeout 180 zig build test --summary all 2>&1 | tail -n 20`. Expected: existing tests still pass (the test file `build_messages_for_agent_prompt_test.zig` doesn't yet reference `self_item_type`, so the addition is backward-compatible). Test count unchanged.

- [ ] **Step 1.1.8:** Commit.

```bash
git add src/ai_workflow/tui/llm_history.zig
git commit -m "feat(kanban-prompt): add self_item_type to WorkspaceContext (anchor read)"
```

---

## Chunk 2: Build the markdown renderer (file 2 of 4)

**Files:** `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` (new `BuildKanbanStatusPrompt` function)

### Task 2.1: Add the SQL helper + renderer in build_messages_for_agent_prompt.zig

The new helper lives next to `BuildWorkspaceContext` (around line 822-929). It:
1. Calls `llm_history.getWorkspaceContext` to get `ctx.self_item_type` (re-using the existing anchor).
2. If `ctx.self_item_type` !== `"kanban"`, returns `""`.
3. Otherwise calls `kanban_model.listColumns` for the columns.
4. Reads the task's current `kanban_column_id` via a single SQL query.
5. Renders the `## Kanban Status Tracking` block.

- [ ] **Step 2.1.1:** Add `kanban_model` to the file's imports. Currently the file imports `llm_history` and `sqlite` but not `kanban_model`. Add:

```zig
const kanban_model = nalarcore.ai_mod.kanban_model;
```

near the existing top-of-file imports (after `const sqlite = tree1_mod.sqlite;`).

- [ ] **Step 2.1.2:** Add a constant for the column cap near the existing `MAX_SIBLING_ITEMS`/`MAX_TASKS_PER_ITEM` block:

```zig
/// Maximum number of kanban columns rendered in the `## Kanban Status
/// Tracking` section. Boards with more columns truncate to the first
/// N by `position ASC` and add an `… and M more` footer. 10 is well
/// above any realistic kanban (typical N ≤ 7).
const MAX_KANBAN_COLUMNS: u32 = 10;
```

- [ ] **Step 2.1.3:** Add the new function right after `BuildWorkspaceContext` (around line 929):

```zig
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
/// This task is on a kanban board (item_type: `kanban`). **You MUST
/// call `kanban_move_task` at every meaningful workflow checkpoint.**
/// The tool description (in the tool listing) shows the exact
/// argument shape.
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
pub fn BuildKanbanStatusPrompt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    // 1. Re-use the workspace-context anchor to read the parent's
    //    item_type without a second JOIN. Bail out when the parent
    //    isn't a kanban.
    const ctx = (llm_history.getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildKanbanStatusPrompt: getWorkspaceContext failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer ctx.deinit(allocator);

    if (!std.mem.eql(u8, ctx.self_item_type, "kanban")) {
        return allocator.dupe(u8, "");
    }

    // 2. Read the columns. Same graceful-skip pattern as
    //    BuildWorkspaceContext — any DB failure returns "".
    const cols = kanban_model.listColumns(allocator, db, ctx.self_item_id) catch |err| {
        std.log.warn("BuildKanbanStatusPrompt: listColumns failed: {}", .{err});
        return allocator.dupe(u8, "");
    };
    defer kanban_model.freeColumns(allocator, cols);

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
        }
        if (cols.len > MAX_KANBAN_COLUMNS) {
            const footer = try std.fmt.allocPrint(allocator,
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
```

- [ ] **Step 2.1.4:** Add a unit test for the renderer in the existing `build_messages_for_agent_prompt_test.zig`:

```zig
test "BuildKanbanStatusPrompt returns empty string for non-kanban parent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: a chat item, not a kanban.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_chat', 'ws_x', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES ('sess_chat', 'chat task', 'wi_chat', 'standard')",
        &.{});

    const result = try build_messages.BuildKanbanStatusPrompt(alloc, &ctx.db, "sess_chat");
    defer alloc.free(result);

    try testing.expectEqualStrings("", result);
}

test "BuildKanbanStatusPrompt renders mandatory rule + columns for kanban parent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: a kanban item with 3 columns, task in column 0.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_kanban', 'ws_x', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES " ++
            "('col_a', 'wi_kanban', 'todo', 0), " ++
            "('col_b', 'wi_kanban', 'in progress', 1), " ++
            "('col_c', 'wi_kanban', 'done', 2)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, task_type) " ++
            "VALUES ('sess_kanban', 'kanban task', 'wi_kanban', 'col_a', 'standard')",
        &.{});

    const result = try build_messages.BuildKanbanStatusPrompt(alloc, &ctx.db, "sess_kanban");
    defer alloc.free(result);

    // Mandatory rule is present.
    try testing.expect(std.mem.indexOf(u8, result, "## Kanban Status Tracking") != null);
    try testing.expect(std.mem.indexOf(u8, result, "MUST call the `kanban_move_task` tool") != null);

    // Current column line.
    try testing.expect(std.mem.indexOf(u8, result, "Current column:** `todo` (`col_a`)") != null);

    // All three columns listed with ids.
    try testing.expect(std.mem.indexOf(u8, result, "- `todo` (`col_a`, position 0)") != null);
    try testing.expect(std.mem.indexOf(u8, result, "- `in progress` (`col_b`, position 1)") != null);
    try testing.expect(std.mem.indexOf(u8, result, "- `done` (`col_c`, position 2)") != null);

    // All four transitions present.
    try testing.expect(std.mem.indexOf(u8, result, "**start**") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**milestone**") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**complete**") != null);
    try testing.expect(std.mem.indexOf(u8, result, "**blocked**") != null);
}

test "BuildKanbanStatusPrompt renders unassigned note when task has no column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: kanban item with columns, but task has NULL kanban_column_id.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_kanban', 'ws_x', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('col_a', 'wi_kanban', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
            "VALUES ('sess_kanban', 'kanban task', 'wi_kanban', 'standard')",
        &.{});

    const result = try build_messages.BuildKanbanStatusPrompt(alloc, &ctx.db, "sess_kanban");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "Current column:** _unassigned_") != null);
}

test "BuildKanbanStatusPrompt renders empty-board hint when kanban has no columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: kanban item, NO columns, 1 task.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_kanban', 'ws_x', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
            "VALUES ('sess_kanban', 'kanban task', 'wi_kanban', 'standard')",
        &.{});

    const result = try build_messages.BuildKanbanStatusPrompt(alloc, &ctx.db, "sess_kanban");
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "_No columns configured yet._") != null);
}
```

> Note: the `setupDb` helper used above does NOT include `kanban_columns` in the CREATE TABLE list. Step 2.1.5 adds it. If you'd rather not extend `setupDb`, inline a `try ctx.db.exec(alloc, "CREATE TABLE kanban_columns (id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL, name TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0)", &.{});` at the top of each test.

- [ ] **Step 2.1.5:** Extend `setupDb` (in `build_messages_for_agent_prompt_test.zig`) to create the `kanban_columns` table (matches the post-Migration 051 baseline):

```zig
// Add after the existing CREATE TABLE statements in setupDb:
try db.exec(alloc,
    \\CREATE TABLE kanban_columns (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_item_id TEXT NOT NULL,
    \\    name TEXT NOT NULL,
    \\    position INTEGER NOT NULL DEFAULT 0,
    \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    \\)
, &.{});
```

The test also needs to extend the `workspace_item_tasks` CREATE TABLE to include `kanban_column_id` (nullable TEXT) — the existing CREATE TABLE in `setupDb` already omits this column. Update:

```zig
try db.exec(alloc,
    \\CREATE TABLE workspace_item_tasks (
    \\    id TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    workspace_item_id TEXT NOT NULL,
    \\    kanban_column_id TEXT, -- NEW
    \\    task_type TEXT NOT NULL DEFAULT 'standard',
    \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
    \\)
, &.{});
```

> **Pitfall — `workspace_item_tasks` already has `kanban_column_id` in the live schema.** The existing `setupDb` was authored for the workspace-context work (Chunk 1 of the 2026-06-19 plan), which predates the kanban feature. Adding the column to the CREATE TABLE matches the post-Migration 051 / 052 baseline that `BuildKanbanStatusPrompt` expects. Existing tests that don't reference `kanban_column_id` are unaffected (the column is nullable, default NULL).

- [ ] **Step 2.1.6:** Run `timeout 180 zig build test --summary all 2>&1 | tail -n 20`. Expected: 4 new tests pass, existing test count unchanged (the renderer tests are additive). Test count goes from N to N+4.

- [ ] **Step 2.1.7:** Commit.

```bash
git add src/ai_workflow/tui/build_messages_for_agent_prompt.zig \
        src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig
git commit -m "feat(kanban-prompt): render Kanban Status Tracking block (with 4 tests)"
```

---

## Chunk 3: Wire into `buildMessages` and `build_agent_prompt` (files 3-4 of 4)

**Files:** `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` and `src/modules/agent/prompts.zig`

### Task 3.1: Thread the new value through `buildMessages`

- [ ] **Step 3.1.1:** After the existing `BuildWorkspaceContext` call (around line 95-96), add:

```zig
const kanbanStatusContent = try BuildKanbanStatusPrompt(allocator, db, session_id);
defer allocator.free(kanbanStatusContent);
```

- [ ] **Step 3.1.2:** Pass `kanbanStatusContent` to `build_agent_prompt` at the existing call site (around line 98). Update the call signature to add a new last parameter:

```zig
const systemContent = try prompt.build_agent_prompt(
    allocator, io, cwd, skills, memoryMd, backgroundProcessmessage,
    agentUsed, tools, activity_info, environment, sub_agents_listing,
    workspaceContext, kanbanStatusContent,
);
```

### Task 3.2: Update `build_agent_prompt` to render the section

**Files:** `src/modules/agent/prompts.zig`

- [ ] **Step 3.2.1:** Add `kanbanStatusContent: []const u8` as a new last parameter to `build_agent_prompt` (around line 332-355). Update the docstring to mention it:

```zig
/// Pre-rendered "Kanban Status Tracking" markdown block, built by
/// `BuildKanbanStatusPrompt(allocator, db, session_id)` in
/// `build_messages_for_agent_prompt.zig`. Empty string means "the
/// session is not on a kanban board" (the section is silently
/// omitted). The block already includes its `## Kanban Status
/// Tracking` header. Rendered right after the Workspace Context
/// section so the agent sees "you are on a kanban" framing before
/// the tool listing.
kanbanStatusContent: []const u8,
```

- [ ] **Step 3.2.2:** Render the section between the Workspace Context block and the OS info. After line 463-465 (the `if (workspaceContext.len > 0)` block) and before line 467 (the `// OS info.` comment), add:

```zig
// Kanban status tracking — instructs the agent to call
// `kanban_move_task` at status transitions. Rendered right after
// the Workspace Context section so the agent sees the workflow
// expectations before the tool listing (where kanban_move_task's
// argument shape is documented). Block already includes its
// `## Kanban Status Tracking` header (built by
// `BuildKanbanStatusPrompt`); we just append it verbatim.
if (kanbanStatusContent.len > 0) {
    try result.appendSlice(allocator, kanbanStatusContent);
}
```

- [ ] **Step 3.2.3:** Verify all call sites of `build_agent_prompt` are updated. Run:

```bash
rg -n "build_agent_prompt\b" src/
```

Expected: 2 hits — one in `build_messages_for_agent_prompt.zig` (updated in step 3.1.2) and one in `prompts_test.zig` (will be updated in Task 3.3). No other call sites.

- [ ] **Step 3.2.4:** Update every existing test call in `prompts_test.zig` to add the new trailing parameter `""`. Search for `build_agent_prompt(` and add `, ""` before the closing `)` of each call. Use `text_replace` for surgical changes — there are ~15 call sites.

> **Pitfall — don't accidentally pass `null` or omit the param.** Zig 0.16 will reject a missing positional arg with `expected type '[]const u8', found '?'` or `error: function expects 12 arguments, found 11`. The pattern is: every existing call site gets a trailing `""` (empty string → no kanban section rendered).

- [ ] **Step 3.2.5:** Add 2 new tests in `prompts_test.zig` (next to the existing sub-agents listing tests around line 781-834):

```zig
test "build_agent_prompt renders Kanban Status Tracking when section is non-empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const kanban_block =
        \\## Kanban Status Tracking
        \\
        \\**You MUST call `kanban_move_task`** at every workflow checkpoint.
        \\
        \\**Current column:** `todo` (`col_a`)
        \\
        \\**Columns on this board** (in flow order):
        \\- `todo` (`col_a`, position 0)
        \\- `in progress` (`col_b`, position 1)
        \\- `done` (`col_c`, position 2)
        \\
        \\**Status transitions** (call `kanban_move_task`):
        \\- **start** — move from `todo` → `in progress`
        \\- **complete** — move to `done` before your final reply
    ;
    const prompt = try prompts.build_agent_prompt(
        alloc, io, "/tmp", "", "", "", "", &tools, "",
        null, "", "", kanban_block,
    );
    defer alloc.free(prompt);

    try std.testing.expect(contains(prompt, "## Kanban Status Tracking"));
    try std.testing.expect(contains(prompt, "MUST call `kanban_move_task`"));
    try std.testing.expect(contains(prompt, "Current column:** `todo` (`col_a`)"));
}

test "build_agent_prompt omits Kanban Status Tracking when section is empty" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tools = [_]AgentTool{};
    const prompt = try prompts.build_agent_prompt(
        alloc, io, "/tmp", "", "", "", "", &tools, "",
        null, "", "", "", // empty kanbanStatusContent
    );
    defer alloc.free(prompt);

    try std.testing.expect(!contains(prompt, "## Kanban Status Tracking"));
}
```

- [ ] **Step 3.2.6:** Run `timeout 180 zig build test --summary all 2>&1 | tail -n 20`. Expected: 2 new tests pass, no regressions in existing tests. Test count goes from N+4 to N+6.

- [ ] **Step 3.2.7:** Commit.

```bash
git add src/ai_workflow/tui/build_messages_for_agent_prompt.zig \
        src/modules/agent/prompts.zig \
        src/modules/agent/prompts_test.zig
git commit -m "feat(kanban-prompt): inject Kanban Status Tracking into system prompt"
```

---

## Chunk 4: Verify via `/test/system-prompt` endpoint + manual smoke test

The `/test/system-prompt/:session_id` endpoint (already wired at `src/ai_workflow/tui/http_handlers/system_prompt_get.zig`) returns the rendered system prompt verbatim. This is the fastest way to verify the section renders correctly without running a full LLM call.

### Task 4.1: Build and start the binary on port 8080

> Project rule (per NALAR.md): another `nalar` process is always running on port 8081. NEVER kill it. Use port 8080 for any local smoke testing.

- [ ] **Step 4.1.1:** Build the binary.

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: 4/6 build steps succeed. The 5th is `cp /usr/local/bin/nalar` which fails harmlessly with permission denied.

- [ ] **Step 4.1.2:** Start the binary on port 8080 in the background.

```bash
nohup ./zig-out/bin/nalar --port 8080 > /tmp/nalar-kanban-smoke.log 2>&1 &
echo $! > /tmp/nalar-kanban-smoke.pid
sleep 2  # let it boot
```

### Task 4.2: Set up a kanban + chat session via REST API

- [ ] **Step 4.2.1:** Create a workspace + kanban item + 3 columns + 1 task in the kanban.

```bash
# 1. Workspace
curl -sX POST http://127.0.0.1:8080/api/workspaces \
  -H 'Content-Type: application/json' \
  -d '{"id":"ws_kanban_smoke","name":"Kanban Smoke"}' | jq .

# 2. Kanban item
curl -sX POST http://127.0.0.1:8080/api/workspaces/ws_kanban_smoke/items/kanban \
  -H 'Content-Type: application/json' \
  -d '{"name":"Smoke Kanban"}' | jq .id

# Capture the returned kanban item_id (e.g., "item_1782550000000")

# 3. Verify default columns exist
curl -s http://127.0.0.1:8080/api/workspaces/ws_kanban_smoke/items/<KANBAN_ID>/kanban/columns | jq .

# 4. Create a task in the kanban (auto-assigned to first column)
curl -sX POST http://127.0.0.1:8080/api/workspaces/ws_kanban_smoke/items/<KANBAN_ID>/tasks \
  -H 'Content-Type: application/json' \
  -d '{"name":"smoke task","task_type":"standard"}' | jq .

# Capture the returned task_id (which IS the session_id per the convention)
```

- [ ] **Step 4.2.2:** Fetch the rendered system prompt via `/test/system-prompt`.

```bash
curl -s "http://127.0.0.1:8080/test/system-prompt/<TASK_ID>" | jq .
```

Expected response:

```json
{
  "session_id": "<TASK_ID>",
  "system_prompt": "<full prompt with ## Kanban Status Tracking block>",
  "size_bytes": N
}
```

- [ ] **Step 4.2.3:** Assert the rendered prompt contains the section.

```bash
RESPONSE=$(curl -s "http://127.0.0.1:8080/test/system-prompt/<TASK_ID>")
echo "$RESPONSE" | jq -r '.system_prompt' | grep -c "## Kanban Status Tracking"
# Expected: 1 (or more if the header substring also matches other sections)

echo "$RESPONSE" | jq -r '.system_prompt' | grep -c "MUST call"
# Expected: >= 1

echo "$RESPONSE" | jq -r '.system_prompt' | grep -c "Current column:"
# Expected: 1
```

- [ ] **Step 4.2.4:** Verify the column ids appear in the rendered prompt.

```bash
echo "$RESPONSE" | jq -r '.system_prompt' | grep -oE "col_[0-9]+"
# Expected: 3 column ids (the seeded default columns)
```

- [ ] **Step 4.2.5:** Verify the section is OMITTED for a non-kanban session. Create a chat item + task and check.

```bash
# Create a chat item
curl -sX POST http://127.0.0.1:8080/api/workspaces/ws_kanban_smoke/items \
  -H 'Content-Type: application/json' \
  -d '{"item_type":"chat","name":"chat smoke","path":"/tmp"}' | jq .id

# Create a task
curl -sX POST http://127.0.0.1:8080/api/workspaces/ws_kanban_smoke/items/<CHAT_ITEM_ID>/tasks \
  -H 'Content-Type: application/json' \
  -d '{"name":"chat task","task_type":"standard"}' | jq .id

# Fetch the rendered prompt
curl -s "http://127.0.0.1:8080/test/system-prompt/<CHAT_TASK_ID>" | jq -r '.system_prompt' | grep -c "## Kanban Status Tracking"
# Expected: 0
```

- [ ] **Step 4.2.6:** Stop the binary.

```bash
kill $(cat /tmp/nalar-kanban-smoke.pid)
rm -f /tmp/nalar-kanban-smoke.pid /tmp/nalar-kanban-smoke.log
```

### Task 4.3: Frontend build (no changes, just confirm not broken)

- [ ] **Step 4.3.1:** Run the frontend type-check + tests.

```bash
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Expected: both clean (no frontend changes, but defensive).

---

## Verification (run before declaring done)

```bash
# 1. Tests
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 10
# Expected: "test success" and N+6 tests (was N before this plan).
# N = 775 baseline (approximate; verify via "Zig test result" line).
# 4 renderer tests + 2 build_agent_prompt tests = +6.

# 2. Build
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
# Expected: 4/6 steps succeed (the cp step fails harmlessly).

# 3. Frontend (no changes, just confirm not broken)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 20
# Expected: both clean.

# 4. Manual smoke (Chunk 4.2 above)
```

---

## Out of scope (follow-up plans)

- **Auto-move-on-start hook.** Today the agent must *remember* to call `kanban_move_task` at the start of the session. A hook could automatically fire the start transition the first time the agent generates an assistant message. Out of scope — relies on a session-message callback the runtime doesn't expose today.
- **Blocker detection in tool output.** When a tool returns `error` or the agent emits text matching "blocked on X", auto-fire the blocked transition. Requires a tool-result interceptor that's not in `tool_registry.zig` today.
- **Frontend kanban column picker.** Today the user can move tasks via drag-and-drop on the kanban board (existing UI). A "the agent suggests a move" inline UI would surface the LLM's tool calls as one-click accept. Out of scope — UI work.
- **Sub-agent parity.** Sub-agents spawned by a parent that sees the section don't inherit it via `inherited_context`. A follow-up can decide whether to (a) pass it via inherited_context, (b) re-render in `build_sub_agent_prompt`, or (c) keep it parent-only.
- **Per-task rule override.** A `workspace_item_tasks.status_transition_mode` column ('strict' | 'advisory' | 'off') would let users disable the mandatory rule on tasks that don't need it. Out of scope — schema change + UI work.
- **Column rename propagation.** When the user renames a column (`kanban_columns_update`), the in-flight agent's prompt is stale (the column id is the same but the name changed). Out of scope — the LLM uses ids, not names, so this is mostly cosmetic.

---

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Prompt bloat when kanban has many columns (10+) | Low | Slow first-token latency, $$ cost | 10-column cap + `… and N more` footer |
| LLM ignores the imperative rule (soft language creep) | Medium | Stale kanban board | Imperative wording, single sentence, repeated in the transitions list; verified via `/test/system-prompt` smoke test |
| Sub-agent doesn't see the section (out of scope) | Low | Sub-agent can't move the task | Acceptable for v1 — sub-agents rarely need to move parent tasks. Follow-up plan. |
| `task.id == session_id` convention broken for new tasks | Low | Renderer misbehaves | Convention is enforced by the frontend (`AppLayout.vue :chat-id="activeTask.id"`); no backend changes can break it. |
| `setupDb` CREATE TABLE misses `kanban_columns` | Medium | Renderer tests fail to compile | Step 2.1.5 adds the table explicitly. |
| `prompts_test.zig` existing calls lack the new param | High | Compile error after step 3.2.1 | Step 3.2.4 updates all call sites with `, ""` trailing arg |
| Static analyzer thinks `BuildKanbanStatusPrompt` is unused (it's only called by `buildMessages` which is only called by `workflow.zig` which the test build doesn't reach) | Low | Compile error | Already covered by Chunk 2 tests + Chunk 3 `build_agent_prompt` tests — both reach the function. |
| The `kanban_model` import in `build_messages_for_agent_prompt.zig` triggers a circular dep via `nalarcore.ai_mod.kanban_model` | Low | Compile error | `nalarcore.ai_mod.kanban_model` is already accessible from `tool_registry.zig` (line 30: `const kanban_list_mod = nalar_mod.kanban_list;`). The path resolves at compile time, no circular dep. |