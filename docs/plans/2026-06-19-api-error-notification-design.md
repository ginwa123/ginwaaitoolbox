# Plan: Global error notification for API failures (4xx/5xx)

> **Goal:** Surface every HTTP 4xx/5xx response from `src/apps/desktop/src/api/index.ts`
> as a user-visible toast notification, so silent `console.error` failures
> become actionable UI feedback.

---

## 1. Symptom (what the user sees today)

When an API call to the backend fails (e.g. backend returns 400 for a
malformed body, 404 for a missing workspace, 500 for an unhandled
exception), the failure is **invisible to the user**:

- `api/index.ts:546` (and 20+ similar sites) logs `console.error(`HTTP ${status}: ${errorText}`)`.
- The error is also `throw`n (or returned as `{ status: 'offline' }`) so
  the caller can react — but most callers just `.catch` and ignore it,
  because there is no UI affordance for surfacing the error.
- The user sees no feedback. The button click appears to do nothing.
  They do not know whether the network is down, the server rejected
  their input, or the request succeeded.

The only existing user-visible error notification is the inline toast
in `SettingsView.vue:124-133`, which is **scoped to the settings page**
— it cannot be triggered from anywhere else.

The existing `SseStatusBadge` covers SSE connection state but not
regular HTTP `fetch()` errors.

---

## 2. Design (what we are building)

### 2.1 Components

| File | Purpose |
|------|---------|
| `src/apps/desktop/src/components/ErrorNotification.vue` | Toast UI: red bg, message + details, dismiss × button, 5s auto-dismiss. |
| `src/apps/desktop/src/components/NotificationContainer.vue` | Mounts once in `AppLayout.vue`. Renders one `<ErrorNotification>` per entry in the store. |
| `src/apps/desktop/src/stores/notifications.ts` | Pinia store: `notifications[]`, `notifyError(message, details?)`, `dismiss(id)`, `dismissAll()`. |
| `src/apps/desktop/src/api/index.ts` (modified) | Add `apiFetch(url, opts)` wrapper + `ApiError` class. Refactor 55 exported API functions to use it. |

### 2.2 Data flow

```
component → api.X(...) → apiFetch() → fetch() → 4xx/5xx
                                          ↓
                                    notifyError(...)
                                          ↓
                                    store.notifications.push
                                          ↓
                                    NotificationContainer renders ErrorNotification[]
                                          ↓
                                    setTimeout(5000) → dismiss(id)
```

### 2.3 `apiFetch` wrapper contract

```ts
interface ApiFetchOptions extends Omit<RequestInit, 'body'> {
  body?: unknown
  /** When true, skip the error notification (caller handles UI inline) */
  silent?: boolean
}

export async function apiFetch<T = unknown>(
  url: string,
  opts: ApiFetchOptions = {},
): Promise<T>

export class ApiError extends Error {
  constructor(public status: number, public statusText: string, public body: string)
}
```

**Auto-trigger behavior:**
- On any 4xx/5xx response, by default, the wrapper:
  1. Reads the response body (best-effort, `await response.text().catch(() => '')`).
  2. Tries to parse it as JSON and extract a `.error` field. If present, that becomes the notification message; the full body becomes `details`.
  3. If parsing fails or no `.error` field exists, message is `HTTP {status} {statusText}`, details is the raw body.
  4. Calls `useNotificationStore().notifyError(message, details)`.
  5. Throws `new ApiError(status, statusText, body)` for the caller to handle (e.g. for fallback UI).

- When `opts.silent === true`, the notification is suppressed. The wrapper still throws.

- 2xx responses: parse JSON and return (unchanged behavior).

- Network failures (fetch rejects): do **not** fire a notification (those are
  connection-level failures already covered by the `SseStatusBadge` for SSE,
  and a global "offline" toast for plain fetch is out of scope). The fetch
  rejection propagates to the caller.

### 2.4 Notification store

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

export const useNotificationStore = defineStore('notifications', () => {
  const notifications = ref<Notification[]>([])
  let counter = 0

  function notifyError(message: string, details?: string) {
    counter += 1
    const id = `n_${Date.now()}_${counter}`
    notifications.value.push({ id, message, details, createdAt: Date.now() })
    setTimeout(() => dismiss(id), 5000)
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

- Counter-based unique IDs (no `crypto.randomUUID` dependency).
- Auto-cleanup via `setTimeout(5000)` per notification.
- **Stacked**: each new error pushes onto the array; the container renders bottom-up.
- **No dedup in v1** (would add complexity; revisit if it becomes a problem).

### 2.5 `ErrorNotification.vue` component

```vue
<script setup lang="ts">
import { useNotificationStore } from '../stores/notifications'

const props = defineProps<{
  message: string
  details?: string
}>()

const emit = defineEmits<{ dismiss: [] }>()

const store = useNotificationStore()
// `id` is passed via a sibling prop in the container; here we just emit.
</script>

<template>
  <div
    class="fixed bottom-6 right-6 px-4 py-3 rounded-lg shadow-lg z-50 max-w-md"
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
        @click="emit('dismiss')"
        aria-label="Dismiss"
      >×</button>
    </div>
  </div>
</template>
```

- Position: `fixed bottom-6 right-6` (matches the existing SettingsView toast so the user does not see the position jump).
- Color: `var(--color-red)` (matches the existing error variant).
- Dismiss: manual × button OR 5s auto-dismiss (driven by the store).
- Accessibility: `role="alert"` so screen readers announce the error.
- `details` accordion collapsed by default (saves vertical space; the user can expand to see the raw body for debugging).

### 2.6 `NotificationContainer.vue` component

```vue
<script setup lang="ts">
import { useNotificationStore } from '../stores/notifications'
import ErrorNotification from './ErrorNotification.vue'

const store = useNotificationStore()
</script>

<template>
  <div class="fixed bottom-6 right-6 z-50 flex flex-col-reverse gap-2 pointer-events-none">
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

- `flex-col-reverse` + `gap-2`: new errors push up; old ones stay at the bottom until they dismiss.
- `pointer-events-none` on the wrapper + `pointer-events-auto` on each toast so clicks pass through the gaps between toasts.

### 2.7 Mount point in `AppLayout.vue`

Add 1 import + 1 line in the template:

```vue
<!-- after the <RightSidebar> closing div, sibling to all views -->
<NotificationContainer />
```

### 2.8 API function refactor strategy

All 55 exported functions in `src/apps/desktop/src/api/index.ts` currently
follow one of these patterns:

```ts
// Pattern A: throws on non-OK
const response = await fetch(url, opts)
if (!response.ok) {
  const text = await response.text().catch(() => '')
  console.error(`HTTP ${response.status}: ${text}`)
  throw new Error(`HTTP ${response.status}`)
}
return response.json()

// Pattern B: returns status string instead of throwing
const response = await fetch(url, opts)
if (!response.ok) {
  const text = await response.text().catch(() => '')
  console.error(`HTTP ${response.status}: ${text}`)
  if (response.status === 400) return { status: 'bad_request' }
  throw new Error(`HTTP ${response.status}`)
}
```

**Refactor target (Pattern A):**
```ts
return await apiFetch<T>(url, { ...opts, silent: <opt-out cases> })
```

**Refactor target (Pattern B):**
```ts
try {
  return await apiFetch<T>(url, { ...opts, silent: true })
} catch (err) {
  if (err instanceof ApiError) {
    if (err.status === 400) return { status: 'bad_request' }
    return { status: 'http_error' }
  }
  return { status: 'offline' }
}
```

**Opt-out cases (`silent: true`):**
- `readFileContent`, `writeFileContent` — `AppLayout.vue` shows a fullscreen error view via `codeEditorError` ref (lines 224, 268, 312, 329). A toast would double-up.
- `getSession` — `fetchChatSessionCwd` in AppLayout silently swallows and falls back to message-derived cwd.
- `getChatHistory` — `fetchChatSessionCwd` fallback.
- `sendChatMessage` — the function's own return shape (`{ status: 'offline' | 'bad_request' | ... }`) is the caller's error contract.
- All other 50 functions: default `silent: false` (auto-fire).

(Exact opt-out list is decided during implementation; the rule is "if the
caller has a meaningful inline error UI, opt out; otherwise auto-fire.")

### 2.9 Out of scope (v1)

- **SSE connection errors** — the `SseStatusBadge` already shows state. `SseClient` reconnect errors stay as `console.error`.
- **Non-API `console.error` calls** — in `sseClient.ts`, `scrollLogger.ts`, `App.vue`, etc. Stays as-is.
- **The inline `SettingsView.vue` toast** — separate concern (user action feedback for forms). Could be unified in a follow-up.
- **Notification dedup** — multiple identical errors stack. Add if/when it becomes noise.
- **Retry logic, sounds, OS notifications, persistence to localStorage**.

---

## 3. Testing

### 3.1 Unit tests

| File | Coverage |
|------|----------|
| `src/apps/desktop/src/__tests__/notifications.spec.ts` | Store: `notifyError` adds entry, `setTimeout` auto-dismisses, `dismiss(id)` removes, multiple notifications stack in order. |
| `src/apps/desktop/src/__tests__/ErrorNotification.spec.ts` | Component: renders message, renders details accordion when `details` is set, × button emits `dismiss`. |
| `src/apps/desktop/src/__tests__/NotificationContainer.spec.ts` | Container: renders one `<ErrorNotification>` per store entry, passes `dismiss` handler. |
| `src/apps/desktop/src/__tests__/apiFetch.spec.ts` | Wrapper: 2xx returns parsed body, 4xx calls `notifyError` and throws `ApiError`, 5xx same, `silent: true` skips notification, network failure (fetch rejects) does NOT call `notifyError`. |

### 3.2 Manual smoke test

After implementation:
1. `timeout 120 bun run build` — type-check + bundle. Must be clean.
2. `timeout 120 bunx vitest run` — all tests green.
3. Start `nalar` on port 8080 (NOT 8081 — see MANDATORY rule).
4. Trigger a deliberate 4xx (e.g. try to delete a non-existent workspace) → confirm red toast appears bottom-right, auto-dismisses after 5s.
5. Trigger a deliberate 5xx (if possible by killing the backend mid-request) → same path.
6. Verify the code editor's fullscreen error view does NOT also show a toast for `readFileContent` failures.
7. Verify the existing SettingsView success/error toasts still work.

---

## 4. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| **Double-toast**: a function opts out by mistake, OR a function does NOT opt out when it should have | List of opt-out cases in §2.8 is decided during implementation. Manual smoke test (§3.2) covers the most common cases. |
| **Test pollution**: `setTimeout(5000)` in the store leaks timers across tests | Tests use `vi.useFakeTimers()` and `vi.advanceTimersByTime(5000)`. The store is reset between tests via `beforeEach(() => setActivePinia(createPinia()))`. |
| **Stacked notifications overflow viewport** | Cap stack at 5 visible; older ones auto-collapse into a "+3 more" summary. (Defer to follow-up if not needed in v1.) |
| **`fetch` error path confusion**: `!response.ok` vs `fetch` rejection | `apiFetch` only notifies on `!response.ok`. Network failures (fetch rejects) propagate without notification, matching the user's "HTTP 400-500" intent. |
| **Vitest can't resolve `vue-tsc`-only types** | Use the same pattern as existing tests: `mount(...)` from `@vue/test-utils`, `setActivePinia(createPinia())` from `pinia`. The 31-test baseline already passes. |

---

## 5. File summary

**New files (7):**
- `src/apps/desktop/src/components/ErrorNotification.vue`
- `src/apps/desktop/src/components/NotificationContainer.vue`
- `src/apps/desktop/src/stores/notifications.ts`
- `src/apps/desktop/src/__tests__/notifications.spec.ts`
- `src/apps/desktop/src/__tests__/ErrorNotification.spec.ts`
- `src/apps/desktop/src/__tests__/NotificationContainer.spec.ts`
- `src/apps/desktop/src/__tests__/apiFetch.spec.ts`

**Modified files (2):**
- `src/apps/desktop/src/api/index.ts` — add `apiFetch`, `ApiError`, refactor 55 functions
- `src/apps/desktop/src/components/AppLayout.vue` — mount `<NotificationContainer />`

**Estimated diff size:** ~600 lines added (mostly the 55 mechanical function refactors + tests), ~50 lines removed (the inline `console.error` blocks).