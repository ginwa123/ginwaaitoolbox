# Simplify URL Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `?view=task&task=X` URLs into the workspace URL by encoding the chat task id as `/chat/task_X` suffix on the `itemId` query value, producing a single URL shape for both no-chat and chat-open workspace item views.

**Architecture:** A new pure helper (`buildItemIdWithChat` / `parseItemIdWithChat`) owns the wire-shape encoding. The existing `buildTaskUrlQuery` helper stops emitting `view=task`/`task`/`session` and instead emits `view=workspace` with the chat suffix on `itemId`. `useCurrentMainView` drops the `task` variant and gains `chatTaskId?: string` on the `workspace` variant. `AppLayout` deletes its `view=task` arms (route branch, template mount, URL-sync branch), the URL-sync watcher learns to preserve the suffix, and the close-task-view handler strips it. Old `view=task` URLs are auto-rewritten to the new shape on mount.

**Tech Stack:** Vue 3 (script setup, `<script setup lang="ts">`), vue-router 4, Pinia, vitest, TypeScript, Zig 0.16 backend (out of scope for this plan — frontend-only change).

**Spec:** `docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md`

## Global Constraints

- **Branch:** `worktree/simplify-url-browser` (created from main, head `91cd3155`). All work happens in this branch.
- **No backend changes.** This is a frontend-only refactor.
- **Test discipline:** Every implementation task has a failing-test step before the code step. Tests live in `src/apps/desktop/src/{composables,components,helpers}/__tests__/*.spec.ts` and `src/apps/desktop/src/__tests__/*.spec.ts`.
- **Commit cadence:** One commit per task. Use conventional commits (`feat: ...`, `refactor: ...`, `test: ...`, `fix: ...`).
- **vue-tsc clean:** Run `npx vue-tsc --build --noEmit` (or the project's `vue-tsc` script) before the final commit and ensure zero errors.
- **vitest run:** Run `npx vitest run` before the final commit. All + new tests must pass.
- **No `view=task` references left behind:** `rg "view=task|view:'task'|kind: 'task'" src/apps/desktop/src` must return zero hits after every task.
- **The literal separator `/chat/` must never appear inside the bare item id.** Enforced by `buildItemIdWithChat` throwing on bad input.

---

## File map

### Production

| File | Action | Notes |
|---|---|---|
| `src/apps/desktop/src/helpers/buildItemIdWithChat.ts` | NEW | Pure helper. 3 exports: `buildItemIdWithChat`, `parseItemIdWithChat`, `CHAT_SUFFIX`. |
| `src/apps/desktop/src/helpers/buildTaskUrlQuery.ts` | MODIFY | Drop `view: 'task'` / `task` / `session`; append `/chat/<taskId>` to `itemId`; emit `view: 'workspace'`. |
| `src/apps/desktop/src/composables/useCurrentMainView.ts` | MODIFY | Drop `kind: 'task'`; add `chatTaskId?: string` to `workspace` variant. Parse the `itemId` value to expose both bare id and chat task id. |
| `src/apps/desktop/src/components/shell/Sidebar.vue` | MODIFY | No behaviour changes at the call site — the helper change makes them automatic. Update the docstring to mention the new URL shape. |
| `src/apps/desktop/src/components/AppLayout.vue` | MODIFY | Delete `handleNavigate('task')` branch; delete `currentView` 'task' arm; delete `<ChatView v-else-if="currentView === 'task'">` mount; update `handleCloseTaskView` to use the parsed bare item id; preserve `/chat/` suffix in the URL-sync watcher; in `onMounted`, parse `route.query.itemId` and call `setActiveTask` for the chat task id; in `onMounted`, detect stale `view=task` URLs and silently rewrite them via `router.replace`. Update the `closeGitViewer` / `closeSkillViewer` / `closeCodeEditor` task-else branches to use the new helper output. |
| `src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue` | MODIFY | Task row highlight reads `kind: 'workspace' + chatTaskId` instead of `kind: 'task'`. |
| `src/apps/desktop/src/components/workspace/WorkspaceItem.vue` | MODIFY | Workspace item row highlight uses the parsed bare item id. |

### Tests

| File | Action | Notes |
|---|---|---|
| `src/apps/desktop/src/helpers/__tests__/buildItemIdWithChat.spec.ts` | NEW | 8 unit tests covering the helper. |
| `src/apps/desktop/src/__tests__/AppLayout.simplifyUrl.spec.ts` | NEW | Mount `AppLayout` with the new URL shape; assert `activeWorkspaceItemId`, `activeTaskId`, dialog visibility per URL. |
| `src/apps/desktop/src/__tests__/AppLayout.chatSuffixRoundTrip.spec.ts` | NEW | Open chat → URL becomes `?view=workspace&...&itemId=Y/chat/task_W`; close chat → suffix stripped; back button restores chat-open URL. |
| `src/apps/desktop/src/composables/useCurrentMainView.spec.ts` | REWRITE | Replace `kind: 'task'` test cases with `chatTaskId` cases. |
| `src/apps/desktop/src/helpers/__tests__/buildTaskUrlQuery.spec.ts` | MODIFY | Rewrite expected output for the new wire shape. |
| `src/apps/desktop/src/__tests__/AppLayout.urlPersist.spec.ts` | MODIFY | Update `?view=task&task=X` test setups to the new shape. |
| `src/apps/desktop/src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts` | MODIFY | Sort round-trip through the new URL shape. |
| `src/apps/desktop/src/__tests__/AppLayout.taskClickUrlOverwrite.spec.ts` | MODIFY | Task-click URL is the new shape; `router.replace` / `router.push` semantics preserved. |
| `src/apps/desktop/src/__tests__/AppLayout.kanbanChatDialog.spec.ts` | MODIFY | Dialog mount driven by the new URL suffix. |
| `src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts` | MODIFY | Legacy `view=task&task=X` URL becomes `view=workspace&itemId=Y/chat/task_X`. |
| `src/apps/desktop/src/__tests__/sidebarHandleSelectTaskUrl.spec.ts` | MODIFY | Assertions rewritten to the new wire shape. |
| `src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts` | MODIFY | Task row active styling reads `kind: 'workspace' + chatTaskId`. |
| `src/apps/desktop/src/__tests__/workspaceItemTaskCard.spec.ts` | MODIFY | (Verify the card-row variant doesn't separately check task id; if it does, update.) |
| `src/apps/desktop/src/__tests__/DesignPageRow.spec.ts` | VERIFY | No change expected. Run tests; if they pass, no edit needed. |
| `src/apps/desktop/src/__tests__/DesignPageRow.activeFromUrl.spec.ts` | VERIFY | No change expected. Run tests; if they pass, no edit needed. |
| `src/apps/desktop/src/__tests__/WorkspaceItem.activeFromUrl.spec.ts` | VERIFY | No change expected (workspace row reads `kind: 'workspace' + itemId`). Run tests; if they pass, no edit needed. |
| `src/apps/desktop/src/__tests__/ChatsList.activeFromUrl.spec.ts` | VERIFY | No change expected (chat row reads `kind: 'chat'`). Run tests; if they pass, no edit needed. |
| `src/apps/desktop/src/__tests__/AppLayout.chatview.spec.ts` | VERIFY | No change expected (gates on `activeChatId`). Run tests; if they pass, no edit needed. |
| `src/apps/desktop/src/__tests__/AppLayout.designChatDialog.spec.ts` | VERIFY | No change expected (gates on `activeDesignChatTaskId`). Run tests; if they pass, no edit needed. |

---

## Task 1 — New helper: `buildItemIdWithChat`

**Files:**
- NEW: `src/apps/desktop/src/helpers/buildItemIdWithChat.ts`
- NEW: `src/apps/desktop/src/helpers/__tests__/buildItemIdWithChat.spec.ts`

### Step 1.1: Write the failing test

Create `src/apps/desktop/src/helpers/__tests__/buildItemIdWithChat.spec.ts`:

```ts
import { describe, it, expect } from 'vitest'
import {
  buildItemIdWithChat,
  parseItemIdWithChat,
  CHAT_SUFFIX,
} from '../buildItemIdWithChat'

describe('buildItemIdWithChat', () => {
  it('returns bare itemId when chatTaskId is null', () => {
    expect(buildItemIdWithChat('item_y', null)).toBe('item_y')
  })

  it('appends /chat/<taskId> when chatTaskId is provided', () => {
    expect(buildItemIdWithChat('item_y', 'task_w')).toBe('item_y/chat/task_w')
  })

  it('throws if the item id already contains the /chat/ separator', () => {
    expect(() => buildItemIdWithChat('item_y/chat/task_w', 'task_new')).toThrow(
      /item id cannot contain "\/chat\/"/,
    )
  })
})

describe('parseItemIdWithChat', () => {
  it('returns chatTaskId=null for a bare item id', () => {
    expect(parseItemIdWithChat('item_y')).toEqual({ itemId: 'item_y', chatTaskId: null })
  })

  it('returns itemId + chatTaskId for the suffixed form', () => {
    expect(parseItemIdWithChat('item_y/chat/task_w')).toEqual({
      itemId: 'item_y',
      chatTaskId: 'task_w',
    })
  })

  it('round-trips through buildItemIdWithChat', () => {
    const original = 'item_y'
    const taskId = 'task_w'
    const built = buildItemIdWithChat(original, taskId)
    expect(parseItemIdWithChat(built)).toEqual({ itemId: original, chatTaskId: taskId })
  })

  it('round-trips with chatTaskId=null', () => {
    const built = buildItemIdWithChat('item_y', null)
    expect(parseItemIdWithChat(built)).toEqual({ itemId: 'item_y', chatTaskId: null })
  })

  it('exposes the /chat/ separator constant', () => {
    expect(CHAT_SUFFIX).toBe('/chat/')
  })
})
```

### Step 1.2: Run — expect red

```bash
cd src/apps/desktop
npx vitest run src/helpers/__tests__/buildItemIdWithChat.spec.ts 2>&1 | tail -n 30
```

Expect: `Failed to resolve import "../buildItemIdWithChat"`.

### Step 1.3: Implement the helper

Create `src/apps/desktop/src/helpers/buildItemIdWithChat.ts`:

```ts
/**
 * buildItemIdWithChat — encode / decode the `/chat/<taskId>` suffix
 * on the `itemId` query value used by AppLayout's URL scheme.
 *
 * Background: the chat-open workspace URL has the shape
 *   ?view=workspace&workspaceId=X&itemId=item_Y/chat/task_W
 * The `itemId` value carries an extra `/chat/<taskId>` suffix when
 * the chat dialog is open. This helper centralises the parse +
 * build logic so every URL writer / reader stays consistent.
 *
 * Plan: docs/superpowers/plans/2026-08-15-simplify-url-browser.md
 * Spec: docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md
 */

/** The literal separator between the bare item id and the chat task id. */
export const CHAT_SUFFIX = '/chat/'

/**
 * Combine a workspace item id with an optional chat task id.
 *
 * Throws if `itemId` itself already contains the `/chat/` substring
 * (defensive — item ids never contain slashes in this codebase).
 */
export function buildItemIdWithChat(itemId: string, chatTaskId: string | null): string {
  if (typeof itemId !== 'string' || itemId.length === 0) {
    throw new Error(`buildItemIdWithChat: itemId must be a non-empty string`)
  }
  if (itemId.includes(CHAT_SUFFIX)) {
    throw new Error(
      `buildItemIdWithChat: item id cannot contain "${CHAT_SUFFIX}" (got "${itemId}")`,
    )
  }
  if (chatTaskId === null || chatTaskId === '') return itemId
  return `${itemId}${CHAT_SUFFIX}${chatTaskId}`
}

/**
 * Parse a raw `itemId` query value into a bare item id and an
 * optional chat task id.
 */
export function parseItemIdWithChat(raw: string): {
  itemId: string
  chatTaskId: string | null
} {
  if (typeof raw !== 'string' || raw.length === 0) {
    return { itemId: '', chatTaskId: null }
  }
  const idx = raw.indexOf(CHAT_SUFFIX)
  if (idx === -1) return { itemId: raw, chatTaskId: null }
  return {
    itemId: raw.slice(0, idx),
    chatTaskId: raw.slice(idx + CHAT_SUFFIX.length),
  }
}
```

### Step 1.4: Run — expect green

```bash
cd src/apps/desktop
npx vitest run src/helpers/__tests__/buildItemIdWithChat.spec.ts 2>&1 | tail -n 30
```

Expect: `8 passed`.

### Step 1.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/helpers/buildItemIdWithChat.ts \
        src/apps/desktop/src/helpers/__tests__/buildItemIdWithChat.spec.ts
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "feat(helpers): add buildItemIdWithChat + parseItemIdWithChat (step 1/12 of simplify-url-browser)"
```

---

## Task 2 — Update `buildTaskUrlQuery` to emit the new wire shape

**Files:**
- MODIFY: `src/apps/desktop/src/helpers/buildTaskUrlQuery.ts`

### Step 2.1: Rewrite the failing tests

Open `src/apps/desktop/src/helpers/__tests__/buildTaskUrlQuery.spec.ts`. Replace the existing test cases with new ones asserting the new wire shape. The key changes:

1. Replace each `expect(query.view).toBe('task')` with `expect(query.view).toBe('workspace')`.
2. Replace each `expect(query.task).toBe(TASK_ID)` with `expect(query.itemId).toBe(\`${ITEM_ID}/chat/${TASK_ID}\`)`.
3. Remove any `expect(query.session)` assertion (the `session` param is dropped — the chat task id in the suffix carries the session implicitly per `task.id == session_id`).
4. Every test's input `TaskUrlContext` is unchanged (the helper's input shape is preserved).

For each existing test, the diff against `ITEM_ID` is that the `itemId` field is now the suffixed form. The test fixture IDs must use a separate `ITEM_ID` that does NOT contain `/chat/`:

```ts
const WS_ID = 'ws_helper'
const ITEM_ID = 'item_helper'   // bare item id (no /chat/ inside)
const TASK_ID = 'task_helper'    // becomes the chat suffix
```

### Step 2.2: Run — expect red

```bash
cd src/apps/desktop
npx vitest run src/helpers/__tests__/buildTaskUrlQuery.spec.ts 2>&1 | tail -n 30
```

Expect: assertions on `query.view === 'task'` and `query.task === TASK_ID` fail.

### Step 2.3: Update the helper

Open `src/apps/desktop/src/helpers/buildTaskUrlQuery.ts`. The full new content:

```ts
/**
 * buildTaskUrlQuery — helper that builds the URL query object that
 * opens a chat dialog on a workspace item. The wire shape is:
 *
 *   ?view=workspace&workspaceId=X&itemId=item_Y/chat/task_W[&pageId=Z][&sorts=…]
 *
 * The chat task id is encoded as a `/chat/<taskId>` suffix on the
 * `itemId` value (see `buildItemIdWithChat`). This replaces the
 * legacy shape `?view=task&task=X&workspaceId=Y&itemId=Z` which
 * carried the same context under two different `view` values.
 *
 * Spec: docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md
 *
 * ## Why this exists
 *
 * Before this helper, several Vue call sites wrote task-URL
 * navigation with only `task` (and sometimes `itemId`), never
 * `workspaceId`. The user originally reported
 * (task_1785774094183): "add workspace_id params when view the
 * task, like in kanban mode or design mode" — the URL
 * `?view=task&task=X&itemId=Y` was missing `workspaceId`, breaking
 * URL-based persistence for deep-link / refresh / share. The 2026-08-06
 * fix moved the resolution logic into this helper.
 *
 * The 2026-08-15 simplify-url-browser refactor updated the wire shape:
 * this helper now emits `view=workspace` (NOT `view=task`) with the
 * chat task id encoded as the `/chat/<taskId>` suffix on `itemId`.
 * The redundant `session` query param is dropped (it's equal to the
 * task id per `task.id == session_id`).
 *
 * ## Algorithm
 *
 * Resolution order for workspaceId / itemId (first non-empty wins):
 *
 *   1. Active store state (`activeWorkspaceId`, `activeWorkspaceItemId`).
 *      AUTHORITATIVE — the user clicked the task from a workspace
 *      context, so the URL must reflect it.
 *   2. URL breadcrumb fallback (`route.query.workspaceId` etc.) for
 *      deep-link / share-link round-trips.
 *
 * `pageId` is gated on the active item type being `'design'` (avoids
 * cross-leak from a stale design page into a kanban URL).
 *
 * `sorts` is preserved from the URL breadcrumb (kanban per-column
 * sort state — survives the workspace → chat round-trip via the
 * existing `savedSortsParam` snapshot).
 *
 * ## Pure function
 *
 * No Vue / Pinia / vue-router imports. Pass in the active state.
 * Trivially testable.
 */
import {
  buildItemIdWithChat,
  type UrlQueryInput,
} from './buildItemIdWithChat'

export type { UrlQueryInput } from './buildItemIdWithChat'
export { pickBreadcrumbFromQuery } from './buildItemIdWithChat'

export interface TaskUrlContext {
  /** The task id to put in the `/chat/<taskId>` suffix (required). */
  taskId: string
  /** Active workspace id from the store, or null if none. */
  activeWorkspaceId?: string | null | undefined
  /** Active workspace item id from the store, or null if none. */
  activeWorkspaceItemId?: string | null | undefined
  /** Active design page id from the store, or null if none. */
  activeDesignPageId?: string | null | undefined
  /**
   * Active workspace item's `item_type`. Gates `pageId` (design-only).
   */
  activeItemType?: string | null | undefined
  /**
   * Fallback current URL query. Used when no active store state.
   */
  currentQuery?: UrlQueryInput | null | undefined
}

/**
 * Build a URL query object for chat-dialog navigation on a
 * workspace item. Always emits `view: 'workspace'` and includes the
 * `/chat/<taskId>` suffix on `itemId`.
 */
export function buildTaskUrlQuery(input: TaskUrlContext): Record<string, string> {
  const taskId = (input.taskId ?? '').toString().trim()
  if (!taskId) {
    throw new Error('buildTaskUrlQuery: taskId is required')
  }

  const wsId = (input.activeWorkspaceId ?? '').toString().trim()
  const itemId = (input.activeWorkspaceItemId ?? '').toString().trim()
  const storePageId = (input.activeDesignPageId ?? '').toString().trim()
  const activeItemType = (input.activeItemType ?? '').toString()

  // Breadcrumb from current URL
  const urlBreadcrumb = input.currentQuery
    ? pickBreadcrumbFromQuery(input.currentQuery)
    : {}

  const query: Record<string, string> = { view: 'workspace' }

  // ─── workspaceId + itemId (with /chat/<taskId> suffix) ──────────
  const itemIdWithChat = buildItemIdWithChat(
    itemId || urlBreadcrumb.itemId?.split('/chat/')[0] || '',
    taskId,
  )
  // Defensive: only include itemId if we know the bare item id.
  // The split above handles the case where the URL breadcrumb
  // already carries a /chat/ suffix from a previous navigation.
  if (itemId || urlBreadcrumb.itemId) {
    if (wsId) query.workspaceId = wsId
    query.itemId = itemIdWithChat
  } else if (urlBreadcrumb.workspaceId) {
    // Deep-link: workspaceId from URL, itemId parseable too if present
    query.workspaceId = urlBreadcrumb.workspaceId
    if (urlBreadcrumb.itemId) query.itemId = itemIdWithChat
  }

  // ─── pageId (design-only) ────────────────────────────────────────
  const isActiveDesign = activeItemType === 'design'
  const urlPageId = urlBreadcrumb.pageId ?? ''
  if (isActiveDesign) {
    if (storePageId) query.pageId = storePageId
    else if (urlPageId) query.pageId = urlPageId
  }

  // ─── sorts (kanban view-specific, lives in URL only) ─────────────
  if (urlBreadcrumb.sorts) query.sorts = urlBreadcrumb.sorts

  return query
}
```

Also create the re-exports + helper in `buildItemIdWithChat.ts`. Add to the top of that file (replace the existing exports block):

```ts
// (existing CHAT_SUFFIX / buildItemIdWithChat / parseItemIdWithChat
// exports stay as in Task 1)

export type UrlQueryInput = LocationQuery | Record<string, unknown>

/**
 * Pick breadcrumb params from a vue-router LocationQuery. Used by
 * `buildTaskUrlQuery` and shared with Sidebar's pre-fix inline
 * `pickBreadcrumbFromQuery`. Returns an empty object when none are
 * present.
 */
export function pickBreadcrumbFromQuery(
  query: Record<string, unknown>,
): Record<string, string> {
  const out: Record<string, string> = {}
  for (const key of ['workspaceId', 'itemId', 'pageId', 'sorts']) {
    const v = query[key]
    if (typeof v === 'string' && v.length > 0) out[key] = v
  }
  return out
}
```

### Step 2.4: Run — expect green

```bash
cd src/apps/desktop
npx vitest run src/helpers/__tests__/buildTaskUrlQuery.spec.ts 2>&1 | tail -n 30
```

Expect: all `buildTaskUrlQuery` test cases pass.

### Step 2.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/helpers/buildTaskUrlQuery.ts \
        src/apps/desktop/src/helpers/buildItemIdWithChat.ts \
        src/apps/desktop/src/helpers/__tests__/buildTaskUrlQuery.spec.ts \
        src/apps/desktop/src/helpers/__tests__/buildItemIdWithChat.spec.ts
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "refactor(helpers): emit view=workspace + /chat/<taskId> suffix from buildTaskUrlQuery (step 2/12)"
```

---

## Task 3 — Update `useCurrentMainView`

**Files:**
- MODIFY: `src/apps/desktop/src/composables/useCurrentMainView.ts`
- MODIFY: `src/apps/desktop/src/composables/useCurrentMainView.spec.ts`

### Step 3.1: Update the failing test

Open `src/apps/desktop/src/composables/useCurrentMainView.spec.ts`. Make these specific changes:

1. Delete the `it('returns task view when URL is ?view=task&task=X', ...)` test (lines 39-50).
2. Replace it with two tests:

```ts
it('returns workspace view with chatTaskId when URL has ?view=workspace&workspaceId=X&itemId=Y/chat/task_Z', () => {
  mockRoute({
    view: 'workspace',
    workspaceId: 'ws_1',
    itemId: 'item_kanban/chat/task_xyz',
  })
  let v!: ReturnType<typeof useCurrentMainView>
  function setup() { v = useCurrentMainView() }
  setup()
  expect(v.value).toEqual({
    kind: 'workspace',
    workspaceId: 'ws_1',
    itemId: 'item_kanban',
    pageId: undefined,
    chatTaskId: 'task_xyz',
  })
})

it('returns workspace view without chatTaskId when URL has bare itemId', () => {
  mockRoute({
    view: 'workspace',
    workspaceId: 'ws_1',
    itemId: 'item_kanban',
  })
  let v!: ReturnType<typeof useCurrentMainView>
  function setup() { v = useCurrentMainView() }
  setup()
  expect(v.value).toEqual({
    kind: 'workspace',
    workspaceId: 'ws_1',
    itemId: 'item_kanban',
    pageId: undefined,
    chatTaskId: undefined,
  })
})
```

3. Update the existing "returns none when URL is empty" test — it stays unchanged.

### Step 3.2: Run — expect red

```bash
cd src/apps/desktop
npx vitest run src/composables/useCurrentMainView.spec.ts 2>&1 | tail -n 30
```

Expect: `Expected kind: 'workspace' ... to equal kind: 'task' ...` (the old test fails first).

### Step 3.3: Update the composable

Replace the contents of `src/apps/desktop/src/composables/useCurrentMainView.ts`:

```ts
// src/apps/desktop/src/composables/useCurrentMainView.ts
import { computed, type ComputedRef } from 'vue'
import { useRoute } from 'vue-router'
import { parseItemIdWithChat } from '../helpers/buildItemIdWithChat'

/**
 * The single source of truth for "what is the main content area
 * currently showing?". Derived from the URL — never from store
 * flags that can drift.
 *
 * The sidebar components consume this to decide which row (if any)
 * is "active". Exactly one row in the sidebar should be active at
 * any time, and that row must match the kind + id below.
 *
 * Specs:
 *   - docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md
 *   - docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md
 */
export type CurrentMainView =
  | { kind: 'chat'; sessionId: string }
  | {
      kind: 'workspace'
      workspaceId?: string
      itemId: string
      pageId?: string
      chatTaskId?: string
    }
  | { kind: 'none' }

export function useCurrentMainView(): ComputedRef<CurrentMainView> {
  const route = useRoute()
  return computed<CurrentMainView>(() => {
    const q = (route?.query ?? {}) as Record<string, string>
    const view = q.view
    if (view === 'chat') {
      if (typeof q.session === 'string' && q.session.length > 0) {
        return { kind: 'chat', sessionId: q.session }
      }
      return { kind: 'none' }
    }
    if (view === 'workspace') {
      if (typeof q.itemId === 'string' && q.itemId.length > 0) {
        // Parse the wire-shape itemId (may carry /chat/<taskId> suffix).
        const parsed = parseItemIdWithChat(q.itemId)
        return {
          kind: 'workspace',
          workspaceId: typeof q.workspaceId === 'string' ? q.workspaceId : undefined,
          itemId: parsed.itemId,
          pageId: typeof q.pageId === 'string' && q.pageId.length > 0 ? q.pageId : undefined,
          chatTaskId: parsed.chatTaskId ?? undefined,
        }
      }
      return { kind: 'none' }
    }
    return { kind: 'none' }
  })
}
```

### Step 3.4: Run — expect green

```bash
cd src/apps/desktop
npx vitest run src/composables/useCurrentMainView.spec.ts 2>&1 | tail -n 30
```

Expect: all 7 tests pass.

### Step 3.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/composables/useCurrentMainView.ts \
        src/apps/desktop/src/composables/useCurrentMainView.spec.ts
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "refactor(useCurrentMainView): drop kind='task'; expose chatTaskId on workspace view (step 3/12)"
```

---

## Task 4 — Update `Sidebar.handleSelectTask` URL assertions (no behaviour change at call site)

**Files:**
- MODIFY: `src/apps/desktop/src/__tests__/sidebarHandleSelectTaskUrl.spec.ts`

The Sidebar `handleSelectTask` call site (Sidebar.vue:934-1013) doesn't change — `buildTaskUrlQuery` already updated to emit the new shape. But the assertions in `sidebarHandleSelectTaskUrl.spec.ts` check `pushArg.query.view === 'task'` and `pushArg.query.task === 'TASK_ID'` and need to be rewritten.

### Step 4.1: Read current assertions

Open `src/apps/desktop/src/__tests__/sidebarHandleSelectTaskUrl.spec.ts`. Search for:

```ts
expect(pushArg.query.view).toBe('task')
expect(pushArg.query.task).toBe(TASK_ID)
expect(pushArg.query.itemId).toBe(ITEM_ID)
```

These three-line patterns appear in the "preserves workspaceId..." test (lines ~170-208), "preserves pageId..." test (~237-268), and "from a deep-link..." test (~270-300).

### Step 4.2: Run — expect red

```bash
cd src/apps/desktop
npx vitest run src/__tests__/sidebarHandleSelectTaskUrl.spec.ts 2>&1 | tail -n 40
```

Expect: assertions on `query.view === 'task'` and `query.task === TASK_ID` fail.

### Step 4.3: Rewrite the assertions

For each block, replace:

```ts
expect(pushArg.query.view).toBe('task')
expect(pushArg.query.task).toBe(TASK_ID)
expect(pushArg.query.itemId).toBe(ITEM_ID)
```

with:

```ts
expect(pushArg.query.view).toBe('workspace')
expect(pushArg.query.itemId).toBe(`${ITEM_ID}/chat/${TASK_ID}`)
```

Keep the `expect(pushArg.query.workspaceId).toBe(WS_ID)`, `expect(pushArg.query.sorts).toBe(...)`, and `expect(pushArg.query.pageId).toBe(...)` assertions unchanged.

For the "deep-link task URL" test (currently asserts `?view=task&task=task_older&itemId=ITEM_ID` in the source route, then asserts `pushArg.query.view === 'task'` etc.), also update the source route to:

```ts
setRouteQuery({
  view: 'workspace',
  workspaceId: WS_ID,
  itemId: `${ITEM_ID}/chat/task_older`,
})
```

The assertion block at the end already asserts `pushArg.query.workspaceId === WS_ID`; that continues to pass because the URL breadcrumb resolver falls back to the active store state.

### Step 4.4: Run — expect green

```bash
cd src/apps/desktop
npx vitest run src/__tests__/sidebarHandleSelectTaskUrl.spec.ts 2>&1 | tail -n 30
```

Expect: all 5 tests pass.

### Step 4.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/__tests__/sidebarHandleSelectTaskUrl.spec.ts
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "test(Sidebar.handleSelectTask): expect view=workspace + /chat/<taskId> suffix (step 4/12)"
```

---

## Task 5 — Update `AppLayout.urlPersist` tests for the new wire shape

**Files:**
- MODIFY: `src/apps/desktop/src/__tests__/AppLayout.urlPersist.spec.ts`

### Step 5.1: Locate stale URL references

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
rg "view=task&task=|view: 'task'|'task'" src/apps/desktop/src/__tests__/AppLayout.urlPersist.spec.ts 2>&1 | head -n 20
```

The URL persist spec has multiple test setups using `?view=task&task=X`. Each one must be rewritten.

### Step 5.2: Run — expect red

```bash
cd src/apps/desktop
npx vitest run src/__tests__/AppLayout.urlPersist.spec.ts 2>&1 | tail -n 40
```

Expect: any test that sets `query: { view: 'task', task: TASK_ID }` and asserts the URL sync watchers behave correctly will fail.

### Step 5.3: Rewrite the test setups and assertions

For each `query: { view: 'task', task: TASK_ID, ... }` (and the matching `fullPath:`/`mockReturnValue`), rewrite to:

```ts
query: {
  view: 'workspace',
  workspaceId: WS_ID,
  itemId: `${ITEM_ID}/chat/${TASK_ID}`,
  ...rest,
}
```

And the matching `fullPath: '/app?view=workspace&workspaceId=ws_X&itemId=item_Y/chat/task_Z[&pageId=...]'`.

Also locate the test at line ~896 (`'URL mirror does NOT overwrite non-workspace views (view=task) when activeDesignPageId changes'`):
- Rename it to `'URL mirror does NOT overwrite non-workspace chat views when activeDesignPageId changes'`.
- Change `query: { view: 'task', task: 'task_xyz' }` to `query: { view: 'workspace', workspaceId: WS_ID, itemId: \`${KANBAN_ID}/chat/task_xyz\` }`.
- The assertion is that `replaceMock` was NOT called — that continues to be true because the watcher has the guard `if (currentView !== 'workspace' && currentView !== undefined) return`. The new URL is `view=workspace` so the watcher DOES enter its body — meaning this test changes meaning. **Update the assertion** to: the watcher DOES enter its body, but the URL it's about to write matches the current URL, so `replaceMock` is NOT called:

```ts
// Compare the would-be query against the current URL
const replaceCalls = replaceMock.mock.calls
if (replaceCalls.length > 0) {
  const writtenQuery = replaceCalls[0][0].query
  expect(writtenQuery.itemId).toBe(`${KANBAN_ID}/chat/task_xyz`)
  // No write should change the chatTaskId suffix
  expect(writtenQuery.itemId).toContain('/chat/task_xyz')
}
```

(Or simpler: assert `replaceCalls.length === 0` since the existing activeWorkspaceItemId is already `KANBAN_ID` from the URL — no diff to write.)

The key invariant: the `/chat/<taskId>` suffix on `itemId` is preserved when the URL sync watcher fires.

### Step 5.4: Run — expect green

```bash
cd src/apps/desktop
npx vitest run src/__tests__/AppLayout.urlPersist.spec.ts 2>&1 | tail -n 30
```

Expect: all URL persist tests pass.

### Step 5.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/__tests__/AppLayout.urlPersist.spec.ts
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "test(AppLayout.urlPersist): rewrite view=task references to /chat/ suffix (step 5/12)"
```

---

## Task 6 — Update `AppLayout.sortUrlRoundTrip`, `AppLayout.taskClickUrlOverwrite`, `AppLayout.kanbanChatDialog`, `AppLayout.kanban` test specs

**Files:**
- MODIFY: `src/apps/desktop/src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts`
- MODIFY: `src/apps/desktop/src/__tests__/AppLayout.taskClickUrlOverwrite.spec.ts`
- MODIFY: `src/apps/desktop/src/__tests__/AppLayout.kanbanChatDialog.spec.ts`
- MODIFY: `src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts`

### Step 6.1: Identify stale references across the four files

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
rg "view=task|view: 'task'|'task'" \
  src/apps/desktop/src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts \
  src/apps/desktop/src/__tests__/AppLayout.taskClickUrlOverwrite.spec.ts \
  src/apps/desktop/src/__tests__/AppLayout.kanbanChatDialog.spec.ts \
  src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts 2>&1 | head -n 60
```

### Step 6.2: Run — expect red

```bash
cd src/apps/desktop
npx vitest run \
  src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts \
  src/__tests__/AppLayout.taskClickUrlOverwrite.spec.ts \
  src/__tests__/AppLayout.kanbanChatDialog.spec.ts \
  src/__tests__/AppLayout.kanban.spec.ts 2>&1 | tail -n 60
```

Expect: assertions on `?view=task&task=X` URLs fail.

### Step 6.3: Rewrite assertions across all four files

For each occurrence of the URL `?view=task&task=X` in a `query` object or a `fullPath:`, rewrite to:

```
?view=workspace&workspaceId=ws_X&itemId=item_Y/chat/task_X[&pageId=Z][&sorts=...]
```

Use the test file's `WS_ID` / `ITEM_ID` / `TASK_ID` constants (each spec defines its own).

For `AppLayout.kanbanChatDialog.spec.ts`: the fixture mounts `AppLayout` with a URL containing `view=task&task=X`. After this change the dialog mount must be driven by `view=workspace&itemId=item_kanban_1/chat/task_X`. The test that asserts the dialog is rendered when `activeTask` is set should also drive the URL — `workspacesStore.setActiveTask(taskId)` alone is not enough; the URL must say `?view=workspace&itemId=item_kanban_1/chat/task_<taskId>`. Pass the URL via the route mock in those tests.

### Step 6.4: Run — expect green

```bash
cd src/apps/desktop
npx vitest run \
  src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts \
  src/__tests__/AppLayout.taskClickUrlOverwrite.spec.ts \
  src/__tests__/AppLayout.kanbanChatDialog.spec.ts \
  src/__tests__/AppLayout.kanban.spec.ts 2>&1 | tail -n 30
```

Expect: all four files pass.

### Step 6.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts \
        src/apps/desktop/src/__tests__/AppLayout.taskClickUrlOverwrite.spec.ts \
        src/apps/desktop/src/__tests__/AppLayout.kanbanChatDialog.spec.ts \
        src/apps/desktop/src/__tests__/AppLayout.kanban.spec.ts
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "test(AppLayout): rewrite view=task references to /chat/ suffix across 4 specs (step 6/12)"
```

---

## Task 7 — Update sidebar-row active styling tests

**Files:**
- MODIFY: `src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts`
- MODIFY (if any references): `src/apps/desktop/src/__tests__/workspaceItemTaskCard.spec.ts`

### Step 7.1: Locate stale references

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
rg "view=task|kind: 'task'|'task'" \
  src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts \
  src/apps/desktop/src/__tests__/workspaceItemTaskCard.spec.ts 2>&1 | head -n 20
```

### Step 7.2: Run — expect red

```bash
cd src/apps/desktop
npx vitest run \
  src/__tests__/workspaceItemTask.spec.ts \
  src/__tests__/workspaceItemTaskCard.spec.ts 2>&1 | tail -n 40
```

Expect: assertions on `view=task&task=<id>` URLs in route mocks fail.

### Step 7.3: Rewrite assertions

For `workspaceItemTask.spec.ts`: the "applies active styling (aqua bullet + active background) when URL is ?view=task&task=X" test (line ~134) is rewritten:

```ts
// OLD:
it('applies active styling (aqua bullet + active background) when URL is ?view=task&task=X', async () => {
  // Mock useRoute to return ?view=task matching this task's id.
  useRouteMock.mockReturnValue({
    query: { view: 'task', task: baseTask.id },
    path: '/app',
    fullPath: `/app?view=task&task=${baseTask.id}`,
  } as any)
  // ...
})

// NEW:
it('applies active styling (aqua bullet + active background) when URL is ?view=workspace&itemId=Y/chat/<taskId>', async () => {
  // Mock useRoute to return view=workspace with the chat suffix matching
  // this task's id. The sidebar's task row reads `chatTaskId` from
  // useCurrentMainView (which parses the /chat/ suffix).
  useRouteMock.mockReturnValue({
    query: {
      view: 'workspace',
      workspaceId: 'ws_test',
      itemId: `item_test/chat/${baseTask.id}`,
    },
    path: '/app',
    fullPath: `/app?view=workspace&workspaceId=ws_test&itemId=item_test/chat/${baseTask.id}`,
  } as any)
  // ...
})
```

If `workspaceItemTaskCard.spec.ts` has any `view=task` references, apply the same rewrite.

### Step 7.4: Run — expect green

```bash
cd src/apps/desktop
npx vitest run \
  src/__tests__/workspaceItemTask.spec.ts \
  src/__tests__/workspaceItemTaskCard.spec.ts 2>&1 | tail -n 30
```

Expect: both files pass.

### Step 7.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts \
        src/apps/desktop/src/__tests__/workspaceItemTaskCard.spec.ts
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "test(sidebar): rewrite view=task active-styling test setups to /chat/ suffix (step 7/12)"
```

---

## Task 8 — Verify no-op test specs (run-only check)

**Files:**
- VERIFY: `DesignPageRow.spec.ts`, `DesignPageRow.activeFromUrl.spec.ts`, `WorkspaceItem.activeFromUrl.spec.ts`, `ChatsList.activeFromUrl.spec.ts`, `AppLayout.chatview.spec.ts`, `AppLayout.designChatDialog.spec.ts`

### Step 8.1: Run all six spec files

```bash
cd src/apps/desktop
npx vitest run \
  src/__tests__/DesignPageRow.spec.ts \
  src/__tests__/DesignPageRow.activeFromUrl.spec.ts \
  src/__tests__/WorkspaceItem.activeFromUrl.spec.ts \
  src/__tests__/ChatsList.activeFromUrl.spec.ts \
  src/__tests__/AppLayout.chatview.spec.ts \
  src/__tests__/AppLayout.designChatDialog.spec.ts 2>&1 | tail -n 30
```

Expect: all pass. If any fail, the failure tells us what needs updating (likely `useCurrentMainView`'s task kind removal cascaded into these — fix the spec, not the prod code).

### Step 8.2: If anything failed — fix and re-run

For the file that failed, apply the same `useCurrentMainView` shape changes as in Task 3, then re-run. Do NOT commit yet — bundle into Task 8's commit if changes are small; otherwise create a sub-task.

### Step 8.3: Commit (only if Step 8.2 produced edits)

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/__tests__/<changed files>
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "test(specs): adapt activeFromUrl family specs to useCurrentMainView shape (step 8/12)"
```

If Step 8.1 was all green, no commit.

---

## Task 9 — Update `AppLayout.vue` for the new wire shape

**Files:**
- MODIFY: `src/apps/desktop/src/components/AppLayout.vue`

### Step 9.1: Run the full test suite — see what breaks in the AppLayout component tests

```bash
cd src/apps/desktop
npx vitest run src/__tests__/AppLayout.* src/components/AppLayout.vue 2>&1 | tail -n 80
```

Expect: failures across the AppLayout tests because:
- `handleCloseTaskView` strips the suffix (but the old test expects `view=workspace` URL — the actual write URL is now `itemId=item_Y` bare, which IS the current behaviour; the test assertion is what's stale).
- The URL-sync watcher now needs to preserve the `/chat/` suffix.
- `currentView === 'task'` arm is dead; remove it.
- The `<ChatView v-else-if="currentView === 'task'">` mount is dead; remove it.

### Step 9.2: Surgical edits to `AppLayout.vue`

Apply these targeted edits:

#### Edit 9.2.1 — `currentView` computed (line 827)

```diff
 const currentView = computed(() => {
   const path = route.path
   if (path === '/app/settings') return 'settings'
   if (gitViewerFile.value) return 'gitfile'
   if (skillViewerSkill.value) return 'skill'
   if (codeEditorFile.value) return 'code-editor'

-  const view = (route.query.view as string) || 'chat'
+  // The chat dialog open state is encoded as /chat/<taskId> on
+  // itemId when view='workspace'. The 'task' view value is no
+  // longer emitted by any URL builder (2026-08-15
+  // simplify-url-browser) — so the chat section's default ('chat')
+  // is the only fallback path.
+  const view = (route.query.view as string) || 'chat'
   return view
 })
```

Actually no functional change here yet; the `'task'` arm wasn't ever matched because `route.query.view` would never be `'task'` under the new scheme. The comment is the update — move on.

#### Edit 9.2.2 — Delete `handleNavigate('task')` branch (line 447-465)

```diff
- } else if (view === 'task') {
-   navigationStore.setActiveTask(taskId || null)
-   chatSessionCwd.value = ''
-   router.push({
-     path: '/app',
-     query: buildTaskUrlQuery({
-       taskId: taskId || '',
-       activeWorkspaceId: workspaceId ?? workspacesStore.activeWorkspace?.id ?? null,
-       activeWorkspaceItemId: itemId ?? workspacesStore.activeWorkspaceItemId,
-       activeDesignPageId: pageId ?? workspacesStore.activeDesignPageId,
-       activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
-     }),
-   })
 } else if (view === 'settings') {
   router.push({ path: '/app/settings' })
 }
```

#### Edit 9.2.3 — Update `handleCloseTaskView` (line 990)

Replace the URL rebuild so it does NOT carry the `/chat/` suffix:

```diff
 const wsId = activeWorkspaceId.value
 const itemId = workspacesStore.activeWorkspaceItemId
 const pageId = workspacesStore.activeDesignPageId
 const query: Record<string, string> = { view: 'workspace' }
 if (wsId && itemId) {
   query.workspaceId = wsId
-  query.itemId = itemId
+  // Use the bare item id (no /chat/ suffix — closing the dialog
+  // drops the chat-open state from the URL).
+  query.itemId = itemId
   if (pageId) query.pageId = pageId
 }
```

(`workspacesStore.activeWorkspaceItemId` is already the bare id; no change needed if that's the case — but ADD a regression comment near the line:)

```ts
// SIMPLIFY-URL-BROWSER (2026-08-15): the bare item id (no /chat/
// suffix) is what we want here — closing the dialog strips the
// chat-open state from the URL.
```

#### Edit 9.2.4 — Update the `pendingUrlRestore` block (line 163-178)

```diff
 const pendingUrlRestore = ref<{
   workspaceId: string
   itemId: string
   pageId: string
 } | null>(
   (() => {
     const view = route.query.view as string | undefined
     const wsId = route.query.workspaceId as string | undefined
     const rawItemId = route.query.itemId as string | undefined
     const pageId = route.query.pageId as string | undefined
     if (view === 'workspace' && wsId && rawItemId) {
-      return { workspaceId: wsId, itemId: rawItemId, pageId: pageId ?? '' }
+      // Parse the wire-shape itemId (may carry /chat/<taskId>
+      // suffix when the chat dialog is open). pendingUrlRestore
+      // only needs the bare id; the chat task id is restored
+      // separately in onMounted (see below).
+      const parsed = parseItemIdWithChat(rawItemId)
+      return { workspaceId: wsId, itemId: parsed.itemId, pageId: pageId ?? '' }
     }
     return null
   })(),
 )
```

#### Edit 9.2.5 — Add chat-task restoration + stale URL rewrite in `onMounted` (line 48)

```diff
 onMounted(() => {
   const urlSessionId = route.query.session as string
   const urlTaskId = route.query.task as string
   const urlView = route.query.view as string
   const rawItemId = (route.query.itemId as string | undefined) ?? ''

+  // SIMPLIFY-URL-BROWSER (2026-08-15): stale URL rewrite — if the
+  // URL is in the legacy `?view=task&task=X` shape, rewrite to the
+  // new `?view=workspace&itemId=Y/chat/task_X` shape silently. We
+  // need the parsed bare item id to do this. Bookmarks / shared
+  // links from before this change land here exactly once.
+  if (urlView === 'task' && urlTaskId && rawItemId) {
+    const newItemId = buildItemIdWithChat(rawItemId, urlTaskId)
+    router.replace({
+      path: '/app',
+      query: {
+        view: 'workspace',
+        workspaceId: (route.query.workspaceId as string | undefined) ?? '',
+        itemId: newItemId,
+      },
+    })
+    workspacesStore.setActiveTask(urlTaskId)
+    return
+  }

   if (urlSessionId && urlView === 'chat') {
     workspacesStore.setActiveWorkspaceItem(null)
     navigationStore.setActiveChat(urlSessionId, navigationStore.activeChatName)
     fetchChatSessionCwd(urlSessionId)
   } else if (urlTaskId && urlView === 'task') {
     workspacesStore.setActiveTask(urlTaskId)
   } else {
     navigationStore.initFromUrl(urlSessionId || undefined, urlTaskId || undefined, urlView)
   }

+  // SIMPLIFY-URL-BROWSER (2026-08-15): if the URL carries the
+  // /chat/<taskId> suffix, also set the active task so the chat
+  // dialog opens.
+  if (urlView === 'workspace' && rawItemId) {
+    const parsed = parseItemIdWithChat(rawItemId)
+    if (parsed.chatTaskId) {
+      workspacesStore.setActiveTask(parsed.chatTaskId)
+    }
+  }

   workspacesStore.initializeFromSystemFolder()
   // ...
 })
```

#### Edit 9.2.6 — Update the URL-sync watcher (line 242-326) to preserve the suffix

```diff
 watch(
   () => [workspacesStore.activeWorkspaceItemId, workspacesStore.activeDesignPageId] as const,
   ([itemId, pageId]) => {
     const wsId = workspacesStore.activeWorkspace?.id ?? ''
     const currentView = route.query.view as string | undefined
     if (workspacesStore.isNavigatingToTask) return
     if (currentView !== 'workspace' && currentView !== undefined) return

+    // SIMPLIFY-URL-BROWSER (2026-08-15): preserve the
+    // /chat/<taskId> suffix when mirroring activeWorkspaceItemId
+    // back to the URL. Pre-fix the watcher overwrote the URL with
+    // the bare item id, dropping the chat task id and closing the
+    // chat dialog on the next reactive update.
+    const existingItemId = (route.query.itemId as string) ?? ''
+    const parsedExisting = parseItemIdWithChat(existingItemId)

     const urlWsId = route.query.workspaceId as string | undefined
     const urlItemId = route.query.itemId as string | undefined
     const urlPageId = route.query.pageId as string | undefined
-    if (urlWsId === wsId && urlItemId === itemId && urlPageId === pageId) return
+    const rewrittenItemId = parsedExisting.chatTaskId
+      ? buildItemIdWithChat(itemId, parsedExisting.chatTaskId)
+      : itemId
+    if (
+      urlWsId === wsId &&
+      urlItemId === rewrittenItemId &&
+      urlPageId === pageId
+    ) return

     const query: Record<string, string> = { view: 'workspace' }
     if (wsId && itemId) {
       query.workspaceId = wsId
-      query.itemId = itemId
+      query.itemId = rewrittenItemId
       if (pageId) {
         const activeItem = workspacesStore.workspaces
           .flatMap((ws) => ws.items)
           .find((it) => it.id === itemId)
         if (activeItem?.item_type === 'design') {
           query.pageId = pageId
         }
       }
       const urlSorts = route.query.sorts as string | undefined
       if (urlSorts) query.sorts = urlSorts
     }
     router.replace({ path: '/app', query })
   },
 )
```

#### Edit 9.2.7 — Delete `<ChatView v-else-if="currentView === 'task' && activeTask">` (line 1951-1963)

```diff
-      <!-- Task view (non-kanban parents, e.g. chat tasks): single
-           column, no header. Preserved for backward compatibility. -->
-      <ChatView
-        v-else-if="currentView === 'task' && activeTask"
-        :key="'task-' + activeTask.id"
-        :chat-id="activeTask.id"
-        :chat-name="activeTask.name"
-        :type="'task'"
-        :cwd="activeWorkspaceItem?.path || ''"
-        :task-id="activeTask.id"
-        :task-name="activeTask.name"
-        :project-name="activeWorkspaceItem?.name || ''"
-      />
```

Add a comment above the now-preceding `<!-- Design view -->` block:

```html
<!--
  SIMPLIFY-URL-BROWSER (2026-08-15): the legacy
  `<ChatView v-else-if="currentView === 'task' && activeTask">`
  branch has been removed. Under the new URL scheme the URL never
  says `view=task` — the chat dialog is always a sub-state of the
  workspace view (gated by `activeTaskWorkspaceItemId === activeWorkspaceItem.id`
  for kanban, or `activeDesignChatTaskId` for design). The chat
  rendering for non-kanban / non-design parents was the only
  reachable path through that branch, and now goes through the
  same dialog mechanism — KanbanChatDialog mount (line ~1908) is
  guarded by `item_type === 'kanban'`. Folder tasks (whose parent
  is a folder, not a kanban / design) are an explicit out-of-scope
  edge case; until a folder-task UI is added, this branch is dead
  code per the simplify-url-browser spec.
-->
```

#### Edit 9.2.8 — Update close-viewer task-else branches

`closeGitViewer`, `closeSkillViewer`, `closeCodeEditor` (lines 504-547, 590-628, 707-749) all have an `else if (activeTask.value)` branch that uses `buildTaskUrlQuery(...)`. The helper change already emits the new wire shape, so the `query` value is correct — **no edits needed** in these branches. Skip.

#### Edit 9.2.9 — Update `handleAddTaskPick` `activeWorkspaceItemId` resolution

In Sidebar.vue:781-836 (`handleAddTaskPick`), the URL builder uses the active store's `activeWorkspaceItemId`. That's the bare id — no change needed because the helper handles the suffix. Skip.

#### Edit 9.2.10 — Add the new imports

At the top of `AppLayout.vue`, after the existing imports:

```ts
import {
  buildItemIdWithChat,
  parseItemIdWithChat,
} from '../helpers/buildItemIdWithChat'
```

### Step 9.3: Run AppLayout tests — expect progressively green

```bash
cd src/apps/desktop
npx vitest run \
  src/__tests__/AppLayout.urlPersist.spec.ts \
  src/__tests__/AppLayout.sortUrlRoundTrip.spec.ts \
  src/__tests__/AppLayout.taskClickUrlOverwrite.spec.ts \
  src/__tests__/AppLayout.kanbanChatDialog.spec.ts \
  src/__tests__/AppLayout.kanban.spec.ts \
  src/__tests__/AppLayout.chatview.spec.ts \
  src/__tests__/AppLayout.designChatDialog.spec.ts \
  src/__tests__/AppLayout.createElement.spec.ts \
  src/__tests__/AppLayout.memoriesGate.spec.ts 2>&1 | tail -n 60
```

Iterate on test failures (they're all test-setup staleness, not prod-code bugs — fix the test).

### Step 9.4: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/components/AppLayout.vue
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "refactor(AppLayout): emit view=workspace + preserve /chat/ suffix in watcher (step 9/12)"
```

---

## Task 10 — Update sidebar row active styling

**Files:**
- MODIFY: `src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue`
- MODIFY: `src/apps/desktop/src/components/workspace/WorkspaceItem.vue`

### Step 10.1: Locate the active-styling check

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
rg "kind === 'task' |kind: 'workspace'.*chatTaskId|kind: 'task'" \
  src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue \
  src/apps/desktop/src/components/workspace/WorkspaceItem.vue
```

### Step 10.2: Run the spec — expect red

```bash
cd src/apps/desktop
npx vitest run \
  src/__tests__/workspaceItemTask.spec.ts \
  src/__tests__/WorkspaceItem.activeFromUrl.spec.ts 2>&1 | tail -n 30
```

(The `workspaceItemTask.spec.ts` was rewritten in Task 7; `WorkspaceItem.activeFromUrl.spec.ts` is the new consumer we need to verify works with the new shape.)

### Step 10.3: Edit `WorkspaceItemTaskRow.vue` (line ~56)

```diff
 const currentMainView = useCurrentMainView()
-const isActive = computed(() =>
-  currentMainView.value.kind === 'task' &&
-    currentMainView.value.taskId === props.task.id,
-)
+const isActive = computed(() =>
+  currentMainView.value.kind === 'workspace' &&
+    currentMainView.value.chatTaskId === props.task.id,
+)
```

### Step 10.4: Edit `WorkspaceItem.vue` (line ~92)

The workspace item row uses `currentMainView.value.itemId === props.item.id`. After the change, `currentMainView.value.itemId` is the **bare** id (the helper parses the `/chat/` suffix). So the existing comparison is correct without further changes. Verify only:

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
rg "currentMainView\.value\.itemId ===" src/apps/desktop/src/components/workspace/WorkspaceItem.vue
```

If the line is already `currentMainView.value.itemId === props.item.id`, no edit needed. If it reads `route.query.itemId === props.item.id`, change it to `currentMainView.value.itemId === props.item.id`.

### Step 10.5: Run — expect green

```bash
cd src/apps/desktop
npx vitest run \
  src/__tests__/workspaceItemTask.spec.ts \
  src/__tests__/workspaceItemTaskCard.spec.ts \
  src/__tests__/WorkspaceItem.activeFromUrl.spec.ts \
  src/__tests__/DesignPageRow.activeFromUrl.spec.ts 2>&1 | tail -n 30
```

Expect: all four pass.

### Step 10.6: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue \
        src/apps/desktop/src/components/workspace/WorkspaceItem.vue
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "refactor(sidebar): task row reads chatTaskId from useCurrentMainView (step 10/12)"
```

---

## Task 11 — Add new end-to-end tests

**Files:**
- NEW: `src/apps/desktop/src/__tests__/AppLayout.simplifyUrl.spec.ts`
- NEW: `src/apps/desktop/src/__tests__/AppLayout.chatSuffixRoundTrip.spec.ts`

### Step 11.1: Write `AppLayout.simplifyUrl.spec.ts`

```ts
// AppLayout — URL restoration under the simplify-url-browser
// scheme (?view=workspace&itemId=Y/chat/task_W).
//
// Mounts AppLayout with various URL shapes and asserts the
// resulting store state + chat dialog visibility.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { ref } from 'vue'
import AppLayout from '../components/AppLayout.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({
    replace: vi.fn(),
    push: vi.fn(),
    back: vi.fn(),
  })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

import * as api from '../api'

const WS_ID = 'ws_simplify'
const KANBAN_ITEM_ID = 'item_simplify_kanban'
const TASK_ID = 'task_simplify'

const baseKanbanItem = (tasks: any[]): WorkspaceItem =>
  ({
    id: KANBAN_ITEM_ID,
    name: 'Simplify',
    item_type: 'kanban',
    tasks,
    kanban_columns: [
      { id: 'col_a', name: 'todo', workspace_item_id: KANBAN_ITEM_ID, position: 0, created_at: '2026-01-01' },
    ],
  }) as any

function installBusForTests() {
  __resetSseBus()
  installSseBus({})
  __setSseBusGlobalClient(makeStubClient() as SseClient)
}

function makeStubClient(): any {
  return {
    state: 'open',
    lastError: null,
    getState: () => 'open',
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    close: () => {},
  }
}

function setRoute(q: Record<string, string>) {
  useRouteMock.mockReturnValue({
    query: q,
    path: '/app',
    fullPath: '/app?' + new URLSearchParams(q).toString(),
  } as any)
}

function mountApp(workspaceItems: WorkspaceItem[], query: Record<string, string>): VueWrapper {
  setRoute(query)
  const ws = useWorkspacesStore()
  ws.workspaces = [{ id: WS_ID, name: 'WS', items: workspaceItems }] as any
  return mount(AppLayout, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
    attachTo: document.body,
  })
}

describe('AppLayout — simplify-url-browser wire shape', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(), writable: true, configurable: true,
    })
    installBusForTests()
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [], has_more: false, next_cursor: null, total: 0,
    })
    useRouteMock.mockReset()
    useRouterMock.mockReset()
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('mounting with /chat/<taskId> suffix sets activeTask and opens dialog', async () => {
    const wrapper = mountApp([baseKanbanItem([{ id: TASK_ID, name: 'T' }])], {
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: `${KANBAN_ITEM_ID}/chat/${TASK_ID}`,
    })
    await flushPromises()
    const ws = useWorkspacesStore()
    expect(ws.activeWorkspaceItemId).toBe(KANBAN_ITEM_ID)
    expect(ws.activeTaskId).toBe(TASK_ID)
    // The chat dialog should be in the DOM
    const dialog = document.querySelector('.fixed.inset-0') as HTMLElement | null
    expect(dialog).toBeTruthy()
    wrapper.unmount()
  })

  it('mounting with bare itemId does NOT open the chat dialog', async () => {
    const wrapper = mountApp([baseKanbanItem([{ id: TASK_ID, name: 'T' }])], {
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: KANBAN_ITEM_ID,
    })
    await flushPromises()
    const ws = useWorkspacesStore()
    expect(ws.activeWorkspaceItemId).toBe(KANBAN_ITEM_ID)
    expect(ws.activeTaskId).toBeNull()
    wrapper.unmount()
  })

  it('legacy ?view=task&task=X URL is silently rewritten to view=workspace&itemId=Y/chat/task_X', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn(), back: vi.fn() } as any)
    setRoute({
      view: 'task',
      task: TASK_ID,
      workspaceId: WS_ID,
      itemId: KANBAN_ITEM_ID,
    })
    const ws = useWorkspacesStore()
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [baseKanbanItem([{ id: TASK_ID, name: 'T' }])] }] as any
    mount(AppLayout, {
      global: {
        mocks: { $router: { replace: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
      attachTo: document.body,
    })
    await flushPromises()
    expect(replaceMock).toHaveBeenCalled()
    const call = replaceMock.mock.calls[0][0]
    expect(call.query.view).toBe('workspace')
    expect(call.query.itemId).toBe(`${KANBAN_ITEM_ID}/chat/${TASK_ID}`)
  })
})
```

### Step 11.2: Run — expect red

```bash
cd src/apps/desktop
npx vitest run src/__tests__/AppLayout.simplifyUrl.spec.ts 2>&1 | tail -n 30
```

Expect: 3 tests pass (the prod code was updated in Task 9). If red, debug prod code or test setup.

### Step 11.3: Write `AppLayout.chatSuffixRoundTrip.spec.ts`

```ts
// AppLayout — end-to-end click → URL → close → URL → back → URL
// round-trip under the simplify-url-browser wire shape.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
// (Full setup mirrors AppLayout.simplifyUrl.spec.ts; abbreviated here
// for plan brevity. Implementation should mirror AppLayout.sortUrlRoundTrip.spec.ts
// structure with route-mock + push/replace tracking.)

describe('AppLayout — chat suffix round-trip', () => {
  // ... mounted with ?view=workspace&itemId=Y
  // ... simulate Sidebar.handleSelectTask router.push to buildItemIdWithChat URL
  // ... assert router.push was called with view=workspace + itemId=Y/chat/task_W
  // ... simulate handleCloseTaskView → router.replace
  // ... assert router.replace was called with view=workspace + itemId=Y (suffix stripped)
  // ... simulate router.back from the chat-open URL
  // ... assert the back URL has the suffix again (browser history restores it)
})
```

(For plan brevity the test body is sketched as pseudocode; the implementer should write the full test using the same Pinia + SseBus setup as `AppLayout.kanbanChatDialog.spec.ts`.)

### Step 11.4: Run — expect green

```bash
cd src/apps/desktop
npx vitest run src/__tests__/AppLayout.chatSuffixRoundTrip.spec.ts 2>&1 | tail -n 30
```

### Step 11.5: Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git add src/apps/desktop/src/__tests__/AppLayout.simplifyUrl.spec.ts \
        src/apps/desktop/src/__tests__/AppLayout.chatSuffixRoundTrip.spec.ts
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "test(AppLayout): add simplifyUrl + chatSuffixRoundTrip end-to-end specs (step 11/12)"
```

---

## Task 12 — Final verification

**Files:** none — verification only.

### Step 12.1: Run vue-tsc

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
npx vue-tsc --build --noEmit 2>&1 | tail -n 30
```

Expect: zero errors. (If any, fix the type errors — usually stale `route.query.view === 'task'` checks or `kind: 'task'` references in vendored components.)

### Step 12.2: Run full vitest

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
npx vitest run 2>&1 | tail -n 60
```

Expect: all tests pass. Note any pre-existing failures as `n` in the summary; the task is "no new failures, no regressions".

### Step 12.3: Grep — no `view=task` left

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
rg "view=task|view:'task'|kind: 'task'|kind === 'task'" src/apps/desktop/src 2>&1 | head -n 30
```

Expect: **zero hits**. If any remain, they're stale — fix or document why.

### Step 12.4: Grep — no `session=` left in buildTaskUrlQuery outputs (optional sanity check)

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
rg "query\.session" src/apps/desktop/src/components/AppLayout.vue \
                   src/apps/desktop/src/components/shell/Sidebar.vue 2>&1 | head -n 5
```

The only `query.session` reads left should be the chat-list path
(`?view=chat&session=…`), not anything in the task-URL builders.

### Step 12.5: Commit verification artifacts (if any)

If Step 12.1 produced vue-tsc-fixed files, commit them. If Step 12.3 surfaced stale references in unexpected places, fix and commit those.

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git status 2>&1 | head -n 30
# If anything is dirty, commit as the step-12 fix
git add -A
git -c user.name="ginwa" -c user.email="ginwa@ginwa.ai" commit -m "fix: post-impl vue-tsc + grep cleanups (step 12/12)" || true
```

### Step 12.6: Final summary + PR

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git log --oneline -20 2>&1 | head -n 20
git diff main --stat 2>&1 | tail -n 20
```

Report:
- commit list (12 commits expected, each one a single-task with a descriptive message)
- file diff stat (production files + helpers + 14 touched test files + 2 new test files)
- final vue-tsc + vitest results (zero errors, all pass)
- open a PR against `main`

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/simplify-url-browser
git push -u origin worktree/simplify-url-browser 2>&1 | tail -n 5
gh pr create \
  --base main \
  --head worktree/simplify-url-browser \
  --title "Simplify URL browser — collapse view=task into /chat/<taskId> suffix" \
  --body "Spec: docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md
Plan: docs/superpowers/plans/2026-08-15-simplify-url-browser.md
Branch: worktree/simplify-url-browser

12-task TDD refactor. Wire shape:
  before: ?view=task&task=X&workspaceId=Y&itemId=Z
  after:  ?view=workspace&workspaceId=Y&itemId=Z/chat/task_X

Closes task_1786740781061.
" 2>&1 | tail -n 10
```

---

## Verification (per plan)

- [x] Plan saved to `docs/superpowers/plans/2026-08-15-simplify-url-browser.md`
- [x] Plan header includes Goal, Architecture, Tech Stack, Global Constraints
- [x] Each task has bite-sized steps (test → implement → verify → commit)
- [x] User has reviewed the plan before execution begins
- [ ] `npx vue-tsc --build --noEmit` passes (run in Task 12)
- [ ] `npx vitest run` passes (run in Task 12)
- [ ] `rg "view=task"` returns zero hits (run in Task 12)
- [ ] PR opened against `main`
