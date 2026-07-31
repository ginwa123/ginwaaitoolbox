# Kanban Task Search — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a server-side search input to the kanban board header (left of ⚙️ Settings). Typing filters visible tasks by `name`, `description`, and `tags` via a new `?q=` query param on the existing `GET /api/workspaces/:ws/items/:item/tasks` endpoint. Pagination advances through the filtered set.

**Architecture:** Extend the existing `listWorkspaceItemTasksWithCursor` DB function with an optional `q: ?[]const u8` parameter. When set, append `WHERE (LOWER(t.name) LIKE LOWER(?) ESCAPE '\' OR LOWER(COALESCE(t.description, '')) LIKE ? ESCAPE '\' OR LOWER(COALESCE(t.tags, '')) LIKE ? ESCAPE '\')` with `%` and `_` in the user input escaped to `\%` and `\_` (no SQL injection surface). The handler (`tasks_list.zig::parseInput`) parses `q` from the URL and forwards it. The frontend renders a new `<KanbanSearchInput>` component in `KanbanView.vue`'s header. The component is `v-model`-bound to a debounced (300ms) `ref<string>`. The debounced value drives `workspacesStore.fetchKanbanTasks(ws, item, 100, undefined, q)`. SSE-driven refetches forward the active `q` via a per-item map in the workspaces store so multi-tab consistency holds.

**Tech Stack:** Zig 0.16 (backend, project pin), SQLite via `nalarcore.sqlite.SqliteBackend`, Vue 3 + TypeScript + Pinia (frontend), Vitest + `@vue/test-utils` for tests. No new dependencies, no migration.

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-task-search` on branch `worktree/kanban-task-search`
**Spec:** `docs/superpowers/specs/2026-07-30-kanban-task-search-design.md`

---

## Design Decisions (for the user to review before execution begins)

| ID | Decision | Why | Alternative rejected |
|----|----------|-----|----------------------|
| D1 | **Server-side filter** (not frontend `.filter()`) | The kanban only loads the first 100 tasks per page. A frontend filter would miss tasks on later pages — exactly the failure mode the user is trying to avoid when they have 200+ tasks. | Frontend `.filter()` over `item.tasks` — invisible to tasks beyond `MAX_PAGE_SIZE=100` until the user scrolls. |
| D2 | **`LIKE` substring match** (not exact-tag match) on the JSON-encoded `tags` TEXT | `["bug"]` matching `bug` via `LIKE` works because the JSON text contains the literal string. Stricter `json_each` exact-tag match would require SQLite JSON1 extension + `EXISTS (SELECT 1 FROM json_each(...) WHERE value = ?)` — overkill for v1. False positives (`bug` matching `["debug"]`) are accepted as the typical kanban-search UX (Trello/Linear both do this). | `json_each` exact match — adds complexity, stricter than users expect. |
| D3 | **`ESCAPE '\'` + escape `%` and `_`** in user input | Without escape, a user typing `%` matches every row (LIKE wildcard). Escape gives literal semantics: user `%` becomes `\%` in the SQL pattern, only matches rows containing a literal `%`. Same for `_` (single-char wildcard). | No escape (rely on `?` parameterization alone) — `%` and `_` become wildcards, breaking substring semantics for those characters. |
| D4 | **Empty `q` → no filter**, missing `q` → no filter | Both empty and missing mean "search is off" — the user gets the unfiltered list. Avoids a `WHERE '' LIKE '%foo%'` semantic mismatch. | Treat empty as `q=*` (match all) — semantically equivalent to no filter but wasteful. |
| D5 | **Cursor resets to page 1 on every query change** | Mixing page 1 of the old query with page 2 of the new query would return inconsistent results. Reset cursor → page 1 of the filtered set on each debounced re-fetch. | Persist cursor across query changes — gives undefined results when query flips mid-paginate. |
| D6 | **300ms debounce** on the input | Each keystroke would fire a re-fetch. 300ms matches typical instant-search UX (Linear uses ~150ms, GitHub uses 250ms). Conservative for slower networks. | No debounce — wasteful for fast typists (5× requests per typed word). 100ms — too aggressive for slower laptops; reads as "lag". |
| D7 | **Search state is component-local** (NOT in Pinia) | Search is per-board ephemeral state. Closing + reopening the board should clear it. Storing in the store would persist across boards and tempt URL persistence (out of scope). | Lift to Pinia — unnecessary; only the SSE handler needs cross-component access (handled via a per-item `q` map). |
| D8 | **Per-item `q` Map in workspaces store** for SSE forwarding | SSE handlers fire on `kanban_task.*` events and need to refetch with the active search query. The store reads from a `Map<itemId, string>` to forward `q` on refetch. Keeps component-local search state private to KanbanView while letting non-KanbanView code (SSE handler) forward it. | Expose `q` as a prop or via provide/inject — more wiring for the same result. |
| D9 | **Empty state is a single `v-if` block** in `KanbanView.vue`, not a new component | Only one place needs it (the kanban board). A reusable component would be YAGNI. | New `<KanbanEmptyState>` component — duplication-prone. |
| D10 | **No changes to `KanbanColumn.vue`** | The backend already returns only filtered tasks. The existing `cardsInColumn.length === 0` check correctly shows "No tasks yet" when ALL matches for that column are filtered out. The count badge shows the filtered count automatically (because `cardsInColumn.length` is the filtered count). | Add a "filtered count of total" badge — over-engineered; the filter makes the narrowing obvious. |

---

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows. Verify with `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc ...` and `... -target aarch64-macos -lc ...` at the end of each chunk.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns — see `~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md`.
- **No port 8081**: smoke tests use port 8080 (the always-running dev nalar on 8081 is off-limits).
- **TDD discipline**: every implementation step starts with a failing test, then minimal code to make it pass, then a commit.
- **`bun run build` IS the type-check**: every frontend commit must pass `bun run build` (which runs `vue-tsc` under node); `bunx vitest run` alone does NOT catch type errors — see `.nalar/memories/nalar-frontend-patterns.md` §"`bun run build` is the type-check".
- **Lazy analysis trap**: `zig build test` may miss errors in `addExecutable`-only code paths. Run `zig build install:linux:system` at the end of each chunk to catch them.
- **BehavIoUral Vue tests** use `@vue/test-utils` `mount` with `setActivePinia(createPinia())` in `beforeEach`. Mock fetch via `vi.fn()` returning `{ ok, status, json, text }` shape (see `.nalar/memories/nalar-frontend-patterns.md` §"`apiFetch` mock helpers need `text()` method").
- **Behavioural Zig tests** call the function under test with crafted inputs + assertions on return values. Use `std.testing.allocator` + a `setupDb()` helper if DB is needed (mirror the pattern in `tasks_list_test.zig`).
- **NO new comments above `logger.infoFmt(...)` calls** (see `~/.config/nalar/memories/no-comments-on-logger-calls.md`).

---

## File Structure

```
EDIT src/ai_workflow/tui/llm_history.zig                          (+ q param to listWorkspaceItemTasksWithCursor)
EDIT src/ai_workflow/tui/http_handlers/tasks_list.zig              (+ q in TasksListInput + parseInput)
EDIT src/ai_workflow/tui/http_handlers/tasks_list_test.zig         (+ search filter tests — extend existing file)

EDIT src/apps/desktop/src/api/index.ts                             (+ getTasks accepts q as 7th param)
EDIT src/apps/desktop/src/stores/workspaces.ts                     (+ fetchKanbanTasks + loadMoreTasks forward q; per-item q map)
NEW  src/apps/desktop/src/components/kanban/KanbanSearchInput.vue  (compact search input)
EDIT src/apps/desktop/src/components/kanban/KanbanView.vue         (render <KanbanSearchInput> in header + debounced refetch + empty banner)

NEW  src/apps/desktop/src/__tests__/KanbanSearchInput.spec.ts      (behavioural tests: v-model, Esc, ✕)
NEW  src/apps/desktop/src/__tests__/KanbanView.searchFilter.spec.ts (behavioural tests: debounced refetch, empty banner)
EDIT src/apps/desktop/src/__tests__/apiTasks.spec.ts               (if existing; + q param tests)

EDIT docs/SPEC.md                                                 (+ §3.7 search entry; §10.2.1 PR index)
EDIT NALAR.md                                                     (+ Recent changes entry once shipped)
```

Total: ~9 files (2 NEW, 7 EDIT).

---

## Root Cause (read this before chunking — saves re-discovery)

```
User wants to find a specific task on a kanban board with 38+ tasks.

Current behavior:
  - Scroll through all columns
  - Visually scan card titles

Failure mode at scale:
  - With 200+ tasks (typical "merged" column on production boards), scroll-and-scan fails
  - With > 100 tasks (MAX_PAGE_SIZE), a frontend .filter() only sees the first page
  - Tasks on pages 2-N are invisible to search until the user scrolls

Desired behavior (per spec):
  ┌──────────────────────────────────────────────────────────────────────────┐
  │ sprint bulan juni    ⚠️ Set project root  🔍 Search tasks…  ✕    ⚙️    │
  ├──────────────────────────────────────────────────────────────────────────┤
  │ todo(0)  │ in progress(1)  │ in_review(0) │ in_review_task(1) │ ...    │
  │          │ ┌──────────┐    │               │ ┌──────────┐     │        │
  │          │ │ design   │    │               │ │ design   │     │        │
  │          │ │ mode fix │    │               │ │ under    │     │        │
  │          │ └──────────┘    │               │ └──────────┘     │        │
  └──────────────────────────────────────────────────────────────────────────┘
  - User types "design" → backend filters, columns update
  - "merged" column goes from 38 cards to 2 cards (filtered count)
  - "No tasks yet" placeholder appears in columns that had matches elsewhere
  - Esc / ✕ clears → unfiltered list returns
```

The wire/binding is the bug class. Going from "feature request" → "filter at SQL" → "300ms debounce + cursor reset" requires 6 chunks:

1. **Backend DB fn** (`listWorkspaceItemTasksWithCursor`) accepts `q` + applies WHERE clause (TDD).
2. **Backend handler** (`tasks_list.zig`) parses `q` + forwards it.
3. **Frontend API** (`api.getTasks`) adds `q` param.
4. **Frontend store** (`workspacesStore`) accepts `q` in `fetchKanbanTasks` + `loadMoreTasks` + per-item `q` map for SSE.
5. **Frontend component** (`<KanbanSearchInput>`) — new standalone component (TDD).
6. **Frontend wiring** (`KanbanView.vue`) — render in header + debounced refetch + empty banner.

---

## Chunk 1 — Backend: `listWorkspaceItemTasksWithCursor` accepts `q`

**Outcome:** The DB function takes an optional `q: ?[]const u8` parameter. When set, filters by `LOWER(t.name) LIKE ? ESCAPE '\' OR LOWER(COALESCE(t.description, '')) LIKE ? ESCAPE '\' OR LOWER(COALESCE(t.tags, '')) LIKE ? ESCAPE '\'`. Escapes user input `%` and `_` to `\%` and `\_` before binding. Returns the same `WorkspaceItemTaskListCursorResult` as before; pagination advances through the filtered set. Empty/null `q` → no filter (current behavior).

### Task 1.1 — Add `q` parameter to `listWorkspaceItemTasksWithCursor`

**Files to edit:** `src/ai_workflow/tui/llm_history.zig` (the function `listWorkspaceItemTasksWithCursor`)

- [ ] Read `src/ai_workflow/tui/llm_history.zig` and locate the existing `listWorkspaceItemTasksWithCursor` function (search for `pub fn listWorkspaceItemTasksWithCursor`).
- [ ] Read its signature, its WHERE clause construction, and its CALL binding pattern.
- [ ] Read `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` to find the existing `setupDb()` and call site (mirror the same fixture).
- [ ] Write the failing tests in the EXISTING `tasks_list_test.zig` (append, don't replace):
  ```zig
  test "tasks_list returns only tasks matching q in name" {
      // setupDb with 3 tasks: "fix login", "fix signup", "logout fix"
      // GET /tasks?q=login → returns 1 task "fix login"
  }

  test "tasks_list matches q in description" {
      // setupDb with 3 tasks, one of which has description "contains the word login"
      // GET /tasks?q=login → returns that task (NOT the others with "login" in name)
  }

  test "tasks_list matches q in tags" {
      // setupDb with 3 tasks, one with tags = '["login","urgent"]'
      // GET /tasks?q=login → returns that task
  }

  test "tasks_list q is case-insensitive" {
      // GET /tasks?q=LOGIN matches "login" (lowercase), "LOGIN" (uppercase), "Login" (mixed)
  }

  test "tasks_list empty q is equivalent to no filter" {
      // GET /tasks?q= → returns all 3 tasks (no filter applied)
  }

  test "tasks_list missing q is equivalent to no filter" {
      // GET /tasks (no q param) → returns all 3 tasks
  }

  test "tasks_list escapes % so literal % matches nothing" {
      // seeded data has no literal '%' in any task → GET /tasks?q=% returns 0 matches
      // (without ESCAPE, this would return ALL tasks because % is a LIKE wildcard)
  }

  test "tasks_list escapes _ so literal _ matches nothing" {
      // seeded data has no literal '_' → GET /tasks?q=_ returns 0 matches
  }

  test "tasks_list SQL injection attempt is a no-op" {
      // GET /tasks?q=' OR '1'='1 → returns 0 matches (no SQL parse error)
  }

  test "tasks_list q combined with cursor advances through matches only" {
      // setupDb with 5 matching + 5 non-matching tasks
      // GET /tasks?q=match&limit=2 → returns 2 matches + next_cursor
      // GET /tasks?q=match&limit=2&cursor=<next_cursor> → returns next 2 matches
      // Assert: never returns non-matching tasks; pagination resets correctly
  }

  test "tasks_list q nonexistent returns empty list with has_more=false" {
      // GET /tasks?q=nonexistent_token_xyz_12345 → returns { tasks: [], count: 0, has_more: false, next_cursor: null }
  }
  ```
  Each test calls the handler (via direct useCase call OR via a tiny ginwa-server harness — mirror the existing pattern in `tasks_list_test.zig`).

- [ ] Run `timeout 180 zig build test --summary all 2>&1 | grep -E 'tasks_list .* matching|tasks_list .* case|tasks_list .* inject|tasks_list .* escape|tasks_list .* nonexi'`. Expected: failing (function doesn't accept `q` yet).

- [ ] Modify `listWorkspaceItemTasksWithCursor` signature:
  ```zig
  pub fn listWorkspaceItemTasksWithCursor(
      allocator: std.mem.Allocator,
      db: *sqlite.SqliteBackend,
      item_id: []const u8,
      limit: u32,
      cursor: ?[]const u8,
      sort_field: TaskSortField,
      sort_direction: TaskSortDirection,
      q: ?[]const u8,  // NEW — case-insensitive substring filter
  ) !WorkspaceItemTaskListCursorResult {
  ```

- [ ] Add an escape helper at the top of `llm_history.zig` (above `listWorkspaceItemTasksWithCursor`):
  ```zig
  /// Escape SQL LIKE wildcards (`%`, `_`, and the escape character `\` itself)
  /// in user input before binding. The WHERE clause uses `LIKE ? ESCAPE '\'`,
  /// so we prefix `\` to each literal occurrence. Returns the escaped slice
  /// (caller frees).
  fn escapeLikePattern(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
      var out: std.ArrayList(u8) = .empty;
      defer out.deinit(allocator);
      for (input) |c| {
          if (c == '%' or c == '_' or c == '\\') {
              try out.append(allocator, '\\');
          }
          try out.append(allocator, c);
      }
      return out.toOwnedSlice(allocator);
  }
  ```

- [ ] Inside `listWorkspaceItemTasksWithCursor`, before the SQL query is built:
  ```zig
  // When q is set, escape user-supplied LIKE wildcards then wrap in %...%.
  // NULL/empty q means "no filter" — skip the WHERE addition entirely so the
  // cursor query stays an efficient index hit on workspace_item_id alone.
  var escaped_q: ?[]u8 = null;
  if (q) |raw_q| {
      if (raw_q.len > 0) {
          const inner = try escapeLikePattern(allocator, raw_q);
          // Surround with % on both sides for substring match.
          escaped_q = try std.fmt.allocPrint(allocator, "%{s}%", .{inner});
          allocator.free(inner);
      }
  }
  defer if (escaped_q) |e| allocator.free(e);
  ```

- [ ] In the WHERE-clause builder, when `escaped_q` is non-null, append 3 LIKE clauses. Look at the existing `where_buf.appendSlice` pattern (likely in a switch on sort_field or a direct append). The new WHERE clause is:
  ```zig
  AND (
       LOWER(t.name)                          LIKE ? ESCAPE '\\'
    OR LOWER(COALESCE(t.description, ''))     LIKE ? ESCAPE '\\'
    OR LOWER(COALESCE(t.tags, ''))            LIKE ? ESCAPE '\\'
  )
  ```
  And bind `escaped_q.?` three times.

- [ ] **Pitfall**: when `escaped_q` is null (no q), don't add the WHERE clause at all — keep the original efficient WHERE on `workspace_item_id` only. Don't add `LIKE '%%'` (would match all but execute the LOWER/COALESCE on every row).

- [ ] Run `timeout 180 zig build test --summary all 2>&1 | grep -E 'tasks_list .* matching|tasks_list .* escape|tasks_list .* inject|tasks_list .* nonexi'`. Expected: 10 new tests passing.

- [ ] Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`. Expected: clean (catches lazy-analysis errors `zig build test` misses).

- [ ] Commit: `git add -A && git commit -m "feat(backend): listWorkspaceItemTasksWithCursor accepts q param for case-insensitive LIKE filter"`.

---

## Chunk 2 — Backend: `tasks_list.zig` parseInput forwards `q`

**Outcome:** The HTTP handler parses `q` from the URL query string and forwards it to the DB function. Empty/missing `q` → not passed (DB interprets as no filter). The wire shape is unchanged from the client's perspective — same response body.

### Task 2.1 — Parse `q` in `tasks_list.zig::parseInput` and forward to DB fn

**Files to edit:** `src/ai_workflow/tui/http_handlers/tasks_list.zig`

- [ ] Read `src/ai_workflow/tui/http_handlers/tasks_list.zig::parseInput` (around line 65) and the existing `TasksListInput` struct (around line 47).

- [ ] Write the failing tests in `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` (append; mirror the existing pattern — direct `useCase(allocator, db, input)` calls OR HTTP-harness calls):
  ```zig
  test "parseInput reads q from URL query string" {
      // Construct a fake query map with { "q" -> "design" }
      // Call parseInput directly (or refactor to expose it for testing)
      // Assert TasksListInput.q == "design"
  }

  test "parseInput treats empty q as null (no filter)" {
      // query map with { "q" -> "" }
      // Assert TasksListInput.q == null
  }

  test "parseInput treats missing q as null (no filter)" {
      // query map without "q"
      // Assert TasksListInput.q == null
  }

  test "useCase passes q through to the DB fn" {
      // setupDb with 2 matching + 1 non-matching task
      // Call useCase with .q = "match" → returns only matching tasks
  }
  ```
  If `parseInput` isn't currently exposed for direct testing, refactor it to `pub fn` OR add a test-only entrypoint. Mirror whichever pattern the file uses for the other parsers.

- [ ] Run `timeout 180 zig build test --summary all 2>&1 | grep -E 'parseInput|useCase passes q'`. Expected: failing.

- [ ] Add `q: ?[]const u8` to `TasksListInput`:
  ```zig
  pub const TasksListInput = struct {
      item_id: []const u8,
      limit: u32,
      cursor: ?[]const u8,
      sort_field: llm_history.TaskSortField,
      sort_direction: llm_history.TaskSortDirection,
      q: ?[]const u8,  // NEW
  };
  ```

- [ ] Update `parseInput` to parse `q`:
  ```zig
  // q: empty string or missing → null (no filter)
  const q_raw = query.get("q");
  const q: ?[]const u8 = if (q_raw) |raw| (if (raw.len == 0) null else raw) else null;
  ```
  Add `q = q` to the returned struct.

- [ ] Update `useCase` to forward `q` to the DB fn call:
  ```zig
  const result = ai_mod.workspace_item_tasks.listWorkspaceItemTasksWithCursor(
      allocator,
      db,
      input.item_id,
      input.limit,
      input.cursor,
      input.sort_field,
      input.sort_direction,
      input.q,  // NEW
  ) catch return error.QueryFailed;
  ```

- [ ] Run `timeout 180 zig build test --summary all 2>&1 | grep -E 'parseInput|useCase passes q'`. Expected: 4 new tests pass; all Chunk 1 tests still pass.

- [ ] Run `timeout 180 zig build install:linux:system 2>&1 | tail -n 5`. Expected: clean.

- [ ] Commit: `git add -A && git commit -m "feat(backend): tasks_list handler parses q query param and forwards to DB"`.

---

## Chunk 3 — Frontend: `api.getTasks` accepts `q`

**Outcome:** The frontend API wrapper `getTasks` gains a 7th optional `q` parameter. When non-empty, it sets `?q=<value>` in the URLSearchParams. When empty/undefined, it omits the param (the backend treats missing/empty as no filter).

### Task 3.1 — Extend `getTasks` signature + URL params

**Files to edit:** `src/apps/desktop/src/api/index.ts` (around line 473)

- [ ] Read `src/apps/desktop/src/api/index.ts` lines 470-510 (the existing `getTasks` function).

- [ ] Locate the test file `src/apps/desktop/src/__tests__/apiTasks.spec.ts` (or grep `getTasks` in `__tests__` — if no existing test file, create one).

- [ ] Write the failing tests (in `apiTasks.spec.ts` OR new file if not exists):
  ```ts
  it('includes ?q= in the URL when q is non-empty', async () => {
      fetchMock.mockResolvedValueOnce(mockOk({ tasks: [], has_more: false, next_cursor: null }))
      await getTasks('ws_1', 'item_1', 20, undefined, 'updated_at', 'desc', 'design')
      const url = fetchMock.mock.calls[0][0]
      expect(url).toContain('q=design')
  })

  it('omits q param when q is undefined', async () => {
      fetchMock.mockResolvedValueOnce(mockOk({ tasks: [], has_more: false, next_cursor: null }))
      await getTasks('ws_1', 'item_1')
      const url = fetchMock.mock.calls[0][0]
      expect(url).not.toContain('q=')
  })

  it('omits q param when q is empty string', async () => {
      fetchMock.mockResolvedValueOnce(mockOk({ tasks: [], has_more: false, next_cursor: null }))
      await getTasks('ws_1', 'item_1', 20, undefined, 'updated_at', 'desc', '')
      const url = fetchMock.mock.calls[0][0]
      expect(url).not.toContain('q=')
  })

  it('URL-encodes q value (spaces, special chars)', async () => {
      fetchMock.mockResolvedValueOnce(mockOk({ tasks: [], has_more: false, next_cursor: null }))
      await getTasks('ws_1', 'item_1', 20, undefined, 'updated_at', 'desc', 'fix login bug')
      const url = fetchMock.mock.calls[0][0]
      expect(url).toContain('q=fix%20login%20bug')  // OR +login+bug — verify which URLSearchParams produces
  })
  ```

- [ ] Run `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/apiTasks.spec.ts 2>&1 | tail -n 20`. Expected: 4 tests fail.

- [ ] Update the `getTasks` function signature:
  ```ts
  export async function getTasks(
    workspaceId: string,
    itemId: string,
    limit = 20,
    cursor?: string,
    sortBy: 'created_at' | 'updated_at' | 'name' = 'updated_at',
    direction: 'asc' | 'desc' = 'desc',
    q?: string,   // NEW
  ): Promise<{...}> {
    const params = new URLSearchParams()
    params.set('limit', String(limit))
    params.set('sort_by', sortBy)
    params.set('direction', direction)
    if (cursor) {
      params.set('cursor', cursor)
    }
    if (q && q.length > 0) {     // NEW
      params.set('q', q)
    }
    // ... rest unchanged
  }
  ```

- [ ] Run `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/apiTasks.spec.ts 2>&1 | tail -n 20`. Expected: 4 tests pass.

- [ ] Run `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 10`. Expected: clean (vue-tsc catches the missing comma / signature mismatch).

- [ ] Commit: `git add -A && git commit -m "feat(api): getTasks accepts optional q query param"`.

---

## Chunk 4 — Frontend: `workspacesStore.fetchKanbanTasks` + `loadMoreTasks` forward `q` + per-item `q` map

**Outcome:** The store's `fetchKanbanTasks(ws, item, limit=100, cursor?, q?)` accepts and forwards `q`. `loadMoreTasks` also forwards the current `q` (read from the per-item map). A new per-item `Map<itemId, string>` (`activeSearchQueries`) lets SSE handlers and `loadMoreTasks` read the active search without prop-drilling. Each call to `fetchKanbanTasks(..., q)` updates the map; clearing the search (q === undefined) removes the entry.

### Task 4.1 — Extend store actions + add per-item q map

**Files to edit:** `src/apps/desktop/src/stores/workspaces.ts`

- [ ] Read the existing `fetchKanbanTasks` (around line 846), `loadMoreTasks` (around line 1420), and the stores object structure (look for `state()` and `actions:`).

- [ ] Locate the test file `src/apps/desktop/src/__tests__/workspacesStoreKanbanTasks.spec.ts` (existing per the kanban-lazy-load-tasks memory).

- [ ] Write the failing tests in `workspacesStoreKanbanTasks.spec.ts` (append):
  ```ts
  it('fetchKanbanTasks forwards q to api.getTasks when q is non-empty', async () => {
      vi.mocked(api.getTasks).mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
      await store.fetchKanbanTasks('ws_1', 'item_1', 100, undefined, 'design')
      expect(api.getTasks).toHaveBeenCalledWith('ws_1', 'item_1', 100, undefined, 'updated_at', 'desc', 'design')
  })

  it('fetchKanbanTasks forwards q=undefined when search is cleared', async () => {
      vi.mocked(api.getTasks).mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
      await store.fetchKanbanTasks('ws_1', 'item_1', 100, undefined, undefined)
      expect(api.getTasks).toHaveBeenCalledWith('ws_1', 'item_1', 100, undefined, 'updated_at', 'desc', undefined)
  })

  it('loadMoreTasks forwards the per-item active q', async () => {
      // First set the active q via fetchKanbanTasks(q='design')
      await store.fetchKanbanTasks('ws_1', 'item_1', 100, undefined, 'design')
      // Mock the loadMoreTasks call
      vi.mocked(api.getTasks).mockResolvedValue({ tasks: [], has_more: true, next_cursor: 'abc' })
      await store.loadMoreTasks('ws_1', 'item_1')
      // loadMoreTasks should pass the stored q to api.getTasks
      expect(api.getTasks).toHaveBeenCalledWith('ws_1', 'item_1', 100, expect.any(String), 'updated_at', 'desc', 'design')
  })

  it('loadMoreTasks forwards undefined q when no search is active', async () => {
      vi.mocked(api.getTasks).mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
      await store.loadMoreTasks('ws_1', 'item_1')
      expect(api.getTasks).toHaveBeenCalledWith('ws_1', 'item_1', 100, undefined, 'updated_at', 'desc', undefined)
  })

  it('activeSearchQueries is updated by fetchKanbanTasks(q)', async () => {
      vi.mocked(api.getTasks).mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
      await store.fetchKanbanTasks('ws_1', 'item_1', 100, undefined, 'design')
      expect(store.activeSearchQueries.get('item_1')).toBe('design')
  })

  it('activeSearchQueries entry is removed when fetchKanbanTasks(q=undefined)', async () => {
      vi.mocked(api.getTasks).mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
      await store.fetchKanbanTasks('ws_1', 'item_1', 100, undefined, 'design')
      await store.fetchKanbanTasks('ws_1', 'item_1', 100, undefined, undefined)
      expect(store.activeSearchQueries.has('item_1')).toBe(false)
  })
  ```

- [ ] Run `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/workspacesStoreKanbanTasks.spec.ts 2>&1 | tail -n 20`. Expected: 6 new tests fail.

- [ ] Add the per-item q map to the store state:
  ```ts
  // Map<itemId, string> — the active search query per board. Read by
  // loadMoreTasks and SSE handlers to forward q on refetch.
  // NOT in Pinia's strict map type because Map is non-reactive by default
  // — use a plain object Map<string, string> via reactive() IF reactivity
  // is needed. For our read-pattern (forward-on-refetch only), a plain Map
  // suffices; assign via direct property mutation. Verify with vue-test-utils
  // that map reads after fetchKanbanTasks() return the updated value.
  activeSearchQueries: new Map<string, string>(),
  ```

- [ ] Update `fetchKanbanTasks` signature:
  ```ts
  async fetchKanbanTasks(
    workspaceId: string,
    itemId: string,
    limit = 100,
    cursor?: string,
    q?: string,   // NEW
  ): Promise<void> {
    // ... existing logic ...
    const response = await api.getTasks(workspaceId, itemId, limit, cursor, 'updated_at', 'desc', q)
    // ... existing assignment logic ...

    // Track the active q for SSE / loadMore forwarding
    if (q && q.length > 0) {
      this.activeSearchQueries.set(itemId, q)
    } else {
      this.activeSearchQueries.delete(itemId)
    }
  }
  ```

- [ ] Update `loadMoreTasks` to read q from the map:
  ```ts
  async loadMoreTasks(workspaceId: string, itemId: string): Promise<void> {
    // ... existing guards (isLoadingMoreTasks, hasMoreTasks) ...
    const q = this.activeSearchQueries.get(itemId)
    const response = await api.getTasks(
      workspaceId, itemId, 100,
      this.$state.workspaces.find(w => w.id === workspaceId)?.items.find(i => i.id === itemId)?.nextCursor,
      'updated_at', 'desc',
      q,  // NEW — forward active search
    )
    // ... existing append logic ...
  }
  ```

- [ ] Run `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/workspacesStoreKanbanTasks.spec.ts 2>&1 | tail -n 20`. Expected: 6 new tests pass; no regressions.

- [ ] Run `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 10`. Expected: vue-tsc clean (signature changes are type-checked here, NOT in vitest).

- [ ] Commit: `git add -A && git commit -m "feat(store): workspacesStore.fetchKanbanTasks + loadMoreTasks forward q; per-item activeSearchQueries map"`.

---

## Chunk 5 — Frontend: `<KanbanSearchInput>` component (TDD)

**Outcome:** A new standalone Vue 3 component (`<KanbanSearchInput>`) that:
- Accepts `v-model` (the typed query string)
- Renders a compact input with `🔍` left icon, `✕` clear button on the right (visible when value is non-empty)
- Emits `update:modelValue` on input
- Clears on Esc key
- Uses `--semantic-card-bg` + `--color-border` for styling (matches existing inputs)

### Task 5.1 — Build the component

**Files to create:** `src/apps/desktop/src/components/kanban/KanbanSearchInput.vue`

- [ ] Read the existing `KanbanColumn.vue` for the styling tokens used (`--semantic-sidebar-bg`, `--color-border`, `--semantic-text-dim`) — match.

- [ ] Write the failing tests in `src/apps/desktop/src/__tests__/KanbanSearchInput.spec.ts`:
  ```ts
  import { mount } from '@vue/test-utils'
  import { describe, it, expect } from 'vitest'
  import KanbanSearchInput from '../components/kanban/KanbanSearchInput.vue'

  describe('KanbanSearchInput', () => {
    it('renders with empty placeholder when v-model is empty', () => {
      const wrapper = mount(KanbanSearchInput, { props: { modelValue: '' } })
      const input = wrapper.find('input[type="text"]')
      expect(input.exists()).toBe(true)
      expect((input.element as HTMLInputElement).value).toBe('')
    })

    it('emits update:modelValue with the typed character on input', async () => {
      const wrapper = mount(KanbanSearchInput, { props: { modelValue: '' } })
      const input = wrapper.find('input[type="text"]')
      await input.setValue('d')
      // Vue's v-model fires update:modelValue with the new value
      expect(wrapper.emitted('update:modelValue')).toBeTruthy()
      expect(wrapper.emitted('update:modelValue')![0]).toEqual(['d'])
    })

    it('renders the clear ✕ button only when modelValue is non-empty', async () => {
      const emptyWrap = mount(KanbanSearchInput, { props: { modelValue: '' } })
      expect(emptyWrap.find('[data-testid="kanban-search-input-clear"]').exists()).toBe(false)

      const filledWrap = mount(KanbanSearchInput, { props: { modelValue: 'design' } })
      expect(filledWrap.find('[data-testid="kanban-search-input-clear"]').exists()).toBe(true)
    })

    it('clicking the clear ✕ button emits update:modelValue with empty string', async () => {
      const wrapper = mount(KanbanSearchInput, { props: { modelValue: 'design' } })
      await wrapper.find('[data-testid="kanban-search-input-clear"]').trigger('click')
      expect(wrapper.emitted('update:modelValue')).toBeTruthy()
      expect(wrapper.emitted('update:modelValue')![0]).toEqual([''])
    })

    it('pressing Esc clears the input (emits empty string)', async () => {
      const wrapper = mount(KanbanSearchInput, { props: { modelValue: 'design' } })
      const input = wrapper.find('input[type="text"]')
      await input.trigger('keydown.esc')
      expect(wrapper.emitted('update:modelValue')![0]).toEqual([''])
    })

    it('does not lose focus when Esc clears', async () => {
      const wrapper = mount(KanbanSearchInput, { props: { modelValue: 'design' } })
      const input = wrapper.find('input[type="text"]')
      await input.trigger('focus')
      await input.trigger('keydown.esc')
      // The component should NOT call .blur() on Esc — just clear
      expect((input.element as HTMLInputElement)).toBe(document.activeElement)
    })
  })
  ```

- [ ] Run `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/KanbanSearchInput.spec.ts 2>&1 | tail -n 20`. Expected: 6 tests fail (component doesn't exist).

- [ ] Create the component. Use `<script setup lang="ts">` with `defineProps<{ modelValue: string }>()` + `defineEmits<{ 'update:modelValue': [value: string] }>()`:
  ```vue
  <script setup lang="ts">
  const props = defineProps<{ modelValue: string }>()
  const emit = defineEmits<{ 'update:modelValue': [value: string] }>()

  const onInput = (e: Event) => {
    const value = (e.target as HTMLInputElement).value
    emit('update:modelValue', value)
  }

  const clear = () => {
    emit('update:modelValue', '')
  }

  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault()
      clear()
    }
  }
  </script>

  <template>
    <div class="relative flex items-center" data-testid="kanban-search-input-container">
      <input
        :value="modelValue"
        @input="onInput"
        @keydown="onKeyDown"
        type="text"
        placeholder="🔍 Search tasks…"
        class="w-48 px-2 py-1 pr-7 rounded text-xs outline-none"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
        data-testid="kanban-search-input"
        aria-label="Search tasks by name, description, or tags"
      />
      <button
        v-if="modelValue"
        type="button"
        @click="clear"
        class="absolute right-1 w-5 h-5 flex items-center justify-center rounded hover:opacity-80"
        style="color: var(--semantic-text-dim);"
        data-testid="kanban-search-input-clear"
        aria-label="Clear search"
      >
        <span aria-hidden="true">✕</span>
      </button>
    </div>
  </template>
  ```

- [ ] Run `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/KanbanSearchInput.spec.ts 2>&1 | tail -n 20`. Expected: 6 tests pass.

- [ ] Run `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 10`. Expected: clean.

- [ ] Commit: `git add -A && git commit -m "feat(kanban): KanbanSearchInput component (v-model, Esc, ✕)"`.

---

## Chunk 6 — Frontend: Wire `<KanbanSearchInput>` in `KanbanView.vue`

**Outcome:** `KanbanView.vue` renders `<KanbanSearchInput>` in the header, between the `⚠️ Set project root` button and the `⚙️ Settings` button. The component is `v-model`-bound to a debounced (300ms) `searchQuery` ref. The debounced value drives `workspacesStore.fetchKanbanTasks(ws, item, 100, undefined, q)` — the cursor reset to page 1 of the filtered set. An empty state banner (`No tasks match "..."`) renders when `tasks.length === 0 && searchQuery.trim() !== ''`.

### Task 6.1 — Render + debounce + refetch

**Files to edit:** `src/apps/desktop/src/components/kanban/KanbanView.vue`

- [ ] Read `src/apps/desktop/src/components/kanban/KanbanView.vue` lines 56-180 (the script setup section) + lines 427-500 (the header template).

- [ ] Locate the existing `@vueuse/core` import in the project (`rg "@vueuse/core" src/apps/desktop/src/`). If `refDebounced` is available, use it. Otherwise, hand-roll a 300ms debounce with `setTimeout`.

- [ ] Write the failing tests in `src/apps/desktop/src/__tests__/KanbanView.searchFilter.spec.ts`:
  ```ts
  import { mount, flushPromises } from '@vue/test-utils'
  import { describe, it, expect, vi, beforeEach } from 'vitest'
  import { createPinia, setActivePinia } from 'pinia'
  import KanbanView from '../components/kanban/KanbanView.vue'
  import { useWorkspacesStore } from '../stores/workspaces'
  import * as api from '../api'

  describe('KanbanView search filter wiring', () => {
    beforeEach(() => {
      setActivePinia(createPinia())
      vi.clearAllMocks()
    })

    function makeItem() {
      return {
        id: 'item_1',
        item_type: 'kanban' as const,
        name: 'Test Board',
        path: '/tmp',
        kanban_columns: [
          { id: 'col_a', name: 'todo', position: 0, created_at: '2026-01-01' },
          { id: 'col_b', name: 'done', position: 1, created_at: '2026-01-01' },
        ],
        tasks: [
          { id: 'task_1', name: 'fix login', description: '', task_type: 'standard', kanban_column_id: 'col_a', kanban_position: 0 },
          { id: 'task_2', name: 'logout', description: '', task_type: 'standard', kanban_column_id: 'col_a', kanban_position: 1 },
          { id: 'task_3', name: 'design', description: '', task_type: 'standard', kanban_column_id: 'col_b', kanban_position: 0 },
        ],
        hasMoreTasks: false,
      } as any
    }

    it('renders <KanbanSearchInput> in the header, left of the settings button', () => {
      const wrapper = mount(KanbanView, {
        props: { item: makeItem(), workspaceId: 'ws_1' },
      })
      const searchInput = wrapper.find('[data-testid="kanban-search-input"]')
      const settingsButton = wrapper.find('[data-testid="kanban-view-item_1-open-settings"]')
      expect(searchInput.exists()).toBe(true)
      expect(settingsButton.exists()).toBe(true)
      // Verify the search input appears BEFORE the settings button in the DOM
      const allEls = wrapper.findAll('[data-testid]')
      const searchIdx = allEls.findIndex((w) => w.attributes('data-testid') === 'kanban-search-input')
      const settingsIdx = allEls.findIndex((w) => w.attributes('data-testid') === 'kanban-view-item_1-open-settings')
      expect(searchIdx).toBeLessThan(settingsIdx)
    })

    it('typing in the search input triggers a debounced (300ms) refetch with q', async () => {
      vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
      const store = useWorkspacesStore()
      vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

      const wrapper = mount(KanbanView, {
        props: { item: makeItem(), workspaceId: 'ws_1' },
      })

      const input = wrapper.find('[data-testid="kanban-search-input"]')
      await input.setValue('design')

      // Immediately after setValue, fetchKanbanTasks should NOT have been called yet
      // (we're still inside the debounce window)
      expect(store.fetchKanbanTasks).not.toHaveBeenCalledWith('ws_1', 'item_1', 100, undefined, 'design')

      // Advance the fake timer past the debounce window
      vi.advanceTimersByTime(350)
      await flushPromises()

      expect(store.fetchKanbanTasks).toHaveBeenCalledWith('ws_1', 'item_1', 100, undefined, 'design')
    })

    it('clearing the search input (Esc) triggers a debounced refetch with q=undefined', async () => {
      vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
      const store = useWorkspacesStore()
      vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

      const wrapper = mount(KanbanView, {
        props: { item: { ...makeItem(), tasks: [] }, workspaceId: 'ws_1' },
      })

      // First set a query
      await wrapper.find('[data-testid="kanban-search-input"]').setValue('design')
      vi.advanceTimersByTime(350)
      await flushPromises()

      // Then clear it (Esc)
      await wrapper.find('[data-testid="kanban-search-input"]').trigger('keydown.esc')
      vi.advanceTimersByTime(350)
      await flushPromises()

      const calls = (store.fetchKanbanTasks as any).mock.calls
      // Last call should have q=undefined (treat cleared as no filter)
      expect(calls[calls.length - 1]).toEqual(['ws_1', 'item_1', 100, undefined, undefined])
    })

    it('renders "No tasks match" banner when tasks.length === 0 && searchQuery is non-empty', async () => {
      const wrapper = mount(KanbanView, {
        props: {
          item: { ...makeItem(), tasks: [] },
          workspaceId: 'ws_1',
        },
      })
      const input = wrapper.find('[data-testid="kanban-search-input"]')
      await input.setValue('nothing-matches')
      expect(wrapper.find('[data-testid="kanban-view-no-search-matches"]').exists()).toBe(true)
      expect(wrapper.find('[data-testid="kanban-view-no-search-matches"]').text()).toContain('nothing-matches')
    })

    it('does NOT render "No tasks match" banner when searchQuery is empty', () => {
      const wrapper = mount(KanbanView, {
        props: { item: { ...makeItem(), tasks: [] }, workspaceId: 'ws_1' },
      })
      expect(wrapper.find('[data-testid="kanban-view-no-search-matches"]').exists()).toBe(false)
    })

    it('does NOT render "No tasks match" banner when tasks exist (even if search is active)', () => {
      const wrapper = mount(KanbanView, {
        props: { item: makeItem(), workspaceId: 'ws_1' },
      })
      // tasks are pre-populated; banner should not render regardless of searchQuery
      expect(wrapper.find('[data-testid="kanban-view-no-search-matches"]').exists()).toBe(false)
    })
  })
  ```

- [ ] Run `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/KanbanView.searchFilter.spec.ts 2>&1 | tail -n 30`. Expected: 6 tests fail.

- [ ] Modify `KanbanView.vue`:
  - Import `refDebounced` from `@vueuse/core` (or hand-roll debounce if not available).
  - Import `KanbanSearchInput` from `./KanbanSearchInput.vue`.
  - Add `const searchQuery = ref('')`.
  - Add `const debouncedSearch = refDebounced(searchQuery, 300)`.
  - Add a watcher on `debouncedSearch` that calls `workspacesStore.fetchKanbanTasks(ws, item, 100, undefined, q)` with the trimmed debounced value or `undefined` if empty.
    ```ts
    watch(debouncedSearch, (newQ) => {
      const trimmed = newQ.trim()
      void workspacesStore.fetchKanbanTasks(
        props.workspaceId,
        effectiveItemId.value,
        100,
        undefined,  // cursor reset → page 1 of filtered set
        trimmed || undefined,
      )
    })
    ```

- [ ] Modify the header template to render `<KanbanSearchInput>` between `⚠️ Set project root` and `⚙️ Settings`:
  ```vue
  <KanbanSearchInput v-model="searchQuery" />
  ```

- [ ] Add the empty-state banner between the header and the columns row:
  ```vue
  <div
    v-if="tasks.length === 0 && searchQuery.trim() !== ''"
    class="px-3 py-2 text-xs shrink-0"
    style="color: var(--semantic-text-dim);"
    :data-testid="`kanban-view-${item.id}-no-search-matches`"
  >
    No tasks match "{{ searchQuery }}"
  </div>
  ```

- [ ] Run `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/KanbanView.searchFilter.spec.ts 2>&1 | tail -n 30`. Expected: 6 new tests pass.

- [ ] Run `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 10`. Expected: clean (vue-tsc verifies the new emits, computed props, imports).

- [ ] Commit: `git add -A && git commit -m "feat(kanban): wire KanbanSearchInput in KanbanView header (debounced refetch + empty state banner)"`.

---

## Chunk 7 — SSE handler forwards `q` (and final verification)

**Outcome:** SSE handlers (`useKanbanSseStore` or equivalent) read the active `q` from `workspacesStore.activeSearchQueries.get(itemId)` and forward it on refetch triggered by `kanban_task.*` events. This keeps the search consistent when OTHER events fire (e.g. a remote task moved into the board). Also includes the final cross-platform verification + live smoke test.

### Task 7.1 — SSE handler forwards q

**Files to edit:** `src/apps/desktop/src/stores/designSse.ts` and/or `src/apps/desktop/src/composables/useKanbanSseStore.ts` (whichever exists — search for `kanban_task` SSE handler).

- [ ] Search for `kanban_task` SSE event handlers: `rg -n 'kanban_task\.' src/apps/desktop/src/`. Look for `.fetchKanbanTasks(` or `getTasks(` calls inside SSE handlers.

- [ ] Write a failing test (in the existing SSE-handler test file if exists, OR new file):
  ```ts
  it('SSE kanban_task handler forwards active q when refetching', async () => {
      const store = useWorkspacesStore()
      vi.spyOn(store, 'fetchKanbanTasks').mockResolvedValue()

      // Set up an active search
      vi.spyOn(api, 'getTasks').mockResolvedValueOnce({ tasks: [], has_more: false, next_cursor: null })
      await store.fetchKanbanTasks('ws_1', 'item_1', 100, undefined, 'design')

      // Simulate an incoming SSE event
      const event = { workspace_id: 'ws_1', item_id: 'item_1', /* ... */ }
      sseHandler(event)

      // The refetch should carry the active q
      expect(store.fetchKanbanTasks).toHaveBeenCalledWith('ws_1', 'item_1', expect.any(Number), undefined, 'design')
  })
  ```

- [ ] Locate the SSE handler in the codebase and update its `fetchKanbanTasks(...)` / `getTasks(...)` call to forward `store.activeSearchQueries.get(itemId)`.

- [ ] Run `cd src/apps/desktop && timeout 120 bunx vitest run src/__tests__/<sse-handler>.spec.ts 2>&1 | tail -n 20`. Expected: passes.

- [ ] Run `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 10`. Expected: clean.

- [ ] Commit: `git add -A && git commit -m "feat(kanban): SSE handler forwards active q on kanban_task refetch"`.

### Task 7.2 — Final verification + docs update

**Files to edit:** `docs/SPEC.md` (add §3.7 search entry)

- [ ] Run the full backend test suite:
  ```bash
  cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-task-search
  timeout 180 zig build test --summary all 2>&1 | tail -n 10
  ```
  Expected: all tests pass (no regressions + 10 new backend tests in tasks_list).

- [ ] Build the binary:
  ```bash
  timeout 180 zig build install:linux:system 2>&1 | tail -n 5
  ```
  Expected: clean (catches lazy-analysis errors).

- [ ] Fresh full rebuild:
  ```bash
  rm -rf zig-out/bin && timeout 360 zig build 2>&1 | tail -n 5
  ```
  Expected: clean.

- [ ] Cross-compile:
  ```bash
  cat > /tmp/kanban_search_test_mod.zig <<'EOF'
  const nalarcore = @import("nalarcore");
  pub fn main() void {
      const m = nalarcore.ai_mod.workspace_item_tasks;
      _ = m.listWorkspaceItemTasksWithCursor;
  }
  EOF
  zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
    --dep nalarcore -Mroot=/tmp/kanban_search_test_mod.zig \
    -Mnalarcore=src/root.zig 2>&1 | tail -n 5
  zig build-obj -fno-emit-bin -target aarch64-macos -lc \
    --dep nalarcore -Mroot=/tmp/kanban_search_test_mod.zig \
    -Mnalarcore=src/root.zig 2>&1 | tail -n 5
  rm /tmp/kanban_search_test_mod.zig
  ```
  Expected: clean type-check on both targets.

- [ ] Frontend full build + tests:
  ```bash
  cd src/apps/desktop
  timeout 180 bun run build 2>&1 | tail -n 10
  timeout 180 bunx vitest run 2>&1 | tail -n 10
  ```
  Expected: clean type-check + all tests pass (no regressions + 6 new KanbanSearchInput + 6 new KanbanView wiring + ~6 new api/store tests = ~18 new tests).

- [ ] Live smoke against port 8080:
  ```bash
  rm -rf /tmp/nalar-search-smoke && mkdir -p /tmp/nalar-search-smoke
  env -i HOME=/tmp/nalar-search-smoke PATH=$PATH \
    /home/ginwa/ginwaaitoolbox/.worktrees/kanban-task-search/zig-out/bin/nalarcore-linux-x86_64 \
    --port 8080 > /tmp/nalar-search-smoke.log 2>&1 &
  sleep 4

  # Health check
  curl -sS http://127.0.0.1:8080/api/health
  # Expected: status 200

  # Create workspace + kanban with 5 tasks
  WS_ID=$(curl -sS -X POST http://127.0.0.1:8080/api/workspaces \
    -H 'content-type: application/json' -d '{"name":"search-smoke"}' \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  ITEM_RESP=$(curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/kanban" \
    -H 'content-type: application/json' -d '{"name":"Search Board","path":"/tmp"}')
  ITEM_ID=$(echo "$ITEM_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["item"]["id"])')

  # Create 5 tasks with distinct names + descriptions + tags
  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks" \
    -H 'content-type: application/json' \
    -d '{"name":"fix login","description":"","tags":"[]"}' >/dev/null
  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks" \
    -H 'content-type: application/json' \
    -d '{"name":"design page","description":"checkout ui","tags":"[]"}' >/dev/null
  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks" \
    -H 'content-type: application/json' \
    -d '{"name":"random task","description":"irrelevant","tags":"[]"}' >/dev/null
  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks" \
    -H 'content-type: application/json' \
    -d '{"name":"backend api","description":"login flow","tags":"[]"}' >/dev/null
  curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks" \
    -H 'content-type: application/json' \
    -d '{"name":"frontend","description":"","tags":"[\"design\",\"urgent\"]"}' >/dev/null

  # No filter: 5 tasks
  COUNT_ALL=$(curl -sS "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks?limit=100" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d["tasks"]))')
  echo "all=$COUNT_ALL"   # Expected: 5

  # q=login: matches "fix login" (name) and "backend api" (description "login flow")
  COUNT_LOGIN=$(curl -sS "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks?limit=100&q=login" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d["tasks"]))')
  echo "q=login=$COUNT_LOGIN"   # Expected: 2

  # q=design: matches "design page" (name) + "frontend" (tag)
  COUNT_DESIGN=$(curl -sS "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks?limit=100&q=design" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d["tasks"]))')
  echo "q=design=$COUNT_DESIGN"   # Expected: 2

  # q=DESIGN (uppercase): same as above (case-insensitive)
  COUNT_DESIGN_UPPER=$(curl -sS "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks?limit=100&q=DESIGN" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d["tasks"]))')
  echo "q=DESIGN=$COUNT_DESIGN_UPPER"   # Expected: 2

  # q=nonexistent: empty list, has_more=false
  EMPTY=$(curl -sS "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks?limit=100&q=nonexistent_token_xyz" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(f"count={len(d[\"tasks\"])},has_more={d[\"has_more\"]}")')
  echo "q=nonexistent=$EMPTY"   # Expected: count=0,has_more=False

  # q=% (literal wildcard): 0 matches (data has no literal %)
  PCT=$(curl -sS "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks?limit=100&q=%25" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d["tasks"]))')
  echo "q=%=$PCT"   # Expected: 0

  # Smoke teardown
  pkill -f "nalar --port 8080"
  rm -rf /tmp/nalar-search-smoke
  ```
  Expected: `all=5`, `q=login=2`, `q=design=2`, `q=DESIGN=2`, `q=nonexistent=count=0,has_more=False`, `q=%=0`.

- [ ] Update `docs/SPEC.md`:
  - §3.7 (Kanban — currently exists per project memory): append a new subsection **Search**.
  - §10.2.1 (PR index): add a row for the merged PR.

- [ ] Update `AGENTS.md` (root memory): append a "Recent changes" entry under the appropriate date matching the spec's ~303-line size and chunks:
  ```markdown
  ### 2026-07-30: Kanban task search (server-side q param)

  **What landed (per spec 2026-07-30-kanban-task-search-design.md, 8 files / 2 NEW + 6 EDIT):**
  - **Backend:** `GET /api/workspaces/:ws/items/:item/tasks?q=` filters by case-insensitive substring match against `name`, `description`, `tags`. `LIKE ? ESCAPE '\'` + user-input escape of `%`/`_`/`\`. Cursor advances through the filtered set.
  - **Frontend:** `<KanbanSearchInput>` in `KanbanView.vue` header (left of ⚙️ Settings). 300ms debounce → `workspacesStore.fetchKanbanTasks(ws, item, 100, undefined, q)`. SSE handler forwards active q via `activeSearchQueries: Map<itemId, string>`.
  - **Tests:** 14 backend (10 in tasks_list_test.zig + 4 useCase passthrough) + 18 frontend (6 KanbanSearchInput + 6 KanbanView wiring + 6 store/api q-forwarding) = 32 new tests.

  **Why server-side (not frontend .filter):** Kanban loads only the first 100 tasks per page (MAX_PAGE_SIZE). A frontend filter would miss tasks on later pages — defeats the purpose when boards grow past 100 tasks.

  **Pitfalls.** (1) Always escape user input `%` and `_` before LIKE binding (LIKE wildcards). (2) Reset cursor to undefined on every query change — mixing page-1-old-query with page-2-new-query gives inconsistent results. (3) SSE handlers must forward the active q — otherwise a remote task move during a search resets the user's view to the unfiltered set.
  ```

- [ ] Commit:
  ```bash
  git add -A
  git commit -m "docs(kanban): SPEC.md + AGENTS.md updates for task search feature"
  ```

- [ ] Push branch and open PR:
  ```bash
  git push -u origin worktree/kanban-task-search
  ```
  Then open a PR with title: `feat(kanban): server-side task search via ?q= param + header search input`. Description body: paste the spec's Summary section + acceptance criteria checklist.

---

## Pitfalls (read before execution)

- **Don't forget the `%` and `_` escape in user input.** Without it, a user typing `%` matches everything (LIKE wildcard). The `ESCAPE '\'` clause + escaped user input gives literal semantics. See Chunk 1.
- **Don't add the LIKE clause when `q` is null.** When no search is active, the original efficient WHERE on `workspace_item_id` is enough — don't pay the LOWER/COALESCE cost on every row.
- **Don't persist the search query in the URL.** State is component-local. URL persistence is out of scope (D section §5).
- **Don't use `v-else` after a new `v-if` in the KanbanView header.** Each `v-if` is independent — the search input, Set-project-root button, and Settings button all need their own `v-if` (the Set-project-root button already has one — don't chain a `v-else`). See memory `vue-3-v-if-chain-attaches-to-previous-sibling.md`.
- **Don't make the search input collapsE-to-icon for v1.** Keep it always-visible. Icon-collapse adds a click the user doesn't expect.
- **Don't forget the `q` parameter in the SSE handler refetch.** Otherwise, an external `kanban_task.moved` event during a search would re-fetch the unfiltered set, silently resetting the user's narrowed view. Chunk 7 covers this.
- **Don't add highlight-styling inside card titles in v1.** That's an enhancement; the current UX (filter rows out) is enough. See §5 in the spec.
- **The 300ms debounce uses `refDebounced` from `@vueuse/core`.** Verify it exists in `package.json` (project memory `vue-3-virtual-scroller-reactive-scrollability.md` references the project already depending on it). If not, hand-roll with `setTimeout` + `clearTimeout`.
- **`bunx vitest run` does NOT type-check.** Always run `bun run build` BEFORE claiming done on any frontend task (project memory `nalar-frontend-patterns.md` §"`bun run build` is the type-check").
- **Don't commit `.js` files emitted next to `.ts` files** by `vue-tsc --build` (memory `vue-tsc-build-emits-js-files.md`). Delete them before each commit.

## Verification (post-execution)

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/kanban-task-search

# Backend
timeout 180 zig build test --summary all
timeout 180 zig build install:linux:system
rm -rf zig-out/bin && timeout 360 zig build

# Cross-platform
zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc \
  --dep nalarcore -Mroot=/tmp/kanban_search_test_mod.zig -Mnalarcore=src/root.zig
zig build-obj -fno-emit-bin -target aarch64-macos -lc \
  --dep nalarcore -Mroot=/tmp/kanban_search_test_mod.zig -Mnalarcore=src/root.zig

# Frontend
cd src/apps/desktop
timeout 180 bun run build
timeout 180 bunx vitest run
# Cleanup emitted .js files if any: find src -name '*.js' -newer '*.ts' -delete
```

All seven commands must pass. See Chunk 7.2 for the live smoke test against port 8080.
