# Sidebar: Single Active State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure at most one row in the sidebar is ever styled as "active" at a time, and that row always corresponds to what the main content area is currently showing (per URL).

**Architecture:** Drive sidebar active state from the URL via a new `useCurrentMainView` composable. Each sidebar component asks "am I the current view?" against the composable. Drop the confused `--semantic-active-bg` background from expanded workspaces (open ≠ active). Add a 2px violet left accent bar to the single active row for unambiguous visual signal.

**Tech Stack:** Vue 3, Pinia, TypeScript, vue-router, vitest. Frontend-only — no backend, no migration, no Zig changes.

**Spec:** `docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md`

## Global Constraints

- **CRITICAL**: never kill port 8081 — use 8080 for local smoke (N/A here, frontend only).
- **CRITICAL**: every change must work on Linux + macOS + Windows. Frontend-only so this is automatic.
- **CRITICAL**: NO static-contract tests (user rule 2026-07-29). All new tests are behavioural.
- **CRITICAL**: do not touch `.pabrik/agents/<name>/PABRIK.md`. Only root `pabrik-frontend-patterns` / project memory files.
- File paths: `src/apps/desktop/src/composables/useCurrentMainView.ts` (new); `src/apps/desktop/src/components/{shell,workspace,views}/*.vue` (modified); `src/apps/desktop/src/__tests__/*` (new + updated).
- Pre-commit: `cd src/apps/desktop && bun run build && bunx vitest run`.

## File Structure

| File | Change |
|---|---|
| `src/apps/desktop/src/composables/useCurrentMainView.ts` | NEW — URL-derived `currentMainView` computed |
| `src/apps/desktop/src/composables/useCurrentMainView.spec.ts` | NEW — 6 behavioural tests |
| `src/apps/desktop/src/components/views/ChatsList.vue` | Chat row active → URL-driven |
| `src/apps/desktop/src/components/workspace/WorkspaceItem.vue` | Item row active → URL-driven |
| `src/apps/desktop/src/components/workspace/DesignPageRow.vue` | Page row active → URL-driven |
| `src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue` | Task row active → URL-driven |
| `src/apps/desktop/src/components/workspace/WorkspaceList.vue` | Expanded workspace → no active bg; add accent bar via CSS |
| `src/apps/desktop/src/components/shell/Sidebar.vue` | (no changes if not needed; verify after step 2) |
| `src/apps/desktop/src/__tests__/ChatsList.activeFromUrl.spec.ts` | NEW — 4 behavioural tests |
| `src/apps/desktop/src/__tests__/WorkspaceItem.activeFromUrl.spec.ts` | NEW — 4 behavioural tests |
| `src/apps/desktop/src/__tests__/DesignPageRow.activeFromUrl.spec.ts` | NEW — 4 behavioural tests |
| `src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts` | UPDATE existing active test to URL-driven |
| `src/apps/desktop/src/__tests__/WorkspaceList.expandedNoActiveBg.spec.ts` | NEW — 2 behavioural tests |
| `src/apps/desktop/src/__tests__/sidebarSingleActive.spec.ts` | NEW — E2E test: exactly one row active |

---

## Task 1: Create `useCurrentMainView` composable (RED → GREEN)

**Files:**
- CREATE: `src/apps/desktop/src/composables/useCurrentMainView.ts`
- CREATE: `src/apps/desktop/src/composables/useCurrentMainView.spec.ts`

### Step 1.1 — Write the failing test file

```ts
// src/apps/desktop/src/composables/useCurrentMainView.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { reactive, nextTick } from 'vue'
import { useCurrentMainView } from './useCurrentMainView'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

function mockRoute(query: Record<string, string>) {
  // `reactive` so post-mount mutations trigger the computed.
  const obj = reactive({ query, path: '/app', fullPath: '/app' })
  useRouteMock.mockReturnValue(obj as any)
  return obj
}

describe('useCurrentMainView', () => {
  beforeEach(() => { useRouteMock.mockReset() })

  it('returns chat view when URL is ?view=chat&session=X', () => {
    mockRoute({ view: 'chat', session: 'session_abc' })
    let v: ReturnType<typeof useCurrentMainView> | undefined
    // Composable needs a component context; use a fake `currentInstance`-less
    // call by reading the route directly via the mock, then asserting the
    // composable's return shape equivalent.
    // Simpler: we test the route-derivation logic by minting a tiny harness
    // that calls useRoute() inside a setup-like function.
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({ kind: 'chat', sessionId: 'session_abc' })
  })

  it('returns task view when URL is ?view=task&task=X', () => {
    mockRoute({ view: 'task', task: 'task_xyz' })
    let v: ReturnType<typeof useCurrentMainView> | undefined
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({
      kind: 'task',
      taskId: 'task_xyz',
      workspaceId: undefined,
      itemId: undefined,
    })
  })

  it('returns workspace view with pageId when URL is ?view=workspace&itemId=Y&pageId=Z', () => {
    mockRoute({ view: 'workspace', workspaceId: 'ws_1', itemId: 'item_design', pageId: 'page_42' })
    let v: ReturnType<typeof useCurrentMainView> | undefined
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({
      kind: 'workspace',
      workspaceId: 'ws_1',
      itemId: 'item_design',
      pageId: 'page_42',
    })
  })

  it('returns none when URL is empty', () => {
    mockRoute({})
    let v: ReturnType<typeof useCurrentMainView> | undefined
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
  })

  it('returns none when URL is a non-content view (settings)', () => {
    mockRoute({ view: 'settings' })
    let v: ReturnType<typeof useCurrentMainView> | undefined
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v.value).toEqual({ kind: 'none' })
  })

  it('reacts to URL changes (computed re-runs when route.query mutates)', async () => {
    const route = mockRoute({})
    let v: ReturnType<typeof useCurrentMainView> | undefined
    function setup() { v = useCurrentMainView() }
    setup()
    expect(v!.value).toEqual({ kind: 'none' })
    route.query = { view: 'chat', session: 'session_now' }
    await nextTick()
    expect(v!.value).toEqual({ kind: 'chat', sessionId: 'session_now' })
  })
})
```

### Step 1.2 — Run the test, confirm it fails

```bash
cd src/apps/desktop && bunx vitest run src/composables/useCurrentMainView.spec.ts 2>&1 | tail -20
```
Expect: file not found (composable doesn't exist yet).

### Step 1.3 — Implement the composable

```ts
// src/apps/desktop/src/composables/useCurrentMainView.ts
import { computed, type ComputedRef } from 'vue'
import { useRoute } from 'vue-router'

/**
 * The single source of truth for "what is the main content area
 * currently showing?". Derived from the URL — never from store
 * flags that can drift.
 *
 * The sidebar components consume this to decide which row (if any)
 * is "active". Exactly one row in the sidebar should be active at
 * any time, and that row must match the kind + id below.
 *
 * Why the URL and not the store?
 *   - The URL is the only state that survives a page refresh, a
 *     deep link, and the browser back/forward buttons. If the
 *     sidebar's active state is derived from the URL, the active
 *     row is always consistent with the main content area — no
 *     store flag can drift.
 *   - Multiple store flags (activeTaskId, activeWorkspaceItemId,
 *     activeDesignPageId, navigationStore.sessionId) are
 *     nearly-always-mutually-exclusive in practice but not
 *     enforced. Deriving from the URL guarantees mutual exclusivity.
 *
 * Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md
 */
export type CurrentMainView =
  | { kind: 'chat'; sessionId: string }
  | { kind: 'task'; taskId: string; workspaceId?: string; itemId?: string }
  | { kind: 'workspace'; workspaceId?: string; itemId: string; pageId?: string }
  | { kind: 'none' }

export function useCurrentMainView(): ComputedRef<CurrentMainView> {
  const route = useRoute()
  return computed<CurrentMainView>(() => {
    const q = route.query as Record<string, string>
    const view = q.view
    if (view === 'chat') {
      if (typeof q.session === 'string' && q.session.length > 0) {
        return { kind: 'chat', sessionId: q.session }
      }
      return { kind: 'none' }
    }
    if (view === 'task') {
      if (typeof q.task === 'string' && q.task.length > 0) {
        return {
          kind: 'task',
          taskId: q.task,
          workspaceId: typeof q.workspaceId === 'string' ? q.workspaceId : undefined,
          itemId: typeof q.itemId === 'string' ? q.itemId : undefined,
        }
      }
      return { kind: 'none' }
    }
    if (view === 'workspace') {
      if (typeof q.itemId === 'string' && q.itemId.length > 0) {
        return {
          kind: 'workspace',
          workspaceId: typeof q.workspaceId === 'string' ? q.workspaceId : undefined,
          itemId: q.itemId,
          pageId: typeof q.pageId === 'string' && q.pageId.length > 0 ? q.pageId : undefined,
        }
      }
      return { kind: 'none' }
    }
    return { kind: 'none' }
  })
}
```

### Step 1.4 — Run the test, confirm it passes

```bash
cd src/apps/desktop && bunx vitest run src/composables/useCurrentMainView.spec.ts 2>&1 | tail -20
```
Expect: 6/6 pass.

### Step 1.5 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
git add src/apps/desktop/src/composables/useCurrentMainView.ts src/apps/desktop/src/composables/useCurrentMainView.spec.ts
git commit -m "feat(sidebar): useCurrentMainView composable

Derive 'what is the main content area showing' from the URL. Returns
one of {chat, task, workspace, none}. Sidebar components consume this
to decide which row is active.

Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md"
```

---

## Task 2: Wire `useCurrentMainView` into ChatsList (chat row active)

**Files:**
- MODIFIED: `src/apps/desktop/src/components/views/ChatsList.vue`
- CREATE: `src/apps/desktop/src/__tests__/ChatsList.activeFromUrl.spec.ts`

### Step 2.1 — Write the failing test

```ts
// src/apps/desktop/src/__tests__/ChatsList.activeFromUrl.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, reactive, ref } from 'vue'
import { mount } from '@vue/test-utils'

import ChatsList from '../components/views/ChatsList.vue'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

function mountChatsList() {
  return mount(ChatsList, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

function pushItem(wrapper: any, session: { id: string; name: string; active: boolean }) {
  // @ts-expect-error: mutate the internal navItems ref
  wrapper.vm.navItems = [session]
}

describe('ChatsList — chat row active state from URL', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })
  afterEach(() => { vi.restoreAllMocks() })

  it('chat row is active when URL is ?view=chat&session=X (URL-driven)', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'chat_abc' },
      path: '/app',
      fullPath: '/app?view=chat&session=chat_abc',
    } as any)
    const wrapper = mountChatsList()
    await nextTick()
    pushItem(wrapper, { id: 'chat_abc', name: 'My Chat', active: false })
    await nextTick()
    // Find the chat row button by data-testid or content
    const buttons = wrapper.findAll('button')
    const chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton).toBeDefined()
    // The active bg must be applied via inline style
    expect(chatButton!.attributes('style')).toContain('--semantic-active-bg')
  })

  it('chat row is NOT active when URL is ?view=workspace (different section)', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_x' },
      path: '/app',
      fullPath: '/app?view=workspace&itemId=item_x',
    } as any)
    const wrapper = mountChatsList()
    await nextTick()
    pushItem(wrapper, { id: 'chat_abc', name: 'My Chat', active: false })
    await nextTick()
    const buttons = wrapper.findAll('button')
    const chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton).toBeDefined()
    expect(chatButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('chat row is NOT active when URL is ?view=chat&session=OTHER (different chat)', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'chat_other' },
      path: '/app',
      fullPath: '/app?view=chat&session=chat_other',
    } as any)
    const wrapper = mountChatsList()
    await nextTick()
    pushItem(wrapper, { id: 'chat_abc', name: 'My Chat', active: false })
    await nextTick()
    const buttons = wrapper.findAll('button')
    const chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton).toBeDefined()
    expect(chatButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('chat row active state reacts to URL changes mid-mount', async () => {
    const route = reactive({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    })
    useRouteMock.mockReturnValue(route as any)
    const wrapper = mountChatsList()
    await nextTick()
    pushItem(wrapper, { id: 'chat_abc', name: 'My Chat', active: false })
    await nextTick()

    // Initially no active bg
    let buttons = wrapper.findAll('button')
    let chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')

    // URL changes to chat
    route.query = { view: 'chat', session: 'chat_abc' }
    await nextTick()
    buttons = wrapper.findAll('button')
    chatButton = buttons.find((b) => b.text().includes('My Chat'))
    expect(chatButton!.attributes('style')).toContain('--semantic-active-bg')
  })
})
```

### Step 2.2 — Run the test, confirm it fails

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/ChatsList.activeFromUrl.spec.ts 2>&1 | tail -20
```
Expect: failures (the existing implementation uses `item.active` from navItems, not URL).

### Step 2.3 — Modify ChatsList.vue

The pre-existing `loadChats()` sets `active: savedSessionId === session.session_id` on each nav item. Replace that with the URL-driven check using the new composable.

In ChatsList.vue:
- Add `import { useCurrentMainView } from '../../composables/useCurrentMainView'` at the top.
- Inside `setup()`, add `const currentMainView = useCurrentMainView()`.
- In `loadChats()`, replace the line `active: savedSessionId === session.session_id` with `active: currentMainView.value.kind === 'chat' && currentMainView.value.sessionId === session.session_id`.
- In `loadMoreChats()`, the new items are always `active: false` (their ids are not in the URL). Leave that.
- In the template, also gate the inline `item.active` style on the URL-derived value. Add a small `isCurrentChat` helper:

```ts
// In loadChats, derive active from URL:
const isActive = (sessionId: string) =>
  currentMainView.value.kind === 'chat' && currentMainView.value.sessionId === sessionId
```

Then replace `active: savedSessionId === session.session_id` with `active: isActive(session.session_id)`.

In the template, the `:style` on the chat row button already binds to `item.active`. With the new `active` flag now URL-driven, the styling flows through. No template change needed.

### Step 2.4 — Run the test, confirm it passes

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/ChatsList.activeFromUrl.spec.ts 2>&1 | tail -20
```
Expect: 4/4 pass.

### Step 2.5 — Run the full ChatsList suite to catch regressions

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/ChatsList src/__tests__/ChatsList.activeFromUrl 2>&1 | tail -10
```
Expect: all pass.

### Step 2.6 — Run full test suite to surface any cross-cutting regressions

```bash
cd src/apps/desktop && bunx vitest run 2>&1 | tail -30
```
Expect: pre-existing failure count stays the same (19 baseline). No new failures.

### Step 2.7 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
git add src/apps/desktop/src/components/views/ChatsList.vue src/apps/desktop/src/__tests__/ChatsList.activeFromUrl.spec.ts
git commit -m "feat(sidebar): ChatsList chat row active state from URL

Replaces navItems[].active-derived-from-store with a URL-driven
check via the new useCurrentMainView composable. A chat row is now
active iff the URL is ?view=chat&session=<row.id> — regardless of
store flags that may have drifted.

Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md"
```

---

## Task 3: Wire `useCurrentMainView` into WorkspaceItemTaskRow (task row active)

**Files:**
- MODIFIED: `src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue`
- MODIFIED: `src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts` (update existing active test)

### Step 3.1 — Update the existing active test to be URL-driven

In `src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts`, find the test at line ~121:
```ts
it('applies active styling (aqua bullet + active background) when activeTaskId === task.id', async () => {
  const ws = useWorkspacesStore()
  ws.activeTaskId = baseTask.id
  ...
})
```

Replace it with a URL-driven version (RED — the implementation doesn't read the URL yet):

```ts
it('applies active styling (aqua bullet + active background) when URL is ?view=task&task=X', async () => {
  // Mock useRoute to return ?view=task matching this task's id.
  useRouteMock.mockReturnValue({
    query: { view: 'task', task: baseTask.id },
    path: '/app',
    fullPath: `/app?view=task&task=${baseTask.id}`,
  } as any)
  const { wrapper } = mountTask()
  const rowButton = wrapper.find('button.group\\/task')
  expect(rowButton.exists()).toBe(true)
  expect(rowButton.attributes('style')).toContain('--semantic-active-bg')
  expect(rowButton.attributes('style')).toContain('--color-aqua')
  const bullet = wrapper.find('span.w-1\\.5.h-1\\.5.rounded-full')
  expect(bullet.attributes('style')).toContain('--color-aqua')
})
```

Add the `useRouteMock` hoisted block at the top of the file (mirror `sidebarHandleSelectTaskUrl.spec.ts:57-69`).

### Step 3.2 — Run the test, confirm it fails

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/workspaceItemTask.spec.ts 2>&1 | tail -20
```
Expect: 1 failure (the updated test).

### Step 3.3 — Modify WorkspaceItemTaskRow.vue

- Add `import { useCurrentMainView } from '../../composables/useCurrentMainView'`.
- Inside `setup()`, add `const currentMainView = useCurrentMainView()`.
- Replace the two `:style` checks (line 89-93 — the inline style binding) to source `active` from the URL:
  ```ts
  const isActive = computed(() =>
    currentMainView.value.kind === 'task' && currentMainView.value.taskId === props.task.id,
  )
  ```
- Bind `isActive` to the inline style. Replace the existing `:style` contents with:
  ```ts
  :style="{
    color: isActive.value ? 'var(--color-aqua)' : 'var(--semantic-text-dim)',
    backgroundColor: isActive.value ? 'var(--semantic-active-bg)' : 'transparent',
    boxShadow: dropIndicatorBoxShadow,
  }"
  ```
- Also update the bullet dot color (line ~212):
  ```ts
  :style="{ backgroundColor: isActive.value ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }"
  ```

### Step 3.4 — Run the test, confirm it passes

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/workspaceItemTask.spec.ts 2>&1 | tail -20
```
Expect: all pass.

### Step 3.5 — Run the full task-row suite to catch regressions

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/workspaceItemTask src/__tests__/workspaceItemTaskRename src/__tests__/workspaceItemTaskSpinner src/__tests__/workspaceItemTaskRoutine src/__tests__/workspaceItemTaskNotification 2>&1 | tail -10
```
Expect: all pass.

### Step 3.6 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
git add src/apps/desktop/src/components/workspace/WorkspaceItemTaskRow.vue src/apps/desktop/src/__tests__/workspaceItemTask.spec.ts
git commit -m "feat(sidebar): WorkspaceItemTaskRow active state from URL

Task row's active styling is now driven by URL ?view=task&task=X
rather than workspacesStore.activeTaskId. The store flag is kept
for AppLayout's view-routing but no longer drives sidebar highlighting.

Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md"
```

---

## Task 4: Wire `useCurrentMainView` into WorkspaceItem (workspace item active)

**Files:**
- MODIFIED: `src/apps/desktop/src/components/workspace/WorkspaceItem.vue`
- CREATE: `src/apps/desktop/src/__tests__/WorkspaceItem.activeFromUrl.spec.ts`

### Step 4.1 — Write the failing test

```ts
// src/apps/desktop/src/__tests__/WorkspaceItem.activeFromUrl.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, reactive, ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

const baseItem = {
  id: 'item_design',
  name: 'Design',
  item_type: 'design',
  path: '/tmp',
  tasks: [],
  design_elements: [],
  kanban_columns: [],
  isLoaded: true,
  isLoading: false,
}

function mountItem(overrides: { isActive?: boolean } = {}) {
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: baseItem,
      workspaceId: 'ws_1',
      isActive: overrides.isActive ?? false,
    },
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
  return { wrapper }
}

describe('WorkspaceItem — item row active state from URL', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })
  afterEach(() => { vi.restoreAllMocks() })

  it('item row is active when URL is ?view=workspace&itemId=Y (this item)', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_design' },
      path: '/app',
      fullPath: '/app?view=workspace&itemId=item_design',
    } as any)
    const { wrapper } = mountItem()
    await nextTick()
    // Find the main row button (the one with the chevron + name)
    const buttons = wrapper.findAll('button')
    const itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton).toBeDefined()
    expect(itemButton!.attributes('style')).toContain('--semantic-active-bg')
  })

  it('item row is NOT active when URL is ?view=chat&session=X', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'chat_xyz' },
      path: '/app',
      fullPath: '/app?view=chat&session=chat_xyz',
    } as any)
    const { wrapper } = mountItem()
    await nextTick()
    const buttons = wrapper.findAll('button')
    const itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton).toBeDefined()
    expect(itemButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('item row is NOT active when URL is ?view=workspace&itemId=OTHER', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_other' },
      path: '/app',
      fullPath: '/app?view=workspace&itemId=item_other',
    } as any)
    const { wrapper } = mountItem()
    await nextTick()
    const buttons = wrapper.findAll('button')
    const itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton).toBeDefined()
    expect(itemButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('item row active state reacts to URL changes mid-mount', async () => {
    const route = reactive({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    })
    useRouteMock.mockReturnValue(route as any)
    const { wrapper } = mountItem()
    await nextTick()
    let buttons = wrapper.findAll('button')
    let itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')

    route.query = { view: 'workspace', itemId: 'item_design' }
    await nextTick()
    buttons = wrapper.findAll('button')
    itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton!.attributes('style')).toContain('--semantic-active-bg')
  })
})
```

### Step 4.2 — Run the test, confirm it fails

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/WorkspaceItem.activeFromUrl.spec.ts 2>&1 | tail -20
```
Expect: 4 failures.

### Step 4.3 — Modify WorkspaceItem.vue

- Add `import { useCurrentMainView } from '../../composables/useCurrentMainView'`.
- Inside `setup()`, add `const currentMainView = useCurrentMainView()`.
- Add a new computed `isCurrentMainView`:
  ```ts
  const isCurrentMainView = computed(() =>
    currentMainView.value.kind === 'workspace' && currentMainView.value.itemId === props.item.id,
  )
  ```
- Replace the existing `isActive` prop usage in the template's `:style` binding (line 488-490) with `isCurrentMainView.value`:
  ```ts
  :style="isCurrentMainView
    ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text); box-shadow: inset 2px 0 0 0 var(--color-violet);`
    : `color: var(--semantic-text-muted);`"
  ```
  (The accent bar is added — see step 4.4.)
- The `isActive` prop is still passed by the parent (WorkspaceList). Keep it (other consumers may rely on it) but document that the visual now uses the URL.

### Step 4.4 — Add the violet left accent bar

In the `:style` for the active item, append `box-shadow: inset 2px 0 0 0 var(--color-violet);` to the active string. (This is what makes the active item visually distinct from non-active siblings.)

Do NOT add the accent bar to the inactive state.

### Step 4.5 — Run the test, confirm it passes

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/WorkspaceItem.activeFromUrl.spec.ts 2>&1 | tail -20
```
Expect: 4/4 pass.

### Step 4.6 — Run the full WorkspaceItem-related suite

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/workspaceItem src/__tests__/WorkspaceItem.kanban src/__tests__/WorkspaceItem.processing src/__tests__/WorkspaceItem.memories src/__tests__/WorkspaceItem.pinned src/__tests__/WorkspaceItem.hide src/__tests__/WorkspaceItem.taskCard 2>&1 | tail -10
```
Expect: all pass (no regressions).

### Step 4.7 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
git add src/apps/desktop/src/components/workspace/WorkspaceItem.vue src/apps/desktop/src/__tests__/WorkspaceItem.activeFromUrl.spec.ts
git commit -m "feat(sidebar): WorkspaceItem active state from URL + accent bar

Item row's active styling is now driven by URL ?view=workspace&itemId=X
(match), with a 2px violet left accent bar added to the active state
for unambiguous visual signal. The isActive prop is still passed by
the parent (kept for backwards compatibility) but the visual now
sources from the URL.

Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md"
```

---

## Task 5: Wire `useCurrentMainView` into DesignPageRow (design page active)

**Files:**
- MODIFIED: `src/apps/desktop/src/components/workspace/DesignPageRow.vue`
- CREATE: `src/apps/desktop/src/__tests__/DesignPageRow.activeFromUrl.spec.ts`

### Step 5.1 — Write the failing test

```ts
// src/apps/desktop/src/__tests__/DesignPageRow.activeFromUrl.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, reactive } from 'vue'
import { mount } from '@vue/test-utils'

import DesignPageRow from '../components/workspace/DesignPageRow.vue'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

const basePage = {
  id: 'page_42',
  name: 'Task Dialog',
  workspace_item_id: 'item_design',
  workspace_item_task_id: 'task_42',
  position: 0,
  created_at: '2026-01-01',
  width: 1440,
  height: 1024,
}

function mountRow(overrides: { isActivePage?: boolean } = {}) {
  const wrapper = mount(DesignPageRow, {
    props: {
      page: basePage,
      workspaceId: 'ws_1',
      itemId: 'item_design',
      isActivePage: overrides.isActivePage ?? false,
    },
  })
  return { wrapper }
}

describe('DesignPageRow — page row active state from URL', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })
  afterEach(() => { vi.restoreAllMocks() })

  it('page row is active when URL is ?view=workspace&pageId=Z (this page)', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_design', pageId: 'page_42' },
      path: '/app',
      fullPath: '/app?view=workspace&itemId=item_design&pageId=page_42',
    } as any)
    const { wrapper } = mountRow()
    await nextTick()
    const row = wrapper.find('[data-page-id="page_42"]')
    expect(row.exists()).toBe(true)
    expect(row.attributes('style')).toContain('--semantic-active-bg')
  })

  it('page row is NOT active when URL is ?view=workspace&pageId=OTHER', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_design', pageId: 'page_other' },
      path: '/app',
      fullPath: '/app?view=workspace&itemId=item_design&pageId=page_other',
    } as any)
    const { wrapper } = mountRow()
    await nextTick()
    const row = wrapper.find('[data-page-id="page_42"]')
    expect(row.exists()).toBe(true)
    expect(row.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('page row is NOT active when URL is ?view=chat', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'chat_xyz' },
      path: '/app',
      fullPath: '/app?view=chat&session=chat_xyz',
    } as any)
    const { wrapper } = mountRow()
    await nextTick()
    const row = wrapper.find('[data-page-id="page_42"]')
    expect(row.exists()).toBe(true)
    expect(row.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('page row active state reacts to URL changes mid-mount', async () => {
    const route = reactive({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    })
    useRouteMock.mockReturnValue(route as any)
    const { wrapper } = mountRow()
    await nextTick()
    let row = wrapper.find('[data-page-id="page_42"]')
    expect(row.attributes('style') ?? '').not.toContain('--semantic-active-bg')

    route.query = { view: 'workspace', itemId: 'item_design', pageId: 'page_42' }
    await nextTick()
    row = wrapper.find('[data-page-id="page_42"]')
    expect(row.attributes('style')).toContain('--semantic-active-bg')
  })
})
```

### Step 5.2 — Run the test, confirm it fails

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/DesignPageRow.activeFromUrl.spec.ts 2>&1 | tail -20
```
Expect: 4 failures (the existing implementation uses `props.isActivePage`).

### Step 5.3 — Modify DesignPageRow.vue

- Add `import { useCurrentMainView } from '../../composables/useCurrentMainView'`.
- Inside `setup()`, add `const currentMainView = useCurrentMainView()`.
- Add a computed `isCurrentMainView`:
  ```ts
  const isCurrentMainView = computed(() =>
    currentMainView.value.kind === 'workspace' && currentMainView.value.pageId === props.page.id,
  )
  ```
- Replace the `:style` and `data-active-page` bindings to use `isCurrentMainView.value` instead of `props.isActivePage`.
  - Note: the `isActivePage` prop is still passed by the parent (WorkspaceItem). Keep it for backwards compatibility, but the visual now uses the URL.

### Step 5.4 — Add the violet left accent bar to the active page row

In the `:style` for the active page, append `box-shadow: inset 2px 0 0 0 var(--color-violet);` to the active string.

### Step 5.5 — Run the test, confirm it passes

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/DesignPageRow.activeFromUrl.spec.ts 2>&1 | tail -20
```
Expect: 4/4 pass.

### Step 5.6 — Run the related suite

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/workspacesStoreDesignPages src/__tests__/DesignPageRow 2>&1 | tail -10
```
Expect: all pass.

### Step 5.7 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
git add src/apps/desktop/src/components/workspace/DesignPageRow.vue src/apps/desktop/src/__tests__/DesignPageRow.activeFromUrl.spec.ts
git commit -m "feat(sidebar): DesignPageRow active state from URL + accent bar

Page row's active styling is now driven by URL ?view=workspace&pageId=Z
(match), with a 2px violet left accent bar added for visual consistency
with the active workspace-item row. The isActivePage prop is kept for
backwards compat but the visual now sources from the URL.

Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md"
```

---

## Task 6: Drop active-bg from expanded workspaces in WorkspaceList

**Files:**
- MODIFIED: `src/apps/desktop/src/components/workspace/WorkspaceList.vue`
- CREATE: `src/apps/desktop/src/__tests__/WorkspaceList.expandedNoActiveBg.spec.ts`

### Step 6.1 — Write the failing test

```ts
// src/apps/desktop/src/__tests__/WorkspaceList.expandedNoActiveBg.spec.ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceList from '../components/workspace/WorkspaceList.vue'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

const baseWorkspace = {
  id: 'ws_1',
  name: 'agentic coding',
  expanded: true,
  items: [
    {
      id: 'item_design',
      name: 'design',
      item_type: 'design',
      path: '/tmp',
      tasks: [],
      design_elements: [],
      kanban_columns: [],
      isLoaded: true,
      isLoading: false,
    },
  ],
}

function mountList() {
  // Use the sidebar-store ref to expand workspaces by default
  return mount(WorkspaceList, {
    props: {
      workspaces: [baseWorkspace],
      activeWorkspaceItemId: null,
    },
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

describe('WorkspaceList — expanded workspace has NO active background', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    } as any)
  })
  afterEach(() => { vi.restoreAllMocks() })

  it('expanded workspace does NOT have --semantic-active-bg in its inline style', async () => {
    const wrapper = mountList()
    await nextTick()
    // Find the workspace header button (containing "agentic coding")
    const buttons = wrapper.findAll('button')
    const wsButton = buttons.find((b) => b.text().includes('agentic coding'))
    expect(wsButton).toBeDefined()
    // Lock in the new contract: expanded state alone does NOT
    // trigger the active background. Only the active item below
    // gets the active bg.
    expect(wsButton!.attributes('style') ?? '').not.toContain('--semantic-active-bg')
  })

  it('expanded workspace still rotates the chevron (visual cue for expand state)', async () => {
    const wrapper = mountList()
    await nextTick()
    // The chevron is a span with class containing 'transition-transform'
    // The rotated chevron is the one inside the workspace header
    const chevrons = wrapper.findAll('span[style*="rotate(90deg)"]')
    expect(chevrons.length).toBeGreaterThan(0)
  })
})
```

### Step 6.2 — Run the test, confirm it fails

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/WorkspaceList.expandedNoActiveBg.spec.ts 2>&1 | tail -20
```
Expect: 1 failure (the existing implementation uses `--semantic-active-bg` when expanded).

### Step 6.3 — Modify WorkspaceList.vue

In the workspace header button's `:style` binding (line 487-493), change:
```ts
:style="{
  backgroundColor: workspace.expanded
    ? 'var(--semantic-active-bg)'
    : 'transparent',
  color: workspace.expanded
    ? 'var(--semantic-active-text)'
    : 'var(--semantic-text-muted)',
}"
```
to:
```ts
:style="{
  backgroundColor: workspace.expanded
    ? 'transparent'
    : 'transparent',
  color: workspace.expanded
    ? 'var(--semantic-text-muted)'
    : 'var(--semantic-text-muted)',
}"
```

Wait — both branches now produce the same styles. The expanded-only differentiation is purely the chevron rotation. Leave the conditional structure for clarity but make both branches identical (no visible diff).

Actually, a cleaner form is:
```ts
:style="{
  backgroundColor: 'transparent',
  color: 'var(--semantic-text-muted)',
}"
```

But preserve the conditional in case future code needs to add expanded-only styling. The user's intent is "expanded state is not visually equivalent to active state".

### Step 6.4 — Run the test, confirm it passes

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/WorkspaceList.expandedNoActiveBg.spec.ts 2>&1 | tail -20
```
Expect: 2/2 pass.

### Step 6.5 — Run the related suite

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/workspaceListDragDrop src/__tests__/workspaceListItemDragDrop src/__tests__/workspaceListProcessingSpinner src/__tests__/WorkspaceList.expandedNoActiveBg 2>&1 | tail -10
```
Expect: all pass.

### Step 6.6 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
git add src/apps/desktop/src/components/workspace/WorkspaceList.vue src/apps/desktop/src/__tests__/WorkspaceList.expandedNoActiveBg.spec.ts
git commit -m "feat(sidebar): drop active-bg from expanded workspaces

The workspace header used '+--semantic-active-bg+' when expanded,
which conflated 'expanded (UI state)' with 'active (content
relationship)'. Now expanded workspaces render with no background
— the chevron rotation alone signals the open state. The active
content item (driven by the URL) gets the active bg + accent bar.

Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md"
```

---

## Task 7: E2E test — sidebar shows exactly one active row

**Files:**
- CREATE: `src/apps/desktop/src/__tests__/sidebarSingleActive.spec.ts`

### Step 7.1 — Write the test

```ts
// src/apps/desktop/src/__tests__/sidebarSingleActive.spec.ts
/**
 * End-to-end test: when the URL drives a workspace-view with a
 * specific item + page, the sidebar must show EXACTLY ONE row with
 * the active background + violet accent bar — and that row must be
 * the matching design page row (the most-specific level of the
 * navigation hierarchy).
 *
 * Pre-fix this would fail because the expanded workspace would
 * ALSO have the active bg.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, reactive, ref } from 'vue'
import { createApp, type App as VueApp } from 'vue'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

function makeStubClient(): SseClient {
  return {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting',
    onStateChange: () => () => {},
  } as any
}

const baseWorkspace = {
  id: 'ws_1',
  name: 'agentic coding',
  expanded: true,
  items: [
    {
      id: 'item_design',
      name: 'design',
      item_type: 'design',
      path: '/tmp',
      tasks: [],
      design_elements: [],
      design_pages: [
        { id: 'page_42', name: 'Task Dialog', workspace_item_id: 'item_design', workspace_item_task_id: 'task_42', position: 0, created_at: '2026-01-01', width: 1440, height: 1024 },
        { id: 'page_99', name: 'Other Page', workspace_item_id: 'item_design', workspace_item_task_id: 'task_99', position: 1, created_at: '2026-01-01', width: 1440, height: 1024 },
      ],
      kanban_columns: [],
      isLoaded: true,
      isLoading: false,
    },
  ],
}

describe('Sidebar — exactly one row is active at a time (URL-driven)', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('sidebar shows exactly ONE active row when URL is ?view=workspace&itemId=X&pageId=Z', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', workspaceId: 'ws_1', itemId: 'item_design', pageId: 'page_42' },
      path: '/app',
      fullPath: '/app?view=workspace&workspaceId=ws_1&itemId=item_design&pageId=page_42',
    } as any)

    // Pre-populate the workspaces store so the sidebar has a tree to render.
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const ws = useWorkspacesStore()
    ws.workspaces = [baseWorkspace]
    // The store's designPagesByItemId cache needs to be populated for
    // the page rows to render. Manually emit the cache.
    ws.designPagesByItemId = { item_design: baseWorkspace.items[0].design_pages }
    // Expand the design item so its pages render.
    ws.expandedItemIds = { item_design: true }

    const wrapper = mount(Sidebar, {
      global: {
        mocks: { $router: { replace: vi.fn(), push: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
    })
    await nextTick()

    // Count rows with the active bg.
    const html = wrapper.html()
    const activeRows = (html.match(/--semantic-active-bg/g) ?? []).length
    // Exactly ONE: the design page row whose id matches page_42.
    expect(activeRows).toBe(1)
  })

  it('sidebar shows zero active rows when URL is ?view=chat&session=X', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'session_xyz' },
      path: '/app',
      fullPath: '/app?view=chat&session=session_xyz',
    } as any)

    const { useWorkspacesStore } = await import('../stores/workspaces')
    const ws = useWorkspacesStore()
    ws.workspaces = [baseWorkspace]
    ws.designPagesByItemId = { item_design: baseWorkspace.items[0].design_pages }
    ws.expandedItemIds = { item_design: true }

    const wrapper = mount(Sidebar, {
      global: {
        mocks: { $router: { replace: vi.fn(), push: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
    })
    await nextTick()

    const html = wrapper.html()
    const activeRows = (html.match(/--semantic-active-bg/g) ?? []).length
    // Zero: no workspace item or page is active when the URL is chat-only.
    expect(activeRows).toBe(0)
  })
})
```

### Step 7.2 — Run the test, confirm it fails

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/sidebarSingleActive.spec.ts 2>&1 | tail -40
```
Expect: 2 failures (the sidebar still has multiple active rows).

### Step 7.3 — Diagnose the failure

If the count is not 1 in the first test, find which row is wrongly active. The likely culprits:
- The ChatsList (no mocked chats → empty list, so no chat row to be active)
- The workspace item (`item_design`) — should be active
- The page row (`page_42`) — should be active
- The expanded workspace (`agentic coding`) — should NOT be active

If the count is 2, the expanded workspace is still active. Need to investigate further (the test in Task 6 already locks this in, but the Sidebar might still render expanded workspace styling somewhere).

### Step 7.4 — Investigate and fix any remaining issues

Most likely: the test will pass after Tasks 1-6 are complete. If not, debug by inspecting the sidebar HTML to find the extra active row.

### Step 7.5 — Run the test, confirm it passes

```bash
cd src/apps/desktop && bunx vitest run src/__tests__/sidebarSingleActive.spec.ts 2>&1 | tail -20
```
Expect: 2/2 pass.

### Step 7.6 — Run the full test suite

```bash
cd src/apps/desktop && bunx vitest run 2>&1 | tail -30
```
Expect: pre-existing 19 failures stay the same. NO new failures.

### Step 7.7 — Type-check

```bash
cd src/apps/desktop && bun run build 2>&1 | tail -10
```
Expect: clean (vue-tsc passes).

### Step 7.8 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
git add src/apps/desktop/src/__tests__/sidebarSingleActive.spec.ts
git commit -m "test(sidebar): E2E — exactly one row active at a time

Pre-fix: the sidebar would show 2-3 active rows simultaneously
(expanded workspace + active item + active page). After this
feature, the URL ?view=workspace&itemId=X&pageId=Z renders exactly
one row with the active background, and ?view=chat renders zero.

Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md"
```

---

## Task 8: Cleanup — remove now-unused store-flag reads in sidebar

**Files:**
- MODIFIED: `src/apps/desktop/src/components/shell/Sidebar.vue` (if any cleanup needed)
- Possibly MODIFIED: `src/apps/desktop/src/components/views/ChatsList.vue` (drop `chatsListRef.resetActiveChat()` calls)

### Step 8.1 — Audit the sidebar for stale store-flag reads

Run:
```bash
cd src/apps/desktop && rg -n 'activeWorkspaceItemId|activeTaskId|activeDesignPageId' src/components/shell/Sidebar.vue src/components/views/ChatsList.vue
```

For each match, decide:
- If the flag is used to DRIVE A VISUAL: replace with `useCurrentMainView` (already done in Tasks 2-5).
- If the flag is used to COORDINATE side-effects (e.g., `workspacesStore.setActiveWorkspaceItem(null)`): leave alone — these are still valid store mutations.

### Step 8.2 — Check `chatsListRef.resetActiveChat()` calls

Search:
```bash
cd src/apps/desktop && rg -n 'resetActiveChat' src/components/
```

If `resetActiveChat()` is no longer needed (the URL drives the active state), remove the call sites. If it's still needed for some other reason (e.g., to clear the local navItems ref when the user explicitly clicks a chat), keep it.

### Step 8.3 — Verify the accumulated tests still pass

```bash
cd src/apps/desktop && bunx vitest run 2>&1 | tail -10
```
Expect: pre-existing 19 failures stay the same. No new failures.

### Step 8.4 — Commit (if any cleanup was needed)

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
# Only commit if there are actual changes from step 8.1/8.2
git add -u
git commit -m "refactor(sidebar): drop stale store-flag-driven visuals

The URL is now the source of truth for sidebar active state. Any
remaining store-flag reads in the sidebar are either (a) coordinating
side-effects (kept) or (b) no longer needed (removed here).

Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md"
```

---

## Task 9: Final verification

### Step 9.1 — Type-check + build

```bash
cd src/apps/desktop && bun run build 2>&1 | tail -10
```
Expect: clean.

### Step 9.2 — Full test suite

```bash
cd src/apps/desktop && bunx vitest run 2>&1 | tail -10
```
Expect: same pre-existing 19 failures, no new failures.

### Step 9.3 — Manual smoke test (browser)

1. Open `http://localhost:5173/app?view=workspace&itemId=item_design&pageId=page_42` in the browser.
2. Verify:
   - The "agentic coding" workspace header is NOT highlighted (just chevron rotated).
   - The "design" item row is highlighted with bg + violet left accent bar.
   - The "Task Dialog" page row is highlighted with bg + violet left accent bar.
   - The CHATS section does NOT show any active chat.
3. Click a chat in the CHATS list. Verify:
   - The chat row is highlighted with bg + violet accent bar.
   - The "design" item row is NOT highlighted.
   - The "Task Dialog" page row is NOT highlighted.
4. Click a task in a kanban. Verify:
   - The task row is highlighted with bg + violet accent bar.
   - The CHATS section does NOT show any active chat (the chat's session id is not in the URL).
   - The workspace item is NOT highlighted.
5. Hard-refresh the browser on each URL. Verify the active state survives.

### Step 9.4 — AGENTS.md + docs/SPEC.md changelog

Add a changelog entry to `AGENTS.md` under "Recent changes" following the format of prior entries (see `### 2026-08-06:` blocks).

Add a row to `docs/SPEC.md` §10.2.1 (PR index) if the user has been doing that.

### Step 9.5 — Commit

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
git add AGENTS.md docs/SPEC.md
git commit -m "docs: changelog for sidebar single-active state"
```

### Step 9.6 — Final commit review

```bash
cd /home/ginwa/ginwaaitoolbox/.worktrees/sidebar-single-active
git log --oneline main..HEAD
```
Expect: 7-9 commits, each one a focused, testable unit of work.

### Step 9.7 — Open a PR (optional)

If the user wants a PR, push the branch and open one. Otherwise, merge directly to main.

---

## Pitfalls (project-specific)

- **vue-router mock pattern**: every test that uses `useRoute()` in setup must mock 'vue-router' at module level (see `sidebarHandleSelectTaskUrl.spec.ts:57-77` for the canonical pattern). The mock must return a `reactive` object so post-mount URL changes trigger the computed.
- **Pinia is per-test**: `setActivePinia(createPinia())` in `beforeEach` resets the store. Tests that pre-populate the store must do it AFTER the Pinia setup.
- **ChatsList's `loadChats()` is async**: tests that assert on `navItems` need an `await nextTick()` after mocking `api.getChats` AND after invoking `loadChats` (via `wrapper.vm`).
- **WorkspaceItem `isActive` prop**: the parent (WorkspaceList) still passes `isActive` based on `activeWorkspaceItemId`. We're keeping this prop for backwards compat (other consumers may use it) but the visual now sources from the URL. If the prop is removed in the future, call sites break.
- **AppLayout's view-routing still uses store flags**: `activeWorkspaceItemId`, `activeTaskId`, `activeDesignPageId` are still set/cleared by AppLayout's URL-restore handlers. Removing these would break view routing. The fix here is purely visual — the store flags remain.
- **The `+` icon at the bottom of the workspace list** (`+ Add Item`) is unchanged.
- **The active styling uses `--semantic-active-bg` (#282727) and `--color-aqua` (#8ea4a2)**: these are the existing dark-theme colors. The new accent bar uses `--color-violet` (#8992a7).
- **No backend changes**: this is purely frontend. No Zig, no migration, no DB.
- **Active workspace item `box-shadow` on hover**: the parent `<li>` has a `box-shadow: 0 -2px 0 0 var(--color-violet)` for drag-over. The active item's `box-shadow: inset 2px 0 0 0 var(--color-violet)` is on the INNER button, not the `<li>` — they don't conflict.
- **Processing spinner (yellow ring) is independent**: stays unchanged. A row can be active AND processing simultaneously, which is correct UX.

## Verification (final)

- [ ] `bun run build` clean (vue-tsc + vite)
- [ ] `bunx vitest run` — pre-existing 19 failures stay, no new failures
- [ ] Browser smoke test (Task 9.3) — exactly one active row everywhere
- [ ] `docs/SPEC.md` + `AGENTS.md` updated with changelog entry
- [ ] PR or direct merge to `main`
