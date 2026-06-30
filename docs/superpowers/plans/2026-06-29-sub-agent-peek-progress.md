# Sub-Agent Peek Progress Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user click on a `spawn_sub_agent` tool pill in a chat message and watch the sub-agent's live progress (streaming LLM chunks arriving for that sub-agent's session) without leaving the parent chat.

**Architecture:** A right-side slide-over panel (`SubAgentPeekPanel.vue`) opens when the user clicks the `spawn_sub_agent` header in the existing `SpawnSubAgent.vue` card. The panel mounts a small composable (`useSubAgentPeek`) that (1) fetches the sub-agent's initial message history via `GET /llm/session/{sid}/messages` and (2) opens a dedicated `llm:<sid>` SSE channel for live updates. On close, the channel is torn down. The composable is mounted at the `ChatView` level (so it survives a re-render of the tool card) and toggled by a new piece of navigation state in `navigationStore`.

**Tech Stack:** Vue 3 (Composition API) + TypeScript + Pinia + the project's existing `api.SseClient` wrapper. No new backend code is needed — the data model already supports it (sub-agent session has its own `llm_history` rows with `parent_session_id` set, its own `worker` row keyed by `session_id`, and the existing `?channels=llm:<sid>` SSE routing already exists from `unified_events_sse.zig`).

---

## Background & motivation

Today, the user sees `spawn_sub_agent` rendered as a tool card with one row per sub-agent, showing name, success/failure, and a `session_id`. To see what the sub-agent actually did, the user has to either:

1. Click `session_id` (currently no link — they have to copy-paste it into the chat URL bar `/app/chat/{sid}`), or
2. Wait for the sub-agent to finish and read the `<response>` block.

For long-running sub-agents (the user said the screenshot showed `spawn_sub_agent` running on Chunk 1 — these can take minutes), there is no way to see **in-progress** progress without leaving the parent chat. This plan adds that capability.

## Locked design decisions

1. **UI surface:** Right-side slide-over panel (`<SubAgentPeekPanel>`), not a modal, not in-place expand. Rationale: a modal blocks the parent chat (the user explicitly wants to watch without leaving); in-place expand inside the tool card makes the card visually chaotic when streaming long content. A slide-over is the standard pattern in IDEs (VS Code "Peek Definition") for "view child without losing parent context".

2. **One sub-agent per panel:** v1 shows ONE sub-agent at a time. If a `spawn_sub_agent` call spawned 3 sub-agents, the user clicks the row for the one they care about — each row has its own "peek" affordance. (The existing card already has per-row UI; we add a "peek" button per row, not just the header.) A multi-tab panel is deferred to v2.

3. **Composable-driven SSE:** All SSE wiring lives in `useSubAgentPeek` so the panel component is a thin presentational layer. Easier to unit-test and re-use if other surfaces ever need the same view (e.g., a future "active sub-agents" widget on the kanban board).

4. **No new backend work:** The backend already exposes everything we need — `/llm/session/{sid}/messages` (history), `/api/events?channels=llm:{sid}` (live streaming). This plan is **frontend-only**.

5. **No cross-chat peek:** v1 peek only works when the user is viewing a chat that contains the `spawn_sub_agent` tool call. The composable reads `parent_session_id` from the panel payload to enforce this — you can't peek into a sub-agent from a chat that didn't spawn it.

6. **Panel auto-refreshes completion:** When the SSE `finish_reason` arrives, the panel marks the sub-agent "complete", the spinner stops, and the full response is rendered. The user can keep the panel open (to scroll back through the assistant's tool calls), close it, or click "Open full chat view" to navigate to `/app/chat/<sid>`.

## Out of scope (deferred)

- **Multiple sub-agents in one panel** (tabs/carousel) — deferred to v2 if usage data shows users want it.
- **Notifications when a peeked sub-agent completes while panel is closed** — deferred; in v1 the user must keep the panel open to see completion. (We could add a small "● 1 sub-agent completed" badge on the tool card header, but that's a follow-up.)
- **Stop / Cancel from the peek panel** — the peek is read-only in v1. Stopping a running sub-agent has other UX implications (orphan the in-flight generation on the backend) that warrant their own plan.
- **Editing / re-running a sub-agent from the peek panel** — read-only in v1.
- **Showing the sub-agent's full system prompt** — security: the system prompt can contain API keys, custom instructions the user considers private, and embedded memory file contents. v1 shows the **first 200 chars of the instruction** only, with a "…" truncation. Full system prompt is gated behind "Open full chat view" (which is the user's chat, they can already see it).
- **A persistent "active sub-agents" widget on the sidebar / kanban** — this would be a separate feature.
- **Peek a sub-agent from a session that is NOT the parent** — out of scope; see decision #5.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue` | CREATE | The slide-over panel UI: header, message list, status badge, "open full" button. Pure presentational — receives all data via props. |
| `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.spec.ts` | CREATE | Vue Test Utils render tests: header renders agent name + status, message list renders user/assistant/tool messages, "Open full chat view" emits the navigate event. |
| `src/apps/desktop/src/composables/useSubAgentPeek.ts` | CREATE | Owns the peek lifecycle: fetch initial history, open SSE, accumulate chunks, expose reactive state (`messages`, `status`, `tokens`), cleanup on unmount. |
| `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts` | CREATE | Composables test (using `@vue/test-utils`'s `mount` + a mocked `api.SseClient`): fetches messages, accumulates chunks, marks complete on `finish_reason='stop'`, cleans up on unmount. |
| `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue` | MODIFY | Add an `eye` icon button per agent row (between the existing session-id badge and the success/failed label). Emit a `peek` event with `{ sessionId, agentName, instruction }`. |
| `src/apps/desktop/src/components/ChatView.vue` | MODIFY | Listen for the `peek` event from `<SpawnSubAgent>`, set the new navigation store field, render `<SubAgentPeekPanel>` once. |
| `src/apps/desktop/src/stores/navigation.ts` | MODIFY | Add `peekPanel: { sessionId, agentName, instruction } \| null` + `openPeek(payload)` / `closePeek()` actions. |
| `src/apps/desktop/src/api/index.ts` | MODIFY | Add a typed wrapper `getSessionMessages(sid, { limit })` if not already present (it is — `loadSessionMessages` at line ~580). **May not need a change.** Verify before editing. |

`SubAgentPeekPanel.vue` and the composable live under `components/nalar/` (next to the existing `SubAgentModal.vue`) and `composables/` respectively, matching the project's existing structure.

---

## Backend data flow (already exists; cited for context)

When a parent chat's LLM calls `spawn_sub_agent`:

1. `execSpawnSubAgent` in `src/ai_workflow/tui/tool_registry.zig:971` runs each sub-agent via `group.concurrent`.
2. Each `runSubAgent` (line 1180) creates a `session_id` of the form `subagent_{nanoseconds}_{resolved_name}` (line 1186).
3. The session's `llm_history` rows have `parent_session_id` set to the parent's `session_id` (line 1214 of `tool_registry.zig`).
4. Each sub-agent registers a `worker` row keyed by `session_id` (line 901).
5. As the sub-agent streams, chunks are emitted on the `llm:<sid>` SSE channel via `unified_events_sse.zig:118`.
6. On finish, `markSessionIdle` / `deleteWorkerBySessionId` fire a `worker_deleted` event.

The peek panel listens on `llm:<sid>` for the live stream. It does NOT need to listen on `workers` — the SSE chunks carry everything the panel needs (`content`, `finish_reason`, `tool_calls`, `tool_call_id`, `tool_name`, etc. per the `SseEvent` interface at `api/index.ts:720`).

---

## Implementation

### Chunk 1 — Navigation store + composable skeleton

#### Task 1.1: Add peek state to navigation store

**Files:** Modify `src/apps/desktop/src/stores/navigation.ts`

- [ ] **Step 1: Write the failing test**

Edit the existing `src/apps/desktop/src/__tests__/navigation.spec.ts` (or create it if missing — check first). Add 3 tests:
1. `openPeek(payload)` sets `peekPanel.value` to the payload.
2. `closePeek()` sets `peekPanel.value` to `null`.
3. After `closePeek()`, `peekPanel` is reactive (the panel disappears).

```ts
import { setActivePinia, createPinia } from 'pinia'
import { useNavigationStore } from '../stores/navigation'

describe('navigation.peekPanel', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('openPeek sets the panel payload', () => {
    const nav = useNavigationStore()
    nav.openPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
    expect(nav.peekPanel).toEqual({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
  })

  it('closePeek clears the panel', () => {
    const nav = useNavigationStore()
    nav.openPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
    nav.closePeek()
    expect(nav.peekPanel).toBeNull()
  })

  it('peekPanel is reactive', () => {
    const nav = useNavigationStore()
    const r = nav.peekPanel  // read once
    nav.openPeek({ sessionId: 's', agentName: 'a', instruction: 'i' })
    expect(r).not.toBe(null)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run navigation.spec.ts 2>&1 | tail -n 20`
Expected: FAIL with `peekPanel is undefined` or similar.

- [ ] **Step 3: Add the field + actions to the store**

In `src/apps/desktop/src/stores/navigation.ts`, after `clearAll` (around line 122):

```ts
// Sub-agent peek panel state. When set, <ChatView> renders
// <SubAgentPeekPanel> for the given sub-agent session. The payload
// carries everything the panel needs from the spawn_sub_agent tool
// card (so we don't have to re-parse the message). Set via
// `openPeek()` from the SpawnSubAgent card's row click handler;
// cleared via `closePeek()` from the panel's close button or
// route change away from the parent chat.
const peekPanel = ref<{
  sessionId: string
  agentName: string
  instruction: string
} | null>(null)

function openPeek(payload: { sessionId: string; agentName: string; instruction: string }) {
  peekPanel.value = payload
}

function closePeek() {
  peekPanel.value = null
}
```

Then add `peekPanel`, `openPeek`, `closePeek` to the returned object from the store.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run navigation.spec.ts 2>&1 | tail -n 20`
Expected: PASS (3/3 tests).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/stores/navigation.ts src/apps/desktop/src/__tests__/navigation.spec.ts
git commit -m "feat(peek): add peekPanel state + openPeek/closePeek actions to navigation store"
```

#### Task 1.2: Create the `useSubAgentPeek` composable (skeleton — no SSE yet)

**Files:** Create `src/apps/desktop/src/composables/useSubAgentPeek.ts`

- [ ] **Step 1: Write the failing test**

Create `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts`:

```ts
import { defineComponent, h } from 'vue'
import { mount } from '@vue/test-utils'
import { useSubAgentPeek } from '../composables/useSubAgentPeek'
import * as api from '../api'

// Mock the api module so loadSessionMessages is deterministic
vi.mock('../api', () => ({
  apiFetch: vi.fn(),
  createUnifiedSseConnection: vi.fn(() => ({ close: vi.fn() })),
}))

describe('useSubAgentPeek', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    ;(api.apiFetch as any).mockResolvedValue({
      messages: [
        { id: 'm1', role: 'user', content: 'do X' },
        { id: 'm2', role: 'assistant', content: 'starting...', finish_reason: null },
      ],
      has_more: false,
      next_cursor: null,
    })
  })

  it('fetches initial history on mount', async () => {
    let peek: ReturnType<typeof useSubAgentPeek> | null = null
    const Comp = defineComponent({
      setup() {
        peek = useSubAgentPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
        return () => h('div')
      },
    })
    mount(Comp)
    // Wait one microtask for the async fetch
    await new Promise(r => setTimeout(r, 0))
    expect(peek!.messages.value.length).toBeGreaterThanOrEqual(1)
    expect(api.apiFetch).toHaveBeenCalledWith(
      expect.stringContaining('/llm/session/subagent_1_foo/messages'),
      expect.any(Object),
    )
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run useSubAgentPeek.spec.ts 2>&1 | tail -n 20`
Expected: FAIL with `Cannot find module '../composables/useSubAgentPeek'`.

- [ ] **Step 3: Write the composable skeleton (no SSE yet)**

Create `src/apps/desktop/src/composables/useSubAgentPeek.ts`:

```ts
import { onMounted, onUnmounted, ref, shallowRef } from 'vue'
import * as api from '../api'
import type { ChatMessage } from '../api'

export interface UseSubAgentPeekOptions {
  sessionId: string
  agentName: string
  instruction: string
}

export type PeekStatus = 'idle' | 'loading' | 'streaming' | 'complete' | 'error'

export interface UseSubAgentPeekReturn {
  messages: ReturnType<typeof ref<ChatMessage[]>>
  status: ReturnType<typeof ref<PeekStatus>>
  errorMessage: ReturnType<typeof ref<string | null>>
  totalTokens: ReturnType<typeof ref<number>>
  /** Force a manual reload (called from the "Reload" button on error). */
  reload: () => Promise<void>
}

export function useSubAgentPeek(opts: UseSubAgentPeekOptions): UseSubAgentPeekReturn {
  const messages = ref<ChatMessage[]>([])
  const status = ref<PeekStatus>('idle')
  const errorMessage = ref<string | null>(null)
  const totalTokens = ref(0)

  let sseClient: api.SseClient | null = null

  async function fetchInitial() {
    status.value = 'loading'
    errorMessage.value = null
    try {
      const data = await api.apiFetch<{
        messages: ChatMessage[]
        has_more: boolean
        next_cursor: string | null
      }>(`/llm/session/${opts.sessionId}/messages?limit=100&sort_by=created_at&direction=asc`, { silent: true })
      messages.value = data.messages ?? []
      // If the latest message has finish_reason set, the sub-agent already finished
      const last = messages.value[messages.value.length - 1]
      if (last?.finish_reason) {
        status.value = 'complete'
      } else {
        status.value = 'streaming'
        openSse()
      }
    } catch (err) {
      errorMessage.value = String(err)
      status.value = 'error'
    }
  }

  function openSse() {
    sseClient = api.createUnifiedSseConnection({
      channels: {
        llm: {
          sessionId: opts.sessionId,
          onEvent: (ev: api.SseEvent) => {
            applyChunk(ev)
          },
        },
      },
    })
  }

  function applyChunk(ev: api.SseEvent) {
    // ... see Chunk 2 for the full implementation ...
  }

  function closeSse() {
    if (sseClient) {
      sseClient.close()
      sseClient = null
    }
  }

  onMounted(() => {
    fetchInitial()
  })

  onUnmounted(() => {
    closeSse()
  })

  return {
    messages,
    status,
    errorMessage,
    totalTokens,
    reload: fetchInitial,
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run useSubAgentPeek.spec.ts 2>&1 | tail -n 20`
Expected: PASS (1/1 test).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/composables/useSubAgentPeek.ts src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts
git commit -m "feat(peek): add useSubAgentPeek composable skeleton with initial history fetch"
```

### Chunk 2 — SSE chunk accumulation + message assembly

#### Task 2.1: Implement `applyChunk` with streaming semantics

**Files:** Modify `src/apps/desktop/src/composables/useSubAgentPeek.ts`

The composable must accumulate streaming chunks into message bubbles (similar to how `ChatView.vue` does it for the parent chat). Re-use the same pattern: when a chunk arrives with `content`, find or create the last assistant message and append. When `tool_calls` arrives, attach it to the last assistant message. When a tool result with `tool_call_id` arrives, append a new tool message.

- [ ] **Step 1: Write the failing test**

Add to `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts`:

```ts
import { defineComponent, h, nextTick } from 'vue'

it('accumulates streaming content chunks into the last assistant message', async () => {
  let peek: ReturnType<typeof useSubAgentPeek> | null = null
  const Comp = defineComponent({
    setup() {
      peek = useSubAgentPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
      return () => h('div')
    },
  })
  mount(Comp)
  await new Promise(r => setTimeout(r, 0))  // wait for initial fetch

  // Find the SSE onEvent callback that was registered
  const sseCall = (api.createUnifiedSseConnection as any).mock.calls[0][0]
  const onEvent = sseCall.channels.llm.onEvent

  // Simulate 3 streaming chunks arriving
  onEvent({ session_id: 'subagent_1_foo', role: 'assistant', content: 'Hello', id: 'a1' })
  onEvent({ session_id: 'subagent_1_foo', role: 'assistant', content: ' world', id: 'a1' })
  onEvent({ session_id: 'subagent_1_foo', role: 'assistant', content: '!', finish_reason: 'stop', id: 'a1' })
  await nextTick()

  const lastMsg = peek!.messages.value[peek!.messages.value.length - 1]
  expect(lastMsg.content).toBe('Hello world!')
  expect(peek!.status.value).toBe('complete')
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run useSubAgentPeek.spec.ts 2>&1 | tail -n 20`
Expected: FAIL with `expected 'Hello' to be 'Hello world!'` (the skeleton doesn't accumulate).

- [ ] **Step 3: Implement `applyChunk`**

Replace the placeholder `applyChunk` in the composable with:

```ts
function applyChunk(ev: api.SseEvent) {
  if (!ev.id && !ev.tool_call_id) return

  // Tool-result message (carries tool_call_id, no content typically)
  if (ev.role === 'tool' && ev.tool_call_id) {
    messages.value = [...messages.value, {
      id: ev.id ?? `tool-${ev.tool_call_id}`,
      role: 'tool',
      content: ev.content ?? '',
      tool_call_id: ev.tool_call_id,
      tool_name: ev.tool_name,
      finish_reason: ev.finish_reason ?? null,
    } as ChatMessage]
    return
  }

  // User or assistant message — find the last message with the same id
  // and append, or create a new one.
  const idx = ev.id ? messages.value.findIndex(m => m.id === ev.id) : -1
  if (idx >= 0) {
    const existing = messages.value[idx]
    const updated: ChatMessage = {
      ...existing,
      content: (existing.content ?? '') + (ev.content ?? ''),
      finish_reason: ev.finish_reason ?? existing.finish_reason,
      tool_calls: ev.tool_calls ?? existing.tool_calls,
    }
    const newArr = [...messages.value]
    newArr[idx] = updated
    messages.value = newArr
  } else {
    messages.value = [...messages.value, {
      id: ev.id,
      role: ev.role ?? 'assistant',
      content: ev.content ?? '',
      tool_calls: ev.tool_calls,
      tool_call_id: ev.tool_call_id,
      tool_name: ev.tool_name,
      finish_reason: ev.finish_reason ?? null,
    } as ChatMessage]
  }

  // Track token usage if the chunk carries it
  if (ev.total_tokens) {
    totalTokens.value = ev.total_tokens
  }

  // Detect completion
  if (ev.finish_reason === 'stop' || ev.finish_reason === 'length' || ev.finish_reason === 'tool_calls') {
    status.value = 'complete'
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run useSubAgentPeek.spec.ts 2>&1 | tail -n 20`
Expected: PASS (2/2 tests).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/composables/useSubAgentPeek.ts src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts
git commit -m "feat(peek): accumulate streaming chunks into assistant/tool messages"
```

#### Task 2.2: Add error / reconnect / cancellation test

**Files:** Modify `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts`

- [ ] **Step 1: Write the failing test**

```ts
it('marks error status if initial fetch fails', async () => {
  ;(api.apiFetch as any).mockRejectedValueOnce(new Error('network'))
  let peek: ReturnType<typeof useSubAgentPeek> | null = null
  const Comp = defineComponent({
    setup() {
      peek = useSubAgentPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
      return () => h('div')
    },
  })
  mount(Comp)
  await new Promise(r => setTimeout(r, 10))
  expect(peek!.status.value).toBe('error')
  expect(peek!.errorMessage.value).toContain('network')
})

it('reload() re-fetches the history', async () => {
  let peek: ReturnType<typeof useSubAgentPeek> | null = null
  const Comp = defineComponent({
    setup() {
      peek = useSubAgentPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
      return () => h('div')
    },
  })
  mount(Comp)
  await new Promise(r => setTimeout(r, 0))
  await peek!.reload()
  expect(api.apiFetch).toHaveBeenCalledTimes(2)
})

it('closes the SSE connection on unmount', async () => {
  let peek: ReturnType<typeof useSubAgentPeek> | null = null
  const Comp = defineComponent({
    setup() {
      peek = useSubAgentPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })
      return () => h('div')
    },
  })
  const wrapper = mount(Comp)
  await new Promise(r => setTimeout(r, 0))
  const sseMock = (api.createUnifiedSseConnection as any).mock.results[0].value
  wrapper.unmount()
  expect(sseMock.close).toHaveBeenCalled()
})
```

- [ ] **Step 2: Run test to verify the unmount test fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run useSubAgentPeek.spec.ts 2>&1 | tail -n 30`
Expected: The error and reload tests may already pass (the skeleton handles them), but the unmount test fails because `closeSse` is only called on unmount if the SSE was created. **Verify which tests fail and proceed.**

- [ ] **Step 3: If needed, fix the composable to fully implement reload + unmount cleanup**

The skeleton already has `onMounted(fetchInitial)` and `onUnmounted(closeSse)`. Verify the implementation matches the test expectations. If the unmount test fails because the SSE wasn't opened (no chunks were sent so `status` stayed at `loading`), update the test to first send a chunk that flips status to `streaming`.

- [ ] **Step 4: Run test to verify all pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run useSubAgentPeek.spec.ts 2>&1 | tail -n 20`
Expected: PASS (5/5 tests).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/composables/useSubAgentPeek.ts src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts
git commit -m "test(peek): cover error/reload/unmount paths in useSubAgentPeek"
```

### Chunk 3 — Panel component UI

#### Task 3.1: Create the `SubAgentPeekPanel.vue` shell

**Files:** Create `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue`

- [ ] **Step 1: Write the failing test**

Create `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.spec.ts`:

```ts
import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import SubAgentPeekPanel from './SubAgentPeekPanel.vue'

describe('SubAgentPeekPanel', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('renders the agent name in the header', () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: {
        sessionId: 'subagent_1_foo',
        agentName: 'foo',
        instruction: 'do X',
        status: 'streaming',
        errorMessage: null,
        messages: [],
      },
    })
    expect(wrapper.text()).toContain('foo')
  })

  it('shows the streaming spinner when status is streaming', () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: {
        sessionId: 'subagent_1_foo',
        agentName: 'foo',
        instruction: 'do X',
        status: 'streaming',
        errorMessage: null,
        messages: [],
      },
    })
    expect(wrapper.find('[data-testid="peek-status"]').text()).toMatch(/streaming/i)
  })

  it('shows the complete badge when status is complete', () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: {
        sessionId: 'subagent_1_foo',
        agentName: 'foo',
        instruction: 'do X',
        status: 'complete',
        errorMessage: null,
        messages: [],
      },
    })
    expect(wrapper.find('[data-testid="peek-status"]').text()).toMatch(/complete/i)
  })

  it('emits close when the close button is clicked', async () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: {
        sessionId: 'subagent_1_foo',
        agentName: 'foo',
        instruction: 'do X',
        status: 'complete',
        errorMessage: null,
        messages: [],
      },
    })
    await wrapper.find('[data-testid="peek-close"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('emits openFull when the "Open full chat view" button is clicked', async () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: {
        sessionId: 'subagent_1_foo',
        agentName: 'foo',
        instruction: 'do X',
        status: 'complete',
        errorMessage: null,
        messages: [],
      },
    })
    await wrapper.find('[data-testid="peek-open-full"]').trigger('click')
    expect(wrapper.emitted('openFull')?.[0]).toEqual(['subagent_1_foo'])
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run SubAgentPeekPanel.spec.ts 2>&1 | tail -n 20`
Expected: FAIL with `Cannot find module './SubAgentPeekPanel.vue'`.

- [ ] **Step 3: Write the panel component (shell + header only)**

Create `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue`:

```vue
<script setup lang="ts">
import { computed } from 'vue'
import type { ChatMessage } from '../../api'
import type { PeekStatus } from '../../composables/useSubAgentPeek'

const props = defineProps<{
  sessionId: string
  agentName: string
  instruction: string
  status: PeekStatus
  errorMessage: string | null
  messages: ChatMessage[]
  totalTokens?: number
}>()

const emit = defineEmits<{
  close: []
  openFull: [sessionId: string]
  reload: []
}>()

const instructionPreview = computed(() => {
  const max = 200
  return props.instruction.length > max
    ? props.instruction.slice(0, max) + '…'
    : props.instruction
})

const statusLabel = computed(() => {
  switch (props.status) {
    case 'idle': return 'Idle'
    case 'loading': return 'Loading…'
    case 'streaming': return 'Streaming…'
    case 'complete': return 'Complete'
    case 'error': return 'Error'
  }
})

const statusClass = computed(() => {
  switch (props.status) {
    case 'streaming': return 'text-violet-500'
    case 'complete': return 'text-green-500'
    case 'error': return 'text-red-500'
    default: return 'text-[var(--semantic-text-muted)]'
  }
})
</script>

<template>
  <Teleport to="body">
    <div
      class="fixed inset-0 z-50 flex justify-end"
      data-testid="peek-panel"
      @keydown.esc="emit('close')"
    >
      <!-- Backdrop -->
      <div
        class="absolute inset-0 bg-black/30"
        @click="emit('close')"
      ></div>

      <!-- Panel -->
      <div
        class="relative w-full max-w-[480px] h-full bg-[var(--semantic-card-bg)] border-l border-[var(--color-border)] shadow-2xl flex flex-col"
      >
        <!-- Header -->
        <div class="px-4 py-3 border-b border-[var(--color-border)] flex items-center gap-2">
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <span class="text-[10px] uppercase tracking-wide text-[var(--semantic-text-muted)]">
                Sub-agent
              </span>
              <span class="font-semibold text-sm truncate" :title="agentName">
                {{ agentName }}
              </span>
              <span
                class="text-xs whitespace-nowrap"
                :class="statusClass"
                data-testid="peek-status"
              >
                <span v-if="status === 'streaming'" class="inline-block w-2 h-2 rounded-full bg-violet-500 animate-pulse mr-1"></span>
                {{ statusLabel }}
              </span>
            </div>
            <p
              class="text-xs text-[var(--semantic-text-muted)] mt-0.5 truncate"
              :title="instruction"
            >
              {{ instructionPreview }}
            </p>
          </div>
          <button
            class="text-xs px-2 py-1 rounded bg-[var(--semantic-content-bg)] hover:bg-violet-500/10 border border-[var(--color-border)]"
            data-testid="peek-open-full"
            :title="`Open ${sessionId} in main chat view`"
            @click="emit('openFull', sessionId)"
          >
            Open full
          </button>
          <button
            class="text-[var(--semantic-text-muted)] hover:text-[var(--semantic-text)] w-7 h-7 flex items-center justify-center rounded"
            data-testid="peek-close"
            title="Close"
            @click="emit('close')"
          >
            ✕
          </button>
        </div>

        <!-- Error banner -->
        <div
          v-if="status === 'error' && errorMessage"
          class="px-4 py-2 bg-red-500/10 border-b border-red-500/30 text-xs text-red-500 flex items-center gap-2"
        >
          <span class="flex-1">{{ errorMessage }}</span>
          <button
            class="px-2 py-0.5 rounded border border-red-500/30 hover:bg-red-500/10"
            @click="emit('reload')"
          >
            Retry
          </button>
        </div>

        <!-- Message list (placeholder; Chunk 3.2 fills it in) -->
        <div class="flex-1 overflow-y-auto px-4 py-3">
          <p class="text-xs text-[var(--semantic-text-muted)]">
            {{ messages.length }} message(s) loaded
          </p>
        </div>

        <!-- Footer -->
        <div class="px-4 py-2 border-t border-[var(--color-border)] text-xs text-[var(--semantic-text-muted)] flex items-center gap-3">
          <span class="truncate" :title="sessionId">session: {{ sessionId }}</span>
          <span v-if="totalTokens" class="ml-auto">{{ totalTokens.toLocaleString() }} tokens</span>
        </div>
      </div>
    </div>
  </Teleport>
</template>
```

- [ ] **Step 4: Run test to verify all 5 pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run SubAgentPeekPanel.spec.ts 2>&1 | tail -n 20`
Expected: PASS (5/5 tests).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue src/apps/desktop/src/components/nalar/SubAgentPeekPanel.spec.ts
git commit -m "feat(peek): create SubAgentPeekPanel shell with header, status, error, close, openFull"
```

#### Task 3.2: Render the message list inside the panel

**Files:** Modify `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue`

The message list needs to render user, assistant, and tool messages. Re-use the visual style of the parent `ChatView.vue` so the user has visual continuity between the peek and the full chat view.

- [ ] **Step 1: Write the failing test**

Add to `src/apps/desktop/src/__tests__/SubAgentPeekPanel.spec.ts`:

```ts
import type { ChatMessage } from '../../api'

it('renders user messages', () => {
  const messages: ChatMessage[] = [
    { id: 'u1', role: 'user', content: 'do X', finish_reason: null },
  ]
  const wrapper = mount(SubAgentPeekPanel, {
    props: {
      sessionId: 's', agentName: 'a', instruction: 'i',
      status: 'streaming', errorMessage: null, messages,
    },
  })
  expect(wrapper.find('[data-testid="peek-msg-user"]').exists()).toBe(true)
  expect(wrapper.text()).toContain('do X')
})

it('renders assistant messages with streaming content', () => {
  const messages: ChatMessage[] = [
    { id: 'a1', role: 'assistant', content: 'Hello world', finish_reason: null },
  ]
  const wrapper = mount(SubAgentPeekPanel, {
    props: {
      sessionId: 's', agentName: 'a', instruction: 'i',
      status: 'streaming', errorMessage: null, messages,
    },
  })
  expect(wrapper.find('[data-testid="peek-msg-assistant"]').exists()).toBe(true)
  expect(wrapper.text()).toContain('Hello world')
})

it('renders tool messages with tool_call_id', () => {
  const messages: ChatMessage[] = [
    { id: 't1', role: 'tool', content: 'tool result', tool_call_id: 'call_1', finish_reason: null },
  ]
  const wrapper = mount(SubAgentPeekPanel, {
    props: {
      sessionId: 's', agentName: 'a', instruction: 'i',
      status: 'streaming', errorMessage: null, messages,
    },
  })
  expect(wrapper.find('[data-testid="peek-msg-tool"]').exists()).toBe(true)
})

it('auto-scrolls to the bottom when a new message is added', async () => {
  const wrapper = mount(SubAgentPeekPanel, {
    props: {
      sessionId: 's', agentName: 'a', instruction: 'i',
      status: 'streaming', errorMessage: null,
      messages: [{ id: '1', role: 'user', content: 'first', finish_reason: null }],
    },
  })
  // Mock the scrollIntoView on the auto-scroll element
  const scrollEl = wrapper.find('[data-testid="peek-messages-scroll"]')
  const spy = vi.spyOn(scrollEl.element as HTMLElement, 'scrollTop', 'set')
  await wrapper.setProps({
    messages: [
      { id: '1', role: 'user', content: 'first', finish_reason: null },
      { id: '2', role: 'assistant', content: 'response', finish_reason: null },
    ],
  })
  await wrapper.vm.$nextTick()
  expect(spy).toHaveBeenCalled()
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run SubAgentPeekPanel.spec.ts 2>&1 | tail -n 30`
Expected: FAIL — `peek-msg-user` element doesn't exist yet.

- [ ] **Step 3: Add the message list rendering**

In `src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue`, replace the placeholder message list with:

```vue
<!-- Message list -->
<div
  ref="scrollRef"
  class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
  data-testid="peek-messages-scroll"
>
  <div v-if="messages.length === 0 && status !== 'loading'" class="text-xs text-[var(--semantic-text-muted)] italic">
    No messages yet.
  </div>

  <div
    v-for="msg in messages"
    :key="msg.id ?? msg.tool_call_id"
    :data-testid="`peek-msg-${msg.role}`"
    class="rounded-md p-2 text-xs"
    :class="{
      'bg-[var(--semantic-content-bg)] border border-[var(--color-border)]': msg.role === 'user',
      'bg-violet-500/5 border border-violet-500/20': msg.role === 'assistant',
      'bg-[var(--color-border)]/30 border border-[var(--color-border)] font-mono text-[11px]': msg.role === 'tool',
    }"
  >
    <div class="font-semibold text-[10px] uppercase tracking-wide text-[var(--semantic-text-muted)] mb-1">
      {{ msg.role }}
      <span v-if="msg.tool_name" class="ml-1 font-normal normal-case">({{ msg.tool_name }})</span>
    </div>
    <pre class="whitespace-pre-wrap break-all font-sans text-xs">{{ msg.content }}</pre>
  </div>
</div>
```

Add a `scrollRef` and a `watch` to auto-scroll:

```ts
import { ref, watch, nextTick } from 'vue'

const scrollRef = ref<HTMLElement | null>(null)

watch(() => props.messages.length, async () => {
  await nextTick()
  if (scrollRef.value) {
    scrollRef.value.scrollTop = scrollRef.value.scrollHeight
  }
})
```

Also watch content changes (streaming chunks append to existing messages):

```ts
watch(() => props.messages.map(m => m.content?.length ?? 0).join(','), async () => {
  await nextTick()
  if (scrollRef.value) {
    scrollRef.value.scrollTop = scrollRef.value.scrollHeight
  }
})
```

- [ ] **Step 4: Run test to verify all pass**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run SubAgentPeekPanel.spec.ts 2>&1 | tail -n 20`
Expected: PASS (9/9 tests total — 5 from 3.1 + 4 new).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/nalar/SubAgentPeekPanel.vue src/apps/desktop/src/components/nalar/SubAgentPeekPanel.spec.ts
git commit -m "feat(peek): render user/assistant/tool message list with auto-scroll"
```

### Chunk 4 — Wire it all together

#### Task 4.1: Add peek button + event to `SpawnSubAgent.vue`

**Files:** Modify `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue`

- [ ] **Step 1: Write the failing test**

In `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.spec.ts` (create if missing; verify first with `find`), add:

```ts
import { mount } from '@vue/test-utils'
import SpawnSubAgent from './SpawnSubAgent.vue'

it('emits peek with sessionId when peek button is clicked', async () => {
  const wrapper = mount(SpawnSubAgent, {
    props: {
      content: `<results>
<agent name="foo" success="true" random_fallback="false">
<session_id>subagent_1_foo</session_id>
<response>done</response>
</agent>
<summary succeeded="1" failed="0" />
</results>`,
      expanded: true,
    },
  })
  await wrapper.find('[data-testid="peek-button"]').trigger('click')
  expect(wrapper.emitted('peek')?.[0]).toEqual([
    expect.objectContaining({
      sessionId: 'subagent_1_foo',
      agentName: 'foo',
    }),
  ])
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run SpawnSubAgent.spec.ts 2>&1 | tail -n 20`
Expected: FAIL — `peek-button` element doesn't exist.

- [ ] **Step 3: Add the defineEmits + peek button**

In `src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue`:

Add to the script:
```ts
const emit = defineEmits<{
  peek: [payload: { sessionId: string; agentName: string; instruction: string }]
}>()

function peekAgent(agent: { sessionId: string | null; name: string; response: string | null }, instruction: string) {
  if (!agent.sessionId) return
  emit('peek', {
    sessionId: agent.sessionId,
    agentName: agent.name,
    instruction,
  })
}
```

Inject `instruction` from props (it's parsed from `subAgentArgs[idx]`). Add a new prop:

```ts
const props = defineProps<{
  content: string
  expanded?: boolean
  subAgentArgs?: SubAgentArgs[] | null
}>()
```

The `subAgentArgs[idx].instruction` already exists in the parsed args (see `parseSpawnSubAgentArgs.ts`).

In the template, inside the agent header row (around line 192-199, between the inherited_context badge and the success/failed label), add:

```vue
<button
  v-if="agent.sessionId"
  class="text-xs text-[var(--semantic-text-muted)] hover:text-violet-500 px-1 rounded"
  data-testid="peek-button"
  :title="`Peek into ${agent.name}'s progress`"
  @click.stop="peekAgent(agent, subAgentArgs?.[idx]?.instruction ?? '')"
>
  👁
</button>
```

(Using `👁` as the peek icon — emoji; matches the project's existing icon usage. Alternative: the text "peek" if emoji rendering is inconsistent across platforms.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run SpawnSubAgent.spec.ts 2>&1 | tail -n 20`
Expected: PASS (1/1 test).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.spec.ts
git commit -m "feat(peek): add peek button per agent row in SpawnSubAgent.vue"
```

#### Task 4.2: Render the panel from ChatView.vue + wire up navigation

**Files:** Modify `src/apps/desktop/src/components/ChatView.vue`

- [ ] **Step 1: Write the failing test**

In `src/apps/desktop/src/components/ChatView.spec.ts` (create if missing; verify first), add:

```ts
import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { useNavigationStore } from '../stores/navigation'
import ChatView from './ChatView.vue'

describe('ChatView peek panel wiring', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('renders <SubAgentPeekPanel> when navigationStore.peekPanel is set', async () => {
    const nav = useNavigationStore()
    nav.openPeek({ sessionId: 'subagent_1_foo', agentName: 'foo', instruction: 'do X' })

    const wrapper = mount(ChatView, {
      props: { chatId: 'parent', chatName: 'Parent' },
      global: {
        stubs: {
          // Stub everything that's hard to mount in isolation
          Teleport: true,
        },
      },
    })
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="peek-panel"]').exists()).toBe(true)
  })

  it('closes panel when navigationStore.closePeek() is called', async () => {
    const nav = useNavigationStore()
    nav.openPeek({ sessionId: 's', agentName: 'a', instruction: 'i' })
    const wrapper = mount(ChatView, {
      props: { chatId: 'parent', chatName: 'Parent' },
      global: { stubs: { Teleport: true } },
    })
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="peek-panel"]').exists()).toBe(true)

    nav.closePeek()
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="peek-panel"]').exists()).toBe(false)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run ChatView.spec.ts 2>&1 | tail -n 20`
Expected: FAIL — `peek-panel` element doesn't exist in ChatView.

- [ ] **Step 3: Wire up the panel**

In `src/apps/desktop/src/components/ChatView.vue`:

Add imports near the top of `<script setup>`:
```ts
import { useNavigationStore } from '../stores/navigation'
import { useSubAgentPeek } from '../composables/useSubAgentPeek'
import SubAgentPeekPanel from './nalar/SubAgentPeekPanel.vue'
```

Inside `<script setup>`, after the existing refs:
```ts
const nav = useNavigationStore()

// Sub-agent peek state. The composable is mounted only when the
// peek panel is open (so we don't open an SSE channel
// unnecessarily). When peekPanel is null, peek is `null` and the
// composable is not active.
const peek = computed(() => {
  if (!nav.peekPanel) return null
  return useSubAgentPeek({
    sessionId: nav.peekPanel.sessionId,
    agentName: nav.peekPanel.agentName,
    instruction: nav.peekPanel.instruction,
  })
})

function openFullPeek(sessionId: string) {
  // Close the peek panel and navigate to the sub-agent's full chat
  // view. The user can return to the parent chat via the browser
  // back button or the chats list.
  nav.closePeek()
  // Use the same navigate path as Sidebar.vue: replace the URL
  // with view=chat&session=<sid>
  const router = useRouter()
  router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
}
```

Find the `<SpawnSubAgent>` v-if block (around line 1825) and add `@peek="..."`:

```vue
<SpawnSubAgent
  v-if="..."
  :content="..."
  :sub-agent-args="..."
  @peek="nav.openPeek($event)"
/>
```

Then near the end of the template, AFTER all the existing chat-view markup (before the closing `</template>`), add:

```vue
<SubAgentPeekPanel
  v-if="nav.peekPanel && peek"
  :session-id="nav.peekPanel.sessionId"
  :agent-name="nav.peekPanel.agentName"
  :instruction="nav.peekPanel.instruction"
  :status="peek.status.value"
  :error-message="peek.errorMessage.value"
  :messages="peek.messages.value"
  :total-tokens="peek.totalTokens.value"
  @close="nav.closePeek()"
  @open-full="openFullPeek"
  @reload="peek.reload"
/>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run ChatView.spec.ts 2>&1 | tail -n 20`
Expected: PASS (2/2 tests).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/ChatView.vue src/apps/desktop/src/components/ChatView.spec.ts
git commit -m "feat(peek): wire SubAgentPeekPanel into ChatView with navigationStore + composable"
```

#### Task 4.3: End-to-end manual smoke test

**Files:** none (manual)

- [ ] **Step 1: Start the backend**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
zig build install:linux:system 2>&1 | tail -n 5
./zig-out/bin/nalar --port 8080 &
```

- [ ] **Step 2: Start the desktop app**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/src/apps/desktop
bun run dev
```

- [ ] **Step 3: Trigger a sub-agent spawn**

1. Open the app at http://localhost:5173
2. Open any existing chat (or create a new one)
3. Send a message that will cause the LLM to call `spawn_sub_agent` (e.g. "spawn a sub-agent to summarize the README.md")
4. Wait for the spawn_sub_agent tool card to appear in the chat

- [ ] **Step 4: Verify the peek button works**

1. The expanded tool card should show a 👁 button per agent row
2. Click the 👁 button for one sub-agent
3. The right-side slide-over panel should open
4. The panel header should show the agent name, status ("Streaming…" with pulsing dot), and the instruction preview
5. The message list should populate as the sub-agent streams
6. When the sub-agent finishes, the status badge should change to "Complete"
7. Click "Open full" — the panel closes and the URL changes to `/app?view=chat&session=subagent_xxx` (the sub-agent's chat loads in the main view)

- [ ] **Step 5: Verify edge cases**

1. Open a peek panel, then close it (click the ✕) — verify the SSE connection is torn down (DevTools Network tab: the `/api/events?channels=llm:subagent_xxx` request should be closed)
2. Open a peek panel for a sub-agent that ALREADY finished (load a chat from history) — the panel should show "Complete" status immediately, no streaming
3. Open a peek panel for a sub-agent that ERRORED — the panel should show an error banner with a "Retry" button
4. Open a peek panel, then navigate to a DIFFERENT chat in the sidebar — verify the panel closes (peek is scoped to the parent chat)

---

## Verification

1. **Type-check:** `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20` — must show clean TypeScript build (per project memory `desktop-typescript-bun-build-as-typecheck`).
2. **Unit tests:** `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 30` — must show all new tests passing, no regressions in existing tests.
3. **Zig backend (no changes expected but verify nothing broke):** `timeout 180 zig build test --summary all 2>&1 | tail -n 5` — same 846/846 baseline.
4. **Manual smoke:** see Task 4.3 above.

---

## Backward compatibility

- **No backend changes** — fully frontend-only. Existing spawn_sub_agent behavior is unchanged.
- **No new endpoints** — reuses `/llm/session/{sid}/messages` and the existing `?channels=llm:<sid>` SSE route.
- **No new DB columns** — the `parent_session_id` column added in a prior migration already stores the link.
- **Peek is opt-in** — if the user never clicks the 👁 button, no SSE channels are opened and no behavior changes.

## Risk analysis

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Multiple SSE connections from one user overwhelm the backend | Low | Medium | v1 caps one peek panel open at a time. v2: add a "max open peeks" check. |
| User leaves parent chat while peek is open | Medium | Low | The peek panel is scoped to the parent chat; on route change, ChatView unmounts, which triggers `onUnmounted(closeSse)`. Verified by the unmount test. |
| Sub-agent session is deleted between fetch and SSE | Low | Low | SSE auto-reconnects via the SseClient. The next fetch attempt (via `reload()` button) would return an error and the panel would show the error state. |
| The peek panel shows content from a different user's session | None | High | The backend `worker_list.zig` already filters by session_id; the SSE endpoint is per-session. Cross-user session access is prevented by the existing auth boundary. |
| Stale `peekPanel` state in navigationStore after a route change | Low | Low | A `watch(() => route.fullPath, () => nav.closePeek())` in AppLayout would close it on any navigation. Out of scope for v1; the panel is scoped to ChatView, so it unmounts when ChatView unmounts. |

## Follow-up work (out of scope for this plan)

- **Multi-agent tabs in one panel** (v2)
- **"● N sub-agents completed" badge on the parent tool card** (v2)
- **Push notification when a peeked sub-agent completes while panel is closed** (v2)
- **Stop / cancel from the peek panel** (v3, requires backend support)
- **Persist peek panel across navigation** (v3, requires global SSE refactor)
- **Show full system prompt** (deferred pending security review)
- **A standalone "Active sub-agents" widget on the sidebar** (separate feature)