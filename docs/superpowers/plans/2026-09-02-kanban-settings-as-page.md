# Kanban Settings: Centered Modal → Dedicated Page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `KanbanSettingsDialog` (the centered modal that pops up when the user clicks ⚙ on a kanban board header) with a dedicated full-page route that occupies the entire main content area — the same shape as `SettingsView` (sidebar tabs on the left, content panel on the right). The URL becomes the source of truth: clicking ⚙ pushes a vue-router **path** route (`/app/kanban/:itemId/settings`), the page reads the kanban from the URL on mount, the **← Back** button navigates back to the kanban board. Reload preserves the page (no in-memory flag drift).

**Architecture:** New component `KanbanSettingsView.vue` is mounted at the AppLayout level as a sibling of `<KanbanView>` and `<SettingsView>`, gated on a new `currentView === 'kanban-settings'` branch (mirrors the `settings` branch at AppLayout:2676). The component owns its own column-management UI (lifted from `KanbanSettingsDialog`'s columns tab) + the Local Memories tab + the Copy Spec footer + the inline per-row `KanbanColumnEditor` (rename / delete). All HTTP work routes through `workspacesStore` actions unchanged — `KanbanSettingsView` is purely presentational, same contract as the old dialog.

The URL is a **vue-router path route** (matching the established convention for sibling sub-pages: `/app/settings`, `/app/chat/:sessionId`, `/app/task/:taskId`):

```
/app/kanban/:itemId/settings
```

The router gains one new entry that resolves to `AppLayout` (the existing pattern — all sub-page routes resolve to AppLayout, which dispatches via the `currentView` computed). `useCurrentMainView` gains a `{ kind: 'kanban-settings', workspaceId, itemId }` variant that parses `route.path` for the itemId (path param) + reads `route.query.workspaceId` (optional, for the back navigation). The kanban's owning workspaceId is **derived from the store** by walking `workspacesStore.workspaces` looking for the matching item — no need to encode it in the URL (itemId is globally unique across all workspaces).

The existing `<CopyKanbanSpecDialog>` and the AppLayout-level `<KanbanColumnEditor>` stay as siblings — the new view emits the same `copySpec` / `requestRenameColumn` / `requestDeleteColumn` events the dialog used to, and AppLayout keeps owning those modals.

**Tech Stack:** Vue 3 (Composition API + `<script setup>`), TypeScript, Pinia, `@vue/test-utils` + Vitest, `node vue-tsc --build` for type-check. No backend changes, no migration, no Zig changes. The kanban column / memory / spec HTTP routes are unchanged.

**Worktree:** `/home/ginwa/ginwaaitoolbox/.worktrees/kanban-settings-page` on branch `worktree/kanban-settings-page`.

---

## Global Constraints

- **Cross-platform**: every feature MUST work on Linux, macOS, AND Windows. Verify with `zig build-obj -fno-emit-bin -target x86_64-windows-gnu -lc ...` and `... -target aarch64-macos -lc ...` at the end of the plan.
- **No static-contract tests**: ALL tests are behavioural. No `expect(source).toContain(...)` / `indexOf(u8, source, ...)` patterns anywhere.
- **No port 8081**: smoke tests use port 8080.
- **Behavioural Vue tests use `@vue/test-utils` `mount` with `setActivePinia(createPinia())`** in `beforeEach`. Mock `useRoute` / `useRouter` via `vi.mock('vue-router', ...)` (mirror `useCurrentMainView.spec.ts`).
- **TDD discipline**: every implementation task starts with a failing test, then minimal code to make it pass, then a commit.
- **Teleport-based dialog tests** must use `attachTo: document.body` and `document.querySelector(...)` for DOM assertions (not `wrapper.find(...)` for teleported content). See `.pabrik/skills/vue-teleport-vitest-document-queryselector/SKILL.MD`.
- **Pure architectural relocation**: no UX changes beyond the dialog → page conversion. The columns UI, memories tab, copy-spec footer, and rename/delete flows are byte-identical in content (just inside a full-page layout instead of a centered modal).
- **URL is source of truth**: every read goes through `useRoute().query`; every write goes through `router.replace`. No `ref(false)` open/close flags.

---

## File map

| File | Action | Why |
|---|---|---|
| `src/apps/desktop/src/components/views/KanbanSettingsView.vue` | NEW | Full-page kanban settings (columns tab + memories tab + copy spec + per-row editor) |
| `src/apps/desktop/src/composables/useCurrentMainView.ts` | EDIT | Add `kind: 'kanban-settings'` variant that parses `route.path` (path param) + `route.query.workspaceId` |
| `src/apps/desktop/src/composables/useCurrentMainView.spec.ts` | EDIT | Update mock helper to include `path` + `params`; add 4 tests for the new variant |
| `src/apps/desktop/src/router/index.ts` | EDIT | Add `/app/kanban/:itemId/settings` path route resolving to `AppLayout` |
| `src/apps/desktop/src/components/AppLayout.vue` | EDIT | `currentView` recognizes the new path; `handleOpenKanbanSettings` uses `router.push` with the path; mount `<KanbanSettingsView>` branch; remove `showKanbanSettingsDialog` ref + `<KanbanSettingsDialog>` mount |
| `src/apps/desktop/src/components/workspace/WorkspaceItem.vue` | EDIT | Extend `isCurrentMainView` computed to also match `kind === 'kanban-settings'` (so the parent kanban row stays highlighted in the sidebar when the user is on its settings page) |
| `src/apps/desktop/src/components/kanban/KanbanSettingsDialog.vue` | DELETE | Replaced by `KanbanSettingsView` |
| `src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts` | DELETE | Replaced by `KanbanSettingsView.spec.ts` |
| `src/apps/desktop/src/__tests__/KanbanSettingsView.spec.ts` | NEW | Behavioural tests for the new page (header, back button, columns tab, memories tab, copy-spec footer, path-driven mount) |
| `docs/SPEC.md` | EDIT | Add §10.2.1 PR index row; update Kanban layout §3.7 entry |
| `PABRIK.md` | EDIT | Append "### 2026-09-02: kanban settings as dedicated page" changelog entry |

Total: **11 files** (2 NEW, 5 EDIT, 2 DELETE, 2 doc). No backend changes, no migration, no Zig changes.

---

## Task 1: Extend `useCurrentMainView` URL contract (TDD)

**Why:** The composable is the single source of truth for "what is the main content area showing?". The sidebar marks the active row by matching this kind — if we don't add a `kanban-settings` variant, the kanban row in the sidebar won't be highlighted when the user is on the settings page. Build it test-first so the URL contract is locked before any component work.

**Files:**
- `src/apps/desktop/src/composables/useCurrentMainView.spec.ts` — EDIT
- `src/apps/desktop/src/composables/useCurrentMainView.ts` — EDIT

### Step 1.1: Add failing tests + update the mock helper

In `useCurrentMainView.spec.ts`, FIRST update the `mockRoute` helper (line 15-22) to accept a `path` + `params` (the existing 8 tests pass `path: '/app'` already, so the change is backward compatible — just thread `params` through):

```ts
function mockRoute(query: Record<string, string>, path = '/app', params: Record<string, string> = {}) {
  // `reactive` so post-mount mutations trigger the computed.
  const obj = reactive({ query, path, params, fullPath: path + (Object.keys(query).length ? '?' + new URLSearchParams(query).toString() : '') })
  useRouteMock.mockReturnValue(obj as any)
  return obj
}
```

Then append FOUR new tests inside `describe('useCurrentMainView', ...)` (the kanban-settings URL is now a vue-router **path** route, NOT a query param):

```ts
it('returns kanban-settings view when URL is /app/kanban/:itemId/settings', () => {
  mockRoute({}, '/app/kanban/item_kanban/settings', { itemId: 'item_kanban' })
  let v!: ReturnType<typeof useCurrentMainView>
  function setup() { v = useCurrentMainView() }
  setup()
  expect(v.value).toEqual({
    kind: 'kanban-settings',
    workspaceId: undefined,
    itemId: 'item_kanban',
  })
})

it('returns kanban-settings view with workspaceId when ?workspaceId=X is on the path', () => {
  mockRoute({ workspaceId: 'ws_1' }, '/app/kanban/item_kanban/settings', { itemId: 'item_kanban' })
  let v!: ReturnType<typeof useCurrentMainView>
  function setup() { v = useCurrentMainView() }
  setup()
  expect(v.value).toEqual({
    kind: 'kanban-settings',
    workspaceId: 'ws_1',
    itemId: 'item_kanban',
  })
})

it('returns kanban-settings view with empty itemId when the path lacks :itemId (defensive)', () => {
  // Path is /app/kanban//settings (double slash) — Vue Router would
  // normally reject this, but we want the composable to degrade
  // gracefully so the sidebar can still react.
  mockRoute({}, '/app/kanban//settings', { itemId: '' })
  let v!: ReturnType<typeof useCurrentMainView>
  function setup() { v = useCurrentMainView() }
  setup()
  expect(v.value.kind).toBe('kanban-settings')
  expect(v.value).toEqual({
    kind: 'kanban-settings',
    workspaceId: undefined,
    itemId: '',
  })
})

it('reacts to URL changes for kanban-settings (computed re-runs when route.path mutates)', async () => {
  const route = mockRoute({}, '/app', {})
  let v!: ReturnType<typeof useCurrentMainView>
  function setup() { v = useCurrentMainView() }
  setup()
  expect(v.value).toEqual({ kind: 'none' })
  // Simulate vue-router's navigation — both path and params update.
  route.path = '/app/kanban/item_now/settings'
  route.params = { itemId: 'item_now' }
  await nextTick()
  expect(v.value).toEqual({
    kind: 'kanban-settings',
    workspaceId: undefined,
    itemId: 'item_now',
  })
})
```

Run `npm run test:unit -- useCurrentMainView.spec.ts`. The four new tests FAIL (no `kanban-settings` branch in the computed yet). The existing 8 tests still pass — they don't reference the new variant.

### Step 1.2: Add the `kanban-settings` variant to the computed

In `useCurrentMainView.ts`:

1. Extend the `CurrentMainView` union (line 28-37) with the new variant. Place it BEFORE the `{ kind: 'none' }` member for clarity:

```ts
export type CurrentMainView =
  | { kind: 'chat'; sessionId: string }
  | {
      kind: 'workspace'
      workspaceId?: string
      itemId: string
      pageId?: string
      chatTaskId?: string
    }
  | {
      kind: 'kanban-settings'
      workspaceId?: string
      itemId: string
    }
  | { kind: 'none' }
```

2. Add the branch to the computed (insert AFTER the `view === 'workspace'` branch at line 70, BEFORE the `return { kind: 'none' }` fallthrough). The URL is a **path route** (`/app/kanban/:itemId/settings`), so we parse the path with a regex AND read `workspaceId` from query (optional, used by the back navigation):

```ts
// Kanban settings page (path route /app/kanban/:itemId/settings).
// itemId comes from route.params (path); workspaceId is optional
// and comes from ?workspaceId=X query (used by the back navigation
// to round-trip back to ?view=workspace&workspaceId=X&itemId=Y).
// itemId may be empty if Vue Router matched a malformed URL — we
// return the empty string so the page can render a friendly hint
// instead of crashing.
const kanbanSettingsMatch = /^\/app\/kanban\/([^/]+)\/settings\/?$/.exec(
  route?.path ?? '',
)
if (kanbanSettingsMatch) {
  return {
    kind: 'kanban-settings',
    workspaceId:
      typeof q.workspaceId === 'string' && q.workspaceId.length > 0
        ? q.workspaceId
        : undefined,
    itemId: kanbanSettingsMatch[1] ?? '',
  }
}
```

Run `npm run test:unit -- useCurrentMainView.spec.ts`. All 12 tests pass.

### Step 1.2.5: Add a guard test for a non-matching path

The 4 new tests cover the happy path + the URL param combinations. Add ONE more defensive test — confirm the regex doesn't match other `/app/...` paths (so we don't accidentally hijack `/app/settings` or `/app/chat/:id`):

```ts
it('does NOT match kanban-settings for unrelated paths like /app/settings', () => {
  mockRoute({}, '/app/settings', {})
  let v!: ReturnType<typeof useCurrentMainView>
  function setup() { v = useCurrentMainView() }
  setup()
  // /app/settings is its own view — the composable's chat/workspace
  // branches don't match it either, so it falls through to 'none'.
  expect(v.value).toEqual({ kind: 'none' })
})
```

Run `npm run test:unit -- useCurrentMainView.spec.ts`. All 13 tests pass.

### Step 1.3: Commit

```
feat: extend URL contract with kind=kanban-settings variant
```

---

## Task 1.5: Add the `/app/kanban/:itemId/settings` route to `router/index.ts`

**Why:** Before the page can be navigated to, vue-router needs to know about the path. Add the new route entry — it resolves to `AppLayout` (same as the other sub-page routes: `/app/settings`, `/app/chat/:sessionId`, `/app/task/:taskId`).

**Files:**
- `src/apps/desktop/src/router/index.ts` — EDIT

### Step 1.5.1: Add the route entry

In `router/index.ts` (line 1-34), append a new entry AFTER the existing `/app/task/:taskId` route:

```ts
{
  // Kanban settings page (plan: 2026-09-02-kanban-settings-as-page).
  // Resolves to AppLayout which dispatches via the `currentView`
  // computed (path-based regex match at AppLayout.vue line ~890).
  // The `name` is informational — we navigate by path from
  // AppLayout.handleOpenKanbanSettings via `router.push`.
  path: '/app/kanban/:itemId/settings',
  name: 'kanban-settings',
  component: AppLayout,
},
```

### Step 1.5.2: Verify the route resolves

Boot the dev server (`npm run dev`) and manually navigate to `http://localhost:5173/app/kanban/wi_test/settings` — the page should render AppLayout (which shows an empty state because `wi_test` isn't a real item). The URL bar should show the full path. If vue-router throws a warning about the route, double-check the syntax.

### Step 1.5.3: Commit

```
feat: add /app/kanban/:itemId/settings route
```

---

## Task 2: Build `KanbanSettingsView.vue` (TDD)

**Why:** The page component is the centrepiece of the change. Build it test-first so the URL-driven mount + back navigation + tab strip + columns / memories / copy-spec flows are all locked before wiring it into AppLayout.

**Files:**
- `src/apps/desktop/src/components/views/KanbanSettingsView.vue` — NEW
- `src/apps/desktop/src/__tests__/KanbanSettingsView.spec.ts` — NEW

### Step 2.1: Write the failing tests

Create `src/apps/desktop/src/__tests__/KanbanSettingsView.spec.ts` with TWELVE behavioural tests. Mirror the mock pattern from `useCurrentMainView.spec.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { reactive } from 'vue'

import KanbanSettingsView from '@/components/views/KanbanSettingsView.vue'
import type { WorkspaceItem } from '@/stores/workspaces'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
  useRouterMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: useRouteMock,
    useRouter: useRouterMock,
  }
})

const baseItem: WorkspaceItem = {
  id: 'wi_test',
  name: 'Sprint 12',
  item_type: 'kanban',
  path: null,
  kanban_columns: [
    {
      id: 'col_a',
      workspace_item_id: 'wi_test',
      name: 'todo',
      description: 'Not started',
      position: 0,
      created_at: '2026-06-26T10:00:00Z',
    },
    {
      id: 'col_b',
      workspace_item_id: 'wi_test',
      name: 'done',
      description: '',
      position: 1,
      created_at: '2026-06-26T10:00:00Z',
    },
  ],
}

function setupRoute(query: Record<string, string>) {
  const obj = reactive({ query, path: '/app', fullPath: '/app' })
  useRouteMock.mockReturnValue(obj as any)
  const push = vi.fn()
  const replace = vi.fn()
  const back = vi.fn()
  useRouterMock.mockReturnValue({ push, replace, back, currentRoute: obj } as any)
  return { route: obj, router: { push, replace, back } }
}

describe('KanbanSettingsView', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    // Seed the workspaces store with one kanban so the page can
    // resolve itemId → WorkspaceItem via workspacesStore.
    const { useWorkspacesStore } = await import('@/stores/workspaces')
    // ... store seed below
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.innerHTML = ''
  })

  // ... tests below
})
```

(Full spec for the 12 tests in Task 2.2 below — write each as a separate `it(...)` block.)

### Step 2.2: Test list (write all 12 before implementation)

1. **`renders the kanban name in the header`** — given `useRoute` returns `path: '/app/kanban/wi_test/settings'` with `params.itemId = 'wi_test'`, and the store has a kanban `wi_test` named "Sprint 12", the rendered header text contains "Sprint 12".
2. **`renders one row per column sorted by position`** — the test data has `col_a` (position 0) and `col_b` (position 1); assert the rendered rows appear in that order via `[data-testid^="kanban-settings-page-column-row-"]`.
3. **`adds a column via the inline form`** — type into `[data-testid="kanban-settings-page-add-name"]`, click `[data-testid="kanban-settings-page-add-submit"]`, assert `wrapper.emitted('addColumn')` equals `[['Review', '']]`.
4. **`deletes a column via the per-row Delete button`** — click `[data-testid="kanban-settings-page-delete-col_a"]`, assert `wrapper.emitted('deleteColumn')` equals `[['col_a']]`.
5. **`renames the kanban via the inline pencil`** — click the rename display, type "Sprint 13", click save, assert `wrapper.emitted('renameItem')` equals `[['Sprint 13']]`.
6. **`copies spec via the footer button`** — click `[data-testid="kanban-settings-page-copy-spec"]`, assert `wrapper.emitted('copySpec')` is non-empty.
7. **`navigates back to the kanban board on the Back button`** — given the store has the kanban in workspace `ws_1`, click `[data-testid="kanban-settings-page-back"]`, assert `router.replace` was called with `{ path: '/app', query: { view: 'workspace', workspaceId: 'ws_1', itemId: 'wi_test' } }`. The workspaceId is derived from the store by looking up which workspace owns the item (NOT from the URL).
8. **`shows the Local Memories tab when the kanban has a path`** — set `path: '/tmp/some-folder'` on the kanban, assert `[data-testid="kanban-settings-page-tab-memories"]` exists.
9. **`hides the Local Memories tab when the kanban has no path`** — `path: null` (default), assert the tab is absent.
10. **`switches to the Local Memories tab on click`** — given the kanban has a path, click the memories tab, assert `[data-testid="kanban-settings-page-memories-panel"]` renders and the columns tab content unmounts.
11. **`shows a "no kanban selected" hint when the URL itemId is empty`** — set `params.itemId = ''`, assert the page renders `[data-testid="kanban-settings-page-no-item"]` with a friendly message instead of the columns UI.
12. **`falls back to the kanban view if itemId is missing from the store`** — set the URL to a non-existent itemId, assert the page renders `[data-testid="kanban-settings-page-not-found"]` with a friendly message.

Run `npm run test:unit -- KanbanSettingsView.spec.ts`. All 12 tests FAIL (no component yet).

### Step 2.3: Implement `KanbanSettingsView.vue`

Create the component at `src/apps/desktop/src/components/views/KanbanSettingsView.vue`. Structure (top → bottom):

1. **Imports** — `useRoute` / `useRouter` from `vue-router`; `KanbanColumnEditor` from `../kanban/KanbanColumnEditor.vue`; `InlineEditableText` from `../preview/InlineEditableText.vue`; `WorkspaceItemMemoriesView` from `./WorkspaceItemMemoriesView.vue`; `useWorkspacesStore` from `../../stores/workspaces`.

2. **Props** — none (the component reads everything from `useRoute()` — itemId from `route.params`, optional workspaceId from `route.query`).

3. **Emits** — verbatim from the old dialog:
   - `close: []` — not used by the page itself (the page navigates back via the router), but kept for backward compat with any future host that wants to embed the page.
   - `addColumn: [name: string, description: string]`
   - `editColumn: [{ columnId: string; name: string; description: string }]`
   - `deleteColumn: [columnId: string]`
   - `renameItem: [name: string]`
   - `copySpec: []`
   - `requestRenameColumn: [columnId: string]` — forwarded to host (AppLayout opens `KanbanColumnEditor` rename mode)
   - `requestDeleteColumn: [columnId: string]` — same for delete

4. **Refs** — `settingsMode: 'columns' | 'memories'` (default `'columns'`); the rename/delete editor state (`showSettingsEditor`, `settingsEditorMode`, `settingsEditorTargetId`, `settingsEditorTargetName`, `settingsEditorTargetDescription`).

5. **Computed**:
   - `itemId` — `route.params.itemId as string` (path param, may be empty).
   - `item` — looks up the kanban `WorkspaceItem` in `useWorkspacesStore().workspaces` by matching `id === itemId` across ALL workspaces (itemId is globally unique; no need to filter by workspaceId first). Returns `null` if the itemId is empty OR if no matching kanban exists.
   - `workspaceId` — derived from the item: walks `workspacesStore.workspaces` looking for the workspace that owns `item` and returns its `id`. Returns `''` if the item isn't found (defensive — used by `goBack`).
   - `notFound` — `!!itemId && !item`.
   - `emptyHint` — `!itemId`.

6. **Handlers** — mirror the dialog handlers 1:1 (add column, edit column, delete column, rename, copy spec, request rename/delete, back).

7. **`goBack`** — `router.replace({ path: '/app', query: { view: 'workspace', workspaceId, itemId } })`. The `workspaceId` is the one derived from the item in the store. Guards: if `item` isn't found, fall back to `router.replace({ path: '/app' })` so the user doesn't get stuck on a stale URL.

8. **Template** — full-page layout (NOT a centered modal):
   - Outer wrapper: `<div class="flex h-full" style="background-color: var(--semantic-content-bg)">`.
   - Left sidebar (240px wide): back button + page title "⚙ Kanban Settings" + kanban name (via `<InlineEditableText>`) + tab strip ("Columns" / "🧠 Local Memories", memories tab hidden when `item?.path` is null). The sidebar mirrors `SettingsView`'s 240px sidebar shape (AppLayout.vue:2676 / SettingsView.vue:43-105) so the two pages feel consistent.
   - Right content panel (`flex-1 overflow-hidden`): when `emptyHint`, render a centered hint. When `notFound`, render a centered "kanban not found" hint. Otherwise render the columns tab body (add-form + columns list + copy-spec footer) OR the memories tab body (WorkspaceItemMemoriesView). Identical markup to the dialog's tabs.
   - Bottom of template: `<KanbanColumnEditor :show="showSettingsEditor" ... />` for per-row rename/delete (lifted from the dialog, line 517-525).

9. **`data-testid` conventions** — prefix every testid with `kanban-settings-page-` (NOT `kanban-settings-dialog-`) to make it grep-distinct from the old dialog:
   - `kanban-settings-page` — the outer wrapper (matches the dialog's `kanban-settings-dialog`).
   - `kanban-settings-page-back` — back button.
   - `kanban-settings-page-title` — page title.
   - `kanban-settings-page-tabs` / `...-tab-columns` / `...-tab-memories` — tab strip.
   - `kanban-settings-page-add-form` / `...-add-name` / `...-add-description` / `...-add-submit` — add-column form.
   - `kanban-settings-page-column-list` / `...-column-row-<id>` / `...-column-name-<id>` / `...-column-description-<id>` — columns list rows.
   - `kanban-settings-page-edit-<id>` / `...-delete-<id>` — per-row actions.
   - `kanban-settings-page-copy-spec` — copy-spec footer button.
   - `kanban-settings-page-memories-panel` — memories tab body.
   - `kanban-settings-page-memories-no-path` — fallback when memories tab forced without path.
   - `kanban-settings-page-no-item` — empty itemId hint.
   - `kanban-settings-page-not-found` — item not in store hint.

10. **Lifecycle** — `watch([() => route.query.workspaceId, () => route.query.itemId], ...)` does NOT trigger a re-render (the computed already reacts); no extra watcher needed.

Run `npm run test:unit -- KanbanSettingsView.spec.ts`. All 12 tests pass.

### Step 2.4: Commit

```
feat: kanban settings page (full-page route)
```

---

## Task 3: Wire `KanbanSettingsView` into AppLayout

**Why:** The page exists but isn't mounted anywhere yet. This task wires the URL → component path AND converts the old ⚙ click → dialog flow to click → URL navigate → page mount.

**Files:**
- `src/apps/desktop/src/components/AppLayout.vue` — EDIT

### Step 3.1: Replace the show-flag with a router.push (path-based)

In AppLayout.vue, locate the kanban-settings state block (line 1631-1677):

1. **DELETE** the `showKanbanSettingsDialog` ref (line 1640).
2. **DELETE** the `handleOpenKanbanSettings` function body (line 1642-1644) and replace with a `router.push` to the new path route:

```ts
const handleOpenKanbanSettings = () => {
  const itemId = activeWorkspaceItem.value?.id ?? ''
  if (!itemId) return
  // Path-based route: /app/kanban/:itemId/settings (registered in
  // router/index.ts). workspaceId is derived from the store by the
  // page itself — no need to encode it in the URL (itemId is
  // globally unique across all workspaces).
  router.push({ path: `/app/kanban/${itemId}/settings` })
}
```

3. **DELETE** the `handleCloseKanbanSettings` handler entirely — the new page navigates itself via its own Back button (or `router.back()`). No need for an AppLayout-level close handler.

4. **KEEP** all the column-management handlers (`handleKanbanSettingsAddColumn`, `handleKanbanSettingsEditColumn`, `handleKanbanSettingsDeleteColumn`, `handleKanbanRenameItem`, `handleOpenCopyKanbanSpec`) — the new page emits the same events, AppLayout still routes them to `workspacesStore`.

### Step 3.2.5: Sidebar active-row highlight (UX gap closure)

The sidebar's kanban row uses `useCurrentMainView().value.kind === 'workspace'` (WorkspaceItem.vue:102-105) to decide whether to highlight itself. Without an update, navigating to `/app/kanban/X/settings` would leave the parent kanban row unhighlighted — visually inconsistent with how `?view=workspace` behaves.

In `src/apps/desktop/src/components/workspace/WorkspaceItem.vue`, extend the `isCurrentMainView` computed (line 102-105):

```ts
const isCurrentMainView = computed(() => {
  const v = currentMainView.value
  if (v.kind === 'workspace' && v.itemId === props.item.id) return true
  // NEW (plan: 2026-09-02-kanban-settings-as-page): keep the parent
  // row highlighted when the user is on the kanban settings page.
  // The page is a sub-state of the kanban (same itemId), so the row
  // should stay visually selected until the user navigates elsewhere.
  if (v.kind === 'kanban-settings' && v.itemId === props.item.id) return true
  return false
})
```

Add 2 behavioural tests in the existing `WorkspaceItem.spec.ts` (or create one if it doesn't exist):
- `stays highlighted when currentMainView.kind === 'kanban-settings' && itemId === props.item.id`.
- `is not highlighted when currentMainView.kind === 'kanban-settings' && itemId === SOME_OTHER_ITEM`.

### Step 3.3: Mount the page

In AppLayout.vue's `<template>` block, locate the `<KanbanSettingsDialog>` mount at line 2744-2753. **DELETE** that mount entirely.

Then, in the `<main>` block, AFTER the existing `<KanbanView v-else-if="...item_type === 'kanban'">` branch (line 2349-2371) and AFTER the kanban chat dialog mounts (line 2385-2399), add the new branch. Important: this branch must be a sibling `v-else-if` in the SAME chain as the kanban / chat / design / agent mounts so they're mutually exclusive (mirrors the existing pattern).

```vue
<KanbanSettingsView
  v-else-if="currentView === 'kanban-settings'"
  :key="'kanban-settings-' + (route.params.itemId as string)"
  @add-column="handleKanbanSettingsAddColumn"
  @edit-column="handleKanbanSettingsEditColumn"
  @delete-column="handleKanbanSettingsDeleteColumn"
  @rename-item="handleKanbanRenameItem"
  @copy-spec="handleOpenCopyKanbanSpec"
/>
```

Also: add `KanbanSettingsView` to the imports block (line 1-46) — `import KanbanSettingsView from './views/KanbanSettingsView.vue'`.

### Step 3.4: Verify the URL watcher doesn't clobber the kanban-settings URL

Locate the activeWorkspaceItemId → URL mirror watcher (AppLayout.vue line 297-406). It currently guards:

```ts
if (currentView !== 'workspace' && currentView !== undefined) return
```

The path-based kanban-settings URL has `currentView === 'kanban-settings'` (via the regex in Step 4.1 below), so the existing guard already prevents the watcher from clobbering it. **No edit needed in the watcher** — just verify in the smoke test that the URL stays at `/app/kanban/X/settings` when activeWorkspaceItemId changes.

### Step 3.5: Commit

```
feat: wire KanbanSettingsView into AppLayout on /app/kanban/:itemId/settings
```

---

## Task 4: Add `<KanbanSettingsView>` to the `currentView` family in AppLayout

**Why:** AppLayout's `currentView` computed (line 888-913) returns one of several strings; with a path-based URL, `currentView` doesn't recognize `/app/kanban/:itemId/settings` automatically. Add an explicit branch BEFORE the `route.query.view` fallthrough so the path is recognized as `'kanban-settings'`.

**Files:**
- `src/apps/desktop/src/components/AppLayout.vue` — EDIT

### Step 4.1: Add the path-based branch to `currentView`

In AppLayout.vue, the `currentView` computed (line 888-913). Currently:

```ts
const currentView = computed(() => {
  const path = route.path
  if (path === '/app/settings') return 'settings'
  // gitfile / skill / code-editor priority chain...
  const view = (route.query.view as string) || 'chat'
  return view
})
```

Add a new branch BEFORE the fallthrough (place it AFTER the `path === '/app/settings'` check at line 890, BEFORE the `gitViewerFile.value` check):

```ts
// NEW (plan: 2026-09-02-kanban-settings-as-page). Path-based
// kanban-settings route (/app/kanban/:itemId/settings). Must come
// BEFORE the route.query.view fallthrough because the URL has no
// `view=` query param — the path IS the discriminator.
if (/^\/app\/kanban\/[^/]+\/settings\/?$/.test(path)) {
  return 'kanban-settings'
}
```

This regex matches `/app/kanban/<non-empty>/settings` (with optional trailing slash). It deliberately does NOT match `/app/kanban/X` (no `/settings`) — the kanban board itself stays at the existing `?view=workspace` URL, so a future migration to `/app/kanban/:itemId` would be a separate plan.

### Step 4.2: Commit

```
feat: currentView recognizes /app/kanban/:itemId/settings path route
```

---

## Task 5: Delete the old `KanbanSettingsDialog`

**Why:** The page fully replaces the dialog. Keeping the dialog around creates two parallel code paths that drift over time (see the agent-kanbans mirror plan, where parallel panels caused bugs). Delete the files and let `vue-tsc` catch any leftover references.

**Files:**
- `src/apps/desktop/src/components/kanban/KanbanSettingsDialog.vue` — DELETE
- `src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts` — DELETE

### Step 5.1: Delete the files

```bash
rm src/apps/desktop/src/components/kanban/KanbanSettingsDialog.vue
rm src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts
```

### Step 5.2: Audit for leftover references

Run `npm run type-check` (or `node node_modules/vue-tsc/bin/vue-tsc.js --build`). Expect errors at:

- `src/apps/desktop/src/components/AppLayout.vue` — if the import line `import KanbanSettingsDialog from './kanban/KanbanSettingsDialog.vue'` is still present, remove it (Task 3.2 should have caught this; double-check).

Grep for `KanbanSettingsDialog` to confirm zero remaining references:

```bash
grep -rn "KanbanSettingsDialog" src/apps/desktop/src
```

Expect: zero hits.

### Step 5.3: Commit

```
chore: remove KanbanSettingsDialog (replaced by KanbanSettingsView)
```

---

## Task 6: Verify no obsolete `useCurrentMainView` assertions

**Why:** Task 1.1 + 1.2.5 already added the new tests AND updated the `mockRoute` helper to include `path` + `params`. The 8 pre-existing tests use `path: '/app'` (the default), which still works after the helper update. The "does NOT have a kind=task variant" sanity test (line 117-127) and the "returns none when URL is a non-content view (settings)" test (line 98-104) are unaffected by the new variant.

**Skip — no edit needed.** Task 1.1 + 1.2.5 cover it.

---

## Task 7: Update `docs/SPEC.md` and `PABRIK.md`

**Files:**
- `docs/SPEC.md` — EDIT
- `PABRIK.md` — EDIT

### Step 7.1: SPEC.md

Find the "PR index" section (around line 241, where `2026-06-27-kanban-column-description-settings.md` is listed). Add a new row:

```
| `2026-09-02-kanban-settings-as-page.md` | ✅ | Migration 053 + new `KanbanSettingsView` replaces `KanbanSettingsDialog` |
```

Find the Kanban layout section (§3.7) and update the entry to reflect "settings is a dedicated page, not a modal".

### Step 7.2: PABRIK.md

Append a new changelog entry at the bottom of the "Recent changes" section:

```markdown
- **Kanban settings: centered modal → dedicated page** (2026-09-02): Clicking ⚙ on a kanban board header used to open `KanbanSettingsDialog` as a centered modal. Now navigates to the vue-router path route `/app/kanban/:itemId/settings` and renders the new `KanbanSettingsView` (full-page layout mirroring `SettingsView`'s 240px sidebar + content panel shape). The URL is the source of truth — reload preserves the page, **← Back** returns to the kanban board. `<KanbanSettingsDialog>` + its spec are deleted. `useCurrentMainView` gains a `{ kind: 'kanban-settings', workspaceId, itemId }` variant that parses `route.path` + `route.params`. AppLayout's `currentView` computed recognizes the new path via regex. 11 files: 2 NEW (`KanbanSettingsView.vue`, `KanbanSettingsView.spec.ts`), 5 EDIT (`useCurrentMainView.ts`, `useCurrentMainView.spec.ts`, `router/index.ts`, `AppLayout.vue`, `WorkspaceItem.vue`), 2 DELETE (`KanbanSettingsDialog.vue`, `KanbanSettingsDialog.spec.ts`), 2 docs.
```

### Step 7.3: Commit

```
docs: kanban settings as dedicated page
```

---

## Task 8: Final verification

**Why:** Verify the entire flow works end-to-end before reporting completion.

### Step 8.1: Type check

```bash
npm run type-check
```

Expect: zero errors.

### Step 8.2: Unit tests

```bash
npm run test:unit
```

Expect: all tests pass (existing + 4 new in `useCurrentMainView.spec.ts` + 12 new in `KanbanSettingsView.spec.ts` - 20 deleted from `KanbanSettingsDialog.spec.ts` = NET +16 tests).

### Step 8.3: Build

```bash
npm run build
```

Expect: success.

### Step 8.4: Manual smoke (port 8080, NOT 8081)

1. Start the backend: `zig build pabrik-desktop --summary all` (binary at `zig-out/bin/pabrikcore-linux-x86_64`).
2. Launch the desktop binary on port 8080.
3. Open the desktop app, navigate to a workspace with at least one kanban.
4. Click ⚙ Settings on the kanban header.
5. Verify:
   - URL becomes `/app/kanban/item_X/settings`.
   - The page renders full-bleed (not a modal).
   - Columns tab + Memories tab + Copy Spec footer all work.
   - **← Back** returns to the kanban board.
   - Reload mid-page restores the kanban-settings page.
6. Repeat on macOS + Windows builds.

### Step 8.5: Commit (if any fixes landed)

```
chore: post-verification fixes
```

---

## Notes

- **Backward compat**: any test that referenced `data-testid="kanban-settings-dialog"` will need migration to `data-testid="kanban-settings-page"`. The deleted `KanbanSettingsDialog.spec.ts` had ~20 such references; the migration is "delete the file" (Task 5) rather than rewrite, because the page owns the new testids.
- **Why a vue-router path route (`/app/kanban/:itemId/settings`)?** Matches the existing convention for sibling sub-pages: `/app/settings`, `/app/chat/:sessionId`, `/app/task/:taskId`. Path routes are more readable (no `?view=` prefix), support vue-router's path params natively (`route.params.itemId`), and align with how Notion / Linear / GitHub structure their URLs (per-resource sub-pages always use paths). The kanban board itself stays at `?view=workspace` for now — migrating it to `/app/kanban/:itemId` would be a separate plan (route ordering with the new `/app/kanban/:itemId/settings` is fine because the settings path is longer and vue-router resolves it first).
- **Why is workspaceId NOT in the path?** itemId is globally unique across all workspaces (`workspace_items.id` is the PK), so we don't need workspaceId to disambiguate. The page derives workspaceId by walking `workspacesStore.workspaces` looking for which workspace owns the item — used only by `goBack` to round-trip back to `?view=workspace&workspaceId=X&itemId=Y`. Encoding workspaceId in the URL would add noise (and break if a kanban is ever moved between workspaces — unlikely but possible). If workspaceId becomes important for routing later, add `/app/kanban/:workspaceId/:itemId/settings` as a new path.
- **Why delete the dialog entirely instead of leaving it as a fallback?** Two parallel implementations always drift. The page covers 100% of the dialog's surface (columns / memories / copy spec / rename / delete / kanban rename), so there is no gap.
- **Why not a `<KanbanSettingsDialog>` mode on the existing modal component?** The user explicitly asked for "a new page, not a dialog". A full-page layout gives the columns list + memories tab room to breathe (currently cramped in `min(80vh, calc(100vh - 2rem))`) and lets the back button be a real nav action (browser back / `router.back()`), not just a modal close.
- **Why delete the dialog entirely instead of leaving it as a fallback?** Two parallel implementations always drift. The page covers 100% of the dialog's surface (columns / memories / copy spec / rename / delete / kanban rename), so there is no gap.
- **Sidebar highlight**: the sidebar reads `useCurrentMainView` to mark the active row. After Task 1, the sidebar's `kanban` row will be highlighted when `kind === 'kanban-settings'` (the sidebar's branch should already match by item id — verify with a quick smoke test).
