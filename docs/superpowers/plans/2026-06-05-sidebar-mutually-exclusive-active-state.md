# Sidebar Mutually Exclusive Active State - Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sidebar's three sources of "active" state — Chats list item, workspace item, and task — mutually exclusive. At any moment, AT MOST ONE of the three can be highlighted, never two.

**Architecture:** Keep the existing state distribution (chat state in `navigationStore`; workspace-item/task state in `workspacesStore`) but add explicit "clear the other" side effects at every place that transitions between the three modes. The cleanup is performed in the components that already orchestrate both stores (`ChatsList.vue` and `AppLayout.vue`).

**Tech Stack:** Vue 3 (Composition API), Pinia, Vue Router, TypeScript, Vitest.

---

## Context

### The bug

Screenshot from the user shows a "tanya-dong" chat highlighted in the Chats list **and** the "be" project under the `agentic_coding_zig` workspace showing a small aqua active dot. The user reports: *"there's an active state in list Chats and task — it should be either chats or workspace items"*.

### Three "active" surfaces in the sidebar

| Surface | What shows as active | Where the state lives | Cleared by |
|---|---|---|---|
| Chats list row | `background: var(--semantic-active-bg)` + `color: var(--semantic-active-text)` | `ChatsList.navItems[i].active` (local `ref`) | `setActive` / `createChat` / `removeChat` in `ChatsList.vue` |
| Workspace item row | `background: var(--semantic-active-bg)` + aqua dot indicator | `workspacesStore.activeWorkspaceItemId` | `setActiveWorkspaceItem` in `stores/workspaces.ts` |
| Task row (under expanded item) | `color: var(--color-aqua)` + `background: var(--semantic-active-bg)` | `workspacesStore.activeTaskId` | `setActiveTask` / `deleteTask` in `stores/workspaces.ts` |

### Where the cross-state reset is currently broken

A single store-level invariant: "navigating to a chat clears the active workspace item, and navigating to a workspace item or task clears the active chat" should hold at every transition. Today, only the **task → chat** direction is enforced (via `setActiveTask` calling `clearActiveChat` inside `stores/navigation.ts:102-111`). The **chat → workspace-item** direction is enforced in only ONE of the five places that select a chat:

| Selection path | Calls `setActiveWorkspaceItem(null)`? | File:line |
|---|---|---|
| `Sidebar.handleChatsNavigate` for `chat-…` (called via old `emit('navigate', 'chat-X')`) | ✅ Yes | `components/Sidebar.vue:194` |
| `Sidebar.handleChatsNavigate` for `chat-…` (called when `loadChats` restores the active session) | ✅ Yes | `components/Sidebar.vue:194` |
| `Sidebar.handleSelectItem` (workspace item click) — does the **other** direction | ✅ Yes (resets chat) | `components/Sidebar.vue:229-237` |
| `ChatsList.setActive` (chat row click) | ❌ No — the bug | `components/ChatsList.vue:208-216` |
| `ChatsList.createChat` (new chat button) | ❌ No | `components/ChatsList.vue:198-206` |
| `ChatsList.removeChat` (active chat deleted) | ❌ No | `components/ChatsList.vue:223-244` |
| `AppLayout.handleNavigate` for `chat-…` view (URL→state sync) | ❌ No | `components/AppLayout.vue:78-100` |
| `AppLayout` URL watch `view === 'chat'` (browser back/forward) | ❌ No | `components/AppLayout.vue:471-481` |
| `AppLayout.onMounted` for `view === 'chat'` (page reload) | ❌ No | `components/AppLayout.vue:38-40` |

So 6 out of 9 transition paths skip the reset. The bug reproduces on: (1) clicking any chat row, (2) creating a new chat, (3) deleting the active chat, (4) deep-linking to a chat URL, (5) page reload while a workspace item was previously active.

### Existing patterns to follow

- `workspacesStore.setActiveWorkspaceItem(null)` is the standard "clear workspace item" call. Already used correctly in `Sidebar.vue:194` and `Sidebar.vue:239`.
- `ChatsList` already imports `useWorkspacesStore` indirectly via the parent `Sidebar`. We need to add the import to `ChatsList.vue` directly.
- `AppLayout` already imports both `useNavigationStore` and `useWorkspacesStore`. We just need to add the reset calls.

---

## File Structure

| File | Change | Reason |
|---|---|---|
| `src/apps/desktop/src/components/ChatsList.vue` | Modify `setActive`, `createChat`, `removeChat` to also call `workspacesStore.setActiveWorkspaceItem(null)`. Add import for `useWorkspacesStore`. | Fixes 3 of the 6 broken paths |
| `src/apps/desktop/src/components/AppLayout.vue` | Modify `handleNavigate` for `chat-…` and `view === 'chat'` cases, plus the `route.query` watch `view === 'chat'` branch, and the `onMounted` `view === 'chat'` branch, to also call `workspacesStore.setActiveWorkspaceItem(null)` | Fixes the remaining 3 broken paths |
| `src/apps/desktop/src/__tests__/sidebarActiveState.spec.ts` | New Vitest spec covering the new behavior | Regression guard |

No backend changes. No store changes — the store APIs already exist and are correct; only the call sites that need to be fixed.

---

## Chunk 1: Reproduce the bug with a failing test, then fix `ChatsList.vue`

### Files
- Create: `src/apps/desktop/src/__tests__/sidebarActiveState.spec.ts`
- Modify: `src/apps/desktop/src/components/ChatsList.vue:1-9` (imports), `198-206` (createChat), `208-216` (setActive), `223-244` (removeChat)

- [ ] **Step 1: Write a failing test that reproduces the bug**

Create `src/apps/desktop/src/__tests__/sidebarActiveState.spec.ts`:

```ts
/**
 * Regression tests for the "active state leaks across Chats ↔ workspace
 * item" bug. Selecting a chat must clear `activeWorkspaceItemId` in the
 * workspaces store, and vice versa. Before the fix these tests fail.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'

import * as api from '../api'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import ChatsList from '../components/ChatsList.vue'
import { mount } from '@vue/test-utils'

function makeLocalStorageStub(): Storage {
  const backing = new Map<string, string>()
  return {
    get length() {
      return backing.size
    },
    clear: () => backing.clear(),
    getItem: (k) => backing.get(k) ?? null,
    key: (i) => Array.from(backing.keys())[i] ?? null,
    removeItem: (k) => {
      backing.delete(k)
    },
    setItem: (k, v) => {
      backing.set(k, v)
    },
  }
}

function mountChatsList() {
  // Stub router so router.replace doesn't blow up
  const router = { replace: vi.fn() }
  return mount(ChatsList, {
    global: {
      mocks: { $router: router },
      provide: { processingState: { value: {} } },
    },
  })
}

describe('sidebar active-state exclusivity', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // Default: empty chats list
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('clicking a chat row clears activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_42')
    expect(ws.activeWorkspaceItemId).toBe('item_42')

    const nav = useNavigationStore()
    nav.setActiveWorkspaceItemBridge = undefined // ensure we use the real method

    const wrapper = mountChatsList()
    await nextTick()
    // Inject a fake chat into the list
    // @ts-expect-error: pushing into the local navItems for test purposes
    wrapper.vm.navItems = [
      { id: 'chat_abc', name: 'My Chat', active: false, processing: false },
    ]
    // @ts-expect-error: invoke internal method
    await wrapper.vm.setActive('chat_abc')

    expect(ws.activeWorkspaceItemId).toBeNull()
  })

  it('createChat clears activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_99')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: invoke internal method
    wrapper.vm.createChat()

    expect(ws.activeWorkspaceItemId).toBeNull()
  })

  it('removing the active chat clears activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_77')
    const nav = useNavigationStore()
    nav.setActiveChat('chat_del', 'Doomed Chat')

    const wrapper = mountChatsList()
    await nextTick()
    // @ts-expect-error: push a fake active chat
    wrapper.vm.navItems = [
      { id: 'chat_del', name: 'Doomed Chat', active: true, processing: false },
    ]
    vi.spyOn(api, 'deleteChat').mockResolvedValue(undefined)
    // @ts-expect-error: invoke internal method
    await wrapper.vm.removeChat('chat_del')

    expect(ws.activeWorkspaceItemId).toBeNull()
  })
})
```

Notes on the test:
- The test invokes internal component methods (`setActive`, `createChat`, `removeChat`) directly via `wrapper.vm`. This is acceptable because the bug is at those exact methods.
- We push a fake `navItems` entry to skip the SSE/SSE-driven load. The bug is about *what happens on click*, not about how the list was populated.
- `processingState` is injected because the watcher in `ChatsList.vue:108-117` reads it during the test lifecycle.

- [ ] **Step 2: Run the test and confirm it fails (bug reproduces)**

Run: `cd src/apps/desktop && bunx vitest run src/__tests__/sidebarActiveState.spec.ts 2>&1 | tail -n 40`
Expected: 3 failing tests, each with a message containing `expected 'item_42' to be null` (or the equivalent). This proves the bug is real and the tests will catch it.

- [ ] **Step 3: Fix `ChatsList.setActive` to clear the workspace item**

Modify `src/apps/desktop/src/components/ChatsList.vue`:

Add the workspaces store import at the top of `<script setup>` (after the existing `useNavigationStore` import on line 4):

```ts
import { useWorkspacesStore } from '../stores/workspaces'
```

Then in the same `<script setup>`, add the store instance after the navigation store line:

```ts
const workspacesStore = useWorkspacesStore()
```

Replace the `setActive` function (lines 208-216):

```ts
const setActive = (id: string) => {
  const chat = navItems.value.find((item) => item.id === id)
  const chatName = chat?.name || ''
  navigationStore.setActiveChatName(chatName)
  // Mutually exclusive active state: chat wins, clear workspace item.
  workspacesStore.setActiveWorkspaceItem(null)
  navItems.value = navItems.value.map((item) => ({ ...item, active: item.id === id }))
  navigationStore.setActiveChat(id, chatName)
  // Update URL with session ID
  router.replace({ path: '/app', query: { view: 'chat', session: id } })
}
```

- [ ] **Step 4: Run the first test, confirm it passes**

Run: `cd src/apps/desktop && bunx vitest run src/__tests__/sidebarActiveState.spec.ts -t "clicking a chat row" 2>&1 | tail -n 20`
Expected: PASS for the "clicking a chat row" test. The other 2 still fail.

- [ ] **Step 5: Fix `ChatsList.createChat` to clear the workspace item**

In the same `ChatsList.vue`, replace `createChat` (lines 198-206):

```ts
const createChat = () => {
  const name = 'New Chat'
  const newChatId = `session-${Date.now()}`
  // Mutually exclusive active state: a brand-new chat wins, clear workspace item.
  workspacesStore.setActiveWorkspaceItem(null)
  navItems.value.forEach((item) => (item.active = false))
  navItems.value.unshift({ id: newChatId, name, active: true, processing: false })
  // Update navigation store
  navigationStore.setActiveChat(newChatId, name)
  emit('navigate', `chat-${newChatId}`, name)
}
```

- [ ] **Step 6: Run the second test, confirm it passes**

Run: `cd src/apps/desktop && bunx vitest run src/__tests__/sidebarActiveState.spec.ts -t "createChat" 2>&1 | tail -n 20`
Expected: PASS. The third test still fails.

- [ ] **Step 7: Fix `ChatsList.removeChat` to clear the workspace item when the active chat is removed**

In `ChatsList.vue`, replace `removeChat` (lines 223-244). The reset only matters if the *active* chat is the one being removed — but doing it unconditionally is simpler and matches the existing "always clear the other side" pattern:

```ts
const removeChat = async (chatId: string) => {
  const index = navItems.value.findIndex((item) => item.id === chatId)
  if (index !== -1) {
    const wasActive = navItems.value[index]?.active ?? false
    navItems.value.splice(index, 1)
    // Clear from navigation store if this was the active chat
    if (wasActive) {
      navigationStore.clearActiveChat()
      // Mutually exclusive active state: deleting the active chat means
      // we drop back to "no chat selected" — also clear the workspace item.
      workspacesStore.setActiveWorkspaceItem(null)
    }
    try {
      await api.deleteChat(chatId)
    } catch (err) {
      console.error('Failed to delete chat:', err)
    }
    if (wasActive && navItems.value.length > 0 && navItems.value[0]) {
      navItems.value[0].active = true
      const nextChat = navItems.value[0]
      navigationStore.setActiveChat(nextChat.id, nextChat.name)
      router.replace({ path: '/app', query: { view: 'chat', session: nextChat.id } })
    }
  }
}
```

- [ ] **Step 8: Run all 3 new tests, confirm all pass**

Run: `cd src/apps/desktop && bunx vitest run src/__tests__/sidebarActiveState.spec.ts 2>&1 | tail -n 20`
Expected: 3 passed.

- [ ] **Step 9: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/ChatsList.vue src/apps/desktop/src/__tests__/sidebarActiveState.spec.ts
git commit -m "fix(sidebar): clear workspace-item active state when selecting a chat

ChatsList.setActive/createChat/removeChat were setting the active chat
without resetting workspacesStore.activeWorkspaceItemId. Result: the
aqua active-dot on a workspace item stayed on while a chat was also
highlighted. This adds the explicit reset on all three code paths and
guards with a regression test."
```

---

## Chunk 2: Fix `AppLayout.vue` URL-driven chat navigation

The ChatsList fix covers user-initiated chat selection. The remaining broken paths are all *URL-driven* — they fire when the user reloads the page, hits back/forward, or follows a deep link to `?view=chat&session=…` while the workspaces store still has an `activeWorkspaceItemId` from a previous session. Fix them all in `AppLayout.vue` (which is the single point of truth for "URL → state" sync).

### Files
- Modify: `src/apps/desktop/src/components/AppLayout.vue:33-48` (onMounted), `78-100` (handleNavigate), `471-481` (URL watch)

- [ ] **Step 1: Fix `onMounted` chat-view branch**

Replace lines 38-40 in `AppLayout.vue`:

```ts
if (urlSessionId && urlView === 'chat') {
  // Clear any workspace-item active state from a prior session — the URL
  // is the source of truth, and it points to a chat.
  workspacesStore.setActiveWorkspaceItem(null)
  navigationStore.setActiveChat(urlSessionId, navigationStore.activeChatName)
  fetchChatSessionCwd(urlSessionId)
}
```

- [ ] **Step 2: Fix `handleNavigate` for `chat-…` view**

Replace lines 78-84 in `AppLayout.vue` (the `view.startsWith('chat-')` branch of `handleNavigate`):

```ts
if (view.startsWith('chat-')) {
  const chatSessionId = view.replace(/^chat-/, '')
  // Clear any workspace-item active state — navigating to a chat wins.
  workspacesStore.setActiveWorkspaceItem(null)
  navigationStore.setActiveChat(chatSessionId, chatName)
  // Fetch cwd for folder explorer and git
  fetchChatSessionCwd(chatSessionId)
  router.replace({ path: '/app', query: { view: 'chat', session: chatSessionId } })
}
```

Also fix the `view === 'chat'` branch (no session) right below it — clearing the workspace item is still correct because the URL is asserting "no chat selected, no workspace item selected":

```ts
} else if (view === 'chat') {
  workspacesStore.setActiveWorkspaceItem(null)
  navigationStore.clearActiveChat()
  chatSessionCwd.value = ''
  router.replace({ path: '/app', query: { view: 'chat' } })
}
```

- [ ] **Step 3: Fix the URL watch for `view === 'chat'`**

Replace lines 471-481 in `AppLayout.vue` (the `view === 'chat' && sessionId` branch of the `watch(() => route.query, …)` callback):

```ts
if (view === 'chat' && sessionId) {
  if (activeChatId.value !== `chat-${sessionId}`) {
    // URL changed to a different chat — clear any leftover workspace
    // item active state from a previous view.
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.setActiveChat(sessionId, navigationStore.activeChatName)
  }
  // Fetch cwd for folder explorer and git
  // Use localStorage cached value if available for immediate use
  const cachedCwd = localStorage.getItem(`session_cwd_${sessionId}`)
  if (cachedCwd) {
    chatSessionCwd.value = cachedCwd
  }
  await fetchChatSessionCwd(sessionId)
  // Cache the cwd for future use
  if (chatSessionCwd.value) {
    localStorage.setItem(`session_cwd_${sessionId}`, chatSessionCwd.value)
  }
}
```

Also clear the workspace item in the `!view || view === 'workspace'` branch right below (lines 488-491), because "no view" / "workspace" means "no chat selected":

```ts
} else if (!view || view === 'workspace') {
  // Clear chat session cwd when not in chat view
  chatSessionCwd.value = ''
  workspacesStore.setActiveWorkspaceItem(null)
}
```

- [ ] **Step 4: Add a regression test for the URL-driven path**

Append to `src/apps/desktop/src/__tests__/sidebarActiveState.spec.ts`:

```ts
import AppLayout from '../components/AppLayout.vue'
import { createMemoryHistory, createRouter } from 'vue-router'
import { createI18n } from 'vue-i18n' // adjust if i18n is not used
import { flushPromises } from '@vue/test-utils'

describe('AppLayout URL-driven chat navigation', () => {
  it('clears activeWorkspaceItemId when URL is ?view=chat&session=X on mount', async () => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem('item_stale')

    // Stub api.getSession to prevent real HTTP
    vi.spyOn(api, 'getSession').mockResolvedValue({
      session_id: 'chat_url',
      session_name: 'URL Chat',
      cwd: '/tmp',
      messages: [],
    })
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({ messages: [], cwd: '/tmp' })

    const router = createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/app', component: { template: '<div />' } }],
    })
    await router.push({ path: '/app', query: { view: 'chat', session: 'chat_url' } })
    await router.isReady()

    mount(AppLayout, {
      global: {
        plugins: [router],
        stubs: {
          // Stub out the heavy children — we only care about onMounted
          Sidebar: true,
          RightSidebar: true,
          GitFileViewer: true,
          SkillDetail: true,
          ChatView: true,
          Chats: true,
          SettingsView: true,
          CodeEditor: true,
        },
      },
    })
    await flushPromises()

    expect(ws.activeWorkspaceItemId).toBeNull()
  })
})
```

If `AppLayout` has more dependencies that fail to mount in tests (e.g. `provide` calls for `OPEN_IN_CODE_EDITOR_KEY`), narrow the stub list or add a tiny `__tests__/AppLayout.shim.ts` wrapper. The goal is to exercise `onMounted`, not the template.

- [ ] **Step 5: Run the new test, confirm it passes**

Run: `cd src/apps/desktop && bunx vitest run src/__tests__/sidebarActiveState.spec.ts 2>&1 | tail -n 30`
Expected: 4 passed (3 from Chunk 1 + 1 from Chunk 2).

- [ ] **Step 6: Run the full frontend test suite to confirm nothing else broke**

Run: `cd src/apps/desktop && bunx vitest run 2>&1 | tail -n 20`
Expected: all tests pass (was 31 before this change, should be 35 after: 31 + 3 from Chunks 1 + 1 from Chunk 2).

- [ ] **Step 7: Run the desktop build (NOT build-only — we need vue-tsc)**

Run: `cd src/apps/desktop && bun run build 2>&1 | tail -n 30`
Expected: clean build with no TypeScript errors.

- [ ] **Step 8: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/AppLayout.vue src/apps/desktop/src/__tests__/sidebarActiveState.spec.ts
git commit -m "fix(sidebar): clear workspace-item active state on URL-driven chat navigation

AppLayout handles three URL-to-state transitions that can leave a stale
activeWorkspaceItemId in the workspaces store: onMounted for view=chat,
handleNavigate for chat-… and chat-without-session, and the route.query
watcher for view=chat. All three now call workspacesStore.setActiveWorkspaceItem(null)
so the sidebar's active highlight stays in exactly one place."
```

---

## Chunk 3: Manual end-to-end verification

The unit tests prove the state plumbing is correct. The visual confirmation requires a real browser.

### Steps

- [ ] **Step 1: Start nalar on port 8080 (do NOT use 8081 — that's another agent's port)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
# Confirm no other nalar is running on 8080
lsof -i :8080 || echo "port 8080 free"
```

If port 8080 is free:
```bash
# Build and start the server in background
zig build
nohup ./zig-out/bin/nalar --port 8080 > /tmp/nalar-8080.log 2>&1 &
echo "PID: $!"
sleep 2
curl -s http://localhost:8080/api/health
```

- [ ] **Step 2: Open the desktop app, create a workspace with a project**

Open `http://localhost:5173` (Vite dev server) in a browser. Use the sidebar's "+" → "Add Workspace" → "Add Project" to create a workspace and project.

- [ ] **Step 3: Click on the workspace item**

Verify: the item shows the aqua active dot AND no chat in the Chats list is highlighted.

- [ ] **Step 4: Click a chat in the Chats list**

Verify:
- The chat row gets the active background highlight.
- The aqua dot on the workspace item is GONE (this was the bug).
- No task under the workspace is highlighted (already correct before this fix).

- [ ] **Step 5: Create a new chat**

Click the "+" button next to the Chats header.
Verify: the new chat row is active, and the workspace item is NOT active.

- [ ] **Step 6: Delete the active chat**

Click the X on the active chat row, confirm the deletion.
Verify: the next chat in the list (or the empty state) is shown, and the workspace item is NOT active.

- [ ] **Step 7: Deep-link to a chat while a workspace item is active**

Manually set `localStorage` to make a workspace item active (or just click a workspace item first), then navigate to `http://localhost:5173/?view=chat&session=ANY_ID` and reload the page.
Verify: the chat view loads and the workspace item is NOT active.

- [ ] **Step 8: Click a workspace item, then click the same chat twice**

Click a chat → workspace item loses its dot → click the same chat again → no flicker or state regression.

- [ ] **Step 9: Stop nalar**

```bash
kill $(lsof -t -i :8080) 2>/dev/null || true
```

- [ ] **Step 10: Commit any manual test notes**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add docs/superpowers/plans/2026-06-05-sidebar-mutually-exclusive-active-state.md
git commit -m "docs: add plan for sidebar-mutually-exclusive-active-state fix"
```

---

## Gotchas to watch for

1. **Don't import `useWorkspacesStore` twice in `ChatsList.vue`.** The store must be created once per Pinia instance. If the file already imports it transitively, just check that the explicit import is at the top.
2. **The `processingState` watcher in `ChatsList.vue:362-367` re-maps `navItems` on every change.** If you push a fake item with `processing: true` in the test, the watcher will rewrite it. Always set `processing: false` in the test fixture.
3. **The `watch(() => route.query, ...)` in `AppLayout.vue` fires AFTER `onMounted`.** So if a deep-link URL is set, `onMounted` runs first (and now correctly clears the workspace item), then the watch fires with the same query. The watch's "if `activeChatId.value !== 'chat-${sessionId}'`" guard prevents the double-clear from being a no-op, but make sure both paths use the same logic.
4. **Don't add `workspacesStore.setActiveWorkspaceItem(null)` to the `view === 'task'` branch.** `setActiveTask` already does the right thing (it sets the parent item as active on purpose). Resetting it would break task view.
5. **`Sidebar.handleChatsNavigate` for the `chat-` ID is now redundant** with the `ChatsList.setActive` reset. It still needs to handle the `delete-chat` branch (line 180-189), so keep the function. Just don't rely on it as the only chat-selection path.
6. **The test stubs `EventSource` in `setup.ts`.** `ChatsList` doesn't directly use `EventSource` (it uses the `api.SseClient`), but `onMounted` does call `connectSessionsSse` which uses the api module. The api module is mocked, so the test should not open a real EventSource. If you see `EventSource is not defined` errors, the api mock is not effective — check that `vi.spyOn(api, 'getChats').mockResolvedValue(...)` runs BEFORE `mount(ChatsList)`.

---

## Verification summary

- `cd src/apps/desktop && bunx vitest run` → 35/35 tests pass (4 new + 31 existing).
- `cd src/apps/desktop && bun run build` → clean TypeScript build, no errors.
- Manual: visual confirmation in the browser that at most one of {chat row, workspace item, task row} is highlighted at any time.
