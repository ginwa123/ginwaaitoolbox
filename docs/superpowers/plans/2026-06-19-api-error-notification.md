# API Error Notification Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface every HTTP 4xx/5xx response from `src/apps/desktop/src/api/index.ts` as a user-visible toast notification, replacing the 20+ silent `console.error` calls.

**Architecture:** A central `apiFetch()` wrapper in `api/index.ts` auto-fires a Pinia-stored notification on any non-OK response. A `NotificationContainer` mounted once in `AppLayout.vue` renders the toast stack. All 55 exported API functions route through the wrapper (with `silent: true` opt-out for ~5 functions that have their own inline error UI).

**Tech Stack:** Vue 3 Composition API, TypeScript, Pinia, Vue Test Utils + Vitest.

**Reference docs:**
- Design doc: `docs/plans/2026-06-19-api-error-notification-design.md`
- Project memory: `bun run build` is the type-check (not `bunx vitest run`)

---

## File Structure

### New files

| File | Responsibility |
|------|----------------|
| `src/apps/desktop/src/stores/notifications.ts` | Pinia store: notifications[], notifyError, dismiss, dismissAll. Counter-based IDs. setTimeout auto-dismiss. |
| `src/apps/desktop/src/components/ErrorNotification.vue` | Toast UI: red bg, ⚠ icon, message, optional details accordion, × button, `role="alert"`. |
| `src/apps/desktop/src/components/NotificationContainer.vue` | Mounts in AppLayout. Renders ErrorNotification per store entry via `flex-col-reverse`. `pointer-events-none` wrapper, `pointer-events-auto` on toasts. |
| `src/apps/desktop/src/__tests__/notifications.spec.ts` | Store tests: notifyError, dismiss, dismissAll, auto-dismiss timer, stacking. |
| `src/apps/desktop/src/__tests__/ErrorNotification.spec.ts` | Component tests: renders props, × emits dismiss, details accordion toggles. |
| `src/apps/desktop/src/__tests__/NotificationContainer.spec.ts` | Container tests: renders one per entry, dismiss handler wired. |
| `src/apps/desktop/src/__tests__/apiFetch.spec.ts` | Wrapper tests: 2xx returns, 4xx/5xx notifies + throws ApiError, silent:true skips notify, fetch rejection does not notify. |

### Modified files

| File | Change |
|------|--------|
| `src/apps/desktop/src/api/index.ts` | Add `apiFetch<T>()` helper + `ApiError` class. Refactor 55 exported functions to use it. Replace inline `console.error` blocks. Add `silent: true` to 5 opt-out functions (`readFileContent`, `writeFileContent`, `getSession`, `getChatHistory`, `sendChatMessage`). |
| `src/apps/desktop/src/components/AppLayout.vue` | Import + mount `<NotificationContainer />` once (sibling to `<RightSidebar>`). |

### Out of scope

- SSE error notifications (the `SseStatusBadge` already shows connection state)
- Non-API `console.error` calls (in `sseClient.ts`, `scrollLogger.ts`, `App.vue`)
- The inline `SettingsView.vue` toast (separate concern)
- Dedup, retry, sounds, OS notifications, persistence

---

## Chunk 1: Pinia store (foundation)

**Why first:** All UI and API code depends on `useNotificationStore`. Isolating this chunk lets us verify the store contract before building consumers.

---

### Task 1.1: Write failing store tests

**Files:**
- Create: `src/apps/desktop/src/__tests__/notifications.spec.ts`

- [ ] **Step 1.1.1: Write the test file**

```ts
// src/apps/desktop/src/__tests__/notifications.spec.ts
import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useNotificationStore } from '../stores/notifications'

describe('useNotificationStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('starts with empty notifications array', () => {
    const store = useNotificationStore()
    expect(store.notifications).toEqual([])
  })

  it('notifyError pushes a new entry with unique id', () => {
    const store = useNotificationStore()
    store.notifyError('Something failed', 'details')
    expect(store.notifications).toHaveLength(1)
    expect(store.notifications[0]?.message).toBe('Something failed')
    expect(store.notifications[0]?.details).toBe('details')
    expect(store.notifications[0]?.id).toMatch(/^n_\d+_\d+$/)
  })

  it('notifyError without details omits the field', () => {
    const store = useNotificationStore()
    store.notifyError('Plain error')
    expect(store.notifications[0]?.details).toBeUndefined()
  })

  it('multiple notifyError calls stack in insertion order', () => {
    const store = useNotificationStore()
    store.notifyError('first')
    store.notifyError('second')
    store.notifyError('third')
    expect(store.notifications.map(n => n.message)).toEqual(['first', 'second', 'third'])
  })

  it('each notification auto-dismisses after 5000ms', () => {
    const store = useNotificationStore()
    store.notifyError('auto-dismiss me')
    expect(store.notifications).toHaveLength(1)
    vi.advanceTimersByTime(5000)
    expect(store.notifications).toHaveLength(0)
  })

  it('dismiss removes a specific entry by id', () => {
    const store = useNotificationStore()
    store.notifyError('a')
    store.notifyError('b')
    const bId = store.notifications[1]?.id ?? ''
    store.dismiss(bId)
    expect(store.notifications).toHaveLength(1)
    expect(store.notifications[0]?.message).toBe('a')
  })

  it('dismiss on unknown id is a no-op', () => {
    const store = useNotificationStore()
    store.notifyError('a')
    store.dismiss('nonexistent')
    expect(store.notifications).toHaveLength(1)
  })

  it('dismissAll empties the array', () => {
    const store = useNotificationStore()
    store.notifyError('a')
    store.notifyError('b')
    store.dismissAll()
    expect(store.notifications).toEqual([])
  })
})
```

- [ ] **Step 1.1.2: Run the test — it must fail (no store yet)**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run notifications.spec.ts 2>&1 | tail -n 15`

Expected: `Failed to resolve import "../stores/notifications"` or `Cannot find module`.

- [ ] **Step 1.1.3: Commit the failing test**

```bash
git add src/apps/desktop/src/__tests__/notifications.spec.ts
git commit -m "test(notifications): add failing store spec for error notification"
```

---

### Task 1.2: Implement the store

**Files:**
- Create: `src/apps/desktop/src/stores/notifications.ts`

- [ ] **Step 1.2.1: Write the implementation**

```ts
// src/apps/desktop/src/stores/notifications.ts
import { defineStore } from 'pinia'
import { ref } from 'vue'

export interface Notification {
  id: string
  message: string
  details?: string
  createdAt: number
}

const AUTO_DISMISS_MS = 5000

export const useNotificationStore = defineStore('notifications', () => {
  const notifications = ref<Notification[]>([])
  let counter = 0

  function notifyError(message: string, details?: string) {
    counter += 1
    const id = `n_${Date.now()}_${counter}`
    notifications.value.push({ id, message, details, createdAt: Date.now() })
    setTimeout(() => dismiss(id), AUTO_DISMISS_MS)
  }

  function dismiss(id: string) {
    const i = notifications.value.findIndex(n => n.id === id)
    if (i !== -1) notifications.value.splice(i, 1)
  }

  function dismissAll() {
    notifications.value = []
  }

  return { notifications, notifyError, dismiss, dismissAll }
})
```

- [ ] **Step 1.2.2: Run tests — must pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run notifications.spec.ts 2>&1 | tail -n 10`

Expected: `Test Files  1 passed (1)` and `Tests  8 passed (8)`.

- [ ] **Step 1.2.3: Type-check — must be clean**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`

Expected: type-check + bundle pass. (No new errors; the store file alone won't pull in vue-tsc issues.)

- [ ] **Step 1.2.4: Commit**

```bash
git add src/apps/desktop/src/stores/notifications.ts
git commit -m "feat(notifications): add Pinia store for error notifications"
```

---

## Chunk 2: UI components (depend on store)

**Why next:** The container is what the user sees; needs the store wired before it can render anything.

---

### Task 2.1: ErrorNotification component

**Files:**
- Create: `src/apps/desktop/src/components/ErrorNotification.vue`
- Create: `src/apps/desktop/src/__tests__/ErrorNotification.spec.ts`

- [ ] **Step 2.1.1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/ErrorNotification.spec.ts
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import ErrorNotification from '../components/ErrorNotification.vue'

describe('ErrorNotification', () => {
  it('renders the message', () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'Server returned 500' },
    })
    expect(wrapper.text()).toContain('Server returned 500')
  })

  it('hides the details accordion when details prop is absent', () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'Plain error' },
    })
    expect(wrapper.find('details').exists()).toBe(false)
  })

  it('shows the details accordion when details prop is set', () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'Server returned 500', details: 'Internal Server Error' },
    })
    expect(wrapper.find('details').exists()).toBe(true)
    expect(wrapper.find('details').text()).toContain('Internal Server Error')
  })

  it('clicking × emits dismiss', async () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'Click me away' },
    })
    await wrapper.find('button[aria-label="Dismiss"]').trigger('click')
    expect(wrapper.emitted('dismiss')).toHaveLength(1)
  })

  it('has role="alert" for screen readers', () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'A11y matters' },
    })
    expect(wrapper.attributes('role')).toBe('alert')
  })
})
```

- [ ] **Step 2.1.2: Run the test — must fail (no component yet)**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run ErrorNotification.spec.ts 2>&1 | tail -n 10`

Expected: `Failed to resolve import "../components/ErrorNotification.vue"`.

- [ ] **Step 2.1.3: Write the component implementation**

```vue
<!-- src/apps/desktop/src/components/ErrorNotification.vue -->
<script setup lang="ts">
defineProps<{
  message: string
  details?: string
}>()

const emit = defineEmits<{ dismiss: [] }>()
</script>

<template>
  <div
    class="pointer-events-auto px-4 py-3 rounded-lg shadow-lg max-w-md"
    style="background-color: var(--color-red); color: white;"
    role="alert"
  >
    <div class="flex items-start gap-3">
      <span class="text-lg shrink-0">⚠</span>
      <div class="flex-1 min-w-0">
        <div class="font-medium">{{ message }}</div>
        <details v-if="details" class="mt-1 text-xs opacity-90">
          <summary class="cursor-pointer">Details</summary>
          <pre class="mt-1 whitespace-pre-wrap break-all">{{ details }}</pre>
        </details>
      </div>
      <button
        class="shrink-0 text-white opacity-70 hover:opacity-100"
        style="background: none; border: none; font-size: 1.25rem; line-height: 1; cursor: pointer;"
        @click="emit('dismiss')"
        aria-label="Dismiss"
      >×</button>
    </div>
  </div>
</template>
```

- [ ] **Step 2.1.4: Run tests — must pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run ErrorNotification.spec.ts 2>&1 | tail -n 10`

Expected: `Test Files  1 passed (1)` and `Tests  5 passed (5)`.

- [ ] **Step 2.1.5: Commit (test + impl)**

```bash
git add src/apps/desktop/src/components/ErrorNotification.vue src/apps/desktop/src/__tests__/ErrorNotification.spec.ts
git commit -m "feat(notifications): add ErrorNotification toast component"
```

---

### Task 2.2: NotificationContainer component

**Files:**
- Create: `src/apps/desktop/src/components/NotificationContainer.vue`
- Create: `src/apps/desktop/src/__tests__/NotificationContainer.spec.ts`

- [ ] **Step 2.2.1: Write the failing test**

```ts
// src/apps/desktop/src/__tests__/NotificationContainer.spec.ts
import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import NotificationContainer from '../components/NotificationContainer.vue'
import { useNotificationStore } from '../stores/notifications'

describe('NotificationContainer', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders nothing when store is empty', () => {
    const wrapper = mount(NotificationContainer)
    expect(wrapper.findAll('[role="alert"]')).toHaveLength(0)
  })

  it('renders one ErrorNotification per store entry', () => {
    const store = useNotificationStore()
    store.notifyError('first')
    store.notifyError('second')
    const wrapper = mount(NotificationContainer)
    expect(wrapper.findAll('[role="alert"]')).toHaveLength(2)
    expect(wrapper.text()).toContain('first')
    expect(wrapper.text()).toContain('second')
  })

  it('clicking × on a toast calls store.dismiss(id)', async () => {
    const store = useNotificationStore()
    store.notifyError('dismiss me')
    const wrapper = mount(NotificationContainer)
    await wrapper.find('button[aria-label="Dismiss"]').trigger('click')
    expect(store.notifications).toHaveLength(0)
  })
})
```

- [ ] **Step 2.2.2: Run the test — must fail (no component yet)**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run NotificationContainer.spec.ts 2>&1 | tail -n 10`

Expected: `Failed to resolve import "../components/NotificationContainer.vue"`.

- [ ] **Step 2.2.3: Write the component implementation**

```vue
<!-- src/apps/desktop/src/components/NotificationContainer.vue -->
<script setup lang="ts">
import { useNotificationStore } from '../stores/notifications'
import ErrorNotification from './ErrorNotification.vue'

const store = useNotificationStore()
</script>

<template>
  <div
    class="fixed bottom-6 right-6 z-50 flex flex-col-reverse gap-2 pointer-events-none"
    aria-live="polite"
    aria-atomic="false"
  >
    <ErrorNotification
      v-for="n in store.notifications"
      :key="n.id"
      :message="n.message"
      :details="n.details"
      @dismiss="store.dismiss(n.id)"
    />
  </div>
</template>
```

- [ ] **Step 2.2.4: Run tests — must pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run NotificationContainer.spec.ts 2>&1 | tail -n 10`

Expected: `Test Files  1 passed (1)` and `Tests  3 passed (3)`.

- [ ] **Step 2.2.5: Commit (test + impl)**

```bash
git add src/apps/desktop/src/components/NotificationContainer.vue src/apps/desktop/src/__tests__/NotificationContainer.spec.ts
git commit -m "feat(notifications): add NotificationContainer stack renderer"
```

---

## Chunk 3: apiFetch wrapper (independent of UI)

**Why this chunk:** The wrapper is the linchpin — without it, no notifications fire. Can be developed and tested without UI.

---

### Task 3.1: Write failing apiFetch tests

**Files:**
- Create: `src/apps/desktop/src/__tests__/apiFetch.spec.ts`

- [ ] **Step 3.1.1: Write the test file**

```ts
// src/apps/desktop/src/__tests__/apiFetch.spec.ts
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { apiFetch, ApiError } from '../api/index'

describe('apiFetch', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  it('returns parsed JSON on 2xx response', async () => {
    const fakeResponse = new Response(JSON.stringify({ ok: true, value: 42 }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(fakeResponse)

    const result = await apiFetch<{ ok: boolean; value: number }>('/test')
    expect(result).toEqual({ ok: true, value: 42 })
  })

  it('notifies and throws ApiError on 4xx response with JSON .error field', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    const fakeResponse = new Response(JSON.stringify({ error: 'Invalid name' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(fakeResponse)

    await expect(apiFetch('/test')).rejects.toBeInstanceOf(ApiError)

    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(1)
    expect(store.notifications[0]?.message).toBe('Invalid name')
    expect(store.notifications[0]?.details).toBe('{"error":"Invalid name"}')
  })

  it('notifies and throws ApiError on 5xx response', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    const fakeResponse = new Response('Internal Server Error', { status: 500 })
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(fakeResponse)

    await expect(apiFetch('/test')).rejects.toBeInstanceOf(ApiError)

    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(1)
    expect(store.notifications[0]?.message).toBe('HTTP 500 Internal Server Error')
    expect(store.notifications[0]?.details).toBe('Internal Server Error')
  })

  it('does not notify when silent:true is passed', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    const fakeResponse = new Response('{"error":"bad"}', { status: 400 })
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(fakeResponse)

    await expect(apiFetch('/test', { silent: true })).rejects.toBeInstanceOf(ApiError)

    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(0)
  })

  it('does not notify on fetch rejection (network failure)', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('NetworkError'))

    await expect(apiFetch('/test')).rejects.toThrow('NetworkError')

    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(0)
  })

  it('serializes JSON body automatically', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{}', { status: 200 }),
    )

    await apiFetch('/test', { method: 'POST', body: { foo: 'bar' } })
    const init = fetchSpy.mock.calls[0]?.[1] as RequestInit | undefined
    expect(init?.body).toBe('{"foo":"bar"}')
  })

  it('uses API_BASE prefix on the URL', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{}', { status: 200 }),
    )

    await apiFetch('/workspaces')
    const calledUrl = fetchSpy.mock.calls[0]?.[0] as string | undefined
    expect(calledUrl).toBe('/api/workspaces')
  })
})
```

- [ ] **Step 3.1.2: Run the test — must fail (no apiFetch yet)**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run apiFetch.spec.ts 2>&1 | tail -n 10`

Expected: `apiFetch` is not exported from `../api`.

- [ ] **Step 3.1.3: Commit the failing test**

```bash
git add src/apps/desktop/src/__tests__/apiFetch.spec.ts
git commit -m "test(apiFetch): add failing spec for centralized HTTP wrapper"
```

---

### Task 3.2: Implement apiFetch and ApiError

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts` (add at top, after `API_BASE` constant)

- [ ] **Step 3.2.1: Read the current file header to find the insertion point**

Run: `head -n 30 src/apps/desktop/src/api/index.ts`

Look for: `export const API_BASE = '/api'` (line 6). The new code goes RIGHT AFTER it, BEFORE the first function export.

- [ ] **Step 3.2.2: Add the wrapper code**

Insert immediately after `export const API_BASE = '/api'`:

```ts
import { useNotificationStore } from '../stores/notifications'

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body: string,
  ) {
    super(`HTTP ${status} ${statusText}`)
    this.name = 'ApiError'
  }
}

export interface ApiFetchOptions extends Omit<RequestInit, 'body'> {
  body?: unknown
  /** When true, skip the error notification (caller handles UI inline). */
  silent?: boolean
}

/**
 * Centralized HTTP wrapper. Auto-fires a toast notification on 4xx/5xx
 * responses (unless `silent: true`). Throws `ApiError` on non-OK so
 * callers can still implement fallback UI.
 *
 * Network failures (fetch rejects) propagate WITHOUT a notification —
 * those are covered by SseStatusBadge for SSE, and a global offline
 * toast is out of scope for v1.
 */
export async function apiFetch<T = unknown>(
  url: string,
  opts: ApiFetchOptions = {},
): Promise<T> {
  const { body, silent, ...init } = opts

  const fetchInit: RequestInit = {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(init.headers as Record<string, string> | undefined),
    },
    body: body !== undefined ? JSON.stringify(body) : (init.body as BodyInit | undefined),
  }

  const response = await fetch(`${API_BASE}${url}`, fetchInit)

  if (!response.ok) {
    const responseBody = await response.text().catch(() => '')

    if (!silent) {
      const parsedError = tryParseJsonErrorField(responseBody)
      const message = parsedError ?? `HTTP ${response.status} ${response.statusText}`
      const details = parsedError ? responseBody : responseBody || undefined
      useNotificationStore().notifyError(message, details)
    }

    throw new ApiError(response.status, response.statusText, responseBody)
  }

  // 204 No Content — return undefined cast to T
  if (response.status === 204) {
    return undefined as T
  }

  return (await response.json()) as T
}

function tryParseJsonErrorField(body: string): string | null {
  if (!body) return null
  try {
    const obj = JSON.parse(body)
    if (obj && typeof obj === 'object' && typeof obj.error === 'string') {
      return obj.error
    }
    return null
  } catch {
    return null
  }
}
```

- [ ] **Step 3.2.3: Run tests — must pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run apiFetch.spec.ts 2>&1 | tail -n 10`

Expected: `Test Files  1 passed (1)` and `Tests  7 passed (7)`.

- [ ] **Step 3.2.4: Run type-check — must be clean**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`

Expected: clean build. No new errors. (Existing 55 functions still use `fetch` directly — they remain type-correct.)

- [ ] **Step 3.2.5: Commit**

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(api): add apiFetch wrapper + ApiError class for centralized error handling"
```

---

## Chunk 4: Mount in AppLayout

**Why next:** Wires the UI to the page. Small, isolated change. Verifies the end-to-end rendering before doing the API refactor.

---

### Task 4.1: Add NotificationContainer to AppLayout

**Files:**
- Modify: `src/apps/desktop/src/components/AppLayout.vue`

- [ ] **Step 4.1.1: Add the import**

In `AppLayout.vue`, find the import block (lines 1-20). Add:

```ts
import NotificationContainer from './NotificationContainer.vue'
```

- [ ] **Step 4.1.2: Add the template mount point**

Find the closing `</main>` and the `<RightSidebar>` line near the end of the template. The `<NotificationContainer />` should be the LAST child of the root `<div class="flex h-screen">` (after `<RightSidebar>`).

Insert:

```vue
<!-- Global error notification stack -->
<NotificationContainer />
```

- [ ] **Step 4.1.3: Run type-check — must be clean**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`

Expected: clean build.

- [ ] **Step 4.1.4: Run all tests — must be green**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 10`

Expected: all existing tests still pass (31 baseline) + 8 store + 5 ErrorNotification + 3 NotificationContainer + 7 apiFetch = **54 total, 54 passing**.

- [ ] **Step 4.1.5: Commit**

```bash
git add src/apps/desktop/src/components/AppLayout.vue
git commit -m "feat(notifications): mount NotificationContainer in AppLayout"
```

---

## Chunk 5: Refactor API functions to use apiFetch

**Why last:** Mechanical refactor of 55 functions. Independent of UI; can be split into sub-chunks if needed. The risk is silent behavior change — each refactor must preserve the original semantics.

**Refactor rules:**
- **Pattern A** (throws on non-OK): Replace `fetch + if !ok + console.error + throw` with `return apiFetch<T>(url, { ...opts, silent: false })`.
- **Pattern B** (returns status string): Keep the return-shape semantics. Route through `apiFetch` with `silent: true` and add a `try/catch` to convert `ApiError` → `{ status: 'http_error' }`.
- **Opt-out cases** (`silent: true`): `readFileContent`, `writeFileContent`, `getSession`, `getChatHistory`, `sendChatMessage`. The remaining 50 functions default to `silent: false`.

---

### Task 5.1: Refactor Pattern A functions (50 functions)

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 5.1.1: Identify the 50 Pattern A functions**

Search for all exported functions in `src/apps/desktop/src/api/index.ts` that follow Pattern A. Concretely, every function except the 5 opt-out ones AND `sendChatMessage` (which is Pattern B).

The list (50 functions, alphabetical within the file):

```
healthCheck, getSystemFolder, listFolder, getWorkspaces, getWorkspacesItems,
createWorkspace, getWorkspace, deleteWorkspace, updateWorkspace,
reorderWorkspaces, reorderWorkspaceItems, getTasks, createTask, updateTask,
updateTaskSimple, deleteTask, runRoutine, getChatHistory, updateSession,
getChats, getChatsLegacy, createChat, deleteChat, getSession, compactSession,
getWorkers, createWorkspaceItem, deleteWorkspaceItem, getSkills,
getSkillDetail, deleteSkill, getMemories, getMemoryDetail, createMemory,
updateMemory, deleteMemory, getGitStatus, getGitChanges, listFiles,
getQueuedMessages, getNalarConfig, saveNalarConfig, deleteProfile,
getGitFileDiff, readGitFile, readFileContent, writeFileContent,
stageGitFiles
```

Wait — `readFileContent` and `writeFileContent` ARE Pattern A but they go on the opt-out list. So Pattern A opt-IN is 50 - 2 = 48 functions. Re-classifying:

**Pattern A, opt-in (auto-fire notification):** 48 functions (all except `readFileContent`, `writeFileContent`, and the Pattern B `sendChatMessage`).

- [ ] **Step 5.1.2: Refactor each function**

For each Pattern A function:

**Before:**
```ts
export async function foo(): Promise<Foo> {
  const response = await fetch(`${API_BASE}/foo`, { method: 'GET' })
  if (!response.ok) {
    const text = await response.text().catch(() => '')
    console.error(`foo HTTP ${response.status}: ${text}`)
    throw new Error(`HTTP ${response.status}`)
  }
  return response.json()
}
```

**After:**
```ts
export async function foo(): Promise<Foo> {
  return await apiFetch<Foo>('/foo', { method: 'GET' })
}
```

Special cases to handle in-line:
- If the function originally passed `JSON.stringify(...)` as the body, change to `body: { ... }` and let `apiFetch` serialize it.
- If the function originally passed `headers: { 'Content-Type': 'application/json', ... }`, drop the Content-Type header (apiFetch sets it automatically).
- If the function originally had `await response.json()` and the response is empty (no body), this could fail in the original code too. Preserve original behavior.

- [ ] **Step 5.1.3: Run type-check after each batch of ~10 refactors**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 15`

Expected: clean build. If any errors appear, fix before continuing to the next batch. **Do NOT batch-refactor all 48 then check** — incremental checks catch issues early.

Recommended batches (top-to-bottom in the file):
1. `healthCheck`, `getSystemFolder`, `listFolder`, `getWorkspaces`, `getWorkspacesItems` (5)
2. `createWorkspace`, `getWorkspace`, `deleteWorkspace`, `updateWorkspace`, `reorderWorkspaces`, `reorderWorkspaceItems` (6)
3. `getTasks`, `createTask`, `updateTask`, `updateTaskSimple`, `deleteTask`, `runRoutine` (6)
4. `updateSession`, `getChats`, `getChatsLegacy`, `createChat`, `deleteChat`, `compactSession` (6)
5. `getWorkers`, `createWorkspaceItem`, `deleteWorkspaceItem`, `getSkills`, `getSkillDetail`, `deleteSkill` (6)
6. `getMemories`, `getMemoryDetail`, `createMemory`, `updateMemory`, `deleteMemory`, `getGitStatus` (6)
7. `getGitChanges`, `listFiles`, `getQueuedMessages`, `getNalarConfig`, `saveNalarConfig`, `deleteProfile` (6)
8. `getGitFileDiff`, `readGitFile`, `stageGitFiles` (3)

= 44 functions. The remaining 4 (`readFileContent`, `writeFileContent`, `sendChatMessage`, `getChatHistory`) are handled in Task 5.2.

- [ ] **Step 5.1.4: Run all tests after each batch**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 5`

Expected: 54/54 still pass (the refactor preserves behavior; tests don't break).

- [ ] **Step 5.1.5: Commit after each batch (or once at the end of the task)**

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "refactor(api): migrate 48 Pattern A functions to apiFetch wrapper"
```

---

### Task 5.2: Refactor Pattern A opt-out + Pattern B (5 functions)

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 5.2.1: Refactor `readFileContent` (Pattern A, opt-out)**

**Before** (around line 1610):
```ts
export async function readFileContent(cwd: string, filePath: string): Promise<ReadFileResponse> {
  const response = await fetch(`${API_BASE}/files/read?cwd=${encodeURIComponent(cwd)}&path=${encodeURIComponent(filePath)}`)
  if (!response.ok) {
    console.error(`readFileContent HTTP ${response.status}`)
    throw new Error(`HTTP ${response.status}`)
  }
  return response.json()
}
```

**After:**
```ts
export async function readFileContent(cwd: string, filePath: string): Promise<ReadFileResponse> {
  return await apiFetch<ReadFileResponse>(
    `/files/read?cwd=${encodeURIComponent(cwd)}&path=${encodeURIComponent(filePath)}`,
    { silent: true },
  )
}
```

- [ ] **Step 5.2.2: Refactor `writeFileContent` (Pattern A, opt-out)**

Same shape as `readFileContent` — add `silent: true`.

- [ ] **Step 5.2.3: Refactor `getSession` (Pattern A, opt-out)**

`AppLayout.vue:357-374` (`fetchChatSessionCwd`) silently swallows the error to fall back to message-derived cwd. The toast would be wrong here — add `silent: true`.

- [ ] **Step 5.2.4: Refactor `getChatHistory` (Pattern A, opt-out)**

Same reasoning as `getSession` — used inside `fetchChatSessionCwd` as a fallback.

- [ ] **Step 5.2.5: Refactor `sendChatMessage` (Pattern B)**

**Before** (around line 501-566):
```ts
export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
  imageUrls?: string[],
  selectedProfile?: string,
): Promise<{ status: string }> {
  let body: string
  try {
    body = JSON.stringify({ session_id: sessionId, queue_message: message, ... })
  } catch (serializeError) {
    console.error('Failed to serialize request body:', serializeError)
    return { status: 'invalid_payload' }
  }
  try {
    JSON.parse(body)
  } catch (parseError) {
    console.error('Serialized body failed round-trip validation:', parseError)
    return { status: 'invalid_payload' }
  }
  try {
    const response = await fetch(`${API_BASE}/llm/session`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body })
    if (!response.ok) {
      const errorText = await response.text().catch(() => '')
      console.error(`HTTP ${response.status}: ${errorText}`)
      if (response.status === 400) return { status: 'bad_request' }
      if (response.status === 422) return { status: 'unprocessable_entity' }
      throw new Error(`HTTP ${response.status}`)
    }
    const text = await response.text()
    try {
      return JSON.parse(text)
    } catch {
      console.error('Response is not valid JSON:', text)
      return { status: 'invalid_response' }
    }
  } catch (error) {
    console.error('Request failed:', error)
    return { status: 'offline' }
  }
}
```

**After:**
```ts
export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
  imageUrls?: string[],
  selectedProfile?: string,
): Promise<{ status: string }> {
  // Join image URLs with pipe separator (matches backend convention)
  const imageUrlsStr = imageUrls?.join('|') || ''

  try {
    const result = await apiFetch<{ status: string }>(
      '/llm/session',
      {
        method: 'POST',
        body: {
          session_id: sessionId,
          queue_message: message,
          allowed_tools: 'all',
          cwd_session: cwdSession,
          image_urls: imageUrlsStr,
          selected_profile_model: selectedProfile || '',
        },
        silent: true,
      },
    )
    return result
  } catch (err) {
    if (err instanceof ApiError) {
      if (err.status === 400) return { status: 'bad_request' }
      if (err.status === 422) return { status: 'unprocessable_entity' }
      return { status: 'http_error' }
    }
    return { status: 'offline' }
  }
}
```

Note: the JSON-serialize-failure and round-trip-validation blocks are now obsolete (apiFetch handles serialization). The "invalid_response" branch is also obsolete (apiFetch handles JSON parsing). If those failure modes are truly unreachable (because `JSON.stringify` and `response.json()` only throw on extreme conditions), the simplification is correct. If they ARE reachable in production, add a try/catch wrapper around the apiFetch call to preserve the `'invalid_payload'` / `'invalid_response'` return values.

**Fallback decision:** Keep the simpler form above. Add a regression test (Step 5.2.7) that exercises the happy path. If the round-trip validation was paranoid-only, the simplification is safe.

- [ ] **Step 5.2.6: Run type-check**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 15`

Expected: clean build. If `readFileContent` / `writeFileContent` had callers that didn't handle the new `ApiError` (vs the old `Error`), the error type may now be narrower — verify all call sites still compile.

- [ ] **Step 5.2.7: Run all tests**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 5`

Expected: 54/54 still pass.

- [ ] **Step 5.2.8: Add a regression test for `sendChatMessage` 422 path**

Create: `src/apps/desktop/src/__tests__/sendChatMessage.spec.ts`

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { sendChatMessage, ApiError } from '../api/index'

describe('sendChatMessage', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  it('returns { status: "bad_request" } on 400', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"error":"bad"}', { status: 400 }),
    )
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'bad_request' })
  })

  it('returns { status: "unprocessable_entity" } on 422', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"error":"bad"}', { status: 422 }),
    )
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'unprocessable_entity' })
  })

  it('returns { status: "offline" } on network failure', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('NetworkError'))
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'offline' })
  })

  it('returns parsed body on 2xx', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"status":"queued"}', { status: 200, headers: { 'Content-Type': 'application/json' } }),
    )
    expect(await sendChatMessage('s1', 'msg', '/cwd')).toEqual({ status: 'queued' })
  })

  it('does not fire a notification on 400 (silent: true)', async () => {
    const { useNotificationStore } = await import('../stores/notifications')
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('{"error":"bad"}', { status: 400 }),
    )
    await sendChatMessage('s1', 'msg', '/cwd')
    const store = useNotificationStore()
    expect(store.notifications).toHaveLength(0)
  })
})
```

Run: `cd src/apps/desktop && timeout 120 bunx vitest run sendChatMessage.spec.ts 2>&1 | tail -n 10`

Expected: 5/5 pass.

- [ ] **Step 5.2.9: Commit**

```bash
git add src/apps/desktop/src/api/index.ts src/apps/desktop/src/__tests__/sendChatMessage.spec.ts
git commit -m "refactor(api): migrate 5 opt-out/Pattern-B functions to apiFetch"
```

---

### Task 5.3: Final verification + manual smoke test

- [ ] **Step 5.3.1: Run full type-check + build**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`

Expected: clean build. No TypeScript errors. The vite bundle for the webapp is produced.

- [ ] **Step 5.3.2: Run full test suite**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 10`

Expected: 54 baseline tests + 5 new `sendChatMessage` tests = **59 passing**, 0 failures.

- [ ] **Step 5.3.3: Manual smoke test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 180 zig build install:linux:system 2>&1 | tail -n 5  # builds nalar binary
./zig-out/bin/nalar --port 8080 &
sleep 3
curl -X DELETE http://127.0.0.1:8080/api/workspaces/does-not-exist
# Expected: backend returns 4xx (e.g. 404 or 400) — frontend SHOULD show a toast.
kill %1 2>/dev/null || true
```

Then in the browser at `http://localhost:8080`:
1. Trigger an API failure (e.g. delete a non-existent workspace, or rename a profile with an empty name).
2. Confirm: red toast appears bottom-right with the server's error message.
3. Confirm: × button dismisses the toast immediately.
4. Wait 5 seconds on a non-dismissed toast → confirm: it auto-dismisses.
5. Trigger 2 failures in quick succession → confirm: toasts stack vertically.
6. Trigger a code-editor error (open a non-existent file) → confirm: ONLY the fullscreen error view shows, NO toast (because `silent: true` was set on `readFileContent`).

- [ ] **Step 5.3.4: Final commit**

If any smoke-test fixes were needed:
```bash
git add -A
git commit -m "fix(notifications): smoke-test fixes"
```

Otherwise skip.

---

## Definition of done

- [ ] All 7 new files exist and pass their tests
- [ ] All 55 API functions route through `apiFetch`
- [ ] `bun run build` is clean
- [ ] `bunx vitest run` is green (59+ tests, 0 failures)
- [ ] Manual smoke test confirms toasts appear for HTTP 4xx/5xx and do NOT appear for the 5 opt-out cases
- [ ] No regressions in existing functionality (SettingsView success/error toast, code editor fullscreen error, SseStatusBadge)
- [ ] All commits pushed to main

---

## Risk checklist (during execution)

- [ ] **Double-toast check**: after Task 5.1, grep for any caller of `apiFetch`d functions that ALSO has its own error UI. Verify the function is on the opt-out list.
- [ ] **Type narrowing check**: `apiFetch` throws `ApiError` (a specific class). Any caller that previously did `catch (err)` and accessed `err.message` may now see a different message (`HTTP {status} {statusText}`). Verify call sites still work.
- [ ] **Headers passthrough check**: apiFetch sets `Content-Type: application/json` by default. If a function originally had `Content-Type: text/plain` or other custom headers, the override pattern `{ 'Content-Type': 'application/json', ...init.headers }` may overwrite them. Audit each function with non-JSON Content-Type.
- [ ] **204 No Content check**: Functions that previously returned `response.json()` on a 204 response would have thrown (JSON parse error). apiFetch now returns `undefined` for 204. If a caller expected the throw, audit and adjust.
- [ ] **Network failure path**: apiFetch does NOT notify on fetch rejection. Callers that previously did `console.error('Request failed:', error)` lose that log. Decide if that's a regression (probably not — the toast is the user-facing version; the console log is for debugging).