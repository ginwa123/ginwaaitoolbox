# Kanban Task Search — Design

> **For agentic workers:** This is a design spec. After the user approves, the next step is to invoke the `superpowers:writing-plans` skill to create a bite-sized implementation plan.

**Goal:** Add a search input to the kanban board header that filters visible tasks by `name`, `description`, and `tags`. The filter runs at the SQL level on the existing `GET /api/workspaces/:ws/items/:item/tasks` endpoint via a new `?q=` query parameter — no new endpoint, no migration, no schema change. Pagination advances through the filtered set, so "Load more" fetches the next page of matches, not the next page of everything.

**Architecture:** Extend the existing `tasks_list.zig` handler + the underlying `listWorkspaceItemTasksWithCursor` DB function with an optional `q` parameter. When `q` is set, append `WHERE LOWER(t.name) LIKE LOWER(?) OR LOWER(t.description) LIKE LOWER(?) OR LOWER(t.tags) LIKE LOWER(?)` to the query (escaping user input `%` and `_` to prevent wildcard injection). The frontend renders a new compact `<KanbanSearchInput>` component in the `KanbanView.vue` header (to the left of the existing ⚙️ Settings button). The component is `v-model`-bound to a debounced `searchQuery` ref; the debounced value drives a `workspacesStore.fetchKanbanTasks(ws, item, limit, cursor, q)` re-fetch. SSE-driven refetches forward the current `q` so multi-tab search stays consistent.

**Tech Stack:** Zig 0.16 (backend), SQLite via `nalarcore.sqlite.SqliteBackend`, Vue 3 + TypeScript + Vitest (frontend). No new dependencies, no new packages, no migration. Backend reuses the existing cursor-paginated `listWorkspaceItemTasksWithCursor` infrastructure.

## 1. Why now — the problem

The kanban board can hold arbitrarily many tasks (the `merged` column in production has 38 today and grows as the project progresses). When a user wants to find a specific task, the only options today are:

1. Scroll through every column and visually scan card titles.
2. Open the column editor and scan the cards one by one.
3. Use a separate tool (search the DB directly, grep the filesystem).

There is no in-board search. With 38 cards the scroll-and-scan is merely tedious; with 200+ cards it becomes unusable. The user has asked for a way to type a query and see only matching cards.

The implementation must be **server-side** (not a frontend `.filter()` over the loaded page) because `fetchKanbanTasks` loads up to `MAX_PAGE_SIZE = 100` tasks per page. A frontend filter would only see what's loaded — late pages would be invisible to search, which is exactly the failure mode the user is trying to avoid.

## 2. Current state — what exists today

- `GET /api/workspaces/:ws/items/:item/tasks` returns `{ tasks: [...], count, has_more, next_cursor }`
- `tasks_list.zig` parses `limit`, `cursor`, `sort_by`, `direction` from query string
- `listWorkspaceItemTasksWithCursor` (in `src/ai_workflow/tui/llm_history.zig`) builds the SELECT with `WHERE t.workspace_item_id = ?` + cursor pagination + sort + direction
- `api.getTasks(ws, item, limit, cursor, sortBy, direction)` in `src/apps/desktop/src/api/index.ts` wraps the call
- `workspacesStore.fetchKanbanTasks(ws, item, limit=100)` in `src/apps/desktop/src/stores/workspaces.ts` calls `api.getTasks` and assigns `item.tasks = ...`
- `KanbanView.vue` header has: kanban title (left, `flex-1`), `⚠️ Set project root` button (conditional), `⚙️ Settings` button (right)
- `KanbanColumn.vue` filters `props.tasks` by `kanban_column_id` for its column (the column receives the FULL tasks array, not pre-filtered)
- Each column header has a count badge: `<span>{{ cardsInColumn.length }}</span>`
- Lazy-load: when `hasMoreTasks` is true, an IntersectionObserver + manual "Load more" button in each column fires `workspacesStore.loadMoreTasks`
- `Task` interface (`src/apps/desktop/src/stores/workspaces.ts:104`) has `name`, `description?`, `tags?: string[]`, `kanban_column_id`

## 3. Design

### 3.1 Backend filter

**Endpoint:** `GET /api/workspaces/:workspace_id/items/:item_id/tasks` (existing, extended).

**New query parameter:** `q` — the user's search query. Optional. Empty / missing → no filter (current behavior).

**SQL change** — `listWorkspaceItemTasksWithCursor` accepts an optional `q: ?[]const u8` parameter. When set, append to the existing WHERE clause:

```sql
WHERE t.workspace_item_id = ?
  AND (
    LOWER(t.name)        LIKE ? ESCAPE '\'
    OR LOWER(COALESCE(t.description, '')) LIKE ? ESCAPE '\'
    OR LOWER(COALESCE(t.tags,        '')) LIKE ? ESCAPE '\'
  )
```

The same bound parameter is reused 3 times (`?` without index → auto-numbered; SQLite reuses the same bind position). `LOWER()` makes the match case-insensitive. `ESCAPE '\'` lets us neutralize user-supplied `%` and `_` by prepending `\` to each (the SQL pattern itself becomes `\%` and `\_`).

**Why `ESCAPE '\'`:** Without escape, a user typing `%` in the search box would match everything (because `LIKE '%'` matches any string). With escape, the user's literal `%` becomes `\%` in the SQL pattern, which only matches a literal `%` in the data. Same for `_` (single-char wildcard).

**Why `LIKE '%q%'`:** Substring match is what users expect from a kanban search box. Prefix / exact / regex are out of scope (Section 5).

**Why `tags LIKE '%q%'` (JSON-text substring) is acceptable:** The `tags` column stores a JSON-encoded array like `'["bug","urgent","frontend"]'`. Substring match on the JSON text means:
- Searching `"bug"` matches `["bug"]` ✓
- Searching `"bug"` matches `["debug"]` ✓ (substring overlap — same as Trello behavior)
- Searching `"bug"` matches `["Bug"]` only because of `LOWER()` (case-insensitive) ✓
- Searching `","` matches anything with ≥2 tags (false positive — but the input is supposed to be a real word, so this is rare in practice)

A stricter `json_each`-based exact-tag match (`bug` matches `["bug"]` but NOT `["debug"]`) would require JSON1 extension + `EXISTS (SELECT 1 FROM json_each(tags) WHERE value LIKE ?)` — out of scope for v1. Document the false-positive behavior in the search box placeholder: "🔍 Search tasks…".

**`description` is nullable** (Migration 062 declares it NOT NULL DEFAULT `''`, but legacy rows from before Migration 062 may have NULL). `COALESCE(t.description, '')` is defensive against legacy data.

### 3.2 Wire shape

**No new request fields.** `q` is a URL query parameter, not a body field.

**Response shape unchanged:** `{ tasks: [...], count, has_more, next_cursor }`. The `tasks` array contains only the filtered subset. `has_more` and `next_cursor` reflect pagination within the filtered set.

**Frontend `api.getTasks` signature** gains `q?: string` as the 7th parameter:

```ts
export async function getTasks(
  workspaceId: string,
  itemId: string,
  limit = 20,
  cursor?: string,
  sortBy: 'created_at' | 'updated_at' | 'name' = 'updated_at',
  direction: 'asc' | 'desc' = 'desc',
  q?: string,   // NEW — server-side search query
): Promise<{...}>
```

When `q` is non-empty, `params.set('q', q)`. When empty / undefined, omit the param.

### 3.3 UX — search input placement

A new compact `<KanbanSearchInput>` component (sibling to `KanbanColumn`, `KanbanCard`) lives in the `KanbanView.vue` header, between `Set project root` and `Settings`:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ sprint bulan juni          ⚠️ Set project root  🔍 Search tasks…   ✕    ⚙️  │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **Width:** `w-48` (192px) when collapsed; grows to `w-64` when focused (subtle animation, optional — v1 uses fixed `w-48` for simplicity).
- **Placeholder:** `🔍 Search tasks…` (the emoji is decorative; the icon is also rendered inside the input on the left).
- **Clear button:** `✕` rendered inside the input on the right when the value is non-empty. Click → clears.
- **Esc key** while focused → clears (focus stays).
- **Color:** matches the existing `--semantic-card-bg` + `--color-border` tokens used by `KanbanColumn` headers and the Settings button.

The component is reusable across boards (no board-specific state). Self-contained — owns its `v-model`.

### 3.4 State management

`searchQuery` lives in `KanbanView.vue` as a component-local `ref<string>('')`. **Not in the Pinia store** — search is per-board ephemeral state. Closing and reopening the board should clear it.

```ts
// KanbanView.vue
import { refDebounced } from '@vueuse/core'  // or hand-rolled 100ms debounce

const searchQuery = ref('')
const debouncedSearch = refDebounced(searchQuery, 300)

watch(debouncedSearch, async (newQ) => {
  if (!effectiveItemId.value) return
  const trimmed = newQ.trim()
  await workspacesStore.fetchKanbanTasks(
    props.workspaceId,
    effectiveItemId.value,
    100,        // limit (matches MAX_PAGE_SIZE)
    undefined,  // cursor — restart from page 1 of the filtered set
    trimmed || undefined,  // q
  )
})
```

**Why restart cursor on each query change:** The user typing changes the filter set. Mixing page 1 of the old query with page 2 of the new query would return inconsistent results. Reset cursor to undefined (page 1 of the filtered set).

**Why 300ms debounce:** Each keystroke triggers a re-fetch otherwise — wasteful for fast typists. 300ms matches typical "instant search" UX (Linear, GitHub search). Could go lower (100ms) on fast networks; 300ms is conservative.

**Why `refDebounced` from `@vueuse/core`:** Project already imports from `@vueuse/core` in several components (e.g. workspace stores use `useDebounceFn`). Verify with `grep -r "@vueuse/core" src/apps/desktop/src/`.

### 3.5 SSE wire

The SSE handler that drives `fetchKanbanTasks` on `kanban_task.*` events (`useKanbanSseStore` or equivalent — verify by searching for `kanbanSse` / `kanbanSse` action) needs to forward the current `q` so a remote task move during a search doesn't reset the user's view to the unfiltered set.

**Mechanism:** Read the current `searchQuery.value` from the active board via a per-board ref OR by exposing it through the workspaces store. Simplest implementation: store the active `q` per-workspace in the workspaces store (Map<itemId, string>) so SSE handlers can read it without prop drilling.

**Out of scope:** Cross-tab SSE-driven search changes (when user A searches and user B sees the search). Only the local user's search is persisted; SSE only preserves the local search when OTHER events happen.

### 3.6 Empty state + counts

- **No matches anywhere:** A banner between header and columns: `No tasks match "design"`. Inline `v-if` block in `KanbanView.vue`. Dismissed by clearing the search (✕ or Esc).
- **Column with 0 matches while others have matches:** Renders the existing `No tasks yet` placeholder. The condition flips from `cardsInColumn.length === 0` to `(searchQuery ? filteredCardsInColumn.length === 0 : cardsInColumn.length === 0)` (or simpler: always `cardsInColumn.length === 0` because the backend already filtered the data).
- **Count badge** in column header: reflects `cardsInColumn.length` (the filtered count when search is active, the total when not). No "X of Y" format — the filter itself makes it obvious the board is narrowed.

### 3.7 Drag-and-drop coexistence

The filter is a render concern only. `props.item.tasks` contains only the filtered subset returned by the backend, but the store still considers the full task graph "synced". Moving a card during a search:
1. Emits `move-task` → calls `api.moveTask` → backend moves the card
2. Backend emits `kanban_task.moved` SSE event → frontend SSE handler calls `fetchKanbanTasks(q)` (with current search)
3. The moved card is still a match → re-renders in the new column
4. OR the moved card is NOT a match for the current search → disappears (correct UX; user can clear search to see it)

No new edge cases. No new event handling.

## 4. API surface

### 4.1 `GET /api/workspaces/:ws/items/:item/tasks`

New query param `q` (optional). Behavior:
- `?q=foo` → returns tasks where `name`, `description`, or `tags` contains "foo" (case-insensitive).
- `?q=` (empty) → returns all tasks (same as no `q`).
- `?q` missing → returns all tasks (same as today).
- Combined with `limit`/`cursor`/`sort_by`/`direction` — pagination advances through the filtered set.

Error cases: none new. Malformed `q` (non-UTF-8?) is handled by the URL parser — returns 400 on parse error (existing behavior for invalid query strings).

### 4.2 No other endpoints change

`POST /tasks`, `PUT /tasks/:id`, `PUT /workspaces/tasks/:id` — unchanged. The `q` filter is a read-only concern.

## 5. Out of scope (deferred)

1. **Multi-page auto-load on search.** Search only sees the first 100 matches; user must click "Load more" to see beyond. Sufficient for v1 — most boards have <100 matching tasks per query.
2. **Fuzzy / regex search.** Plain substring is enough.
3. **Search history / recent searches.**
4. **URL persistence** of the active `q` (sharing a kanban URL with a search in it is confusing).
5. **Highlight matched substring** inside the card title/description.
6. **Search by `memory_name` or `routine.schedule`** — adds API surface without clear user demand.
7. **Per-tag exact match** (`bug` matches `["bug"]` but NOT `["debug"]`) — would require `json_each`, defer.
8. **Sort by relevance** — current sort_by (`updated_at`, `created_at`, `name`) stays. A future "sort by match score" is a separate feature.

## 6. Acceptance criteria

### Backend

1. `GET /tasks?q=foo` returns only tasks whose name, description, or tags contain "foo" (case-insensitive).
2. `GET /tasks?q=BUG` returns tasks with tag `"bug"` (case-insensitive).
3. `GET /tasks?q=` (empty) returns all tasks (no filter applied).
4. `GET /tasks` (no `q`) returns all tasks (no filter applied).
5. `GET /tasks?q=foo&cursor=<next_cursor>` advances through the **filtered** set, not all tasks.
6. `GET /tasks?q=%25` (literal `%`) — escaped — returns 0 matches (the data doesn't contain a literal `%`; verify this works).
7. `GET /tasks?q=_` (literal `_`) — escaped — returns 0 matches (no task names contain `_` in test data; verify escape works).
8. `GET /tasks?q=' OR '1'='1` — parameterized query — returns 0 matches (no SQL injection surface; verify no error).
9. `GET /tasks?q=foo` combined with `sort_by=name&direction=asc` — sorts matches alphabetically.
10. `GET /tasks?q=foo` returns `has_more: true` when > 100 matches exist (verify with 150 seeded matching tasks).
11. `GET /tasks?q=nonexistent_token_xyz` returns `{ tasks: [], count: 0, has_more: false, next_cursor: null }`.

### Frontend

12. Typing in `<KanbanSearchInput>` updates `searchQuery` reactively.
13. After 300ms debounce, `workspacesStore.fetchKanbanTasks` is called with `q=<trimmed input>`.
14. Empty query → `q` is omitted (URL has no `q=` param).
15. Esc / ✕ clears the query and triggers an unfiltered refetch.
16. Column count badge shows the filtered count when search is active.
17. "No tasks match …" banner renders when `tasks.length === 0 && searchQuery !== ''`.
18. SSE-driven refetches (`kanban_task.*` events) forward the current `q`.
19. Moving a card during a search → re-fetches with `q` → card stays or disappears based on whether it still matches.

### Cross-platform

20. `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc` — clean (no POSIX-only SQL escape).
21. `zig build-obj -fno-emit-bin -target aarch64-macos -lc` — clean.
22. `zig build test --summary all` — all existing tests + new tests pass.
23. `zig build install:linux:system` — builds cleanly.

### Live smoke (port 8080)

24. Boot `nalar` on port 8080, create a kanban with 5 tasks having distinct name / description / tags.
25. `GET /tasks?q=foo` returns only matches.
26. Frontend: open the kanban in the browser, type "foo" → see only matching cards in each column.

## 7. Files touched

### Backend (3 files)

- `src/ai_workflow/tui/llm_history.zig` — extend `listWorkspaceItemTasksWithCursor` to accept `q: ?[]const u8`. Append WHERE clause when set. Escape `%` and `_` in user input.
- `src/ai_workflow/tui/http_handlers/tasks_list.zig` — `parseInput` parses `q` from query string; pass through to the DB fn. `TasksListInput` gains `q: ?[]const u8`.
- `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` — extend existing tests (Section 6.1–6.11).

### Frontend (5 files + 2 new tests)

- `src/apps/desktop/src/api/index.ts` — `getTasks(ws, item, limit, cursor, sortBy, direction, q?)` adds `q` param; sets `params.set('q', q)` when non-empty.
- `src/apps/desktop/src/stores/workspaces.ts` — `fetchKanbanTasks(ws, item, limit, cursor, q?)` passes `q` to `api.getTasks`. `loadMoreTasks` forwards `q`. Add per-item `searchQuery` map so SSE handlers can read the current `q`.
- `src/apps/desktop/src/components/kanban/KanbanSearchInput.vue` — **NEW** — the compact search input.
- `src/apps/desktop/src/components/kanban/KanbanView.vue` — render `<KanbanSearchInput>` in header; bind to `searchQuery`; debounce + refetch.
- `src/apps/desktop/src/components/kanban/KanbanColumn.vue` — column count badge flips to `(cardsInColumn.length === 0)` (which is already filtered by the API, so the existing v-if for `No tasks yet` works).
- `src/apps/desktop/src/__tests__/KanbanSearchInput.spec.ts` — **NEW** — v-model, Esc, ✕ tests.
- `src/apps/desktop/src/__tests__/KanbanView.searchFilter.spec.ts` — **NEW** — debounced refetch, empty state banner, count badge behavior.

### Docs (1 file)

- `docs/superpowers/plans/2026-07-30-kanban-task-search-plan.md` — **NEW** — the implementation plan (written via `writing-plans` skill after this spec is approved).
- `docs/SPEC.md` — append a row to §3.7 (Kanban — search entry) and §10.2.1 (PR index) after merge.

## 8. Open questions / risks

- **SSE handler needing current `q`** — the SSE handler is `useKanbanSseStore` (verify by searching). It needs access to the per-board `q` to forward on refetch. Simplest: store the active `q` in the workspaces store keyed by `itemId`. Confirmed during implementation.
- **`COALESCE(t.description, '')`** — Migration 062 declares `description NOT NULL DEFAULT ''`, so technically all rows have `description = ''` at minimum. `COALESCE` is defensive against legacy pre-Migration-062 rows. Cheap to leave in.
- **`json_each` exact-tag match** — see §3.1 — deferred. If users complain about false positives (`bug` matching `["debug"]`), revisit in v2.
- **Search box width on narrow screens** — `w-48` may collide with the `Settings` button on screens < 1024px. Future: collapse to icon on narrow viewports. v1: fixed width.

## 9. Verification recipe (post-implementation)

```bash
# Backend tests (Linux)
cd /home/ginwa/ginwaaitoolbox
timeout 180 zig build test --summary all
# Expect: all existing tests + new tasks_list_test.zig extensions pass

timeout 180 zig build install:linux:system
# Expect: 87 MB nalar binary at zig-out/bin/nalar

# Cross-platform compile-only checks
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/test_mod.zig -Mnalarcore=src/root.zig
# Expect: clean type-check (no link)

# Frontend
cd src/apps/desktop
timeout 180 bun run build  # vue-tsc + vite
# Expect: type-check + bundle clean

timeout 180 bunx vitest run
# Expect: all existing tests + 2 new test files pass

# Live smoke (port 8080)
cd /home/ginwa/ginwaaitoolbox
rm -rf /tmp/nalar-search-smoke && mkdir -p /tmp/nalar-search-smoke
env -i HOME=/tmp/nalar-search-smoke PATH=$PATH \
  ./zig-out/bin/nalarcore-linux-x86_64 --port 8080 > /tmp/smoke.log 2>&1 &
sleep 4
WS=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
  -H 'content-type: application/json' -d '{"name":"search-smoke"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
ITEM=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS/items/kanban" \
  -H 'content-type: application/json' -d '{"name":"Search Board","path":"/tmp"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["item"]["id"])')
# Create 5 tasks: name contains "design", description contains "login", tags contain "bug", etc.
# ... (full smoke commands in the implementation plan)
pkill -f "nalar --port 8080"
```
