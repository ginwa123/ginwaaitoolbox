# Workspace Item Task Pagination (Click-to-Load) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cursor-paginated "Load More" pagination to the task list shown inside each expanded `WorkspaceItem` in the desktop sidebar. The user must click a button to fetch the next page; there is no auto-load / infinite scroll.

**Architecture:** Extend the existing `GET /api/workspaces/:workspace_id/items/:item_id/tasks` endpoint with `limit` + `cursor` query params and a `has_more` / `next_cursor` response shape (mirroring `getChatHistory` / `session_list.zig`). Store the pagination state per-item in the existing `workspaces` Pinia store, render a single "Load More" button at the bottom of the task list in `WorkspaceItem.vue`. Each item's task list is independent — the button and pagination state live per-item, not per-workspace or globally.

**Tech Stack:** Zig 0.15 (backend handler + DB layer), TypeScript / Vue 3 / Pinia (frontend store + component), Vitest (frontend tests).

---

## File Structure

### Backend (Zig)

- **Modify** `src/ai_workflow/tui/http_handlers/tasks_list.zig` — parse `limit` and `cursor` query params, call new cursor-based DB function, return `has_more` / `next_cursor` in the response.
- **Modify** `src/ai_workflow/tui/http_handlers/http_response.zig:295-310` — add `has_more: bool` and `next_cursor: ?[]const u8 = null` to `WorkspaceItemTaskListResponse`; update `makeWorkspaceItemTaskListResponse` to accept and serialize the new fields.
- **Modify** `src/ai_workflow/tui/llm_history.zig:2343-2373` — add `listWorkspaceItemTasksWithCursor(allocator, db, item_id, limit, cursor)` (cursor = `created_at` of the last task from the previous page, same key-pagination pattern as `getSessionListWithCursor`).
- **Create** `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` — integration-style tests for the handler (limit, cursor, has_more, next_cursor). Wire into `test_runner.zig` if one exists in that subtree; otherwise rely on the project's existing test harness (see verification step).

### Frontend (TypeScript / Vue)

- **Modify** `src/apps/desktop/src/api/index.ts:135-139` — extend `getTasks(workspaceId, itemId, limit?, cursor?)` to accept optional pagination params, parse `has_more` / `next_cursor` from the response.
- **Modify** `src/apps/desktop/src/stores/workspaces.ts:14, 65, 169-180, 640-675` — extend the `WorkspaceItem` interface (or use a sibling `Record<string, …>`) with `hasMoreTasks: boolean` + `tasksNextCursor: string | null` + `isLoadingMoreTasks: boolean`; add `loadMoreTasks(workspaceId, itemId)` action; update `init()` to seed those fields from the first page.
- **Modify** `src/apps/desktop/src/components/WorkspaceItem.vue:125-166` — render a "Load More" button at the bottom of the task list, gated on `item.hasMoreTasks`, with a spinner while `item.isLoadingMoreTasks`. Emit a `loadMoreTasks` event so `WorkspaceList` can route the call to the store (keeps the store reference at the parent level, matching the existing `addTask` / `selectTask` event pattern).
- **Modify** `src/apps/desktop/src/components/WorkspaceList.vue:14-25, 99-109, 207-218` — add `loadMoreTasks: [workspaceId, itemId]` to `defineEmits`, forward the `WorkspaceItem` `@load-more-tasks` event to the parent (`AppLayout` / `Sidebar`) where the store action is invoked.
- **Modify** the parent (likely `AppLayout.vue` or `Sidebar.vue` — confirm during execution) — add a `handleLoadMoreTasks(workspaceId, itemId)` that calls `workspacesStore.loadMoreTasks(workspaceId, itemId)`.
- **Create** `src/apps/desktop/src/__tests__/workspaceItemTaskLoadMore.spec.ts` — unit tests for: store's `loadMoreTasks` appends + advances cursor; store hides button when `has_more === false`; component renders button when `hasMoreTasks`, hides otherwise; click triggers store call.

---

## Design Notes (read first)

1. **Default page size: 20.** Chosen to match the `loadMoreChats` pattern in `ChatsList.vue:171`. Reasonable for a sidebar task list — fits comfortably and rarely needs more than one or two loads per session.
2. **Cursor = `created_at` timestamp string of the last task from the previous page.** Same pattern as `getSessionListWithCursor` (`llm_history.zig:416` bug-fix entry). Tasks are ordered `created_at DESC`, so a `WHERE created_at < ?` cursor yields the next older page.
3. **Per-item state, not a global "all tasks" fetch.** Each `WorkspaceItem` has its own `hasMoreTasks` + `tasksNextCursor` because the task lists of different items are independent. The init() code that fans out per-item (`workspaces.ts:169-180`) already supports this shape — extend it to seed pagination fields.
4. **Existing patterns to copy:**
   - Handler: `src/ai_workflow/tui/http_handlers/session_list.zig:11-55` — the `limit` / `cursor` parsing + `has_more` computation. Mirror this exactly.
   - Frontend state: `src/apps/desktop/src/components/ChatsList.vue:164-189` (`loadMoreChats`) — `chatsLoading` guard, `chatsHasMore` + `chatsNextCursor`, append, then update both fields.
5. **`unshift` for new tasks is preserved.** `addTask` (`workspaces.ts:407-435`) prepends new tasks to `item.tasks`. This still works with pagination because new tasks have the *latest* `created_at` and live in the "first page" zone. The cursor only advances as the user clicks "Load More" *downward* (older tasks).
6. **No changes to:**
   - `createTask` / `updateTask` / `deleteTask` handlers
   - The DB schema / migrations (the existing `idx_workspace_item_tasks_item_created` index from `migration.zig:644` already covers the cursor query)
   - The `addTask` action semantics (it `unshift`s; pagination is for older/historical tasks)
7. **Verification commands** (always run before claiming done):
   - Backend: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | tail -n 30` (build)
   - Backend tests: find the existing test runner in this codebase (likely `src/test_runner.zig` or invoked via `zig build test`) — use that. If the project has a `run_tests.sh` or similar, prefer it.
   - Frontend: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30` (TS check + build — per the mandatory rule, NOT `build-only`)
   - Frontend tests: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 120 bun run test:run 2>&1 | tail -n 50` (or whatever the project uses; check `package.json` `scripts`).

---

# Chunk 1: Backend Pagination

## Task 1.1: Add cursor-based DB query function

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig:2343-2373`

- [ ] **Step 1: Read the existing `listWorkspaceItemTasks` and the `getSessionListWithCursor` for reference**

Verify the surrounding imports and types (`WorkspaceItemTaskInfo`, `sqlite.SqliteBackend`). The new function lives right after the existing `listWorkspaceItemTasks` (line 2373).

- [ ] **Step 2: Add `listWorkspaceItemTasksWithCursor`**

Add directly below the existing `listWorkspaceItemTasks` (line 2373). Signature:

```zig
/// List workspace item tasks with cursor pagination. `cursor` is the
/// `created_at` string of the last task from the previous page; pass null
/// to fetch the first page. Ordered by `created_at DESC` (newest first).
/// Returns at most `limit` tasks plus a `has_more` flag indicating whether
/// at least one more task exists after this page.
pub fn listWorkspaceItemTasksWithCursor(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    limit: u32,
    cursor: ?[]const u8,
) !struct {
    tasks: []WorkspaceItemTaskInfo,
    has_more: bool,
} {
    // Fetch `limit + 1` rows when cursor is set, `limit` when not. We
    // detect "has more" by checking whether we got more than `limit` rows.
    // (Matches the `getSessionListWithCursor` has_more pattern.)
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(
        allocator,
        "SELECT id, name, workspace_item_id, session_id, created_at, updated_at FROM workspace_item_tasks WHERE workspace_item_id = ?",
    );
    if (cursor) |c| {
        try sql.appendSlice(allocator, " AND created_at < ?");
    }
    try sql.appendSlice(allocator, " ORDER BY created_at DESC LIMIT ?");

    // Bind params in the same order they appear in the SQL.
    const fetch_limit: u32 = limit + 1;
    var rows: std.sqlite.Rows = if (cursor) |c|
        try db.query(allocator, sql.items, &.{ workspace_item_id, c, &fetch_limit })
    else
        try db.query(allocator, sql.items, &.{ workspace_item_id, &fetch_limit });
    defer rows.deinit();

    var tasks = std.ArrayList(WorkspaceItemTaskInfo).empty;
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const task = WorkspaceItemTaskInfo{
            .id = try allocator.dupe(u8, row.values[0]),
            .name = try allocator.dupe(u8, row.values[1]),
            .workspace_item_id = try allocator.dupe(u8, row.values[2]),
            .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
            .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
            .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
        };
        try tasks.append(allocator, task);
        row.deinit(allocator);
    }

    const has_more = tasks.items.len > limit;
    if (has_more) {
        // Drop the extra row we fetched to detect has_more.
        const extra = tasks.pop().?;
        extra.deinit(allocator);
    }

    return .{
        .tasks = try tasks.toOwnedSlice(allocator),
        .has_more = has_more,
    };
}
```

**Adapt the SQLite API** to whatever the project actually uses. Look at `getSessionListWithCursor` (`llm_history.zig:416` bug-fix entry mentions it) for the exact call pattern — `db.query` signature, parameter binding style, and `Rows`/`row.next()` API may differ from the skeleton above. The `WorkspaceItemTaskInfo` type and its `deinit(allocator)` method are confirmed to exist (used by the current `listWorkspaceItemTasks`).

- [ ] **Step 3: Build the project to confirm the new function compiles**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 60 zig build 2>&1 | tail -n 20`
Expected: builds cleanly (or only pre-existing warnings).

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/llm_history.zig
git commit -m "feat(backend): add listWorkspaceItemTasksWithCursor for paginated task listing"
```

---

## Task 1.2: Extend the response type to carry pagination fields

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig:295-310`

- [ ] **Step 1: Update `WorkspaceItemTaskListResponse` to include pagination fields**

```zig
pub const WorkspaceItemTaskListResponse = struct {
    tasks: []const WorkspaceItemTaskResponse,
    count: u32,
    has_more: bool = false,
    next_cursor: ?[]const u8 = null,
};
```

- [ ] **Step 2: Update `makeWorkspaceItemTaskListResponse` to accept the new fields**

```zig
pub fn makeWorkspaceItemTaskListResponse(
    allocator: std.mem.Allocator,
    tasks: []const WorkspaceItemTaskResponse,
    has_more: bool,
    next_cursor: ?[]const u8,
) ![]u8 {
    const response = WorkspaceItemTaskListResponse{
        .tasks = tasks,
        .count = @intCast(tasks.len),
        .has_more = has_more,
        .next_cursor = next_cursor,
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}
```

- [ ] **Step 3: Build to confirm**

Run: `timeout 60 zig build 2>&1 | tail -n 20`
Expected: build fails at the existing `tasks_list.zig:42` call site (the old 2-arg call signature) — this is expected. Leave the failure; Task 1.3 will fix it.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/http_response.zig
git commit -m "feat(backend): add has_more and next_cursor to WorkspaceItemTaskListResponse"
```

---

## Task 1.3: Wire the handler to use cursor pagination

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/tasks_list.zig:8-43`

- [ ] **Step 1: Read the existing handler**

Already familiar from exploration (`tasks_list.zig:8-43`). Note: it only takes `item_id` from path params and ignores query params.

- [ ] **Step 2: Rewrite the handler to parse query params and call the cursor function**

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

/// Default page size when the client doesn't pass `limit`.
const DEFAULT_PAGE_SIZE: u32 = 20;

/// Maximum page size (guards against a client asking for a million rows).
const MAX_PAGE_SIZE: u32 = 100;

/// GET /api/workspaces/:workspace_id/items/:item_id/tasks
/// Optional query params:
///   - limit: u32, defaults to 20, max 100
///   - cursor: string (the `created_at` of the last task from the previous page)
/// Response: `{ tasks: [...], count, has_more, next_cursor }`
pub fn tasksListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const query = req.query;

    // Parse limit (default 20, clamp to MAX_PAGE_SIZE)
    const limit_str = query.get("limit") orelse "20";
    const limit_parsed = std.fmt.parseInt(u32, limit_str, 10) catch DEFAULT_PAGE_SIZE;
    const limit: u32 = if (limit_parsed == 0) DEFAULT_PAGE_SIZE else if (limit_parsed > MAX_PAGE_SIZE) MAX_PAGE_SIZE else limit_parsed;

    // Optional cursor — null when absent or empty
    const cursor_raw = query.get("cursor");
    const cursor: ?[]const u8 = if (cursor_raw) |c| (if (c.len == 0) null else c) else null;

    const result = ai_mod.workspace_item_tasks.listWorkspaceItemTasksWithCursor(allocator, sqlite_db, item_id, limit, cursor) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch tasks" }) });
    };
    defer {
        for (result.tasks) |task| task.deinit(allocator);
        allocator.free(result.tasks);
    }

    // Convert to response format
    var task_responses = std.ArrayList(http_response.WorkspaceItemTaskResponse).empty;
    defer task_responses.deinit(allocator);

    for (result.tasks) |task| {
        try task_responses.append(allocator, http_response.WorkspaceItemTaskResponse{
            .id = task.id,
            .name = task.name,
            .workspace_item_id = task.workspace_item_id,
            .session_id = task.session_id,
            .created_at = task.created_at,
            .updated_at = task.updated_at,
        });
    }

    // next_cursor: the created_at of the last task in THIS page, when
    // has_more is true. null otherwise (so the frontend knows to stop).
    const next_cursor: ?[]const u8 = if (result.has_more and result.tasks.len > 0)
        result.tasks[result.tasks.len - 1].created_at
    else
        null;

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemTaskListResponse(allocator, task_responses.items, result.has_more, next_cursor) });
}
```

**Note:** `result.tasks[result.tasks.len - 1].created_at` is an `?[]const u8`. Add a null-check fallback if the compiler complains (the DB schema marks `created_at` NOT NULL, but be defensive):

```zig
const next_cursor: ?[]const u8 = blk: {
    if (!result.has_more) break :blk null;
    if (result.tasks.len == 0) break :blk null;
    return result.tasks[result.tasks.len - 1].created_at orelse null;
};
```

- [ ] **Step 3: Build to confirm**

Run: `timeout 60 zig build 2>&1 | tail -n 20`
Expected: clean build (this is the second half of the API contract change; the previous task's build failure is resolved here).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/tasks_list.zig
git commit -m "feat(backend): paginate tasks_list handler with limit and cursor"
```

---

## Task 1.4: Add integration tests for the handler

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/tasks_list_test.zig`
- Possibly: register in `src/test_runner.zig` or equivalent (look for the existing pattern in the repo before creating the file — search for other `_test.zig` files and how they're wired up).

- [ ] **Step 1: Find the existing test harness pattern**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
rg "tasks_update_test|tasks_create_test|tasks_delete_test" --type zig
```

Use the same harness style for `tasks_list_test.zig`. If there's a `test_runner.zig` in `src/ai_workflow/tui/http_handlers/`, add `_ = @import("tasks_list_test.zig");` there. If tests are auto-discovered, no extra wiring is needed.

- [ ] **Step 2: Write the tests**

Use the existing `tasks_update_test.zig` / `tasks_create_test.zig` as the structural reference (DB setup, teardown, etc.). The tests should cover:

```zig
test "tasksListHandler returns first page with default limit" {
    // Seed 25 tasks for a known item_id.
    // Call handler with no query params.
    // Assert: response.count == 20, has_more == true, next_cursor != null,
    //         tasks[0] is the newest (latest created_at).
}

test "tasksListHandler respects limit query param" {
    // Seed 10 tasks. Call with ?limit=5.
    // Assert: count == 5, has_more == false, next_cursor == null.
}

test "tasksListHandler advances with cursor" {
    // Seed 30 tasks. Fetch with ?limit=10. Use next_cursor.
    // Fetch again with ?limit=10&cursor=<previous next_cursor>.
    // Assert: second page is older than first (every created_at <
    //         every created_at from the first page).
    //         If 30 total and 10 per page, second has_more == true.
}

test "tasksListHandler reaches end and signals has_more=false" {
    // Seed 5 tasks. Fetch with ?limit=10.
    // Assert: count == 5, has_more == false, next_cursor == null.
}

test "tasksListHandler clamps limit at MAX_PAGE_SIZE" {
    // Seed 5 tasks. Fetch with ?limit=99999.
    // Assert: limit is clamped (count == 5 since we only have 5, but the
    //         handler should not error).
}

test "tasksListHandler returns 400 when item_id is missing" {
    // Call handler with no item_id path param.
    // Assert: status_code == 400.
}
```

Use the project's standard mock HTTP context (whatever `tasks_create_test.zig` uses) so the test doesn't hit a real DB. The exact mocking pattern is project-specific — read one of the existing test files in the same directory first.

- [ ] **Step 3: Run the tests**

Use the project's test command. Per project rules, check for an existing `run_tests.sh`, `zig build test`, or `bun run test:zig` script. If none exists, find the test runner by looking at `build.zig`. Then run it and confirm all `tasks_list_test.zig` tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/tasks_list_test.zig
# Also add the test_runner.zig entry if you had to wire it up.
git commit -m "test(backend): add integration tests for paginated tasks_list handler"
```

---

# Chunk 2: Frontend API + Store

## Task 2.1: Extend the frontend `getTasks` API helper

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:135-139`

- [ ] **Step 1: Update `getTasks` to support pagination**

```typescript
/**
 * Fetch tasks for a workspace item, with optional cursor pagination.
 *
 * @param workspaceId  - owning workspace
 * @param itemId       - workspace item (e.g. a project folder)
 * @param limit        - page size (default 20; backend clamps at 100)
 * @param cursor       - the `created_at` of the last task from the previous
 *                       page; pass undefined for the first page
 * @returns `{ tasks, has_more, next_cursor }`. `next_cursor` is null when
 *          there are no more pages.
 */
export async function getTasks(
  workspaceId: string,
  itemId: string,
  limit = 20,
  cursor?: string,
): Promise<{
  tasks: Task[]
  has_more: boolean
  next_cursor: string | null
}> {
  const params = new URLSearchParams()
  params.set('limit', String(limit))
  if (cursor) {
    params.set('cursor', cursor)
  }
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks?${params.toString()}`,
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const data = await response.json()
  return {
    tasks: data.tasks ?? [],
    has_more: data.has_more ?? false,
    next_cursor: data.next_cursor ?? null,
  }
}
```

**Behavior preserved:** all current callers that call `getTasks(workspaceId, itemId)` with no extra args get `{ tasks, has_more, next_cursor }` instead of `{ tasks }`. Update each caller in Task 2.2 / 2.3 to handle the new shape (most just destructure `tasks`).

- [ ] **Step 2: Build the frontend to confirm types**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30`
Expected: clean (or only pre-existing warnings unrelated to this change).

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(frontend): extend getTasks API helper with limit and cursor"
```

---

## Task 2.2: Add per-item pagination state and `loadMoreTasks` action to the store

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts:14, 169-180, 407-435, 460-489, 640-675`

- [ ] **Step 1: Extend the `WorkspaceItem` interface (line 14)**

Add three optional fields:

```typescript
export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  path?: string
  lastAccessed?: Date
  entries?: FolderEntry[]
  isLoaded?: boolean
  isLoading?: boolean
  expanded?: boolean
  tasks?: Task[]
  // Pagination state for the task list. Populated when tasks are first
  // fetched; reset whenever tasks are reloaded. `null` next_cursor means
  // there are no more pages. `isLoadingMoreTasks` is per-item and
  // independent of `isLoading` (which is for the folder entry fetch).
  hasMoreTasks?: boolean
  tasksNextCursor?: string | null
  isLoadingMoreTasks?: boolean
}
```

- [ ] **Step 2: Seed the new fields in `init()` (lines 169-180)**

The per-item fan-out already calls `api.getTasks(ws.id, item.id)` — switch to the new response shape and populate the pagination fields:

```typescript
await Promise.all(
  (items || []).map(async (item: WorkspaceItem) => {
    try {
      const { tasks, has_more, next_cursor } = await api.getTasks(ws.id, item.id)
      tasksByItem.set(item.id, tasks)
      // Stash pagination state on the item object directly. The spread
      // below (line ~186-192) will copy these into the final item.
      item.hasMoreTasks = has_more
      item.tasksNextCursor = next_cursor
    } catch (err) {
      console.error(`Failed to fetch tasks for item ${item.id}:`, err)
    }
  }),
)
```

(Don't change the final `.map((item) => ({ ...item, … }))` — the spread will pick up the new fields automatically.)

- [ ] **Step 3: Preserve the new fields in `addTask` and `deleteTask`**

- **`addTask` (lines 407-435):** when prepending a new task, also clear the cursor *if this new task is "newer" than what was loaded*. Since `addTask` `unshift`s a freshly-created task (it has the latest `created_at`), and the existing `tasksNextCursor` points to the *oldest loaded task's* `created_at`, the new task is newer than the cursor. The cursor is still valid for "older than the oldest loaded task" — so the cursor is **unchanged** by `addTask`. However, `hasMoreTasks` should remain whatever it was. No change needed.

  But: if `hasMoreTasks` was `false` (first page covered everything) and we add a new task, we now have N+1 tasks but the page is no longer "complete" — the user should still see all of them. We just keep `hasMoreTasks: false`. No change.

- **`deleteTask` (lines 460-489):** does not touch pagination state. Deleting a task shrinks the current page but doesn't add new "has more" — the cursor still points to the same point in the timeline. No change.

- **Both functions are safe to leave as-is.** Only `init()` and the new `loadMoreTasks` action (next step) touch the new fields.

- [ ] **Step 4: Add the `loadMoreTasks` action**

Insert after the `deleteTask` action (around line 489):

```typescript
// Load the next page of tasks for a workspace item. No-op if there are
// no more pages, a load is already in progress for this item, or the
// item / workspace can't be found.
async function loadMoreTasks(workspaceId: string, itemId: string) {
  const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
  if (!workspace) return
  const item = workspace.items.find((i) => i.id === itemId)
  if (!item) return
  if (item.isLoadingMoreTasks) return
  if (!item.hasMoreTasks) return
  if (!item.tasksNextCursor) return

  item.isLoadingMoreTasks = true
  try {
    const { tasks, has_more, next_cursor } = await api.getTasks(
      workspaceId,
      itemId,
      20, // PAGE_SIZE — keep in sync with the default in api/index.ts
      item.tasksNextCursor,
    )
    // Append the new page to the existing list. We push (not unshift)
    // because tasks are ordered newest-first, so older tasks go at the
    // end of the list.
    if (!item.tasks) item.tasks = []
    item.tasks.push(...tasks)
    item.hasMoreTasks = has_more
    item.tasksNextCursor = next_cursor
  } catch (err) {
    console.error(`Failed to load more tasks for item ${itemId}:`, err)
    // Leave hasMoreTasks/cursor as-is so the user can retry by clicking
    // the button again. Do not surface a toast — keep the failure mode
    // quiet (same pattern as addTask's catch block).
  } finally {
    item.isLoadingMoreTasks = false
  }
}
```

- [ ] **Step 5: Export `loadMoreTasks` from the store (lines 640-675)**

Add `loadMoreTasks,` to the returned object alongside `deleteTask`:

```typescript
return {
  // State
  // ...
  // Actions
  // ...
  addTask,
  toggleTask,
  deleteTask,
  loadMoreTasks,   // ← new
  // ...
}
```

- [ ] **Step 6: Build the frontend to confirm types**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add src/apps/desktop/src/stores/workspaces.ts
git commit -m "feat(frontend): add per-item pagination state and loadMoreTasks action"
```

---

## Task 2.3: Add a store-level test for `loadMoreTasks`

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspacesStoreLoadMoreTasks.spec.ts`

- [ ] **Step 1: Read the existing `workspacesStoreInit.spec.ts` to learn the test setup pattern**

This test file already exists in `src/apps/desktop/src/__tests__/`. Use it as a template for how to instantiate the store, mock `api.getTasks`, and assert state.

- [ ] **Step 2: Write the tests**

```typescript
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useWorkspacesStore } from '../stores/workspaces'

// Mock the api module — see workspacesStoreInit.spec.ts for the
// project's preferred mocking style (vi.mock, dependency injection, etc.).
vi.mock('../api', () => ({
  getWorkspaces: vi.fn(),
  getWorkspacesItems: vi.fn(),
  getTasks: vi.fn(),
  // ... other methods the store uses during init()
}))

import * as api from '../api'

describe('workspacesStore.loadMoreTasks', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('appends the next page to the existing tasks and advances the cursor', async () => {
    // Arrange: a workspace with one item whose initial fetch returned
    //   tasks [A, B, C], has_more=true, next_cursor='C-time'.
    //   Mock the second call to api.getTasks to return
    //   tasks [D, E], has_more=false, next_cursor=null.
    // Act: call store.loadMoreTasks(wsId, itemId).
    // Assert: item.tasks === [A, B, C, D, E], item.hasMoreTasks === false,
    //         item.tasksNextCursor === null, and api.getTasks was called
    //         with ('C-time') as the cursor.
  })

  it('is a no-op when hasMoreTasks is false', async () => {
    // Arrange: item with hasMoreTasks=false, tasksNextCursor=null.
    // Act: call store.loadMoreTasks(wsId, itemId).
    // Assert: api.getTasks is NOT called.
  })

  it('is a no-op when a load is already in progress for this item', async () => {
    // Arrange: item with isLoadingMoreTasks=true (set directly).
    // Act: call store.loadMoreTasks(wsId, itemId).
    // Assert: api.getTasks is NOT called.
  })

  it('leaves state intact on fetch failure so the user can retry', async () => {
    // Arrange: item with hasMoreTasks=true, cursor='X'. Mock api.getTasks
    //   to reject.
    // Act: call store.loadMoreTasks(wsId, itemId).
    // Assert: item.tasks unchanged, item.hasMoreTasks still true,
    //         item.tasksNextCursor still 'X', item.isLoadingMoreTasks false.
  })
})
```

Adapt the mocking style to match `workspacesStoreInit.spec.ts` exactly (the project may use a different mock pattern — read it first).

- [ ] **Step 3: Run the test file**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 60 bun run test:run -- workspacesStoreLoadMoreTasks 2>&1 | tail -n 30`
Expected: 4 tests pass.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/workspacesStoreLoadMoreTasks.spec.ts
git commit -m "test(frontend): add unit tests for workspaces store loadMoreTasks"
```

---

# Chunk 3: Frontend UI

## Task 3.1: Add the "Load More" button to `WorkspaceItem.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceItem.vue:22-28, 125-166`

- [ ] **Step 1: Add the `loadMoreTasks` to the emits list**

Replace the existing `defineEmits` block (lines 22-28) with:

```typescript
const emit = defineEmits<{
  click: [item: WorkspaceItem]
  delete: [item: WorkspaceItem]
  addTask: [item: WorkspaceItem]
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  loadMoreTasks: [workspaceId: string, itemId: string]
}>()
```

- [ ] **Step 2: Add the click handler**

Add right after `handleDeleteTask` (line 61):

```typescript
const handleLoadMoreTasks = (event: Event) => {
  event.stopPropagation()
  emit('loadMoreTasks', props.workspaceId, props.item.id)
}
```

- [ ] **Step 3: Add the button to the template**

Replace the closing `</div>` of the task list block (the `v-if="isExpanded && item.tasks && item.tasks.length > 0"` div, line 125-166) with the button appended after the `v-for` task list. The final state of the tasks-list `<div>` is:

```vue
<div v-if="isExpanded && item.tasks && item.tasks.length > 0" class="ml-8 mt-1 space-y-0.5">
  <button
    v-for="task in item.tasks"
    :key="task.id"
    class="flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"
    :style="{
      color: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)',
      backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--semantic-active-bg)' : 'transparent',
    }"
    @click="handleSelectTask(task.id)"
  >
    <span
      v-if="processingState[task.id]"
      class="w-4 h-4 flex items-center justify-center shrink-0"
      data-testid="task-spinner"
    >
      <div
        class="w-3 h-3 border-2 rounded-full animate-spin"
        style="border-color: var(--color-yellow); border-top-color: transparent"
      ></div>
    </span>
    <span
      v-else
      class="w-1.5 h-1.5 rounded-full shrink-0"
      :style="{ backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }"
    />
    <span class="flex-1 truncate">{{ task.name }}</span>
    <button
      @click="handleDeleteTask($event, task.id)"
      class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-red-400"
      style="color: var(--semantic-text-dim);"
    >
      <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
      </svg>
    </button>
  </button>

  <!-- Load More button: shown when the backend says there are more tasks
       for this item. Hidden during the load to prevent double-clicks. -->
  <button
    v-if="item.hasMoreTasks"
    data-testid="load-more-tasks"
    :disabled="item.isLoadingMoreTasks"
    @click="handleLoadMoreTasks"
    class="w-full flex items-center justify-center gap-1.5 px-3 py-1 rounded text-xs transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80"
    style="color: var(--semantic-text-dim);"
  >
    <span v-if="item.isLoadingMoreTasks" class="w-3 h-3">
      <div
        class="w-3 h-3 border-2 rounded-full animate-spin"
        style="border-color: var(--color-aqua); border-top-color: transparent"
      ></div>
    </span>
    <span>{{ item.isLoadingMoreTasks ? 'Loading…' : 'Load more' }}</span>
  </button>
</div>
```

Notes:
- Uses `data-testid="load-more-tasks"` for test selectors (matches the project's `data-testid` convention used elsewhere in the codebase).
- The button has the same dim color as the existing task bullets, so it visually reads as "less prominent than a task, more prominent than nothing".
- `stopPropagation()` on the click handler prevents the task list's parent `<button>` from toggling item expansion.
- `disabled` and `cursor-not-allowed` are belt-and-suspenders against double-clicks, even though `isLoadingMoreTasks` is set synchronously in the store.

- [ ] **Step 4: Build the frontend to confirm types**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/WorkspaceItem.vue
git commit -m "feat(frontend): add Load More button to WorkspaceItem task list"
```

---

## Task 3.2: Wire the new event through `WorkspaceList` to the parent

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceList.vue:14-25, 99-109, 207-218`
- Modify: whichever parent actually owns the store invocation (likely `AppLayout.vue` — confirm during execution; it could also be `Sidebar.vue`).

- [ ] **Step 1: Read the existing event flow for `addTask` / `selectTask` in `WorkspaceList.vue`**

It's already clear from exploration (lines 14-25, 99-109, 207-218): `WorkspaceList` defines an emit per task operation, the `<WorkspaceItemComponent>` forwards the matching event, and `WorkspaceList` re-emits upward to `AppLayout` (or wherever it lives).

- [ ] **Step 2: Add the `loadMoreTasks` emit to `WorkspaceList`**

In the `defineEmits` block (line 14-25), add:

```typescript
loadMoreTasks: [workspaceId: string, itemId: string]
```

In the handlers (around line 107-109), add:

```typescript
const handleLoadMoreTasks = (workspaceId: string, itemId: string) => {
  emit('loadMoreTasks', workspaceId, itemId)
}
```

In the `<WorkspaceItemComponent>` template (around line 207-218), add:

```vue
@load-more-tasks="handleLoadMoreTasks(workspace.id, $event)"
```

(Note: Vue 3 maps `load-more-tasks` in the template to the `loadMoreTasks` emit camelCase name.)

- [ ] **Step 3: Find and update the parent**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
rg "loadMoreChats|@add-task|@select-task" src/apps/desktop/src/components/ -l
```

The parent is whichever component renders `<WorkspaceList>` AND uses `workspacesStore`. Open it and add a handler:

```typescript
const handleLoadMoreTasks = (workspaceId: string, itemId: string) => {
  workspacesStore.loadMoreTasks(workspaceId, itemId)
}
```

Pass it down (or, if the parent uses a refs-only pattern, call it via a ref handle — match the existing style). Add `loadMoreTasks` to the parent's `defineEmits` (if it re-emits) OR pass it as a prop callback (whichever pattern the parent already uses for `addTask` / `selectTask`).

- [ ] **Step 4: Build the frontend to confirm types**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 90 bun run build 2>&1 | tail -n 30`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/WorkspaceList.vue <parent-file>
git commit -m "feat(frontend): wire loadMoreTasks event from WorkspaceItem up to store"
```

---

## Task 3.3: Add a component test for the "Load More" button

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspaceItemTaskLoadMore.spec.ts`

- [ ] **Step 1: Read `workspaceItemTaskSpinner.spec.ts` to learn the project's test pattern for `WorkspaceItem.vue`**

It exists in the same `__tests__/` directory and renders the same component. Use it as a template for the testing-library setup, mock store injection, and any stubbing of child components.

- [ ] **Step 2: Write the tests**

```typescript
import { describe, it, expect, vi } from 'vitest'
// Read workspaceItemTaskSpinner.spec.ts for the exact setup helpers
// (renderWorkspaceItem, mockStore, etc.) and use those.

describe('WorkspaceItem — Load More button', () => {
  it('renders the button when item.hasMoreTasks is true', () => {
    // Render a WorkspaceItem with hasMoreTasks: true, isLoadingMoreTasks: false.
    // Assert: getByTestId('load-more-tasks') is in the document.
    // Assert: button text is "Load more" (not "Loading…").
  })

  it('hides the button when item.hasMoreTasks is false', () => {
    // Render with hasMoreTasks: false.
    // Assert: queryByTestId('load-more-tasks') is null.
  })

  it('emits loadMoreTasks with workspaceId and itemId on click', async () => {
    // Render with hasMoreTasks: true. Capture emits.
    // Click the button.
    // Assert: emitted('loadMoreTasks') === [['<wsId>', '<itemId>']]
  })

  it('shows the spinner and "Loading…" text while isLoadingMoreTasks is true', () => {
    // Render with hasMoreTasks: true, isLoadingMoreTasks: true.
    // Assert: button text is "Loading…", button has the spinner.
  })

  it('disables the button while isLoadingMoreTasks is true (no double-click)', () => {
    // Render with hasMoreTasks: true, isLoadingMoreTasks: true.
    // Assert: button has `disabled` attribute.
  })

  it('stops click propagation so the parent toggle is not triggered', async () => {
    // Render with hasMoreTasks: true. Mock a parent click handler.
    // Click the Load More button.
    // Assert: parent click handler was NOT called (because of stopPropagation).
  })
})
```

Adapt the API (render function name, mock injection style) to whatever `workspaceItemTaskSpinner.spec.ts` uses.

- [ ] **Step 3: Run the test file**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop && timeout 60 bun run test:run -- workspaceItemTaskLoadMore 2>&1 | tail -n 30`
Expected: 6 tests pass.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/__tests__/workspaceItemTaskLoadMore.spec.ts
git commit -m "test(frontend): add component tests for Load More button in WorkspaceItem"
```

---

# Final Verification

After every chunk, run the full project verification (NOT just the changed pieces) to catch cross-cutting regressions.

## Run all checks

```bash
# Backend build
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 60 zig build 2>&1 | tail -n 20

# Backend tests (use the project's actual command — adjust if different)
# (Look for build.zig test target or run_tests.sh)
timeout 120 zig build test 2>&1 | tail -n 40 || \
  timeout 120 bun run test:zig 2>&1 | tail -n 40 || \
  echo "Find the right backend test command by reading build.zig"

# Frontend build (MUST be `bun run build`, not `build-only` — see project rules)
cd src/apps/desktop
timeout 90 bun run build 2>&1 | tail -n 30

# Frontend tests
timeout 120 bun run test:run 2>&1 | tail -n 50
```

## Manual smoke test (start the desktop app, NOT the nalar process)

```bash
# Start the desktop dev server (NOT the production server, NOT nalar)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
bun run dev  # or whatever `dev` script is in package.json
```

In the running desktop app:

1. Create a workspace + add an item (project folder).
2. Manually insert >20 tasks for that item directly into the DB (e.g. via a small Zig script or by hand using `sqlite3` on the dev DB). OR, better: temporarily lower the default page size in `api/index.ts:135` to e.g. `3`, then click "Add Task" 5 times, then revert.
3. Open the sidebar, expand the workspace, expand the item.
4. Confirm: only the first 3 (or 20) tasks are visible, and a "Load more" button appears at the bottom.
5. Click "Load more". Confirm: the next page appears, the button is replaced by another "Load more" (if more pages) or disappears (if last page).
6. Re-collapse and re-expand the item. Confirm: tasks are still loaded (no re-fetch), the "Load more" state is preserved.
7. Delete a task from the middle of the list. Confirm: pagination state is preserved (no spurious re-fetch, button visibility unchanged).
8. Reload the page. Confirm: the workspace reinitializes via `init()`, the first page loads, and "Load more" is shown again if applicable.

## All tests must pass

- Zig tests for `tasks_list_test.zig` ✅
- Vitest for `workspacesStoreLoadMoreTasks.spec.ts` ✅
- Vitest for `workspaceItemTaskLoadMore.spec.ts` ✅
- `vue-tsc --build` (run as part of `bun run build`) passes with no new errors ✅

## Acceptance criteria

- [ ] Backend returns `{ tasks, count, has_more, next_cursor }` from `GET /api/workspaces/:workspace_id/items/:item_id/tasks`.
- [ ] Frontend fetches the first page on workspace init, populates per-item pagination state.
- [ ] "Load more" button appears at the bottom of an item's task list when more pages exist.
- [ ] Clicking "Load more" appends the next page, advances the cursor, and updates the button visibility.
- [ ] Button is hidden when no more pages exist.
- [ ] Button shows a spinner and disables itself during a load (no double-click).
- [ ] No regression in addTask / deleteTask / updateTask flow.
- [ ] All tests pass; build is clean.
