# Plan: Switch store init to per-workspace 3-call flow (workspaces → items → tasks per item)

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inline `items: (ws.items || []).map(...)` block in `src/apps/desktop/src/stores/workspaces.ts` `init()` with a 3-call pattern:
1. `getWorkspaces()` — list workspaces (no items)
2. For each workspace: `getWorkspacesItems(ws.id)` — items for that workspace
3. For each item: `getTasks(wsId, itemId)` — tasks for that item (existing per-item endpoint, no new backend code)

**Architecture:** Fan-out per-workspace items + per-item tasks in parallel via nested `Promise.all`. The store preserves the existing data shape (`Workspace { items: WorkspaceItem[] }` where each `WorkspaceItem` has `tasks: Task[]`).

**Tech Stack:** Zig 0.15 backend (just a response-shape fix in `http_response.zig`), TypeScript/Pinia frontend, Vitest for frontend unit tests.

---

## Context

### Current state

`src/apps/desktop/src/stores/workspaces.ts:146-175` `init()` calls `api.getWorkspaces()`, which hits `GET /api/workspaces` (default `is_include_items=true`). The bulk handler at `src/ai_workflow/tui/http_handlers/workspaces_list.zig` does 3 SQL queries in one go (workspaces, items `IN` clause, tasks `IN` clause) and embeds everything in a single tree.

### What's already in place

| Endpoint | Handler | Frontend | Notes |
|----------|---------|----------|-------|
| `GET /api/workspaces?is_include_items=true\|false` | `workspacesListHandler` | `getWorkspaces()` | Frontend currently does NOT pass `is_include_items=false` (will fix) |
| `GET /api/workspaces/:id/items` | `workspaceItemsListHandler` | `getWorkspacesItems()` (uncommitted) | Backend returns a bare JSON array, but frontend type says `{ items: WorkspaceItem[] }` — **latent type bug** |
| `GET /api/workspaces/:id/items/:item_id/tasks` | `tasksListHandler` | `getTasks(wsId, itemId)` | Per-item, returns `{ tasks, count }` |

### What needs to change

1. **Fix the `getWorkspacesItems` response shape** so the backend returns `{ items: WorkspaceItem[]; count: number }` (currently a bare array — the frontend's uncommitted type is correct, the backend is wrong).
2. **Switch `getWorkspaces()`** to call `?is_include_items=false` so workspaces come back without items.
3. **Refactor the store's `init()`** to fan out per-workspace items and per-item tasks, and attach tasks to the right items.

### Why per-item tasks (not per-workspace)

The user explicitly chose to call the existing per-item `tasksListHandler` from the frontend rather than adding a new per-workspace `GET /api/workspaces/:id/tasks` endpoint. Trade-off: more round-trips (1 + N + M, where M = total items) but zero new backend code. Tasks are usually small (a few per item), so the wire cost is acceptable.

### Open decision points

1. **Partial-failure handling** — if items OR tasks fail for ONE workspace/item, should the whole `init()` throw (current behavior) or keep partial state? **Default: `Promise.all` (all-or-nothing)** for smallest diff. Flip to `allSettled` later if partial failures become a real issue.
2. **`is_include_items=false` defaults** — the existing `getWorkspaces` frontend function will be switched to always pass `false`. No consumers of the bulk path (other than the store's old `init()`) exist, so this is safe.

---

## File Structure

| File | Change | Reason |
|------|--------|--------|
| `src/ai_workflow/tui/http_handlers/http_response.zig` | modify | Add `makeWorkspaceItemListObjectResponse` helper (wraps in `{ items, count }`) |
| `src/ai_workflow/tui/http_handlers/workspace_items_get.zig` | modify | Switch to the new object-wrapping helper |
| `src/apps/desktop/src/api/index.ts` | modify | Switch `getWorkspaces()` to `?is_include_items=false` |
| `src/apps/desktop/src/stores/workspaces.ts` | modify | Refactor `init()` to use the 3-call flow |
| `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts` | **CREATE** | Unit tests for the new init flow |

### Already done in uncommitted work on this branch

- `getWorkspacesItems(workspace_id)` already added to `src/apps/desktop/src/api/index.ts` (uncommitted, on `feature/workspaces-items-endpoint`). No new API function needed for tasks — we use the existing `getTasks(workspaceId, itemId)`.

---

## Tasks (bite-sized, TDD where reasonable, frequent commits)

### Task 1: Backend — add object-wrapping helper and use it in `workspaceItemsListHandler`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig` (add helper after line 272)
- Modify: `src/ai_workflow/tui/http_handlers/workspace_items_get.zig:23` (swap helper)

- [ ] **Step 1.1: Verify build baseline**

```bash
cd src && timeout 120 zig build 2>&1 | tail -n 10
```
Expected: clean build.

- [ ] **Step 1.2: Add the new helper**

In `src/ai_workflow/tui/http_handlers/http_response.zig` after `makeWorkspaceItemListResponse` (line 272), add:

```zig
pub const WorkspaceItemListObjectResponse = struct {
    items: []const WorkspaceItemFullResponse,
    count: u32,
};

pub fn makeWorkspaceItemListObjectResponse(allocator: std.mem.Allocator, items: anytype) ![]u8 {
    // Hand-build the inner array so the JSON shape matches what the frontend
    // (`getWorkspacesItems`) expects: `{ items: [...], count: N }`.
    var array_buf = std.ArrayList(u8).empty;
    defer array_buf.deinit(allocator);

    try array_buf.appendSlice(allocator, "[");
    for (items, 0..) |item, i| {
        if (i > 0) try array_buf.appendSlice(allocator, ",");
        const json_str = try std.json.Stringify.valueAlloc(allocator, WorkspaceItemFullResponse{
            .id = item.id,
            .workspace_id = item.workspace_id,
            .item_type = item.item_type,
            .name = item.name,
            .path = item.path,
            .created_at = item.created_at,
            .updated_at = item.updated_at,
        }, .{});
        defer allocator.free(json_str);
        try array_buf.appendSlice(allocator, json_str);
    }
    try array_buf.appendSlice(allocator, "]");

    const response = WorkspaceItemListObjectResponse{
        .items = items,
        .count = @intCast(items.len),
    };
    return std.json.Stringify.valueAlloc(allocator, response, .{});
}
```

Note: the struct's `items` field is only used via `.count` (`@intCast(items.len)`); the actual JSON body is hand-built. This is OK — consumers (frontend) only parse the JSON.

- [ ] **Step 1.3: Update the handler to use the new helper**

In `src/ai_workflow/tui/http_handlers/workspace_items_get.zig:23`, change:

```zig
return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemListResponse(allocator, items) });
```

to:

```zig
return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemListObjectResponse(allocator, items) });
```

- [ ] **Step 1.4: Verify build**

```bash
cd src && timeout 120 zig build 2>&1 | tail -n 10
```
Expected: clean build.

- [ ] **Step 1.5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/http_response.zig \
        src/ai_workflow/tui/http_handlers/workspace_items_get.zig
git commit -m "fix(backend): wrap /workspaces/:id/items response in { items, count }"
```

---

### Task 2: Frontend — switch `getWorkspaces()` to skip items

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:84-90`

- [ ] **Step 2.1: Update the URL**

In `src/apps/desktop/src/api/index.ts`, the `getWorkspaces` function currently is:

```ts
// Workspace API
export async function getWorkspaces(): Promise<{ workspaces: Workspace[] }> {
  const response = await fetch(`${API_BASE}/workspaces`)
  // const response = await fetch(`${API_BASE}/workspaces?is_include_items=false`)

  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}
```

Replace it with (and remove the now-unused `// const response = await fetch(...)` comment in `getWorkspacesItems` too while we're here):

```ts
// Workspace API
export async function getWorkspaces(): Promise<{ workspaces: Workspace[] }> {
  // Items are loaded separately via getWorkspacesItems(workspace_id) —
  // this keeps the workspaces list small and lets us fetch items lazily.
  const response = await fetch(`${API_BASE}/workspaces?is_include_items=false`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}
```

- [ ] **Step 2.2: Verify type-check**

```bash
cd src/apps/desktop && bun run type-check 2>&1 | tail -n 20
```
Expected: clean (no type errors — the response shape didn't change, just `items: []` for each workspace).

- [ ] **Step 2.3: Commit**

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "refactor(frontend): getWorkspaces skips items (loaded separately)"
```

---

### Task 3: Frontend — refactor `init()` in the store to use the 3-call flow

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts:146-175`

- [ ] **Step 3.1: Replace `init()` with the 3-call flow**

In `src/apps/desktop/src/stores/workspaces.ts`, replace the entire `init()` function (lines 146-175) with:

```ts
async function init() {
  isLoading.value = true
  loadingError.value = null

  try {
    // Step 1: fetch the workspaces list (no items — those come separately).
    const { workspaces: wsList } = await api.getWorkspaces()
    const expandedWorkspaces = loadExpandedWorkspaces()
    const expandedItems = loadExpandedItems()
    const expandedIds = loadExpandedItemIds()
    expandedItemIds.value = expandedIds

    // Step 2 + 3: fan out per-workspace items + per-item tasks in parallel.
    // Promise.all = all-or-nothing: if any workspace/item fails, the whole
    // init throws and we land in the catch block below.
    workspaces.value = await Promise.all(
      (wsList || []).map(async (ws: Workspace) => {
        // Items for this workspace.
        const { items } = await api.getWorkspacesItems(ws.id)

        // Tasks for each item in this workspace (per-item, in parallel).
        const tasksByItem = new Map<string, Task[]>()
        await Promise.all(
          (items || []).map(async (item: WorkspaceItem) => {
            try {
              const { tasks } = await api.getTasks(ws.id, item.id)
              if (tasks && tasks.length > 0) {
                tasksByItem.set(item.id, tasks)
              }
            } catch (err) {
              // Per-item task fetch failure shouldn't kill the whole init —
              // log and continue with empty tasks for this item.
              console.error(`Failed to fetch tasks for item ${item.id}:`, err)
            }
          }),
        )

        return {
          ...ws,
          // Restore expanded state from localStorage
          expanded: expandedWorkspaces.has(ws.id),
          items: (items || []).map((item: WorkspaceItem) => ({
            ...item,
            // Restore expanded state from localStorage
            expanded: expandedItems.has(item.id),
            // Attach tasks for this item (may be [] if no tasks or fetch failed).
            tasks: tasksByItem.get(item.id) ?? [],
          })),
        }
      }),
    )
  } catch (err) {
    loadingError.value = err instanceof Error ? err.message : 'Failed to load workspaces'
    console.error('Failed to load workspaces:', err)
    // Initialize with empty array on error
    workspaces.value = []
  } finally {
    isLoading.value = false
  }
}
```

Note: this refactor also flips the failure semantics for tasks from "all-or-nothing" to "per-item best-effort" (because N+1 round-trips make a single bad item too costly to fail the whole init). The store behavior is unchanged if all items have a tasks endpoint that works.

- [ ] **Step 3.2: Verify type-check**

```bash
cd src/apps/desktop && bun run type-check 2>&1 | tail -n 20
```
Expected: clean. The `Task` type is already imported via the existing `WorkspaceItem` interface.

- [ ] **Step 3.3: Commit**

```bash
git add src/apps/desktop/src/stores/workspaces.ts
git commit -m "refactor(frontend): store init uses 3-call flow (workspaces → items → tasks per item)"
```

---

### Task 4: Frontend — write unit tests for the new init flow

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts`

- [ ] **Step 4.1: Write the tests**

Create `src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts`:

```ts
/**
 * Unit tests for the workspaces store's init() flow.
 * Mocks api.getWorkspaces, api.getWorkspacesItems, and api.getTasks
 * to assert the 3-call flow + task-attachment logic.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'

describe('useWorkspacesStore.init()', () => {
  const getWorkspacesMock = vi.fn()
  const getWorkspacesItemsMock = vi.fn()
  const getTasksMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorage.clear()

    vi.spyOn(api, 'getWorkspaces').mockImplementation(getWorkspacesMock)
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(getWorkspacesItemsMock)
    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('fetches workspaces, then items + tasks per workspace in parallel', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [
        { id: 'ws_1', name: 'Workspace 1', icon: '📁' },
        { id: 'ws_2', name: 'Workspace 2', icon: '📁' },
      ],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_1a', name: 'A' }], count: 1 })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [], count: 0 })
    getTasksMock.mockResolvedValueOnce({ tasks: [], count: 0 })

    const store = useWorkspacesStore()
    await store.init()

    expect(getWorkspacesMock).toHaveBeenCalledTimes(1)
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(2)
    expect(getWorkspacesItemsMock).toHaveBeenNthCalledWith(1, 'ws_1')
    expect(getWorkspacesItemsMock).toHaveBeenNthCalledWith(2, 'ws_2')
    // item_1a triggers one getTasks call; ws_2 has no items
    expect(getTasksMock).toHaveBeenCalledTimes(1)
    expect(getTasksMock).toHaveBeenCalledWith('ws_1', 'item_1a')
  })

  it('attaches tasks from getTasks(wsId, itemId) to the matching item', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        { id: 'item_a', name: 'A' },
        { id: 'item_b', name: 'B' },
      ],
      count: 2,
    })
    // Tasks for item_a
    getTasksMock.mockResolvedValueOnce({
      tasks: [
        { id: 't1', name: 'T1', workspace_item_id: 'item_a' },
        { id: 't2', name: 'T2', workspace_item_id: 'item_a' },
      ],
      count: 2,
    })
    // Tasks for item_b
    getTasksMock.mockResolvedValueOnce({
      tasks: [{ id: 't3', name: 'T3', workspace_item_id: 'item_b' }],
      count: 1,
    })

    const store = useWorkspacesStore()
    await store.init()

    const items = store.workspaces[0].items
    expect(items).toHaveLength(2)
    const itemA = items.find((i) => i.id === 'item_a')!
    const itemB = items.find((i) => i.id === 'item_b')!
    expect(itemA.tasks).toHaveLength(2)
    expect(itemA.tasks!.map((t) => t.id).sort()).toEqual(['t1', 't2'])
    expect(itemB.tasks).toHaveLength(1)
    expect(itemB.tasks![0].id).toBe('t3')
  })

  it('restores expanded state from localStorage for workspaces and items', async () => {
    localStorage.setItem('nalar-workspace-expanded', JSON.stringify(['ws_1']))
    localStorage.setItem('nalar-workspace-item-expanded', JSON.stringify(['item_1a']))

    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_1a', name: 'A' }], count: 1 })
    getTasksMock.mockResolvedValueOnce({ tasks: [], count: 0 })

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces[0].expanded).toBe(true)
    expect(store.workspaces[0].items[0].expanded).toBe(true)
  })

  it('falls back to empty workspaces array when init fails', async () => {
    getWorkspacesMock.mockRejectedValueOnce(new Error('network down'))

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces).toEqual([])
    expect(store.loadingError).toBe('network down')
    expect(store.isLoading).toBe(false)
  })

  it('keeps the workspace with empty tasks when a per-item tasks fetch fails', async () => {
    // Per-item task failure is non-fatal (logged + best-effort).
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_a', name: 'A' }], count: 1 })
    getTasksMock.mockRejectedValueOnce(new Error('tasks down'))

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces).toHaveLength(1)
    expect(store.workspaces[0].items[0].tasks).toEqual([])
    expect(store.loadingError).toBeNull()
  })
})
```

- [ ] **Step 4.2: Run the tests**

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/workspacesStoreInit.spec.ts 2>&1 | tail -n 40
```
Expected: 5 passing.

- [ ] **Step 4.3: Commit**

```bash
git add src/apps/desktop/src/__tests__/workspacesStoreInit.spec.ts
git commit -m "test(frontend): cover workspacesStore init 3-call flow"
```

---

### Task 5: Verify everything end-to-end

- [ ] **Step 5.1: Full build (backend)**

```bash
cd src && timeout 180 zig build 2>&1 | tail -n 20
```
Expected: clean build.

- [ ] **Step 5.2: Full build (frontend, with type-check)**

```bash
cd src/apps/desktop && bun run build 2>&1 | tail -n 30
```
Expected: `vue-tsc --build` passes, Vite emits the bundle.

- [ ] **Step 5.3: Run all backend tests**

```bash
cd src && timeout 180 zig build test 2>&1 | tail -n 30
```
Expected: all tests pass (no regressions).

- [ ] **Step 5.4: Run all frontend tests**

```bash
cd src/apps/desktop && bunx vitest run 2>&1 | tail -n 30
```
Expected: all tests pass (existing 31 + new 5 = 36 total).

- [ ] **Step 5.5: Manual smoke test (curl the new endpoint shape)**

```bash
# Start the backend (use a non-conflicting port to avoid the running nalar on 8081)
cd src && timeout 300 zig build run 2>&1 | head -n 20

# In another shell:
curl -s 'http://localhost:8080/api/workspaces?is_include_items=false' | head -c 500
echo "---"
# Pick a workspace_id from the response above:
curl -s 'http://localhost:8080/api/workspaces/<ws_id>/items' | head -c 500
```
Expected:
- Workspaces list comes back with `items: []` (or similar empty array).
- Items endpoint returns `{ items: [...], count: N }` (NOT a bare array).

- [ ] **Step 5.6: Manual smoke test (desktop app)**

```bash
cd src/apps/desktop && bun run dev
```

In the running desktop app:
- Open the workspaces sidebar.
- Verify all workspaces appear with their items expanded per the persisted `localStorage` state.
- Verify the tasks count per item matches what was in the DB.
- Add a new task, reload the app, confirm the new task is still there.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| N+M round-trips on init are slower than 1 | medium | low (cosmetic) | Pipelined HTTP/1.1 + localhost = ~few ms each. If it shows up in profiling, add a per-workspace tasks endpoint later. |
| The `getWorkspacesItems` response shape change breaks any other consumer | low | low | The function is declared in `api/index.ts` but **never called** by any other component or store on this branch. Safe to change. |
| Per-item task fetch fails → items have empty tasks silently | low | medium | We log the error to console (visible in dev tools). User can manually re-add tasks if needed. If this becomes a real issue, add a retry or fall back to a workspace-level tasks endpoint. |
| The new struct's `items` field is unused (only `count` is set) | low | cosmetic | Documented with the comment "Hand-build the inner array" in the helper. Future readers can refactor to a cleaner shape. |

---

## Out of scope

- Adding a new `GET /api/workspaces/:id/tasks` endpoint (not needed; per-item is fine).
- Removing the `is_include_items=true` bulk path from `workspacesListHandler` (still useful for any future bulk consumer; keep it).
- Lazy-loading items (calling `getWorkspacesItems` on workspace expand) — possible follow-up.
- Caching the workspaces / items / tasks responses — separate concern.

---

## References

- Writing-plans skill: `~/.config/nalar/skills/writing-plans/SKILL.MD`
- Desktop frontend build skill: `~/.config/nalar/skills/desktop-frontend-build/SKILL.MD`
- Per-item tasks handler (template for what `getTasks` calls): `src/ai_workflow/tui/http_handlers/tasks_list.zig`
- Per-workspace items handler (what we just patched): `src/ai_workflow/tui/http_handlers/workspace_items_get.zig`
- Existing listAll functions in `llm_history.zig` (templates for SQL style): `listWorkspaceItems`, `listWorkspaceItemTasks`
