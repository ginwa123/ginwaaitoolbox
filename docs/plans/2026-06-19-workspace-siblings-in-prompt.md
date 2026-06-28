# Workspace Siblings in System Prompt — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Draft. Resolves the unfinished `buildWorkspaceTaskList` stub at `src/ai_workflow/tui/build_messages_for_agent_prompt.zig:788`.

**Goal:** When a task is running inside a workspace, the agent's system prompt should expose the other workspace items + tasks in the same workspace (their names, paths/cwds, item_types, task types) so the agent can **discover and navigate to siblings** without having to call a tool first.

**Architecture:** Finish the `buildWorkspaceTaskList` helper so it returns a fully-rendered markdown block (instead of `error.Unimplemented`). Wire that block into `buildMessages` → `build_agent_prompt` as a new dynamic section, gated on the task being bound to a workspace item (no-op for "lone" sessions). Add one short static preamble so the model knows *why* the section is there and *how* to use it.

**Tech Stack:** Zig 0.16, `std.Io.Threaded`, `SqliteBackend`. No new dependencies. No frontend changes in this plan (the UI already shows a 🌳 worktree badge on sessions with `git_worktree_cwd`; a workspace-context UI is a follow-up plan).

---

## Decisions locked during brainstorming

1. **Scope of "siblings" = workspace-items in the same workspace, plus the tasks under each.** Not "other tasks in the *same* item" (too narrow — the user wants cross-item discovery) and not "all sessions in the DB" (too broad). The SQL anchors on `workspace_item_tasks.session_id = ?` → `workspace_item_id` → `workspace_id`, then enumerates `workspace_items WHERE workspace_id = ?`.

2. **Use `session_id` (not `task_id`) as the helper's input.** The function signature already takes `session_id: []const u8`, matching the convention of `BuildSkillContent` / `BuildBackgroundProcessPrompt` / `BuildDynamicAgentContent` / `BuildSubAgentsListing`. Lookup chain: `session_id → workspace_item_tasks.session_id → workspace_item_id → workspace_id`. Sessions that aren't bound to any task get an empty result (no section, no error).

3. **Fix the existing SQL.** The draft in the stub has three bugs that the review of the next task will catch:
   - `wit.id = 'task_...'` is a literal in the WHERE; must be a bound parameter.
   - Joining `workspace_item_tasks` on the LEFT side produces a row per *task* per item, not one row per item. Use a CTE / subquery to find the workspace, then a single SELECT against `workspace_items` — no JOIN to `workspace_item_tasks` on the LEFT.
   - The `is_self` flag should compare against the **task's own item id** (one value), not the anchor's `wi2.id` (already implicit via the join). Restating the comparison makes the SQL self-documenting.

4. **Section header = `## Workspace Context`** (mirrors the existing `## Active Workers` / `## Running Background Processes` patterns at `prompts.zig:461, 622`). Sits right after `**Current working directory:**` and before `**Operating System:**` — i.e., between the cwd line and the OS line — so the "you are here" framing flows naturally: cwd → workspace siblings → OS info.

5. **Static preamble is one short paragraph**, not a multi-line rule block. Mirrors the `**Current working directory:**` line above and the `**Operating System:**` line below. The dynamic section itself contains the actionable content. No new `PROMPT_SECTIONS` entry needed; the preamble lives inside the dynamic block.

6. **No new tool.** Discovery happens at prompt-build time, not via an LLM call. The `list_workspaces` tool (or equivalent) is out of scope — this is *passive* awareness, not active exploration. Active exploration (e.g., "open the other task's chat history") goes through existing HTTP handlers via the `set_git_worktree`-style pattern in a follow-up plan.

7. **Empty case = silent skip.** When the session is not bound to any workspace task, `BuildWorkspaceContext` returns `""` and the section is omitted (matches `appendSkillsListing` and `loadGlobalKnowledge` behavior).

8. **Cap on sibling count = 20 items, 5 tasks per item.** A 50-task workspace would otherwise blow up the prompt. The cap is hard-coded; if exceeded, the section renders the first 20 items and a `… and N more items` footer. The cap is documented in the function's doc comment so it can be tuned without re-reading the implementation.

9. **No new migration.** The data model already supports everything (`workspace_items.workspace_id`, `workspace_items.path`, `workspace_item_tasks.workspace_item_id`, `workspace_item_tasks.session_id`). Existing indexes (`idx_workspace_items_workspace`, `idx_workspace_item_tasks_item`) cover the lookup.

10. **Sub-agent parity is out of scope.** `build_sub_agent_prompt` is a separate function. Sub-agents spawned by a parent that *does* see the section don't inherit it (they get the parent's system prompt via `inherited_context`, but the `Workspace Context` block lives in the parent's prompt, not in `inherited_context`'s `MessageHistory` payload). This is consistent with how the `## Available Sub-Agents` and `## Active Workers` sections behave — they're parent-prompt-only. A follow-up plan can decide whether to forward the section to sub-agents.

---

## File structure

### Modified files

```
src/ai_workflow/tui/
├── build_messages_for_agent_prompt.zig
│     (1) Replace `buildWorkspaceTaskList` stub with `BuildWorkspaceContext`
│     (2) Add a new `workspaceContext: []const u8` param to `buildMessages`
│     (3) Call `BuildWorkspaceContext(allocator, db, session_id)` and pass the result
│     (4) Update the existing 1 internal caller in `buildMessages` to thread the new value
│
├── build_messages_for_agent_prompt_test.zig          (new — see Chunk 1)
│     (5) Unit tests for `BuildWorkspaceContext` across 5 cases
│
├── llm_history.zig
│     (6) Add a new `getWorkspaceContext` helper that the tui's helper wraps
│         (so the SQL lives in `llm_history.zig` next to its siblings, mirroring
│          `getWorkspaceItem`, `listWorkspaceItems`, `getWorkspaceItemTask`,
│          `createWorkspaceItemTask` — see lines 2215, 2274, 2427, 2395)
│
src/modules/agent/
├── prompts.zig
│     (7) Add `workspaceContext: []const u8` param to `build_agent_prompt`
│     (8) Inject the `## Workspace Context` block right after the cwd line
│         (between line 445 and 447, before `// OS info.`)
│
src/ai_workflow/tui/
├── prompts_test.zig
│     (9) Add 4 tests for the new section: present, empty, many items, single task
│
src/ai_workflow/tui/
├── test_runner.zig
│     (10) Register the new `build_messages_for_agent_prompt_test.zig`
```

### Not modified (intentional)

- **No frontend changes.** The `WorkspaceContext` block is in the system prompt only. Surfacing it in the UI is a follow-up plan (analogous to the 🌳 worktree badge added in commit `eead77b1`).
- **No new tools.** Discovery is passive.
- **No new migrations.** The data model is complete.
- **No `PROMPT_SECTIONS` entry.** The preamble is part of the dynamic block, not a static section.

---

## Architecture diagram

```
buildMessages(cwd, session_id, ...) in build_messages_for_agent_prompt.zig
        │
        ├─► BuildSkillContent          (existing)
        ├─► BuildMemoryForAgent        (existing)
        ├─► BuildBackgroundProcessPrompt  (existing)
        ├─► BuildDynamicAgentContent   (existing)
        ├─► BuildSubAgentsListing      (existing)
        │
        └─► BuildWorkspaceContext(allocator, db, session_id) ◄── NEW
                │
                │ 1. session_id → workspace_item_tasks.session_id?
                │    no  → return ""
                │    yes → continue
                │
                │ 2. workspace_item_tasks → workspace_items.workspace_id
                │
                │ 3. SELECT all workspace_items in that workspace
                │    with (item.id = self_item_id) AS is_self
                │    ORDER BY is_self DESC, position DESC, id ASC
                │
                │ 4. For each item (max 20), SELECT its tasks
                │    (max 5 per item)
                │
                │ 5. Render as:
                │    "## Workspace Context\n\n"
                │    "<one-paragraph preamble>\n\n"
                │    "This task is part of workspace `<workspace_id>`. "
                │    "Sibling items (same workspace, listed for discovery):\n\n"
                │    "- **<name>** (item_type: `<type>`, path: `<path>`)"
                │    " *(this task)*"   ← when is_self
                │    "   - tasks: <task_name> (type: standard|routine, session: <sid>)"
                │    "… and N more items"
                │
                ▼
        workspaceContext: []const u8
                │
                ▼
        prompt.build_agent_prompt(..., workspaceContext)
                │
                └─► injects "## Workspace Context" block at line 446
```

---

## Chunk 1: SQL helper + unit tests (file 1 of 4)

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig` (add `getWorkspaceContext` near line 2330, next to `listWorkspaceItems`)
- Modify: `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` (replace lines 788-816)
- Create: `src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (register the new test file)

### Task 1.1: Write the failing test — `getWorkspaceContext` returns empty for unbound session

**Files:** `src/ai_workflow/tui/llm_history_test.zig` (existing; add to it) OR `src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig` (new — see below)

We add a new test file rather than touching the existing `llm_history.zig` test surface because the `Build*` helpers live in `build_messages_for_agent_prompt.zig` and the project convention (per `add_skill` / `edit_skill` precedent) is to colocate tests with the function under test.

```zig
const HANDLER_PATH = "src/ai_workflow/tui/build_messages_for_agent_prompt.zig";

test "BuildWorkspaceContext returns empty string for session not bound to any task" {
    const alloc = testing.allocator;
    var ctx = try setupDb();  // see setupDb below
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Create a workspace with 2 items and 3 tasks, NONE bound to our session.
    try seedWorkspace(ctx, alloc, .{
        .workspace_id = "ws_x",
        .items = &.{
            .{ .id = "wi_a", .path = "/abs/a" },
            .{ .id = "wi_b", .path = "/abs/b" },
        },
        .tasks = &.{
            .{ .id = "task_a1", .workspace_item_id = "wi_a", .session_id = "sess_other" },
            .{ .id = "task_b1", .workspace_item_id = "wi_b", .session_id = "sess_other" },
        },
    });

    const result = try build_messages.BuildWorkspaceContext(
        alloc, &ctx.db, "sess_lone",
    );
    defer alloc.free(result);

    try testing.expectEqualStrings("", result);
}
```

`setupDb` mirrors the pattern from `src/ai_workflow/tui/routines/model_test.zig:60-100` (use `std.Io.Threaded.init(alloc, .{})` + `db.init(io, ":memory:")` + `CREATE TABLE` for `workspace_items`, `workspace_item_tasks`, `workspaces`, `sessions`). See `@skill:zig-0.16-inmemory-sqlite-test-setup` for the boilerplate.

- [ ] **Step 1.1.1:** Create `src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig` with the test above and a `setupDb` helper that mirrors `model_test.zig`'s `setupDb` exactly.

- [ ] **Step 1.1.2:** Register the new file in `src/ai_workflow/tui/test_runner.zig` with `_ = @import("build_messages_for_agent_prompt_test.zig");` (in alphabetical order; the existing imports are sorted).

- [ ] **Step 1.1.3:** Run `timeout 180 zig build test --summary all 2>&1 | tail -n 20`. Expected: the new test **fails to compile** because `build_messages.BuildWorkspaceContext` does not exist yet. (We have to write the function before the test can run.)

### Task 1.2: Implement the `getWorkspaceContext` SQL helper in `llm_history.zig`

**Files:** Modify `src/ai_workflow/tui/llm_history.zig` (insert after `listWorkspaceItems` at line 2316)

- [ ] **Step 1.2.1:** Add `getWorkspaceContext` to `src/ai_workflow/tui/llm_history.zig`, placed immediately after the `listWorkspaceItems` definition (line 2316). The function returns `!?WorkspaceContext` — `null` when the session is not bound to any task, or a populated struct otherwise. **Definition:**

```zig
/// Context for the "Workspace Context" dynamic prompt section.
/// Returned by `getWorkspaceContext`; the tui layer's
/// `BuildWorkspaceContext` consumes this struct and renders
/// the markdown block.
pub const WorkspaceContext = struct {
    workspace_id: []u8,
    self_item_id: []u8,            // task's own item id
    self_task_id: []u8,            // task's own id
    self_path: ?[]u8,              // task's own item path (cwd hint)
    siblings: []SiblingItem,       // all items in the same workspace, self first
    truncated_items_count: u32,    // > 0 when 20-item cap hit
    total_item_count: u32,         // for diagnostic footer

    pub const SiblingItem = struct {
        id: []u8,
        item_type: []u8,
        name: ?[]u8,
        path: ?[]u8,
        is_self: bool,
        tasks: []SiblingTask,        // ≤ 5
        truncated_tasks_count: u32,   // > 0 when 5-task cap hit

        pub const SiblingTask = struct {
            id: []u8,
            name: []u8,
            task_type: []u8,
            session_id: ?[]u8,
        };
    };

    pub fn deinit(self: WorkspaceContext, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.self_item_id);
        allocator.free(self.self_task_id);
        if (self.path) |p| allocator.free(p);
        for (self.siblings) |sib| {
            allocator.free(sib.id);
            allocator.free(sib.item_type);
            if (sib.name) |n| allocator.free(n);
            if (sib.path) |p| allocator.free(p);
            for (sib.tasks) |t| {
                allocator.free(t.id);
                allocator.free(t.name);
                allocator.free(t.task_type);
                if (t.session_id) |sid| allocator.free(sid);
            }
            allocator.free(sib.tasks);
        }
        allocator.free(self.siblings);
    }
};

const MAX_SIBLING_ITEMS: u32 = 20;
const MAX_TASKS_PER_ITEM: u32 = 5;

/// Look up the workspace context for a session. Returns `null`
/// when the session is not bound to any workspace_item_task (the
/// caller omits the section silently in that case).
///
/// Anchor: `workspace_item_tasks.session_id = ?` → task → item → workspace.
/// Then enumerate `workspace_items WHERE workspace_id = ?` (capped at
/// MAX_SIBLING_ITEMS, ordered with self first). For each item,
/// enumerate its tasks (capped at MAX_TASKS_PER_ITEM).
pub fn getWorkspaceContext(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?WorkspaceContext {
    if (session_id.len == 0) return null;

    // 1. Anchor: find the task bound to this session.
    const anchor_sql =
        \\SELECT t.id, t.workspace_item_id, i.workspace_id, i.path
        \\FROM workspace_item_tasks t
        \\JOIN workspace_items i ON i.id = t.workspace_item_id
        \\WHERE t.session_id = ?
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
    anchor_row.deinit(allocator);

    // 2. Total item count for the "and N more" footer.
    var count_q = try db.query(allocator,
        "SELECT COUNT(*) FROM workspace_items wi WHERE wi.workspace_id = ?",
        &.{workspace_id},
    );
    defer count_q.deinit();
    const count_row = (try count_q.next()) orelse
        return WorkspaceContext{ .workspace_id = workspace_id, .self_item_id = self_item_id, .self_task_id = self_task_id, .self_path = self_path, .siblings = &.{}, .truncated_items_count = 0, .total_item_count = 0 };
    const total_item_count = try std.fmt.parseInt(u32, count_row.values[0], 10);
    count_row.deinit(count_row.allocator);  // ← (1) BUG: row.deinit(allocator) — see Pitfall 1 below

    // 3. Enumerate items (capped).
    var items_q = try db.query(allocator,
        \\SELECT wi.id, wi.item_type, wi.name, wi.path,
        \\       (wi.id = ?) AS is_self
        \\FROM workspace_items wi
        \\WHERE wi.workspace_id = ?
        \\ORDER BY is_self DESC, wi.position DESC, wi.id ASC
        \\LIMIT ?
    , &.{ self_item_id, workspace_id, &[_]u8{} });  // (2) LIMIT ? needs a u32, not a slice — see Pitfall 2
    defer items_q.deinit();

    var siblings: std.ArrayList(WorkspaceContext.SiblingItem) = .empty;
    errdefer {
        for (siblings.items) |s| s.deinit(allocator);  // ← (3) SiblingItem has no deinit method — see Pitfall 3
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

        // 4. Enumerate tasks under this item (capped).
        var tasks_q = try db.query(allocator,
            "SELECT id, name, task_type, COALESCE(session_id, '') FROM workspace_item_tasks t WHERE t.workspace_item_id = ? ORDER BY t.updated_at DESC LIMIT ?",
            &.{ item_id_owned, &[_]u8{} });  // (2) same bug
        defer tasks_q.deinit();

        var tasks: std.ArrayList(WorkspaceContext.SiblingTask) = .empty;
        errdefer {
            for (tasks.items) |t| {
                allocator.free(t.id);
                allocator.free(t.name);
                allocator.free(t.task_type);
                if (t.session_id) |sid| allocator.free(sid);
            }
            tasks.deinit(allocator);
        }

        while (try tasks_q.next()) |trow| {
            const t_id = try allocator.dupe(u8, trow.values[0]);
            const t_name = try allocator.dupe(u8, trow.values[1]);
            const t_type = try allocator.dupe(u8, trow.values[2]);
            const t_sid: ?[]u8 = if (trow.values[3].len > 0) try allocator.dupe(u8, trow.values[3]) else null;
            trow.deinit(allocator);
            try tasks.append(allocator, .{
                .id = t_id,
                .name = t_name,
                .task_type = t_type,
                .session_id = t_sid,
            });
        }

        // Truncation detection: see if there are more tasks than we loaded.
        var task_count_q = try db.query(allocator,
            "SELECT COUNT(*) FROM workspace_item_tasks t WHERE t.workspace_item_id = ?",
            &.{item_id_owned},
        );
        defer task_count_q.deinit();
        const task_count_row = (try task_count_q.next()) orelse
            std.debug.panic("COUNT(*) returned no rows", .{});
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
        .self_path = self_path,
        .siblings = try siblings.toOwnedSlice(allocator),
        .truncated_items_count = truncated_items_count,
        .total_item_count = total_item_count,
    };
}
```

**Pitfall 1 — `row.allocator` is not a thing.** The stub at line 814 (`std.debug.print("{s}\n", .{sql_query})`) is irrelevant; the real issue is in step 1.2.1's `count_row.deinit(count_row.allocator)` line. `row.deinit(allocator)` takes the allocator as a parameter (per `src/modules/databases/sqlite/Sqlite.zig:167`); `count_row.allocator` does not exist. Fix: use `count_row.deinit(allocator)`. Same fix needed for the `task_count_row.deinit(allocator)` call a few lines later. See project memory `zig-migration-tests-three-pitfalls.md` for the broader pattern.

**Pitfall 2 — SQLite `LIMIT ?` does not bind a `[]u8`.** Passing `&[_]u8{}` (an empty slice) for a `LIMIT` parameter is wrong. SQLite expects an integer literal or a bound numeric value. In `SqliteBackend`, the binding goes through the C API's `sqlite3_bind_text` family, which only accepts text — there's no `bind_int` path. Two safe patterns:
   - Stringify the int and bind as text (works for SQLite because it does implicit int coercion in `LIMIT`): `const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{MAX_SIBLING_ITEMS}); try db.query(..., &.{ self_item_id, workspace_id, limit_str }); defer allocator.free(limit_str);`
   - Inline the limit into the SQL as a literal (loses the parameterized feel but is unambiguous): `\\LIMIT {d}` with `MAX_SIBLING_ITEMS` formatted via `std.fmt.allocPrint` at SQL build time. Prefer the inlined approach — it matches the project's existing convention (see `routines/model.zig:170-176` where the index hint is inlined). **Use the inlined LIMIT for both the items query and the tasks query.**

**Pitfall 3 — `WorkspaceContext.SiblingItem.deinit` was defined on the parent, not the child.** The `errdefer` in step 1.2.1 calls `s.deinit(allocator)`, but the `deinit` method is on `WorkspaceContext`, not `WorkspaceContext.SiblingItem`. Two safe fixes:
   - Add `pub fn deinit(self: SiblingItem, allocator: std.mem.Allocator) void` to the inner struct, mirroring the parent.
   - Inline the cleanup at the errdefer site.
   
   Prefer the named method (cleaner) — the per-item cleanup is exactly 6 lines and matches the parent's deinit shape. **Add `pub fn deinit` to `SiblingItem`** as part of step 1.2.1 (so step 1.2.1 writes the correct code from the start). The body inlines the same 6 frees (id, item_type, name, path, tasks loop, tasks array) as the parent.

- [ ] **Step 1.2.2:** Add `pub fn deinit(self: WorkspaceContext.SiblingItem, allocator: std.mem.Allocator) void` inside the `SiblingItem` struct (NOT at file scope — Zig 0.16 requires struct methods to be declared inside the struct body).

- [ ] **Step 1.2.3:** Run `timeout 180 zig build test --summary all 2>&1 | tail -n 20`. Expected: the new test in step 1.1.3 **now compiles and passes**. (The test only checks the empty case, which the helper returns `null` for; the helper returns `null` after step 1.2.1's anchor lookup miss, never reaching the items query.)

### Task 1.3: Add tests for the populated case

**Files:** `src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig`

- [ ] **Step 1.3.1:** Add 4 more tests to the new test file:

```zig
test "BuildWorkspaceContext lists self item first with is_self flag" {
    // Seed: 1 workspace, 3 items (a=this task, b, c), 1 task per item.
    // Query: session bound to task_a1 (item wi_a).
    // Expect: 3 siblings, [0].is_self == true, [0].id == "wi_a".
}

test "BuildWorkspaceContext includes tasks under each item" {
    // Seed: 1 workspace, 2 items, wi_a has 3 tasks (this one + 2 others), wi_b has 1.
    // Expect: siblings[0].tasks.len == 3, siblings[1].tasks.len == 1.
}

test "BuildWorkspaceContext caps at 20 items and reports truncation" {
    // Seed: 1 workspace, 25 items.
    // Expect: siblings.len == 20, truncated_items_count == 5, total_item_count == 25.
}

test "BuildWorkspaceContext caps tasks at 5 per item" {
    // Seed: 1 workspace, 1 item with 8 tasks.
    // Expect: siblings[0].tasks.len == 5, truncated_tasks_count == 3.
}
```

Each test follows the same `setupDb` + `seedWorkspace` pattern from step 1.1.1. `seedWorkspace` takes a `WorkspaceSeed` struct:

```zig
const WorkspaceSeed = struct {
    workspace_id: []const u8,
    items: []const struct { id: []const u8, path: []const u8 },
    tasks: []const struct {
        id: []const u8,
        workspace_item_id: []const u8,
        session_id: []const u8,
    },
};

fn seedWorkspace(ctx: anytype, alloc: std.mem.Allocator, seed: WorkspaceSeed) !void {
    try ctx.db.exec(alloc,
        "INSERT INTO workspaces (id) VALUES (?)",
        &.{seed.workspace_id},
    );
    for (seed.items) |item| {
        try ctx.db.exec(alloc,
            "INSERT INTO workspace_items (id, workspace_id, item_type, path) VALUES (?, ?, 'chat', ?)",
            &.{ item.id, seed.workspace_id, item.path },
        );
    }
    for (seed.tasks) |task| {
        try ctx.db.exec(alloc,
            "INSERT INTO workspace_item_tasks (id, workspace_item_id, session_id, task_type) VALUES (?, ?, ?, 'standard')",
            &.{ task.id, task.workspace_item_id, task.session_id },
        );
    }
}
```

- [ ] **Step 1.3.2:** Run `timeout 180 zig build test --summary all 2>&1 | tail -n 20`. Expected: 4 new tests pass (in addition to the 1 from step 1.1.3). Test count goes from N to N+5.

- [ ] **Step 1.3.3:** Commit.

```bash
git add src/ai_workflow/tui/llm_history.zig \
        src/ai_workflow/tui/build_messages_for_agent_prompt.zig \
        src/ai_workflow/tui/build_messages_for_agent_prompt_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(workspace): add getWorkspaceContext SQL helper + 5 unit tests"
```

---

## Chunk 2: Build the markdown block (file 2 of 4)

**Files:** Modify `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` (replace `buildWorkspaceTaskList` stub at lines 788-816 with `BuildWorkspaceContext`)

### Task 2.1: Replace the stub with a real renderer

- [ ] **Step 2.1.1:** Replace the entire `buildWorkspaceTaskList` function (lines 788-816) with `BuildWorkspaceContext`. The new function:

```zig
/// Build a "## Workspace Context" section listing the workspace items
/// and tasks in the same workspace as the current task. Returns `""`
/// when the session is not bound to any workspace_item_task (caller
/// omits the section silently — matches `appendSkillsListing` behavior).
///
/// Cap: 20 items (siblings), 5 tasks per item. When exceeded, the
/// `… and N more` footer is rendered.
///
/// The block has this shape (omitted when empty):
///
/// ```markdown
/// ## Workspace Context
///
/// This task is part of workspace `<workspace_id>`. Sibling items
/// (same workspace, listed for discovery):
///
/// - **<name>** (item_type: `<type>`, path: `<path>`) *(this task)*
///   - task: `<task_name>` (type: standard|routine, session: `<sid>`)
///   - ...
/// - **<name>** (item_type: `<type>`, path: `<path>`)
///   - task: `<task_name>` ...
///
/// … and N more items in this workspace.
/// ```
///
/// Inserted into the system prompt right after the
/// `**Current working directory:**` line. See Chunk 3 for wiring.
pub fn BuildWorkspaceContext(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]const u8 {
    if (session_id.len == 0) return allocator.dupe(u8, "");

    const ctx = (llm_history.getWorkspaceContext(allocator, db, session_id) catch |err| {
        std.log.warn("BuildWorkspaceContext: lookup failed: {}", .{err});
        return allocator.dupe(u8, "");
    }) orelse return allocator.dupe(u8, "");
    defer ctx.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\n\n## Workspace Context\n\n");
    try out.appendSlice(allocator,
        \\This task is part of workspace `)
    ;
    try out.appendSlice(allocator, ctx.workspace_id);
    try out.appendSlice(allocator,
        \\`. The other items in this workspace are listed below for
        \\discovery — you can read or reference their files via `bash`,
        \\`read_file`, etc. by using the `path` shown for each item.
        \\
        \\The item marked *(this task)* is the one your session is bound
        \\to. Sibling items may be running other conversations; treat
        \\their files as a shared workspace, not as something to modify
        \\without the user asking.
        \\
    );

    if (ctx.self_path) |p| {
        try out.appendSlice(allocator,
            \\**Your task's working directory (cwd hint):** `)
        ;
        try out.appendSlice(allocator, p);
        try out.appendSlice(allocator, "`\n\n");
    } else {
        try out.appendSlice(allocator,
            \\**Your task's working directory:** (none recorded)\n\n)
        ;
    }

    for (ctx.siblings) |sib| {
        // "- **<name>** (item_type: `<type>`, path: `<path>`)"
        try out.appendSlice(allocator, "- **");
        if (sib.name) |n| {
            try out.appendSlice(allocator, n);
        } else {
            try out.appendSlice(allocator, sib.id);
        }
        try out.appendSlice(allocator, "** (item_type: `");
        try out.appendSlice(allocator, sib.item_type);
        try out.appendSlice(allocator, "`, path: `");
        if (sib.path) |p| {
            try out.appendSlice(allocator, p);
        } else {
            try out.appendSlice(allocator, "(none)");
        }
        try out.appendSlice(allocator, "`)");
        if (sib.is_self) try out.appendSlice(allocator, " *(this task)*");
        try out.appendSlice(allocator, "\n");

        for (sib.tasks) |t| {
            try out.appendSlice(allocator, "  - task: `");
            try out.appendSlice(allocator, t.name);
            try out.appendSlice(allocator, "` (type: ");
            try out.appendSlice(allocator, t.task_type);
            if (t.session_id) |sid| {
                try out.appendSlice(allocator, ", session: `");
                try out.appendSlice(allocator, sid);
                try out.appendSlice(allocator, "`");
            }
            try out.appendSlice(allocator, ")\n");
        }

        if (sib.truncated_tasks_count > 0) {
            const footer = try std.fmt.allocPrint(allocator,
                "    … and {d} more task{s} under this item\n",
                .{ sib.truncated_tasks_count, if (sib.truncated_tasks_count == 1) "" else "s" },
            );
            defer allocator.free(footer);
            try out.appendSlice(allocator, footer);
        }
    }

    if (ctx.truncated_items_count > 0) {
        const footer = try std.fmt.allocPrint(allocator,
            "\n… and {d} more item{s} in this workspace (cap: {d} shown).\n",
            .{ ctx.truncated_items_count, if (ctx.truncated_items_count == 1) "" else "s", MAX_SIBLING_ITEMS },
        );
        defer allocator.free(footer);
        try out.appendSlice(allocator, footer);
    }

    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 2.1.2:** Move the `MAX_SIBLING_ITEMS` and `MAX_TASKS_PER_ITEM` constants from `llm_history.zig` to a single file-scope `const` block at the top of `build_messages_for_agent_prompt.zig` (next to `SUB_AGENT_DESCRIPTION_MAX` at line 759 if it exists, or just below the imports). The helper in `llm_history.zig` re-exports them as `pub const MAX_SIBLING_ITEMS: u32 = ...;` so step 1.2.1's logic stays self-contained. The renderer uses the same values to format the cap footer.

- [ ] **Step 2.1.3:** Add a unit test for the rendered markdown (not just the data structure):

```zig
test "BuildWorkspaceContext renders markdown with self marker and tasks" {
    // Same seed as Task 1.3.1 ("self item first").
    // Build the markdown.
    // Assert contains: "## Workspace Context", "*(this task)*",
    //                  "item_type: `chat`", "session: `sess_self`".
}

test "BuildWorkspaceContext renders truncation footer" {
    // Same seed as Task 1.3.3 (25 items).
    // Assert contains: "and 5 more items", "cap: 20 shown".
}

test "BuildWorkspaceContext returns empty string for empty workspace" {
    // Seed: 1 workspace, 0 items, 0 tasks, session_id present but not bound.
    // Expect: empty string.
}
```

- [ ] **Step 2.1.4:** Run `timeout 180 zig build test --summary all 2>&1 | tail -n 20`. Expected: 3 new tests pass. Test count goes from N+5 to N+8.

- [ ] **Step 2.1.5:** Commit.

```bash
git add src/ai_workflow/tui/build_messages_for_agent_prompt.zig
git commit -m "feat(workspace): render Workspace Context markdown from getWorkspaceContext"
```

---

## Chunk 3: Wire into `buildMessages` and `build_agent_prompt` (files 3-4 of 4)

**Files:** Modify `src/ai_workflow/tui/build_messages_for_agent_prompt.zig` and `src/modules/agent/prompts.zig`

### Task 3.1: Thread the new value through `buildMessages`

- [ ] **Step 3.1.1:** Add a new parameter to `buildMessages` (line 23-51):

```zig
/// Optional explicit "active agent configuration" to inject as
/// the `## Your Active Agent Configuration` section of the
/// system prompt. When non-empty, this is used verbatim and
/// `BuildDynamicAgentContent` is NOT called. When empty (the
/// default), the function falls back to
/// `BuildDynamicAgentContent(db, session_id)` to read the list
/// of agents loaded via `change_agent` for this session.
///
/// Use cases:
///   - Main agent flow: caller passes `""` to use the
///     `session_agents` table contents.
///   - Sub-agent flow with a config-driven system_prompt:
///     caller passes the resolved `SubAgentConfig.system_prompt`
///     and it appears as the sub-agent's "active configuration".
///   - Sub-agent flow with random fallback: caller passes `""`
///     so the sub-agent gets the default scaffold with no
///     specialized configuration.
activeAgentContent: []const u8,
```

becomes:

```zig
activeAgentContent: []const u8,
/// When `true`, build the `## Workspace Context` section from
/// `BuildWorkspaceContext(db, session_id)`. When `false`, skip
/// the section (caller already provided a custom value, or
/// sub-agent flow that doesn't need workspace awareness).
/// Defaults to `true` for the main agent flow.
includeWorkspaceContext: bool = true,
```

- [ ] **Step 3.1.2:** After the existing `BuildSubAgentsListing` call (line 88), add:

```zig
const workspaceContext = if (includeWorkspaceContext)
    try BuildWorkspaceContext(allocator, db, session_id)
else
    try allocator.dupe(u8, "");
defer allocator.free(workspaceContext);
```

- [ ] **Step 3.1.3:** Pass `workspaceContext` to `build_agent_prompt` at line 91. Update the call signature to add a new last parameter `workspaceContext`. The current call:

```zig
const systemContent = try prompt.build_agent_prompt(allocator, io, cwd, skills, memoryMd, backgroundProcessmessage, agentUsed, tools, activity_info, environment, sub_agents_listing);
```

becomes:

```zig
const systemContent = try prompt.build_agent_prompt(
    allocator, io, cwd, skills, memoryMd, backgroundProcessmessage,
    agentUsed, tools, activity_info, environment, sub_agents_listing,
    workspaceContext,
);
```

### Task 3.2: Update `build_agent_prompt` to render the section

**Files:** `src/modules/agent/prompts.zig`

- [ ] **Step 3.2.1:** Add `workspaceContext: []const u8` as a new last parameter to `build_agent_prompt` (line 327-344). Update the docstring to mention it (line 303-326).

- [ ] **Step 3.2.2:** Render the section between the cwd line and the OS info. After line 445 (`}`) and before line 447 (`// OS info.`), add:

```zig
// Workspace context (siblings in the same workspace). Rendered
// between the cwd line and the OS info so the "you are here"
// framing flows: cwd → workspace siblings → OS info. The block
// already includes its `## Workspace Context` header (built by
// `BuildWorkspaceContext`); we just append it verbatim.
if (workspaceContext.len > 0) {
    try result.appendSlice(allocator, workspaceContext);
}
```

- [ ] **Step 3.2.3:** Update the call sites of `build_agent_prompt` in the project. There is currently one call in `build_messages_for_agent_prompt.zig:91` (handled by step 3.1.3). There is no sub-agent variant (`build_sub_agent_prompt`); the agent prompt builder is only called from `buildMessages`. Verify with `rg -n "build_agent_prompt\b" src/`. Expected: 1 call site (the one we updated).

- [ ] **Step 3.2.4:** Add a `prompts_test.zig` test for the new section:

```zig
test "build_agent_prompt renders Workspace Context when section is non-empty" {
    // Call build_agent_prompt with a workspaceContext that starts
    // with "## Workspace Context". Assert the output contains that
    // header verbatim. Mirrors the existing test pattern in
    // prompts_test.zig (e.g. "## Available Skills" presence tests).
}

test "build_agent_prompt omits Workspace Context when section is empty" {
    // Call with workspaceContext = "". Assert the output does NOT
    // contain "## Workspace Context".
}
```

- [ ] **Step 3.2.5:** Run `timeout 180 zig build test --summary all 2>&1 | tail -n 20`. Expected: 2 new tests pass. Test count goes from N+8 to N+10. **No regression in the existing 570+ tests.**

- [ ] **Step 3.2.6:** Commit.

```bash
git add src/ai_workflow/tui/build_messages_for_agent_prompt.zig \
        src/modules/agent/prompts.zig \
        src/ai_workflow/tui/prompts_test.zig
git commit -m "feat(workspace): inject Workspace Context section into system prompt"
```

### Task 3.3: Manual smoke test on port 8080

The project rule (per NALAR.md): another `nalar` process is always running on port 8081. Never kill it, never use it for new work. Use port 8080.

- [ ] **Step 3.3.1:** Build the binary.

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: 4/6 build steps succeed. The 5th is the `cp /usr/local/bin/nalar` step which fails harmlessly with permission denied (we are not root).

- [ ] **Step 3.3.2:** Start the binary on port 8080 in the background.

```bash
nohup ./zig-out/bin/nalar --port 8080 > /tmp/nalar-workspace-smoke.log 2>&1 &
echo $! > /tmp/nalar-workspace-smoke.pid
```

- [ ] **Step 3.3.3:** Set up a workspace with 3 items and 4 tasks via the existing REST API (see `src/ai_workflow/tui/http_handlers/workspace_items_create.zig` and `task_create.zig` for the wire formats). Specifically:

```bash
# 1. Create a workspace
curl -X POST http://127.0.0.1:8080/api/workspaces -H 'Content-Type: application/json' \
  -d '{"id":"ws_smoke_001","name":"Smoke Test"}'

# 2. Create 3 items in the workspace
curl -X POST http://127.0.0.1:8080/api/workspaces/ws_smoke_001/items -H 'Content-Type: application/json' \
  -d '{"id":"wi_a","item_type":"chat","name":"Frontend","path":"/tmp/smoke-frontend"}'
curl -X POST http://127.0.0.1:8080/api/workspaces/ws_smoke_001/items -H 'Content-Type: application/json' \
  -d '{"id":"wi_b","item_type":"chat","name":"Backend","path":"/tmp/smoke-backend"}'
curl -X POST http://127.0.0.1:8080/api/workspaces/ws_smoke_001/items -H 'Content-Type: application/json' \
  -d '{"id":"wi_c","item_type":"chat","name":"Docs","path":"/tmp/smoke-docs"}'

# 3. Create 4 tasks (3 in wi_a, 1 in wi_b)
curl -X POST http://127.0.0.1:8080/api/workspaces/ws_smoke_001/items/wi_a/tasks -H 'Content-Type: application/json' \
  -d '{"id":"task_a1","name":"Setup","session_id":"sess_self"}'
curl -X POST http://127.0.0.1:8080/api/workspaces/ws_smoke_001/items/wi_a/tasks -H 'Content-Type: application/json' \
  -d '{"id":"task_a2","name":"Build","session_id":"sess_other_a"}'
curl -X POST http://127.0.0.1:8080/api/workspaces/ws_smoke_001/items/wi_a/tasks -H 'Content-Type: application/json' \
  -d '{"id":"task_a3","name":"Deploy","session_id":"sess_other_a"}'
curl -X POST http://127.0.0.1:8080/api/workspaces/ws_smoke_001/items/wi_b/tasks -H 'Content-Type: application/json' \
  -d '{"id":"task_b1","name":"API","session_id":"sess_other_b"}'
```

- [ ] **Step 3.3.4:** Trigger a single LLM call on `sess_self` (the task bound to `task_a1`). Use the existing `/api/llm/stream/sess_self` endpoint with a 1-token prompt (e.g. `"hi"`). Capture the system prompt from the SSE log or the agent process log. Expected: the system prompt contains `## Workspace Context` listing the 3 items (Frontend, Backend, Docs), with `Frontend` marked `*(this task)*` and listing its 3 tasks (Setup, Build, Deploy).

- [ ] **Step 3.3.5:** Trigger a single LLM call on a session NOT bound to any task (e.g. `sess_lone`). Expected: the system prompt does NOT contain `## Workspace Context`.

- [ ] **Step 3.3.6:** Stop the binary.

```bash
kill $(cat /tmp/nalar-workspace-smoke.pid)
rm -f /tmp/nalar-workspace-smoke.pid /tmp/nalar-workspace-smoke.log
```

- [ ] **Step 3.3.7:** Commit the smoke-test artifacts if any (none expected; the binary's stdout goes to the log file we just removed).

---

## Verification (run before declaring done)

```bash
# 1. Tests
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build test --summary all 2>&1 | tail -n 10
# Expected: "test success" and N+10 tests (was ~573 before this plan; new
# 5 unit tests for the SQL helper, 3 for the renderer, 2 for build_agent_prompt).
# No regressions.

# 2. Build
timeout 180 zig build install:linux:system 2>&1 | tail -n 5
# Expected: 4/6 steps succeed (the cp step fails harmlessly).

# 3. Frontend (no changes, just confirm not broken)
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 120 bunx vitest run 2>&1 | tail -n 20
# Expected: both clean.

# 4. Manual smoke (see Chunk 3.3 above)
```

---

## Out of scope (follow-up plans)

- **Frontend workspace-context UI.** A tab or panel showing the siblings visually (analogous to the 🌳 worktree badge added in commit `eead77b1`). Single task: ~150 lines Vue + a new `GET /api/sessions/:id/workspace-context` endpoint (5 lines of handler).
- **Forward `## Workspace Context` to sub-agents.** Sub-agents spawned by a parent that has the section don't inherit it. Decide whether to (a) pass it via `inherited_context`, (b) re-render it in `build_sub_agent_prompt`, or (c) keep it parent-only.
- **Read sibling task history via a new tool.** Today the agent can only see the *names* of sibling tasks. A `view_sibling_task` tool that returns the last N messages of a sibling session's chat history would let the agent actually read the sibling's context. Mirrors `set_git_worktree`'s pattern: small tool, calls an existing endpoint internally.
- **Tunable cap.** `MAX_SIBLING_ITEMS = 20` and `MAX_TASKS_PER_ITEM = 5` are hard-coded. If users complain that the section is too long, expose them as config in `~/.config/nalar/config.json`. The constants are at the top of `build_messages_for_agent_prompt.zig`; changing them is a one-line diff.
- **Filter by task type.** The current implementation lists both `standard` and `routine` tasks. If routine-only users complain about clutter, add a `task_types: ?[]const []const u8` parameter to `BuildWorkspaceContext` and filter at the SQL level.

---

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| The `LIMIT ?` parameter binding fails for integers (Pitfall 2) | High | Compile error or runtime SQL error | Use inlined `LIMIT {d}` at SQL build time (matches `routines/model.zig` precedent) |
| Prompt bloat with many siblings (50+ items) | Medium | Slow first-token latency, $$ cost | 20-item cap + `… and N more` footer. Tunable constant. |
| Sessions not yet bound to a task (race condition at session create) | Low | `## Workspace Context` flickers in/out across messages | Helper returns `""` for unbound sessions; section silently omitted. |
| `row.deinit(allocator)` vs `row.deinit(allocator)` typo (Pitfall 1) | Medium | Use-after-free in tests | Step 1.2.1 uses `allocator` (the parameter) consistently; the test in 1.3 fails red-green if there's a use-after-free. |
| SQL `is_self` subquery vs inlined comparison (Task 1.2) | Low | Wrong self item marked | Use the inlined `(wi.id = ?) AS is_self` pattern with `self_item_id` as the bound parameter; sort `ORDER BY is_self DESC` to put self first deterministically. |
| The 4 items-cap constant `MAX_SIBLING_ITEMS` is hard-coded twice (in `llm_history.zig` and `build_messages_for_agent_prompt.zig`) | Low | Drift if one is updated and the other isn't | Step 2.1.2 centralizes them via a `pub const` re-export. |
