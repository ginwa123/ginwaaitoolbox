# Plan: Revamp UI Chats — workspace-scoped chats, path-based URLs, lazy workspace items

## Goal
One sentence: make the CHATS list workspace-scoped end-to-end (backend filter + frontend fetch), delete the `+` new-chat button, move the whole app URL to a path-based contract (`/app/{workspace_id}/chat/{session_id}`, `/app/{workspace_id}/projects/{project_id}`), stop loading every workspace's items at boot (load active workspace only, lazily on switch), and turn `/app` into a landing page whose job is creating a workspace.

Non-goals (v1): no schema migration / no `sessions.workspace_id` backfill (resolver reuse is enough); no workspace SSE events; no change to kanban-settings path route (`/app/kanban/:itemId/settings` stays); no drag-reorder UI; no vector/FTS search changes; no tab-mode redesign beyond URL-shape migration.

## Decision log
- 2026-09-22 (user): CHATS are **not global** — fetch chats per workspace.
- 2026-09-22 (user): **remove the `+` add-chat button** (both expanded header and collapsed variants).
- 2026-09-22 (user): URL becomes path-based — sidebar chat click → `app/{workspace_id}/chat/{session_id}`; project click → `app/{workspace_id}/projects/{project_id}/`. (Supersedes the earlier `app/{workspace_id}?session=…` draft.)
- 2026-09-22 (user): do **not** load all workspace items for different workspaces at boot — per-workspace lazy loading.
- 2026-09-22 (user): `/app` is the **landing** and it should create a workspace.

## Background (what exists today)

### Session list is global
- Handler `GET /api/llm/session` → `sessionListHandler` (`src/main.zig:513`, `src/http_handlers/session_list.zig`). Params: `limit/cursor/cwd/sort_by/direction` — **no workspace param anywhere** (repo-wide `req.query.get("workspace_id")` = 0 hits).
- Query `getSessionListWithCursor` (`src/agentic_loop/llm_history.zig:222-343`): WHERE = `s.id NOT LIKE '%subagent%'` [+ exact `cwd`] [+ cursor], **zero bind params** (everything interpolated), count query at `:325-329` mirrors it.
- `sessions.workspace_id` exists (Migration 025, `migration.zig:429-434`) but is **always NULL**: 4 production INSERTs never write it (`llm_history.zig:1323,3387`, `session_create.zig:356`, `task_create.zig:567`), no UPDATE/SELECT reads it, no backfill exists.
- Real linkage already implemented + tested: `src/agentic_loop/workspace_scope.zig` —
  `resolveWorkspaceId` (`:20`, task-link join then cwd longest-prefix, fail-closed) and
  `workspaceSessionIds` (`:75`, task-linked ∪ cwd-matched; empty id → empty list). Consumed today only by the `read_workspace_session` agent tool.
- Perf caveat: `workspaceSessionIds`'s cwd fallback loops every session row (`:104-121`) — O(all sessions) queries per call. Acceptable for v1 (same cost as the agent tool's LIST); the `sessions.workspace_id` backfill is the future fix.

### Frontend CHATS
- `src/apps/desktop/src/components/views/ChatsList.vue` — `loadChats()` `:248` calls `api.getChats('updated_at', dir, 30)` with **no workspace filter**; `loadMoreChats()` `:331` same. Header `+` button `:634-642` (`chats-new-chat-button`), collapsed `+` `:769-776` (`collapsed-new-chat-button`), `createChat()` `:372-384` mints a synthetic `session-${Date.now()}` id.
- API client `getChats` (`src/apps/desktop/src/api/index.ts:1673-1756`): `sort_by/direction/limit/cursor` only.
- Only tests touching `createChat`: `__tests__/sidebarActiveState.spec.ts:121-131,192-200`. No test asserts either `+` testid.
- Dead legacy loaders still calling `getChats`: `Sidebar.vue:235-287` (`_loadChats`/`_loadMoreChats`, never invoked) — delete.

### URL contract today (query-based, single route `/app`)
- `?view=chat&session=X` | `?view=workspace&workspaceId=X[&itemId=Y][/chat/T][&pageId=Z][&detail=…][&sorts=…]`; kanban settings path route; legacy `?view=task` boot-rewrite precedent (`useCurrentMainView.ts:15-18`, `AppLayout.vue` onMounted).
- Derived by `composables/useCurrentMainView.ts` (`:66-121`); URL-sync watcher builds query objects at `AppLayout.vue:403-456`; workspace switch = `router.push` (`AppLayout.vue:635-645`), chat click = `router.replace` (`ChatsList.vue:421`).
- URL builder helpers: `buildTaskUrlQuery.ts:121` (always emits `view:'workspace'`), `openInNewTab`, `tabTarget.ts:339`, `tabs.ts:487`. ~193 matches for `view: 'chat'|'workspace'` across src+specs — **largest churn surface**.

### Workspace items load eagerly for every workspace
- `stores/workspaces.ts init()` `:742-975`: `api.getWorkspaces()` (already `is_include_items=false`, `api/index.ts:534-538`) then `Promise.all` over **all** workspaces → `getWorkspacesItems(ws.id)` + per-item `getTasks` + eager design-pages (`:768-830`).
- Consumers assuming all items present: `allWorkspaceItems` (`:978`), `activeWorkspaceItem` (`:983`), `WorkspaceSwitcher.vue:235` item-count badge, `Sidebar.vue:684`.
- Backend already supports skipping items: `workspaces_list.zig:31-33` (`is_include_items=false` → `items: []`).

### Landing
- `components/views/Chats.vue` is deliberately inert (no buttons) — guarded by `ChatsLanding.spec.ts`. Workspace creation exists: `workspaces.ts:1151 addWorkspace` → `api.createWorkspace` (`api/index.ts:549`), UI wired in `Sidebar.vue:713-716` + `WorkspaceSwitcher` emit.

## Proposal

### 1. Backend — workspace-scoped session list (wire change → functional test MANDATORY)
1. `session_list.zig`: accept optional `workspace_id` query param. When present:
   - resolve `workspace_scope.workspaceSessionIds(allocator, db, workspace_id)` (empty/unknown workspace → empty id set),
   - pass the id set into `getSessionListWithCursor` as a new `workspace_ids: ?[]const []const u8` param;
     - non-empty → `AND s.id IN (…)` with **proper binds** (stop extending the zero-bind interpolation for this filter),
     - empty set → `AND 1 = 0` (never emit `IN ()` — syntax error; also never bind `""` into a NOT NULL column, PR #291 trap),
   - apply the same predicate to the COUNT query so `total`/pagination stay truthful.
   - Param absent → today's global behavior (back-compat for `sessions_and_llm_test.py`, `session_wire_test.py`, dead Sidebar loaders).
2. Session detail: expose resolved `workspace_id` on `GET /api/llm/session/:session_id` (via `resolveWorkspaceId`, `null` when unresolvable) so legacy URL rewrites and any sid→workspace lookup work client-side without scanning the tree.
3. Tests (same-file Zig): in-memory SQLite — task-linked session included; cwd-matched plain chat included; cross-workspace session excluded; unknown workspace → 0 sessions + `total: 0`; absent param → unchanged global result; static-contract grep for the `workspace_id` param name.
4. Functional (MANDATORY — wire round-trip, port ≠ 8081): new `tests/functional/session_list_workspace_test.py` using `harness.py`:
   - seed workspace A (2 task sessions via `mode=create_session` + 1 plain session with cwd under A's item path) and workspace B (1 task session);
   - `GET /api/llm/session?workspace_id=A` → only A's sessions (**leak test**: B's id absent, plain chat present);
   - `workspace_id=B` → only B's; unknown `workspace_id=nope` → `sessions: []`, `total: 0`;
   - absent → global (back-compat guard).

### 2. Frontend CHATS — scoped fetch + remove `+`
1. `api.getChats(sort, dir, limit, cursor?, workspaceId?)` → appends `workspace_id` when set.
2. `ChatsList.vue`:
   - workspace id source: URL path workspace when present, else `workspacesStore.activeWorkspace?.id` (fallback chain keeps `/app` landing sane);
   - `loadChats`/`loadMoreChats` pass it; a `watch` on the workspace id resets cursor/navItems and refetches (workspace switch must not show the old workspace's chats, even for one frame — clear `navItems` first);
   - SSE session-event reload keeps working (scoped automatically because the fetch is scoped).
3. Delete `createChat()` + both `+` buttons + the collapsed-only `+` block (collapsed sidebar renders no chats affordance); update the header comment that documents the `+` control; update `DEFAULT_CHAT_TOOLS` comment (`api/index.ts:1481`).
4. New-chat creation now happens only through workspace items (kanban `mode=create_session`, agent-item direct chat `Sidebar.agentDirectChat`, standard-task chat) — all task-linked, therefore all workspace-scoped. Chats created before a workspace existed remain visible only when their cwd resolves into a workspace (fail-closed otherwise: hidden, still deep-linkable by id).
5. Specs: rewrite the two `createChat` cases in `sidebarActiveState.spec.ts` (assert the `+` is gone + row-click clearing still works); new `ChatsList.workspaceScoped.spec.ts` — `getChats` called with the active workspace id, refetch on switch, param omitted when no workspace; existing ChatsList/AppLayout specs keep their `getChats` mocks (signature is backward-compatible).

### 3. URL contract — path-based (biggest surface; do behind one helper)
Routes (vue-router, order matters — specific before `/app/:workspaceId`):

| State | New URL |
|---|---|
| Landing / create workspace | `/app` |
| Workspace selected | `/app/{workspace_id}` |
| Chat open | `/app/{workspace_id}/chat/{session_id}` |
| Project (workspace item) open | `/app/{workspace_id}/projects/{project_id}` (+ query sub-state `?pageId=…&detail=…&sorts=…&panel=…`) |
| Task chat dialog over a project | `/app/{workspace_id}/projects/{project_id}/chat/{task_id}` (path suffix, mirrors today's `itemId/chat/T`; NOT `?chat=`) |
| Settings / kanban settings | unchanged (`/app/settings`, `/app/kanban/:itemId/settings`) |
| Legacy | `/app/chat/:sid`, `/app/task/:tid`, `?view=…` → one-time boot `router.replace` rewrite (same precedent as the `?view=task` rewrite) |

Implementation:
1. NEW helper `src/apps/desktop/src/helpers/appUrl.ts`: **single** builder `buildAppUrl({workspaceId, chat?, project?, chatTask?, query?})` + parser. Every navigation goes through it — no scattered string concat.
2. `useCurrentMainView.ts`: derive kinds from **path params**: `chat {workspaceId, sessionId}` | `workspace {workspaceId}` | `project {workspaceId, projectId, pageId?, chatTaskId?}` | `kanban-settings` | `none`. Row-highlight consumers updated (`ChatsList.isCurrentChat`, `ProjectsList`, `DesignPageRow`, task rows).
3. `AppLayout.vue`: URL-sync watcher emits paths instead of query objects; workspace switch stays `router.push` (Back/Forward crosses switches — deliberate, per 2026-09-22 dropdown plan), chat click stays `router.replace`. Unknown `/app/{workspace_id}` → `router.replace('/app')`.
4. Rewrite call sites file-by-file: `ChatsList` (`setActive`/`openChatInNewTab`/`removeChat`), `Sidebar.handleChatsNavigate`/`handleSelectTask` (`Sidebar.vue:355,412`), `buildTaskUrlQuery` → returns `{path, query}`, `openInNewTab`, `tabTarget.ts`, `tabs.ts` tab identity (tab query becomes the full path — audit `App.spec.ts`, `tabsStore.spec.ts`).
5. Legacy rewrite needs sid→workspace: session detail `workspace_id` (§1.2). Unresolvable → land on `/app` (fail-closed), never render a chat under the wrong workspace path.
6. Trailing slash: canonicalize **without** trailing slash (`/app/X/projects/Y`); the router accepts `/…/` and replaces it away.

### 4. Lazy workspace items — active workspace only
1. `init()`: fetch workspace list + **only the active workspace's** items/tasks/design-pages. Active id source: URL path workspace → store `activeWorkspaceId` → persisted choice → `workspaces[0]`.
2. NEW `ensureWorkspaceItemsLoaded(workspaceId)` (idempotent, in-flight dedupe, `Set` of loaded ids) called on: workspace switch (`setActiveWorkspace`), URL restore, workspace expand. Items of other workspaces stay `[]` until visited.
3. URL restore ordering: `await ensureWorkspaceItemsLoaded(ws)` **before** `setActiveWorkspaceItem(itemId)` (else `activeWorkspaceItem` misses and the row/item render breaks).
4. `WorkspaceSwitcher` count badge: add lightweight `items_count` to `GET /api/workspaces` (one `GROUP BY` count, works with `is_include_items=false`) so the badge doesn't regress to 0 for unvisited workspaces.
5. Audit every `allWorkspaceItems`/`ws.items` consumer for "not loaded yet" (`allWorkspaceItems:978`, `activeWorkspaceItem:983`, `Sidebar.vue:684`, SSE tree-mutation handlers in `installSessionEventHandlers`) — mutations targeting a non-loaded workspace must no-op safely, never throw.
6. Specs: store spec — init fires items fetch for active workspace only; switching triggers exactly one `ensureWorkspaceItemsLoaded`; design-pages/per-item tasks follow the same gate.

### 5. `/app` landing — creates a workspace
1. `Chats.vue` gains a primary **Create workspace** action (name input → `workspacesStore.addWorkspace` → `router.push('/app/{new_id}')`), plus an optional compact list of existing workspaces to jump into. Still no composer/messages/chat list.
2. Amend `ChatsLanding.spec.ts` scope guards deliberately: the create-workspace control is now ALLOWED; composer/assistant-message/list guards stay.
3. `/app` remains reachable as landing even when workspaces exist (user decision); sidebar (chats scoped + projects) renders beside it using the store's active-workspace fallback.

## Verification (no live-server curl — harnesses only)
- **Zig**: `session_list` workspace-filter tests (in-file, in-memory SQLite: include/exclude/empty/absent) + `workspace_scope` tests already green.
- **Functional (wire)**: `tests/functional/session_list_workspace_test.py` (leak test is the point) on a free port 8080–8199, NEVER 8081; re-run `sessions_and_llm_test.py` (back-compat: absent param unchanged).
- **Frontend**: new/updated specs (workspace-scoped fetch, no-`+`, path URL parse/rewrite, lazy store, landing create-workspace); then full `pnpm test`, `pnpm run lint`, `pnpm run type-check`.
- **Whole**: `zig build test`.
- Static checks: `rg "chats-new-chat-button|collapsed-new-chat-button|createChat"` → only removal records; `rg "view: 'chat'|view: 'workspace'"` → only in legacy-rewrite code + historical docs.

## Risks / open questions
1. **Spec churn is the risk** (~193 `view:` matches): mitigated by routing every navigation through `appUrl.ts` and migrating specs alongside their components, not in one big-bang pass.
2. `workspaceSessionIds` O(all sessions) per list fetch — accepted v1; follow-up = `sessions.workspace_id` backfill + creator fix (already specced in `2026-09-15-workspace-scoped-chat-history.md` §Backend step 2).
3. Empty workspace id-set must emit `1 = 0`, never `IN ()` / `""`-as-NULL.
4. Tabs/background-open identity changes shape (path+query) — audit `tabs.ts`/`App.spec.ts` carefully.
5. Unresolvable session workspace (legacy plain chats outside every workspace path): hidden from lists, boot-rewrite fails closed to `/app` — confirm acceptable.
6. Confirm task-chat path suffix form (`…/projects/{pid}/chat/{tid}`) — recommended default, mirrors today's suffix.
7. Removing `+` removes the last way to mint a *plain* (non-task) chat — new chats come only from workspace items. Confirm intended (decision log says yes).

## Steps (execution order)
- [ ] 1. Backend: `workspace_id` param on `GET /api/llm/session` (+ session-detail `workspace_id`) + in-file Zig tests
- [ ] 2. Functional `session_list_workspace_test.py` (leak test) + back-compat re-run — wire green before frontend
- [ ] 3. Frontend CHATS: `getChats` workspaceId, ChatsList scoped fetch + switch refetch, delete `+`/`createChat`, fix specs
- [ ] 4. URL helper `appUrl.ts` + `useCurrentMainView` path kinds + AppLayout sync/rewrite + call-site migration (components → helpers → tabs)
- [ ] 5. Lazy items: `init` active-only + `ensureWorkspaceItemsLoaded` + `items_count` badge + consumer/SSE audit + specs
- [ ] 6. `/app` landing create-workspace + `ChatsLanding.spec.ts` amendment
- [ ] 7. Docs: this plan ticks, `docs/SPEC.md` URL/session-list rows, superseded mentions in `2026-09-22-revamp-workspace-ui-dropdown-projects.md` ("CHATS stay global" non-goal now done)
- [ ] 8. Full verification (`zig build test`, `pnpm test`, lint, type-check, functional suite)
- [ ] 9. Commit + PR from this worktree → human review (`in_review_task`)

## Files to touch (expected)
- EDIT backend: `src/http_handlers/session_list.zig`, `src/agentic_loop/llm_history.zig` (`getSessionListWithCursor` + count), session-detail handler (add `workspace_id`), `src/http_handlers/workspaces_list.zig` (`items_count`), `tests/functional/session_list_workspace_test.py` (NEW)
- EDIT frontend API/stores: `api/index.ts` (`getChats`, `getWorkspaces`), `stores/workspaces.ts` (lazy init, ensureLoaded, addWorkspace nav)
- EDIT frontend views: `ChatsList.vue`, `Chats.vue`, `AppLayout.vue`, `Sidebar.vue`, `ProjectsList.vue`, `DesignPageRow.vue` (+ task-row consumers)
- EDIT frontend routing/helpers: `router/index.ts`, `composables/useCurrentMainView.ts`, NEW `helpers/appUrl.ts`, `helpers/buildTaskUrlQuery.ts`, `helpers/openInNewTab.ts`, `helpers/tabTarget.ts`, `stores/tabs.ts`
- EDIT specs: `sidebarActiveState.spec.ts`, ChatsList specs, AppLayout specs, `useCurrentMainView.spec.ts`, `buildTaskUrlQuery.spec.ts`, `ChatsLanding.spec.ts`, `App.spec.ts`/`tabsStore.spec.ts`, workspace store specs
- DELETE (code): ChatsList `createChat` + `+` buttons; Sidebar dead `_loadChats`/`_loadMoreChats`
