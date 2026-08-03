# Plan: ChatView Stop Button (cancel a running agent)

**Task ID:** `task_1785730430551`
**Date:** 2026-08-06
**Worktree:** `.worktrees/chatview-stop`
**Branch:** `worktree/chatview-stop`

---

## Symtom (user report)

User with the chat-view open and an agent actively running (the
LLM is streaming chunks, a tool call is in flight, or a retry
delay is ticking) has **no way to stop the agent**. The interface
shows the streaming bubble + a "Queue" button instead of "Send",
but Queue is for queueing new messages — it does NOT cancel the
running one. The user has to wait for the agent to finish or
restart the `nalar` process entirely.

The backend already has every primitive needed:

- `POST /api/llm/session/:session/stop` (registered at `src/main.zig:307`)
- Handler `sessionStopHandler` (`src/ai_workflow/tui/http_handlers/session_stop.zig`)
- DB helper `llm_history.cancelSession` (`src/ai_workflow/tui/llm_history.zig:2201`)
- Worker loop check `isWorkerCancelled` at the top of every iteration (`workflow.zig:500`)
- Retry-delay check `isWorkerCancelled` polled every 50ms (`retry_delay_ms.zig:42`)
- Workflow `deleteWorker` on break → SSE `worker deleted` event → `App.vue` removes the session from `processingState`

What's missing is purely the frontend: an API wrapper + a button +
the test that proves the button actually cancels the agent.

---

## Goal

User can click a Stop button in the chat view while the agent is
running. Clicking it sends a request to the backend that flips
the worker's `cancelled` flag. The agent's loop breaks at the next
iteration boundary, the worker row is deleted, the SSE `worker
deleted` event fires, and the UI returns to the idle state.

## UX

| State | Button visible | Button label | Click behaviour |
|---|---|---|---|
| Idle (no worker) | hidden | — | — |
| Agent running | shown | "Stop" with a red square icon | POST `/api/llm/session/<sid>/stop`, show inline spinner until idle |
| Stop in flight | shown | spinner + "Stopping…" | disabled (no re-click) |
| Stop API error | shown | "Stop" | re-enable, show error toast |

Reads the local `processingState[sessionId]` ref (same source the
per-task spinner in `WorkspaceItemTaskCard.vue:294` uses) to drive
the visible state. NO new state — we piggyback on the existing
SSE-`worker`-event-driven ref so the button auto-hides when the
worker is deleted without any extra subscription.

## Placement

Adjacent to the existing **Queue** button in `FileInput.vue` —
inside the chat's input form (the same row as the text input +
📎 file picker + Queue). This places the button:

- In the user's natural focus zone (where they would type next)
- Visible in BOTH the full-width chat AND the KanbanChatDialog
  (the FileInput is mounted in both layouts)
- Visible in BOTH the headerless standalone chat (`showHeader=false`)
  AND the kanban 3-column layout (`showHeader=true`)

We do NOT collapse the Queue button into a Stop button — users
still want to queue follow-up messages while the agent runs.
Two buttons, side-by-side: violet/blue **Queue** + red **Stop**.

## Out of scope (v1)

- **Mid-stream cancellation during the LLM SSE chunk read** —
  `Agent.zig` declares `error.Cancelled` in its error enum but it
  is never actually returned from the streaming loop. The cancel
  check fires at the top of the workflow loop iteration and inside
  the retry delay, so the LLM stops at the next iteration boundary
  (typically within a few seconds). True mid-stream interrupt is
  a follow-up; see "Future enhancements" below.
- **Cancelling queued messages** — the stop button only flips the
  worker `cancelled` flag. Queued messages remain queued and will
  be drained by the next session. (The workflow's loop top also
  drains the queue, so this would be a separate UX decision.)
- **Confirmation modal** — clicking Stop is irreversible and the
  agent will continue streaming the current chunk, so a
  confirmation dialog would feel slow. Per-user-feedback pattern
  ("I just want it to stop now"). The button is small and red;
  mis-clicks are recoverable (the user can re-send the message).
- **Keyboard shortcut** (e.g. `Esc` or `Cmd/Ctrl+.`) — could be
  added later as a follow-up.

---

## Architecture

### 1. Frontend API wrapper

File: `src/apps/desktop/src/api/index.ts`

Add a new function (around the existing `compactSession` at line 1252):

```ts
/**
 * Stop/cancel a running LLM session.
 *
 * The backend handler (`sessionStopHandler`) flips the worker row's
 * `cancelled` flag to 1. The workflow's loop checks this flag at the
 * top of every iteration and inside the retry delay — once it sees
 * `cancelled`, it breaks out, calls `deleteWorker`, and the SSE
 * `worker deleted` event removes the session from `processingState`
 * on the frontend. The next stop-button visibility check (driven by
 * `processingState[sessionId]`) hides the button.
 *
 * Idempotent: calling stop on a session that has no worker row is a
 * 200 OK (the UPDATE matches 0 rows; the handler does not inspect
 * the row count). Calling stop on a session that is already
 * cancelled is a 200 OK (the flag is already 1).
 *
 * Returns `{ success: true, session_id }` on success.
 *
 * POST /api/llm/session/:session/stop
 */
export async function stopSession(
  sessionId: string,
): Promise<{ success: boolean; session_id?: string }> {
  try {
    return await apiFetch<{ success: boolean; session_id: string }>(
      `/llm/session/${sessionId}/stop`,
      { method: 'POST' },
    )
  } catch (error) {
    console.error('Failed to stop session:', error)
    return { success: false }
  }
}
```

Uses `apiFetch` (not raw `fetch`) so the error-toast-on-non-2xx
contract is consistent with the rest of the desktop client.

### 2. FileInput — new event + button

File: `src/apps/desktop/src/components/file/FileInput.vue`

**Props (unchanged):** the existing `isLoading` and
`isLLMProcessing` are already passed by `ChatView.vue:2697`.

**DefineEmits (extended):**

```ts
const emit = defineEmits<{
  submit: [message: string, files?: File[]]
  'files-selected': [files: File[]]
  // NEW: emitted when the user clicks the Stop button. Parent
  // (ChatView) calls api.stopSession(sessionId) and owns the
  // session-id → API mapping. We do NOT inject the API call here
  // because FileInput is a generic input component shared by
  // multiple chat views (KanbanChatDialog, the standalone chat
  // route, etc.) and the stop semantics are tied to the chat's
  // sessionId, not the input box.
  'stop-session': []
  // NEW: optional — parent can pass back a `isStoppingSession` flag
  // so the button shows a spinner while the API call is in flight.
  // We don't strictly need this — the SSE `worker deleted` event
  // fires faster than the API round-trip — but it covers the case
  // where the user clicks Stop and the SSE event is delayed.
}>()
```

**New reactive state:**

```ts
const isStopping = ref(false)
```

**Click handler:**

```ts
const handleStopClick = () => {
  if (isStopping.value) return
  isStopping.value = true
  emit('stop-session')
}
```

We emit a `stop-session` event rather than calling the API
directly. The parent (ChatView) is the layer that owns the API
wrapper and can coordinate the optimistic UI with the SSE
`worker deleted` event.

**Reset on idle:** a `watch` on the parent's `isLLMProcessing`
prop flips `isStopping` back to false when the LLM is no longer
processing. This handles the fast path (SSE beats the API call)
and the slow path (backend processes the cancel before SSE).

```ts
watch(
  () => props.isLLMProcessing,
  (isProcessing) => {
    if (!isProcessing) isStopping.value = false
  },
)
```

**New template (sibling of the existing Queue button):**

```vue
<button
  v-if="isLLMProcessing"
  type="button"
  @click="handleStopClick"
  :disabled="isStopping"
  data-testid="stop-session-button"
  class="px-3 py-3 rounded-xl text-sm font-medium transition-all duration-200 border flex items-center gap-2"
  :class="isStopping ? 'cursor-not-allowed opacity-70' : 'hover:opacity-90 active:scale-95'"
  style="
    background-color: var(--color-red);
    color: var(--color-bg);
    border-color: var(--color-border);
  "
  title="Stop the running agent"
  aria-label="Stop session"
>
  <div
    v-if="isStopping"
    class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
    style="border-color: var(--color-bg); border-top-color: transparent;"
  ></div>
  <svg v-else xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
    <rect x="6" y="6" width="12" height="12" rx="2" />
  </svg>
  <span>{{ isStopping ? 'Stopping…' : 'Stop' }}</span>
</button>
```

### 3. ChatView — handle the emit

File: `src/apps/desktop/src/components/views/ChatView.vue`

The `<FileInput>` template at line 2693 receives the new emit:

```vue
<FileInput
  :cwd="cwd"
  :queuedMessages="queuedMessages"
  :isLoading="isLoading"
  :isLLMProcessing="isLLMProcessing"
  @submit="handleFileInputSubmit"
  @files-selected="handleFileInputSubmit"
  @stop-session="handleStopSession"
/>
```

**New handler:**

```ts
const handleStopSession = async () => {
  if (!sessionId.value) return
  try {
    await api.stopSession(sessionId.value)
  } catch (err) {
    console.error('Failed to stop session:', err)
  }
  // We deliberately do NOT optimistically flip isLLMProcessing
  // here. The SSE `worker deleted` event drives the visible state
  // and will flip processingState[sessionId] → false within
  // milliseconds. Flipping locally would race with the SSE event
  // and could cause a flicker (button hides → re-shows → hides).
  // The `isStopping` flag in FileInput is the only optimistic UI
  // we need — it shows the spinner during the API round-trip.
}
```

**Why no optimistic flip:** the event bus is already on its way
with the `worker deleted` event. The local `isStopping` flag is
enough to give the user click feedback (spinner appears within the
same frame as the click). When the SSE event lands (typically
<50ms later for a local backend), `processingState[sessionId]`
becomes false → `isLLMProcessing` becomes false → the button's
`v-if` hides it.

### 4. Tests

**4.1 `src/apps/desktop/src/__tests__/FileInput.stopButton.spec.ts` (new)**

Cover the UI state of the button, not the API call:

- A: button is hidden when `isLLMProcessing=false` (default).
- B: button is shown when `isLLMProcessing=true`.
- C: button label is "Stop" by default, "Stopping…" when `isStopping` is true.
- D: button click emits `stop-session` exactly once.
- E: button is disabled + shows spinner while `isStopping=true`.
- F: clicking while `isStopping=true` does NOT emit a second `stop-session` (debounce).
- G: when `isLLMProcessing` flips from `true` to `false`, the button re-hides (this is covered by the `v-if` but we lock it in).
- H: when `isLLMProcessing` flips from `true` to `false` while `isStopping=true`, the watch resets `isStopping` to false (no stuck spinner).

Use `mount(FileInput)` with minimal props and assert DOM state.
For the `isStopping` prop, we need to expose it. Add a prop
`isStopping?: boolean` (default false) so the test can force the
state without having to emit-and-await. The prop is the PARENT'S
claim about whether a stop is in flight — conservative: only set
when the API call is in flight. Default false.

**4.2 `src/apps/desktop/src/__tests__/ChatView.stopSession.spec.ts` (new)**

Cover the wiring + the click behaviour end-to-end:

- A: clicking the Stop button calls `api.stopSession(sessionId)` with the active session id.
- B: `api.stopSession` is called with the un-prefixed session id (no `chat-` prefix).
- C: when `api.stopSession` resolves, the SSE `worker deleted` event hides the button (mount = real AppLayout, mock SSE via sseBus, fire the event, assert button absent).
- D: when `api.stopSession` rejects, the error is caught (no unhandled promise rejection) and the button stays visible (until the SSE event clears it).
- E: rapid double-clicks emit exactly one `stop-session` from FileInput and result in exactly one `api.stopSession` call (debounce mirror).

For the SSE event, use `useSseBus()` directly (the same bus
App.vue installs). Import the bus, fire a `{ type: 'worker',
action: 'deleted', session_id: <sid> }` event, await
`flushPromises`, assert the button is gone.

### 5. Documentation

- `docs/SPEC.md` — add a row to the changelog section noting the
  new "Stop" button (link to this plan).
- `AGENTS.md` — add a "### 2026-08-06: ChatView Stop button"
  entry summarising what landed (per the project's append-only
  changelog convention).
- `docs/superpowers/specs/2026-08-06-chatview-stop-button-design.md`
  — design spec (mirror of the spec section below).

---

## Spec (one-glance summary)

### Behaviour

- Active session, agent running → button visible.
- Click button → POST `/api/llm/session/<sid>/stop` → spinner appears.
- Backend flips `cancelled=1` → workflow loop breaks on next iteration.
- Workflow calls `deleteWorker` → SSE `worker deleted` event.
- `App.vue.handleWorkerEvent` removes session from `processingState`.
- `ChatView.isLLMProcessing` flips false → button's `v-if` hides it.
- `FileInput.isStopping` watch resets `isStopping` to false.

### Failure modes

- **API call fails (network/500)**: error caught in ChatView, console.error, button stays visible (no `processingState` change). The `isStopping` flag is NOT reset by the API failure — but the `isStopping` watch fires when `isLLMProcessing` flips, so the spinner disappears the moment the SSE event lands (which always happens server-side regardless of the API call).
- **Mid-stream cancel semantics**: the user might see one more SSE chunk land after clicking Stop — the workflow loop only checks at iteration boundaries. This is acceptable UX (the alternative — true mid-stream interrupt — requires plumbing a cancellation signal into the LLM client's `recv()` loop, which `Agent.zig::callStreaming` does not currently support).
- **Button clicked twice**: the second click is a no-op (the `isStopping` flag in FileInput gates the handler). At the API layer, calling `cancelSession` twice is idempotent (the UPDATE is `cancelled=1` regardless of the current value).

### Visual

- **Idle**: hidden.
- **Running**: red button next to the Queue button. Icon: filled red square. Label: "Stop".
- **Stopping**: red button, disabled, spinner. Label: "Stopping…".

### Affected files

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | + `stopSession()` API wrapper (~20 lines) |
| `src/apps/desktop/src/components/file/FileInput.vue` | + `stop-session` emit, + `isStopping` prop, + `handleStopClick`, + button template (~50 lines) |
| `src/apps/desktop/src/components/views/ChatView.vue` | + `handleStopSession` handler, + `@stop-session` binding on `<FileInput>` (~10 lines) |
| `src/apps/desktop/src/__tests__/FileInput.stopButton.spec.ts` | NEW — 8 behavioural tests |
| `src/apps/desktop/src/__tests__/ChatView.stopSession.spec.ts` | NEW — 5 behavioural tests |
| `docs/SPEC.md` | + changelog row |
| `AGENTS.md` | + changelog block |
| `docs/superpowers/specs/2026-08-06-chatview-stop-button-design.md` | NEW — design spec |

### Verification

```bash
# Frontend
cd src/apps/desktop
timeout 120 bun run build 2>&1 | tail -n 20
timeout 240 bunx vitest run 2>&1 | tail -n 20

# Backend (no changes expected; smoke test to confirm handlers run)
timeout 120 zig build test --summary all 2>&1 | tail -n 20
```

Expected: both `bun run build` (vue-tsc) and `bunx vitest run`
pass clean. `zig build test` still passes (no backend changes).

### Manual smoke test

1. Open a chat with a running agent (use the dev nalar on port 8080).
2. Verify the Stop button appears in the input row.
3. Click Stop. Verify the spinner appears + button label changes to "Stopping…".
4. Within ~1 second, the spinner disappears and the button hides.
5. Verify the agent actually stopped — chat history shows the partial response, no new chunks, no new tool calls.
6. Refresh the page. Verify the chat is in the idle state (no worker row, no spinner).

### Future enhancements (out of scope)

- **Mid-stream cancellation in `Agent.zig::callStreaming`**: add a `state.cancelled` atomic polled in the chunk read loop, return `error.Cancelled` when set. Wire it to the existing `isWorkerCancelled` DB check. This would make the Stop button truly instant (within one SSE chunk).
- **Keyboard shortcut `Esc` while focused on the chat**: would conflict with the existing Esc-to-clear-selection in the design canvas, so a chat-scoped listener is needed.
- **Cancellation confirmation modal**: opt-in via a setting for users who frequently mis-click.
- **Cancelling queued messages**: separate "Stop and clear queue" button or a checkbox in the stop confirmation.

---

## Pitfalls (record during implementation)

Tracked in the per-task memory file at
`.nalar/memories/chatview-stop-button-2026-08-06.md` with the
"Lessons learned" pattern used by sibling memories. Likely
candidates:

- **Don't optimistically flip `isLLMProcessing` locally** — the
  SSE event races with the API response and could cause a flicker
  (button hides → re-shows → hides). The `isStopping` flag is the
  only optimistic UI surface; `processingState` is the source of
  truth.
- **The existing `isLoading` prop in FileInput is for the queue
  fetch, NOT for the stop request** — it's tempting to overload
  it, but a separate `isStopping` flag keeps the two
  affordances independent (a user can queue while stopping).
- **`flushPromises` alone is NOT enough** to make the
  `processingState` change reactive in tests — the SSE event
  listener is registered on `bus.on('worker', ...)` and the
  `delete newState[sessionId]` mutation only triggers re-render
  after Vue's reactivity tick. Wrap with `await nextTick()` in
  addition to `flushPromises()`.
- **The `chat-` prefix on `props.chatId`** must be stripped before
  passing to `api.stopSession` — same `replace(/^chat-/, '')`
  pattern as `sessionId.value = props.chatId.replace(...)` at
  line 2001. Already handled by reusing `sessionId.value`.
- **The frontend `processingState` map is reset on App.vue
  remount** (the on-mount SSE reconnect fetches the worker list
  fresh). For the v1 stop button, this is fine because the user
  clicking Stop is in the same App.vue lifetime.

---

## TDD sequence

1. RED: write `FileInput.stopButton.spec.ts` A–H. They fail:
   `stop-session` emit does not exist, button does not exist.
2. GREEN: add the `isStopping` prop, `handleStopClick`, button
   template, `stop-session` emit. Tests A–H pass.
3. RED: write `ChatView.stopSession.spec.ts` A–E. They fail:
   `api.stopSession` is not exported.
4. GREEN: add `api.stopSession()` and `handleStopSession`. Tests
   A–E pass.
5. Run `bun run build` → vue-tsc pass.
6. Run `bunx vitest run` → no regressions.
7. Manual smoke on port 8080.
